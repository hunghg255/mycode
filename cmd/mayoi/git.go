package main

import (
	"cmp"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/egoist/mygo/ui"

	"mayoi/internal/git"
)

// gitState is what the window knows of the Git work tree its folder is
// in: the files that differ from HEAD, the branch, and the commands
// running.
type gitState struct {
	repo *git.Repo // nil outside a work tree
	// looked is set once the folder was looked up, looking while it is.
	looked, looking bool
	lookup          *int // the lookup running, which a reset drops

	status   *git.Status
	branches []string // the local branches, read with the status
	remotes  []string // the remotes, read with the status
	// remotesStale has the next read of the status read the remotes too.
	remotesStale bool
	// entries are the files that differ, by path; dirs the folders above
	// them, with the letter of the one that matters most.
	entries map[string]git.Entry
	dirs    map[string]byte
	// groups are the files of status in each group of the source control
	// view, worked out for the status groupsOf.
	groups   [groupCount][]git.Entry
	groupsOf *git.Status
	// stale has the next frame read the status again, unless running;
	// read is when it was read last.
	stale, running bool
	read           time.Time

	// meta is when the files Git changes as HEAD moves last changed, and
	// checked when the app last looked.
	meta, checked time.Time
	// refsMeta is when the refs last changed, and refsGen counts the
	// changes, for the history to be read again.
	refsMeta time.Time
	refsGen  int

	// busy names the command running in the background, as "Pushing…",
	// which the status bar shows; "" while none. pending counts the
	// commands running, named or not.
	busy    string
	pending int
	// message is the commit message being written, and amend set while
	// it is to amend the last commit.
	message string
	amend   bool

	// history is the last commits of HEAD, newest first, and unpushed
	// those its upstream lacks, read for the state historyOf names;
	// historyN is how many to read, historyGen counts the reads.
	history        []git.Commit
	unpushed       map[string]bool
	historyOf      string
	historyN       int
	historyGen     int
	loadingHistory bool
	// graph is the lanes of history, laid out for the read graphOf
	// counts.
	graph   []graphRow
	graphOf int
	// tags are the names of the tags, read with the history.
	tags []string
	// reach is the commits of history that HEAD has, worked out for the
	// HEAD and the read reachOf names.
	reach   map[string]bool
	reachOf string
}

// historyPage is how many commits the history reads at first, and more
// each time more are asked for.
const historyPage = 50

// statusEvery is how often the status is read again on its own, for the
// files changed in folders the tree does not watch.
const statusEvery = 5 * time.Second

// lookUpRepo finds the work tree of the folder in the background.
func (a *app) lookUpRepo() {
	g := &a.git
	if a.root == "" || g.looked || g.looking {
		return
	}
	g.looking = true
	root := a.root
	// The lookup, which a folder opened anew, the same one or not, drops:
	// it found what was there before.
	tok := new(int)
	g.lookup = tok
	go func() {
		r, err := git.Open(root)
		a.post(func() {
			if a.root != root || g.lookup != tok {
				return
			}
			g.looking, g.looked = false, true
			if err == nil {
				g.repo, g.stale, g.remotesStale = r, true, true
			}
		})
	}()
}

// refreshGit runs once a frame: it looks up the work tree, notices HEAD
// moving, and reads the status again when it may have changed.
func (a *app) refreshGit() {
	a.lookUpRepo()
	g := &a.git
	if g.repo == nil {
		return
	}
	if time.Since(g.checked) >= 1500*time.Millisecond {
		g.checked = time.Now()
		a.tookGitMeta(gitMeta(g.repo))
	}
	a.refreshHistory()
	if g.running || !g.stale && time.Since(g.read) < statusEvery {
		return
	}
	g.running, g.stale = true, false
	r := g.repo
	// The remotes change seldom: they are read again with the status after
	// a command, or as HEAD moves, not every few seconds.
	readRemotes := g.remotesStale
	g.remotesStale = false
	go func() {
		st, err := r.Status()
		branches, _ := r.Branches()
		var remotes []string
		var remotesErr error
		if readRemotes {
			remotes, remotesErr = r.Remotes()
		}
		a.post(func() {
			g.running, g.read = false, time.Now()
			if g.repo != r {
				return
			}
			if err != nil {
				return
			}
			a.setStatus(st)
			g.branches = branches
			if readRemotes && remotesErr == nil {
				g.remotes = remotes
			}
		})
	}()
}

