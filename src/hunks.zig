//! Staging, unstaging and discarding one run of changes. As hunks.go does,
//! the index's blob is made here (`git hash-object -w` and `git
//! update-index --cacheinfo`) rather than by applying a patch.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const git = @import("git.zig");
const fs = @import("fs.zig");

pub const Hunk = ui.diff.Hunk;

/// `lines` (each without its newline), its lines [from, to) replaced by
/// `with`, joined again; `ends_nl` keeps a last newline.
pub fn splice(gpa: std.mem.Allocator, lines: []const []const u8, from: usize, to: usize, with: []const []const u8, ends_nl: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var first = true;
    const parts = [_][]const []const u8{ lines[0..from], with, lines[to..] };
    for (parts) |part| for (part) |l| {
        if (!first) try out.append(gpa, '\n');
        first = false;
        try out.appendSlice(gpa, l);
    };
    if (ends_nl and out.items.len > 0) try out.append(gpa, '\n');
    return out.toOwnedSlice(gpa);
}

pub const Texts = struct {
    a: []const u8,
    b: []const u8,
};

/// `b` with hunk `h` of the diff from `a` to `b` taken back to `a`'s lines
/// (unstage, discard), or `a` with it taken to `b`'s (stage).
pub fn apply(gpa: std.mem.Allocator, t: Texts, h: Hunk, comptime toward: enum { a, b }) ![]u8 {
    const al = try ui.diff.splitLines(gpa, t.a);
    defer gpa.free(al);
    const bl = try ui.diff.splitLines(gpa, t.b);
    defer gpa.free(bl);
    return switch (toward) {
        // Stage: the index (a) gets the work tree's (b) lines of the hunk.
        .b => splice(gpa, trimLast(al, t.a), h.a0, h.a1, trimLast(bl, t.b)[h.b0..h.b1], endsNl(t.a, t.b)),
        // Unstage or discard: b gets a's lines back.
        .a => splice(gpa, trimLast(bl, t.b), h.b0, h.b1, trimLast(al, t.a)[h.a0..h.a1], endsNl(t.b, t.a)),
    };
}

fn endsNl(primary: []const u8, other: []const u8) bool {
    if (primary.len > 0) return primary[primary.len - 1] == '\n';
    return other.len > 0 and other[other.len - 1] == '\n';
}

/// splitLines may give an empty last line after a final newline: not a line.
fn trimLast(lines: []const []const u8, text: []const u8) []const []const u8 {
    if (lines.len > 0 and lines[lines.len - 1].len == 0 and text.len > 0 and text[text.len - 1] == '\n') return lines[0 .. lines.len - 1];
    return lines;
}

/// The hunks from `a` to `b`, as the diff view shows them.
pub fn hunksOf(gpa: std.mem.Allocator, a: []const u8, b: []const u8) ![]Hunk {
    const al = try ui.diff.splitLines(gpa, a);
    defer gpa.free(al);
    const bl = try ui.diff.splitLines(gpa, b);
    defer gpa.free(bl);
    return ui.diff.lines(gpa, trimLast(al, a), trimLast(bl, b));
}

/// Writes `content` as the index's blob of `rel` (relative to `top`).
pub fn writeIndex(gpa: std.mem.Allocator, io: std.Io, top: []const u8, rel: []const u8, content: []const u8) !void {
    const gitdir = git.line(gpa, io, top, &.{ "rev-parse", "--absolute-git-dir" }) orelse return error.GitFailed;
    defer gpa.free(gitdir);
    const tmp = try std.fs.path.join(gpa, &.{ gitdir, "mycode-hunk.tmp" });
    defer gpa.free(tmp);
    try fs.write(io, tmp, content);
    defer std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
    const sha = git.line(gpa, io, top, &.{ "hash-object", "-w", "--no-filters", tmp }) orelse return error.GitFailed;
    defer gpa.free(sha);
    // The mode the index has, else a regular file's.
    var mode: []const u8 = "100644";
    const ls = git.line(gpa, io, top, &.{ "ls-files", "-s", "--", rel });
    defer if (ls) |l| gpa.free(l);
    if (ls) |l| if (l.len > 6) {
        mode = l[0..6];
    };
    const info = try std.fmt.allocPrint(gpa, "{s},{s},{s}", .{ mode, sha, rel });
    defer gpa.free(info);
    const r = try git.run(gpa, io, top, &.{ "update-index", "--add", "--cacheinfo", info });
    defer r.deinit(gpa);
    if (!r.ok) return error.GitFailed;
}

/// A blob's text: `HEAD:path`, `:path` (the index), or "" when it isn't there.
pub fn show(gpa: std.mem.Allocator, io: std.Io, top: []const u8, spec: []const u8) []u8 {
    const r = git.run(gpa, io, top, &.{ "show", spec }) catch return gpa.dupe(u8, "") catch &.{};
    gpa.free(r.stderr);
    if (!r.ok) {
        gpa.free(r.stdout);
        return gpa.dupe(u8, "") catch &.{};
    }
    return r.stdout;
}

test apply {
    const gpa = std.testing.allocator;
    const a = "one\ntwo\nthree\nfour\n";
    const b = "one\nTWO\nthree\nfour\nfive\n";
    const hs = try hunksOf(gpa, a, b);
    defer gpa.free(hs);
    try std.testing.expectEqual(@as(usize, 2), hs.len);
    // Staging the first hunk alone.
    const staged = try apply(gpa, .{ .a = a, .b = b }, hs[0], .b);
    defer gpa.free(staged);
    try std.testing.expectEqualStrings("one\nTWO\nthree\nfour\n", staged);
    // Discarding the second.
    const back = try apply(gpa, .{ .a = a, .b = b }, hs[1], .a);
    defer gpa.free(back);
    try std.testing.expectEqualStrings("one\nTWO\nthree\nfour\n", back);
}
