//! A project's Git: the commands of the Git menu, source control's events,
//! the Changes tab and commits' tabs, hunks staged and reverted, conflicts
//! resolved, branches and the stash, and how each command went.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const fs = @import("fs.zig");
const git = @import("git.zig");
const Cmd = @import("commands.zig").Cmd;
const wbmod = @import("workbench.zig");
const Workbench = wbmod.Workbench;
const scm_mod = @import("scm.zig");
const gitops = @import("gitops.zig");
const hunks = @import("hunks.zig");
const conflicts = @import("conflicts.zig");
const difflist = @import("difflist.zig");
const Changes = @import("changes.zig").Changes;
const CommitView = @import("commitview.zig").CommitView;
const joinNative = @import("explorer.zig").joinNative;
const Doc = @import("doc.zig").Doc;
const worktree = @import("worktree.zig");

/// Checks out a local branch (the worktree's question's answer).
pub fn switchTo(wb: *Workbench, branch: []const u8) void {
    slow(wb, .checkout, &.{ "checkout", branch }, branch);
}

fn top(wb: *Workbench) ?[]const u8 {
    return wb.scm.top;
}

/// Runs git now (quick commands), keeping its error for source control.
pub fn quick(wb: *Workbench, args: []const []const u8) bool {
    const t = top(wb) orelse return false;
    const r = git.run(wb.gpa, wb.io, t, args) catch return false;
    defer r.deinit(wb.gpa);
    if (!r.ok) {
        const msg = std.mem.trim(u8, if (r.stderr.len > 0) r.stderr else r.stdout, " \r\n");
        wb.scm.setError(msg);
        wb.toastError("Git", msg);
    } else wb.scm.setError("");
    wb.refreshGit();
    return r.ok;
}

fn slow(wb: *Workbench, kind: gitops.Kind, args: []const []const u8, subject: []const u8) void {
    const t = top(wb) orelse return;
    // Git reads the files from the disk: auto save saves them first, and
    // what rewrites the work tree waits for the rest to be saved.
    if (wb.editors.auto_save) wb.editors.saveAll();
    const hard = for (args) |a| {
        if (std.mem.eql(u8, a, "--hard")) break true;
    } else false;
    const detach = for (args) |a| {
        if (std.mem.eql(u8, a, "--detach")) break true;
    } else false;
    const doing: ?[]const u8 = switch (kind) {
        .checkout => if (detach) "checking out a commit" else "switching branches",
        .create_branch => "switching branches",
        .merge => "a merge",
        .rebase => "a rebase",
        .revert => "a revert",
        .cherry_pick => "a cherry-pick",
        .continue_op => "continuing",
        .stash => "stashing",
        .stash_apply, .stash_pop => "applying a stash",
        .reset => if (hard) "a hard reset" else null,
        else => null,
    };
    if (doing) |d| if (!worktree.docsSaved(wb, d)) return;
    if (kind == .pull or kind == .pull_rebase or kind == .pull_merge or kind == .sync) {
        if (wb.head_before) |h| wb.gpa.free(h);
        wb.head_before = git.line(wb.gpa, wb.io, t, &.{ "rev-parse", "HEAD" });
    }
    if (!wb.runner.run(kind, t, args, subject)) _ = wb.toasts.show("A Git command is running");
}

/// What a commit's menu asks for: merging it, rebasing onto it, resetting
/// to it (asked first), reverting it, cherry-picking it, and its branches.
fn graphEvent(wb: *Workbench, c: *ui.Context, ge: @import("graph.zig").Graph.Event) void {
    const br = wb.scm.branch orelse "HEAD";
    switch (ge) {
        .merge => |h| wb.ask(.merge, h, c.print("Merge {s} into {s}?", .{ h[0..@min(h.len, 7)], br }), "Its commits come into the branch checked out.", &.{ "Cancel", "Merge" }),
        .rebase => |h| wb.ask(.rebase, h, c.print("Rebase {s} onto {s}?", .{ br, h[0..@min(h.len, 7)] }), c.print("The commits of {s} that it lacks are made again on top of it. Rebasing commits already pushed rewrites history others may have.", .{br}), &.{ "Cancel", "Rebase" }),
        .reset => |h| wb.ask(.reset, h, c.print("Reset {s} to {s}?", .{ br, h[0..@min(h.len, 7)] }), "Soft keeps the changes of the commits after it staged; Mixed keeps them unstaged; Hard discards them and every change of the work tree.", &.{ "Cancel", "Soft", "Mixed", "Hard" }),
        .revert => |r| wb.ask(.revert, if (r.merge) c.print("m:{s}", .{r.hash}) else r.hash, c.print("Revert {s}?", .{r.hash[0..@min(r.hash.len, 7)]}), if (r.merge) "A new commit takes back its changes, against its first parent." else "A new commit takes back its changes.", &.{ "Cancel", "Revert" }),
        .cherry_pick => |r| slow(wb, .cherry_pick, if (r.merge) &.{ "cherry-pick", "-m", "1", r.hash } else &.{ "cherry-pick", r.hash }, r.hash),
        .rename_branch => |n| renameBranchPrompt(wb, n),
        .delete_branch, .delete_remote => |n| wb.ask(.delete_branch, n, c.print("Delete the branch “{s}”?", .{n}), if (ge == .delete_remote) "It is deleted on its remote." else "The toast's Undo brings it back.", &.{ "Cancel", "Delete" }),
        else => {},
    }
}

/// Goes on with the command stopped for conflicts, once they are resolved
/// and staged: a merge with a message commits it.
fn continueOp(wb: *Workbench) void {
    const op = wb.scm.op;
    if (op == .none) return;
    if (wb.scm.count(.merge) > 0) {
        wb.scm.setError("Resolve the conflicts and stage the files first.");
        return;
    }
    if (op != .rebase and std.mem.trim(u8, wb.scm.message.text(), " \r\n\t").len > 0) return commit(wb, false, false, false);
    slow(wb, .continue_op, &.{ op.name(), "--continue" }, op.title());
}

