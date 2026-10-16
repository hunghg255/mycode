package main

import (
	"os"
	"strings"
	"testing"

	"github.com/egoist/mygo/ui"

	"mayoi/internal/highlight"
)

// Typing in a long file keeps the colors of the line typed in, and of the
// lines a new line moves down, in the frame of the keystroke: before the
// highlighter has lexed the text again.
func TestTypingKeepsColors(t *testing.T) {
	hs := newHarness(t, true)
	a, tt := hs.a, hs.tt
	src := strings.Repeat("// a comment\nvar s = \"a string\"\n", 1500)
	os.WriteFile(hs.path("long.go"), []byte(src), 0o644)
	a.openFile(hs.path("long.go"), true)
	hs.settle()
	d := a.activeEditor()
	p := a.pal
	// colored reports whether line i shows in the color of kind col.
	colored := func(i int, col ui.Color) bool {
		snap := d.buf.Snapshot()
		s, e := snap.LineRange(i)
		for _, r := range d.colors.out {
			if r.Start < e && r.End > s && r.Color == col {
				return true
			}
		}
		return false
	}
	str, comment := p.syntax[highlight.String], p.syntax[highlight.Comment]
	if !colored(1, str) || !colored(2, comment) {
		t.Fatal("no colors to begin with")
	}
	// Inside the string of line 1.
	at := len("// a comment\nvar s = \"a st")
	hs.place(d, at, at)
	tt.Type("x")
	tt.Frame()
	if !colored(1, str) {
		t.Error("the line typed in lost its colors")
	}
	// A new line at the start of line 1 moves the lines below down.
	at = len("// a comment\n")
	hs.place(d, at, at)
	tt.Key(0, ui.KeyEnter)
	tt.Frame()
	if !colored(2, str) || !colored(3, comment) {
		t.Error("the lines moved down lost their colors")
	}
}
