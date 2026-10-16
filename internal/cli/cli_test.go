package cli

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"testing"
)

// The mayoi command hands absolute paths to the app.
func TestScript(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("a shell script")
	}
	dir := t.TempDir()
	bin := filepath.Join(dir, "bin")
	if err := write(bin, "/Apps/My Mayoi.app"); err != nil {
		t.Fatal(err)
	}
	// open says what it was asked, and knows no app by its identifier
	// when $NO_ID is set.
	os.WriteFile(filepath.Join(bin, "open"), []byte("#!/bin/sh\n[ \"$1\" = -b ] && [ -n \"$NO_ID\" ] && exit 1\nfor a in \"$@\"; do echo \"$a\"; done\n"), 0o755)
	run := func(env string, args ...string) []string {
		cmd := exec.Command(filepath.Join(bin, "mycode"), args...)
		cmd.Dir = dir
		cmd.Env = append(os.Environ(), "PATH="+bin+":/usr/bin:/bin", "PWD="+dir, env)
		out, err := cmd.Output()
		if err != nil {
			t.Fatal(err)
		}
		return strings.Split(strings.TrimSuffix(string(out), "\n"), "\n")
	}
	if got := run(""); !slices.Equal(got, []string{"-b", bundleID}) {
		t.Errorf("no args: %v", got)
	}
	got := run("", ".", "a b.go", "/abs/x")
	want := []string{"-b", bundleID, dir + "/.", dir + "/a b.go", "/abs/x"}
	if !slices.Equal(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}
	// Where the system knows no app by the identifier, the one it was
	// installed from.
	got = run("NO_ID=1", "x")
	want = []string{"-a", "/Apps/My Mayoi.app", dir + "/x"}
	if !slices.Equal(got, want) {
		t.Errorf("fallback: got %v, want %v", got, want)
	}
}

func TestInstallAndUninstall(t *testing.T) {
	dir := t.TempDir()
	first, second := filepath.Join(dir, "first"), filepath.Join(dir, "second")
	p, err := Install([]string{first, second}, "")
	if err != nil || p != filepath.Join(first, "mycode") {
		t.Fatalf("installed at %q: %v", p, err)
	}
	if info, err := os.Stat(p); err != nil || info.Mode().Perm()&0o111 == 0 {
		t.Fatalf("not executable: %v", err)
	}
	// Again, over its own.
	if _, err := Install([]string{first}, ""); err != nil {
		t.Fatal(err)
	}
	// Another program's command stays.
	os.MkdirAll(second, 0o755)
	foreign := filepath.Join(second, "mycode")
	os.WriteFile(foreign, []byte("#!/bin/sh\necho other\n"), 0o755)
	if _, err := Install([]string{second}, ""); err == nil {
		t.Error("overwrote another program's mayoi")
	}
	removed, err := Uninstall([]string{first, second})
	if err != nil || !slices.Equal(removed, []string{p}) {
		t.Fatalf("removed %v: %v", removed, err)
	}
	if _, err := os.Stat(foreign); err != nil {
		t.Error("removed another program's mayoi")
	}
}

func TestDirs(t *testing.T) {
	local := filepath.Join("/home/u", ".local", "bin")
	if got := Dirs("/home/u", []string{"/usr/bin", local}); !slices.Equal(got, []string{local, "/usr/local/bin"}) {
		t.Errorf("on the path: %v", got)
	}
	if got := Dirs("/home/u", []string{"/usr/bin"}); !slices.Equal(got, []string{"/usr/local/bin"}) {
		t.Errorf("off the path: %v", got)
	}
}
