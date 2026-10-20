# Changelog

The update window shows the section of the version it offers. Every release
needs a `## <version>` section here, or its build fails.

## Unreleased

- MyCode written in Zig on myzig, in `zig/` (see `zig/README.md`): the Explorer, editor columns and tabs, quick
  open and the command palette, search and replace, source control with the Changes tab, hunk staging, branches,
  stash, the commits graph, conflicts and review comments, terminals with profiles, project tabs, themes, and
  settings and keybindings read from the Go app's files.
- The Zig build has an installer, `MyCode Setup <version> x86_64.exe`, with MyCode's icon on the window, the
  taskbar and the welcome page, the terminal's libraries included, and a crash log. Fixed: choosing a folder or a
  file in a dialog no longer quits it, **Open Folder** chooses a folder, and the Zig build no longer quits as its
  window first draws.
- The Zig build also has the Material and Lucide icon themes and project icons, the Matrix's digital rain, indent
  guides, JPEG, GIF, BMP and WebP pictures, blame after the caret's line, the box of a change from the gutter
  (revert, stage, next, previous), review comments in a diff, copying and pasting files in the Explorer, choosing
  several files in source control, copying a terminal's selection as it is made, and the update window.
- The Zig build now does what the Go app does: its menus, with their checks, submenus and every command (**Undo**,
  **Find Next**, **Toggle Line Comment**, **Go to Bracket**, **Commit & Push**, **Stage File**, **Kill Terminal**,
  **Move Tab to Next Column** and more), accelerators that keybindings.json takes away, checks in the palette, chords
  of up to four keys and `runCommands`, and a terminal with the keyboard keeping Ctrl+L and Ctrl+W for its shell. A
  merge, rebase or cherry-pick stopped for conflicts shows a bar with **Continue** and **Abort**, and a commit's
  menu merges it, rebases onto it, resets to it, reverts it, cherry-picks it and renames or deletes its branches.
  **View as Tree** nests folders, the list takes the arrow keys, and **Amend Last Commit** has the next commit amend.
- In the Zig build, the minimap shows the file in its colors and the selection, drags, scrolls and widens; an
  overview ruler marks changes, matches, comments and the caret; conflicts have their buttons on their first line;
  spaces and tabs selected show; `fontFeatures`, `terminalFontFamily` and any `fontWeight` apply; diffs wrap long
  lines, show full files, keep the file's header at the top, mark the change you are on and take comments from a
  "+" on the line; pictures sit on a checkerboard, zoom around the pointer and pan; Markdown shows local pictures;
  tabs drop between tabs and on either side of a column, a middle click closes one, and **Reopen Closed Tab** brings
  back terminals; terminals drag between the panel and the columns, and their notifications mark the project.
- The Zig build's window has the Go app's title bar: the sidebar's button, the file and folder in the middle (a click
  opens quick open) and the terminal's button, beside Windows' buttons. **Open Folder** and **Open File** show
  Windows' Explorer-style dialog. The status bar names the folder and counts the file's lines. Fixed: opening a
  file no longer quits the Zig build when its minimap is an odd width, as `"minimapWidth": 79`, and closing the tab
  shown with its x or the middle button no longer quits it either.
- The Zig build draws the Go app's icons (Lucide's) everywhere, its rail as the Go app's (each project's square in
  its own color, the gear at its foot), the sidebar's views as buttons with the count of changes, and the
  terminal panel's buttons (new, profiles, to the editor area, kill, maximize, close). Its window's buttons are
  light on a dark theme.
