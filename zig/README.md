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
zig build -Doptimize=ReleaseFast -Dstrip=true -Dwindows-gui=true --prefix dist   # dist/bin/mycode.exe
zig-out/bin/mycode.exe <folder> --myzig-snapshot=shot.png --myzig-script="click:README.md"   # headless
```

The terminal downloads libghostty-vt and ConPTY into the user's cache the first time it opens.

## What it has

- **Explorer**: the file tree with Git's marks, ignored files faint, `filesExclude`; new file and folder, rename,
  delete to the Recycle Bin, copy path, reveal, open in terminal.
- **Editor**: tabs in columns (split, drag tabs, lock a column), a preview tab, auto save, reopen closed tabs, word
  wrap, minimap, sticky scroll, breadcrumbs, the other occurrences of the word at the caret, Git's changes in the
  gutter, inline blame in the status bar, line commands, sort and case, indentation and line endings.
- **Quick open** (Ctrl+P): files, `>` commands, `@` symbols, `:` a line. **Open Recent** (Ctrl+R).
- **Search** (Ctrl+Shift+F): in the background, with case, whole word, regular expressions, files to include and
  exclude, and replace.
- **Source control**: groups, stage, unstage and discard, commit, amend, undo, fetch, pull, push, sync, force push,
  branches (switch, create, rename, delete), stash, the commits graph, a commit's changes, the **Changes** tab with
  hunk staging, merge conflicts, review comments sent to the terminal.
- **Terminals** in the panel or in columns, with profiles (PowerShell, Command Prompt, Git Bash, WSL, your own).
- **Pictures** (PNG on Windows), Markdown and SVG previews.
- **Project tabs**, one instance (later launches hand their folders over), the `mycode` command and Explorer menu
  on Windows, the MyCode, Matrix, Claude and Qoder themes, settings and keybindings applied as they are saved.

## Not yet

- JPEG, GIF, WebP and BMP pictures: myzig decodes PNG off macOS.
- Syntax colors for languages myzig's highlighter doesn't know (HTML, Markdown's own).
- The Matrix's digital rain, indent guides, the Material and Lucide icon themes, review comments made in a diff,
  pasting files in the Explorer, the update window (Check for Updates opens the releases page).
