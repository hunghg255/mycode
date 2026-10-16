// Package workspace is the folder Mayoi has open: its file tree, read a
// directory at a time as the user opens them and kept up to date as files
// change on disk, and an index of its files for quick open.
package workspace

import (
	"cmp"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/fsnotify/fsnotify"

	"mayoi/internal/vfs"
)

// Hidden reports whether the file tree leaves an entry out.
func Hidden(name string) bool {
	switch name {
	case ".git", ".DS_Store", ".hg", ".svn", "Thumbs.db":
		return true
	}
	return false
}

// Skipped reports whether the index of files leaves out a directory.
func Skipped(name string) bool {
	return slices.Contains(skippedNames, name)
}

// skippedNames are the directories the index of files leaves out: build
// output and dependencies, and those the tree hides.
var skippedNames = []string{"node_modules", ".next", ".turbo", ".cache", "__pycache__", ".venv", "target", ".gradle",
	".git", ".DS_Store", ".hg", ".svn", "Thumbs.db"}

// Tree is the file tree of a folder. Its methods run on the main thread,
// except where they say otherwise; it reads directories in the background
// and hands their entries to the main thread with post.
type Tree struct {
	Root string
	// Exclude are the patterns of the paths, relative to Root, the tree
	// leaves out, besides those Hidden names: SetExclude changes them.
	Exclude Globs

	post func(func()) // runs a function on the main thread

	children map[string][]string // a directory's entries, sorted
	dirs     map[string]bool     // the directories among entries
	loading  map[string]bool
	gen      int // bumped by every change of the tree

	watcher *fsnotify.Watcher
	watched map[string]bool
	// OnChange is called on the main thread with the files that changed
	// on disk, and those removed.
	OnChange func(changed, removed []string)
	mu      sync.Mutex
	pending map[string]bool // directories to read again
	files   map[string]bool // files written
	gone    map[string]bool // paths removed
	timer   *time.Timer
	closed  bool
}

// NewTree opens the tree of root. post runs a function on the main thread.
func NewTree(root string, post func(func())) *Tree {
	t := &Tree{
		Root: root, post: post,
		children: map[string][]string{}, dirs: map[string]bool{root: true}, loading: map[string]bool{},
		watched: map[string]bool{},
	}
	if w, err := fsnotify.NewWatcher(); err == nil {
		t.watcher = w
		go t.watch()
	}
	return t
}

// Close stops watching the tree.
func (t *Tree) Close() {
	t.mu.Lock()
	t.closed = true
	if t.timer != nil {
		t.timer.Stop()
	}
	t.mu.Unlock()
	if t.watcher != nil {
		t.watcher.Close()
	}
}

// Gen changes whenever the tree does.
func (t *Tree) Gen() int { return t.gen }

// IsDir reports whether path is a directory of the tree.
func (t *Tree) IsDir(path string) bool { return t.dirs[path] }

// Loaded reports whether a directory's entries were read.
func (t *Tree) Loaded(dir string) bool {
	_, ok := t.children[dir]
	return ok
}

// Children returns a directory's entries, nil for a file and an empty
// slice for a directory not read yet: Load reads it.
func (t *Tree) Children(path string) []string {
	if !t.dirs[path] {
		return nil
	}
	if kids, ok := t.children[path]; ok {
		return kids
	}
	return []string{}
}

// Load reads a directory's entries in the background, unless they were.
func (t *Tree) Load(dir string) {
	if !t.dirs[dir] || t.loading[dir] {
		return
	}
	if _, ok := t.children[dir]; ok {
		return
	}
	t.reload(dir)
}

func (t *Tree) reload(dir string) {
	t.loading[dir] = true
	go func() {
		entries, _ := vfs.ReadDir(dir)
		t.post(func() {
			delete(t.loading, dir)
			if !t.dirs[dir] {
				return // removed meanwhile
			}
			kids, dirs := sortEntries(dir, entries, t.excluded)
			t.set(dir, kids, dirs)
		})
	}()
}

// set records a directory's entries.
func (t *Tree) set(dir string, kids []string, dirs map[string]bool) {
	old := t.children[dir]
	for _, k := range old {
		if t.dirs[k] && !dirs[k] {
			t.forget(k)
		}
	}
	for k := range dirs {
		t.dirs[k] = true
	}
	t.children[dir] = kids
	t.gen++
	if t.watcher != nil && !t.watched[dir] {
		if t.watcher.Add(dir) == nil {
			t.watched[dir] = true
		}
	}
}

