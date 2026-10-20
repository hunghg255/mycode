//! Git through its command line, never a library, with prompts disabled,
//! as internal/git does in the Go app.
const std = @import("std");
const Io = std.Io;

/// The environment git runs with: the app's, with prompts and optional
/// locks off. Made once by `init`, then only read (from any thread).
var env: ?std.process.Environ.Map = null;

pub fn init(gpa: std.mem.Allocator, base: *const std.process.Environ.Map) !void {
    var m = try base.clone(gpa);
    try m.put("GIT_TERMINAL_PROMPT", "0");
    try m.put("GIT_OPTIONAL_LOCKS", "0");
    // Git's words in English, which the app reads; no editor for messages.
    try m.put("LC_ALL", "C");
    try m.put("GIT_EDITOR", "true");
    env = m;
}

pub const Result = struct {
    ok: bool,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(r: Result, gpa: std.mem.Allocator) void {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    }
};

/// Runs `git args...` in `dir`.
pub fn run(gpa: std.mem.Allocator, io: Io, dir: []const u8, args: []const []const u8) !Result {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "git", "-c", "core.quotepath=off", "-c", "color.ui=false" });
    try argv.appendSlice(gpa, args);
    const r = try std.process.run(gpa, io, .{
        .argv = argv.items,
        .cwd = .{ .path = dir },
        .environ_map = if (env) |*m| m else null,
        .stdout_limit = .limited(256 << 20),
    });
    return .{ .ok = r.term.success(), .stdout = r.stdout, .stderr = r.stderr };
}

/// The output of a command that succeeded, trimmed, or null.
pub fn line(gpa: std.mem.Allocator, io: Io, dir: []const u8, args: []const []const u8) ?[]u8 {
    const r = run(gpa, io, dir, args) catch return null;
    defer gpa.free(r.stderr);
    if (!r.ok) {
        gpa.free(r.stdout);
        return null;
    }
    const t = std.mem.trim(u8, r.stdout, " \r\n\t");
    const out = gpa.dupe(u8, t) catch null;
    gpa.free(r.stdout);
    return out;
}

/// The work tree's top folder, or null outside one.
pub fn topLevel(gpa: std.mem.Allocator, io: Io, dir: []const u8) ?[]u8 {
    return line(gpa, io, dir, &.{ "rev-parse", "--show-toplevel" });
}

/// The branch checked out, or the short hash of a detached HEAD.
pub fn branch(gpa: std.mem.Allocator, io: Io, dir: []const u8) ?[]u8 {
    const b = line(gpa, io, dir, &.{ "rev-parse", "--abbrev-ref", "HEAD" }) orelse return null;
    if (!std.mem.eql(u8, b, "HEAD")) return b;
    gpa.free(b);
    return line(gpa, io, dir, &.{ "rev-parse", "--short", "HEAD" });
}

/// The files Git tracks or would track (not ignored), relative, with slashes.
pub fn listFiles(gpa: std.mem.Allocator, io: Io, dir: []const u8) ![][]const u8 {
    const r = try run(gpa, io, dir, &.{ "ls-files", "-z", "--cached", "--others", "--exclude-standard" });
    defer r.deinit(gpa);
    if (!r.ok) return error.GitFailed;
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |s| gpa.free(s);
        out.deinit(gpa);
    }
    var it = std.mem.tokenizeScalar(u8, r.stdout, 0);
    var last: []const u8 = "";
    while (it.next()) |p| {
        // A conflicted file is listed once per stage.
        if (std.mem.eql(u8, p, last)) continue;
        last = p;
        try out.append(gpa, try gpa.dupe(u8, p));
    }
    return out.toOwnedSlice(gpa);
}

pub const Status = enum(u8) {
    modified = 'M',
    added = 'A',
    deleted = 'D',
    renamed = 'R',
    untracked = 'U',
    conflict = 'C',
    ignored = 'I',
};

pub const Change = struct {
    /// Relative to the work tree's top, with slashes.
    path: []const u8,
    /// Where a rename came from.
    orig: ?[]const u8 = null,
    /// The index's state (X) and the work tree's (Y), as porcelain v1 writes them.
    x: u8,
    y: u8,

    pub fn status(ch: Change) Status {
        if (ch.x == 'U' or ch.y == 'U' or (ch.x == 'A' and ch.y == 'A') or (ch.x == 'D' and ch.y == 'D')) return .conflict;
        if (ch.x == '?') return .untracked;
        if (ch.x == '!') return .ignored;
        const k = if (ch.y != ' ' and ch.y != 0) ch.y else ch.x;
        return switch (k) {
            'A' => .added,
            'D' => .deleted,
            'R', 'C' => .renamed,
            else => .modified,
        };
    }

    pub fn staged(ch: Change) bool {
        return ch.x != ' ' and ch.x != '?' and ch.x != '!' and ch.status() != .conflict;
    }

    pub fn unstaged(ch: Change) bool {
        return ch.y != ' ' and ch.x != '?' and ch.status() != .conflict;
    }
};

/// The work tree's changes (`git status --porcelain=v1 -z`). The changes'
/// strings are in `buf`, which the caller frees.
pub fn status(gpa: std.mem.Allocator, io: Io, dir: []const u8, buf: *[]u8) ![]Change {
    const r = try run(gpa, io, dir, &.{ "status", "--porcelain=v1", "-z", "--untracked-files=all" });
    gpa.free(r.stderr);
    if (!r.ok) {
        gpa.free(r.stdout);
        return error.GitFailed;
    }
    buf.* = r.stdout;
    return parseStatus(gpa, r.stdout);
}

pub fn parseStatus(gpa: std.mem.Allocator, out: []const u8) ![]Change {
    var list: std.ArrayList(Change) = .empty;
    errdefer list.deinit(gpa);
    var it = std.mem.splitScalar(u8, out, 0);
    while (it.next()) |rec| {
        if (rec.len < 4) continue;
        var ch: Change = .{ .x = rec[0], .y = rec[1], .path = rec[3..] };
        if (ch.x == 'R' or ch.x == 'C') ch.orig = it.next();
        try list.append(gpa, ch);
    }
    return list.toOwnedSlice(gpa);
}

test parseStatus {
    const gpa = std.testing.allocator;
    const out = " M a.go\x00R  new.go\x00old.go\x00?? n.txt\x00UU c.go\x00";
    const ch = try parseStatus(gpa, out);
    defer gpa.free(ch);
    try std.testing.expectEqual(@as(usize, 4), ch.len);
    try std.testing.expectEqual(Status.modified, ch[0].status());
    try std.testing.expectEqualStrings("old.go", ch[1].orig.?);
    try std.testing.expect(ch[1].staged());
    try std.testing.expectEqual(Status.untracked, ch[2].status());
    try std.testing.expectEqual(Status.conflict, ch[3].status());
}