// historyKey names the state the history is read for: where HEAD and its
// upstream are, and how many commits are asked for.
func (a *app) historyKey() string {
	g := &a.git
	st := g.status
	if st == nil {
		return ""
	}
	return fmt.Sprintf("%s|%s|%d|%d|%d|%d|%t|%d", st.Head, st.Upstream, st.Ahead, st.Behind, max(g.historyN, historyPage),
		len(g.remotes), a.settings.ScmAllBranches, g.refsGen)
}

// refreshHistory reads the last commits again in the background when HEAD
// or its upstream moved, or more are asked for.
func (a *app) refreshHistory() {
	g := &a.git
	st := g.status
	if g.repo == nil || st == nil || g.loadingHistory {
		return
	}
	n := max(g.historyN, historyPage)
	key := a.historyKey()
	if key == g.historyOf {
		return
	}
	g.loadingHistory = true
	// Without a remote nothing is pushed or not: no commit is marked.
	r, remotes, all := g.repo, len(g.remotes) > 0, a.settings.ScmAllBranches
	go func() {
		cs, err := r.Log(n, all)
		var unpushed map[string]bool
		if remotes {
			unpushed = r.Unpushed(n)
		}
		tags, _ := r.Tags()
		a.post(func() {
			g.loadingHistory = false
			if g.repo != r {
				return
			}
			g.historyOf = key
			if err != nil {
				return
			}
			g.history, g.unpushed, g.tags = cs, unpushed, tags
			g.historyGen++
		})
	}()
}

// tookGitMeta takes when the files HEAD moving changes last changed, and
// the refs: as they change, the documents compare their lines again, and
// the history is read again.
func (a *app) tookGitMeta(t, refs time.Time) {
	g := &a.git
	if !t.Equal(g.meta) {
		if !g.meta.IsZero() {
			a.gitChanged()
		}
		g.meta = t
	}
	if !refs.Equal(g.refsMeta) {
		if !g.refsMeta.IsZero() {
			g.refsGen++
		}
		g.refsMeta = refs
	}
}

// gitMeta returns when the files that HEAD moving changes last changed:
// the index, HEAD and its log, and what a fetch writes; and when the refs
// did, as a branch or tag is made, moved or deleted.
func gitMeta(r *git.Repo) (head, refs time.Time) {
	for _, p := range []string{
		filepath.Join(r.Dir, "index"), filepath.Join(r.Dir, "HEAD"), filepath.Join(r.Dir, "logs", "HEAD"),
		filepath.Join(r.Common, "FETCH_HEAD"),
	} {
		if info, err := os.Stat(p); err == nil && info.ModTime().After(head) {
			head = info.ModTime()
		}
	}
	later := func(p string) {
		if info, err := os.Stat(p); err == nil && info.ModTime().After(refs) {
			refs = info.ModTime()
		}
	}
	later(filepath.Join(r.Common, "packed-refs"))
	// A ref written goes in by a rename, which changes its folder's time.
	filepath.WalkDir(filepath.Join(r.Common, "refs"), func(p string, d os.DirEntry, err error) error {
		if err == nil && d.IsDir() {
			later(p)
		}
		return nil
	})
	return head, refs
}

// setStatus takes a status read, and the folders above its files. A
// status that says what the last did is dropped, so that what is worked
// out from it, from the rows of source control to those of the diff, is
// kept.
func (a *app) setStatus(st *git.Status) {
	g := &a.git
	if g.status.Equal(st) {
		return
	}
	g.status = st
	g.entries = make(map[string]git.Entry, len(st.Entries))
	g.dirs = map[string]byte{}
	for _, e := range st.Entries {
		g.entries[e.Path] = e
		l := e.Letter()
		for d := filepath.Dir(e.Path); len(d) >= len(g.repo.Root); d = filepath.Dir(d) {
			if old, ok := g.dirs[d]; ok && letterRank(old) >= letterRank(l) {
				break
			}
			g.dirs[d] = l
			if d == filepath.Dir(d) {
				break
			}
		}
	}
}

// letterRank orders the letters of files by how much a folder above them
// shows it: a conflict before a change before a file added.
func letterRank(l byte) int {
	switch l {
	case 'C':
		return 4
	case 'M', 'R', 'T', 'D':
		return 3
	case 'A':
		return 2
	case 'U':
		return 1
	}
	return 0
}

