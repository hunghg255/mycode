package main

import (
	"os"
	"path/filepath"
	"slices"
	"testing"
)

func TestFreeName(t *testing.T) {
	dir := t.TempDir()
	for _, n := range []string{"a.go", "a copy.go", ".env", "lib.d"} {
		os.WriteFile(filepath.Join(dir, n), nil, 0o644)
	}
	for _, c := range []struct {
		name  string
		isDir bool
		want  string
	}{
		{"new.go", false, "new.go"},
		{"a.go", false, "a copy 2.go"},
		{".env", false, ".env copy"},
		{"lib.d", true, "lib.d copy"},
	} {
		if got := filepath.Base(freeName(dir, c.name, c.isDir)); got != c.want {
			t.Errorf("freeName(%q) = %q, want %q", c.name, got, c.want)
		}
	}
}

func TestCopyInto(t *testing.T) {
	src, dst := t.TempDir(), t.TempDir()
	os.MkdirAll(filepath.Join(src, "pkg/sub"), 0o755)
	os.WriteFile(filepath.Join(src, "pkg/sub/run.sh"), []byte("echo hi\n"), 0o755)
	os.Symlink("sub/run.sh", filepath.Join(src, "pkg/link"))

	to, err := copyInto(filepath.Join(src, "pkg"), dst)
	if err != nil || to != filepath.Join(dst, "pkg") {
		t.Fatalf("copyInto = %q, %v", to, err)
	}
	info, err := os.Stat(filepath.Join(to, "sub/run.sh"))
	if err != nil || info.Mode().Perm() != 0o755 {
		t.Fatalf("run.sh: %v %v", info, err)
	}
	if target, err := os.Readlink(filepath.Join(to, "link")); err != nil || target != "sub/run.sh" {
		t.Errorf("link: %q %v", target, err)
	}
	// Into itself, or a folder within it: refused.
	for _, dir := range []string{to, filepath.Join(to, "sub")} {
		if _, err := copyInto(to, dir); err == nil {
			t.Errorf("pasted %s into %s", to, dir)
		}
	}
}

func TestExplorerCopyPaste(t *testing.T) {
	hs := newHarness(t, true)
	a := hs.a
	// ⌘C copies the file chosen.
	if err := hs.tt.Click("main.go"); err != nil {
		t.Fatal(err)
	}
	hs.settle()
	hs.tt.Command("copy")
	if !slices.Equal(hs.h.clipboard, []string{hs.path("main.go")}) {
		t.Fatalf("clipboard %q", hs.h.clipboard)
	}

	// ⌘V into the folder chosen: a file of the Finder, and the one copied;
	// pasted again, it is named as a copy.
	other := filepath.Join(t.TempDir(), "notes.txt")
	os.WriteFile(other, []byte("hi\n"), 0o644)
	hs.h.clipboard = []string{other, hs.path("main.go")}
	a.revealInTree(hs.path("web/index.html"))
	hs.settle()
	hs.tt.Command("paste")
	hs.settle()
	for _, p := range []string{"web/notes.txt", "web/main.go"} {
		if _, err := os.Stat(hs.path(p)); err != nil {
			t.Errorf("%s: %v", p, err)
		}
	}
	if got := a.files.Item(a.fileRow); got != hs.path("web/notes.txt") {
		t.Errorf("chosen %q", got)
	}
	hs.tt.Command("paste")
	hs.settle()
	if _, err := os.Stat(hs.path("web/main copy.go")); err != nil {
		t.Error(err)
	}
}
