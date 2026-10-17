package main

import (
	"fmt"
	"slices"
	"strings"

	"mayoi/internal/git"
)

// askRenameBranch asks for a new name of a local branch, the one checked
// out when old is "". A branch that tracked an upstream stops tracking
// it, so that the next push publishes it under its new name.
func (a *app) askRenameBranch(old string) {
	g := &a.git
	if g.repo == nil {
		return
	}
	if old == "" {
		if g.status == nil || g.status.Branch == "" {
			a.fail("Check out a branch to rename it.")
			return
		}
		old = g.status.Branch
	}
	a.prompt = &prompt{title: "Rename Branch…", hint: "rename " + old, value: old, done: func(name string) string {
		name = strings.TrimSpace(name)
		switch {
		case name == old:
			return ""
		case !validBranch(name):
			return "Enter a branch name without spaces."
		case slices.Contains(g.branches, name):
			return "A branch with that name exists."
		}
		a.renameBranch(old, name)
		return ""
	}}
}

// renameBranch renames a local branch, which stops tracking its upstream.
func (a *app) renameBranch(old, name string) {
	g := &a.git
	upstream := ""
	a.gitDo("Renaming "+old+"…", func(r *git.Repo) error {
		_, up, err := r.BranchTip(old)
		if err != nil {
			return err
		}
		if err := r.RenameBranch(old, name); err != nil {
			return err
		}
		if up != "" {
			upstream = up
			return r.UnsetUpstream(name)
		}
		return nil
	}, func() {
		g.refsGen++
		msg := "Renamed " + old + " to " + name
		if upstream != "" {
			msg += ". Publish it to push it as " + name + "; " + upstream + " stays until you delete it"
		}
		a.tell(note{message: msg})
	})
}

// askDeleteBranch asks before deleting a local branch, offering to delete
// its upstream too when it has one. The branch checked out cannot go.
func (a *app) askDeleteBranch(name string) {
	g := &a.git
	r := g.repo
	if r == nil {
		return
	}
	if name == a.branch() {
		a.fail("Switch to another branch before deleting %s.", name)
		return
	}
	go func() {
		hash, upstream, err := r.BranchTip(name)
		a.post(func() {
			if g.repo != r {
				return
			}
			if err != nil {
				a.gitFailed(err)
				return
			}
			cf := &confirm{title: "Delete branch " + name + "?", ok: "Delete", danger: true,
				message: fmt.Sprintf("Its last commit is %s. Undo in the toast brings the branch back.", git.ShortHash(hash)),
				run:     func() { a.deleteBranch(name, hash, "", false) }}
			if upstream != "" {
				cf.alternate, cf.alternateShort = "Delete with "+upstream, "With Remote"
				cf.runAlternate = func() { a.deleteBranch(name, hash, upstream, false) }
			}
			a.confirm = cf
		})
	}()
}

// deleteBranch deletes a local branch at hash, and then its upstream when
// upstream is set. A branch whose commits are merged nowhere goes only by
// force, which it asks for.
func (a *app) deleteBranch(name, hash, upstream string, force bool) {
	g := &a.git
	notMerged, remoteGone := false, false
	a.gitDo("Deleting "+name+"…", func(r *git.Repo) error {
		if err := r.DeleteBranch(name, force); err != nil {
			if !force && git.NotMerged(err) {
				notMerged = true
				return nil
			}
			return err
		}
		if upstream != "" {
			if err := r.DeleteRemoteBranch(upstream); err != nil {
				return err
			}
			remoteGone = true
		}
		return nil
	}, func() {
		if notMerged {
			a.confirm = &confirm{title: name + " is not fully merged", ok: "Delete Anyway", danger: true,
				message: "Its commits are in no branch it was merged into. Deleting it leaves them only in the reflog.",
				run:     func() { a.deleteBranch(name, hash, upstream, true) }}
			return
		}
		g.refsGen++
		msg := "Deleted branch " + name
		if remoteGone {
			msg += " and " + upstream
		}
		a.tell(note{message: msg, label: "Undo", action: func() { a.restoreBranch(name, hash) }})
	})
}

// restoreBranch makes a deleted branch again at its commit.
func (a *app) restoreBranch(name, hash string) {
	g := &a.git
	a.gitDo("Restoring "+name+"…", func(r *git.Repo) error { return r.CreateBranch(name, hash) }, func() {
		g.refsGen++
		a.tell(note{message: "Restored branch " + name + " at " + git.ShortHash(hash)})
	})
}

// askDeleteRemoteBranch asks before deleting a branch of a remote, named
// as "origin/feature", on the remote.
func (a *app) askDeleteRemoteBranch(name string) {
	if a.git.repo == nil {
		return
	}
	remote, branch, _ := strings.Cut(name, "/")
	a.confirm = &confirm{title: "Delete " + name + "?", ok: "Delete", danger: true,
		message: "The branch " + branch + " is deleted on " + remote + ", for everyone who uses it.",
		run: func() {
			g := &a.git
			a.gitDo("Deleting "+name+"…", func(r *git.Repo) error { return r.DeleteRemoteBranch(name) }, func() {
				g.refsGen++
				a.tell(note{message: "Deleted " + name})
			})
		}}
}
