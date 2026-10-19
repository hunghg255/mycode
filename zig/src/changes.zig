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
    /// The open files' versions it last followed.
    versions: u64 = 0,

    pub fn create(gpa: std.mem.Allocator) !*Changes {
        const ch = try gpa.create(Changes);
        ch.* = .{ .gpa = gpa, .list = .{ .gpa = gpa } };
        return ch;
    }

    pub fn destroy(ch: *Changes) void {
        ch.list.deinit();
        ch.gpa.destroy(ch);
    }

    /// Makes the list again from Git's status, keeping what was folded and
    /// the file in view.
    pub fn rebuild(ch: *Changes, changes: []const git.Change, generation: u64) void {
        if (generation == ch.seen) return;
        ch.seen = generation;
        const g = ch.gpa;
        // What to keep, by group and path.
        var folded: std.StringHashMapUnmanaged(void) = .empty;
        defer {
            var it = folded.keyIterator();
            while (it.next()) |k| g.free(k.*);
            folded.deinit(g);
        }
        for (ch.list.entries.items) |e| if (e.folded) {
            const k = std.fmt.allocPrint(g, "{s}\x00{s}", .{ e.group, e.path }) catch continue;
            folded.put(g, k, {}) catch g.free(k);
        };
        var keep: ?[]u8 = null;
        defer if (keep) |k| g.free(k);
        if (ch.list.current()) |e| keep = g.dupe(u8, e.path) catch null;

        ch.list.clear();
        var buf: [std.fs.max_path_bytes + 8]u8 = undefined;
        var buf2: [std.fs.max_path_bytes + 8]u8 = undefined;
        for (changes) |c| if (c.status() == .conflict) {
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
        for (ch.list.entries.items, 0..) |*e, i| {
            var kb: [std.fs.max_path_bytes + 40]u8 = undefined;
            const k = std.fmt.bufPrint(&kb, "{s}\x00{s}", .{ e.group, e.path }) catch continue;
            if (folded.contains(k)) e.folded = true;
            if (keep) |kp| if (std.mem.eql(u8, kp, e.path)) {
                ch.list.selected_entry = i;
            };
        }
    }
};
