package main

import (
	"os"
	"os/exec"
	"slices"
	"strings"
	"testing"

	"github.com/egoist/mygo/ui"
)

const conflictText = "top\n" +
	"<<<<<<< HEAD\n" +
	"mine\n" +
	"=======\n" +
	"theirs\n" +
	">>>>>>> feature\n" +
	"middle\n" +
	"<<<<<<< HEAD\n" +
	"=======\n" +
	"added\n" +
	"||||||| not a base after =======\n" +
	">>>>>>> feature\n" +
	"<<<<<<< ours\n" +
	"a\n" +
	"||||||| base\n" +
	"o\n" +
	"=======\n" +
	"b\n" +
	">>>>>>> theirs\n" +
	"<<<<<<< open\n" +
	"never closed\n"

func TestParseConflicts(t *testing.T) {
	snap := ui.NewTextBuffer(conflictText).Snapshot()
	cs := parseConflicts(snap.LineCount(), snap.Line)
	want := []conflict{
		{start: 1, base: -1, mid: 3, end: 5, current: "HEAD", incoming: "feature"},
		{start: 7, base: -1, mid: 8, end: 11, current: "HEAD", incoming: "feature"},
		{start: 12, base: 14, mid: 16, end: 18, current: "ours", incoming: "theirs"},
	}
	if !slices.Equal(cs, want) {
		t.Fatalf("conflicts\n got %+v\nwant %+v", cs, want)
	}
	// Each side, and both; the base's section goes either way.
	cases := []struct {
		k    int
		side conflictSide
		want string
	}{
		{0, keepCurrent, "mine"},
		{0, keepIncoming, "theirs"},
		{0, keepBoth, "mine\ntheirs"},
		{2, keepCurrent, "a"},
		{2, keepIncoming, "b"},
		{2, keepBoth, "a\nb"},
	}
	for _, c := range cases {
		e := cs[c.k].edit(snap, c.side)
		if e.text != c.want {
			t.Errorf("conflict %d side %d: %q, want %q", c.k, c.side, e.text, c.want)
		}
	}
	// Keeping an empty side takes the lines out with their newline.
	buf := ui.NewTextBuffer(conflictText)
	e := cs[1].edit(buf.Snapshot(), keepCurrent)
	buf.Replace(e.start, e.end, e.text)
	if got := buf.String(); !strings.Contains(got, "middle\n<<<<<<< ours\n") {
		t.Errorf("empty side kept:\n%s", got)
	}
}

func TestIsMarker(t *testing.T) {
	for s, want := range map[string]bool{
		"<<<<<<<":        true,
		"<<<<<<< HEAD":   true,
		"<<<<<<<<":       false,
		"<<<<<<<x":       false,
		"=======\r":      true,
		" <<<<<<< HEAD ": false,
	} {
		if got := isMarker(s, s[:min(len(s), 7)]); s[0] != ' ' && got != want {
			t.Errorf("isMarker(%q) = %v", s, got)
		}
	}
}

// TestResolveConflicts: a file a merge left in conflict shows its
// conflicts, which the buttons and commands resolve as steps of undo, and
// the last offers to stage the file.
func TestResolveConflicts(t *testing.T) {
	hs := newHarness(t, true)
	git := hs.gitRepo()
	a := hs.a
	write := func(body string) { os.WriteFile(hs.path("c.txt"), []byte(body), 0o644) }
	// Lines enough between the changes for Git to keep them apart.
	sep := "s1\ns2\ns3\ns4\ns5\ns6\n"
	write("one\n" + sep + "two\n" + sep + "three\n")
	git("add", "c.txt")
	git("commit", "-qm", "base")
	git("switch", "-qc", "feature")
	write("one\n" + sep + "TWO feature\n" + sep + "THREE feature\n")
	git("commit", "-qam", "feature")
	git("switch", "-q", "main")
	write("one\n" + sep + "two main\n" + sep + "three main\n")
	git("commit", "-qam", "main")
	cmd := exec.Command("git", "-C", hs.root, "-c", "user.email=t@t", "-c", "user.name=t", "merge", "feature")
	if out, err := cmd.CombinedOutput(); err == nil {
		t.Fatalf("merge did not conflict: %s", out)
	}
	hs.settleGit()
	a.openFile(hs.path("c.txt"), true)
	hs.settle()
	d := a.activeEditor()
	cs := a.editorConflicts(d)
	if len(cs) != 2 {
		t.Fatalf("conflicts %+v in %q", cs, d.buf.String())
	}
	hs.tt.Frame()
	if n := len(slices.DeleteFunc(hs.tt.Texts(), func(s string) bool { return s != "Conflict" })); n != 2 {
		t.Fatalf("buttons for %d conflicts: %q", n, hs.tt.Texts())
	}
	// The first button keeps the incoming side.
	if err := hs.tt.Click("Accept Incoming"); err != nil {
		t.Fatal(err)
	}
	hs.settle()
	if got := d.buf.String(); !strings.Contains(got, "TWO feature\n") || strings.Contains(got, "two main") {
		t.Fatalf("after accepting incoming:\n%s", got)
	}
	if len(a.editorConflicts(d)) != 1 {
		t.Fatal("the conflict resolved is still found")
	}
	// The command at the caret keeps both, and that was the last.
	d.selectRange(0, 0, false)
	a.run("git.nextConflict")
	hs.settle()
	if l := caretLine(d); l != a.editorConflicts(d)[0].start {
		t.Fatalf("next conflict: caret on line %d", l)
	}
	a.run("git.acceptBoth")
	hs.settle()
	if got := d.buf.String(); got != "one\n"+sep+"TWO feature\n"+sep+"three main\nTHREE feature\n" {
		t.Fatalf("after accepting both:\n%q", got)
	}
	if len(a.editorConflicts(d)) != 0 {
		t.Fatal("conflicts left")
	}
	// Undo brings the conflict back.
	a.run("edit.undo")
	hs.settle()
	if len(a.editorConflicts(d)) != 1 {
		t.Fatalf("undo: %q", d.buf.String())
	}
	a.run("edit.redo")
	hs.settle()
	// The toast stages the file, saved.
	hs.tt.Frame()
	if err := hs.tt.Click("Stage"); err != nil {
		t.Fatalf("%v: %q", err, hs.tt.Texts())
	}
	hs.settleGit()
	if e := a.git.entries[hs.path("c.txt")]; e.Conflicted() || !e.Staged() {
		t.Fatalf("after staging: %c%c", e.X, e.Y)
	}
}
