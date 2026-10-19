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
    // Files save first: Git reads them from the disk.
    wb.editors.saveAll();
    if (!wb.runner.run(kind, t, args, subject)) _ = wb.toasts.show("A Git command is running");
}

pub fn run(wb: *Workbench, c: *ui.Context, cmd: Cmd) void {
    _ = c;
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
        .git_refresh => wb.refreshGit(),
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
        .git_create_branch => wb.prompt.ask(.new_branch, "A new branch's name", "", ""),
        .git_rename_branch => wb.prompt.ask(.rename_branch, "Rename the branch", wb.scm.branch orelse "", ""),
        .git_stash => wb.prompt.ask(.stash, "Stash: a message (or none)", "", ""),
        .git_stash_untracked => wb.prompt.ask(.stash_untracked, "Stash with untracked files: a message (or none)", "", ""),
        .git_stash_apply_latest => slow(wb, .stash_apply, &.{ "stash", "apply", "--index" }, "stash@{0}"),
        .git_stash_pop => slow(wb, .stash_pop, &.{ "stash", "pop", "--index" }, "stash@{0}"),
        .git_stash_apply => wb.picker.show(t.?, .stash_apply),
        .git_stash_pop_pick => wb.picker.show(t.?, .stash_pop),
        .git_stash_view => wb.picker.show(t.?, .stash_view),
        .git_stash_drop => wb.picker.show(t.?, .stash_drop),
        .show_all_branches => {
            wb.scm.graph.all = !wb.scm.graph.all;
            wb.scm.graph.load(wb.io, t.?);
        },
        .scm_tree => wb.scm.tree = !wb.scm.tree,
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
    args.appendSlice(wb.gpa, &.{"commit"}) catch return;
    if (all) args.append(wb.gpa, "-a") catch return;
    if (amend) args.append(wb.gpa, "--amend") catch return;
    if (msg.len > 0) args.appendSlice(wb.gpa, &.{ "-m", msg }) catch return else args.append(wb.gpa, "--no-edit") catch return;
    if (quick(wb, args.items)) {
        wb.scm.message.clear();
        wb.toast_undo_commit = wb.toasts.showAction("Committed", "Undo");
        if (then_push) push(wb, false);
    }
}

fn amendFill(wb: *Workbench) void {
    const t = top(wb) orelse return;
    const m = git.line(wb.gpa, wb.io, t, &.{ "log", "-1", "--format=%B" }) orelse return;
    defer wb.gpa.free(m);
    wb.scm.message.set(m);
    wb.sidebar_open = true;
    wb.side = .scm;
    wb.ask(.commit_all, "amend", "Amend the last commit?", "The staged changes and the message go into the last commit.", &.{ "Cancel", "Amend" });
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
        if (d.kind == .stash_pop or d.kind == .stash_apply) {
            wb.toastError("The stash clashes with your changes", "The files are left in conflict to resolve; the stash entry is kept.");
            return;
        }
        wb.scm.setError(m);
        wb.toastError("Git", m);
        return;
    }
    wb.scm.setError("");
    switch (d.kind) {
        .push, .publish, .force_push => _ = wb.toasts.add(.{ .title = "Pushed", .kind = .success }),
        .pull, .pull_rebase, .pull_merge => _ = wb.toasts.add(.{ .title = "Pulled", .kind = .success }),
        .sync => _ = wb.toasts.add(.{ .title = "Synced", .kind = .success }),
        .fetch => _ = wb.toasts.show("Fetched"),
        .stash => wb.toast_pop_stash = wb.toasts.showAction("Changes stashed", "Pop"),
        .stash_pop => _ = wb.toasts.show("Stash popped"),
        .stash_apply => _ = wb.toasts.show("Stash applied"),
        .checkout, .create_branch => _ = wb.toasts.show(wb.gpa.dupe(u8, "Switched branch") catch "Switched"),
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
            if (fs.exists(wb.io, abs)) _ = wb.editors.openFile(abs, false) catch {};
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
        .branch_at => |h| wb.prompt.ask(.new_branch_at, "A new branch's name, at this commit", "", h),
        .tag_at => |h| wb.prompt.ask(.new_tag, "A new tag's name", "", h),
        .stage => |p| {
            const pp = g.dupe(u8, p) catch return;
            defer g.free(pp);
            _ = quick(wb, &.{ "add", "--", pp });
            stageConflictToast(wb);
        },
        .unstage => |p| {
            const pp = g.dupe(u8, p) catch return;
            defer g.free(pp);
            _ = quick(wb, &.{ "reset", "-q", "HEAD", "--", pp });
        },
        .discard => |p| wb.ask(.discard_file, p, "Discard changes?", c.print("{s}\nThis can't be undone; an untracked file goes to the Recycle Bin.", .{p}), &.{ "Cancel", "Discard" }),
        .stage_all => |grp| switch (grp) {
            .untracked => _ = quick(wb, &.{ "add", "-A", "--", "." }),
            else => _ = quick(wb, &.{ "add", "-u", "--", "." }),
        },
        .unstage_all => _ = quick(wb, &.{ "reset", "-q", "HEAD", "--", "." }),
        .discard_all => wb.ask(.discard_all, "", "Discard all changes?", "Every change not staged is lost, and untracked files go to the Recycle Bin.", &.{ "Cancel", "Discard All" }),
        .stash_files => |p| wb.prompt.ask(.stash_files, "Stash this file: a message (or none)", "", p),
    }
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
        .discard_file => if (button == 1) discardFile(wb, arg),
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
    if (upstream_too) {
        const up = git.line(wb.gpa, wb.io, t, &.{ "config", "--get", "branch.placeholder.remote" });
        if (up) |u| wb.gpa.free(u);
    }
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
        .delete => |b| wb.ask(.delete_branch, b.name, c.print("Delete the branch “{s}”?", .{b.name}), if (b.remote) "It is deleted on its remote." else "The toast's Undo brings it back.", &.{ "Cancel", "Delete" }),
        .rename => |b| wb.prompt.ask(.rename_branch, "Rename the branch", b.name, b.name),
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
        .stash_files => slow(wb, .stash, if (answer.len > 0) &.{ "stash", "push", "-u", "-m", answer, "--", target } else &.{ "stash", "push", "-u", "--", target }, ""),
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
    if (spec.len == 0) return gpa.dupe(u8, "") catch &.{};
    if (std.mem.eql(u8, spec, "@")) {
        const abs = joinNative(gpa, t, path) catch return gpa.dupe(u8, "") catch &.{};
        defer gpa.free(abs);
        if (wb.editors.findDoc(abs)) |d| return d.editor.area.text(gpa);
        const data = fs.read(gpa, wb.io, abs) catch return gpa.dupe(u8, "") catch &.{};
        if (std.mem.indexOf(u8, data, "\r\n") == null) return data;
        defer gpa.free(data);
        return std.mem.replaceOwned(u8, gpa, data, "\r\n", "\n") catch gpa.dupe(u8, "") catch &.{};
    }
    const out = hunks.show(gpa, wb.io, t, spec);
    if (std.mem.indexOf(u8, out, "\r\n") == null) return out;
    defer gpa.free(out);
    return std.mem.replaceOwned(u8, gpa, out, "\r\n", "\n") catch gpa.dupe(u8, "") catch &.{};
}