- The Zig build asks before closing a tab, a project or a window, or quitting, with changes that would be lost
  (**Save**, **Don't Save**, **Cancel**), and the status bar says **Deleted on disk** of a file gone from the disk.
- The Zig build colors some sixty more languages (C#, Kotlin, Swift, Haskell, OCaml, Elixir, Clojure, Nix, Julia,
  Terraform, Perl, LaTeX and others), HTML, XML, Vue and Svelte with their scripts and styles, Markdown and diffs,
  and names them in the status bar. **Toggle Line Comment** does nothing in a language without line comments.
- In the Zig build, switching to a branch checked out in another worktree offers to open that worktree, here or in
  a new window, or to prune it and switch when its folder is gone. Switching branches, checking out a commit, a
  merge, rebase, cherry-pick or revert, continuing one, a hard reset, stashing and applying a stash wait for the
  files changed in the editor to be saved ("Save the changes of a.txt before switching branches."), and nothing is
  saved without asking when auto save is off. A submodule shows as a folder in source control, opens as one, shows
  the commits it is at in the **Changes** tab, and isn't discarded or stashed. Fixed: the Enter that chose **Switch
  Branch…** in the palette no longer checks out the first branch at once.
- The Zig build's status bar is the Go app's: what Git is doing with a spinner ("Switching to main…", "Pushing…"),
  tooltips on the branch, the folder and the caret's place, the indentation's menu with checks and **Convert
  Indentation to Tabs** and **to Spaces**, a menu for the line endings, and for a picture its size, bytes and zoom,
  for a diff its files, changes and lines, for a terminal its folder and size in cells.
- The Zig build's welcome page is the Go app's: the logo beside the name and "a small, quick code editor", a **Start**
  list (**Quick Open…**, **Find in Files**, **Command Palette…**, **New File**, **Toggle Terminal**, **Toggle
  Sidebar**) with their keys as keycaps, and the recent folders with their parent folders.
- In the Zig build, the Explorer's **New File…**, **New Folder…**, **Refresh Explorer** and **Collapse Folders**
  buttons sit on the folder's row with tooltips while the pointer is over the sidebar, and an empty folder shows
  **This Folder Is Empty** with buttons that make the first file or folder. The welcome page writes folders under
  the home folder from `~`.
- The Zig build's Explorer follows the tab shown, opening the folders above its file and choosing it, colors files
  with unsaved changes as the tabs do and the files not shown a little quieter, copies files dropped from File
  Explorer into the folder they land on, and orders its menu as the Go app's.
- The Zig build's find widget is the Go app's: over the top right of the editor, with the arrow that shows
  **Replace**, the **Match Case**, **Match Whole Word** and **Use Regular Expression** toggles inside the field, the
  count of matches ("3 of 12", **No results** in red), icon buttons with tooltips, and **Replace** and **Replace All**.
- The Zig build's tabs are the Go app's: the strip scrolls sideways when they don't fit and brings the tab shown
  into view, each tab has its path as a tooltip, a file deleted on disk is struck through in red, the **Split Right**
  and **Unlock Column** buttons end the strip, and a tab's menu has **Close Others**, **Close All**, **Move to Next
  Column**, **Move to Previous Column** (making the column when there is none), **Show Preview**, **Reveal in File
  Explorer** and **Copy Path**.
- The Zig build's terminal panel is the Go app's: **TERMINAL** underlined in the accent, the terminals' chips
  scrolling sideways with **Close Terminal** buttons, **Previous Terminal** and **Next Terminal** while there are
  several, the default profile named on **New Terminal**'s tooltip and marked **(Default)** in **Launch Profile…**,
  with **Select Default Profile** and **Configure Terminal Profiles…**, and a chip's menu that moves the terminal to
  the locked right column or the editor area.
- The Zig build's quick open is the Go app's: under the title bar, its icon and placeholder by what it searches,
  the characters matched in the accent, commands as **Group: Title** with their keys as keycaps, a terminal of each
  profile and the default one (**Terminal: New Terminal: Git Bash**), symbols nested as in the file until a name
  is typed, `:42:7` for a line and a column, what to type when nothing matches, and a footer with its keys and
  prefixes.
- In the Zig build, Ctrl+clicking a path in a terminal finds it from where the shell is now, then where it
  started, then the project; goes to its column too (`main.zig:12:5`); takes Git Bash's `/c/...`, WSL's
  `/mnt/c/...`, `~/` and `file://` links; and leaves out the punctuation that ends a sentence.
- The Zig build's source control is the Go app's: **No Git Repository** and **No Changes** with how the branch
  stands with its upstream ("main is clean, 2 commits ahead of origin/main.") and a button to **Publish**, **Pull**,
  **Push** or **Sync**; fetch, pull and push as icons counting the commits they would move; the view's actions
  under **More Actions** beside its title; "Summary is long" with the summary's length past 50 characters; and
  tooltips on every button. A change's menu adds **Reveal in Explorer** and **Copy Path**, and a group's buttons
  open its changes.
- The Zig build's toasts say what Git did, as the Go app's: "Committed “…” to main" with **Undo**, "Amended the
  last commit", "Pushed main to origin/main", "Published main", "Pulled 3 commits" or "Already up to date",
  "Created branch x at abc1234", "Stashed the changes" with **Pop**. A commit's tooltip gives its author, age and
  short hash; the branch and stash boxes are the Go app's, with a check by the branch checked out, "Create branch
  x from main", and every action on a stash in its menu.
- Fixed in the Zig build: **Commit All** commits untracked files too (it left them, and failed in a new
  repository), and a branch without commits yet shows its name rather than **No Branch**.
- The Zig build's diffs have the Go app's bar: icons with tooltips for the previous and next change, **Show Full
  Files**, **Toggle Word Wrap**, the **Layout** menu (side by side when wide, side by side, inline) and **Open
  File**; icon buttons on each file; **Stage**, **Unstage** and **Discard** buttons on each change; and **No
  Changes** when the work tree matches the last commit.
- The Zig build's commit tabs open on the Go app's card: the subject, the author's initials and name, when it was
  committed, its short hash (a click copies it), its branches and tags, how many parents and files, and the rest
  of its message folded past six lines with **Show More**.
- The Zig build's boxes asking for a name are the Go app's: titled **New File**, **Rename**, **Create Branch…**,
  **Stash…** with a hint beside (where the file goes, the branch a new one starts from), the button named for what
  it does and off while the name is empty, a name taken or not allowed said in the box without closing it, and
  **Rename** choosing the name without its extension.
- **Stash Changes…** in the menu of a changed file in source control stashes that file alone, or the files chosen.
- Fixed: the app no longer quits when a commit or a push takes files away from an open **Changes** tab scrolled down
  its list.
- A minimap along the right of each editor, as in VS Code: the whole file, small, in its colors, with the lines changed
  since the last commit and the selection. A click scrolls there, the slider drags, and the wheel over it scrolls the
  editor. Drag its left edge to make it wider or narrower (`minimapWidth`); **View → Minimap** hides it (`minimap`).
- Ctrl+click (⌘-click on macOS) on a file path a terminal prints opens the file in the editor at its line and column,
  as `src/app.go:12:5` from a compiler or an agent: relative to the shell's folder or the project, absolute, `~/`,
  on Windows `C:\dir\file`, `dir\file`, Git Bash's `/c/...` and WSL's `/mnt/c/...`, or a `file://` link. A folder of the project shows in the Explorer.
- Windows: terminals use the ConPTY of Windows Terminal, shipped with the app, instead of Windows 10's own, which
  dropped the mouse and the full screen of programs such as Claude Code, Codex and pi: they no longer lag, and the
  wheel scrolls them.
- Merge conflicts in the editor: each block of markers is tinted, with **Accept Current**, **Accept Incoming** and
  **Accept Both** on its first line, commands for the conflict at the caret or the whole file, **Next Conflict** and
  **Previous Conflict**, and a toast that stages the file once its last conflict is resolved.
- Stash: **Stash…** (with untracked files or not), **Apply** or **Pop Latest Stash**, and a box of the stash's
  entries to apply, pop, view or drop, from **Git → Stash**, source control's **⋯** menu and the command palette.
- **Rename Branch…** and **Delete Branch…**, in the status bar's menu, the **Git** menu, the command palette, a
  branch's menu in Switch Branch and a commit's menu in COMMITS. Deleting asks first, can delete the upstream too or
  a remote's branch on its remote, asks again for a branch not merged, and has an **Undo**.
- A middle click on a tab closes it, the tab shown too.
- **Pull (Rebase)** and **Pull (Merge)**: a pull of a branch that has diverged from its upstream asks which, instead
  of failing.
- **Force Push…**, with `--force-with-lease`, and offered when the remote rejects a push, as after an amend.
- **Sync** pulls then pushes, from the menus, the command palette, and the button of a clean work tree that is both
  ahead and behind.
- File and folder icons from the Material Icon Theme, as in VS Code, in the explorer, tabs, breadcrumbs,
  quick open, search and source control. The Matrix theme keeps its one-shade icons.
- **File Icon Theme** (View menu, Manage menu, command palette, or the `iconTheme` setting) switches between the
  Material icons and the Lucide ones.
- The `filesExclude` setting hides files and folders by glob patterns from the explorer, quick open and search, as
  VS Code's `files.exclude`: `"filesExclude": { "**/dist": true, "*.log": true }`. It applies as the file is saved.
- Renamed to MyCode, by hunghg255. The settings of Mayoi carry over on the first start, and the app no longer
  updates itself from Mayoi's releases.
- Windows: a `mycode` command (`mycode .`, `mycode <file>`) in PowerShell, Command Prompt and Git Bash, and
  **Open with MyCode** in File Explorer's menu of folders and files, set up as the installed app starts.
- New app icon.
- A Manage button (a gear) at the bottom left, as in VS Code: the command palette, settings, keyboard shortcuts,
  theme and default terminal.
- Each terminal of the panel has a cross that closes it, and arrows go to the previous and next terminal
  (also **Next Terminal** and **Previous Terminal** in the command palette).
- A terminal profile whose program is not on the machine is left out, rather than fail to start.
- Terminal profiles, as in VS Code: start a terminal of PowerShell, Command Prompt, Git Bash, WSL or a shell of
  your own from the **⌄** button by the panel's **+**, and choose the shell new terminals start.
- The welcome page and the README are in English only, without the Japanese name.
- Project tabs are on by default, and their rail always shows on the left, with a **+** button to add a project.
- Windows: Git and the other commands Mayoi runs no longer flash console windows.
- Removed Vim mode, and the `vim` and `vimCtrlKeys` settings.
- Removed Remote SSH: connecting to hosts, remote folders, port
  forwarding, and uploads and downloads.
- Review comments: choose lines in a diff (Shift-click, a drag or
  Shift+J/K) and press C, or select lines in a file and press ⇧⌘M, to
  comment on them. **Send Review Comments to Terminal** pastes them all
  into the terminal used last, for the agent there, each with its path,
  line numbers and lines; ⌘C in a diff copies the lines chosen so.
- A **+** button by the line under the pointer in a diff comments on it,
  or on the lines chosen with it, and a bar marks the lines of each
  comment, with a mark on the scroll bar.
- A diff with review comments offers **Send N Comments** in its toolbar,
  and Delete deletes the comment chosen in it.
- A file shows each review comment after the last of its lines; click it
  to edit the comment, or hover it to read it all.
- Review comment cards are redrawn: a stripe of the accent down their
  edge, an **Outdated** badge when their lines changed, and a Comment
  button that stays off until there is something to say.
- Lock a column from its tab menu to keep it for terminals: Move to Locked
  Right Column puts a running terminal there in one step. Files opened from
  the Explorer, Search, Quick Open or Source Control go to an unlocked
  column, which stays beside the terminal, at the same width, when its last
  file closes. An empty locked column offers a new terminal, ⌘W closes an
  extra empty column, and each project's session remembers the locks.
- Source Control selects several files: Shift-click or Shift+Up/Down
  for a range, Cmd-click (Ctrl-click on Windows and Linux) for one more,
  and Cmd+A for all. Space, and a selected row's stage, unstage and
  discard buttons and menu items, act on all the files selected.
- The Explorer, and Source Control as a tree, draw indent guides down
  from each open folder, in the Explorer brighter for the folder of the
  file shown, and a shadow under the folder's name as the files scroll
  under it.
- The Markdown preview draws a task's checkbox as a box, filled once
  done, and lists with softer bullets, rings for a list in a list.
- A picture fitted to its tab leaves a margin around it, and a hairline
  sets it off from the pane.
- The editor does less work on every frame it paints: idle and scrolling
  frames of a large file allocate about a quarter of what they did.

## 0.9.1

- ⇧⌘E gives the Explorer the keyboard, as in VS Code, so that the arrows
  choose a file and ⌘V pastes into the folder chosen.
- Remote SSH: files copied in the Finder paste into a folder of the host,
  and files dropped from the Finder on the explorer copy into the folder
  under the pointer. A remote file copied in the explorer pastes as a
  copy on its host, or downloads into a folder of this machine.
  **Upload…** and **Download…** in the explorer's menu do the same by a
  dialog. The status bar shows each transfer and how far it got, and a
  click on it cancels one.
- Remote SSH: ports of the host forward to this machine. A link to
  `localhost` clicked in a terminal of the host forwards its port and
  opens it in the browser, and **Forward a Port…** forwards one by its
  number. The status bar shows the ports forwarded, with a menu to open,
  copy or stop each.
- Remote SSH: the folders of the Explorer open at once: those in a
  folder are read along with it, at one round trip to the host.
- Remote SSH: saving a file that changed on the host since it was
  opened asks whether to overwrite it or revert to it, rather than
  writing over the change.
- Remote SSH: a terminal of the host no longer closes as the connection
  goes: it keeps what it showed, says the connection was lost, and
  starts again as it comes back.
- Remote SSH: a terminal of the host pastes files, and a screenshot alone
  on the clipboard, as copies uploaded to the host, and types their paths
  there, so Claude Code on the host takes a pasted screenshot. A remote
  file dragged to a terminal types its path on the host, not Mayoi's.
- A folder opened again just after `git init` shows its Source Control:
  the look for its repository made before no longer has the last word.
- With Git 2.55 or later, the diff of a submodule shows the commits it
  went from and to again, not the log of the submodule's commit.
- Remote SSH: a connection that drops, as the network goes or the laptop
  sleeps, connects again by itself, after 2 seconds, then less often, up
  to every 30 seconds, and at once as the window comes back to the front.
  The banner says when it tries next, with **Reconnect Now**; a host that
  refuses the keys, or whose key is not trusted, says so and waits.
- Remote SSH: the Connect to Host box groups the recent hosts, with the
  folder opened last on each, apart from those of `~/.ssh/config`, and
  marks the letters the query matched. While it connects it says as whom
  and for how long, and Escape goes back to the hosts.
- Remote SSH: the folders of the host list by name, with `..` to go up,
  `~` for the home folder, and why a folder could not be read; the host
  shows beside the path.
- Remote SSH: the Explorer of a folder whose host is not connected says
  so, with a button to reconnect, and the title bar names the host.
- Remote SSH: a remote folder looks for changes every 15 seconds rather
  than 3 while its window is in the background, and at once as it comes
  back; who each host signs in as is remembered until `~/.ssh/config`
  changes, and a remote file opens at one round trip to the host, not
  two.
- **View → Project Icons** (or `"projectIcons": true` in `settings.json`)
  shows each project's favicon or logo on the rail, from its well-known
  icon files, `favicon.ico` included, or the icon its sources declare,
  rather than its initials. A project without one keeps its initials.
- Project Icons also finds a mygo app's icon (the one `mygo.json` names,
  or `resources/icon.png`), the favicon a `site/` or `docs/` page
  declares beside it, and a macOS app's `.icns` or Xcode AppIcon.

