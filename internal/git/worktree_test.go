package git

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestWorktreeForBranch(t *testing.T) {
	r, git := repo(t)
	path := filepath.Join(t.TempDir(), "work tree\nquoted\"name")
	git("worktree", "add", "-b", "topic", path)
	// Git canonicalizes the temporary directory's symlink on macOS.
	want, err := filepath.EvalSymlinks(path)
	if err != nil {
		t.Fatal(err)
	}
	got, err := r.WorktreeForBranch("topic")
	if err != nil || got != want {
		t.Fatalf("got %q, %v; want %q", got, err, want)
	}
	got, err = r.WorktreeForBranch("missing")
	if err != nil || got != "" {
		t.Fatalf("missing: %q, %v", got, err)
	}
	var occupied *WorktreeInUse
	if switchErr := r.Switch("topic", false); !errors.As(switchErr, &occupied) || occupied.Path != want {
		t.Fatalf("switch occupied branch: %v", switchErr)
	}
	current, err := r.run(nil, "symbolic-ref", "--short", "HEAD")
	if err != nil || strings.TrimSpace(string(current)) != "main" {
		t.Fatalf("original branch changed: %q, %v", current, err)
	}
}

func TestPruneMissingWorktree(t *testing.T) {
	r, git := repo(t)
	path := filepath.Join(t.TempDir(), "gone")
	git("worktree", "add", "-b", "topic", path)
	if err := os.RemoveAll(path); err != nil {
		t.Fatal(err)
	}
	var occupied *WorktreeInUse
	if err := r.Switch("topic", false); !errors.As(err, &occupied) {
		t.Fatalf("switch to the branch of a missing worktree: %v", err)
	}
	if err := r.PruneWorktrees(); err != nil {
		t.Fatal(err)
	}
	if err := r.Switch("topic", false); err != nil {
		t.Fatalf("switch after pruning: %v", err)
	}
}