// branch is the branch checked out, or the commit when HEAD is detached,
// "" outside a work tree.
func (a *app) branch() string {
	st := a.git.status
	switch {
	case st == nil:
		return ""
	case st.Branch != "":
		return st.Branch
	case st.Head != "":
		return git.ShortHash(st.Head)
	}
	return ""
}

// gitChanged has the documents read their bases again, and the status be
// read again, as when a commit may have been made.
func (a *app) gitChanged() {
	for _, d := range a.docs {
		d.git.HeadMoved()
	}
	a.diffsChanged()
	a.git.stale, a.git.remotesStale = true, true
}

// gitDo runs a command on the work tree in the background, naming it
// busy while it runs when busy is set, then reads the status again and
// calls then, unless it failed: then it says why.
func (a *app) gitDo(busy string, fn func(r *git.Repo) error, then func()) {
	g := &a.git
	r := g.repo
	if r == nil {
		return
	}
	if busy != "" {
		if g.busy != "" {
			return
		}
		g.busy = busy
	}
	g.pending++
	go func() {
		err := fn(r)
		a.post(func() {
			g.pending--
			if busy != "" {
				g.busy = ""
			}
			a.gitChanged()
			if err != nil {
				a.gitFailed(err)
				return
			}
			if then != nil {
				then()
			}
		})
	}()
}

// gitFailed says why a git command failed.
func (a *app) gitFailed(err error) {
	var occupied *git.WorktreeInUse
	if errors.As(err, &occupied) {
		a.askOpenWorktree(occupied.Branch, occupied.Path)
		return
	}
	msg := err.Error()
	if len(msg) > 400 {
		msg = msg[:400] + "…"
	}
	if git.NeedsAuth(err) {
		msg += "\nGit needs to sign in: run the command in the terminal once."
	}
	a.fail("%s", msg)
}

// fetch fetches from the remotes, which tells how far behind the branch
// is.
func (a *app) fetch() {
	a.gitDo("Fetching…", func(r *git.Repo) error { return r.Fetch() }, nil)
}

// pull brings in the upstream's commits, when the branch has none of its
// own that it lacks. When the two have diverged, it asks to rebase or
// merge instead.
func (a *app) pull() { a.pullThen(nil) }

// pullThen pulls as pull does, then calls then, unless the pull failed
// or stopped: after a rebase or a merge that the dialog of a divergence
// starts too.
func (a *app) pullThen(then func()) {
	pulled, diverged := 0, false
	a.gitDo("Pulling…", func(r *git.Repo) error {
		before := r.Head()
		if err := r.Pull(); err != nil {
			if git.Diverged(err) {
				diverged = true
				return nil
			}
			return err
		}
		if before != "" {
			pulled = r.Count(before, "HEAD")
		}
		return nil
	}, func() {
		switch {
		case diverged:
			a.askDiverged(then)
			return
		case pulled > 0:
			a.tell(note{message: "Pulled " + plural(pulled, "commit")})
		case then == nil:
			a.tell(note{message: "Already up to date"})
		}
		if then != nil {
			then()
		}
	})
}

// askDiverged asks how to bring in the upstream's commits when the branch
// has commits of its own that the upstream lacks: by a rebase, or a merge.
func (a *app) askDiverged(then func()) {
	st := a.git.status
	branch, upstream := a.branch(), "its upstream"
	if st != nil && st.Upstream != "" {
		upstream = st.Upstream
	}
	a.confirm = &confirm{title: branch + " and " + upstream + " have diverged",
		message: "Each has commits the other lacks. Rebase makes the commits of " + branch +
			" again on top of " + upstream + "'s; Merge joins them in a merge commit.",
		ok: "Pull (Rebase)", okShort: "Rebase", alternate: "Pull (Merge)", alternateShort: "Merge",
		run:          func() { a.pullWith(git.PullRebase, then) },
		runAlternate: func() { a.pullWith(git.PullMerge, then) }}
}

// pullWith pulls by a rebase or a merge, then calls then unless it
// failed or stopped for conflicts, which it says how to go on from.
func (a *app) pullWith(mode git.PullMode, then func()) {
	op, busy, done := git.OpRebase, "Pulling (rebase)…", "Pulled and rebased "+a.branch()
	if mode == git.PullMerge {
		op, busy, done = git.OpMerge, "Pulling (merge)…", "Pulled and merged into "+a.branch()
	}
	a.runOpThen(op, busy, done, func(r *git.Repo) error { return r.PullWith(mode) }, then)
}

