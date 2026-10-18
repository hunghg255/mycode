package main

import (
	"path/filepath"
	"strings"
	"time"

	"github.com/egoist/mygo/ui"

	"mayoi/internal/git"
	"mayoi/internal/workspace"
)

// stashAction is what choosing an entry of the box of the stash does.
type stashAction int

const (
	stashApply stashAction = iota
	stashPop
	stashDrop
	stashView
)

// stashActionNames name the actions, as the box's footer and title say
// them.
var stashActionNames = [...]string{"apply", "pop", "drop", "view"}

// stashPicker is the box of the entries of the stash, found by message.
type stashPicker struct {
	open    bool
	action  stashAction
	query   string
	sel     int
	moved   bool
	loading bool
	list    []git.Stash
	names   []string // what the query matches: the name and the subject
	results []workspace.Match
	shown   string
	stale   bool
}

// hasChanges reports whether the work tree has changes to stash.
func (a *app) hasChanges() bool {
	st := a.git.status
	return st != nil && len(st.Entries) > 0
}

// askStash asks for the message of a stash entry, then puts the changes
// in it, the files Git does not track too with untracked.
func (a *app) askStash(untracked bool) {
	if a.git.repo == nil {
		return
	}
	if !a.hasChanges() {
		a.fail("There are no changes to stash.")
		return
	}
	title := "Stash…"
	if untracked {
		title = "Stash (Include Untracked)…"
	}
	a.prompt = &prompt{title: title, hint: "a message, or none", done: func(msg string) string {
		a.stashChanges(strings.TrimSpace(msg), untracked)
		return ""
	}}
}

// askStashChosen asks for the message of a stash entry, then puts the
// changes of the chosen files in it, or of r's alone when it is not
// chosen, as the menu of a changed file does.
func (a *app) askStashChosen(r scmRow) {
	var paths []string
	files, untracked := 0, false
	for _, e := range a.scmActionEntries(r) {
		if e.Submodule() {
			continue
		}
		files++
		paths = append(paths, entryPaths(e, true)...)
		untracked = untracked || e.Untracked()
	}
	if files == 0 {
		return
	}
	title := "Stash " + filepath.Base(r.e.Path) + "…"
	if files > 1 {
		title = "Stash " + plural(files, "File") + "…"
	}
	a.prompt = &prompt{title: title, hint: "a message, or none", done: func(msg string) string {
		a.stashChanges(strings.TrimSpace(msg), untracked, paths...)
		return ""
	}}
}

// stashChanges puts the changes in a stash entry, once the documents are
// saved: those of paths alone when it is set.
func (a *app) stashChanges(msg string, untracked bool, paths ...string) {
	if !a.docsSaved("stashing") {
		return
	}
	a.gitDo("Stashing…", func(r *git.Repo) error { return r.StashPush(msg, untracked, paths...) }, func() {
		a.tell(note{message: "Stashed the changes", label: "Pop", action: func() { a.applyStash("stash@{0}", true) }})
	})
}

// applyStash puts the changes of a stash entry back, dropping it with
// pop, once the documents are saved. Changes that conflict are left to
// resolve, and the entry kept.
func (a *app) applyStash(name string, pop bool) {
	if !a.docsSaved("applying a stash") {
		return
	}
	busy, done := "Applying "+name+"…", "Applied "+name
	if pop {
		busy, done = "Popping "+name+"…", "Popped "+name
	}
	conflicted := false
	a.gitDo(busy, func(r *git.Repo) (err error) {
		conflicted, err = r.StashApply(name, pop)
		return err
	}, func() {
		if conflicted {
			a.showSourceControl()
			a.tell(note{message: "The stash's changes conflict: resolve them, then stage them. " + name + " is kept."})
			return
		}
		a.tell(note{message: done})
	})
}

// askDropStash asks before deleting a stash entry.
func (a *app) askDropStash(s git.Stash) {
	a.confirm = &confirm{title: "Drop " + s.Name + "?", ok: "Drop", danger: true,
		message: "“" + ellipsize(s.Message(), 80) + "” is deleted, and its changes with it.",
		run: func() {
			a.gitDo("Dropping "+s.Name+"…", func(r *git.Repo) error { return r.StashDrop(s.Name) }, func() {
				a.tell(note{message: "Dropped " + s.Name})
			})
		}}
}

