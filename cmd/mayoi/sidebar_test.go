package main

import (
	"testing"

	"github.com/egoist/mygo/ui"
)

// The sidebar's title shows whole: beside the Explorer's buttons, which go
// on the folder's row, and in source control, whose title gives way to
// its short form in a narrow sidebar.
func TestSidebarTitleFits(t *testing.T) {
	hs := newHarness(t, true)
	a, tt := hs.a, hs.tt
	whole := func(title string) {
		t.Helper()
		var w float32
		ui.NewTester(func(c *ui.Context) {
			w, _ = c.MeasureText(0, ui.Span{Text: title, Size: 11, Weight: 600})
		}, 100, 100).Frame()
		r, ok := tt.Find(title)
		if !ok {
			t.Fatalf("no title %q: %q", title, tt.Texts())
		}
		// Less the title's left padding.
		if r.W-6 < w {
			t.Errorf("the title %q has %.0f points of the %.0f it takes", title, r.W-6, w)
		}
	}
	hs.gitRepo()
	tt.Move(100, 150)
	hs.settle()
	whole("EXPLORER")
	if _, ok := tt.Find("New File…"); !ok {
		t.Error("the Explorer's buttons do not show under the pointer")
	}
	a.run("view.scm")
	hs.settleGit()
	whole("SOURCE CONTROL")
	a.window.SidebarWidth = 180
	hs.settle()
	whole("GIT")
}
