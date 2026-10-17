package main

import (
	"fmt"
	"strings"

	"github.com/egoist/mygo/ui"
)

// conflict is a block of conflict markers a merge left in a file, by its
// lines: <<<<<<< at start, ||||||| at base (-1 without a common
// ancestor's section, as diff3 writes it), ======= at mid and >>>>>>> at
// end. current and incoming are what the markers name, as "HEAD" and the
// branch merged.
type conflict struct {
	start, base, mid, end int
	current, incoming     string
}

// conflictSide is the side of a conflict, or both, that resolving it
// keeps.
type conflictSide int

const (
	keepCurrent conflictSide = iota
	keepIncoming
	keepBoth
)

// parseConflicts finds the blocks of conflict markers among the n lines
// line returns. A block that does not close, or whose markers come out of
// order, is left out.
func parseConflicts(n int, line func(i int) string) []conflict {
	var out []conflict
	cf := conflict{start: -1, base: -1, mid: -1}
	label := func(s, marker string) string { return strings.TrimSpace(strings.TrimPrefix(s, marker)) }
	for i := range n {
		s := line(i)
		if len(s) < 7 {
			continue
		}
		switch {
		case isMarker(s, "<<<<<<<"):
			cf = conflict{start: i, base: -1, mid: -1, current: label(s, "<<<<<<<")}
		case cf.start < 0:
		case isMarker(s, "|||||||") && cf.base < 0 && cf.mid < 0:
			cf.base = i
		case isMarker(s, "=======") && cf.mid < 0 && strings.TrimRight(s, " \t\r") == "=======":
			cf.mid = i
		case isMarker(s, ">>>>>>>") && cf.mid >= 0:
			cf.end, cf.incoming = i, label(s, ">>>>>>>")
			out = append(out, cf)
			cf = conflict{start: -1, base: -1, mid: -1}
		}
	}
	return out
}

// isMarker reports whether s is a line of the marker: the marker alone, or
// followed by a space and a label.
func isMarker(s, marker string) bool {
	if !strings.HasPrefix(s, marker) {
		return false
	}
	rest := s[len(marker):]
	return rest == "" || rest[0] == ' ' || rest[0] == '\t' || rest[0] == '\r'
}

// lines returns the lines of the conflict that resolving it keeps, of the
// n lines line returns.
func (cf conflict) lines(side conflictSide, line func(i int) string) []string {
	var out []string
	add := func(from, to int) {
		for i := from; i < to; i++ {
			out = append(out, line(i))
		}
	}
	currentEnd := cf.mid
	if cf.base >= 0 {
		currentEnd = cf.base
	}
	if side != keepIncoming {
		add(cf.start+1, currentEnd)
	}
	if side != keepCurrent {
		add(cf.mid+1, cf.end)
	}
	return out
}

// edit is the edit of a snapshot that resolves the conflict, keeping side.
func (cf conflict) edit(snap ui.TextSnapshot, side conflictSide) textEdit {
	keep := cf.lines(side, snap.Line)
	s, _ := snap.LineRange(cf.start)
	_, e := snap.LineRange(cf.end)
	if len(keep) > 0 {
		return textEdit{s, e, strings.Join(keep, "\n")}
	}
	// Nothing kept: the lines go with their newline.
	if cf.end+1 < snap.LineCount() {
		e, _ = snap.LineRange(cf.end + 1)
	} else if cf.start > 0 {
		_, s = snap.LineRange(cf.start - 1)
		e = snap.Len()
	}
	return textEdit{s, e, ""}
}

// editorConflicts returns the conflicts of an editor's text, while Git
// says its file is in conflict, finding them again as the text changes.
func (a *app) editorConflicts(d *editor) []conflict {
	snap := d.buf.Snapshot()
	on := d.path != "" && a.git.entries[d.path].Conflicted()
	cc := &d.conflicts
	if cc.on == on && cc.version == snap.Version() && cc.read {
		return cc.list
	}
	cc.on, cc.version, cc.read, cc.list = on, snap.Version(), true, nil
	if on {
		cc.list = parseConflicts(snap.LineCount(), snap.Line)
	}
	return cc.list
}

// conflictCache is the conflicts an editor found in a version of its
// text.
type conflictCache struct {
	on, read bool
	version  uint64
	list     []conflict
}

// conflictAt returns the conflict around line, or -1.
func conflictAt(cs []conflict, line int) int {
	for k, cf := range cs {
		if line >= cf.start && line <= cf.end {
			return k
		}
	}
	return -1
}

// resolveConflict resolves the conflict at k, keeping side, as a step of
// undo.
func (a *app) resolveConflict(d *editor, k int, side conflictSide) {
	cs := a.editorConflicts(d)
	if k < 0 || k >= len(cs) {
		return
	}
	snap := d.buf.Snapshot()
	e := cs[k].edit(snap, side)
	d.edit([2]int{e.start, e.start}, e)
	a.conflictsResolved(d)
}

// resolveAllConflicts resolves every conflict of the file, keeping side,
// as one step of undo.
func (a *app) resolveAllConflicts(d *editor, side conflictSide) {
	cs := a.editorConflicts(d)
	if len(cs) == 0 {
		a.fail("%s has no conflicts.", d.name())
		return
	}
	snap := d.buf.Snapshot()
	edits := make([]textEdit, len(cs))
	for k, cf := range cs {
		edits[k] = cf.edit(snap, side)
	}
	at := edits[0].start
	d.edit([2]int{at, at}, edits...)
	a.conflictsResolved(d)
}

