-- rex-image-paste: paste clipboard images into remote Rex panes as file paths.
--
--   require("rex-image-paste").setup()
--   rex.bind("cmd+shift+v", "image_paste")
--
-- When the clipboard holds an image (a screenshot, an image copied from a
-- browser, or an image file copied in Finder), the action copies it to the
-- machine that runs the focused terminal and pastes the file's absolute path.
-- Otherwise it pastes the clipboard text.
--
-- The action runs in the Mac's own Rex server, which can read the clipboard.
-- For a pane on another Rex server (ctx.server), the file travels over Rex's
-- own connection: a hidden terminal on that server runs `base64 -d`, and the
-- action types the encoded file into it. The remote needs no setup.

local M = {}

M.version = "0.1.0"

M.options = {
  -- Shrink clipboard images whose long edge is larger than this many pixels.
  -- Vision models downscale large images anyway, and each byte crosses the
  -- network in requests of at most 64 KiB. Set to false to keep the original.
  max_dimension = 2000,
  -- Where images are staged on the Mac. Images for local panes stay here.
  local_dir = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "") .. "/rex-image-paste",
  -- Seconds to spend on one paste. Rex stops a configuration action after 30.
  timeout = 25,
  chunk_size = 56 * 1024,
  pasteboard = nil, -- tests only: read this named pasteboard instead
}

M.trace = nil -- tests only: function(label, seconds) called after each upload phase

local SHELL = "com.superlogical.terminal.shell"

-- Prints "png", "file\t<path>", or "none". Writes PNG data to argv[0].
local CLIPBOARD_JS = [=[
ObjC.import('AppKit');
function run(argv) {
  const pb = argv[1] ? $.NSPasteboard.pasteboardWithName(argv[1]) : $.NSPasteboard.generalPasteboard;
  // An image copied in Finder is a file URL plus a TIFF of its icon, so check URLs first.
  const opts = $.NSDictionary.dictionaryWithObjectForKey(true, $.NSPasteboardURLReadingFileURLsOnlyKey);
  const urls = pb.readObjectsForClassesOptions($([$.NSURL]), opts);
  if (urls && !urls.isNil() && urls.count > 0) {
    const path = ObjC.unwrap(urls.objectAtIndex(0).path);
    return /\.(png|jpe?g|gif|webp|heic|tiff?|bmp)$/i.test(path) ? 'file\t' + path : 'none';
  }
  let data = pb.dataForType($.NSPasteboardTypePNG);
  if (data.isNil()) {
    const tiff = pb.dataForType($.NSPasteboardTypeTIFF);
    if (tiff.isNil()) return 'none';
    const rep = $.NSBitmapImageRep.imageRepWithData(tiff);
    if (rep.isNil()) return 'none';
    data = rep.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $());
  }
  if (!data.writeToFileAtomically(argv[0], true)) throw new Error('cannot write ' + argv[0]);
  return 'png';
}
]=]

-- Runs on the remote machine as: sh -c SCRIPT rex-image-paste NAME
-- Reads base64 lines from its terminal (canonical mode, echo off) until EOF,
-- then prints the file's checksum and path for the action to read.
local REMOTE_SCRIPT = [=[
umask 077
stty -echo 2>/dev/null
( sleep 120; kill 0 ) 2>/dev/null &
d="${TMPDIR:-/tmp}/rex-image-paste-$(id -u)"
mkdir -p "$d" && [ -O "$d" ] && chmod 700 "$d" || { echo "REXPASTE-ERR cannot use $d"; sleep 60; exit 1; }
find "$d" -type f -mmin +1440 -delete 2>/dev/null
f="$d/$1"
trap 'rm -f "$f.part"' EXIT
if base64 -d > "$f.part" && mv "$f.part" "$f"; then
  sum=$( (sha256sum "$f" 2>/dev/null || shasum -a 256 "$f") | cut -d' ' -f1)
  printf 'REXPASTE-OK %s %s\n' "$sum" "$f"
else
  echo "REXPASTE-ERR could not decode the upload"
fi
sleep 60
]=]

