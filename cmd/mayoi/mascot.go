package main

import (
	"time"

	"github.com/egoist/mygo/ui"
)

// A theme's character, Clawd in Claude and Qoduck in Qoder, takes the
// logo's place on the welcome page and sits at the start of the status
// bar. It blinks now and then and bobs once in a while, and while Git or
// search works in the background it hops, in place of the Git spinner.
// Like the rain, it steps rather than glides, and holds still while the
// window has not the keyboard or the desktop asks for less motion.

// mascot is a theme's character.
type mascot struct {
	name string // whose it is, as its tip says
	// size is its size drawn in cells of a width, with the headroom of
	// its hop over it.
	size func(cell float32) (w, h float32)
	// draw paints it in r, centered, in cells of a width, in a pose, on
	// bg.
	draw func(a *app, pt *ui.Painter, r ui.Rect, cell float32, bg ui.Color, p mascotPose)
}

var (
	clawd  = &mascot{name: "Claude", size: clawdSize, draw: (*app).drawClawd}
	qoduck = &mascot{name: "Qoder", size: qoduckSize, draw: (*app).drawQoduck}
)

// themeMascot returns the character of the window's theme, or nil.
func (a *app) themeMascot() *mascot {
	switch a.settings.Theme {
	case themeClaude:
		return clawd
	case themeQoder:
		return qoduck
	}
	return nil
}

const (
	mascotPeriod = 4200 * time.Millisecond // between blinks
	mascotBlink  = 140 * time.Millisecond
	mascotBobAt  = 2100 * time.Millisecond // into every third period
	mascotBob    = 260 * time.Millisecond
	mascotHop    = 130 * time.Millisecond // a step of the hop
)

// mascotState is how the character is: moving whether the last paint
// asked for a next, and hopping whether it hopped.
type mascotState struct {
	moving, hopping bool
}

// mascotPose is a moment of the character's: the eyes shut, the body
// lifted by a part of its headroom, and which step of the hop.
type mascotPose struct {
	blink bool
	lift  float32
	step  int
}

// poseAt returns the character's pose at a moment, and how long it holds.
func poseAt(now time.Time, busy bool) (mascotPose, time.Duration) {
	ms := now.UnixMilli()
	if busy {
		step := mascotHop.Milliseconds()
		k := ms / step
		return mascotPose{lift: float32(k % 2), step: int(k % 2)}, time.Duration(step-ms%step) * time.Millisecond
	}
	period := mascotPeriod.Milliseconds()
	in, n := ms%period, ms/period
	// The moments the pose changes, in a period.
	marks := []int64{mascotBlink.Milliseconds(), period}
	var p mascotPose
	switch {
	case in < mascotBlink.Milliseconds():
		p.blink = true
	case n%3 == 0:
		at, end := mascotBobAt.Milliseconds(), (mascotBobAt + mascotBob).Milliseconds()
		marks = []int64{mascotBlink.Milliseconds(), at, end, period}
		if in >= at && in < end {
			p.lift = 0.5
		}
	}
	for _, m := range marks {
		if m > in {
			return p, time.Duration(m-in) * time.Millisecond
		}
	}
	return p, time.Duration(period-in) * time.Millisecond
}

// mascotBusy reports whether there is work for the character to hop to:
// a Git command or a search of the files running.
func (a *app) mascotBusy() bool {
	return a.git.busy != "" || a.inFiles.running
}

// drawMascot paints m in r, centered, in cells of a width, on bg. still
// holds it standing, asking for no more frames.
func (a *app) drawMascot(pt *ui.Painter, m *mascot, r ui.Rect, cell float32, bg ui.Color, still bool) {
	busy := a.mascotBusy()
	var p mascotPose
	a.mascot.moving, a.mascot.hopping = !still, !still && busy
	if !still {
		var hold time.Duration
		p, hold = poseAt(pt.Now(), busy)
		pt.After(hold)
	}
	m.draw(a, pt, r, cell, bg, p)
}

// mascotStill reports whether the character holds still in the window
// now.
func (a *app) mascotStill(c *ui.Context) bool {
	return a.blurred || c.Preferences().ReduceMotion
}

// mascotTip says what the character is doing, under the pointer.
func (a *app) mascotTip(m *mascot) string {
	switch {
	case a.git.busy != "":
		return m.name + " · " + a.git.busy
	case a.inFiles.running:
		return m.name + " · Searching…"
	}
	return m.name
}

// statusMascot is the character at the start of the status bar.
func (a *app) statusMascot(c *ui.Context, m *mascot) {
	const cell = 1
	w, h := m.size(cell)
	still := a.mascotStill(c)
	bg := a.pal.status
	ui.Row(c.Key("status:mascot")).Size(w+12, statusBarH).Tooltip(a.mascotTip(m)).Draw(func(pt *ui.Painter, r ui.Rect) {
		a.drawMascot(pt, m, ui.Rect{X: r.X + 6, Y: r.Y + (r.H-h)/2, W: w, H: h}, cell, bg, still)
	})
}

// welcomeMascot is the character in the logo's place on the welcome
// page.
func (a *app) welcomeMascot(c *ui.Context, m *mascot) {
	const cell = 4
	w, h := m.size(cell)
	still := a.mascotStill(c)
	bg := a.pal.editor
	ui.Row(c.Key("welcome:mascot")).Size(w, h).Tooltip(a.mascotTip(m)).Draw(func(pt *ui.Painter, r ui.Rect) {
		a.drawMascot(pt, m, r, cell, bg, still)
	})
}
