# Architecture

MyCode is a single Zig module, `src/`, with `src/main.zig` as its entry, drawn on the GPU by
[myzig](https://github.com/hunghg255/myzig), which `build.zig.zon` takes from a checkout beside this one (`../myzig`).
myzig's terminal plugin runs the terminals with Ghostty's emulator (ConPTY on Windows), its watch plugin follows the
folder on disk, and its mainthread plugin carries the results of background threads back to the main thread. Git runs
through its command line. This page walks through the source by area.

## Building

`build.zig` makes the `mycode` executable from `src/main.zig`, with myzig and its `terminal`, `watch` and `mainthread`
plugins as imports. It adds the Material icons (`icons/material.zig`), the version from `build.zig.zon` as
`build_options.version` (for updates) and `resources/icon.png` for the welcome page. `zig build run` starts the app,
`zig build test` runs the unit tests and `zig build uitest` the UI tests. `myzig.zon` is for the myzig CLI: `myzig build`
packages the app with its icon and the NSIS installer, whose uninstaller runs `mycode --uninstall-shell` and offers to
delete the settings.

The terminal's native libraries (libghostty-vt, and on Windows `conpty.dll` with `OpenConsole.exe`) are found next to the
executable, where `resources/` puts them for the installer (they are not committed), or else in the user's cache, where
`panel.zig`'s `Host.prepare` downloads them once on a thread of its own.

## myzig in brief

A contributor needs a few of myzig's rules in mind.

- **Views are immediate mode.** A window's view function builds the whole frame again each time it is drawn. There are no
  widget objects: `ui.button` returns whether it was clicked, and the app's own structs hold the state. A frame is drawn
  on input, on a resize, while an animation runs, or when asked (`Window.redraw`, `c.frameIn`), so an idle window costs
  nothing. Code that changes state during the frame sets `c.changed`, and the frame is built again before it is drawn.
- **The frame is laid out after the view returns.** Widgets answer from the last frame's layout: a press is matched to
  the box that was under the pointer then.
- **Ids are positional.** A box's id comes from its parent and its place among its siblings, and text areas, scroll
  positions and carets are kept by id. A box that comes and goes conditionally shifts the ids of every box after it, so
  a press can land on nothing. Key a box that moves with `c.keyed(ptr)` (a pointer keys the object it points to), as
  `Shell.view` keys each project, the rail its squares, and `wb_editor.zig` each tab's body.
- **Strings must outlive the frame.** `ui.text` and the other widgets keep the slices they are given until the frame is
  laid out and drawn, after the view returns. Pass the app's own memory, constants, or the frame's arena:
  `c.print("{d} files", .{n})` formats into it and `c.alloc()` hands it out. Never pass a buffer on the view's stack.
  The same rule is why closed projects are freed only as the next frame starts (below).

## Windows and projects

**`main.zig`.** `Main` holds what the app shares: the settings (`settings.Store`), the state (`state.State`), the keymap,
the terminal profiles, the menu bar and the windows (`shells`). `main` takes the single-instance lock, so a later
`mycode` hands its folders and files to the running one (`Main.second`, then `openArgs`): a folder goes to the window
that has it or opens as a project, and a file opens in the project whose folder holds it. Headless runs (any
`--myzig-` flag) skip the lock and leave the registry alone. Without folders on the command line, the projects open
when MyCode quit come back, else the working directory. `newWindow` makes a window whose title bar the app draws
(`.title_bar = .hidden`), each keeping its place under its own state key. `quit` and `closeShell` save the state;
`regroup` gathers every window's projects into the one in front when **Project Tabs** is turned on, and parts them into
a window each when it is turned off.

**`shell.zig`.** A `Shell` is a window: its projects, the rail of them on its left while project tabs are on, the title
bar, the theme, and the window's own commands (`Shell.run`: open folder or file, settings, zoom, themes, icons,
appearance, the command line, updates, quit). Only the project shown is built; the others keep running out of sight,
and a terminal of theirs that rings marks their square. `addProject` restores a folder's session or takes the layout of
the project shown. Open dialogs run after the frame (`askLater`, posted through the mainthread queue), because a dialog
runs its own loop, which would deliver background results into a half-built frame. Files dropped on the window go to
the terminal under the pointer, into the Explorer's folder under it, or to the column they land on (`onDrop`).

