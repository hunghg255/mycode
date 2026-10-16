package main

import (
	"os"
	"path/filepath"
	"slices"
	"testing"
)

// The filesExclude setting hides files and folders from the explorer, and
// from the files quick open and search look in, and they come back as it
// changes.
func TestFilesExclude(t *testing.T) {
	hs := newHarness(t, true)
	a := hs.a
	for _, f := range []string{"keep.go", "debug.log", "dist/app.js", "src/main.go"} {
		os.MkdirAll(filepath.Dir(hs.path(f)), 0o755)
		os.WriteFile(hs.path(f), []byte("x\n"), 0o644)
	}
	shown := func(path string) bool { return slices.Contains(a.tree.Children(a.root), path) }
	indexed := func(rel string) bool { return slices.Contains(a.index, rel) }

	a.settings.FilesExclude = map[string]bool{"*.log": true, "dist": true, "src": false}
	a.excludesChanged()
	hs.until("the excluded files to go", func() bool {
		a.refreshIndex() // as quick open and search do
		return indexed("keep.go") && !indexed("debug.log") && !shown(hs.path("debug.log")) && shown(hs.path("keep.go"))
	})
	if shown(hs.path("dist")) || !shown(hs.path("src")) {
		t.Error("the explorer shows dist, or not src")
	}
	if indexed("debug.log") || indexed("dist/app.js") || !indexed("keep.go") || !indexed("src/main.go") {
		t.Errorf("the files listed are %v", a.index)
	}

	a.settings.FilesExclude = nil
	a.excludesChanged()
	hs.until("the excluded files to come back", func() bool {
		a.refreshIndex()
		return indexed("debug.log") && indexed("dist/app.js") && shown(hs.path("dist"))
	})
}