local function fail(message)
  error("image paste: " .. message, 0)
end

local function exec(argv, opts)
  local r, err = rex.exec(argv, opts)
  if r == nil then fail(argv[1] .. ": " .. tostring(err)) end
  if not r.ok then fail(argv[1] .. ": " .. (r.stderr ~= "" and r.stderr or ("exit " .. r.code))) end
  return r.stdout
end

-- must(what, f, ...) calls f(...) and fails with "what: error" if it returns nil.
local function must(what, f, ...)
  local result, err = f(...)
  if result == nil then fail(what .. ": " .. tostring(err)) end
  return result
end

local function sleep(seconds)
  if rex.sleep then return rex.sleep(seconds) end -- scripts
  rex.exec({ "sleep", tostring(seconds) }) -- the configuration file has no rex.sleep
end

local function now()
  local r = rex.exec({ "date", "+%s.%N" })
  return tonumber(r and r.stdout) or os.time()
end

local function unique_name(ext)
  math.randomseed(os.time() + math.floor(os.clock() * 1e6))
  return string.format("%s-%04x.%s", os.date("%Y%m%d-%H%M%S"), math.random(0, 0xffff), ext)
end

-- The action reads the clipboard of the machine its server runs on, so make
-- sure that is the Mac whose key was pressed.
local function check_machine(ctx)
  if M.platform == nil then
    local r = rex.exec({ "uname", "-s" })
    M.platform = r and r.stdout:gsub("%s+$", "") or "unknown"
  end
  if M.platform ~= "Darwin" then
    fail("install this on your Mac's Rex server; this server runs on " .. M.platform)
  end
  if ctx.client_id then
    local info = rex.call("client.inspect", { client_id = ctx.client_id })
    local kind = info and info.client and info.client.principal and info.client.principal.kind
    if kind and kind ~= "peer" then
      fail("the key was pressed on another device, and this server can only read its own clipboard")
    end
  end
  if ctx.server and not rex.server then
    fail("this version of Rex can't reach other servers from an action")
  end
end

