# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

@AGENTS.md

## What this is

MyCode is a native code editor in Zig, drawn on the GPU by [myzig](https://github.com/hunghg255/myzig) (no webview),
taken from a checkout beside this one (`../myzig`, with its `terminal`, `watch` and `mainthread` plugins). It was
first written in Go on MyGo, forked from Mayoi, and ported to Zig; some names still say `mayoi` (`MAYOI_DATA_DIR`)
or mention the Go app, whose behavior the port follows.

## Commands

```sh
zig build                                    # zig-out/bin/mycode.exe (Zig 0.17)
zig build run -- <folder-or-file>            # run the app
zig build test                               # unit tests
zig build uitest                             # UI tests: the app run headless with scripts (uitest/main.zig)
zig build uitest -- NAME                     # the UI tests whose names hold NAME
../myzig/cli/zig-out/bin/myzig build --optimize safe   # dist/windows-x86_64: the app, a zip and the installer
MAYOI_DATA_DIR=<dir> zig-out/bin/mycode.exe <folder> --myzig-dark --myzig-snapshot=shot.png \
    --myzig-script="frames:3;click:a.txt;shortcut:ctrl+p;type:x;key:enter;live:1"   # one headless run
```

Script steps (myzig's `ui.Tester.runScript`): `click:TEXT`, `move:TEXT` (fails when the text isn't shown),
`drag:x,y>x,y` (points; the same point twice is a click), `type:`, `key:enter|backspace|escape|f2…`,
`shortcut:ctrl+shift+p`, `frames:N`, `wait:S`, `live:S` (the real event loop, for Git and search results). The
snapshot is 1280x820 points at 2x. Text drawn by the code editor isn't found by `move:`.

Scripts under `scripts/` are bash (Git Bash on Windows).

## Architecture

`docs/ARCHITECTURE.md` is a tour of the source by area; read the relevant section before changing a subsystem. The
big picture:

- **`src/main.zig`** holds `Main` (the app: settings, state, keymap, menus, windows); **`shell.zig`** a `Shell`, one
  window, with its project tabs; **`workbench.zig`** a `Workbench`, one project, split into `wb_*.zig` files.
- **Commands** are named once in `commands.zig` and run through `wb_run.run`: menus (`menubar.zig`), the palette,
  `keybindings.json` (`keymap.zig`, VS Code format) and keys all go through them.
- **Documents vs editors.** A `Doc` (`doc.zig`) is a file's text, history and Git marks; a tab in a column
  (`columns.zig`) shows it, and several tabs may share one `Doc`.
- **Background work** runs on threads (`jobs.zig`) and posts back to the main thread; Git runs through its command
  line (`git.zig`), never a library. Hunk staging builds the index blob itself (`hunks.zig`).
- **Settings and state** (`settings.zig`, `state.zig`) live in `%APPDATA%\MyCode` or `MAYOI_DATA_DIR`:
  `settings.json`, `keybindings.json`, `state-zig.json`; external edits apply live.
- Windows-only code (`winshell.zig`: the `mycode` command and Explorer menu) checks the OS.

### myzig in practice

- Views are immediate mode, rebuilt every frame, and **laid out and painted after the view returns**: `ui.text`
  (and canvases, rich text, tooltips) keep the slices they are given until then; nothing is copied. So:
  - Never pass a stack buffer; format with `c.print`, or copy with `c.alloc()`.
  - **Never free or replace, in the middle of a frame, memory a text of that frame points at**: a path, a name, a
    Git change, a symbol, a document. Whatever the frame drew before (the title bar, the tab strip, another
    column, a breadcrumb) is laid out afterwards and reads it freed: a crash in `layout_cache` (`same`, `hold`)
    or a text measure is this. Release builds' allocator never reuses memory, so it faults at once there.
  - Defer instead: free as the next frame starts (`Shell.closeProjectNow`, `Editors.discard`), keep the old value
    one update longer (`Doc.old_path`, `Doc.old_syms`), or apply what a thread read between frames (`jobs.spawn`'s
    `done` runs on the main thread, never inside a frame).
  - State shared by every column or project must not be rebuilt by each in turn within a frame: give each its own
    (each `Doc` keeps its symbols).
- Ids are positional: a box added conditionally before an interactive one (or a scroll box) changes its id, which
  loses its clicks, its focus and its scroll. Wrap what comes and goes in a box that is always there (the sticky
  lines' box), or use `c.keyed`. Take `c.peekId` right before the text field it names. An editor whose id flips
  every frame scrolls back and forth.
- A box takes its content's width unless told otherwise: give a box beside fixed ones `.w(0).grow()` and `.clip()`
  long text, or a long line pushes its neighbours (the minimap, the status bar) out of the window.
- `c.scroll_max` is kept only for boxes that follow their end; a box's scroll length is `c.scroll_limit` (the last
  layout's).
- Crash logs: Windows builds keep their debug information, so with `mycode.pdb` beside `MyCode.exe` (copy it from
  `.myzig/build/windows-x86_64/x86_64/bin/`), `%APPDATA%\MyCode\crash-zig.log` has the stack.
- Text is selectable unless its box has `.control()`.
- Keep files short and changes to myzig itself out of this repository; myzig is its own project.

### Tests

Unit tests are `test` blocks pulled in by the `test` block at the end of `main.zig`. UI tests (`uitest/main.zig`)
make their folders in `%TEMP%\mycode-uitest`, run the app headless and check its screen and what it wrote; headless
runs leave the registry alone. Add a UI test for a fixed bug that a script can reach.

## Docs and changelog

- `CHANGELOG.md`'s `## Unreleased` section becomes the release notes and the in-app update window;
  `scripts/bump.sh` renames it, sets the version in `build.zig.zon`, tags and publishes the installer.
- User-facing features are also described in `docs/FEATURES.md`, settings in `docs/SETTINGS.md`.
- Match the existing prose style of these files: plain, concrete sentences describing what the user sees, with UI
  names in bold.