## 0.9.0

- Remote SSH: **File → Remote SSH → Connect to Host…** opens a folder on
  another machine with the system's `ssh`, with nothing to install there.
  It lists the hosts of `~/.ssh/config` and those connected to before,
  then the folders of the host. Files open and save in the background,
  and the Explorer, quick open, search, Source Control and terminals run
  on the host, which `inotifywait` or a poll every 3 seconds watches for
  changes. Disconnecting keeps the window, read-only, until it connects
  again. Keys and the SSH agent sign in; Windows does not have it yet.
- A selection made from right to left grows from where it started:
  ⌘⇧← or Shift-Home takes it to the start of the line, where it used to
  drop the part already selected, and the caret's line, the blame beside
  it and the scrolling follow the caret, not the selection's far end.

## 0.8.2

- Selecting text in a terminal copies it to the clipboard, as in Ghostty
  and iTerm2: a drag, a double or triple click, a Shift-drag in a
  program that takes the mouse, or Select All. Set
  `terminalCopyOnSelect` to `false` in settings.json to turn it off.
- Each project keeps its own sidebar and panel: whether the sidebar
  shows the Explorer, Search or Source Control, whether it is open, how
  wide it is, and how tall the terminal panel is. Switching project tabs,
  or windows, no longer carries one project's layout to the others. A
  project opened anew starts with the layout of the one in front, and a
  folder opened again gets back the layout it had.
