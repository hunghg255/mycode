// Every feature group shown on the site. The text follows docs/FEATURES.md;
// keep the two in step when a feature changes.

import changePeek from '../screenshots/change-peek.png'
import columns from '../screenshots/columns.png'
import commandPalette from '../screenshots/command-palette.png'
import commits from '../screenshots/commits.png'
import markdownPreview from '../screenshots/markdown-preview.png'
import projectTabs from '../screenshots/project-tabs.png'
import scmDiffSplit from '../screenshots/scm-diff-split.png'
import search from '../screenshots/search.png'
import terminalTab from '../screenshots/terminal-tab.png'
import themeMatrix from '../screenshots/theme-matrix.png'

export type Shot = { src: string; alt: string; caption: string }

export type Feature = { title: string; text: string }

export type Group = {
  id: string
  title: string
  icon: string
  lead: string
  features: Feature[]
  shots?: Shot[]
}

export const groups: Group[] = [
  {
    id: 'editor',
    title: 'Editor',
    icon: '⌨',
    lead: 'Tabs, line numbers, a highlighted caret line and Chroma syntax highlighting. Files changed on disk reload unless you have unsaved edits.',
    features: [
      {
        title: 'Preview tabs',
        text: 'A file clicked in the Explorer or search opens in a preview tab, its name in italics, so looking through files leaves one tab. Editing it or double-clicking it keeps it open.',
      },
      {
        title: 'Reopen closed tabs',
        text: '⇧⌘T reopens the last tab you closed, in its column and place, with its caret and scroll position. Terminals come back as a new shell in their folder.',
      },
      {
        title: 'Minimap',
        text: 'The whole file, small, in its colors, with the lines changed since the last commit and the selection. Click or drag the slider to scroll; drag its left edge to resize it.',
      },
      {
        title: 'Word wrap',
        text: '**View → Word Wrap** wraps long lines at the edge of the editor. ⌥Z toggles wrapping for the current tab only.',
      },
      {
        title: 'Auto save',
        text: 'A changed file saves one second after the last edit, when its column switches tab, or when the window loses focus. Untitled files wait for ⌘S.',
      },
      {
        title: 'Per-tab undo',
        text: 'Undo covers the app’s edits as well as typing: indenting, moving lines, replacing and reloading from disk. Undoing back to the saved text marks the tab clean.',
      },
    ],
  },
  {
    id: 'editing',
    title: 'Smart editing',
    icon: '✎',
    lead: 'The small things that keep your hands on the keyboard.',
    features: [
      { title: 'Indentation', text: 'Tab and ⇧Tab indent and outdent with tabs or spaces to match the file. Enter keeps the indent, and indents one more level after an opening bracket.' },
      { title: 'Brackets and quotes', text: 'They close themselves, wrap a selection, and are stepped over when typed again.' },
      { title: 'Line commands', text: 'Comment lines (⌘/), move (⌥↑ ⌥↓), copy (⇧⌥↑ ⇧⌥↓) and delete lines (⇧⌘K), and insert a line above or below (⇧⌘↵, ⌘↵).' },
      { title: 'Status bar', text: 'Shows the file’s indentation and line endings, and changes either with a click.' },
      { title: 'Sort and transform', text: '**Sort Lines Ascending**, **Sort Lines Descending** and **Transform to Camel Case** work on the selection or the whole file.' },
    ],
  },
  {
    id: 'reading',
    title: 'Reading aids',
    icon: '◎',
    lead: 'See the shape of the code at a glance.',
    features: [
      { title: 'Indent guides', text: 'With the caret’s block drawn brighter.' },
      { title: 'Bracket matching', text: 'The bracket matching the one at the caret is boxed, and ⇧⌘\\ jumps to it.' },
      { title: 'Word highlights', text: 'Other occurrences of the word at the caret are highlighted.' },
      { title: 'Selection', text: 'Rounded corners, visible spaces and tabs, and it stays visible, dimmed, while the keyboard is elsewhere.' },
      { title: 'Sticky scroll and breadcrumbs', text: 'The lines that open the blocks in view stay pinned at the top, and breadcrumbs name the blocks around the caret. Click either to jump.' },
      { title: 'Overview ruler', text: 'A strip along the right edge shows Git changes, find matches and the caret position for the whole file.' },
    ],
  },
  {
    id: 'columns',
    title: 'Columns',
    icon: '▥',
    lead: 'Split the editor side by side and drag tabs between columns. A file in several columns shares its text and undo history, each keeping its own caret and scroll.',
    features: [
      { title: 'Drag and drop', text: 'Drag a tab along its strip, into another column, or to the edge of a column to make a new one. Files dropped from the Finder open where you drop them.' },
      { title: 'Locked columns', text: '**Lock Column** keeps a column for terminals; files opened from the Explorer, Search or Quick Open go to an unlocked column.' },
      { title: 'Move terminal to the right', text: '**Move to Locked Right Column** moves a running terminal there in one step.' },
    ],
    shots: [{ src: columns, alt: 'Two columns of Go source', caption: 'Two columns of Go source side by side' }],
  },
  {
    id: 'navigation',
    title: 'Quick open & search',
    icon: '⌕',
    lead: 'Find any file, symbol, line or command in a few keystrokes.',
    features: [
      { title: 'Quick open', text: '⌘P opens a fuzzy file search, recent files first. In a Git work tree it lists the files Git tracks, so build output stays out.' },
      { title: 'Go to line and symbol', text: 'Type `:42` to go to line 42, or `@` to list the file’s functions, types and headings.' },
      { title: 'Command palette', text: 'Type `>` or press ⇧⌘P to run any command by name, with its menu, its shortcut and a check when it is on.' },
      { title: 'Find and replace', text: '⌘F and ⌥⌘F, with match case, whole word and regular expressions. Large files are searched in the background.' },
      { title: 'Search in files', text: '⇧⌘F searches every file as you type, with files to include and exclude (`*.go, web/**`). Unsaved edits are searched as they are in the editor.' },
      { title: 'Replace in files', text: '⇧⌘H shows each match struck out with its replacement. Replace one match, one file, or all; open files change as one step of undo.' },
    ],
    shots: [
      { src: commandPalette, alt: 'The command palette', caption: 'Every command by name, with its shortcut' },
      { src: search, alt: 'Search across the folder’s files', caption: 'Search in files, each match in context' },
    ],
  },
  {
    id: 'explorer',
    title: 'Explorer',
    icon: '▤',
    lead: 'A lazy file tree that follows the disk, with Git-ignored files shown faint.',
    features: [
      { title: 'File operations', text: 'Create, rename, trash and reveal files, and New File, New Folder, Refresh and Collapse Folders on the folder’s row.' },
      { title: 'Git status', text: 'A changed file shows its letter (M, A, D, U, C) and its name in a color; a folder with changes inside gets a dot.' },
      { title: 'File icons', text: 'Material Icon Theme icons, as in VS Code, or Lucide ones, from **View → File Icon Theme**.' },
      { title: 'Hide files', text: 'The `filesExclude` setting hides files by glob patterns from the explorer, quick open and search.' },
    ],
  },
  {
    id: 'git',
    title: 'Source control',
    icon: '⎇',
    lead: 'Stage, commit, amend, undo, pull and push without leaving the editor. Git runs as the `git` CLI, using your SSH agent and credential helper.',
    features: [
      { title: 'Changes view', text: 'Files grouped as merge changes, staged changes, changes and untracked, as a list or a tree. Select several and stage, unstage or discard them at once.' },
      { title: 'Commit', text: 'Write a message and press ⌘↵. **Commit & Push**, **Amend Last Commit** and **Undo Last Commit**, which keeps the changes staged.' },
      { title: 'Gutter marks', text: 'Lines added, changed or removed since the last commit. Click a mark to peek the lines at HEAD, then revert or stage just those lines.' },
      { title: 'Inline blame', text: 'The caret’s line shows who changed it last, when, and the commit’s summary.' },
      { title: 'Commit graph', text: 'The last commits on a graph of their branches, with tags, HEAD and unpushed commits marked. Click one to see its changes in a tab.' },
      { title: 'Branches', text: '**Switch Branch…**, create, **Rename Branch…** and **Delete Branch…**, with an **Undo** that brings a deleted branch back.' },
      { title: 'Pull, push and sync', text: '**Pull (Rebase)** or **Pull (Merge)** when diverged, **Force Push…** with `--force-with-lease`, and **Sync**, which pulls then pushes.' },
      { title: 'Stash', text: 'Stash with or without untracked files, then apply, pop, view or drop entries from a searchable box.' },
      { title: 'Merge conflicts', text: 'Each conflict block is tinted, with **Accept Current**, **Accept Incoming** and **Accept Both** on its first line, and a toast that stages the file once resolved.' },
    ],
    shots: [
      { src: changePeek, alt: 'A change peeked from the gutter', caption: 'Peek a change from the gutter, then revert or stage it' },
      { src: commits, alt: 'The commit graph and a commit’s diff', caption: 'The commit graph, with branches, tags and merges' },
    ],
  },
  {
    id: 'diffs',
    title: 'Diffs & review',
    icon: '±',
    lead: 'Every changed file in one Changes tab, folded around the changes, inline or side by side, with changed words tinted.',
    features: [
      { title: 'One tab for all changes', text: 'Staged changes first, then the rest, each file under a header with its lines added and removed. Files are read as they come near the view.' },
      { title: 'Hunk staging', text: 'Point at a run of changes to stage, unstage or discard it alone. MyCode reads the index and the file again first.' },
      { title: 'Split or inline', text: 'Side by side, one column, or side by side when each side has room for 80 columns, which is the default.' },
      { title: 'Pager keys', text: '`j` `k` move, `]` `[` go from change to change, `.` `,` from file to file, `s` stages, `e` opens the file at the line.' },
      { title: 'Review comments', text: 'Choose lines and press `c`, or ⇧⌘M in a file, to comment. Comments follow their lines as the file changes.' },
      { title: 'Send to the agent', text: '**Send Review Comments to Terminal** pastes every comment, with its path, line numbers and lines, into the terminal used last, for the agent there.' },
    ],
    shots: [{ src: scmDiffSplit, alt: 'Source control with a side-by-side diff', caption: 'A side-by-side diff with changed words tinted' }],
  },
  {
    id: 'terminal',
    title: 'Terminal',
    icon: '❯',
    lead: 'Ghostty’s emulator (libghostty-vt), in the bottom panel or in a column tab. Its colors follow the theme.',
    features: [
      { title: 'Panel or tab', text: 'Run several terminals, move one between the panel and a column by dragging it, and maximize the panel.' },
      { title: 'Profiles', text: 'PowerShell, Command Prompt, Git Bash, WSL, the shells of `/etc/shells`, or your own in `terminalProfiles`.' },
      { title: 'Open file paths', text: 'Ctrl+click (⌘-click on macOS) on `src/app.go:12:5` opens the file at its line and column; links open in the browser.' },
      { title: 'Made for agents', text: 'Dropped files type their quoted paths, and ⌘V with an image on the clipboard lets Claude Code paste the screenshot.' },
      { title: 'Copy on select', text: 'Selecting text copies it, as in Ghostty and iTerm2: a drag, a double click for a word, a triple click for a line.' },
      { title: 'Bell marks', text: 'A terminal out of sight that rings its bell or sends a notification marks its project in the accent color.' },
    ],
    shots: [{ src: terminalTab, alt: 'A terminal in a column beside the code', caption: 'A terminal in a tab, beside the code' }],
  },
  {
    id: 'previews',
    title: 'Previews & images',
    icon: '▣',
    lead: 'A live preview of Markdown and SVG beside the source, and a viewer for images.',
    features: [
      { title: 'Markdown preview', text: '⇧⌘V shows headings, links, nested and task lists, quotes, highlighted code, tables and local images. Split with ⌘\\ for a live preview.' },
      { title: 'SVG preview', text: 'An SVG opens as text; ⇧⌘V shows it as an image that updates as you type.' },
      { title: 'Image viewer', text: 'PNG, JPEG, GIF, WebP and BMP, fitted on a checkerboard. ⌘= and ⌘- zoom, double-click toggles actual size, drag to pan.' },
    ],
    shots: [{ src: markdownPreview, alt: 'A Markdown file and its preview', caption: 'Markdown, live beside the source' }],
  },
  {
    id: 'windows',
    title: 'Windows & projects',
    icon: '◫',
    lead: 'A window per folder, or every folder in one window as project tabs.',
    features: [
      { title: 'Project tabs', text: 'A rail on the left with a square per project, a dot for unsaved changes. Each project keeps its tabs, columns, terminals and layout. ⇧⌘] and ⇧⌘[ step along it.' },
      { title: 'Project icons', text: '**View → Project Icons** shows each project’s favicon or logo instead of its initials.' },
      { title: 'Open Recent', text: '⌃R finds a recent folder by name: ↵ opens it here, ⌘↵ in a new window.' },
      { title: 'The mycode command', text: '`mycode .` or `mycode <file>` from a shell. On Windows, **Open with MyCode** in File Explorer too.' },
      { title: 'Sessions', text: 'Every window reopens as you left it, with its columns, tabs, carets, selections and scroll positions.' },
    ],
    shots: [{ src: projectTabs, alt: 'Projects on a rail at the left of the window', caption: 'Every folder in one window, on a rail' }],
  },
  {
    id: 'appearance',
    title: 'Themes & settings',
    icon: '◐',
    lead: 'Light and dark, plus themes with character. Settings are JSON files applied the moment you save them.',
    features: [
      { title: 'MyCode', text: 'The default theme, following the system’s light or dark mode, or always Light or Dark.' },
      { title: 'The Matrix', text: 'Phosphor green on black, the whole window in the code’s font, with digital rain behind the welcome page.' },
      { title: 'Claude and Qoder', text: 'Each in light and dark, with Clawd or Qoduck on the welcome page and in the status bar, hopping while Git works.' },
      { title: 'settings.json', text: 'Fonts, weight, ligatures and line height for the code and the terminal, theme, auto save, word wrap, diff layout and more.' },
      { title: 'keybindings.json', text: 'In VS Code’s format, with `when` conditions, so a VS Code or Cursor file can be pasted in.' },
      { title: 'Updates', text: 'Release builds check GitHub Releases once a day, download only what changed, and verify MyCode’s signing key.' },
    ],
    shots: [{ src: themeMatrix, alt: 'The Matrix theme', caption: 'The Matrix theme' }],
  },
]