// push pushes the branch to its upstream, or to a remote, which becomes
// its upstream. When the remote has commits the branch lacks, as after an
// amend or a rebase, it offers to force the push.
func (a *app) push() {
	st := a.git.status
	if st == nil || st.Branch == "" {
		a.fail("Check out a branch to push.")
		return
	}
	branch, upstream := st.Branch, st.Upstream != ""
	rejected := false
	a.gitDo("Pushing…", func(r *git.Repo) error {
		err := r.Push(branch, upstream)
		if err != nil && git.Rejected(err) {
			rejected = true
			return nil
		}
		return err
	}, func() {
		switch {
		case rejected:
			a.askForcePush(true)
		case upstream:
			a.tell(note{message: "Pushed " + branch + " to " + st.Upstream})
		default:
			a.tell(note{message: "Published " + branch})
		}
	})
}

// askForcePush asks before forcing the push of the branch, saying why the
// push was rejected when it was.
func (a *app) askForcePush(rejected bool) {
	st := a.git.status
	if st == nil || st.Branch == "" {
		a.fail("Check out a branch to push.")
		return
	}
	branch := st.Branch
	remote := cmp.Or(st.Upstream, "the remote")
	title := "Force push " + branch + "?"
	msg := "The commits of " + remote + " that " + branch + " lacks are replaced by its own. " +
		"It stops if " + remote + " has changed since the last fetch (--force-with-lease)."
	if rejected {
		title = "The push of " + branch + " was rejected"
		msg = remote + " has commits that " + branch + " lacks, as after an amend or a rebase. Pull to bring " +
			"them in, or force the push to replace them; it stops if " + remote +
			" has changed since the last fetch (--force-with-lease)."
	}
	cf := &confirm{title: title, message: msg, ok: "Force Push", danger: true, run: a.forcePush}
	if rejected {
		cf.alternate, cf.runAlternate = "Pull", a.pull
	}
	a.confirm = cf
}

// forcePush pushes the branch over the remote's, with a lease: only while
// the remote's is the one last fetched.
func (a *app) forcePush() {
	st := a.git.status
	if st == nil || st.Branch == "" {
		a.fail("Check out a branch to push.")
		return
	}
	branch, upstream := st.Branch, st.Upstream != ""
	a.gitDo("Force pushing…", func(r *git.Repo) error { return r.ForcePush(branch, upstream) }, func() {
		a.tell(note{message: "Force pushed " + branch})
	})
}

// sync pulls the upstream's commits, then pushes the branch's own, as VS
// Code's Sync Changes does; a branch without an upstream is published.
func (a *app) sync() {
	st := a.git.status
	if st == nil || st.Branch == "" {
		a.fail("Check out a branch to sync.")
		return
	}
	if st.Upstream == "" {
		a.push()
		return
	}
	a.pullThen(a.push)
}

// switchBranch checks out a branch, or makes it first when create is set,
// once the documents are saved: Git keeps the changes of the work tree
// when they do not clash with the branch's.
func (a *app) switchBranch(branch string, create bool) {
	if !a.docsSaved("switching branches") {
		return
	}
	a.gitDo("Switching to "+branch+"…", func(r *git.Repo) error { return r.Switch(branch, create) }, nil)
}

// docsSaved reports whether the documents of the work tree are saved,
// saying which is not when one is not, before what doing names.
func (a *app) docsSaved(doing string) bool {
	for _, d := range a.docs {
		if d.dirty() && d.path != "" && a.git.repo != nil && a.git.repo.Contains(d.path) {
			a.fail("Save the changes of %s before %s.", d.name(), doing)
			return false
		}
	}
	return true
}

// checkOutCommit checks out a commit of the history: its branch when it
// has one local branch, or else the commit itself, once asked, as that
// detaches HEAD.
func (a *app) checkOutCommit(cm git.Commit) {
	if b := localBranch(cm); b != "" {
		a.switchBranch(b, false)
		return
	}
	a.confirm = &confirm{title: "Check out " + cm.Short() + "?", ok: "Check Out",
		message: "HEAD will be detached at the commit: commits made there belong to no branch until you create one.",
		run: func() {
			if !a.docsSaved("checking out a commit") {
				return
			}
			hash := cm.Hash
			a.gitDo("Checking out "+cm.Short()+"…", func(r *git.Repo) error { return r.Checkout(hash) }, nil)
		}}
}

