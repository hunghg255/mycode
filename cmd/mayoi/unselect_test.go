package main

import (
	"path/filepath"
	"testing"

	"github.com/egoist/mygo/ui"
)

// A click on the space below the files in the Explorer chooses none, as
// Escape does; a right click there opens the workspace's menu.
func TestExplorerChoosesNoneBelowTheFiles(t *testing.T) {
	hs := newHarness(t, false)
	a, tt := hs.a, hs.tt
	chosen := func() string {
		if a.fileRow < 0 || a.fileRow >= a.files.Rows() {
			return ""
		}
		return a.files.Item(a.fileRow)
	}
	last, ok := tt.Find(filepath.Base(a.files.Item(a.files.Rows() - 1)))
	if !ok {
		t.Fatal("no last row")
	}
	below := func() (float32, float32) { return last.X, last.Y + last.H + 40 }

	if err := tt.Click("main.go"); err != nil {
		t.Fatal(err)
	}
	hs.settle()
	if chosen() != hs.path("main.go") {
		t.Fatalf("chosen %q", chosen())
	}
	tt.Move(below())
	hs.settle()
	tt.ClickAt(below())
	hs.settle()
	if got := chosen(); got != "" {
		t.Fatalf("chosen %q after a click below the files", got)
	}
	if a.targetDir() != a.root {
		t.Errorf("new files go in %q", a.targetDir())
	}

	// A click beside a row, by a folder's arrow, opens it and keeps the
	// choice.
	if err := tt.Click("web"); err != nil {
		t.Fatal(err)
	}
	hs.settle()
	r, _ := tt.Find("web")
	tt.RightClickAt(r.X-24, r.Y+r.H/2)
	hs.settle()
	if m := tt.Menu(); len(m) != 0 {
		t.Errorf("menu beside a row: %q", m)
	}
	tt.CloseMenu()
	if chosen() != hs.path("web") {
		t.Fatalf("chosen %q", chosen())
	}

	// Escape while the tree has the keyboard, which a click gives it.
	hs.key(0, ui.KeyEscape)
	if got := chosen(); got != "" {
		t.Fatalf("chosen %q after Escape", got)
	}

	// The menu below the files is the workspace's. (A file with a tab is
	// clicked by its tab.)
	if err := tt.Click("go.mod"); err != nil {
		t.Fatal(err)
	}
	hs.settle()
	if chosen() != hs.path("go.mod") {
		t.Fatalf("chosen %q", chosen())
	}
	last, _ = tt.Find(filepath.Base(a.files.Item(a.files.Rows() - 1)))
	tt.Move(below())
	hs.settle()
	tt.RightClickAt(below())
	hs.settle()
	if err := tt.ChooseMenuItem("New Folder…"); err != nil {
		t.Fatalf("%v: %q", err, tt.Menu())
	}
	hs.settle()
	if got := chosen(); got != "" {
		t.Errorf("chosen %q after the menu", got)
	}
	if a.prompt == nil || a.prompt.hint != "in "+filepath.Base(a.root) {
		t.Errorf("prompt %+v", a.prompt)
	}
}