pub fn run(wb: *Workbench, c: *ui.Context, cmd: Cmd) void {
    const t = top(wb);
    if (t == null and cmd != .git_init and cmd != .git_refresh) {
        _ = wb.toasts.show("The folder isn't in a Git repository");
        return;
    }
    switch (cmd) {
        .git_init => {
            const r = git.run(wb.gpa, wb.io, wb.root, &.{"init"}) catch return;
            r.deinit(wb.gpa);
            wb.scm.top = null;
            wb.refreshGit();
        },
        .git_refresh => wb.refreshGitSoon(),
        .git_commit => commit(wb, wb.scm.count(.staged) == 0, false, false),
        .git_commit_amend => amendFill(wb),
        .git_undo_commit => undoCommit(wb),
        .git_fetch => slow(wb, .fetch, &.{ "fetch", "--prune" }, ""),
        .git_pull => slow(wb, .pull, &.{ "pull", "--ff-only" }, ""),
        .git_pull_rebase => slow(wb, .pull_rebase, &.{ "pull", "--rebase", "--autostash" }, ""),
        .git_pull_merge => slow(wb, .pull_merge, &.{ "pull", "--no-rebase", "--autostash" }, ""),
        .git_push => push(wb, false),
        .git_force_push => wb.ask(.force_push, "", "Force push?", "Force Push uses --force-with-lease: commits pushed there since the last fetch are not lost.", &.{ "Cancel", "Force Push" }),
        .git_sync => slow(wb, .sync, &.{}, ""),
        .git_switch_branch => wb.picker.show(t.?, .switch_branch),
        .git_delete_branch => wb.picker.show(t.?, .delete_branch),
        .git_create_branch => {
            wb.prompt.ask(.new_branch, "Create Branch…", "", "");
            if (wb.scm.branch) |b| wb.prompt.hint(c.print("from {s}", .{b}));
        },
        .git_rename_branch => renameBranchPrompt(wb, wb.scm.branch orelse ""),
        .git_stash => {
            wb.prompt.ask(.stash, "Stash…", "", "");
            wb.prompt.hint("a message, or none");
        },
        .git_stash_untracked => {
            wb.prompt.ask(.stash_untracked, "Stash (Include Untracked)…", "", "");
            wb.prompt.hint("a message, or none");
        },
        .git_stash_apply_latest => slow(wb, .stash_apply, &.{ "stash", "apply", "--index" }, "stash@{0}"),
        .git_stash_pop => slow(wb, .stash_pop, &.{ "stash", "pop", "--index" }, "stash@{0}"),
        .git_stash_apply => wb.picker.show(t.?, .stash_apply),
        .git_stash_pop_pick => wb.picker.show(t.?, .stash_pop),
        .git_stash_view => wb.picker.show(t.?, .stash_view),
        .git_stash_drop => wb.picker.show(t.?, .stash_drop),
        .show_all_branches => {
            wb.shell.store.setBool("scmAllBranches", !wb.shell.store.s.scmAllBranches);
            wb.scm.graph.all = wb.shell.store.s.scmAllBranches;
            wb.scm.graph.load(wb.io, t.?);
        },
        .scm_tree => wb.shell.store.setBool("scmTree", !wb.shell.store.s.scmTree),
        .git_commit_push => commit(wb, wb.scm.count(.staged) == 0, false, true),
        .stage_file, .unstage_file => if (wb.editors.current()) |it| if (it.path()) |p| {
            const rel = fs.relative(t.?, p);
            _ = quick(wb, if (cmd == .stage_file) &.{ "add", "--", rel } else &.{ "reset", "-q", "HEAD", "--", rel });
        },
        .stage_all => _ = quick(wb, &.{ "add", "-A", "--", "." }),
        .git_continue => continueOp(wb),
        .git_abort => if (wb.scm.op != .none) {
            const op = wb.scm.op.title();
            wb.ask(.abort_op, "", c.print("Abort the {s}?", .{op}), "HEAD, the staged changes and the files go back to how they were before it.", &.{ "Cancel", "Abort" });
        },
        .toggle_blame => wb.shell.store.setBool("blame", !wb.shell.store.s.blame),
        else => {},
    }
}

fn push(wb: *Workbench, force: bool) void {
    if (!wb.scm.ab.upstream) {
        const b = wb.scm.branch orelse return;
        slow(wb, .publish, &.{ "push", "-u", "origin", b }, b);
    } else if (force) {
        slow(wb, .force_push, &.{ "push", "--force-with-lease" }, "");
    } else slow(wb, .push, &.{"push"}, "");
}

pub fn commit(wb: *Workbench, all: bool, amend: bool, then_push: bool) void {
    const msg = std.mem.trim(u8, wb.scm.message.text(), " \r\n\t");
    if (msg.len == 0 and !amend) {
        wb.scm.setError("Write a commit message first.");
        return;
    }
    if (all and wb.scm.changes.len > 0 and !amend and wb.confirm_kind != .commit_all) {
        wb.ask(.commit_all, if (then_push) "push" else "", "Commit all changes?", "Nothing is staged. Stage every change and commit it?", &.{ "Cancel", "Commit All" });
        return;
    }
    wb.editors.saveAll();
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(wb.gpa);
    // Every change staged first, untracked files too: `commit -a` leaves them.
    if (all and !quick(wb, &.{ "add", "-A" })) return;
    args.appendSlice(wb.gpa, &.{"commit"}) catch return;
    if (amend) args.append(wb.gpa, "--amend") catch return;
    if (msg.len > 0) args.appendSlice(wb.gpa, &.{ "-m", msg }) catch return else args.append(wb.gpa, "--no-edit") catch return;
    if (quick(wb, args.items)) {
        // The message is cleared once the toast has its subject.
        defer wb.scm.message.clear();
        wb.scm.amending = false;
        if (then_push) {
            push(wb, false);
        } else if (amend) {
            _ = wb.toasts.show("Amended the last commit");
        } else {
            // As the Go app's: its subject, cut short, and the branch.
            const subject = std.mem.sliceTo(msg, '\n');
            var buf: [160]u8 = undefined;
            const cut = if (subject.len > 48) subject[0..47] else subject;
            const text = if (wb.scm.branch) |b|
                std.fmt.bufPrint(&buf, "Committed “{s}{s}” to {s}", .{ cut, if (subject.len > 48) "…" else "", b }) catch "Committed"
            else
                std.fmt.bufPrint(&buf, "Committed “{s}{s}”", .{ cut, if (subject.len > 48) "…" else "" }) catch "Committed";
            wb.toast_undo_commit = wb.toasts.showAction(text, "Undo");
        }
    }
}

fn amendFill(wb: *Workbench) void {
    const t = top(wb) orelse return;
    // The next commit amends the last, its message the last's unless one is written.
    wb.scm.amending = true;
    wb.sidebar_open = true;
    wb.side = .scm;
    if (std.mem.trim(u8, wb.scm.message.text(), " \r\n\t").len > 0) return;
    const m = git.line(wb.gpa, wb.io, t, &.{ "log", "-1", "--format=%B" }) orelse return;
    defer wb.gpa.free(m);
    wb.scm.message.set(m);
}

/// Takes the last commit back, keeping its changes staged and its message.
pub fn undoCommit(wb: *Workbench) void {
    const t = top(wb) orelse return;
    const m = git.line(wb.gpa, wb.io, t, &.{ "log", "-1", "--format=%B" });
    defer if (m) |x| wb.gpa.free(x);
    if (quick(wb, &.{ "reset", "--soft", "HEAD~1" })) {
        if (m) |x| wb.scm.message.set(x);
        _ = wb.toasts.show("Commit undone: its changes are staged");
    }
}

