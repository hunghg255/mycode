//! The Changes tab: every file changed, as source control lists them, the
//! staged changes first (HEAD to the index), then the rest (the index to the
//! work tree), each diff following the file as it is typed.
const std = @import("std");
const git = @import("git.zig");
const DiffList = @import("difflist.zig").DiffList;

pub const Changes = struct {
    gpa: std.mem.Allocator,
    list: DiffList,
    /// The status it was made of, to make it again only when that changed.
    seen: u64 = 0,

    pub fn create(gpa: std.mem.Allocator) !*Changes {
        const ch = try gpa.create(Changes);
        ch.* = .{ .gpa = gpa, .list = .{ .gpa = gpa } };
        return ch;
    }

    pub fn destroy(ch: *Changes) void {
        ch.list.deinit();
        ch.gpa.destroy(ch);
    }

    /// Makes the list again from Git's status, keeping the file chosen.
    pub fn rebuild(ch: *Changes, changes: []const git.Change, generation: u64) void {
        if (generation == ch.seen) return;
        ch.seen = generation;
        const g = ch.gpa;
        var keep: ?[]u8 = null;
        defer if (keep) |k| g.free(k);
        var keep_staged = false;
        if (ch.list.current()) |e| {
            keep = g.dupe(u8, e.path) catch null;
            keep_staged = e.staged;
        }
        const hunk = ch.list.hunk;
        ch.list.clear();
        var buf: [std.fs.max_path_bytes + 8]u8 = undefined;
        var buf2: [std.fs.max_path_bytes + 8]u8 = undefined;
        for (changes) |c| if (c.status() == .conflict) {
            const new = std.fmt.bufPrint(&buf, ":{s}", .{c.path}) catch continue;
            _ = new;
            ch.list.add(c.path, null, 'C', "Merge Changes", false, std.fmt.bufPrint(&buf2, "HEAD:{s}", .{c.path}) catch continue, "@") catch {};
        };
        for (changes) |c| if (c.staged()) {
            const old_path = c.orig orelse c.path;
            const old = std.fmt.bufPrint(&buf, "HEAD:{s}", .{old_path}) catch continue;
            const new = std.fmt.bufPrint(&buf2, ":{s}", .{c.path}) catch continue;
            ch.list.add(c.path, c.orig, c.x, "Staged Changes", true, if (c.x == 'A') "" else old, if (c.x == 'D') "" else new) catch {};
        };
        for (changes) |c| if (c.unstaged()) {
            const old = std.fmt.bufPrint(&buf, ":{s}", .{c.path}) catch continue;
            ch.list.add(c.path, null, c.y, "Changes", false, old, if (c.y == 'D') "" else "@") catch {};
        };
        for (changes) |c| if (c.status() == .untracked) {
            ch.list.add(c.path, null, 'U', "Untracked", false, "", "@") catch {};
        };
        if (keep) |k| {
            for (ch.list.entries.items, 0..) |e, i| if (std.mem.eql(u8, e.path, k) and e.staged == keep_staged) {
                ch.list.selected = i;
                ch.list.hunk = hunk;
                break;
            };
        }
    }
};
