package main

import (
	"image"
	"os"
	"testing"

	"github.com/egoist/mygo/ui"

	"mayoi/internal/settings"
)

// The screens the other shots leave out: the welcome page, of a folder
// and of a window without one, quick open and the command palette.
func TestShotTour(t *testing.T) {
	if os.Getenv("SHOTS") == "" {
		t.Skip()
	}
	for _, dark := range []bool{true, false} {
		suffix := "-light"
		if dark {
			suffix = "-dark"
		}
		hs := newHarness(t, dark)
		hs.shot("welcome" + suffix)
		hs.a.openQuick("")
		hs.tt.Type("ma")
		hs.settle()
		hs.shot("quick" + suffix)
		hs.a.closeQuick()
		hs.settle()
		hs.a.openQuick(">")
		hs.settle()
		hs.shot("palette" + suffix)

		s := settings.Default()
		s.Recent = []string{hs.root, "/Users/someone/Projects/mygo", "/Users/someone/Projects/website"}
		a := newApp(&fakeHost{}, s, s.NewWindow())
		tt := ui.NewTester(a.view, 1200, 760)
		tt.SetDark(dark)
		empty := &harness{t: t, a: a, h: &fakeHost{}, tt: tt}
		empty.settle()
		empty.shot("empty" + suffix)
	}
}

// The find box and a commit's card up close, at twice the scale.
func TestShotTourClose(t *testing.T) {
	if os.Getenv("SHOTS") == "" {
		t.Skip()
	}
	for _, dark := range []bool{true, false} {
		suffix := "-light"
		if dark {
			suffix = "-dark"
		}
		hs := newHarness(t, dark)
		hs.tt.SetScale(2)
		git := hs.gitRepo()
		os.WriteFile(hs.path("internal/a/a.go"), []byte("package a\n\n// Answer is the answer.\nconst Answer = 42\n"), 0o644)
		git("mv", "README.md", "README.markdown")
		git("commit", "-qam", "Document the answer and rename the README\n\nThe README keeps its words; only its name changes.")
		a := hs.a
		a.openFile(hs.path("main.go"), true)
		hs.settle()
		a.openFind(true)
		a.find.query = "main"
		a.find.matchCase = true
		a.find.stale = true
		hs.settle()
		hs.shotRect("find-close"+suffix, image.Rect(700, 70, 1200, 190), 2)
		a.closeFind()
		a.run("view.scm")
		hs.settleGit()
		a.showCommit(a.git.history[0], false)
		hs.settleGit()
		hs.settle()
		hs.shotRect("commit-close"+suffix, image.Rect(248, 38, 1000, 360), 2)
	}
}
