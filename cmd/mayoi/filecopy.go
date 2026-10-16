package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/egoist/mygo/ui"

)

// ⌘C in the explorer puts the file chosen on the clipboard as the Finder
// copies files, and ⌘V copies the files the clipboard has, of another
// window or of the Finder, into the folder chosen.

// explorerInput takes the Copy and Paste of the Edit menu while the
// explorer has the keyboard.
func (a *app) explorerInput(ev ui.InputEvent) bool {
	if ev.Kind != ui.InputCommand {
		return false
	}
	switch ev.Text {
	case "copy":
		if a.fileRow < 0 || a.fileRow >= a.files.Rows() {
			return false
		}
		a.copyFiles(a.files.Item(a.fileRow))
		return true
	case "paste":
		a.pasteFiles(a.targetDir())
		return true
	}
	return false
}

func (a *app) copyFiles(paths ...string) {
	if err := a.host.copyFiles(paths); err != nil {
		a.fail("Could not copy: %v", err)
	}
}

// clipboardSources are the files the clipboard has, those of the Finder.
func (a *app) clipboardSources() []string { return a.host.clipboardFiles() }

// pasteFiles copies the files of the clipboard into dir, and chooses the
// first of them in the tree.
func (a *app) pasteFiles(dir string) { a.copyPathsInto(a.clipboardSources(), dir) }

// copyPathsInto copies files and folders into dir, as a paste or a drop
// on the explorer does.
func (a *app) copyPathsInto(srcs []string, dir string) {
	if len(srcs) == 0 {
		return
	}
	var first string
	for _, p := range srcs {
		to, err := copyInto(p, dir)
		if err != nil {
			a.fail("Could not paste %s: %v", filepath.Base(p), err)
			continue
		}
		if first == "" {
			first = to
		}
	}
	a.pasted(dir, first)
}

// pasted shows the files pasted into dir in the tree, and chooses first.
func (a *app) pasted(dir, first string) {
	if first == "" || a.tree == nil {
		return
	}
	if dir != a.root {
		a.files.Open.Add(dir)
	}
	a.tree.Refresh()
	a.indexStale = true
	a.selectInTree = first
}

// copyInto copies the file or folder at src into dir, under a name of
// its own there, and returns where it went.
func copyInto(src, dir string) (string, error) {
	info, err := os.Lstat(src)
	if err != nil {
		return "", err
	}
	if info.IsDir() && (dir == src || strings.HasPrefix(dir, src+string(filepath.Separator))) {
		return "", errors.New("a folder cannot be pasted into itself")
	}
	to := freeName(dir, filepath.Base(src), info.IsDir())
	return to, copyEntry(src, to)
}

// freeName is name in dir, or, when that is taken, "name copy", then
// "name copy 2" and on, before the extension of a file, as the Finder
// names them.
func freeName(dir, name string, isDir bool) string {
	path := filepath.Join(dir, name)
	if _, err := os.Lstat(path); err != nil {
		return path
	}
	stem, ext := name, ""
	if e := filepath.Ext(name); !isDir && e != name {
		stem, ext = strings.TrimSuffix(name, e), e
	}
	for n := 1; ; n++ {
		suffix := " copy"
		if n > 1 {
			suffix = fmt.Sprintf(" copy %d", n)
		}
		path = filepath.Join(dir, stem+suffix+ext)
		if _, err := os.Lstat(path); err != nil {
			return path
		}
	}
}

// copyEntry copies a file, a link or a folder with all it has, keeping
// their modes.
func copyEntry(src, dst string) error {
	info, err := os.Lstat(src)
	if err != nil {
		return err
	}
	switch {
	case info.Mode()&os.ModeSymlink != 0:
		target, err := os.Readlink(src)
		if err != nil {
			return err
		}
		return os.Symlink(target, dst)
	case info.IsDir():
		if err := os.Mkdir(dst, info.Mode().Perm()); err != nil {
			return err
		}
		entries, err := os.ReadDir(src)
		if err != nil {
			return err
		}
		for _, e := range entries {
			if err := copyEntry(filepath.Join(src, e.Name()), filepath.Join(dst, e.Name())); err != nil {
				return err
			}
		}
		return nil
	}
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_EXCL, info.Mode().Perm())
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}