- ⌘V pastes a screenshot into Claude Code in the terminal, as in VS Code:
  with only an image on the clipboard, the terminal sends an empty
  bracketed paste, which Claude Code takes as its cue to read the image
  itself. Mayoi builds on a fork of MyGo with this fix until it is
  released upstream.
- A new file in a folder whose name starts with a dot, like
  `.changeset`, shows its lines in Changes instead of a git error, and
  its hunks can be staged. A file's error in Changes no longer runs
  over its header.

## 0.8.1

- The rail of project tabs is redrawn: a pill along its edge grows from
  the project under the pointer to the one shown, the squares ease
  between their states, and a dot cut out of a square's corner marks
  unsaved changes. A square's tip, to its right, gives the project's
  name, its folder and its keys. Drag a square along the rail to reorder
  it, or drop a folder from the Finder on the rail to open it. The button
  after the squares opens another folder, and a square's menu adds
  **Reveal in Finder**, **Copy Path** and **Close Other Projects**.
- With project tabs, a terminal that rings its bell or sends a
  notification in a project out of sight, as a build or an agent does
  as it finishes, marks the project's square in the accent until the
  project shows, and its tip says why.
- The explorer of an empty folder says so, with **New File…** and **New
  Folder…** buttons.

## 0.8.0

- The title bar and status bar now adapt to narrow windows: the status
  bar leaves out its least needed parts, the encoding first, only once
  they would not fit, and the command center leaves out the folder before
  it cuts the file's name short. The command center has a clearer control
  surface, active tabs are easier to identify, and Explorer rows have more
  comfortable spacing.
