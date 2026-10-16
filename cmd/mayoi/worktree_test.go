package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestOpenExistingWorktree(t *testing.T) {
	hs := newHarness(t, true)
	git := hs.gitRepo()
	a := hs.a
	other := filepath.Join(t.TempDir(), "other")
	git("worktree", "add", "-b", "topic", other)
	hs.settleGit()
	a.switchBranch("topic", false)
	hs.settleGit()
	if a.confirm == nil || a.confirm.title != "Open Existing Worktree?" {
		t.Fatalf("no question: %+v", a.confirm)
	}
	if a.confirm.okShort == "" || a.confirm.alternateShort == "" {
		t.Errorf("no short labels: %+v", a.confirm)
	}
	a.confirm.runAlternate()
	a.confirm = nil
	hs.settleGit()
	if w := hs.h.windows; len(w) != 1 || !strings.HasSuffix(w[0], "other") {
		t.Fatalf("windows %q", w)
	}

	// The worktree's folder deleted without git knowing: offer to prune it.
	if err := os.RemoveAll(other); err != nil {
		t.Fatal(err)
	}
	a.switchBranch("topic", false)
	hs.settleGit()
	if a.confirm == nil || a.confirm.title != "Worktree Folder Missing" {
		t.Fatalf("no question: %+v", a.confirm)
	}
	a.confirm.run()
	a.confirm = nil
	hs.settleGit()
	if head := strings.TrimSpace(git("branch", "--show-current")); head != "topic" {
		t.Fatalf("on %q after pruning", head)
	}
}