/// How a slow command went: toasts, and questions to ask next.
pub fn onGitDone(ctx: *anyopaque, d: gitops.Done) void {
    const wb: *Workbench = @ptrCast(@alignCast(ctx));
    wb.refreshGit();
    wb.editors.reloadChanged();
    if (!d.ok) {
        const m = d.message;
        if ((d.kind == .push) and (std.mem.indexOf(u8, m, "rejected") != null or std.mem.indexOf(u8, m, "non-fast-forward") != null)) {
            wb.ask(.force_push, "", "The remote rejected the push", "It has commits this branch doesn't. Pull them first, or force push (with --force-with-lease)?", &.{ "Cancel", "Force Push", "Pull" });
            return;
        }
        if ((d.kind == .pull or d.kind == .sync) and (std.mem.indexOf(u8, m, "Not possible to fast-forward") != null or std.mem.indexOf(u8, m, "diverg") != null)) {
            wb.ask(.pull_diverged, "", "The branch and its upstream have diverged", "Pull by rebasing this branch's commits on top, or by merging?", &.{ "Cancel", "Pull (Merge)", "Pull (Rebase)" });
            return;
        }
        if (std.mem.indexOf(u8, m, "terminal prompts disabled") != null or std.mem.indexOf(u8, m, "could not read Username") != null or std.mem.indexOf(u8, m, "Permission denied") != null) {
            wb.toastError("Git couldn't sign in", "Run the command once in the terminal so your SSH agent or credential helper remembers you.");
            return;
        }
        // A rebase stops again at the next commit that conflicts; a pull
        // or a merge may stop for conflicts too.
        if (wb.scm.op != .none and wb.scm.count(.merge) > 0) {
            // The message git proposes waits in the box, but a rebase's.
            if (wb.scm.op != .rebase and std.mem.trim(u8, wb.scm.message.text(), " \r\n\t").len == 0) if (wb.scm.git_dir) |gd| {
                const p = std.fs.path.join(wb.gpa, &.{ gd, "MERGE_MSG" }) catch "";
                defer wb.gpa.free(p);
                if (fs.read(wb.gpa, wb.io, p)) |msg| {
                    defer wb.gpa.free(msg);
                    var out: std.ArrayList(u8) = .empty;
                    defer out.deinit(wb.gpa);
                    var it = std.mem.splitScalar(u8, msg, '\n');
                    while (it.next()) |l| if (!std.mem.startsWith(u8, l, "#")) {
                        out.appendSlice(wb.gpa, l) catch {};
                        out.append(wb.gpa, '\n') catch {};
                    };
                    wb.scm.message.set(std.mem.trim(u8, out.items, " \r\n\t"));
                } else |_| {}
            };
            _ = wb.toasts.add(.{ .title = "Stopped for conflicts", .description = "Resolve them, stage the files, then Continue.", .kind = .@"error" });
            return;
        }
        // A branch checked out in another worktree opens it.
        if (d.kind == .checkout and worktree.askIfHeld(wb, d.subject)) return;
        if (d.kind == .stash_pop or d.kind == .stash_apply) {
            wb.toastError("The stash clashes with your changes", "The files are left in conflict to resolve; the stash entry is kept.");
            return;
        }
        wb.scm.setError(m);
        wb.toastError("Git", m);
        return;
    }
    wb.scm.setError("");
    var buf: [256]u8 = undefined;
    const branch = wb.scm.branch orelse "";
    switch (d.kind) {
        .push => _ = wb.toasts.show(if (wb.scm.upstream) |u| std.fmt.bufPrint(&buf, "Pushed {s} to {s}", .{ branch, u }) catch "Pushed" else std.fmt.bufPrint(&buf, "Published {s}", .{branch}) catch "Published"),
        .publish => _ = wb.toasts.show(std.fmt.bufPrint(&buf, "Published {s}", .{branch}) catch "Published"),
        .force_push => _ = wb.toasts.show(std.fmt.bufPrint(&buf, "Force pushed {s}", .{branch}) catch "Force pushed"),
        .pull, .pull_rebase, .pull_merge, .sync => {
            // How many commits the pull brought, from HEAD before it.
            var n: usize = 0;
            if (wb.head_before) |h| {
                const range = std.fmt.allocPrint(wb.gpa, "{s}..HEAD", .{h}) catch "";
                defer if (range.len > 0) wb.gpa.free(range);
                if (top(wb)) |t| if (git.line(wb.gpa, wb.io, t, &.{ "rev-list", "--count", range })) |l| {
                    n = std.fmt.parseInt(usize, l, 10) catch 0;
                    wb.gpa.free(l);
                };
                wb.gpa.free(h);
                wb.head_before = null;
            }
            if (n > 0) {
                _ = wb.toasts.show(std.fmt.bufPrint(&buf, "Pulled {d} commit{s}", .{ n, if (n == 1) "" else "s" }) catch "Pulled");
            } else if (d.kind != .sync) _ = wb.toasts.show("Already up to date");
            if (d.kind == .sync) _ = wb.toasts.show(if (wb.scm.upstream) |u| std.fmt.bufPrint(&buf, "Synced {s} with {s}", .{ branch, u }) catch "Synced" else "Synced");
        },
        .fetch => {},
        .stash => wb.toast_pop_stash = wb.toasts.showAction("Stashed the changes", "Pop"),
        .stash_pop => _ = wb.toasts.show("Popped the stash"),
        .stash_apply => _ = wb.toasts.show("Applied the stash"),
        .checkout => {},
        .create_branch => if (top(wb)) |t| if (git.line(wb.gpa, wb.io, t, &.{ "rev-parse", "--short", "HEAD" })) |h| {
            defer wb.gpa.free(h);
            _ = wb.toasts.show(std.fmt.bufPrint(&buf, "Created branch {s} at {s}", .{ d.subject, h }) catch "Created the branch");
        },
        .continue_op => _ = wb.toasts.show("Continued"),
        .merge => _ = wb.toasts.add(.{ .title = "Merged", .kind = .success }),
        .rebase => _ = wb.toasts.add(.{ .title = "Rebased", .kind = .success }),
        .reset => _ = wb.toasts.show("Reset"),
        .revert => _ = wb.toasts.show("Reverted"),
        .cherry_pick => _ = wb.toasts.show("Cherry-picked"),
        .abort_op => _ = wb.toasts.show("Aborted"),
        .delete_branch => {
            wb.toast_restore_branch = wb.toasts.showAction("Branch deleted", "Undo");
        },
        else => {},
    }
}

