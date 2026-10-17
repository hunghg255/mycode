package main

import (
	"testing"

	"mayoi/internal/settings"
)

func TestMinimapGeometry(t *testing.T) {
	// Within a float32's precision.
	near := func(a, b float32) bool { e := 0.01 + max(a, b, -a, -b)*1e-5; return a-b < e && b-a < e }
	// A document that fits: the minimap does not scroll, and the slider is
	// where the editor is, scaled.
	g := geometry{lineH: 20, n: 100}
	m := minimapGeom(g, 300, 500)
	if m.top != 0 || !near(m.sliderY, 30) || !near(m.sliderH, 50) {
		t.Errorf("fits: %+v", m)
	}
	if got := m.scrollFor(m.sliderY); !near(got, 300) {
		t.Errorf("fits: the slider at %v scrolls to %v, want 300", m.sliderY, got)
	}
	// A taller one: the minimap shows its top at the top and its end at
	// the end, and the slider goes the minimap's height.
	g = geometry{lineH: 20, n: 10000}
	end := 2*editorPadY + g.height() - 500
	for _, y := range []float32{0, end / 3, end} {
		m := minimapGeom(g, y, 500)
		if !near(m.scrollFor(m.sliderY), y) {
			t.Errorf("at %v, the slider at %v scrolls to %v", y, m.sliderY, m.scrollFor(m.sliderY))
		}
		if m.sliderY < -0.01 || m.sliderY+m.sliderH > 500.01 {
			t.Errorf("at %v, the slider is out of the minimap: %+v", y, m)
		}
	}
	if m := minimapGeom(g, end, 500); !near(m.sliderY+m.sliderH, 500) {
		t.Errorf("at the end, the slider ends at %v", m.sliderY+m.sliderH)
	}
	if first, last := minimapGeom(g, 0, 500).lines(g, 500); first != 0 || last < 240 || last > 260 {
		t.Errorf("at the top, the minimap shows lines %d to %d", first, last)
	}
}

// TestMinimap: an editor has a minimap at its right, which a click and the
// wheel scroll the editor by, and which the settings hide and size.
func TestMinimap(t *testing.T) {
	hs, d := editHarness(t, "w.go", wrapFile(2000))
	a, tt := hs.a, hs.tt
	box, ok := tt.Find("Minimap")
	if !ok || box.W != settings.DefaultMinimapWidth {
		t.Fatalf("no minimap %v wide: %v %v", settings.DefaultMinimapWidth, box, ok)
	}
	// A click near the bottom scrolls down there, and one at the top back.
	tt.ClickAt(box.X+box.W/2, box.Y+box.H-20)
	hs.settle()
	if d.vscroll.Y < 1000 {
		t.Errorf("a click near the minimap's bottom scrolled to %v", d.vscroll.Y)
	}
	tt.ClickAt(box.X+box.W/2, box.Y+2)
	hs.settle()
	if d.vscroll.Y != 0 {
		t.Errorf("a click at the minimap's top scrolled to %v", d.vscroll.Y)
	}
	// The wheel over it scrolls the editor.
	tt.Scroll(box.X+box.W/2, box.Y+box.H/2, 0, 300)
	hs.settle()
	if d.vscroll.Y == 0 {
		t.Error("the wheel over the minimap did not scroll the editor")
	}

	// Dragging its left edge widens it.
	tt.Press(box.X+2, box.Y+200)
	tt.Frame()
	tt.Move(box.X-48, box.Y+200)
	tt.Frame()
	tt.Release(box.X-48, box.Y+200)
	hs.settle()
	if w := a.settings.MinimapWidth; w < settings.DefaultMinimapWidth+40 {
		t.Errorf("dragging the edge left made it %v wide", w)
	}
	if box, _ := tt.Find("Minimap"); box.W != a.settings.MinimapWidth {
		t.Errorf("the minimap is %v wide, not %v", box.W, a.settings.MinimapWidth)
	}

	// View → Minimap hides it.
	a.run("view.minimap")
	hs.settle()
	if _, ok := tt.Find("Minimap"); ok || a.settings.Minimap {
		t.Error("the minimap shows after hiding it")
	}
	a.run("view.minimap")
	hs.settle()
	if _, ok := tt.Find("Minimap"); !ok {
		t.Error("the minimap did not come back")
	}

	// A narrow editor has none.
	tt.SetSize(560, 700)
	hs.settle()
	if _, ok := tt.Find("Minimap"); ok {
		t.Error("a narrow editor has a minimap")
	}
}
