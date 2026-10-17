package main

import (
	"github.com/egoist/mygo/ui"

	"mayoi/internal/highlight"
	"mayoi/internal/linediff"
	"mayoi/internal/settings"
)

const (
	minimapRowH  = 2 // a line's height in the minimap
	minimapCharW = 1 // a column's width
	minimapPadL  = 6 // left of the text, where the Git marks go
	// minimapRoom is how wide the text of an editor stays, at least, beside
	// its minimap: narrower, the minimap goes.
	minimapRoom = 320
)

// minimapState is what an editor's minimap keeps between frames: whether
// it showed, and the drag of its slider.
type minimapState struct {
	shown bool
	// dragging is set while the pointer pressing the minimap moves the
	// slider, and grab is where on the slider it holds it.
	dragging bool
	grab     float32
	// paths are the blocks of the text in each color, made anew as it
	// paints, kept for their memory.
	paths map[ui.Color]*ui.Path
}

// minimapGeo places the document in a minimap viewH high, as VS Code's: at
// a line every minimapRowH, and when it is taller than the minimap, the
// minimap scrolls with the editor, so that its top shows at the top and
// its end at the end. The slider is the part of it the editor shows.
type minimapGeo struct {
	k       float32 // the minimap's DIPs to a DIP of the editor's content
	top     float32 // how far the minimap is scrolled
	end     float32 // how far the editor scrolls
	sliderY float32
	sliderH float32
	// travel is how far the slider goes, as the editor scrolls from its
	// top to its end.
	travel float32
}

func minimapGeom(g geometry, scrollY, viewH float32) minimapGeo {
	k := minimapRowH / g.lineH
	content := 2*editorPadY + g.height()
	m := minimapGeo{k: k, end: max(0, content-viewH), sliderH: viewH * k}
	if over := content*k - viewH; over > 0 && m.end > 0 {
		m.travel = viewH - m.sliderH
		m.top = scrollY / m.end * over
	} else {
		m.travel = m.end * k
	}
	m.sliderY = scrollY*k - m.top
	return m
}

// scrollFor returns how far the editor scrolls for the slider's top to be
// at y.
func (m minimapGeo) scrollFor(y float32) float32 {
	if m.travel <= 0 {
		return 0
	}
	return clamp(y*m.end/m.travel, 0, m.end)
}

// lines returns the first and last lines of the document the minimap
// shows, viewH high.
func (m minimapGeo) lines(g geometry, viewH float32) (first, last int) {
	return g.at(m.top/m.k - editorPadY), g.at((m.top+viewH)/m.k - editorPadY)
}

// toggleMinimap shows the editors' minimaps, or hides them.
func (a *app) toggleMinimap() {
	a.settings.Minimap = !a.settings.Minimap
	a.settings.Changed()
	a.invalidate()
}

// showsMinimap reports whether an editor viewW wide, as the last frame
// laid it out, has its minimap.
func (a *app) showsMinimap(d *editor, viewW float32) bool {
	if !a.settings.Minimap {
		return false
	}
	if d.mini.shown {
		viewW += a.settings.MinimapWidth
	}
	return viewW == 0 || viewW >= a.settings.MinimapWidth+minimapRoom
}

// minimapView is the minimap along the right of an editor: each line of
// the document in blocks of its colors, the lines changed since the last
// commit, the selection, and the slider over the lines in view. A click
// scrolls there, a drag moves the slider, the wheel scrolls the editor,
// and the handle along its left edge makes it wider or narrower.
func (a *app) minimapView(c *ui.Context, d *editor, g geometry, viewH float32) {
	p, s := a.pal, a.settings
	width := s.MinimapWidth
	ui.Box(c.Key("minimap")).Absolute().Top(0).Right(0).Bottom(0).Width(width).Children(func() {
		box := ui.Box(c).Absolute().Top(0).Left(0).Right(0).Bottom(0).Background(p.editor).Label("Minimap")
		m := minimapGeom(g, d.vscroll.Y, viewH)
		_, y, over := box.PointerPosition()
		box.Dragged()
		switch pressed := box.Pressed(); {
		case pressed && !d.mini.dragging:
			// On the slider, it holds it where it is; elsewhere, it brings
			// the slider's middle there.
			d.mini.dragging, d.mini.grab = true, m.sliderH/2
			if y >= m.sliderY && y < m.sliderY+m.sliderH {
				d.mini.grab = y - m.sliderY
			}
			fallthrough
		case pressed:
			d.vscroll.Y = m.scrollFor(y - d.mini.grab)
			m = minimapGeom(g, d.vscroll.Y, viewH)
		default:
			d.mini.dragging = false
		}
		box.HandleInput(func(ev ui.InputEvent) bool {
			if ev.Kind != ui.InputScroll {
				return false
			}
			d.vscroll.Y = clamp(d.vscroll.Y+ev.DY, 0, minimapGeom(g, d.vscroll.Y, viewH).end)
			return true
		})
		slider := p.text.Alpha(0.07)
		switch {
		case d.mini.dragging:
			slider = p.text.Alpha(0.16)
		case over:
			slider = p.text.Alpha(0.11)
		}
		box.Draw(func(pt *ui.Painter, r ui.Rect) {
			a.paintMinimap(pt, r, d, g, slider)
		})
		a.splitter(c, edgeLeft, func(dx float32) {
			s.MinimapWidth = clamp(width-dx, settings.MinMinimapWidth, settings.MaxMinimapWidth)
		})
	})
}

