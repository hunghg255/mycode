//! Source control's changes as a tree, as the Go app has it: folders
//! before files, a folder with one folder in it and no files merged into
//! one row ("src/ui"), each folder covering the files under it.
const std = @import("std");

pub const Node = struct {
    /// A folder's name (several, merged, with slashes) or a file's.
    name: []const u8,
    /// A folder's path (with slashes), or a file's.
    path: []const u8,
    depth: usize,
    folder: bool,
    /// The files under a folder: indices into the sorted paths.
    lo: usize,
    hi: usize,
};

/// The rows of a tree of `paths` (sorted), with `closed` folders' rows
/// left out; in `a`.
pub fn build(a: std.mem.Allocator, paths: []const []const u8, closed: *const std.StringHashMapUnmanaged(void)) []const Node {
    var out: std.ArrayList(Node) = .empty;
    walk(a, &out, paths, 0, paths.len, 0, 0, closed);
    return out.items;
}

/// The rows of paths[lo..hi], which share their first `skip` bytes.
fn walk(a: std.mem.Allocator, out: *std.ArrayList(Node), paths: []const []const u8, lo: usize, hi: usize, skip: usize, depth: usize, closed: *const std.StringHashMapUnmanaged(void)) void {
    // Folders first.
    var i = lo;
    while (i < hi) {
        const rest = paths[i][skip..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse {
            i += 1;
            continue;
        };
        const first = rest[0 .. slash + 1];
        var j = i + 1;
        while (j < hi and std.mem.startsWith(u8, paths[j][skip..], first)) j += 1;
        // A folder whose files are all in one folder takes its name too.
        var end = skip + slash + 1;
        while (true) {
            const next = std.mem.indexOfScalarPos(u8, paths[i], end, '/') orelse break;
            const pre = paths[i][0 .. next + 1];
            var all = true;
            for (paths[i..j]) |p| if (!std.mem.startsWith(u8, p, pre)) {
                all = false;
            };
            if (!all) break;
            end = next + 1;
        }
        const path = paths[i][0 .. end - 1];
        out.append(a, .{ .name = paths[i][skip .. end - 1], .path = path, .depth = depth, .folder = true, .lo = i, .hi = j }) catch return;
        if (!closed.contains(path)) walk(a, out, paths, i, j, end, depth + 1, closed);
        i = j;
    }
    // Then the files here.
    for (lo..hi) |k| {
        if (std.mem.indexOfScalar(u8, paths[k][skip..], '/') != null) continue;
        out.append(a, .{ .name = paths[k][skip..], .path = paths[k], .depth = depth, .folder = false, .lo = k, .hi = k + 1 }) catch return;
    }
}

test build {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const paths = [_][]const u8{ "README.md", "src/ui/a.zig", "src/ui/b.zig", "zig/x.zig", "zig/y/z.zig" };
    var sorted = paths;
    std.mem.sort([]const u8, &sorted, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    var closed: std.StringHashMapUnmanaged(void) = .empty;
    const nodes = build(arena.allocator(), &sorted, &closed);
    // src/ui merged; zig with its folder y, then its file x.zig; README last.
    try std.testing.expectEqualStrings("src/ui", nodes[0].name);
    try std.testing.expect(nodes[0].folder and nodes[0].hi - nodes[0].lo == 2);
    try std.testing.expectEqualStrings("a.zig", nodes[1].name);
    try std.testing.expectEqualStrings("zig", nodes[3].name);
    try std.testing.expectEqualStrings("y", nodes[4].name);
    try std.testing.expectEqual(@as(usize, 1), nodes[4].depth);
    try std.testing.expectEqualStrings("x.zig", nodes[6].name);
    try std.testing.expectEqualStrings("README.md", nodes[7].name);
}
