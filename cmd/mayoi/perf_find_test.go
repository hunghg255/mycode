package main

import (
	"fmt"
	"os"
	"strings"
	"testing"
	"time"
)

// TestFindInLargeFileStaysQuick types in a large file with find open,
// which looks for the matches in the background.
func TestFindInLargeFileStaysQuick(t *testing.T) {
	hs := newHarness(t, true)
	a, tt := hs.a, hs.tt
	var b strings.Builder
	for i := range 100_000 {
		fmt.Fprintf(&b, "func f%d(x int) int { return x * %d } // line %d\n", i, i, i)
	}
	big := hs.path("big.go")
	os.WriteFile(big, []byte(b.String()), 0o644)
	a.openFile(big, true)
	hs.settle()
	a.find.query = "return x"
	a.openFind(false)
	hs.settle()
	a.activeEditor().vscroll.Focus()
	hs.settle()
	start := time.Now()
	const n = 30
	for range n {
		tt.Type("a")
		tt.Frame()
	}
	t.Logf("type with find open: %.2f ms/frame, %d matches", float64(time.Since(start).Microseconds())/1000/n, len(a.find.matches))

	// The matches found in the background are those of the text as it is.
	tt.Type(" return x")
	d := a.activeEditor()
	for deadline := time.Now().Add(10 * time.Second); a.find.version != d.buf.Version() && time.Now().Before(deadline); {
		hs.settle()
	}
	want := scanMatches(a.find.re, d.buf.Snapshot())
	if a.find.version != d.buf.Version() || len(a.find.matches) != len(want) || a.find.matches[0] != want[0] {
		t.Fatalf("matches of version %d (text %d): %d, want %d", a.find.version, d.buf.Version(), len(a.find.matches), len(want))
	}
}