// viewStash shows the changes of a stash entry in a tab, as a commit's.
func (a *app) viewStash(s git.Stash) {
	r := a.git.repo
	if r == nil {
		return
	}
	go func() {
		cm, err := r.CommitInfo(s.Hash)
		a.post(func() {
			if err != nil {
				a.gitFailed(err)
				return
			}
			if cm.Subject == "" {
				cm.Subject = s.Subject
			}
			a.showCommit(cm, true)
		})
	}()
}

// latestStash calls fn with the latest stash entry, read in the
// background, or says there is none.
func (a *app) latestStash(fn func(s git.Stash)) {
	r := a.git.repo
	if r == nil {
		return
	}
	go func() {
		ss, err := r.StashList()
		a.post(func() {
			switch {
			case err != nil:
				a.gitFailed(err)
			case len(ss) == 0:
				a.fail("The stash is empty.")
			default:
				fn(ss[0])
			}
		})
	}()
}

// openStashPicker shows the box of the entries of the stash, which
// choosing one does action to, reading them in the background.
func (a *app) openStashPicker(action stashAction) {
	r := a.git.repo
	if r == nil {
		return
	}
	b := &a.stashes
	*b = stashPicker{open: true, loading: true, action: action}
	go func() {
		ss, err := r.StashList()
		a.post(func() {
			if !b.open || a.git.repo != r {
				return
			}
			b.loading = false
			if err != nil {
				b.open = false
				a.gitFailed(err)
				return
			}
			if len(ss) == 0 {
				b.open = false
				a.fail("The stash is empty.")
				return
			}
			b.list = ss
			b.names = make([]string, len(ss))
			for i, s := range ss {
				b.names[i] = s.Name + " " + s.Message()
			}
			b.stale = true
		})
	}()
}

func (a *app) closeStashPicker() {
	a.stashes.open = false
	if a.focus != paneTerminal {
		a.focusColumn()
	}
}

// doStash does an action to a stash entry.
func (a *app) doStash(s git.Stash, action stashAction) {
	switch action {
	case stashApply:
		a.applyStash(s.Name, false)
	case stashPop:
		a.applyStash(s.Name, true)
	case stashDrop:
		a.askDropStash(s)
	case stashView:
		a.viewStash(s)
	}
}

// chooseStash does the box's action to the result at i.
func (a *app) chooseStash(i int) {
	b := &a.stashes
	if i < 0 || i >= len(b.results) {
		return
	}
	s := b.list[b.results[i].Index]
	a.closeStashPicker()
	a.doStash(s, b.action)
}

// stashPickerView shows the box of the stash while it is open.
func (a *app) stashPickerView(c *ui.Context) {
	b := &a.stashes
	if !b.open {
		return
	}
	p := a.pal
	if b.stale || b.shown != b.query {
		q := strings.TrimSpace(b.query)
		b.results = workspace.Fuzzy(b.names, q, 200)
		if q == "" {
			b.results = b.results[:0]
			for i := range b.names {
				b.results = append(b.results, workspace.Match{Index: i})
			}
		}
		b.shown, b.stale, b.sel = b.query, false, 0
	}
	verb := stashActionNames[b.action]
	title := strings.ToUpper(verb[:1]) + verb[1:] + " Stash"
	ui.Overlay(c, func() {
		back := a.dialogBack(c, "stashes")
		back.Children(func() {
			box := a.floating(c, ui.Column(c).Width(560).MaxWidthPercent(92).Margin(titleBarH+8, 0, 0, 0).Radius(10), true).Clip().
				Role(ui.RoleDialog).Label(title)
			box.Children(func() {
				ui.Row(c).Padding(10, 14).Gap(10).AlignItems(ui.Center).BorderWidth(0, 0, 1, 0).BorderColor(p.border).Children(func() {
					ui.Icon(c, iconBox).FontSize(15).TextColor(p.muted)
					in := a.textKeys(ui.TextInputBase(c.Key("stash-input"), &b.query)).Grow(1).FontSize(14).AutoFocus().
						Placeholder("Choose a stash to "+verb).Label(title)
					if in.Shortcut(0, ui.KeyDown) {
						b.sel, b.moved = min(b.sel+1, len(b.results)-1), true
					}
					if in.Shortcut(0, ui.KeyUp) {
						b.sel, b.moved = max(b.sel-1, 0), true
					}
					if in.Submitted() {
						sel := b.sel
						a.post(func() { a.chooseStash(sel) })
					}
				})
				switch {
				case len(b.results) > 0:
					ui.Scroll(c.Key("stash-results")).MaxHeight(380).Padding(6).Children(func() {
						for i := range b.results {
							a.stashRow(c, i)
						}
					})
				case b.loading:
					ui.Text(c, "Reading the stash…").FontSize(13).TextColor(p.muted).Padding(12, 16)
				default:
					ui.Text(c, "No matching stashes").FontSize(13).TextColor(p.muted).Padding(12, 16)
				}
				b.moved = false
				a.quickFooter(c, false, verb, "Right-click a stash for more", false)
			})
			if box.PressedOutside() || back.OverlayShortcut(0, ui.KeyEscape) {
				a.closeStashPicker()
			}
		})
	})
}