Closing a project never frees it at once. `closeProjectNow` adds it to `dropping`, and `Shell.view` calls `dropClosed`
as the next frame starts: the frame that closed it may be the project's own (its command or menu), and that frame is
laid out after its view from the project's strings. The last project gone, the window stays with **No Folder Open**
(`noFolder`), whose commands are queued in `pending` and run by the shell itself.

**`workbench.zig`.** A `Workbench` is a project: one folder's sidebar (Explorer, Search, Source Control), its editor
columns (`Editors`), its terminal panel, its status bar, quick open, the prompt and confirmation boxes, the branch
picker, the review comments, the Git runner and the folder's watcher. Its `view` runs the queued commands, reads the
disk again when `refresh_next` is set (the project shown again, the window focused), then builds the sidebar, the
columns and panel, and the status bar, and lastly the drags and boxes over the window. `session` and `restore` turn its
columns, tabs, carets, layout and open folders into a `state.Session` and back. Its work is split by area:
`wb_run.zig` runs commands, `wb_editor.zig` draws the columns and takes the keys, `wb_files.zig` handles files,
terminals and the boxes over the window, and `wb_git.zig` handles Git.

## Commands, menus and keys

**`commands.zig`.** Every command is a `Cmd`, named once. `info` gives its title, its menu (the palette shows
"Group: Title"), its accelerator for the menu bar, a key the window takes itself, and the Go app's id, which
`keybindings.json` may still name; `byId` finds a command by either name. The menu bar, the palette, the keys and the
UI tests all run the same commands.

**`wb_run.zig`.** `run` runs a command in a project, after offering it to `Shell.run` for the window's own. Commands from
the menu bar reach `Main.queue`, then the focused window's project's `pending` list, and run as its next frame starts,
once the frame's state is known.

**`menubar.zig`.** `layout` is the menu bar as data: groups between separators, and submenus for themes, conflicts,
stashes, recent folders and terminal profiles. `build` turns it into myzig's menu items, with checks from `isOn` and
the accelerators `keybindings.json` has not taken. `Main.menuIfChanged` builds it again only when the recent folders,
the settings, the keys or the review comments changed; the labels live in `menu_arena` while the menu shows.

**`keymap.zig`.** `keybindings.json` is read in VS Code's format, comments and trailing commas too (`stripJsonc`): keys
and chords of up to four keys, `-command` removals, `when` conditions (`holds`), and `runCommands`, `type`,
`workbench.action.terminal.sendSequence` and `vscode.open` as steps. Keys and commands it does not know are told once
in a toast. The file is read again as the window takes the keyboard (`loadKeysIfChanged`) or as it is saved in MyCode
(`Shell.fileSaved`). A binding on a menu accelerator takes it off the menu (`takesAccel`).

**`wb_editor.zig` (`keys`).** Each frame asks the keymap first, with what has the keyboard as its `when` context, so a
chord's next key never types. Then come the keys the window takes itself (project, column and tab numbers, and the
editor's line commands). A terminal with the keyboard keeps its shell's keys and passes on only the workbench's own
(`shellSkip`); off macOS it is offered keys before the menu bar (`c.keys_first`).

## Documents, editors and columns

