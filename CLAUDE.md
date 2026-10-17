# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

@AGENTS.md

## What this is

MyCode is a native code editor in Go, drawn on the GPU by [MyGo](https://github.com/egoist/mygo) (no webview). It was
forked from Mayoi and renamed, so the Go module, the main package's folder and some identifiers still say `mayoi`
(`module mayoi`, `cmd/mayoi`, `MAYOI_DATA_DIR`) while the product is MyCode. `go.mod` replaces `github.com/egoist/mygo`
with the `hunghg255/mygo` fork, which ships ConPTY for Windows terminals.

## Commands

```sh
go run ./cmd/mayoi <folder-or-file>          # run the app
scripts/dev.sh                               # live reload (go tool mygo dev), with its own settings folder
go tool mygo build                           # package the app into build/ (mygo.json holds name, id, version)
go test ./...                                # all tests, including headless UI tests
go test -short ./...                         # skip the tests that start a shell
go test -run TestName ./cmd/mayoi            # one test
go test -short -run XXX -bench Frame ./cmd/mayoi   # benchmark an editor frame
FSHOTS=<dir> go test -run TestFeatColumns ./cmd/mayoi   # one feature's screenshots
```

Scripts under `scripts/` are bash (use Git Bash on Windows); `scripts/dev.sh` and the screenshot script assume macOS.

## Architecture

`docs/ARCHITECTURE.md` is a detailed tour of the source by area, with performance figures; read the relevant section
before changing a subsystem. The big picture:

- **`cmd/mayoi`** is one large `main` package holding the whole UI. A `frame` is a native window and a `desktop` a
  project in it with its own `app` (`projects.go`); with project tabs, one window holds several projects and only the
  one shown is built. Menus, accelerators, keybindings and tests all go through the same commands (`commands.go`).
- **Documents vs editors.** A document (`document.go`) is a file's text, undo history and Git marks; an editor is one
  tab's view of it with its own selection and scroll. Undo (`history.go`), editing commands (`editing.go`) and
  decorations belong to the app, not MyGo's text area, so every column showing a file shares text and history.
  Editing commands run on the next frame, once the selection is known.
- **`view.go`** lays out sidebar, columns and panel with stable keys so editors keep their state as panes change.
- **Background work posts back to the main thread.** Highlighting (`internal/highlight`), line diffs
  (`internal/gitmarks`, `internal/linediff`), search, Git status and image decoding run off the main thread; results
  are tagged so stale ones are dropped. Only lines/rows in view are painted or decorated.
- **`internal/git`** shells out to the `git` CLI (never a library), with prompts disabled. Hunk staging builds the
  index blob itself (`git hash-object` + `git update-index`) rather than applying patches (`hunks.go`, `diffhunks.go`).
- **`internal/vfs`** wraps file system and process calls (`Command`); use it rather than `os`/`exec` directly.
- **`internal/settings`, `internal/keymap`** read and watch `settings.json`, `state.json` and `keybindings.json`
  (VS Code format); external edits are applied live on the main thread.
- Platform code is split by file suffix (`_windows.go`, `_other.go`, `_unix_test.go`).

### Tests

UI tests drive a real `app` headlessly with a `fakeHost` (`cmd/mayoi/app_test.go`) standing in for native dialogs,
clipboard and windows. Tests that start a shell check `testing.Short()`. `*_shot_test.go` files render screenshots.

## Docs and changelog

- `CHANGELOG.md`'s `## Unreleased` section becomes the release notes and the in-app update window; a release build
  fails without a `## <version>` section. `scripts/bump.sh` renames it and tags.
- User-facing features are also described in `docs/FEATURES.md`, settings in `docs/SETTINGS.md`.
- Match the existing prose style of these files: plain, concrete sentences describing what the user sees, with UI
  names in bold.