// stashRow is a row of the box of the stash: its name, its message and
// how long ago it was made, with a menu of every action.
func (a *app) stashRow(c *ui.Context, i int) {
	b := &a.stashes
	p := a.pal
	s := b.list[b.results[i].Index]
	row := ui.ButtonBase(c.Key("stash:"+s.Hash)).Padding(5, 10).Gap(10).Radius(6).Justify(ui.Start).AlignItems(ui.Center).
		Label(s.Name + " " + s.Message())
	switch {
	case i == b.sel:
		row.Background(p.active)
	case row.Hovered():
		row.Background(p.hover)
	}
	if i == b.sel && b.moved {
		row.ScrollIntoView()
	}
	if row.Clicked() {
		a.post(func() { a.chooseStash(i) })
	}
	row.ContextMenu(func(m *ui.Menu) {
		for _, it := range []struct {
			label  string
			action stashAction
		}{{"Apply", stashApply}, {"Pop", stashPop}, {"View Changes", stashView}, {"Drop…", stashDrop}} {
			if m.Item(it.label).Disabled(a.git.busy != "").Chosen() {
				action := it.action
				a.post(func() { a.closeStashPicker(); a.doStash(s, action) })
			}
		}
	})
	row.Children(func() {
		ui.Icon(c, iconBox).FontSize(14).TextColor(p.muted)
		ui.Text(c, s.Name).FontSize(13).FontWeight(600).TextColor(p.text).SingleLine().Shrink(0)
		ui.Text(c, s.Message()).FontSize(12.5).TextColor(p.muted).SingleLine().Shrink(1).Grow(1).MinWidth(0)
		if !s.Time.IsZero() {
			ui.Text(c, shortAgo(s.Time, time.Now())).FontSize(11.5).TextColor(p.faint).SingleLine().Shrink(0)
		}
	})
}

// stashMenu has the items of the stash, for a menu's submenu.
func (a *app) stashMenu(m *ui.Menu) {
	busy := a.git.busy != ""
	changes := a.hasChanges()
	if m.Item("Stash…").Disabled(busy || !changes).Chosen() {
		a.post(func() { a.askStash(false) })
	}
	if m.Item("Stash (Include Untracked)…").Disabled(busy || !changes).Chosen() {
		a.post(func() { a.askStash(true) })
	}
	m.Separator()
	if m.Item("Apply Latest Stash").Disabled(busy).Chosen() {
		a.post(func() { a.latestStash(func(s git.Stash) { a.applyStash(s.Name, false) }) })
	}
	if m.Item("Pop Latest Stash").Disabled(busy).Chosen() {
		a.post(func() { a.latestStash(func(s git.Stash) { a.applyStash(s.Name, true) }) })
	}
	m.Separator()
	for _, it := range []struct {
		label  string
		action stashAction
	}{{"Apply Stash…", stashApply}, {"Pop Stash…", stashPop}, {"View Stash…", stashView}, {"Drop Stash…", stashDrop}} {
		if m.Item(it.label).Disabled(busy).Chosen() {
			action := it.action
			a.post(func() { a.openStashPicker(action) })
		}
	}
}
