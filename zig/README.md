# MyCode in Zig

MyCode written again in Zig on [myzig](../../myzig), next to the Go app. It reads the same `settings.json` and
`keybindings.json` (in `%AppData%\MyCode`, or `MAYOI_DATA_DIR`) and keeps its windows and tabs in `state-zig.json`
beside them, so the two apps don't overwrite each other's state.

## Build

It needs Zig 0.17 and a checkout of myzig two folders up (`../../myzig`), with its `terminal`, `watch` and
`mainthread` plugins.

```sh
zig build                       # zig-out/bin/mycode.exe
zig build test                  # unit tests
zig build -Doptimize=ReleaseSafe -Dwindows-gui=true   # zig-out/bin/mycode.exe, as the installer has it
zig-out/bin/mycode.exe <folder> --myzig-snapshot=shot.png --myzig-script="click:README.md"   # headless
```

The terminal downloads libghostty-vt and ConPTY into the user's cache the first time it opens, unless they are
beside the executable: `resources/` holds them for the installer (`ghostty-vt.dll`, `conpty.dll`,
`OpenConsole.exe`, from `%LOCALAPPDATA%\mygo\natives`; they are not in Git).

The Go app's icons (Lucide's, in `cmd/mayoi/icons.go`) are written to `src/lucide.zig` by `python icons/lucide.py`;
the file icons (Material's) to `icons/material.zig` by `python icons/update.py`.

## The installer

The myzig CLI (`cd ../../myzig/cli && zig build -Doptimize=ReleaseSmall`) packages the app with its icon, version and
manifest, and writes an NSIS script; with [NSIS](https://nsis.sourceforge.io) installed it makes the installer:

```sh
../../myzig/cli/zig-out/bin/myzig build --optimize safe
makensis .myzig/build/windows-x86_64/installer.nsi   # when the CLI didn't find makensis
```

`dist/windows-x86_64/` then holds `MyCode/`, a `.zip` and `MyCode Setup <version> x86_64.exe`, which installs for the
user into `%LOCALAPPDATA%\Programs\MyCode`, with a Start menu shortcut and an uninstaller.

A crash of a release started from Explorer writes what happened to `crash-zig.log` in the data folder; the last ten
move to `crashes/`.

## What it has

- **Explorer**: the file tree with Git's marks, ignored files faint, `filesExclude`; new file and folder, rename,
  delete to the Recycle Bin, copy path, reveal, open in terminal.
- **Editor**: tabs in columns (split, drag tabs, lock a column), a preview tab, auto save, reopen closed tabs, word
  wrap, minimap, sticky scroll, breadcrumbs, the other occurrences of the word at the caret, Git's changes in the
  gutter, inline blame in the status bar, line commands, sort and case, indentation and line endings, and the
  colors of some seventy languages, markup, Markdown and diffs; the find widget over the editor.
- **Quick open** (Ctrl+P): files, `>` commands, `@` symbols, `:` a line. **Open Recent** (Ctrl+R).
- **Search** (Ctrl+Shift+F): in the background, with case, whole word, regular expressions, files to include and
  exclude, and replace.
- **Source control**: groups, stage, unstage and discard, commit, amend, undo, fetch, pull, push, sync, force push,
  branches (switch, create, rename, delete), stash, the commits graph, a commit's changes, the **Changes** tab with
  hunk staging, merge conflicts, review comments sent to the terminal, worktrees (a branch checked out in another
  opens it, or is pruned when its folder is gone) and submodules; Git work that rewrites the work tree waits for
  the files to be saved.
- **Terminals** in the panel or in columns, with profiles (PowerShell, Command Prompt, Git Bash, WSL, your own).
- **Pictures** (PNG, JPEG, GIF, BMP, WebP) on a checkerboard, zoomed and panned; Markdown (with its local
  pictures) and SVG previews.
- **Menus** laid out as the Go app's, with checks, its commands and keybindings.json's accelerators.
- **Project tabs**, one instance (later launches hand their folders over), the `mycode` command and Explorer menu
  on Windows, the MyCode, Matrix, Claude and Qoder themes, settings and keybindings applied as they are saved.

## Not yet

- Updates download the whole installer and run it, without checking it against a signing key: myzig's updater
  plugin does, once releases carry its signed manifests (`myzig keygen`, `MYZIG_UPDATER_PRIVATE_KEY`).
- Sessions are kept in `state-zig.json`, apart from the Go app's `state.json`, whose shape differs.
- Review comments show on cards under the editor, not between its lines as the Go app has them: myzig's text area
  leaves no room between lines yet. In a diff they are rows between its lines, as there.
