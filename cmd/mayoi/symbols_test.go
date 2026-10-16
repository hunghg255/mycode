package main

import (
	"testing"

	"github.com/egoist/mygo/ui"
)

func TestGoToSymbol(t *testing.T) {
	hs, d := editHarness(t, "a.go", "package a\n\nfunc first() {}\n\ntype second struct{}\n\nfunc (s second) third() {}\n")
	hs.a.openQuick("@thi")
	hs.settle()
	if !hs.tt.HasText("third") {
		t.Fatalf("symbols: %q", hs.tt.Texts())
	}
	hs.key(0, ui.KeyEnter)
	if d.sel != [2]int{66, 71} { // "third" on the line at 50
		t.Fatalf("selection %v", d.sel)
	}
}