export const shortcuts: [string, string][] = [
  ['⌘P / ⇧⌘O / ⌃G', 'Quick open / go to symbol / go to line'],
  ['⇧⌘P', 'Command palette'],
  ['⌘F / ⌥⌘F / ⌘G', 'Find / replace / next match'],
  ['⇧⌘F / ⇧⌘H', 'Find in files / replace in files'],
  ['⌘S / ⇧⌘S / ⌥⌘S', 'Save / save as / save all'],
  ['⌘O / ⌥⌘O / ⌃R', 'Open folder / in a new window / open recent'],
  ['⌘N / ⌘W / ⇧⌘T', 'New file / close tab / reopen closed tab'],
  ['⌘1…9 / ⌃Tab', 'Go to tab / next tab'],
  ['⇧⌘] / ⇧⌘[ / ⌃⌘1…9', 'Next / previous / go to project'],
  ['⌘\\ / ⌥⌘→ / ⌥⌘←', 'Split right / next column / previous column'],
  ['⌘B / ⌃` / ⌃⇧`', 'Toggle sidebar / terminal panel / new terminal'],
  ['⌃⇧G', 'Source control'],
  ['⌘/', 'Toggle line comment'],
  ['⌥↑ ⌥↓ / ⇧⌥↑ ⇧⌥↓', 'Move line / copy line'],
  ['⇧⌘K / ⌘↵ / ⇧⌘↵', 'Delete line / insert below / insert above'],
  ['⌘L / ⇧⌘\\', 'Select line / go to bracket'],
  ['⌥F5 / ⇧⌥F5', 'Next / previous change'],
  ['⇧⌘M', 'Add review comment'],
  ['⌘= / ⌘- / ⌘0', 'Zoom in / out / reset'],
  ['⇧⌘V / ⌥Z', 'Toggle preview / word wrap for the tab'],
]