// localBranch is the one local branch at a commit, "" when it has none
// or more.
func localBranch(cm git.Commit) string {
	name := ""
	for _, r := range cm.Refs {
		if r.Kind == git.RefBranch {
			if name != "" {
				return ""
			}
			name = r.Name
		}
	}
	return name
}

// revOf names a commit for a command: by its one local branch, so that
// a merge's message names the branch, or else by its hash.
func revOf(cm git.Commit) string { return cmp.Or(localBranch(cm), cm.Hash) }

// inHead reports whether HEAD has commit hash, by the commits of the
// history read: one read before them counts as not.
func (a *app) inHead(hash string) bool {
	g := &a.git
	if g.status == nil || g.status.Head == "" {
		return false
	}
	key := fmt.Sprintf("%s|%d", g.status.Head, g.historyGen)
	if g.reachOf != key {
		parents := make(map[string][]string, len(g.history))
		for _, c := range g.history {
			parents[c.Hash] = c.Parents
		}
		g.reach, g.reachOf = map[string]bool{}, key
		todo := []string{g.status.Head}
		for len(todo) > 0 {
			h := todo[len(todo)-1]
			todo = todo[:len(todo)-1]
			if g.reach[h] {
				continue
			}
			g.reach[h] = true
			todo = append(todo, parents[h]...)
		}
	}
	return g.reach[hash]
}

// runOp runs a command that moves HEAD by commits, once the documents
// are saved, then says done. When it stops for conflicts it says how to
// go on, and the message it proposes goes in the box.
func (a *app) runOp(op git.Op, busy, done string, fn func(r *git.Repo) error) {
	a.runOpThen(op, busy, done, fn, nil)
}

// runOpThen runs a command as runOp does, then calls then unless it
// failed or stopped for conflicts.
func (a *app) runOpThen(op git.Op, busy, done string, fn func(r *git.Repo) error, then func()) {
	if !a.docsSaved("a " + strings.ToLower(op.Title())) {
		return
	}
	stopped, msg := false, ""
	a.gitDo(busy, func(r *git.Repo) error {
		err := fn(r)
		if err != nil && r.InProgress() == op {
			stopped, msg = true, r.MergeMessage()
			return nil
		}
		return err
	}, func() {
		g := &a.git
		g.refsGen++
		if !stopped {
			a.tell(note{message: done})
			if then != nil {
				then()
			}
			return
		}
		if op != git.OpRebase && strings.TrimSpace(g.message) == "" {
			g.message, g.amend = msg, false
		}
		a.showSourceControl()
		a.tell(note{message: op.Title() + " stopped for conflicts: resolve and stage them, then continue",
			label: "Abort", action: func() { a.abortOpOf(op) }})
	})
}

// mergeCommit merges a commit of the history into the branch checked
// out, once asked.
func (a *app) mergeCommit(cm git.Commit) {
	rev, into := revOf(cm), a.branch()
	a.confirm = &confirm{title: fmt.Sprintf("Merge %s into %s?", cmp.Or(localBranch(cm), cm.Short()), into), ok: "Merge",
		message: ellipsize(cm.Subject, 80),
		run: func() {
			a.runOp(git.OpMerge, "Merging…", "Merged "+cmp.Or(localBranch(cm), cm.Short())+" into "+into,
				func(r *git.Repo) error { return r.Merge(rev) })
		}}
}

// rebaseOnto moves the commits of the branch checked out that a commit
// of the history lacks on top of it, once asked.
func (a *app) rebaseOnto(cm git.Commit) {
	rev, branch, onto := revOf(cm), a.branch(), cmp.Or(localBranch(cm), cm.Short())
	a.confirm = &confirm{title: fmt.Sprintf("Rebase %s onto %s?", branch, onto), ok: "Rebase",
		message: "The commits of " + branch + " that " + onto + " lacks are made again on top of it. " +
			"Rebasing commits already pushed rewrites history others may have.",
		run: func() {
			a.runOp(git.OpRebase, "Rebasing…", "Rebased "+branch+" onto "+onto,
				func(r *git.Repo) error { return r.Rebase(rev) })
		}}
}

// cherryPick makes a commit of a commit's changes on the branch checked
// out.
func (a *app) cherryPick(cm git.Commit) {
	hash, merge := cm.Hash, len(cm.Parents) > 1
	a.runOp(git.OpCherryPick, "Cherry-picking…", "Cherry-picked “"+ellipsize(cm.Subject, 48)+"”",
		func(r *git.Repo) error { return r.CherryPick(hash, merge) })
}