pub fn reader(wb: *Workbench) difflist.Reader {
    return .{ .ctx = wb, .read = readSide };
}

/// The Changes tab's events.
pub fn diffEvent(wb: *Workbench, c: *ui.Context, dl: *difflist.DiffList, ev: difflist.Event) void {
    if (ev == .none) return;
    c.changed = true;
    const e = dl.current() orelse return;
    const g = wb.gpa;
    const path = g.dupe(u8, e.path) catch return;
    defer g.free(path);
    switch (ev) {
        .none => {},
        .open => |o| {
            const t = top(wb) orelse return;
            const abs = joinNative(g, t, o.path) catch return;
            defer g.free(abs);
            const it = wb.editors.openFile(abs, false) catch return;
            switch (it.body) {
                .file => |d| d.editor.goToLine(o.line),
                else => {},
            }
        },
        .stage_file => _ = quick(wb, &.{ "add", "--", path }),
        .unstage_file => _ = quick(wb, &.{ "reset", "-q", "HEAD", "--", path }),
        .discard_file => wb.ask(.discard_file, path, "Discard changes?", path, &.{ "Cancel", "Discard" }),
        .stage_hunk, .unstage_hunk, .discard_hunk => |k| hunkOp(wb, c, dl, k, ev),
    }
}

/// Stages, unstages or discards one run of changes of the entry chosen,
/// reading the index and the file again first.
fn hunkOp(wb: *Workbench, c: *ui.Context, dl: *difflist.DiffList, k: usize, ev: difflist.Event) void {
    const t = top(wb) orelse return;
    const e = dl.current() orelse return;
    dl.reload(reader(wb));
    const hs = hunks.hunksOf(c.alloc(), e.old_text, e.new_text) catch return;
    if (k >= hs.len) return;
    const h = hs[k];
    const g = wb.gpa;
    switch (ev) {
        .stage_hunk => {
            // The index gets the work tree's lines of this hunk.
            const out = hunks.apply(g, .{ .a = e.old_text, .b = e.new_text }, h, .b) catch return;
            defer g.free(out);
            hunks.writeIndex(g, wb.io, t, e.path, out) catch |err| wb.toastError("Couldn't stage", @errorName(err));
        },
        .unstage_hunk => {
            const out = hunks.apply(g, .{ .a = e.old_text, .b = e.new_text }, h, .a) catch return;
            defer g.free(out);
            hunks.writeIndex(g, wb.io, t, e.path, out) catch |err| wb.toastError("Couldn't unstage", @errorName(err));
        },
        .discard_hunk => {
            const out = hunks.apply(g, .{ .a = e.old_text, .b = e.new_text }, h, .a) catch return;
            defer g.free(out);
            const abs = joinNative(g, t, e.path) catch return;
            defer g.free(abs);
            if (wb.editors.findDoc(abs)) |d| {
                // An open file: a step of its undo.
                d.editor.area.setText(out);
            } else fs.write(wb.io, abs, out) catch |err| wb.toastError("Couldn't discard", @errorName(err));
        },
        else => {},
    }
    wb.refreshGit();
    if (wb.editors.current()) |it| switch (it.body) {
        .changes => |ch| ch.rebuild(wb.scm.changes, wb.scm.generation),
        else => {},
    };
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