/// Source control's events.
pub fn scmEvent(wb: *Workbench, c: *ui.Context, ev: scm_mod.Event) void {
    if (ev == .none) return;
    c.changed = true;
    const g = wb.gpa;
    switch (ev) {
        .none => {},
        .open => |o| {
            const p = g.dupe(u8, o.path) catch return;
            defer g.free(p);
            openChangesTab(wb, p, false);
        },
        .open_file => |rel| {
            const t = top(wb) orelse return;
            const abs = joinNative(g, t, rel) catch return;
            defer g.free(abs);
            // A submodule opens as a folder.
            if (fs.isDirectory(wb.io, abs)) wb.shell.openFolder(abs, false) else if (fs.exists(wb.io, abs)) _ = wb.editors.openFile(abs, false) catch {};
        },
        .commit => |cm| commit(wb, cm.all, cm.amend, cm.push),
        .undo_commit => undoCommit(wb),
        .amend_fill => amendFill(wb),
        .run => |cmd| @import("wb_run.zig").run(wb, c, cmd),
        .commit_open => |co| {
            const h = g.dupe(u8, co.hash) catch return;
            defer g.free(h);
            openCommit(wb, h, co.keep);
        },
        .commit_checkout => |h| {
            const hh = g.dupe(u8, h) catch return;
            defer g.free(hh);
            checkoutCommit(wb, hh);
        },
        .branch_at => |h| {
            wb.prompt.ask(.new_branch_at, "Create Branch…", "", h);
            wb.prompt.hint(c.print("at {s}", .{h[0..@min(7, h.len)]}));
        },
        .tag_at => |h| {
            wb.prompt.ask(.new_tag, "Create Tag…", "", h);
            wb.prompt.hint(c.print("at {s}", .{h[0..@min(7, h.len)]}));
        },
        .stage => |ps| _ = quick(wb, withPaths(c, &.{ "add", "--" }, ps)),
        .unstage => |ps| _ = quick(wb, withPaths(c, &.{ "reset", "-q", "HEAD", "--" }, ps)),
        .discard => |all| {
            const ps = files(wb, c, all);
            if (ps.len == 0) return;
            const list = std.mem.join(c.alloc(), "\n", ps) catch return;
            const what = if (ps.len == 1) ps[0] else c.print("{d} files", .{ps.len});
            wb.ask(.discard_file, list, "Discard changes?", c.print("{s}\nThis can't be undone; an untracked file goes to the Recycle Bin.", .{what}), &.{ "Cancel", "Discard" });
        },
        .stage_all => |grp| switch (grp) {
            .untracked => _ = quick(wb, &.{ "add", "-A", "--", "." }),
            else => _ = quick(wb, &.{ "add", "-u", "--", "." }),
        },
        .unstage_all => _ = quick(wb, &.{ "reset", "-q", "HEAD", "--", "." }),
        .discard_all => wb.ask(.discard_all, "", "Discard all changes?", "Every change not staged is lost, and untracked files go to the Recycle Bin.", &.{ "Cancel", "Discard All" }),
        .open_all => openChangesTab(wb, null, true),
        .reveal => |rel| if (top(wb)) |t| {
            const abs = joinNative(g, t, rel) catch return;
            defer g.free(abs);
            wb.sidebar_open = true;
            wb.side = .explorer;
            wb.explorer.reveal(abs);
        },
        .copy_path => |rel| if (top(wb)) |t| {
            const abs = joinNative(g, t, rel) catch return;
            defer g.free(abs);
            _ = myzig.clipboard.writeText(abs);
        },
        .press => |rel| {
            const t = top(wb) orelse return;
            const abs = joinNative(g, t, rel) catch return;
            defer g.free(abs);
            @import("wb_files.zig").startFileDrag(wb, c, abs);
        },
        .continue_op => run(wb, c, .git_continue),
        .abort_op => run(wb, c, .git_abort),
        .graph => |ge| graphEvent(wb, c, ge),
        .stash_files => |all| {
            const ps = files(wb, c, all);
            if (ps.len == 0) return;
            const list = std.mem.join(c.alloc(), "\n", ps) catch return;
            wb.prompt.ask(.stash_files, if (ps.len == 1) c.print("Stash {s}…", .{std.fs.path.basename(ps[0])}) else c.print("Stash {d} Files…", .{ps.len}), "", list);
            wb.prompt.hint("a message, or none");
        },
    }
}

/// `git args... paths...`, in the frame's memory.
/// The paths that aren't submodules, which discarding and stashing leave.
fn files(wb: *Workbench, c: *ui.Context, paths: []const []const u8) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (paths) |p| {
        const sub = for (wb.scm.changes) |ch| {
            if (std.mem.eql(u8, ch.path, p)) break ch.sub;
        } else false;
        if (!sub) out.append(c.alloc(), p) catch {};
    }
    return out.items;
}

fn renameBranchPrompt(wb: *Workbench, name: []const u8) void {
    wb.prompt.ask(.rename_branch, "Rename Branch…", name, name);
    var buf: [200]u8 = undefined;
    wb.prompt.hint(std.fmt.bufPrint(&buf, "rename {s}", .{name}) catch "");
}

fn withPaths(c: *ui.Context, args: []const []const u8, paths: []const []const u8) []const []const u8 {
    const out = c.alloc().alloc([]const u8, args.len + paths.len) catch return args;
    @memcpy(out[0..args.len], args);
    @memcpy(out[args.len..], paths);
    return out;
}

fn stageConflictToast(wb: *Workbench) void {
    _ = wb;
}

pub fn checkoutCommit(wb: *Workbench, hash: []const u8) void {
    // A commit with a branch checks out the branch; otherwise ask first.
    const t = top(wb) orelse return;
    const refs = git.line(wb.gpa, wb.io, t, &.{ "branch", "--points-at", hash, "--format=%(refname:short)" });
    defer if (refs) |r| wb.gpa.free(r);
    if (refs) |r| if (r.len > 0) {
        const first = std.mem.sliceTo(r, '\n');
        slow(wb, .checkout, &.{ "checkout", first }, first);
        return;
    };
    wb.ask(.checkout_detached, hash, "Detach HEAD?", "No branch is at this commit: checking it out detaches HEAD.", &.{ "Cancel", "Check Out" });
}

/// The answer to a question asked with `Workbench.ask`.
pub fn confirmed(wb: *Workbench, c: *ui.Context, button: usize) void {
    const arg = wb.gpa.dupe(u8, wb.confirm_arg.items) catch return;
    defer wb.gpa.free(arg);
    const kind = wb.confirm_kind;
    wb.confirm_kind = .close_project; // not .commit_all, which commit reads
    switch (kind) {
        .discard_file => if (button == 1) {
            var it = std.mem.splitScalar(u8, arg, '\n');
            while (it.next()) |p| if (p.len > 0) discardFile(wb, p);
        },
        .discard_all => if (button == 1) {
            _ = quick(wb, &.{ "checkout", "-q", "--", "." });
            for (wb.scm.changes) |ch| if (ch.status() == .untracked) {
                const t = top(wb) orelse break;
                const abs = joinNative(wb.gpa, t, ch.path) catch continue;
                defer wb.gpa.free(abs);
                _ = myzig.shell.trash(abs);
            };
            wb.refreshGit();
            wb.editors.reloadChanged();
        },
        .trash => if (button == 1) {
            if (!myzig.shell.trash(arg)) wb.toastError("Couldn't move it to the Recycle Bin", arg);
            if (wb.editors.findPath(arg)) |l| wb.editors.close(l);
            wb.explorer.refresh();
        },
        .force_push => switch (button) {
            1 => push(wb, true),
            2 => slow(wb, .pull, &.{ "pull", "--ff-only" }, ""),
            else => {},
        },
        .pull_diverged => switch (button) {
            1 => slow(wb, .pull_merge, &.{ "pull", "--no-rebase", "--autostash" }, ""),
            2 => slow(wb, .pull_rebase, &.{ "pull", "--rebase", "--autostash" }, ""),
            else => {},
        },
        .delete_branch => if (button >= 1) deleteBranch(wb, arg, false, button == 2),
        .delete_branch_force => if (button == 1) deleteBranch(wb, arg, true, false),
        .delete_upstream => {},
        .stash_drop => if (button == 1) {
            _ = quick(wb, &.{ "stash", "drop", arg });
        },
        .commit_all => if (button == 1) {
            wb.confirm_kind = .commit_all;
            if (std.mem.eql(u8, arg, "amend")) commit(wb, false, true, false) else commit(wb, true, false, std.mem.eql(u8, arg, "push"));
            wb.confirm_kind = .close_project;
        },
        .checkout_detached => if (button == 1) slow(wb, .checkout, &.{ "checkout", "--detach", arg }, arg),
        .close_project => if (button == 1) wb.shell.closeProjectNow(wb),
        .discard_hunk_closed => {},
        .close_unsaved => @import("wb_files.zig").unsavedAnswer(wb, button),
        .open_worktree, .prune_worktree => worktree.answer(wb, kind == .prune_worktree, arg, button),
        .merge => if (button == 1) slow(wb, .merge, &.{ "merge", "--no-edit", arg }, arg),
        .rebase => if (button == 1) slow(wb, .rebase, &.{ "rebase", arg }, arg),
        .revert => if (button == 1) {
            // "m:<hash>" is a merge, taken back against its first parent.
            if (std.mem.startsWith(u8, arg, "m:")) slow(wb, .revert, &.{ "revert", "--no-edit", "-m", "1", arg[2..] }, arg[2..]) else slow(wb, .revert, &.{ "revert", "--no-edit", arg }, arg);
        },
        .reset => if (button >= 1) {
            const mode: []const u8 = switch (button) {
                1 => "--soft",
                2 => "--mixed",
                else => "--hard",
            };
            slow(wb, .reset, &.{ "reset", mode, arg }, arg);
        },
        .abort_op => if (button == 1 and wb.scm.op != .none) {
            if (wb.scm.op != .rebase) wb.scm.message.clear();
            slow(wb, .abort_op, &.{ wb.scm.op.name(), "--abort" }, wb.scm.op.title());
        },
    }
    c.changed = true;
}