// revertCommit makes a commit that takes back a commit's changes, once
// asked.
func (a *app) revertCommit(cm git.Commit) {
	hash, merge := cm.Hash, len(cm.Parents) > 1
	msg := "A new commit takes back the changes of “" + ellipsize(cm.Subject, 60) + "”."
	if merge {
		msg += " Those of a merge are taken back against its first parent."
	}
	a.confirm = &confirm{title: "Revert " + cm.Short() + "?", ok: "Revert", message: msg, run: func() {
		a.runOp(git.OpRevert, "Reverting…", "Reverted “"+ellipsize(cm.Subject, 48)+"”",
			func(r *git.Repo) error { return r.Revert(hash, merge) })
	}}
}

// resetModes are the ways a reset may go, as the dialog offers them.
var resetModes = []confirmChoice{
	{label: "Soft", message: "Keep the changes of the commits after it staged, and the work tree as it is."},
	{label: "Mixed", message: "Keep the changes of the commits after it, and the work tree's, unstaged."},
	{label: "Hard", message: "Discard the commits after it and every change of the work tree.", danger: true},
}

// resetTo moves the branch checked out to a commit of the history, in
// the mode chosen in the dialog.
func (a *app) resetTo(cm git.Commit) {
	branch, hash := a.branch(), cm.Hash
	cf := &confirm{title: fmt.Sprintf("Reset %s to %s?", branch, cm.Short()), ok: "Reset",
		choices: resetModes, choice: 1}
	cf.run = func() {
		mode := git.ResetMode(strings.ToLower(resetModes[cf.choice].label))
		if mode == git.ResetHard && !a.docsSaved("a hard reset") {
			return
		}
		a.gitDo("Resetting…", func(r *git.Repo) error { return r.Reset(hash, mode) }, func() {
			a.git.refsGen++
			a.tell(note{message: fmt.Sprintf("Reset %s to %s (%s)", branch, git.ShortHash(hash), mode)})
		})
	}
	a.confirm = cf
}

// continueOp goes on with the command stopped for conflicts, once they
// are resolved and staged: a merge, cherry-pick or revert with the
// message written, when one is.
func (a *app) continueOp() {
	g := &a.git
	if g.status == nil || g.status.Op == "" || g.busy != "" {
		return
	}
	op := g.status.Op
	if len(a.groupEntries()[groupMerge]) > 0 {
		a.fail("Resolve the conflicts and stage the files first.")
		return
	}
	if op != git.OpRebase && strings.TrimSpace(g.message) != "" {
		a.commit(false)
		return
	}
	if !a.docsSaved("continuing") {
		return
	}
	stopped := false
	a.gitDo("Continuing the "+strings.ToLower(op.Title())+"…", func(r *git.Repo) error {
		err := r.Continue(op)
		if err != nil && r.InProgress() == op {
			// A rebase stops again at the next commit that conflicts.
			if st, serr := r.Status(); serr == nil && slices.ContainsFunc(st.Entries, git.Entry.Conflicted) {
				stopped = true
				return nil
			}
		}
		return err
	}, func() {
		g.refsGen++
		if stopped {
			a.tell(note{message: op.Title() + " stopped again for conflicts: resolve and stage them, then continue",
				label: "Abort", action: func() { a.abortOpOf(op) }})
			return
		}
		a.tell(note{message: op.Title() + " done"})
	})
}

// abortOp undoes the command stopped for conflicts, once asked.
func (a *app) abortOp() {
	if st := a.git.status; st != nil && st.Op != "" {
		a.abortOpOf(st.Op)
	}
}

// abortOpOf undoes op, stopped for conflicts, once asked.
func (a *app) abortOpOf(op git.Op) {
	g := &a.git
	a.confirm = &confirm{title: "Abort the " + strings.ToLower(op.Title()) + "?", ok: "Abort", danger: true,
		message: "HEAD, the staged changes and the files go back to how they were before it.",
		run: func() {
			a.gitDo("Aborting…", func(r *git.Repo) error { return r.Abort(op) }, func() {
				g.refsGen++
				if op != git.OpRebase {
					g.message = ""
				}
			})
		}}
}