// resolveCaretConflict resolves the conflict around the caret, keeping
// side.
func (a *app) resolveCaretConflict(d *editor, side conflictSide) {
	cs := a.editorConflicts(d)
	k := conflictAt(cs, caretLine(d))
	if k < 0 {
		a.fail("No conflict at the caret.")
		return
	}
	a.resolveConflict(d, k, side)
}

// conflictsResolved offers to stage the file once its last conflict is
// resolved, saving it first.
func (a *app) conflictsResolved(d *editor) {
	if len(a.editorConflicts(d)) > 0 || d.path == "" {
		return
	}
	doc, path := d.document, d.path
	a.tell(note{message: "No conflicts left in " + d.name(), label: "Stage", action: func() {
		a.saveDoc(doc, func() { a.stage(path) })
	}})
}

// stepConflict moves the caret to the next conflict after it, or the
// previous one before it, around the file.
func (a *app) stepConflict(d *editor, step int) {
	cs := a.editorConflicts(d)
	if len(cs) == 0 {
		a.fail("%s has no conflicts.", d.name())
		return
	}
	line := caretLine(d)
	k := -1
	if step > 0 {
		for i, cf := range cs {
			if cf.start > line {
				k = i
				break
			}
		}
		if k < 0 {
			k = 0
		}
	} else {
		for i := len(cs) - 1; i >= 0; i-- {
			if cs[i].end < line {
				k = i
				break
			}
		}
		if k < 0 {
			k = len(cs) - 1
		}
	}
	a.jumpToScope(d, cs[k].start)
}

// conflictColors are the tints of a conflict's lines: of its current side
// and its markers, and of its incoming side and its markers.
func (a *app) conflictColors() (current, currentMark, incoming, incomingMark ui.Color) {
	p := a.pal
	return p.added.Alpha(0.10), p.added.Alpha(0.24), p.accent.Alpha(0.10), p.accent.Alpha(0.24)
}

// conflictBands calls fn with each run of lines of the conflicts from
// first to last and its tint: the markers stronger than the sides, and a
// common ancestor's section faint.
func (a *app) conflictBands(cs []conflict, first, last int, fn func(from, to int, col ui.Color)) {
	cur, curMark, inc, incMark := a.conflictColors()
	base := a.pal.faint.Alpha(0.10)
	for _, cf := range cs {
		if cf.end < first || cf.start > last {
			continue
		}
		currentEnd := cf.mid
		if cf.base >= 0 {
			currentEnd = cf.base
		}
		fn(cf.start, cf.start, curMark)
		fn(cf.start+1, currentEnd-1, cur)
		if cf.base >= 0 {
			fn(cf.base, cf.mid-1, base)
		}
		fn(cf.mid, cf.mid, base)
		fn(cf.mid+1, cf.end-1, inc)
		fn(cf.end, cf.end, incMark)
	}
}

// conflictActionsView shows, on the line of each conflict's <<<<<<< in
// view, the buttons that resolve it, as VS Code's code lenses do.
func (a *app) conflictActionsView(c *ui.Context, d *editor) {
	cs := a.editorConflicts(d)
	if len(cs) == 0 {
		return
	}
	p, f := a.pal, a.font
	n := d.buf.Snapshot().LineCount()
	g := a.geometry(d, n)
	view := d.hscroll.Bounds(c)
	stuck := float32(len(d.sticky)) * f.lineH
	for _, cf := range cs {
		y := editorPadY + g.top(cf.start) - d.vscroll.Y
		if y < stuck || y > view.H-f.lineH {
			continue
		}
		bar := ui.Row(c.Key(fmt.Sprintf("conflict:%d", cf.start))).Absolute().Top(y).Right(18).Height(f.lineH).Gap(2).
			AlignItems(ui.Center).Role(ui.RoleToolbar).Label("Conflict")
		bar.Children(func() {
			button := func(label, tip string, side conflictSide) {
				b := ui.ButtonBase(c.Key(label)).Height(max(f.lineH-2, 16)).Padding(0, 7).Radius(4).AlignItems(ui.Center).
					Background(p.chrome).BorderWidth(1, 1, 1, 1).BorderColor(p.border).Label(label).Tooltip(tip)
				col := p.muted
				if b.Hovered() {
					b.Background(p.hover)
					col = p.text
				}
				b.Children(func() { ui.Text(c, label).FontSize(11.5).TextColor(col).SingleLine() })
				if b.Clicked() {
					// By its first line, as the conflicts are found again.
					start := cf.start
					a.queueEdit(d, func(d *editor) { a.resolveConflict(d, conflictAt(a.editorConflicts(d), start), side) })
				}
			}
			button("Accept Current", "Keep "+orWord(cf.current, "the current change"), keepCurrent)
			button("Accept Incoming", "Keep "+orWord(cf.incoming, "the incoming change"), keepIncoming)
			button("Accept Both", "Keep both changes, the current first", keepBoth)
		})
	}
}

// orWord returns s, or else what when s is empty.
func orWord(s, what string) string {
	if s == "" {
		return what
	}
	return s
}