- Inactive editor tabs no longer lay out their text every frame, keeping
  rendering responsive as more files are opened while preserving each tab's
  selection and scroll position.
- Project tabs: **View → Project Tabs** (or `"projectTabs": true` in
  `settings.json`) keeps every folder open in one window, with a rail on
  its left of a square for each, its initials in it. A click shows a
  project, as do ⇧⌘] and ⇧⌘[ (**Go → Next Project** and **Previous
  Project**) and ⌃⌘1…9, each with its tabs, terminals and Explorer as it
  left them. Opening a folder adds it to the rail. **File → Close
  Project** closes one. Turning it on gathers the windows into the one in
  front, and off parts them into a window each again.
- The commits' context menu does what Sourcetree's does: **Merge into**
  the branch, **Rebase** it onto the commit, **Reset** it to the commit
  (Soft, Mixed or Hard), **Revert Commit** and **Cherry-Pick Commit**.
  When one stops for conflicts, source control says so with **Continue**
  and **Abort** buttons, which the menu and the command palette offer too,
  and the commit box takes the message Git proposes.
- The initials of a commit's author sit in the middle of their circle, in
  the history and on the commit's card.
- When Mayoi crashes, what ended it, with every goroutine's stack, is kept
  in `crash.log` in its data folder, and the last 10 crashes in its
  `crashes` folder, also when it was started from the Finder or the Dock.

## 0.7.0

- MyGo 0.4.8: shortcuts work on keyboard layouts that type no Latin
  letters, a selection paints above the text's highlights, and long files
  lay out and draw with less work.
- The Qoder theme: **View → Theme → Qoder** takes Qoder's Forest colors,
  light or dark as the Appearance is, with its code in Forest's greens,
  blues, teals and ambers. Qoduck, Qoder's round-faced duck, its beak
  tilted so that both eyes show, takes the logo's place on the welcome page
  and sits at the start of the status bar, blinking now and then and
  hopping while Git or a search works, as Clawd does in Claude.
- Switching to a branch checked out in another worktree offers to open
  that worktree, in this window or a new one; when its folder was deleted,
  to prune it and switch.
- Better on Windows and Linux: the menus' shortcuts work there, with VS
  Code's keys where Ctrl for ⌘ would collide or be AltGr (F3 and
  Shift+F3 find the next and previous match, Ctrl+H replaces, Alt+1 to
  Alt+9 show a tab), the terminal leaves the shell its Ctrl keys but the
  workbench's, vim's normal mode leaves ⌃F, ⌃B and ⌃R to Find, the
  sidebar and Open Recent unless `vimCtrlKeys` is on, tooltips and hints
  show Ctrl+… rather than ⌘, and the menus name File Explorer and the
  Recycle Bin.
