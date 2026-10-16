package workspace

import (
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"testing"
	"time"
)

func mkfiles(t *testing.T, root string, files ...string) {
	for _, f := range files {
		p := filepath.Join(root, f)
		os.MkdirAll(filepath.Dir(p), 0o755)
		if err := os.WriteFile(p, []byte(f), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

// post runs the tree's functions as a window's main thread would.
type mainThread chan func()

func (m mainThread) post(fn func()) { m <- fn }

func (m mainThread) wait(t *testing.T, until func() bool) {
	deadline := time.After(5 * time.Second)
	for !until() {
		select {
		case fn := <-m:
			fn()
		case <-deadline:
			t.Fatal("timed out")
		}
	}
}

func TestTreeLoadsSortsAndFollowsTheDisk(t *testing.T) {
	root := t.TempDir()
	mkfiles(t, root, "b.go", "A.md", "src/main.go", ".git/HEAD", "zeta/x")
	m := make(mainThread, 64)
	tree := NewTree(root, m.post)
	defer tree.Close()

	if kids := tree.Children(root); kids == nil || len(kids) != 0 {
		t.Fatalf("unread root: %v", kids)
	}
	tree.Load(root)
	m.wait(t, func() bool { return tree.Loaded(root) })
	var names []string
	for _, k := range tree.Children(root) {
		names = append(names, filepath.Base(k))
	}
	if want := []string{"src", "zeta", "A.md", "b.go"}; !slices.Equal(names, want) {
		t.Errorf("entries %v, want %v", names, want)
	}
	if tree.Children(filepath.Join(root, "b.go")) != nil {
		t.Error("a file has children")
	}

	mkfiles(t, root, "new.txt")
	m.wait(t, func() bool { return len(tree.Children(root)) == 5 })
	var changed []string
	tree.OnChange = func(c, r []string) { changed = append(changed, c...) }
	os.WriteFile(filepath.Join(root, "b.go"), []byte("changed"), 0o644)
	m.wait(t, func() bool { return slices.Contains(changed, filepath.Join(root, "b.go")) })
}

func TestIndexSkipsAndFuzzyRanks(t *testing.T) {
	root := t.TempDir()
	mkfiles(t, root, "src/main.go", "src/domain/manifest.json", "node_modules/m/index.js", "docs/README.md", "cmd/mayoi/main_test.go")
	files := Index(root)
	slices.Sort(files)
	if want := []string{"cmd/mayoi/main_test.go", "docs/README.md", "src/domain/manifest.json", "src/main.go"}; !slices.Equal(files, want) {
		t.Fatalf("index %v", files)
	}
	got := Fuzzy(files, "main", 10)
	if len(got) < 2 || files[got[0].Index] != "src/main.go" {
		var order []string
		for _, m := range got {
			order = append(order, files[m.Index])
		}
		t.Errorf("order %v", order)
	}
	if got := Fuzzy(files, "rdme", 10); len(got) == 0 || files[got[0].Index] != "docs/README.md" {
		t.Errorf("rdme: %v", got)
	}
	if got := Fuzzy(files, "zzz", 10); len(got) != 0 {
		t.Errorf("zzz: %v", got)
	}
}

func TestIndexLeavesOutWhatGitIgnores(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("no git")
	}
	root := t.TempDir()
	mkfiles(t, root, ".gitignore", "main.go", "build/app.bin", "src/a.go", "gone.go")
	os.WriteFile(filepath.Join(root, ".gitignore"), []byte("build/\n"), 0o644)
	git := func(args ...string) {
		cmd := exec.Command("git", append([]string{"-C", root, "-c", "user.name=t", "-c", "user.email=t@t"}, args...)...)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	git("init", "-q")
	git("add", ".")
	git("commit", "-qm", "x")
	os.Remove(filepath.Join(root, "gone.go"))
	mkfiles(t, root, "new.go")
	if ig := Ignored(root); !ig[filepath.Join(root, "build")] || len(ig) != 1 {
		t.Errorf("Ignored = %v", ig)
	}
	got := Index(root)
	slices.Sort(got)
	want := []string{".gitignore", "main.go", "new.go", "src/a.go"}
	if !slices.Equal(got, want) {
		t.Fatalf("Index = %v, want %v", got, want)
	}
}

// The tree leaves out the paths of its Exclude patterns, and shows them
// again as they change.
func TestTreeExcludes(t *testing.T) {
	root := t.TempDir()
	mkfiles(t, root, "a.go", "debug.log", "dist/x.js", "src/dist/y.js", "src/keep.go", "web/out/z.js")
	m := make(mainThread, 64)
	tree := NewTree(root, m.post)
	defer tree.Close()
	tree.Exclude = GlobsOf([]string{"*.log", "/dist", "web/out"})
	names := func(dir string) []string {
		var out []string
		for _, k := range tree.Children(dir) {
			out = append(out, filepath.Base(k))
		}
		return out
	}
	for _, dir := range []string{root, filepath.Join(root, "src"), filepath.Join(root, "web")} {
		tree.Load(dir)
		m.wait(t, func() bool { return tree.Loaded(dir) })
	}
	if got, want := names(root), []string{"src", "web", "a.go"}; !slices.Equal(got, want) {
		t.Errorf("root %v, want %v", got, want)
	}
	if got, want := names(filepath.Join(root, "src")), []string{"dist", "keep.go"}; !slices.Equal(got, want) {
		t.Errorf("src %v, want %v", got, want)
	}
	if got := names(filepath.Join(root, "web")); len(got) != 0 {
		t.Errorf("web %v, want nothing", got)
	}
	gen := tree.Gen()
	tree.SetExclude(nil)
	m.wait(t, func() bool { return tree.Gen() >= gen+3 })
	if got, want := names(root), []string{"dist", "src", "web", "a.go", "debug.log"}; !slices.Equal(got, want) {
		t.Errorf("root without excludes %v, want %v", got, want)
	}
}
