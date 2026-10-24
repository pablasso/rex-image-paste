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

-- Saves the clipboard's image as it is, to argv[0] plus ".png" or ".tiff".
-- Prints "png", "tiff", "file\t<path>" for an image file, or "none".
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
  for (const [type, kind] of [[$.NSPasteboardTypePNG, 'png'], [$.NSPasteboardTypeTIFF, 'tiff']]) {
    const data = pb.dataForType(type);
    if (data.isNil()) continue;
    if (!data.writeToFileAtomically(argv[0] + '.' + kind, true)) throw new Error('cannot write ' + argv[0]);
    return kind;
  }
  return 'none';
}
]=]

-- Runs on the remote machine as: sh -c SCRIPT rex-image-paste NAME
-- If the directory already has NAME, it reports a hit. Otherwise it reads
-- base64 lines from its terminal (canonical mode, echo off) until EOF, then
-- prints the file's checksum and path for the action.
local REMOTE_SCRIPT = [=[
umask 077
d="${TMPDIR:-/tmp}/rex-image-paste-$(id -u)"
mkdir -p "$d" && [ -O "$d" ] && chmod 700 "$d" || { echo "REXPASTE-ERR cannot use $d"; sleep 60; exit 1; }
find "$d" -type f -mmin +1440 -delete 2>/dev/null
f="$d/$1"
if [ -s "$f" ]; then
  touch "$f"
  printf 'REXPASTE-HIT %s\n' "$f"
  sleep 60
  exit 0
fi
stty -echo 2>/dev/null
( sleep 120; kill 0 ) 2>/dev/null &
t="$f.part.$$"
trap 'rm -f "$t"' EXIT
if base64 -d > "$t" && mv "$t" "$f"; then
  printf 'REXPASTE-OK %s %s\n' "$( (sha256sum "$f" 2>/dev/null || shasum -a 256 "$f") | cut -d' ' -f1)" "$f"
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

local function temp_name()
  math.randomseed(os.time() + math.floor(os.clock() * 1e6))
  return string.format("incoming-%s-%04x", os.date("%Y%m%d-%H%M%S"), math.random(0, 0xffff))
end

local function exists(path)
  local f = io.open(path)
  if f then f:close() end
  return f ~= nil
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

-- Saves the clipboard's image under base and returns the saved file and its
-- extension, or nil when the clipboard has no image.
local function read_clipboard(base)
  local argv = { "osascript", "-l", "JavaScript", "-e", CLIPBOARD_JS, base }
  if M.options.pasteboard then argv[#argv + 1] = M.options.pasteboard end
  local out = exec(argv, { timeout = 5 }):gsub("%s+$", "")
  local kind, path = out:match("^(%w+)\t?(.*)$")
  if kind == "png" or kind == "tiff" then return base .. "." .. kind, kind end
  if kind ~= "file" then return nil end
  local ext = (path:match("%.(%w+)$") or ""):lower()
  exec({ "cp", path, base .. "." .. ext })
  return base .. "." .. ext, ext
end

-- Agents read PNG, JPEG, GIF, and WebP. Other formats are converted to PNG.
local KEEP_FORMAT = { png = true, jpg = true, jpeg = true, gif = true, webp = true }

local function output_ext(ext)
  return KEEP_FORMAT[ext] and ext or "png"
end

-- Returns src ready to paste: converted to a format agents read, and shrunk.
-- sips output isn't byte-for-byte repeatable, so images are named before this.
local function prepare_image(src, base, ext)
  local argv = { "sips" }
  if output_ext(ext) ~= ext then
    for _, a in ipairs({ "-s", "format", "png" }) do argv[#argv + 1] = a end
  end
  local limit = M.options.max_dimension
  if limit and ext ~= "gif" and ext ~= "webp" then
    local info = exec({ "sips", "-g", "pixelWidth", "-g", "pixelHeight", src })
    local w = tonumber(info:match("pixelWidth: (%d+)")) or 0
    local h = tonumber(info:match("pixelHeight: (%d+)")) or 0
    if math.max(w, h) > limit then
      argv[#argv + 1] = "-Z"
      argv[#argv + 1] = tostring(limit)
    end
  end
  if #argv == 1 then return src end
  local out = base .. "-ready." .. output_ext(ext)
  for _, a in ipairs({ src, "--out", out }) do argv[#argv + 1] = a end
  exec(argv, { timeout = 10 })
  return out
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

local function sha256(path)
  return exec({ "shasum", "-a", "256", path }):match("^(%x+)")
end

-- Copies a file to the server behind `api` as name, unless the server already
-- has name. prepare() returns the file to send and its SHA-256; it runs only
-- when the file is needed. Returns the remote path and whether it was there.
local function upload(api, session_id, name, prepare)
  local started = M.trace and now()
  local function mark(label) if M.trace then M.trace(label, now() - started) end end
  local stop = os.time() + M.options.timeout
  local function check_time(doing)
    if os.time() >= stop then
      fail(string.format("gave up %s after %ds; the image is too large for this connection",
        doing, M.options.timeout))
    end
  end

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
  mark("started terminal")

  local function screen_text()
    local screen = block_method(api, session_id, block_id, "format", { trim = true, unwrap = true })
    local text = screen and screen.content or ""
    local why = text:match("REXPASTE%-ERR ([^\r\n]+)")
    if why then fail(why) end
    return text
  end

  local ok, result, cached = pcall(function()
    -- The remote either reports a copy it already has, or turns off echo
    -- (so the hidden terminal doesn't draw the upload) and waits for one.
    while true do
      local mode = block_method(api, session_id, block_id, "input_mode")
      if mode and mode.echo == false then break end
      local path = screen_text():match("REXPASTE%-HIT ([^\r\n]+)")
      if path then
        mark("already there")
        return path, true
      end
      check_time("starting the upload")
      sleep(0.02)
    end
    mark("echo off")

    local local_path, sum = prepare()
    local encoded = exec({ "base64", "-b", "76", "-i", local_path })
    local size = M.options.chunk_size
    for i = 1, #encoded, size do
      must("upload", block_method, api, session_id, block_id, "write", { data = encoded:sub(i, i + size - 1) })
      check_time(string.format("uploading (%d of %d KiB sent)", math.floor(i / 1024), math.floor(#encoded / 1024)))
    end
    must("upload", block_method, api, session_id, block_id, "write", { data = "\n\004" })
    mark("wrote " .. #encoded .. " bytes in " .. math.ceil(#encoded / size) .. " chunks")

    while true do
      local got, path = screen_text():match("REXPASTE%-OK (%x+) ([^\r\n]+)")
      if got then
        if got ~= sum then fail("checksum mismatch for " .. path) end
        mark("decoded and verified")
        return path, false
      end
      check_time("waiting for the remote file")
      sleep(0.05)
    end
  end)

  api.call("block.close", { session_id = session_id, block_id = block_id })
  if not ok then error(result, 0) end
  return result, cached
end

-- The action body. ctx needs session_id and block_id, and server for a pane
-- on another Rex server.
function M.paste(ctx)
  if not ctx.session_id or not ctx.block_id then fail("no focused terminal") end
  check_machine(ctx)
  local api = ctx.server and rex.server(ctx.server) or rex
  exec({ "mkdir", "-p", M.options.local_dir })
  local base = M.options.local_dir .. "/" .. temp_name()
  local src, ext = read_clipboard(base)

  if not src then
    local text = exec({ "pbpaste" }, { env = { LANG = "en_US.UTF-8", LC_ALL = "en_US.UTF-8" } })
    if text ~= "" then paste_text(api, ctx, text) end
    return { pasted = "text" }
  end

  -- Name the image after the clipboard's bytes, so pasting it again reuses
  -- the copy, and convert and shrink it only when a copy is needed.
  local name = sha256(src):sub(1, 16) .. "." .. output_ext(ext)
  local ready
  local function prepare()
    ready = prepare_image(src, base, ext)
    return ready, sha256(ready)
  end
  local function clean_up()
    os.remove(src)
    if ready and ready ~= src then os.remove(ready) end
  end

  local target, cached
  if ctx.server then
    local ok, remote, hit = pcall(upload, api, ctx.session_id, name, prepare)
    clean_up()
    if not ok then error(remote, 0) end
    target, cached = remote, hit
  else
    target = M.options.local_dir .. "/" .. name
    cached = exists(target)
    if not cached then
      prepare()
      os.rename(ready, target)
    end
    clean_up()
  end
  paste_text(api, ctx, target)
  return { pasted = "image", path = target, server = ctx.server, cached = cached }
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