- Keyboard shortcuts of your own: **File → Open Keyboard Shortcuts** opens
  `keybindings.json`, in VS Code's format, so those of VS Code or Cursor
  can be pasted in. It takes chords, as `ctrl+. g c`, the names of VS
  Code's commands, `when` conditions, `runCommands`, `vscode.open` and
  keys taken away with `-`, and applies as it is saved.
- New commands: **Sort Lines Ascending** and **Descending**, **Transform
  to Camel Case**, **Copy Path of Active File**, **Reveal Active File in
  Finder** and **Indent Using Tabs** or **Spaces**.
- The sidebar's title is no longer cut short: the Explorer's buttons show
  on the folder's row, source control's Refresh is in its **⋯** menu, and
  in a narrow sidebar the title reads **GIT** rather than **SOURCE C…**.
- Quick open's footer shows the prefixes it takes, **>** for commands,
  **:** for a line and **@** for a symbol, as keys, and its placeholder no
  longer repeats them.
- A button that loses something, as **Discard**, is a deeper red that its
  white label reads on in a dark window, and shades under the pointer
  as the other buttons do.
- **⇧⌘V**, or the button at the end of the breadcrumbs, previews a
  Markdown file as well as an SVG: headings, lists and task lists, quotes,
  code highlighted as in the editor, tables, cached local bitmap and SVG
  images, inline badges and links, with comments and front matter hidden, in
  the editor's fonts and colors. It follows your edits, and with the same
  file in another column shows its source beside it. An image or link
  starting with `/` is found from the repository's root, as on GitHub.
- A sideways swipe on a trackpad scrolls a long line smoothly, as in VS
  Code: it moves the text sideways only, rather than stopping every few
  frames and drifting up or down.

## 0.6.0

- **⌘C** in the Explorer copies the file or folder chosen, and **⌘V**
  pastes the files copied, in another window or in the Finder, into the
  folder chosen; a name taken gets "copy" added, as in the Finder. The
  menu of a file or folder has **Copy** and **Paste** too.
- Double-clicking a file in the Explorer keeps its tab open, and gives
  it the keyboard, rather than leaving it a preview.
- A commit clicked under **COMMITS** opens in the preview tab, its name
  in italics, and the keyboard stays in the list: clicking through
  commits leaves one tab. Enter, a double click or **Open Changes** keeps
  it.
- Drag a file from the explorer, from source control's changes or from
  the search results to open it where it is dropped: on a tab strip where
  the marker shows, on a column after the tab shown, or on the edge of a
  column in a new column there. A search match opens selected. Dropped on
  a terminal, the file types its path.
- A commit's tab wraps its message to the width of the view instead of
  cutting it at the right edge: the subject on up to three lines, the line
  of its author, date, hash and branches onto a second, and the body in the
  editor's font. A body longer than twelve lines folds under **Show More**.
  The message can be selected and copied, and a click on the hash copies
  it. A long subject in the breadcrumbs ends in an ellipsis.
- A click on the empty space below the files in the Explorer, or Escape,
  unselects the file or folder chosen, so new files and pasted ones go in
  the workspace's folder. A right click there opens a menu for the
  workspace: **New File…**, **New Folder…**, **Reveal in Finder**,
  **Open in Terminal** and **Paste**.

## 0.5.1

- **COMMITS** in source control draws the history as a graph, each branch
  in a lane and color of its own, and shows each commit's author, branches
  and tags; a branch and its remote's at the same commit share a badge.
  HEAD has a ring and a merge a hollow dot. The commit's tab shows its
  branches and tags too.