**`doc.zig`.** A `Doc` is a file open in a tab: a myzig `ui.CodeEditor` holding its text, with highlighting, undo,
find and the selection, plus saving and reloading, line endings (a CRLF file is read without its CRs and written with
them), the gutter's marks of the lines changed since `HEAD`, conflict blocks, and what the editor draws over its lines
(other occurrences of the word at the caret, blame and review notes after lines' ends). Tabs share a `Doc` by counting
(`retain`, `release`): **Split Right** shows a file in two columns with one text and one undo history.
`reloadIfChanged` reads a file changed on disk again unless it has edits, as a step of undo.

The marks are made again whenever the text's version changes (`updateMarks`): `HEAD`'s text is read once with
`git show`, then the lines are compared with `ui.diff`. A file and its base larger than 8 MB together get no marks.

**`columns.zig`.** `Editors` holds a project's columns. A `Column` has its tabs, the one shown and whether it is locked;
an `Item` is a tab whose `Body` is a file, a picture, the Changes tab, a commit or a terminal. Each column has at most
one preview tab: `openFile` with `preview` takes the preview tab's place, while an edit, a double click or opening a file
for good keeps it. Files open in `fileColumn`, the focused column unless it is locked for terminals. When two tabs show
one file, each keeps its own selection and preview state in its `Item`, swapped into the shared editor as it is drawn.
`tick` saves a file a second after its last edit while **Auto Save** is on. Closing a tab whose changes would be lost
queues it in `ask_close` for a question; closed tabs are kept for **Reopen Closed Tab**. `tabdrag.zig` works out where
a dragged tab, an Explorer file or files from the system land: between tabs, in a column, or on its edge for a new
column.

**`wb_editor.zig`.** `columnsView` lays the columns out side by side in nested splits, each with its strip of tabs and
its body: the editor with its breadcrumbs, sticky lines, conflict buttons, review strip, minimap (`minimap.zig`) and
overview ruler (`ruler.zig`); a picture; a list of diffs; or a terminal. Each body is keyed by its `Item`, so tabs keep
their state as columns come and go. A file opened to edit takes the keyboard for a few frames (`focus_editor`). The
welcome page shows while no tab is open.

**`editing.zig`.** Editing commands are functions of a `ui.TextArea`, each one step of undo: moving, copying, deleting
and inserting lines, sorting them, changing case, trimming trailing whitespace and reindenting.

**`symbols.zig`.** A file's functions, types and headings are found from the shapes of its lines, so they work in any
language. They serve `@` in quick open, the sticky lines and the breadcrumbs.

**`findwidget.zig`, `peek.zig`.** The find widget sits over the editor, which finds and marks the matches itself. A
click on a gutter mark opens `peek.zig`'s box with `HEAD`'s lines, from which the change is reverted or staged.

## Explorer, quick open and search

**`explorer.zig`.** The Explorer is a myzig `ui.outline` over the folder, each folder read as it first opens
(`fs.list`). Git's state colors each changed file and the folders above it, and the files Git ignores
(`git ls-files --ignored --directory`) show faint. Its menu creates, renames, trashes and reveals files; files pasted or
dropped on a row copy into its folder. `wb_files.zig` acts on its events. `fs.zig` holds the small file helpers and the
names left out (`skipped`, and `heavy` folders such as `node_modules`).

**`quickopen.zig`.** Quick open lists the folder's files with `git ls-files`, or else a walk of at most 50,000 files, and
finds them with a fuzzy `score`, recent files first. `>` turns it into the command palette (each command with its keys,
and a terminal of each profile), `@` goes to a symbol of the file shown, and `:42` or `:42:7` to a line and column.
**Open Recent** (`Shell.recentBox`) and **Switch Branch** (`branches.zig`) are boxes like it.

**`search.zig`.** Search in files lists the files as quick open does, then reads and matches them on a thread of its own,
with match case, whole word, regular expressions (`ui.Regex`), and files to include and to exclude (`glob.zig`, which
also serves `files.exclude`). Files with unsaved edits are searched as the editor has them. Results come back through
the mainthread queue 20 files at a time. Each search has a generation number in a `Shared` block the thread holds
on to: a newer search or a closed project makes the thread stop and its batches be dropped, so typing never shows stale
results. A search stops at 20,000 matches, and skips files over 4 MB. Replacing goes through `replaceAll`.

## Source control

**`git.zig`.** Git runs through its command line, never a library (`run`), with `GIT_TERMINAL_PROMPT=0`,
`GIT_OPTIONAL_LOCKS=0`, `LC_ALL=C` and `GIT_EDITOR=true`, so a login that needs a prompt fails rather than hanging and
Git's words come in English. `status` reads `git status --porcelain=v1 -z` into `Change`s, marking submodules.

**`scm.zig`, `scmtree.zig`.** The source control view groups the changes as merge changes, staged changes, changes and
untracked files, by path or as a tree (`scmtree.zig`, a folder with only one folder in it merged into one row), with
the commit box, the branch with fetch, pull and push, a banner while a merge, rebase, cherry-pick or revert is stopped
for conflicts (`Op.of` reads the Git folder), and the commit graph. `Scm.refresh` reads the status, the branch, its
distance from upstream and the remotes on the main thread. It runs when the project is shown again or the window
focused, when the watcher reports a change, and after each Git command; each read bumps `generation`, which the
Changes tab follows.

**`gitops.zig`, `wb_git.zig`.** Commands that take a while (fetch, pull, push, checkout, stash, commit, merge, rebase and
the like) go through a `Runner`, one at a time, off the main thread, while a bar moves under the title; `onGitDone`
hears how each went. Quick commands (stage, unstage) run at once through `wb_git.quick`. Before a command that rewrites
the work tree, auto save saves the open files, and `worktree.docsSaved` stops it while one still has unsaved changes.
Inline blame runs `git blame --porcelain` for the caret's line on a thread (`BlameJob`), 0.6 seconds after the caret
stops on a saved file.

**`hunks.zig`.** Staging, unstaging or discarding one run of changes never applies a patch. The texts are compared
again (`hunksOf`), the hunk is applied toward one side (`apply`), and the result is written to the index with
`git hash-object -w` and `git update-index --cacheinfo` (`writeIndex`). Reverting a hunk in the editor is an edit of
the document.

**`difflist.zig`, `changes.zig`, `commitview.zig`.** A `DiffList` shows the diffs of several files, one at a time (`single`, the Changes tab's
unless `diffAllFiles`) or in one scroll: each file under a header, side by side or in one column (`auto` chooses side by side when each side has room for 80
columns), its runs of changes under `@@` lines with buttons to stage, unstage or discard them, three unchanged lines
around them, and review comments under their lines. A file is read as it comes into view, and one with over 2,000
changed lines starts folded. The rows are made again each frame from myzig's `ui.DiffView`. `wb_git.readSide` reads
each side: a blob through `git show`, or the work tree's file as the editor has it, so the **Changes** tab
(`changes.zig`, staged changes first, then the rest) follows a file as it is typed. A commit's tab (`commitview.zig`)
is the same list, with the files `git diff-tree` names against the first parent, under a card of the commit's message.

**`graph.zig`.** **COMMITS** in source control shows the branch's last 50 commits (`git log`, or of every branch), more on
**Show More Commits**, each given a lane so the branches draw as a graph, with its author's initials, branches, tags and
age.

**`branches.zig`, `worktree.zig`, `conflicts.zig`, `review.zig`.** `branches.zig` is the box of **Switch Branch** and
**Delete Branch**, local and remote branches ordered by their last commit, and the stash's box. `worktree.zig` opens the
worktree a branch is checked out in, here or in a window of its own, and prunes one whose folder is gone. `conflicts.zig`
finds the blocks of conflict markers (diff3's base too) and resolves one by taking a side. `review.zig` keeps review
comments on lines of files until MyCode quits; each follows its lines as the file changes, and **Send Review Comments to
Terminal** pastes them all into the terminal for an agent to read.

## Terminals

**`panel.zig`.** A `Term` is one terminal, made with the terminal plugin's `Terminal.create`, shown in the bottom panel
or in a column's tab. It keeps its folder, its profile, whether it rang or asked for attention (OSC 9 and OSC 777) while
out of sight, and pastes pictures and copied files as a terminal agent expects. `Panel` is the bottom panel with its
chips, profiles and buttons; its requests (a new terminal, a move to a column) go to `wb_files.panelRequest`. `Host` is
what terminals report to: the window to redraw, the font of the settings, and the links Ctrl+click opens.

**`termprofiles.zig`.** The profiles are the shells this machine has (PowerShell 7, Windows PowerShell, Command Prompt,
Git Bash and WSL on Windows; `/etc/shells` elsewhere) and those `terminalProfiles` adds.

**`termlinks.zig`.** A clicked link names a path with the `:line` or `:line:col` compilers print after it, Git Bash's
`/c/...` and WSL's `/mnt/c/...` as Windows names them, or `~/`. `Shell.openLink` resolves a relative one from where the
shell is now, where it started, then the project, and opens the file at its line or reveals the folder.

## Background work

**`jobs.zig`.** Work off the main thread goes through `spawn`: `work` runs on a thread of its own, then `done` runs on
the main thread through the mainthread plugin's queue (a message-only window on Windows), so nothing polls. A project
registers itself with `live` and leaves with `gone`; a job's `done` checks `isAlive` first, since its project may have
closed while it ran. `post` hands any function to the main thread. Git commands, blame, update checks and searches run
this way; the Git status, the gutter's marks and the diffs' sides are read on the main thread.

**`fswatch.zig`.** Each project's `FsWatch` follows its folder with the watch plugin on a thread of its own, recursively,
with 150 ms of debounce. It leaves out heavy folders and Git's objects but watches `.git` itself and `.git/refs`, so a
commit or checkout made in a terminal is seen. A change sets atomic flags and posts once to the main thread, where
`Workbench.onDiskChange` reads the Explorer, the open files and Git's state again. `stop` never waits for the thread,
which may be reading the whole folder: the project, the thread and a queued delivery each hold a reference, and the
last frees the watcher.

## Settings and state

**`settings.zig`.** The settings live in `settings.json` in the data folder: `%APPDATA%\MyCode` (myzig's
`appPath(.config, "MyCode")`), or the folder `MAYOI_DATA_DIR` names. A first start copies `settings.json` and
`keybindings.json` from a `Mayoi` folder beside it. `Store.reload` reads the file again when its time changes, checked
as each frame starts and as the window takes the keyboard, and bumps `version` so views apply the change once. `set`
writes one key while keeping the keys this app does not know. `keybindings.json` is made empty if missing.

**`state.zig`.** The app's memory is `state-zig.json` beside the settings (the Go app's `state.json` had another shape):
the projects open and the one in front, the recent folders (20), and a session for each folder (30): its columns and
tabs with carets, selection, scroll and preview state, the sidebar and panel, and the folders open in the Explorer.
`Main.saveState` writes it as projects open and close, and as a window loses the keyboard.

## Themes and looks

**`themes.zig`.** The palettes of MyCode, The Matrix (always dark), Claude and Qoder, each light and dark but The Matrix.
`uiTheme` makes myzig's theme and `syntax` the code's colors; `Shell.applyTheme` applies them each frame, with the first
installed family of `fontFamily`. `icons.zig` draws file icons from the Material Icon Theme (`icons/material.zig`, made
by `icons/update.py`) or Lucide's (`lucide.zig`, made by `icons/lucide.py`). `rain.zig` paints The Matrix's rain behind
the welcome page, a step every 70 ms, and `mascot.zig` the Claude and Qoder characters; both step from the time and hold
still while the window does not have the keyboard. `logo.zig` finds a project's icon for the rail, and `checks.zig`
makes the checkerboard behind pictures once.

## Viewer

**`viewer.zig`.** A picture opens in an `Image` tab rather than a document: its bytes go to myzig's picture cache under a
key that changes when the file is read again, and it is fitted, zoomed and dragged over the checkerboard. Markdown shows
rendered (`ui.Markdown`, local pictures only, never fetched) and SVG as a picture updated as it is typed, both in place of
their editor.

## Updates, shell integration and crashes

**`updates.zig`.** A release build looks at GitHub's latest release once a day, ten seconds after it starts, with
`curl.exe` on a job thread; **Check for Updates…** looks at once. The box shows the release notes and offers to install
it (the installer is downloaded and run, and MyCode quits), skip that version or wait. The choice is kept in
`updater.json`; development builds never look.

**`winshell.zig`.** On Windows, an installed MyCode sets up the `mycode` command (`mycode.cmd`, and `mycode` for Git Bash,
in `%LOCALAPPDATA%\MyCode\bin`, added to the user's PATH) and the **Open with MyCode** menus of folders, their insides,
drives and files under `HKCU`, off the main thread as it starts (`atStart`). A build in `zig-out` leaves them alone.
Uninstalling them leaves a `no-shell-integration` marker so they stay away; `--uninstall-shell` removes them for the
uninstaller.

**`crashlog.zig`.** A release started from Explorer has no console, so its error output (panics, a fault's stack) goes
to `crash-zig.log` in the data folder. A log the last run left with something in it moves to `crashes/` as the app
starts, and the last 10 are kept.

## Tests

**Unit tests** sit beside the code as `test` blocks, and `zig build test` runs those of the files `main.zig`'s `test`
block names: parsing Git's status, keybindings, globs, conflicts, hunks, editing, symbols, search, the state's JSON and
more.

**UI tests** live in `uitest/main.zig` and run with `zig build uitest` (`zig build uitest -- NAME` runs the cases whose
names hold NAME). Each case makes its folders under the temporary folder (`mycode-uitest/caseN`), optionally commits
them to a Git repository, writes its settings, and runs the built app headless with its own `MAYOI_DATA_DIR`,
`--myzig-snapshot` and a `--myzig-script` of clicks, keys and typing. A step that finds no text fails the case, so
`move:TEXT` checks that a text is shown, and a crash fails it too. Some cases then check what the app left: a saved file,
a commit, its state.
