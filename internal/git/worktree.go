package git

import (
	"fmt"
	"strings"

)

// WorktreeInUse reports a branch checked out in another worktree.
type WorktreeInUse struct{ Branch, Path string }

func (e *WorktreeInUse) Error() string {
	return fmt.Sprintf("branch %q is checked out in %s", e.Branch, e.Path)
}

// WorktreeForBranch returns the checkout owning a local branch, in the same
// filesystem namespace as the repository. NUL records preserve unusual paths.
func (r *Repo) WorktreeForBranch(branch string) (string, error) {
	out, err := r.run(nil, "worktree", "list", "--porcelain", "-z")
	if err != nil {
		return "", err
	}
	return worktreeForBranch(r.Root, string(out), branch), nil
}

func worktreeForBranch(root, out, branch string) string {
	var path string
	for _, field := range strings.Split(out, "\x00") {
		switch {
		case field == "":
			path = ""
		case strings.HasPrefix(field, "worktree "):
			path = strings.TrimPrefix(field, "worktree ")
		case field == "branch refs/heads/"+branch && path != "":
			return path
		}
	}
	return ""
}

// PruneWorktrees forgets the worktrees whose folders are gone, which keep
// their branches checked out until it does.
func (r *Repo) PruneWorktrees() error {
	_, err := r.run(nil, "worktree", "prune")
	return err
}