// askRefAt asks for the name of a branch, or a tag, to make at a commit
// of the history, without checking it out.
func (a *app) askRefAt(cm git.Commit, tag bool) {
	g := &a.git
	if g.repo == nil {
		return
	}
	what, title, names := "branch", "Create Branch…", g.branches
	if tag {
		what, title, names = "tag", "Create Tag…", g.tags
	}
	hash := cm.Hash
	a.prompt = &prompt{title: title, hint: "at " + cm.Short() + " " + ellipsize(cm.Subject, 32), done: func(name string) string {
		name = strings.TrimSpace(name)
		if name == "" || strings.ContainsAny(name, " ~^:?*[\\") {
			return "Enter a " + what + " name without spaces."
		}
		if slices.Contains(names, name) {
			return "A " + what + " with that name exists."
		}
		a.gitDo("Creating "+what+" "+name+"…", func(r *git.Repo) error {
			if tag {
				return r.CreateTag(name, hash, "")
			}
			return r.CreateBranch(name, hash)
		}, func() {
			g.refsGen++
			a.tell(note{message: fmt.Sprintf("Created %s %s at %s", what, name, git.ShortHash(hash))})
		})
		return ""
	}}
}

// askNewBranch asks for the name of a branch to make and check out.
func (a *app) askNewBranch() {
	if a.git.repo == nil {
		return
	}
	a.prompt = &prompt{title: "Create Branch…", hint: "from " + a.branch(), done: func(name string) string {
		name = strings.TrimSpace(name)
		if name == "" || strings.ContainsAny(name, " ~^:?*[\\") {
			return "Enter a branch name without spaces."
		}
		if slices.Contains(a.git.branches, name) {
			return "A branch with that name exists."
		}
		a.switchBranch(name, true)
		return ""
	}}
}

// branchMenu is the menu of the branch in the status bar: the branches to
// switch to, and the commands of the remotes.
func (a *app) branchMenu(m *ui.Menu) {
	g := &a.git
	cur := a.branch()
	if m.Item("Switch Branch…").Disabled(g.busy != "").Chosen() {
		a.post(a.openBranchPicker)
	}
	m.Separator()
	for _, b := range g.branches {
		if m.Item(b).Checked(b == cur).Disabled(g.busy != "").Chosen() && b != cur {
			a.post(func() { a.switchBranch(b, false) })
		}
	}
	if len(g.branches) > 0 {
		m.Separator()
	}
	if m.Item("Create Branch…").Disabled(g.busy != "").Chosen() {
		a.post(a.askNewBranch)
	}
	if m.Item("Rename Branch…").Disabled(g.busy != "" || g.status == nil || g.status.Branch == "").Chosen() {
		a.post(func() { a.askRenameBranch("") })
	}
	if m.Item("Delete Branch…").Disabled(g.busy != "").Chosen() {
		a.post(a.openDeleteBranchPicker)
	}
	m.Separator()
	if m.Item("Fetch").Disabled(g.busy != "").Chosen() {
		a.post(a.fetch)
	}
	if m.Item("Pull").Disabled(g.busy != "").Chosen() {
		a.post(a.pull)
	}
	if m.Item("Push").Disabled(g.busy != "").Chosen() {
		a.post(a.push)
	}
	a.remoteMoreMenu(m)
}

// remoteMoreMenu has the menus' less common ways to pull and push: by a
// rebase or a merge, forced, and both at once.
func (a *app) remoteMoreMenu(m *ui.Menu) {
	busy := a.git.busy != ""
	if m.Item("Pull (Rebase)").Disabled(busy).Chosen() {
		a.post(func() { a.pullWith(git.PullRebase, nil) })
	}
	if m.Item("Pull (Merge)").Disabled(busy).Chosen() {
		a.post(func() { a.pullWith(git.PullMerge, nil) })
	}
	if m.Item("Force Push…").Disabled(busy).Chosen() {
		a.post(func() { a.askForcePush(false) })
	}
	if m.Item("Sync").Disabled(busy).Chosen() {
		a.post(a.sync)
	}
}

// branchLabel is what the status bar says of the branch: its name, and
// how far it is ahead of its upstream and behind it.
func (a *app) branchLabel() string {
	label := a.branch()
	if st := a.git.status; st != nil && st.Upstream != "" {
		if st.Behind > 0 {
			label += fmt.Sprintf(" ↓%d", st.Behind)
		}
		if st.Ahead > 0 {
			label += fmt.Sprintf(" ↑%d", st.Ahead)
		}
	}
	return label
}
