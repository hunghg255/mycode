package main

import (
	"slices"
	"strings"
	"time"

	"github.com/egoist/mygo/ui"

	"mayoi/internal/git"
	"mayoi/internal/workspace"
)

// branchPicker is the box that switches branches: the branches, local and
// of the remotes, found by name, the one committed to last first, and
// the name typed, to create a branch of.
type branchPicker struct {
	open    bool
	query   string
	sel     int
	moved   bool
	loading bool
	// branches are those read when the box opened, names their names, and
	// results those the query matches.
	branches []git.Branch
	names    branchNames
	results  []workspace.Match
	shown    string // the query the results are of
	stale    bool
	// deleting has the box choose a branch to delete rather than switch
	// to: the branch checked out is left out, and no branch is created.
	deleting bool
}

// branchNames are the names of branches, local and of remotes.
type branchNames []string

// has reports whether name is a branch's, or a remote's branch's without
// the remote, as "feature" of "origin/feature", which switching to by
// name checks out.
func (ns branchNames) has(name string) bool {
	for _, n := range ns {
		if n == name {
			return true
		}
		if _, short, ok := strings.Cut(n, "/"); ok && short == name {
			return true
		}
	}
	return false
}

// openBranchPicker shows the box of the branches, reading them in the
// background.
func (a *app) openBranchPicker() { a.openBranchBox(false) }

// openDeleteBranchPicker shows the box of the branches to choose one to
// delete, local or of a remote.
func (a *app) openDeleteBranchPicker() { a.openBranchBox(true) }

func (a *app) openBranchBox(deleting bool) {
	r := a.git.repo
	if r == nil {
		return
	}
	b := &a.branches
	*b = branchPicker{open: true, loading: true, deleting: deleting}
	go func() {
		bs, err := r.BranchList()
		a.post(func() {
			if !b.open || a.git.repo != r {
				return
			}
			b.loading = false
			if err != nil {
				a.gitFailed(err)
				return
			}
			// A remote's branch that a local one tracks by its name shows
			// as the local one.
			local := map[string]bool{}
			for _, br := range bs {
				if !br.Remote {
					local[br.Name] = true
				}
			}
			b.branches = slices.DeleteFunc(bs, func(br git.Branch) bool {
				_, name, _ := strings.Cut(br.Name, "/")
				return br.Remote && local[name]
			})
			// The branch checked out comes first, or, to delete, not at all.
			cur := a.branch()
			if b.deleting {
				b.branches = slices.DeleteFunc(b.branches, func(br git.Branch) bool { return !br.Remote && br.Name == cur })
			}
			current := func(br git.Branch) int { return btoi(!br.Remote && br.Name == cur) }
			slices.SortStableFunc(b.branches, func(x, y git.Branch) int { return current(y) - current(x) })
			b.names = make(branchNames, len(b.branches))
			for i, br := range b.branches {
				b.names[i] = br.Name
			}
			b.stale = true
		})
	}()
}

func (a *app) closeBranchPicker() {
	a.branches.open = false
	if a.focus != paneTerminal {
		a.focusColumn()
	}
}

// branchChoice is a row of the box: a branch, or the name typed, to
// create.
type branchChoice struct {
	create string // the name of the branch to create, "" for a branch
	at     int    // the result shown, for a branch
}

// branchChoices returns the rows of the box: the branches the query
// matches, then creating the branch typed, when the branches are read and
// it names none of them, local or of a remote.
func (a *app) branchChoices() []branchChoice {
	b := &a.branches
	var out []branchChoice
	for i := range b.results {
		out = append(out, branchChoice{at: i})
	}
	if name := strings.TrimSpace(b.query); name != "" && !b.loading && !b.deleting && validBranch(name) && !b.names.has(name) {
		out = append(out, branchChoice{create: name})
	}
	return out
}

// validBranch reports whether a name may be a branch's, as far as the
// box checks before Git does.
func validBranch(name string) bool {
	return name != "" && !strings.ContainsAny(name, " ~^:?*[\\") && !strings.HasPrefix(name, "-")
}

// chooseBranch does what a row of the box does: switches to its branch,
// or creates the branch typed from the one checked out.
func (a *app) chooseBranch(ch branchChoice) {
	b := &a.branches
	if ch.create != "" {
		a.closeBranchPicker()
		a.switchBranch(ch.create, true)
		return
	}
	if ch.at < 0 || ch.at >= len(b.results) {
		return
	}
	br := b.branches[b.results[ch.at].Index]
	a.closeBranchPicker()
	if b.deleting {
		a.deleteBranchOf(br)
		return
	}
	name := br.Name
	if br.Remote {
		// Git makes the local branch that tracks it, of the same name.
		_, name, _ = strings.Cut(br.Name, "/")
	}
	if name != a.branch() {
		a.switchBranch(name, false)
	}
}

// deleteBranchOf asks before deleting a branch of the box: a local one, or
// one of a remote on the remote.
func (a *app) deleteBranchOf(br git.Branch) {
	if br.Remote {
		a.askDeleteRemoteBranch(br.Name)
	} else {
		a.askDeleteBranch(br.Name)
	}
}