fn discardFile(wb: *Workbench, rel: []const u8) void {
    const t = top(wb) orelse return;
    for (wb.scm.changes) |ch| if (std.mem.eql(u8, ch.path, rel)) {
        if (ch.status() == .untracked) {
            const abs = joinNative(wb.gpa, t, rel) catch return;
            defer wb.gpa.free(abs);
            _ = myzig.shell.trash(abs);
            if (wb.editors.findPath(abs)) |l| wb.editors.close(l);
            wb.refreshGit();
        } else if (ch.status() == .added) {
            _ = quick(wb, &.{ "rm", "-q", "-f", "--", rel });
        } else _ = quick(wb, &.{ "checkout", "-q", "--", rel });
        wb.editors.reloadChanged();
        return;
    };
}

fn deleteBranch(wb: *Workbench, name: []const u8, force: bool, upstream_too: bool) void {
    const t = top(wb) orelse return;
    // Keeps where it was, for the toast's Undo.
    const at = git.line(wb.gpa, wb.io, t, &.{ "rev-parse", name });
    defer if (at) |a| wb.gpa.free(a);
    if (std.mem.startsWith(u8, name, "origin/") or std.mem.indexOfScalar(u8, name, '/') != null and !isLocal(wb, name)) {
        const slash = std.mem.indexOfScalar(u8, name, '/').?;
        slow(wb, .delete_remote_branch, &.{ "push", name[0..slash], "--delete", name[slash + 1 ..] }, name);
        return;
    }
    // Its upstream (origin/name), before the branch and its config go.
    var ref_buf: [512]u8 = undefined;
    const up_ref = std.fmt.bufPrint(&ref_buf, "{s}@{{upstream}}", .{name}) catch "";
    const upstream = if (upstream_too) git.line(wb.gpa, wb.io, t, &.{ "rev-parse", "--abbrev-ref", up_ref }) else null;
    defer if (upstream) |u| wb.gpa.free(u);
    const r = git.run(wb.gpa, wb.io, t, &.{ "branch", if (force) "-D" else "-d", name }) catch return;
    defer r.deinit(wb.gpa);
    if (!r.ok) {
        if (std.mem.indexOf(u8, r.stderr, "not fully merged") != null) {
            wb.ask(.delete_branch_force, name, "The branch isn't merged", "Its commits are merged nowhere: deleting it may lose them. Delete it anyway?", &.{ "Cancel", "Delete" });
        } else wb.toastError("Couldn't delete the branch", std.mem.trim(u8, r.stderr, " \r\n"));
        return;
    }
    if (at) |a| {
        wb.restore_branch.clearRetainingCapacity();
        wb.restore_branch.print(wb.gpa, "{s}\x00{s}", .{ name, a }) catch {};
        wb.toast_restore_branch = wb.toasts.showAction("Branch deleted", "Undo");
    }
    if (upstream) |u| if (std.mem.indexOfScalar(u8, u, '/')) |slash| {
        slow(wb, .delete_remote_branch, &.{ "push", u[0..slash], "--delete", u[slash + 1 ..] }, u);
    };
    wb.refreshGit();
}

fn isLocal(wb: *Workbench, name: []const u8) bool {
    const t = top(wb) orelse return false;
    var buf: [512]u8 = undefined;
    const ref = std.fmt.bufPrint(&buf, "refs/heads/{s}", .{name}) catch return false;
    const r = git.line(wb.gpa, wb.io, t, &.{ "rev-parse", "--verify", "-q", ref }) orelse return false;
    wb.gpa.free(r);
    return true;
}

pub fn restoreDeletedBranch(wb: *Workbench) void {
    var it = std.mem.splitScalar(u8, wb.restore_branch.items, 0);
    const name = it.next() orelse return;
    const at = it.next() orelse return;
    _ = quick(wb, &.{ "branch", name, at });
}

/// The branch picker's and the stash box's choices.
pub fn pickerEvent(wb: *Workbench, c: *ui.Context, pick: @import("branches.zig").Pick) void {
    c.changed = true;
    switch (pick) {
        .checkout => |b| {
            if (b.remote) {
                // A remote's branch: a local branch tracking it.
                const slash = std.mem.indexOfScalar(u8, b.name, '/') orelse return;
                const local = b.name[slash + 1 ..];
                if (isLocal(wb, local)) slow(wb, .checkout, &.{ "checkout", local }, local) else slow(wb, .checkout, &.{ "checkout", "--track", b.name }, local);
            } else slow(wb, .checkout, &.{ "checkout", b.name }, b.name);
        },
        .create => |n| slow(wb, .create_branch, &.{ "checkout", "-b", n }, n),
        .delete => |b| if (!b.remote and b.upstream.len > 0)
            wb.ask(.delete_branch, b.name, c.print("Delete the branch “{s}”?", .{b.name}), c.print("Its upstream, {s}, can go too, on its remote. The toast's Undo brings the local branch back.", .{b.upstream}), &.{ "Cancel", "Delete", "Delete with Upstream" })
        else
            wb.ask(.delete_branch, b.name, c.print("Delete the branch “{s}”?", .{b.name}), if (b.remote) "It is deleted on its remote." else "The toast's Undo brings it back.", &.{ "Cancel", "Delete" }),
        .rename => |b| renameBranchPrompt(wb, b.name),
        .stash => |s| switch (s.mode) {
            .stash_apply => slow(wb, .stash_apply, &.{ "stash", "apply", "--index", s.name }, s.name),
            .stash_pop => slow(wb, .stash_pop, &.{ "stash", "pop", "--index", s.name }, s.name),
            .stash_view => openCommit(wb, s.name, true),
            .stash_drop => wb.ask(.stash_drop, s.name, c.print("Drop {s}?", .{s.name}), "Its changes are lost.", &.{ "Cancel", "Drop" }),
            else => {},
        },
    }
}