func (a *app) paintMinimap(pt *ui.Painter, r ui.Rect, d *editor, g geometry, slider ui.Color) {
	p := a.pal
	snap := d.buf.Snapshot()
	m := minimapGeom(g, d.vscroll.Y, r.H)
	first, last := m.lines(g, r.H)
	lineY := func(i int) float32 { return r.Y + (editorPadY+g.top(i))*m.k - m.top }
	cols := int((r.W - minimapPadL) / minimapCharW)

	// The selection, over the whole width of its lines.
	if sel := d.sel; sel[0] != sel[1] {
		n := snap.Len()
		from, to := snap.LineAt(min(sel[0], sel[1], n)), snap.LineAt(min(max(sel[0], sel[1]), n))
		for i := max(from, first); i <= min(to, last); i++ {
			pt.Fill(ui.Rect{X: r.X, Y: lineY(i), W: r.W, H: minimapRowH}, p.selection, 0)
		}
	}

	// The text: a block for each run of a color, between blanks.
	if d.mini.paths == nil {
		d.mini.paths = map[ui.Color]*ui.Path{}
	}
	for _, path := range d.mini.paths {
		path.Reset()
	}
	block := func(col ui.Color, x0, x1 int, y float32) {
		path := d.mini.paths[col]
		if path == nil {
			path = &ui.Path{}
			d.mini.paths[col] = path
		}
		l, rt := r.X+minimapPadL+float32(x0)*minimapCharW, r.X+minimapPadL+float32(x1)*minimapCharW
		path.MoveTo(l, y).LineTo(rt, y).LineTo(rt, y+minimapRowH-0.5).LineTo(l, y+minimapRowH-0.5).Close()
	}
	lexed := d.hl != nil && d.hl.Lexer() != nil
	for i := first; i <= last; i++ {
		s, e := snap.LineRange(i)
		var toks []highlight.Token
		if lexed && e-s <= highlight.MaxLineRunes {
			toks = d.hl.Line(i, snap.Slice(s, e))
		}
		text := snap.Slice(s, min(e, s+cols))
		y := lineY(i)
		col, k, from := 0, 0, -1
		var runCol ui.Color
		n := 0 // the rune of text
		for _, ch := range text {
			for k < len(toks) && toks[k].End <= n {
				k++
			}
			c := p.text
			if k < len(toks) && toks[k].Start <= n {
				c = p.syntax[toks[k].Kind]
			}
			blank := ch == ' ' || ch == '\t'
			if from >= 0 && (blank || c != runCol) {
				block(runCol, from, col, y)
				from = -1
			}
			if !blank && from < 0 {
				from, runCol = col, c
			}
			if ch == '\t' {
				col = (col/tabWidth + 1) * tabWidth
			} else {
				col++
			}
			n++
			if col >= cols {
				break
			}
		}
		if from >= 0 {
			block(runCol, from, min(col, cols), y)
		}
	}
	for col, path := range d.mini.paths {
		pt.FillPath(path, col.Alpha(0.75))
	}

	// The lines changed since the last commit, along the left edge.
	marks := d.git.Lines
	for i := first; i <= min(last, len(marks)-1); i++ {
		y := lineY(i)
		switch marks[i] {
		case linediff.Added:
			pt.Fill(ui.Rect{X: r.X + 1, Y: y, W: 2, H: minimapRowH}, p.added, 0)
		case linediff.Modified:
			pt.Fill(ui.Rect{X: r.X + 1, Y: y, W: 2, H: minimapRowH}, p.changed, 0)
		case linediff.Deleted:
			pt.Fill(ui.Rect{X: r.X + 1, Y: y - 1, W: 3, H: 2}, p.removed, 0)
		case linediff.DeletedBelow:
			pt.Fill(ui.Rect{X: r.X + 1, Y: y + minimapRowH - 1, W: 3, H: 2}, p.removed, 0)
		}
	}

	pt.Fill(ui.Rect{X: r.X, Y: r.Y + m.sliderY, W: r.W, H: max(m.sliderH, 4)}, slider, 0)
}