- **Show All Branches**, from the COMMITS header or the **⋯** menu, shows
  every branch and tag, not only the branch checked out. It is the
  `scmAllBranches` setting.
- A commit's menu checks it out, creates a branch or a tag there, and
  copies the name of its branches and tags.
- The **⋯** menu of source control no longer ignores an item chosen with
  the pointer past the sidebar, as **View as Tree** often was.
- A folder closed, by closing its window, **File → Close Folder** or
  opening another folder in its window, opens again with its tabs,
  columns and the folders open in the Explorer. Opening
  another folder in a window now closes the tabs of the one it had,
  rather than keeping them beside the new folder's.
- Tabs come back with their caret, selection, scroll position and own
  word wrap, and a diff showing every line still does, also when Mayoi
  starts again.
- The windows, tabs, recent folders and layout move from `settings.json`
  to `state.json` beside it, so `settings.json` holds only the
  preferences.
- Closing the last tab of a column with another after it no longer
  crashes Mayoi.

## 0.5.0

- **View → Theme → Claude**: Anthropic's ivory and warm near-black with
  Claude's orange. Clawd, Claude Code's little character, takes the logo's
  place on the welcome page and sits in the status bar, blinking now and
  then, and hops while Git or search works.
- **View → Theme** picks the theme (Mayoi, The Matrix or Claude) and,
  apart from it, System, Light or Dark, so Claude can be light or dark
  whatever the system is. They are the `theme` and `appearance` settings;
  a settings file with `"appearance": "matrix"` keeps The Matrix. Light
  and Dark are greyed out under The Matrix, which is always dark.
- **Search** in the sidebar (⇧⌘F) finds text in every file of the folder,
  with match case, whole word and regular expressions, and files to
  include and exclude. ⇧⌘H replaces across files, all at once, a file at
  a time or a match at a time, showing each replacement first. Open files
  change as a step of undo.
- Search's results: ↓ and ↑ walk every match, past the file headers, as
  far as the list scrolls; ↑ from the first match and Escape go back to
  the query. Each match shows its line number, matches stand out more,
  a bar moves while searching, and searches ignoring case are about
  twice as fast.
- **Preview tabs**: a file clicked in the Explorer or chosen in search's
  results opens in a tab with its name in italics, which the next file
  chosen replaces. Editing it, double-clicking it or its tab, or Enter
  keeps it. Moving through search's results with ↓ and ↑, or clicking
  one, shows each match in the editor while the keyboard stays in the
  results, and the match clicked becomes the one chosen.
- **File → Open Settings** (⌘,) opens `settings.json`, and saving it
  applies the fonts, theme, auto save, word wrap, vim mode and the other
  preferences in every window at once, rather than at the next start.
- New font settings: `fontWeight`, `fontFeatures` (as `["calt=0"]` to
  turn ligatures off), `lineHeight`, and `terminalFontFamily` and
  `terminalFontSize` for a terminal font of its own.
- Zooming the text resizes the terminals of every window, not only the
  window's own.
- **Reveal in Explorer** in a tab's menu shows the Explorer, chooses the
  file and scrolls to it, and the menu has **Reveal in Finder** too. The
  Explorer scrolls to the file shown as tabs change.
- The welcome page titles its sections as the sidebar titles its views.
- A diff says that a file has no changes in its text, or is binary, in
  the window's font rather than as a line of code.

## 0.4.0

- **Go → Command Palette…** (⇧⌘P), or `>` typed in quick open, runs any
  command by name. Each row shows its menu and its shortcut, and a check
  when it is on; the commands run last come first.
- The status bar no longer calls `go.mod` AMPL or every `.sql` file
  MySQL. Brewfiles highlight as Ruby and `.npmrc` as INI.
- In The Matrix, the welcome page sits on a panel over the digital rain,
  so its words read.
- Line numbers, comments and secondary text, such as the folders in
  quick open, read more easily in the light and dark themes.

## 0.3.3

- **View → Theme** (formerly Appearance) adds The Matrix: phosphor green on
  black, the whole window in the code's font, file icons in greens, and
  red and amber kept for what is removed, failed or changed. The terminal
  takes its colors, and digital rain falls behind the welcome page while
  the window has the keyboard.
- Clicking a file or a commit in source control focuses its changes, so
  `]` `[` go from change to change and `.` `,` from file to file at once.

## 0.3.2

- Drop files from the Finder to open them: on a column, on its tab strip
  where they should go, or on the side of a column to open them in a new
  column there. A folder dropped on a window opens as `mayoi <dir>` opens
  it. Dropped on a terminal, files type their paths, quoted for the shell.
- Primary buttons, such as **Commit**, stay purple under the pointer and
  as they are pressed, rather than turning blue. In a dark window they
  are a deeper purple, so their white labels read clearly.
- Quick open, the pickers and the prompts fade in from just above where
  they settle, and so do find and the peek of a change. Their shadows are
  lighter in a light window.