/// The prompt's answers that are Git's.
pub fn promptAnswer(wb: *Workbench, purpose: @import("prompt.zig").Purpose, answer: []const u8, target: []const u8) bool {
    switch (purpose) {
        .new_branch => slow(wb, .create_branch, &.{ "checkout", "-b", answer }, answer),
        .new_branch_at => slow(wb, .create_branch, &.{ "checkout", "-b", answer, target }, answer),
        .rename_branch => {
            if (target.len > 0) _ = quick(wb, &.{ "branch", "-m", target, answer }) else _ = quick(wb, &.{ "branch", "-m", answer });
            // It stops tracking its upstream: the next push publishes it.
            _ = quick(wb, &.{ "branch", "--unset-upstream", answer });
        },
        .new_tag => _ = quick(wb, &.{ "tag", answer, target }),
        .stash => slow(wb, .stash, if (answer.len > 0) &.{ "stash", "push", "-m", answer } else &.{ "stash", "push" }, ""),
        .stash_untracked => slow(wb, .stash, if (answer.len > 0) &.{ "stash", "push", "-u", "-m", answer } else &.{ "stash", "push", "-u" }, ""),
        .stash_files => {
            var args: std.ArrayList([]const u8) = .empty;
            defer args.deinit(wb.gpa);
            args.appendSlice(wb.gpa, &.{ "stash", "push", "-u" }) catch return true;
            if (answer.len > 0) args.appendSlice(wb.gpa, &.{ "-m", answer }) catch return true;
            args.append(wb.gpa, "--") catch return true;
            var it = std.mem.splitScalar(u8, target, '\n');
            while (it.next()) |p| if (p.len > 0) args.append(wb.gpa, p) catch {};
            slow(wb, .stash, args.items, "");
        },
        else => return false,
    }
    return true;
}

/// Opens (or shows) the Changes tab, on a file (absolute or relative).
pub fn openChangesTab(wb: *Workbench, path: ?[]const u8, keep: bool) void {
    _ = keep;
    const t = top(wb) orelse return;
    var ed = &wb.editors;
    var found: ?*Changes = null;
    for (ed.cols.items, 0..) |col, ci| for (col.items.items, 0..) |it, i| switch (it.body) {
        .changes => |ch| {
            found = ch;
            ed.show(.{ .col = ci, .idx = i });
        },
        else => {},
    };
    const ch = found orelse blk: {
        const nc = Changes.create(wb.gpa) catch return;
        const it = ed.newItem(.{ .changes = nc }, false) catch {
            nc.destroy();
            return;
        };
        _ = ed.add(it, ed.fileColumn()) catch return;
        break :blk nc;
    };
    ch.rebuild(wb.scm.changes, wb.scm.generation);
    if (path) |p| {
        const rel = fs.relative(t, p);
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (rel.len <= buf.len) {
            @memcpy(buf[0..rel.len], rel);
            std.mem.replaceScalar(u8, buf[0..rel.len], '\\', '/');
            ch.list.select(buf[0..rel.len]);
        }
    }
}

pub fn openCommit(wb: *Workbench, rev: []const u8, keep: bool) void {
    const t = top(wb) orelse return;
    var ed = &wb.editors;
    for (ed.cols.items, 0..) |col, ci| for (col.items.items, 0..) |it, i| switch (it.body) {
        .commit => |cv| if (std.mem.eql(u8, cv.hash, rev) or std.mem.startsWith(u8, cv.hash, rev)) {
            if (keep) it.preview = false;
            ed.show(.{ .col = ci, .idx = i });
            return;
        },
        else => {},
    };
    const cv = CommitView.create(wb.gpa, wb.io, t, rev) catch |err| {
        wb.toastError("Couldn't read the commit", @errorName(err));
        return;
    };
    const it = ed.newItem(.{ .commit = cv }, !keep) catch {
        cv.destroy();
        return;
    };
    _ = ed.add(it, ed.fileColumn()) catch {};
}

/// Reads a side of a diff: a blob, nothing, or the file as the editor has it.
pub fn readSide(ctx: *anyopaque, gpa: std.mem.Allocator, spec: []const u8, path: []const u8) []u8 {
    const wb: *Workbench = @ptrCast(@alignCast(ctx));
    const t = top(wb) orelse return gpa.dupe(u8, "") catch &.{};
    if (openSide(ctx, gpa, spec, path)) |text| return text;
    return readSideAt(gpa, wb.io, t, spec, path);
}

/// An open file's text, for the work tree's side ("@"): main thread only.
fn openSide(ctx: *anyopaque, gpa: std.mem.Allocator, spec: []const u8, path: []const u8) ?[]u8 {
    const wb: *Workbench = @ptrCast(@alignCast(ctx));
    if (!std.mem.eql(u8, spec, "@")) return null;
    const t = top(wb) orelse return null;
    const abs = joinNative(gpa, t, path) catch return null;
    defer gpa.free(abs);
    const d = wb.editors.findDoc(abs) orelse return null;
    return d.editor.area.text(gpa);
}

/// A side as Git and the disk have it, from any thread: a blob (`git
/// show`), the file in the work tree, or a submodule's commit.
fn readSideAt(gpa: std.mem.Allocator, io: std.Io, t: []const u8, spec: []const u8, path: []const u8) []u8 {
    if (spec.len == 0) return gpa.dupe(u8, "") catch &.{};
    if (std.mem.eql(u8, spec, "@")) {
        const abs = joinNative(gpa, t, path) catch return gpa.dupe(u8, "") catch &.{};
        defer gpa.free(abs);
        if (fs.isDirectory(io, abs)) return subproject(io, gpa, abs, null);
        const data = fs.read(gpa, io, abs) catch return gpa.dupe(u8, "") catch &.{};
        if (std.mem.indexOf(u8, data, "\r\n") == null) return data;
        defer gpa.free(data);
        return std.mem.replaceOwned(u8, gpa, data, "\r\n", "\n") catch gpa.dupe(u8, "") catch &.{};
    }
    // A submodule's side is the commit it is at, as `git diff` shows it.
    if (std.fs.path.join(gpa, &.{ t, path })) |abs| {
        defer gpa.free(abs);
        if (fs.isDirectory(io, abs)) return subproject(io, gpa, t, spec);
    } else |_| {}
    const out = hunks.show(gpa, io, t, spec);
    if (std.mem.indexOf(u8, out, "\r\n") == null) return out;
    defer gpa.free(out);
    return std.mem.replaceOwned(u8, gpa, out, "\r\n", "\n") catch gpa.dupe(u8, "") catch &.{};
}

/// "Subproject commit <hash>": of the blob `spec` names in `dir`'s
/// repository, or else of the submodule checked out at `dir`, "-dirty"
/// when its files have changes.
fn subproject(io: std.Io, gpa: std.mem.Allocator, dir: []const u8, spec: ?[]const u8) []u8 {
    const hash = git.line(gpa, io, dir, &.{ "rev-parse", "-q", "--verify", spec orelse "HEAD" }) orelse
        return gpa.dupe(u8, "") catch &.{};
    defer gpa.free(hash);
    var dirty = false;
    if (spec == null) if (git.run(gpa, io, dir, &.{ "status", "--porcelain" })) |r| {
        defer r.deinit(gpa);
        dirty = r.ok and std.mem.trim(u8, r.stdout, " \r\n").len > 0;
    } else |_| {};
    return std.fmt.allocPrint(gpa, "Subproject commit {s}{s}\n", .{ hash, if (dirty) "-dirty" else "" }) catch gpa.dupe(u8, "") catch &.{};
}

