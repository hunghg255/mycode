//! Merge conflicts: the blocks of conflict markers Git writes (with diff3's
//! common ancestor too), and resolving one by taking a side.
const std = @import("std");

pub const Block = struct {
    /// Lines (from 0) of `<<<<<<<`, `|||||||` (diff3), `=======` and `>>>>>>>`.
    start: usize,
    base: ?usize = null,
    sep: usize,
    end: usize,
};

pub const Side = enum { current, incoming, both };

pub fn find(gpa: std.mem.Allocator, text: []const u8) ![]Block {
    var out: std.ArrayList(Block) = .empty;
    errdefer out.deinit(gpa);
    var it = std.mem.splitScalar(u8, text, '\n');
    var line: usize = 0;
    var open: ?Block = null;
    var have_sep = false;
    while (it.next()) |l| : (line += 1) {
        if (std.mem.startsWith(u8, l, "<<<<<<<")) {
            open = .{ .start = line, .sep = 0, .end = 0 };
            have_sep = false;
        } else if (open != null and !have_sep and std.mem.startsWith(u8, l, "|||||||")) {
            open.?.base = line;
        } else if (open != null and !have_sep and std.mem.startsWith(u8, l, "=======")) {
            open.?.sep = line;
            have_sep = true;
        } else if (open != null and have_sep and std.mem.startsWith(u8, l, ">>>>>>>")) {
            open.?.end = line;
            try out.append(gpa, open.?);
            open = null;
        }
    }
    return out.toOwnedSlice(gpa);
}

/// The text that replaces a block's lines when `side` is taken, with a
/// newline after each line.
pub fn resolved(gpa: std.mem.Allocator, lines: []const []const u8, b: Block, side: Side) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const cur_end = b.base orelse b.sep;
    if (side != .incoming) for (lines[b.start + 1 .. cur_end]) |l| {
        try out.appendSlice(gpa, l);
        try out.append(gpa, '\n');
    };
    if (side != .current) for (lines[b.sep + 1 .. b.end]) |l| {
        try out.appendSlice(gpa, l);
        try out.append(gpa, '\n');
    };
    return out.toOwnedSlice(gpa);
}

/// The block holding `line`, or the next after it.
pub fn at(blocks: []const Block, line: usize) ?usize {
    for (blocks, 0..) |b, i| if (line >= b.start and line <= b.end) return i;
    return null;
}

test find {
    const gpa = std.testing.allocator;
    const t = "a\n<<<<<<< HEAD\nmine\n=======\ntheirs\n>>>>>>> b\nz\n";
    const bs = try find(gpa, t);
    defer gpa.free(bs);
    try std.testing.expectEqual(@as(usize, 1), bs.len);
    try std.testing.expectEqual(@as(usize, 3), bs[0].sep);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, t, '\n');
    while (it.next()) |l| try lines.append(gpa, l);
    const r = try resolved(gpa, lines.items, bs[0], .both);
    defer gpa.free(r);
    try std.testing.expectEqualStrings("mine\ntheirs\n", r);
}
