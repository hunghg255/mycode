package main

import (
	"slices"
	"testing"

	"github.com/egoist/mygo/ui"
)

func TestCommandPaletteRunsACommand(t *testing.T) {
	hs := newHarness(t, true)
	a, tt := hs.a, hs.tt
	a.run("go.commands")
	hs.settle()
	if !a.quick.open || a.quick.query != ">" {
		t.Fatalf("palette open %v with %q", a.quick.open, a.quick.query)
	}
	tt.Type("wordwrap")
	hs.settle()
	hs.shot("command-palette")
	tt.Key(0, ui.KeyEnter)
	hs.settle()
	if a.quick.open {
		t.Error("the palette stayed open")
	}
	if !a.settings.WordWrap {
		t.Error("View: Word Wrap did not turn word wrap on")
	}
	// The command run last comes first.
	a.run("go.commands")
	hs.settle()
	if e := a.paletteEntries()[a.quick.results[0].Index]; e.id != "view.wordWrap" {
		t.Errorf("first command %s, want the one run last", e.id)
	}
	tt.Key(0, ui.KeyEscape)
	hs.settle()
	if a.quick.open {
		t.Error("Escape left the palette open")
	}
}

func TestAccelCaps(t *testing.T) {
	for _, c := range []struct {
		accel string
		mac   bool
		want  []string
	}{
		{"Shift+CmdOrCtrl+P", true, []string{"⇧", "⌘", "P"}},
		{"Alt+CmdOrCtrl+Right", true, []string{"⌥", "⌘", "→"}},
		{"Ctrl+`", true, []string{"⌃", "`"}},
		{"Shift+Alt+F5", true, []string{"⌥", "⇧", "F5"}},
		{"CmdOrCtrl+=", true, []string{"⌘", "="}},
		{"Shift+CmdOrCtrl+P", false, []string{"Ctrl", "Shift", "P"}},
		{"", true, nil},
	} {
		if got := accelCaps(c.accel, c.mac); !slices.Equal(got, c.want) {
			t.Errorf("accelCaps(%q, %v) = %q, want %q", c.accel, c.mac, got, c.want)
		}
	}
}
