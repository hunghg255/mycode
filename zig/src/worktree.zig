//! Git's worktrees, as the Go app's `worktree.go`: a branch checked out in
//! another worktree opens that worktree (here or in a window of its own),
//! and one whose folder is gone is pruned so the branch switches here.
//! Also whether the files Git is about to change are saved.
const std = @import("std");
const fs = @import("fs.zig");
const git = @import("git.zig");
const Workbench = @import("workbench.zig").Workbench;

/// The worktree a local branch is checked out in, from `git worktree list
/// --porcelain -z`, which keeps unusual paths whole; null if none.
pub fn forBranch(out: []const u8, branch: []const u8) ?[]const u8 {
    var path: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, out, 0);
    while (it.next()) |field| {
        if (field.len == 0) {
            path = null;
        } else if (std.mem.startsWith(u8, field, "worktree ")) {
            path = field["worktree ".len..];
        } else if (std.mem.startsWith(u8, field, "branch refs/heads/") and std.mem.eql(u8, field["branch refs/heads/".len..], branch)) {
            if (path) |p| return p;
        }
    }
    return null;
}

fn samePath(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const nx = if (x == '\\') '/' else std.ascii.toLower(x);
        const ny = if (y == '\\') '/' else std.ascii.toLower(y);
        if (nx != ny) return false;
    }
    return true;
}

/// After a checkout of `branch` failed: if another worktree holds the
/// branch, asks to open it, or to prune it when its folder is gone; true
/// if it asked.
pub fn askIfHeld(wb: *Workbench, branch: []const u8) bool {
    const t = wb.scm.top orelse return false;
    const r = git.run(wb.gpa, wb.io, t, &.{ "worktree", "list", "--porcelain", "-z" }) catch return false;
    defer r.deinit(wb.gpa);
    if (!r.ok) return false;
    const path = forBranch(r.stdout, branch) orelse return false;
    if (samePath(path, t)) return false;
    const arg = std.mem.concat(wb.gpa, u8, &.{ branch, "\n", path }) catch return false;
    defer wb.gpa.free(arg);
    var buf: [2048]u8 = undefined;
    if (!fs.isDirectory(wb.io, path)) {
        const text = std.fmt.bufPrint(&buf, "The branch “{s}” is checked out in a worktree whose folder is gone:\n\n{s}\n\nPrune the missing worktree and switch to the branch here?", .{ branch, path }) catch return false;
        wb.ask(.prune_worktree, arg, "Worktree Folder Missing", text, &.{ "Cancel", "Prune and Switch" });
        return true;
    }
    const text = std.fmt.bufPrint(&buf, "The branch “{s}” is already checked out in:\n\n{s}\n\nChoose where to open this worktree.", .{ branch, path }) catch return false;
    wb.ask(.open_worktree, arg, "Open Existing Worktree?", text, &.{ "Cancel", "Current Window", "New Window" });
    return true;
}

/// The answer to `askIfHeld`'s question, `arg` the branch and the path.
pub fn answer(wb: *Workbench, prune: bool, arg: []const u8, button: usize) void {
    if (button == 0) return;
    const nl = std.mem.indexOfScalar(u8, arg, '\n') orelse return;
    const branch = arg[0..nl];
    const path = arg[nl + 1 ..];
    if (prune) {
        const t = wb.scm.top orelse return;
        const r = git.run(wb.gpa, wb.io, t, &.{ "worktree", "prune" }) catch return;
        defer r.deinit(wb.gpa);
        if (!r.ok) return wb.toastError("Git", std.mem.trim(u8, r.stderr, " \r\n"));
        @import("wb_git.zig").switchTo(wb, branch);
        return;
    }
    if (!fs.isDirectory(wb.io, path)) return wb.toastError("Couldn't open the worktree", path);
    wb.shell.openFolder(path, button == 2);
}

/// Whether the open files under the work tree are saved; if one isn't,
/// says so, before what `doing` names (the Go app's `docsSaved`).
pub fn docsSaved(wb: *Workbench, doing: []const u8) bool {
    const t = wb.scm.top orelse return true;
    for (wb.editors.cols.items) |col| for (col.items.items) |it| switch (it.body) {
        .file => |d| if (d.dirty() and d.path.len > 0 and fs.relative(t, d.path).ptr != d.path.ptr) {
            var buf: [512]u8 = undefined;
            wb.toastError(std.fmt.bufPrint(&buf, "Save the changes of {s} before {s}.", .{ d.name(), doing }) catch "Save your changes first.", "");
            return false;
        },
        else => {},
    };
    return true;
}

test forBranch {
    const out = "worktree /a\x00HEAD 1\x00branch refs/heads/main\x00\x00worktree /b c\x00HEAD 2\x00branch refs/heads/feat\x00\x00";
    try std.testing.expectEqualStrings("/b c", forBranch(out, "feat").?);
    try std.testing.expectEqualStrings("/a", forBranch(out, "main").?);
    try std.testing.expect(forBranch(out, "fea") == null);
    try std.testing.expect(samePath("D:\\x\\Y", "d:/x/y"));
}