// forget drops a directory, and those inside it, from the tree.
func (t *Tree) forget(dir string) {
	for _, k := range t.children[dir] {
		if t.dirs[k] {
			t.forget(k)
		}
	}
	delete(t.children, dir)
	delete(t.dirs, dir)
	if t.watched[dir] {
		t.watcher.Remove(dir)
		delete(t.watched, dir)
	}
}

// SetExclude makes g the patterns the tree leaves out, and reads its
// directories again.
func (t *Tree) SetExclude(g Globs) {
	t.Exclude = g
	t.Refresh()
}

// Refresh reads every directory read so far again.
func (t *Tree) Refresh() {
	for dir := range t.children {
		if !t.loading[dir] {
			t.reload(dir)
		}
	}
}

// sortEntries are the paths of a directory's entries, directories first,
// then files, each by name, as the file managers sort them, and the
// directories among them.
func sortEntries(dir string, entries []vfs.Entry, excluded func(string) bool) ([]string, map[string]bool) {
	kids := make([]string, 0, len(entries))
	dirs := map[string]bool{}
	for _, e := range entries {
		if Hidden(e.Name) {
			continue
		}
		p := filepath.Join(dir, e.Name)
		if excluded != nil && excluded(p) {
			continue
		}
		if e.Dir {
			dirs[p] = true
		}
		kids = append(kids, p)
	}
	slices.SortFunc(kids, func(a, b string) int {
		if dirs[a] != dirs[b] {
			if dirs[a] {
				return -1
			}
			return 1
		}
		return compareNames(filepath.Base(a), filepath.Base(b))
	})
	return kids, dirs
}

// excluded reports whether the patterns of Exclude match path.
func (t *Tree) excluded(path string) bool {
	return len(t.Exclude) > 0 && t.Exclude.Match(t.Rel(path))
}

// compareNames orders names case-insensitively, then by case.
func compareNames(a, b string) int {
	return cmp.Or(cmp.Compare(strings.ToLower(a), strings.ToLower(b)), cmp.Compare(a, b))
}

// watch gathers the watcher's events and reads the directories they
// changed again, a moment after the last, so that a burst of changes, as
// a checkout or a build makes, reads each directory once.
func (t *Tree) watch() {
	for {
		select {
		case ev, ok := <-t.watcher.Events:
			if !ok {
				return
			}
			t.event(ev.Name, ev.Has(fsnotify.Create), ev.Has(fsnotify.Remove) || ev.Has(fsnotify.Rename), ev.Has(fsnotify.Write))
		case _, ok := <-t.watcher.Errors:
			if !ok {
				return
			}
		}
	}
}

// event gathers a change of a file, which the next flush takes: made,
// removed or renamed away, or written. Safe from any goroutine.
func (t *Tree) event(name string, created, removed, written bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.pending == nil {
		t.pending, t.files, t.gone = map[string]bool{}, map[string]bool{}, map[string]bool{}
	}
	if created || removed {
		t.pending[filepath.Dir(name)] = true
	}
	if removed {
		t.gone[name] = true
	}
	if written || created {
		t.files[name] = true
		delete(t.gone, name)
	}
	if t.timer == nil && !t.closed {
		t.timer = time.AfterFunc(120*time.Millisecond, t.flush)
	}
}

func (t *Tree) flush() {
	t.mu.Lock()
	dirs, files, gone := t.pending, t.files, t.gone
	t.pending, t.files, t.gone, t.timer = nil, nil, nil, nil
	closed := t.closed
	t.mu.Unlock()
	if closed {
		return
	}
	t.post(func() {
		for dir := range dirs {
			if _, ok := t.children[dir]; ok && !t.loading[dir] {
				t.reload(dir)
			}
		}
		if t.OnChange != nil && (len(files) > 0 || len(gone) > 0) {
			var changed, removed []string
			for f := range files {
				changed = append(changed, f)
			}
			for f := range gone {
				removed = append(removed, f)
			}
			t.OnChange(changed, removed)
		}
	})
}

// Watch watches a file's directory, as for a file open in the editor
// outside the directories the tree read.
func (t *Tree) Watch(path string) {
	dir := filepath.Dir(path)
	if t.watcher == nil || t.watched[dir] {
		return
	}
	if t.watcher.Add(dir) == nil {
		t.watched[dir] = true
	}
}

// Rel returns path relative to the root, with slashes.
func (t *Tree) Rel(path string) string {
	rel, err := filepath.Rel(t.Root, path)
	if err != nil {
		return path
	}
	return filepath.ToSlash(rel)
}

// SkippedDirs are the names of the directories the index leaves out.
func SkippedDirs() []string { return slices.Clone(skippedNames) }
