package main

import (
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// lineSuffix is the :line or :line:col after a path a program prints, as
// compilers, linters and agents print where they mean.
var lineSuffix = regexp.MustCompile(`:(\d+)(?::(\d+))?$`)

// splitTermLink splits a link a terminal printed into its path and its
// line and column, 1-based, 0 when it has none.
func splitTermLink(link string) (path string, line, col int) {
	path = link
	if m := lineSuffix.FindStringSubmatchIndex(link); m != nil {
		path = link[:m[0]]
		line, _ = strconv.Atoi(link[m[2]:m[3]])
		if m[4] >= 0 {
			col, _ = strconv.Atoi(link[m[4]:m[5]])
		}
	}
	return path, line, col
}

// hostPath is a path a program printed as this machine names it: on
// Windows, Git Bash's /c/... and WSL's /mnt/c/... are C:/....
func hostPath(p string) string {
	if hostOS != "windows" {
		return p
	}
	rest := strings.TrimPrefix(p, "/mnt")
	if len(rest) >= 2 && rest[0] == '/' && isDriveLetter(rest[1]) && (len(rest) == 2 || rest[2] == '/') {
		return strings.ToUpper(rest[1:2]) + ":" + rest[2:]
	}
	return p
}

func isDriveLetter(c byte) bool { return 'a' <= c && c <= 'z' || 'A' <= c && c <= 'Z' }

// termLinkTarget is the file or folder a link clicked in a terminal
// names, "" for none: a path, as of where the shell is, or a file URL.
func (a *app) termLinkTarget(s *session, link string) (path string, line, col int) {
	if u, err := url.Parse(link); err == nil && u.Scheme == "file" {
		p := u.Path
		if len(p) >= 3 && p[0] == '/' && p[2] == ':' {
			p = p[1:] // /C:/... on Windows
		}
		link = filepath.FromSlash(p)
	} else if strings.Contains(link, "://") || strings.HasPrefix(link, "mailto:") {
		return "", 0, 0
	}
	// Punctuation that ends the sentence around a path is not of it.
	p, line, col := splitTermLink(strings.TrimRight(link, ".,;"))
	p = filepath.FromSlash(hostPath(p))
	if rest, ok := strings.CutPrefix(p, "~"+string(filepath.Separator)); ok {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", 0, 0
		}
		p = filepath.Join(home, rest)
	}
	// A relative path is the program's, as of where the shell is now, or
	// else where it started, or the project.
	var tries []string
	if filepath.IsAbs(p) {
		tries = []string{p}
	} else {
		for _, dir := range []string{s.term.Dir(), s.dir, a.root} {
			if dir != "" {
				tries = append(tries, filepath.Join(dir, p))
			}
		}
	}
	for _, c := range tries {
		if _, err := os.Stat(c); err == nil {
			if abs, err := filepath.Abs(c); err == nil {
				c = abs
			}
			return c, line, col
		}
	}
	return "", 0, 0
}

// openTermLink opens what a Control+click (Command+click on macOS) on a
// terminal's link names: a file at its line and column, or a folder of the
// project in the Explorer. It reports whether it did, as a URL it leaves
// opens in the browser.
func (a *app) openTermLink(s *session, link string) bool {
	path, line, col := a.termLinkTarget(s, link)
	if path == "" {
		return false
	}
	if info, err := os.Stat(path); err == nil && info.IsDir() {
		if a.tree == nil || !strings.HasPrefix(path, a.root+string(filepath.Separator)) {
			return false
		}
		a.post(func() {
			a.window.SidebarClosed = false
			a.revealInTree(path)
		})
		return true
	}
	a.post(func() {
		a.openFile(path, true)
		if d := a.activeEditor(); line > 0 && d != nil && d.path == path {
			a.goToLine(line, col)
		}
	})
	return true
}
