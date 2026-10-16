package main

import (
	"errors"
	"fmt"
	"mayoi/internal/git"
	"mayoi/internal/vfs"
	"os"
)

// Opening an existing checkout never changes the branch in either worktree.
func (a *app) askOpenWorktree(branch, path string) {
	r := a.git.repo
	if _, err := os.Stat(path); errors.Is(err, os.ErrNotExist) {
		a.askPruneWorktree(branch, path)
		return
	}
	open := func(newWindow bool) {
		if a.git.repo != r {
			return
		}
		a.gitDo("Opening worktree…", func(_ *git.Repo) error {
			info, err := vfs.Stat(path)
			if err != nil {
				return err
			}
			if !info.IsDir() {
				return fmt.Errorf("worktree is not a folder: %s", path)
			}
			return nil
		}, func() {
			if newWindow {
				a.host.newWindow(path)
			} else {
				a.switchFolder(path)
			}
		})
	}
	a.confirm = &confirm{
		title:          "Open Existing Worktree?",
		message:        fmt.Sprintf("The branch %q is already checked out in:\n\n%s\n\nChoose where to open this worktree.", branch, shortenHome(path)),
		ok:             "Open in Current Window",
		okShort:        "Current Window",
		run:            func() { open(false) },
		alternate:      "Open in New Window",
		alternateShort: "New Window",
		runAlternate:   func() { open(true) },
	}
}

// askPruneWorktree offers to forget a worktree whose folder was deleted
// without git knowing, which still holds the branch, and to switch to it.
func (a *app) askPruneWorktree(branch, path string) {
	r := a.git.repo
	a.confirm = &confirm{
		title:   "Worktree Folder Missing",
		message: fmt.Sprintf("The branch %q is checked out in a worktree whose folder is gone:\n\n%s\n\nPrune the missing worktree and switch to the branch here?", branch, shortenHome(path)),
		ok:      "Prune and Switch",
		run: func() {
			if a.git.repo != r {
				return
			}
			a.gitDo("Switching to "+branch+"…", func(r *git.Repo) error {
				if err := r.PruneWorktrees(); err != nil {
					return err
				}
				err := r.Switch(branch, false)
				if occupied, ok := errors.AsType[*git.WorktreeInUse](err); ok {
					// Pruning keeps a locked worktree.
					return fmt.Errorf("the worktree at %s is locked; unlock it with git worktree unlock", occupied.Path)
				}
				return err
			}, nil)
		},
	}
}