/// Reads Git's status on a thread, then gives it to source control
/// (`Workbench.refreshGitSoon`).
pub fn statusInBackground(wb: *Workbench) void {
    const Job = struct {
        wb: *Workbench,
        gpa: std.mem.Allocator,
        io: std.Io,
        top: []u8,
        commits: bool,
        all: bool,
        limit: usize,
        seq: u64,
        ignored: bool,
        st: @import("scm.zig").Scm.Status = .{},

        fn work(j: *@This()) void {
            j.st = @import("scm.zig").Scm.readStatus(j.gpa, j.io, j.top, j.commits, j.all, j.limit);
            if (j.ignored) j.st.ignored = @import("explorer.zig").Explorer.listIgnored(j.gpa, j.io, j.top);
        }

        fn done(j: *@This()) void {
            defer {
                j.gpa.free(j.top);
                j.gpa.destroy(j);
            }
            if (!@import("jobs.zig").isAlive(j.wb)) return j.st.deinit(j.gpa);
            const w = j.wb;
            w.git_job = false;
            // Read before a refresh made at once: that one is newer.
            if (j.seq != w.git_seq) {
                j.st.deinit(j.gpa);
            } else {
                if (j.st.ignored) |ig| {
                    w.explorer.setIgnored(j.top, ig);
                    j.gpa.free(ig);
                    j.st.ignored = null;
                }
                w.scm.applyStatus(j.st);
                w.gitRefreshed();
                if (w.shell.window) |win| win.redraw();
            }
            if (w.git_again) {
                w.git_again = false;
                w.refreshGitSoon();
            }
        }
    };
    const top_dir = wb.scm.top orelse return;
    const j = wb.gpa.create(Job) catch return wb.refreshGit();
    j.* = .{
        .wb = wb,
        .gpa = wb.gpa,
        .io = wb.io,
        .top = wb.gpa.dupe(u8, top_dir) catch {
            wb.gpa.destroy(j);
            return wb.refreshGit();
        },
        .commits = wb.scm.commits_open,
        .all = wb.scm.graph.all,
        .limit = wb.scm.graph.limit,
        .seq = wb.git_seq,
        .ignored = wb.git_ignored,
    };
    wb.git_ignored = false;
    wb.git_job = true;
    @import("jobs.zig").spawn(Job, j, Job.work, Job.done) catch {
        wb.git_job = false;
        wb.gpa.free(j.top);
        wb.gpa.destroy(j);
        wb.refreshGit();
    };
}

pub fn reader(wb: *Workbench) difflist.Reader {
    return .{
        .ctx = wb,
        .read = readSide,
        .capture = openSide,
        .side = if (top(wb) != null) readSideAt else null,
        .top = top(wb) orelse "",
        .io = wb.io,
        .wake = struct {
            fn f(ctx: *anyopaque) void {
                const w: *Workbench = @ptrCast(@alignCast(ctx));
                if (w.shell.window) |win| win.redraw();
            }
        }.f,
    };
}

/// The Changes tab's events.
pub fn diffEvent(wb: *Workbench, c: *ui.Context, dl: *difflist.DiffList, ev: difflist.Event) void {
    if (ev == .none) return;
    c.changed = true;
    const g = wb.gpa;
    const pathOf = struct {
        fn f(d: *difflist.DiffList, gpa: std.mem.Allocator, ei: usize) ?[]u8 {
            if (ei >= d.entries.items.len) return null;
            return gpa.dupe(u8, d.entries.items[ei].path) catch null;
        }
    }.f;
    switch (ev) {
        .none => {},
        .open => |o| {
            const t = top(wb) orelse return;
            const abs = joinNative(g, t, o.path) catch return;
            defer g.free(abs);
            if (fs.isDirectory(wb.io, abs)) return wb.shell.openFolder(abs, false);
            const it = wb.editors.openFile(abs, false) catch return;
            switch (it.body) {
                .file => |d| d.editor.goToLine(o.line),
                else => {},
            }
        },
        .stage_file => |ei| if (pathOf(dl, g, ei)) |p| {
            defer g.free(p);
            _ = quick(wb, &.{ "add", "--", p });
        },
        .unstage_file => |ei| if (pathOf(dl, g, ei)) |p| {
            defer g.free(p);
            _ = quick(wb, &.{ "reset", "-q", "HEAD", "--", p });
        },
        .discard_file => |ei| if (pathOf(dl, g, ei)) |p| {
            defer g.free(p);
            wb.ask(.discard_file, p, "Discard changes?", p, &.{ "Cancel", "Discard" });
        },
        .stage_hunk => |h| hunkOp(wb, c, dl, h.entry, h.hunk, .stage),
        .unstage_hunk => |h| hunkOp(wb, c, dl, h.entry, h.hunk, .unstage),
        .discard_hunk => |h| hunkOp(wb, c, dl, h.entry, h.hunk, .discard),
        .comment => |cm| {
            const e = &dl.entries.items[cm.entry];
            var existing: []const u8 = "";
            for (wb.review.list.items) |k| if (std.mem.eql(u8, k.path, e.path) and k.first == cm.first and k.last == cm.last) {
                existing = k.text;
            };
            wb.diff_comment.clearRetainingCapacity();
            wb.diff_comment.appendSlice(g, cm.snippet) catch {};
            var buf: [std.fs.max_path_bytes + 64]u8 = undefined;
            const target = std.fmt.bufPrint(&buf, "{d}:{d}:{s}", .{ cm.first, cm.last, e.path }) catch return;
            wb.prompt.askText(g, .diff_comment, if (cm.first == cm.last) "A comment on this line" else "A comment on these lines", existing, target);
        },
        .delete_comment => |i| if (i < wb.review.list.items.len) wb.review.remove(i),
        .send_review => @import("wb_run.zig").run(wb, c, .send_review),
        .edit_comment => |i| if (i < wb.review.list.items.len) {
            const k = wb.review.list.items[i];
            wb.diff_comment.clearRetainingCapacity();
            wb.diff_comment.appendSlice(g, k.snippet) catch {};
            var buf: [std.fs.max_path_bytes + 64]u8 = undefined;
            const target = std.fmt.bufPrint(&buf, "{d}:{d}:{s}", .{ k.first, k.last, k.path }) catch return;
            wb.prompt.askText(g, .diff_comment, "Edit the comment", k.text, target);
        },
    }
}

const HunkOp = enum { stage, unstage, discard };

/// Stages, unstages or discards one run of changes of an entry, reading
/// the index and the file again first.
fn hunkOp(wb: *Workbench, c: *ui.Context, dl: *difflist.DiffList, ei: usize, k: usize, op: HunkOp) void {
    const t = top(wb) orelse return;
    if (ei >= dl.entries.items.len) return;
    const e = &dl.entries.items[ei];
    dl.load(e, reader(wb));
    const hs = hunks.hunksOf(c.alloc(), e.old_text, e.new_text) catch return;
    if (k >= hs.len) {
        _ = wb.toasts.show("The change moved: look again");
        return;
    }
    const h = hs[k];
    const g = wb.gpa;
    switch (op) {
        .stage => {
            // The index gets the work tree's lines of this hunk.
            const out = hunks.apply(g, .{ .a = e.old_text, .b = e.new_text }, h, .b) catch return;
            defer g.free(out);
            hunks.writeIndex(g, wb.io, t, e.path, out) catch |err| wb.toastError("Couldn't stage", @errorName(err));
        },
        .unstage => {
            const out = hunks.apply(g, .{ .a = e.old_text, .b = e.new_text }, h, .a) catch return;
            defer g.free(out);
            hunks.writeIndex(g, wb.io, t, e.path, out) catch |err| wb.toastError("Couldn't unstage", @errorName(err));
        },
        .discard => {
            const out = hunks.apply(g, .{ .a = e.old_text, .b = e.new_text }, h, .a) catch return;
            defer g.free(out);
            const abs = joinNative(g, t, e.path) catch return;
            defer g.free(abs);
            if (wb.editors.findDoc(abs)) |d| {
                // An open file: a step of its undo.
                d.editor.area.setText(out);
            } else fs.write(wb.io, abs, out) catch |err| wb.toastError("Couldn't discard", @errorName(err));
        },
    }
    wb.refreshGit();
    dl.reload(reader(wb));
}

