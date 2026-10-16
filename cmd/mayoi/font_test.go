package main

import (
	"slices"
	"testing"
)

// The code's font follows the settings' preferences as they change, and
// the terminals' follows the code's where they leave it to.
func TestFontFollowsTheSettings(t *testing.T) {
	hs := newHarness(t, false)
	a := hs.a
	hs.settle()
	if a.font.lineH != 20 || a.font.weight != 400 {
		t.Fatalf("line height %v, weight %d", a.font.lineH, a.font.weight)
	}
	p := a.settings.Prefs
	p.FontSize, p.LineHeight, p.FontWeight, p.FontFeatures = 14, 2, 600, []string{"calt=0", "ss01"}
	a.settings.SetPrefs(p)
	hs.settle()
	if f := a.font; f.size != 14 || f.lineH != 28 || f.weight != 600 || !slices.Equal(f.featureList(), p.FontFeatures) {
		t.Fatalf("font %+v", f)
	}
	if tf := termFont(a.settings); tf.Family != "monospace" || tf.Size != 13.5 || tf.Weight != 600 || len(tf.Features) != 2 {
		t.Fatalf("terminal font %+v", tf)
	}
	a.settings.TerminalFontFamily, a.settings.TerminalFontSize = "Menlo", 11
	if tf := termFont(a.settings); tf.Family != "Menlo" || tf.Size != 11 {
		t.Fatalf("terminal's own font %+v", tf)
	}
}