// branchPickerView shows the box of the branches while it is open.
func (a *app) branchPickerView(c *ui.Context) {
	b := &a.branches
	if !b.open {
		return
	}
	p := a.pal
	if b.stale || b.shown != b.query {
		b.results = workspace.Fuzzy(b.names, strings.TrimSpace(b.query), 200)
		if strings.TrimSpace(b.query) == "" {
			// Every branch, the one committed to last first.
			b.results = b.results[:0]
			for i := range b.names {
				b.results = append(b.results, workspace.Match{Index: i})
			}
		}
		b.shown, b.stale, b.sel = b.query, false, 0
	}
	choices := a.branchChoices()
	title, placeholder, footer := "Switch Branch", "Switch to a branch, or type a name to create one", "Type a new name to create a branch"
	if b.deleting {
		title, placeholder, footer = "Delete Branch", "Choose a branch to delete", "Remote branches are deleted on their remote"
	}
	ui.Overlay(c, func() {
		back := a.dialogBack(c, "branches")
		back.Children(func() {
			box := a.floating(c, ui.Column(c).Width(560).MaxWidthPercent(92).Margin(titleBarH+8, 0, 0, 0).Radius(10), true).Clip().
				Role(ui.RoleDialog).Label(title)
			box.Children(func() {
				ui.Row(c).Padding(10, 14).Gap(10).AlignItems(ui.Center).BorderWidth(0, 0, 1, 0).BorderColor(p.border).Children(func() {
					ui.Icon(c, iconBranch).FontSize(15).TextColor(p.muted)
					in := a.textKeys(ui.TextInputBase(c.Key("branch-input"), &b.query)).Grow(1).FontSize(14).AutoFocus().
						Placeholder(placeholder).Label(title)
					if in.Shortcut(0, ui.KeyDown) {
						b.sel, b.moved = min(b.sel+1, len(choices)-1), true
					}
					if in.Shortcut(0, ui.KeyUp) {
						b.sel, b.moved = max(b.sel-1, 0), true
					}
					if in.Submitted() && b.sel >= 0 && b.sel < len(choices) {
						a.post(func() { a.chooseBranch(choices[b.sel]) })
					}
				})
				switch {
				case len(choices) > 0:
					ui.Scroll(c.Key("branch-results")).MaxHeight(380).Padding(6).Children(func() {
						for i, ch := range choices {
							a.branchRow(c, ch, i)
						}
					})
				case b.loading:
					ui.Text(c, "Reading the branches…").FontSize(13).TextColor(p.muted).Padding(12, 16)
				default:
					ui.Text(c, "No matching branches").FontSize(13).TextColor(p.muted).Padding(12, 16)
				}
				b.moved = false
				action := "switch"
				if b.deleting {
					action = "delete"
				}
				a.quickFooter(c, false, action, footer, false)
			})
			if box.PressedOutside() || back.OverlayShortcut(0, ui.KeyEscape) {
				a.closeBranchPicker()
			}
		})
	})
}

// branchRow is a row of the box of the branches: a branch, with the
// characters the query matched in the accent color, a check by the one
// checked out, and the subject of its last commit and how long ago it was
// made; or the branch to create.
func (a *app) branchRow(c *ui.Context, ch branchChoice, i int) {
	b := &a.branches
	p := a.pal
	key, label := "create", "Create Branch "+ch.create
	var br git.Branch
	var positions []int
	if ch.create == "" {
		m := b.results[ch.at]
		br, positions = b.branches[m.Index], m.Positions
		key, label = "branch:"+br.Name, br.Name
	}
	row := ui.ButtonBase(c.Key(key)).Padding(5, 10).Gap(10).Radius(6).Justify(ui.Start).AlignItems(ui.Center).Label(label)
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
		a.post(func() { a.chooseBranch(ch) })
	}
	if ch.create == "" {
		row.ContextMenu(func(m *ui.Menu) { a.branchRowMenu(m, br) })
	}
	row.Children(func() {
		if ch.create != "" {
			ui.Icon(c, iconPlus).FontSize(14).TextColor(p.accent)
			ui.RichText(c, ui.Span{Text: "Create branch "}, ui.Span{Text: ch.create, Weight: 650}).FontSize(13).
				TextColor(p.text).SingleLine().Shrink(1)
			ui.Spacer(c)
			if from := a.branch(); from != "" {
				ui.Text(c, "from "+from).FontSize(12).TextColor(p.faint).SingleLine().Shrink(0)
			}
			return
		}
		icon, col := iconBranch, p.muted
		if br.Remote {
			icon = iconFetch
		}
		current := !br.Remote && br.Name == a.branch()
		if current {
			icon, col = iconCheck, p.accent
		}
		ui.Icon(c, icon).FontSize(14).TextColor(col)
		var spans []ui.Span
		k := 0
		for at, r := range br.Name {
			for k < len(positions) && positions[k] < at {
				k++
			}
			on := k < len(positions) && positions[k] == at
			if n := len(spans); n > 0 && (spans[n-1].Weight == 650) == on {
				spans[n-1].Text += string(r)
				continue
			}
			sp := ui.Span{Text: string(r), Color: p.text}
			if on {
				sp.Color, sp.Weight = p.accent, 650
			}
			spans = append(spans, sp)
		}
		ui.RichText(c, spans...).FontSize(13).SingleLine().Shrink(0)
		ui.Text(c, br.Subject).FontSize(12).TextColor(p.faint).SingleLine().Shrink(1).Grow(1).MinWidth(0)
		if !br.Time.IsZero() {
			ui.Text(c, shortAgo(br.Time, time.Now())).FontSize(11.5).TextColor(p.faint).SingleLine().Shrink(0)
		}
	})
}

// branchRowMenu is the menu of a branch of the box: renaming a local
// branch, and deleting any but the one checked out.
func (a *app) branchRowMenu(m *ui.Menu, br git.Branch) {
	busy := a.git.busy != ""
	current := !br.Remote && br.Name == a.branch()
	if !br.Remote && m.Item("Rename Branch…").Disabled(busy).Chosen() {
		a.post(func() { a.closeBranchPicker(); a.askRenameBranch(br.Name) })
	}
	if m.Item("Delete Branch…").Disabled(busy || current).Chosen() {
		a.post(func() { a.closeBranchPicker(); a.deleteBranchOf(br) })
	}
}
