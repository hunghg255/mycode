package main

import (
	"net/url"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestSplitTermLink(t *testing.T) {
	for _, c := range []struct {
		link      string
		path      string
		line, col int
	}{
		{"main.go", "main.go", 0, 0},
		{"main.go:12", "main.go", 12, 0},
		{"cmd/mayoi/app.go:12:5", "cmd/mayoi/app.go", 12, 5},
		{`C:\src\a.go:3:1`, `C:\src\a.go`, 3, 1},
		{"C:/src/a.go", "C:/src/a.go", 0, 0},
	} {
		path, line, col := splitTermLink(c.link)
		if path != c.path || line != c.line || col != c.col {
			t.Errorf("%q: %q %d %d, want %q %d %d", c.link, path, line, col, c.path, c.line, c.col)
		}
	}
}

func TestHostPathOnWindows(t *testing.T) {
	defer func(os string) { hostOS = os }(hostOS)
	hostOS = "windows"
	for in, want := range map[string]string{
		"/c/Users/me/a.go":   "C:/Users/me/a.go",
		"/mnt/d/projects/x":  "D:/projects/x",
		"/d":                 "D:",
		"/usr/lib/x":         "/usr/lib/x",
		"/cd/x":              "/cd/x",
		"internal/a/a.go":    "internal/a/a.go",
		"D:/projects/mycode": "D:/projects/mycode",
	} {
		if got := hostPath(in); got != want {
			t.Errorf("%q: %q, want %q", in, got, want)
		}
	}
	hostOS = "darwin"
	if got := hostPath("/c/x"); got != "/c/x" {
		t.Errorf("macOS changed /c/x to %q", got)
	}
}

// TestTerminalLinkOpensFile: a Control+click on a path a terminal printed
// opens the file at its line and column, as of the shell's folder.
func TestTerminalLinkOpensFile(t *testing.T) {
	if testing.Short() {
		t.Skip("starts a shell")
	}
	if runtime.GOOS != "windows" {
		t.Setenv("SHELL", "/bin/sh")
	}
	hs := newHarness(t, true)
	a := hs.a
	t.Cleanup(a.closeTerminals)
	a.newTerminal()
	hs.settle()
	s := a.panelTerm

	opens := func(link, rel string, line, col int) {
		t.Helper()
		if !a.openTermLink(s, link) {
			t.Fatalf("%q did not open", link)
		}
		hs.settle()
		d := a.activeEditor()
		if d == nil || d.path != hs.path(rel) {
			t.Fatalf("%q: the editor shows %v, want %s", link, d, rel)
		}
		snap := d.buf.Snapshot()
		at := d.sel[1]
		l := snap.LineAt(at)
		start, _ := snap.LineRange(l)
		if l+1 != line || at-start+1 != col {
			t.Errorf("%q: caret at %d:%d, want %d:%d", link, l+1, at-start+1, line, col)
		}
	}
	opens("internal/a/a.go:3:7", "internal/a/a.go", 3, 7)
	opens("./main.go:6", "main.go", 6, 1)
	opens(hs.path("README.md")+":3", "README.md", 3, 1)
	opens(filepath.ToSlash(hs.path("internal/b/b.ts")), "internal/b/b.ts", 1, 1)
	opens("go.mod:3.", "go.mod", 3, 1)
	if runtime.GOOS == "windows" {
		opens(`internal\a\a.go:3:7`, "internal/a/a.go", 3, 7)
		opens(`.\web\index.html:2`, "web/index.html", 2, 1)
	}
	u := url.URL{Scheme: "file", Path: filepath.ToSlash(hs.path("web/style.css"))}
	if !strings.HasPrefix(u.Path, "/") {
		u.Path = "/" + u.Path
	}
	opens(u.String(), "web/style.css", 1, 1)

	for _, link := range []string{"nothere.go:1", "https://example.com/a.go", "mailto:me@example.com"} {
		if a.openTermLink(s, link) {
			t.Errorf("%q opened", link)
		}
	}

	// A folder of the project shows in the Explorer.
	a.window.SidebarClosed = true
	if !a.openTermLink(s, "internal/a") {
		t.Fatal("a folder did not open")
	}
	hs.settle()
	if a.window.SidebarClosed || !a.files.Open.Has(hs.path("internal")) {
		t.Errorf("the folder is not shown in the Explorer")
	}
}