- The explorer of a window without a folder looks like source control's
  empty views, with a button to open one.

## 0.3.1

- Built with MyGo 0.4.1: a select or combobox list no longer jumps back
  to its highlighted option while you scroll it, and text an input method
  is composing keeps its highlighting.
- The disk images and Windows installers of a release are named
  `Mayoi.<version>.<arch>.dmg` and `Mayoi.Setup.<version>.<arch>.exe`.

## 0.3.0

- **View → Vim Mode** edits with vim's keys: normal, insert and visual
  modes, motions, operators and text objects with counts, `.` to repeat,
  and yanks and pastes through the system clipboard. The status bar shows
  the mode, and normal mode shows a block cursor.
- **View → Sidebar on Right** moves the sidebar, and its button in the
  title bar, to the right of the editors.

## 0.2.1

- Source control lists the last commits of the branch, with those not yet
  pushed marked. Click one to see its message and its changes in a tab of
  its own; its menu copies the hash or the message.
- The commit button says what it will do (**Commit**, **Commit All**,
  **Amend Commit**), and its menu has Commit & Push, Amend and the new
  **Undo Last Commit**, which keeps the changes staged and the message.
- **Switch Branch…** finds a branch by name among the local ones and the
  remotes', the one committed to last first, with its last commit, and
  creates a branch of the name typed. The branch at the top of source
  control opens it, and the pull and push buttons beside it show how many
  commits they would move. A branch with no upstream gets **Publish
  Branch**.
- **View as Tree**, in the **⋯** menu of source control, lists the changes
  under their folders, which stage, unstage or discard all they hold.
- A clean work tree says so, and offers to push or pull when the branch is
  ahead or behind. A folder outside a repository explains itself.
- The summary line of a commit message shows its length past 50
  characters, in a warning color past 72.
- A thin bar under the title moves while a Git command runs, and a toast
  says when a commit, push or pull is done. The commit's toast has an
  **Undo** button.
- Stage, unstage or discard one change at a time from the Changes tab:
  point at a run of changes for its buttons, or press `s` on a line.
- A file's header stays at the top of the diff as you scroll through it.
- Diff headers show the file's icon, a badge of its state, where a renamed
  file came from, and a bar of the lines added and removed. Folded lines
  read "Show N unchanged lines" and light up under the pointer.
- Source control and the Changes tab stay quick with thousands of changed
  files: an idle frame of 2,000 changes went from 0.39 ms to 0.22 ms and
  allocates a tenth as much, and reading the status again when nothing
  changed no longer lays the diff out again.
- **File → Open Recent** lists the folders opened last, but the window's
  and those not on the disk, with **Clear Recently Opened**. ⌃R, or
  **More…**, finds one by name: ⏎ opens it in the window, ⌘⏎ in a new
  one. A terminal keeps ⌃R for its shell. On macOS the Dock icon's menu
  lists them too.

## 0.2.0

- Source control: the sidebar lists the files changed, staged and not, to
  stage, unstage, discard and commit, with Commit & Push and Amend.
- Diffs open in a tab, in one column or side by side, with the words that
  changed tinted, and follow the file as you type.
- Diffs fold the unchanged lines away from the changes, head each change
  with its `@@` line and the block it is in, wrap long lines, and go side
  by side when there is room.
- Every file changed shows in one **Changes** tab, staged and not, each
  under a header that folds it, stages it or discards it. Clicking a file
  in source control scrolls the tab to it.
- In a diff, `j`/`k`, `]`/`[`, `.`/`,`, Space, `g`/`G` and `z` move about as
  in a pager.
- Click a gutter mark to see what the lines were, and revert or stage that
  change alone. ⌥F5 goes to the next change.
- The Explorer shows each changed file's letter and color.
- The branch in the status bar switches and creates branches, says how far
  it is ahead and behind, and fetches, pulls and pushes.
- The caret's line shows who changed it last.
- ⇧⌘T (**File → Reopen Closed Tab**) reopens the last tab closed, where it
  was and scrolled as it was. Terminals come back as a new shell.
- Highlighting keeps up with typing: after a keystroke only the lines around
  the edit are lexed again, under 1 ms in a 6,000-line file where the whole
  file took 170 ms, and lines an edit moves keep their colors meanwhile.
- A large file opened shows the colors of the lines in view first.
- The tab strip has an edge along its bottom, which the tab shown breaks.
- Line numbers are easier to read, the find and replace fields line up, and
  the status bar says "1 line", names languages consistently, and shows a
  terminal's folder and size.

## 0.1.0

- The first release: tabs, columns, the file tree, quick open, find and
  replace, Git marks, a terminal, an image viewer and auto save.
- Mayoi updates itself from GitHub Releases, from **Mayoi → Check for
  Updates…** or in the background once a day.
