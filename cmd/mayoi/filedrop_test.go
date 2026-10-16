package main

import (
	"os"
	"slices"
	"strings"
	"testing"
)

func tabNames(col *column) string {
	var out []string
	for _, t := range col.tabs {
		out = append(out, t.name())
	}
	return strings.Join(out, " ")
}

func TestDroppingFiles(t *testing.T) {
	hs := newHarness(t, true)
	a := hs.a
	a.openFile(hs.path("main.go"), true)
	a.openFile(hs.path("go.mod"), true)
	hs.settle()
	col := a.cols[0]

	// Between tabs, in the order they come, the last shown; the folder
	// opens as `mayoi <dir>` opens it.
	a.dropFiles([]string{hs.path("README.md"), hs.path("internal"), hs.path("web/style.css"), hs.path("missing.txt")}, col, 1)
	hs.settle()
	if got := tabNames(col); got != "main.go README.md style.css go.mod" {
		t.Fatalf("tabs %q", got)
	}
	if col.tab().name() != "style.css" {
		t.Errorf("shown %q", col.tab().name())
	}
	if !slices.Equal(hs.h.folders, []string{hs.path("internal")}) {
		t.Errorf("folders %q", hs.h.folders)
	}
	// One open already comes forward, and those after it follow it.
	a.dropFiles([]string{hs.path("main.go"), hs.path("web/index.html")}, col, 4)
	hs.settle()
	if got := tabNames(col); got != "main.go index.html README.md style.css go.mod" {
		t.Fatalf("tabs %q", got)
	}

	// Beside the column: a column of their own.
	a.dropFilesBeside([]string{hs.path("internal/a/a.go")}, col, true)
	hs.settle()
	if len(a.cols) != 2 || tabNames(a.cols[1]) != "a.go" || a.col != 1 {
		t.Fatalf("split: %d columns, col %d", len(a.cols), a.col)
	}
	// None that opens leaves no column behind.
	bin := hs.path("blob.bin")
	os.WriteFile(bin, []byte{0, 1, 2, 0, 0, 3}, 0o644)
	a.dropFilesBeside([]string{bin}, a.cols[1], true)
	hs.settle()
	if len(a.cols) != 2 {
		t.Errorf("%d columns after dropping a binary file beside", len(a.cols))
	}
	// Only folders beside a column split nothing.
	a.dropFilesBeside([]string{hs.path("web")}, a.cols[1], false)
	hs.settle()
	if len(a.cols) != 2 || hs.h.folders[len(hs.h.folders)-1] != hs.path("web") {
		t.Errorf("%d columns, folders %q", len(a.cols), hs.h.folders)
	}
}

func TestShellQuote(t *testing.T) {
	for in, want := range map[string]string{
		"/Users/me/a.go":     "/Users/me/a.go",
		"/tmp/my file.txt":   "'/tmp/my file.txt'",
		"/tmp/it's":          `'/tmp/it'\''s'`,
		"/tmp/$HOME;rm":      "'/tmp/$HOME;rm'",
		"":                   "''",
		"/tmp/a-b_c.d@e%f+g": "/tmp/a-b_c.d@e%f+g",
	} {
		if got := shellQuote(in); got != want {
			t.Errorf("shellQuote(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestDraggingFilesFromTheSidebar(t *testing.T) {
	hs := newHarness(t, true)
	a, tt := hs.a, hs.tt
	a.openFile(hs.path("main.go"), true)
	a.openFile(hs.path("go.mod"), true)
	hs.settle()
	col := a.cols[0]
	// From the explorer onto a tab: before it, kept and shown.
	r, ok := tt.Find("README.md")
	if !ok {
		t.Fatal("no README.md in the explorer")
	}
	x1, y1 := hs.tabCenter("go.mod")
	hs.drag(r.X+r.W/2, r.Y+r.H/2, x1, y1)
	if got := tabNames(col); got != "main.go README.md go.mod" || col.tab().name() != "README.md" || col.tab().transient {
		t.Fatalf("tabs %q, shown %q", got, col.tab().name())
	}
	// Onto the side of the editor: a column of its own.
	tt.Click("web")
	hs.settle()
	r, ok = tt.Find("style.css")
	body, ok2 := tt.Find("Editor README.md")
	if !ok || !ok2 {
		t.Fatalf("no style.css or no editor: %q", tt.Texts())
	}
	hs.drag(r.X+r.W/2, r.Y+r.H/2, body.X+body.W-20, body.Y+body.H/2)
	if len(a.cols) != 2 || tabNames(a.cols[1]) != "style.css" || a.col != 1 {
		t.Fatalf("%d columns, col %d", len(a.cols), a.col)
	}
	if a.dragging {
		hs.settle()
		if a.dragging {
			t.Error("still dragging")
		}
	}
	// A match of the search results, onto the middle of a column: after the
	// tab shown, with the match selected.
	hs.searchFor("Answer")
	head, ok := tt.Find("internal/a")
	body, ok2 = tt.Find("Editor style.css")
	if !ok || !ok2 {
		t.Fatalf("no result or no editor: %q", tt.Texts())
	}
	hs.drag(head.X+head.W/2, head.Y+head.H/2+22, body.X+body.W/2, body.Y+body.H/2)
	d := a.activeEditor()
	if tabNames(a.cols[1]) != "style.css a.go" || d == nil || d.buf.Slice(d.sel[0], d.sel[1]) != "Answer" {
		t.Fatalf("tabs %q", tabNames(a.cols[1]))
	}
}
