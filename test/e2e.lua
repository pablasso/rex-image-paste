-- End-to-end test. Run from a Rex terminal on the Mac:
--
--   rex do test/e2e.lua                 # a pane on this server
--   rex do test/e2e.lua host=LABEL      # a pane on another Rex server
--   rex do test/e2e.lua host=LABEL kind=tiff src=/path/to/image.png
--
-- kind is png, tiff, or file: how the image is put on the clipboard. kind=text
-- puts text there instead, and checks that nothing is pasted. The test uses a
-- private pasteboard, so it never changes your clipboard, and pastes into a
-- hidden terminal that it closes afterward.

local root = debug.getinfo(1, "S").source:match("^@?(.*)/test/[^/]+$") or "."
local M = dofile(root .. "/init.lua")

local SEED_JS = [=[
ObjC.import('AppKit');
function run(argv) {
  const [name, kind, path] = argv;
  const pb = $.NSPasteboard.pasteboardWithName(name);
  pb.clearContents;
  if (kind === 'png') pb.setDataForType($.NSData.dataWithContentsOfFile(path), $.NSPasteboardTypePNG);
  else if (kind === 'tiff') pb.setDataForType($.NSImage.alloc.initWithContentsOfFile(path).TIFFRepresentation, $.NSPasteboardTypeTIFF);
  else if (kind === 'file') pb.writeObjects($([$.NSURL.fileURLWithPath(path)]));
  else if (kind === 'text') pb.setStringForType(path, $.NSPasteboardTypeString);
  else throw new Error('kind must be png, tiff, file, or text');
  return 'ok';
}
]=]

local host = rex.args.host
local kind = rex.args.kind or "png"
local src = rex.args.src
local failed = false

if kind == "text" then
  src = "echo one\necho two"
elseif not src then
  -- Every Mac has this icon; convert it to a PNG to paste.
  src = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "") .. "/rex-image-paste-test.png"
  rex.exec({ "sips", "-s", "format", "png",
    "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericDocumentIcon.icns",
    "--out", src })
end

local function check(cond, message)
  if not cond then
    rex.log("error", "FAIL: " .. message)
    failed = true
  end
  return cond
end

M.options.pasteboard = "rex-image-paste-test"
M.trace = function(label, seconds) rex.log(string.format("  %6.2fs %s", seconds, label)) end

local seeded = rex.exec({ "osascript", "-l", "JavaScript", "-e", SEED_JS, M.options.pasteboard, kind, src })
if not (seeded and seeded.ok) then
  rex.log("error", "could not seed the test pasteboard: " .. (seeded and seeded.stderr or "?"))
  rex.stop(1)
end

local api, session_id = rex, rex.session_id
if host then
  api = rex.server(host)
  local sessions = assert(api.call("session.list", {})).sessions
  session_id = assert(sessions[1], "no sessions on " .. host).session_id
  assert(api.call("session.attach", { session_id = session_id }))
end

-- A hidden terminal that turns on bracketed paste and echoes what it receives.
local target = assert(api.call("session.new_block", {
  session_id = session_id,
  flavor = "com.superlogical.terminal.shell",
  label = "rex-image-paste-test",
  options = { shell = "none", command = { "sh", "-c", [[printf '\033[?2004h'; cat]] } },
})).block_id
rex.sleep(0.5)

local function paste_and_check(label)
  local ok, result = pcall(M.paste, { server = host, session_id = session_id, block_id = target })
  if not check(ok, label .. ': ' .. tostring(result)) then return nil end
  check(result.pasted == "image", label .. ": pasted " .. tostring(result.pasted) .. ", not an image")
  rex.sleep(0.3)
  local screen = api.call("block.method", {
    session_id = session_id, block_id = target, method = "format", args = { trim = true, unwrap = true },
  })
  local shown = screen and screen.content or ""
  check(shown:find("^[[200~" .. result.path .. "^[[201~", 1, true),
    label .. ": the pane didn't receive a bracketed paste of " .. tostring(result.path) .. "; it shows: " .. shown)
  rex.log(string.format("%s: pasted %s%s%s", label, result.path, host and (" on " .. host) or "",
    result.cached and " (already there)" or ""))
  return result
end

local first = kind ~= "text" and paste_and_check("first paste")
local again = first and paste_and_check("same image again")
if again then
  check(again.cached, "the same image was copied again")
  check(again.path == first.path, "the same image got another path: " .. tostring(again.path))
end

if kind == "text" then
  local ok, result = pcall(M.paste, { server = host, session_id = session_id, block_id = target })
  if check(ok, "text: " .. tostring(result)) then
    check(result.pasted == "nothing", "text: pasted " .. tostring(result.pasted) .. ", not nothing")
    rex.sleep(0.3)
    local screen = api.call("block.method", {
      session_id = session_id, block_id = target, method = "format", args = { trim = true },
    })
    local shown = screen and screen.content or ""
    check(not shown:find("echo", 1, true), "text: the pane received the text: " .. shown)
    rex.log("text: pasted nothing" .. (host and (" on " .. host) or ""))
  end
end

-- Remove the test images.
for _, result in ipairs({ first or false, again or false }) do
  if result and host then
    api.call("session.new_block", {
      session_id = session_id,
      flavor = "com.superlogical.terminal.shell",
      options = { shell = "none", command = { "rm", "-f", result.path } },
    })
  elseif result then
    os.remove(result.path)
  end
end

api.call("block.close", { session_id = session_id, block_id = target })
rex.log(failed and "e2e: FAILED" or "e2e: passed")
rex.stop(failed and 1 or 0)
