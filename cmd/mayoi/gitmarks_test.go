package main

import (
	"fmt"
	"os"
	"os/exec"
	"slices"
	"strings"
	"testing"
	"time"

	"mayoi/internal/linediff"
)

func TestGitMarksFollowEdits(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("no git")
	}
	hs := newHarness(t, true)
	git := func(args ...string) {
		cmd := exec.Command("git", append([]string{"-C", hs.root, "-c", "user.email=t@t", "-c", "user.name=t"}, args...)...)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	os.WriteFile(hs.path("m.txt"), []byte("a\nb\nc\nd\n"), 0o644)
	git("init", "-q")
	git("add", "m.txt")
	git("commit", "-q", "-m", "x")
	os.WriteFile(hs.path("m.txt"), []byte("a\nB\nc\nnew\nd\n"), 0o644)
	hs.a.openFile(hs.path("m.txt"), true)
	hs.settle()
	d := hs.a.activeEditor()
	want := []linediff.Kind{0, linediff.Modified, 0, linediff.Added, 0, 0}
	if !slices.Equal(d.git.Lines, want) {
		t.Fatalf("marks %v, want %v", d.git.Lines, want)
	}
	// Taking the line out again marks it no more.
	d.edit([2]int{0, 0}, textEdit{6, 10, ""})
	hs.settle()
	want = []linediff.Kind{0, linediff.Modified, 0, 0, 0}
	if !slices.Equal(d.git.Lines, want) {
		t.Fatalf("after the edit: marks %v, want %v", d.git.Lines, want)
	}
	// After a commit, nothing is changed.
	hs.a.run("file.save")
	git("commit", "-q", "-am", "y")
	hs.a.gitChanged()
	hs.settle()
	if slices.ContainsFunc(d.git.Lines, func(k linediff.Kind) bool { return k != 0 }) {
		t.Fatalf("after the commit: marks %v", d.git.Lines)
	}
}

// Typing in a long file Git has stays quick, while its lines are compared
// with HEAD in the background.
func TestTypingInLargeTrackedFile(t *testing.T) {
	if testing.Short() {
		t.Skip()
	}
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("no git")
	}
	hs := newHarness(t, true)
	var b strings.Builder
	for i := range 100_000 {
		fmt.Fprintf(&b, "\tx%d := f(x%d) // line %d\n", i, i, i)
	}
	os.WriteFile(hs.path("big.go"), []byte("package big\n\nfunc g() {\n"+b.String()+"}\n"), 0o644)
	for _, args := range [][]string{{"init", "-q"}, {"add", "big.go"}, {"commit", "-q", "-m", "x"}} {
		cmd := exec.Command("git", append([]string{"-C", hs.root, "-c", "user.email=t@t", "-c", "user.name=t"}, args...)...)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	hs.a.openFile(hs.path("big.go"), true)
	hs.settle()
	d := hs.a.activeEditor()
	d.vscroll.Y = 50_000 * hs.a.font.lineH
	hs.place(d, d.buf.Len()/2, d.buf.Len()/2)
	start := time.Now()
	const n = 100
	for range n {
		hs.tt.Type("a")
		hs.tt.Frame()
	}
	t.Logf("type in a tracked file: %.2f ms/frame", float64(time.Since(start).Microseconds())/1000/n)
	hs.settle()
	time.Sleep(200 * time.Millisecond)
	hs.settle()
	changed := 0
	for _, k := range d.git.Lines {
		if k != linediff.Same {
			changed++
		}
	}
	if changed != 1 {
		t.Errorf("%d lines marked changed, want 1", changed)
	}
}