/// Stages or reverts the run of changes at the caret of the file shown.
pub fn hunkAtCaret(wb: *Workbench, stage: bool) void {
    const t = top(wb) orelse return;
    const d = wb.editors.currentDoc() orelse return;
    if (d.path.len == 0) return;
    const g = wb.gpa;
    const rel = g.dupe(u8, fs.relative(t, d.path)) catch return;
    defer g.free(rel);
    std.mem.replaceScalar(u8, rel, '\\', '/');
    var spec_buf: [std.fs.max_path_bytes + 2]u8 = undefined;
    const spec = std.fmt.bufPrint(&spec_buf, ":{s}", .{rel}) catch return;
    const index = hunks.show(g, wb.io, t, spec);
    defer g.free(index);
    const now = d.text();
    defer g.free(now);
    const hs = hunks.hunksOf(g, index, now) catch return;
    defer g.free(hs);
    const line = d.editor.area.caretLine();
    for (hs) |h| {
        const hit = (line >= h.b0 and line < @max(h.b1, h.b0 + 1));
        if (!hit) continue;
        if (stage) {
            const out = hunks.apply(g, .{ .a = index, .b = now }, h, .b) catch return;
            defer g.free(out);
            hunks.writeIndex(g, wb.io, t, rel, out) catch |err| wb.toastError("Couldn't stage", @errorName(err));
        } else {
            const out = hunks.apply(g, .{ .a = index, .b = now }, h, .a) catch return;
            defer g.free(out);
            d.editor.area.setText(out);
        }
        wb.refreshGit();
        return;
    }
    _ = wb.toasts.show("No change at the caret");
}

/// Resolves the conflict at the caret (or every one) by taking a side, as a
/// step of undo; once the last is gone, offers to stage the file.
pub fn acceptConflict(wb: *Workbench, side: conflicts.Side, all: bool) void {
    const d = wb.editors.currentDoc() orelse return;
    d.updateConflicts();
    if (d.blocks.len == 0) return;
    const g = wb.gpa;
    const text = d.text();
    defer g.free(text);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(g);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| lines.append(g, l) catch return;
    const caret_line = d.editor.area.caretLine();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(g);
    var li: usize = 0;
    for (d.blocks) |b| {
        const take = all or (caret_line >= b.start and caret_line <= b.end);
        if (!take) continue;
        while (li < b.start) : (li += 1) {
            out.appendSlice(g, lines.items[li]) catch return;
            out.append(g, '\n') catch return;
        }
        const r = conflicts.resolved(g, lines.items, b, side) catch return;
        defer g.free(r);
        out.appendSlice(g, r) catch return;
        li = b.end + 1;
    }
    if (li == 0) return;
    while (li < lines.items.len) : (li += 1) {
        out.appendSlice(g, lines.items[li]) catch return;
        if (li + 1 < lines.items.len) out.append(g, '\n') catch return;
    }
    const caret = d.editor.area.sel.caret;
    d.editor.area.setText(out.items);
    d.editor.area.collapse(@min(caret, out.items.len));
    d.updateConflicts();
    if (d.blocks.len == 0) wb.toast_stage_conflicts = wb.toasts.showAction("Conflicts resolved", "Stage");
}

pub fn stageCurrentFile(wb: *Workbench) void {
    const t = top(wb) orelse return;
    const d = wb.editors.currentDoc() orelse return;
    d.save() catch {};
    const rel = wb.gpa.dupe(u8, fs.relative(t, d.path)) catch return;
    defer wb.gpa.free(rel);
    _ = quick(wb, &.{ "add", "--", rel });
}

/// The caret line's last change, read off the main thread a moment after
/// the caret stops (inline blame).
pub const BlameJob = struct {
    wb: *Workbench,
    gpa: std.mem.Allocator,
    io: std.Io,
    key: u64,
    top: []u8,
    path: []u8,
    line: usize,
    out: []u8 = &.{},

    pub fn work(j: *BlameJob) void {
        const g = j.gpa;
        var buf: [64]u8 = undefined;
        const range = std.fmt.bufPrint(&buf, "{d},{d}", .{ j.line + 1, j.line + 1 }) catch return;
        const r = git.run(g, j.io, j.top, &.{ "blame", "--porcelain", "-L", range, "--", j.path }) catch return;
        defer r.deinit(g);
        if (!r.ok) return;
        var author: []const u8 = "";
        var time: i64 = 0;
        var summary: []const u8 = "";
        var hash: []const u8 = "";
        var it = std.mem.splitScalar(u8, r.stdout, '\n');
        if (it.next()) |first| hash = std.mem.sliceTo(first, ' ');
        while (it.next()) |l| {
            if (std.mem.startsWith(u8, l, "author ")) author = l[7..];
            if (std.mem.startsWith(u8, l, "author-time ")) time = std.fmt.parseInt(i64, l[12..], 10) catch 0;
            if (std.mem.startsWith(u8, l, "summary ")) summary = l[8..];
        }
        if (std.mem.startsWith(u8, hash, "0000000")) {
            j.out = g.dupe(u8, "You, not committed yet") catch &.{};
            return;
        }
        const now = std.Io.Clock.real.now(j.io).toSeconds();
        j.out = std.fmt.allocPrint(g, "{s}, {s} • {s}", .{ author, ago(&buf, now - time), summary }) catch &.{};
    }

    pub fn done(j: *BlameJob) void {
        const wb = j.wb;
        if (!@import("jobs.zig").isAlive(wb)) return j.free();
        wb.blame_busy = false;
        if (j.key == wb.blame_key) {
            wb.blame.clearRetainingCapacity();
            wb.blame.appendSlice(wb.gpa, j.out) catch {};
            if (wb.shell.window) |w| w.redraw();
        }
        j.free();
    }

    fn free(j: *BlameJob) void {
        j.gpa.free(j.out);
        j.gpa.free(j.top);
        j.gpa.free(j.path);
        j.gpa.destroy(j);
    }
};

fn ago(buf: []u8, s: i64) []const u8 {
    const units = [_]struct { i64, []const u8 }{ .{ 365 * 86400, "year" }, .{ 30 * 86400, "month" }, .{ 7 * 86400, "week" }, .{ 86400, "day" }, .{ 3600, "hour" }, .{ 60, "minute" } };
    for (units) |u| if (s >= u[0]) {
        const n = @divTrunc(s, u[0]);
        return std.fmt.bufPrint(buf, "{d} {s}{s} ago", .{ n, u[1], if (n == 1) "" else "s" }) catch "";
    };
    return "just now";
}
