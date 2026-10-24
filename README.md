# rex-image-paste

Paste images into [Rex](https://www.superlogical.com/rex) panes on remote servers, for sharing screenshots with coding agents.

## Overview

With an image on the clipboard, press <kbd>Cmd</kbd>+<kbd>Shift</kbd>+<kbd>V</kbd> and the image's file path is pasted into the focused pane. If the pane runs on another Rex server, the image is first copied to that machine, so the path works there. Agents such as Claude Code attach pasted image paths. With text on the clipboard, the key pastes the text.

## How it works

- A custom Rex action in your Mac's Rex configuration reads the clipboard: a screenshot, an image copied from an app, or an image file copied in Finder. Images whose long edge is over 2000 pixels are shrunk, and formats agents can't read, such as HEIC, are converted to PNG.
- For a pane on another server, the action opens a hidden terminal there that runs `base64 -d`, types the encoded image into it over Rex's own connection, and checks the result's SHA-256. The remote needs no SSH or setup, only `sh` and `base64`.
- The action then pastes the path, such as `/tmp/rex-image-paste-1000/0e24b34aaa3434f1.png`, as a bracketed paste. Each image is named after a hash of its contents, so pasting the same image again reuses the copy without uploading it. Images older than a day are deleted on the next paste.

Uploads use requests of at most 64 KiB, so their speed depends on the latency to the server. A paste gives up after 25 seconds.

## Install

On the Mac where you run Rex, clone the repository into Rex's configuration directory:

```sh
git clone https://github.com/pablasso/rex-image-paste ~/.config/rex/rex-image-paste
```

Add these lines to `~/.config/rex/init.lua`:

```lua
require("rex-image-paste").setup()
rex.bind("cmd+shift+v", "image_paste")
```

Then reload the configuration:

```sh
rex config reload
```

Rex loads modules from beside the `init.lua` path it opens, so if `init.lua` is a symlink, clone next to the link. To keep full-size images, use `setup{ max_dimension = false }`.

## Upgrade

```sh
git -C ~/.config/rex/rex-image-paste pull
rex config reload
```