-- Returns kind ("png", "file", or "none") and a local path.
local function read_clipboard(png_path)
  local argv = { "osascript", "-l", "JavaScript", "-e", CLIPBOARD_JS, png_path }
  if M.options.pasteboard then argv[#argv + 1] = M.options.pasteboard end
  local out = exec(argv, { timeout = 5 }):gsub("%s+$", "")
  local kind, path = out:match("^(%w+)\t?(.*)$")
  if kind == "png" then return "png", png_path end
  if kind == "file" then return "file", path end
  return "none", nil
end

local function shrink(path)
  local limit = M.options.max_dimension
  if not limit then return end
  local info = exec({ "sips", "-g", "pixelWidth", "-g", "pixelHeight", path })
  local w = tonumber(info:match("pixelWidth: (%d+)")) or 0
  local h = tonumber(info:match("pixelHeight: (%d+)")) or 0
  if math.max(w, h) > limit then exec({ "sips", "-Z", tostring(limit), path }, { timeout = 10 }) end
end

local function block_method(api, session_id, block_id, method, args)
  return api.call("block.method", {
    session_id = session_id, block_id = block_id, method = method, args = args or {},
  })
end

local function paste_text(api, ctx, text)
  must("paste", api.call, "block.event", {
    session_id = ctx.session_id,
    block_id = ctx.block_id,
    event = { type = "paste", payload = { text = text } },
  })
end

-- Copies local_path to the server behind `api` and returns the remote path.
local function upload(api, session_id, local_path, name)
  local started = M.trace and now()
  local function mark(label) if M.trace then M.trace(label, now() - started) end end
  local stop = os.time() + M.options.timeout
  local function check_time(doing)
    if os.time() >= stop then
      fail(string.format("gave up %s after %ds; the image is too large for this connection",
        doing, M.options.timeout))
    end
  end

  local sum = exec({ "shasum", "-a", "256", local_path }):match("^(%x+)")
  local encoded = exec({ "base64", "-b", "76", "-i", local_path })
  local block_id = must("start upload terminal", api.call, "session.new_block", {
    session_id = session_id,
    flavor = SHELL,
    label = "rex-image-paste",
    options = {
      shell = "none",
      command = { "sh", "-c", REMOTE_SCRIPT, "rex-image-paste", name },
      size = { columns = 400, rows = 10 },
    },
  }).block_id
  mark("encoded " .. #encoded .. " bytes, started terminal")

  local ok, result = pcall(function()
    -- Wait for `stty -echo`, so the hidden terminal doesn't draw the upload.
    while true do
      local mode = block_method(api, session_id, block_id, "input_mode")
      if mode and mode.echo == false then break end
      check_time("starting the upload")
      sleep(0.02)
    end
    mark("echo off")

    local size = M.options.chunk_size
    for i = 1, #encoded, size do
      must("upload", block_method, api, session_id, block_id, "write", { data = encoded:sub(i, i + size - 1) })
      check_time(string.format("uploading (%d of %d KiB sent)", math.floor(i / 1024), math.floor(#encoded / 1024)))
    end
    must("upload", block_method, api, session_id, block_id, "write", { data = "\n\004" })
    mark("wrote " .. math.ceil(#encoded / size) .. " chunks")

    while true do
      local screen = block_method(api, session_id, block_id, "format", { trim = true, unwrap = true })
      local text = screen and screen.content or ""
      local got, path = text:match("REXPASTE%-OK (%x+) ([^\r\n]+)")
      if got then
        if got ~= sum then fail("checksum mismatch for " .. path) end
        mark("decoded and verified")
        return path
      end
      local why = text:match("REXPASTE%-ERR ([^\r\n]+)")
      if why then fail(why) end
      check_time("waiting for the remote file")
      sleep(0.05)
    end
  end)

  api.call("block.close", { session_id = session_id, block_id = block_id })
  if not ok then error(result, 0) end
  return result
end

-- The action body. ctx needs session_id and block_id, and server for a pane
-- on another Rex server.
function M.paste(ctx)
  if not ctx.session_id or not ctx.block_id then fail("no focused terminal") end
  check_machine(ctx)
  local api = ctx.server and rex.server(ctx.server) or rex
  exec({ "mkdir", "-p", M.options.local_dir })
  local name = unique_name("png")
  local staged = M.options.local_dir .. "/" .. name
  local kind, path = read_clipboard(staged)

  if kind == "none" then
    local text = exec({ "pbpaste" }, { env = { LANG = "en_US.UTF-8", LC_ALL = "en_US.UTF-8" } })
    if text ~= "" then paste_text(api, ctx, text) end
    return { pasted = "text" }
  end

  if kind == "file" then
    -- Stage a copy with a predictable name and no spaces.
    name = name:gsub("png$", (path:match("%.(%w+)$") or "png"):lower())
    staged = M.options.local_dir .. "/" .. name
    exec({ "cp", path, staged })
  end
  if not name:match("%.gif$") and not name:match("%.webp$") then shrink(staged) end

  local target = staged
  if ctx.server then
    local ok, remote = pcall(upload, api, ctx.session_id, staged, name)
    os.remove(staged)
    if not ok then error(remote, 0) end
    target = remote
  end
  paste_text(api, ctx, target)
  return { pasted = "image", path = target, server = ctx.server }
end

function M.setup(opts)
  local known = { pasteboard = true }
  for k in pairs(M.options) do known[k] = true end
  for k, v in pairs(opts or {}) do
    if known[k] then
      M.options[k] = v
    else
      rex.log("warn", "rex-image-paste: ignoring unknown option " .. tostring(k))
    end
  end
  rex.action{
    name = "image_paste",
    title = "Paste (Images as File Paths)",
    description = "Paste the clipboard. An image is copied to the pane's machine, and its path is pasted.",
    category = "Clipboard",
    keywords = "clipboard screenshot image upload agent",
    run = function(ctx) return M.paste(ctx) end,
  }
  return M
end

return M
