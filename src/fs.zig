//! Small file system helpers over `std.Io.Dir`, for the explorer, tabs and
//! quick open.
const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;

pub const Entry = struct {
    /// Absolute, with the platform's separators.
    path: []const u8,
    dir: bool,
};

/// Names the explorer and quick open leave out.
pub fn skipped(name: []const u8) bool {
    return std.mem.eql(u8, name, ".git");
}

/// Folders too big to walk for quick open outside a Git work tree.
pub fn heavy(name: []const u8) bool {
    const names = [_][]const u8{ ".git", "node_modules", "zig-cache", ".zig-cache", "zig-out", "build", "dist", "target", ".next", "vendor" };
    for (names) |n| if (std.mem.eql(u8, name, n)) return true;
    return false;
}

/// The entries of a folder, folders first, each sorted by name without case.
/// The paths are allocated from `gpa`, as is the slice.
pub fn list(gpa: std.mem.Allocator, io: Io, path: []const u8) ![]Entry {
    var dir = try Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var out: std.ArrayList(Entry) = .empty;
    errdefer {
        for (out.items) |e| gpa.free(e.path);
        out.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (skipped(e.name)) continue;
        const is_dir = switch (e.kind) {
            .directory => true,
            .sym_link => isDir(io, path, e.name),
            else => false,
        };
        try out.append(gpa, .{ .path = try std.fs.path.join(gpa, &.{ path, e.name }), .dir = is_dir });
    }
    std.mem.sort(Entry, out.items, {}, lessThan);
    return out.toOwnedSlice(gpa);
}

fn isDir(io: Io, parent: []const u8, name: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}{c}{s}", .{ parent, std.fs.path.sep, name }) catch return false;
    const st = Dir.cwd().statFile(io, p, .{}) catch return false;
    return st.kind == .directory;
}

fn lessThan(_: void, a: Entry, b: Entry) bool {
    if (a.dir != b.dir) return a.dir;
    return std.ascii.lessThanIgnoreCase(std.fs.path.basename(a.path), std.fs.path.basename(b.path));
}

pub fn freeList(gpa: std.mem.Allocator, entries: []const Entry) void {
    for (entries) |e| gpa.free(e.path);
    gpa.free(entries);
}

pub fn exists(io: Io, path: []const u8) bool {
    Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

pub fn isDirectory(io: Io, path: []const u8) bool {
    const st = Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .directory;
}

/// The file's modification time, or 0 when it can't be read.
pub fn mtime(io: Io, path: []const u8) i96 {
    const st = Dir.cwd().statFile(io, path, .{}) catch return 0;
    return st.mtime.nanoseconds;
}

pub fn read(gpa: std.mem.Allocator, io: Io, path: []const u8) ![]u8 {
    return Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 20));
}

pub fn write(io: Io, path: []const u8, data: []const u8) !void {
    try Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

pub fn absolute(gpa: std.mem.Allocator, io: Io, path: []const u8) ![]u8 {
    const z = try Dir.cwd().realPathFileAlloc(io, path, gpa);
    defer gpa.free(z);
    return gpa.dupe(u8, z);
}

/// Whether the first bytes of a file look binary (a NUL byte).
pub fn binary(data: []const u8) bool {
    return std.mem.indexOfScalar(u8, data[0..@min(data.len, 8000)], 0) != null;
}

/// `path` relative to `root`, with slashes, or `path` itself when outside it.
pub fn relative(root: []const u8, path: []const u8) []const u8 {
    if (path.len > root.len and std.mem.startsWith(u8, path, root) and (path[root.len] == '/' or path[root.len] == '\\'))
        return path[root.len + 1 ..];
    return path;
}

/// Every file under `root` (relative paths with slashes), leaving out heavy
/// folders, up to `max` files.
pub fn walk(gpa: std.mem.Allocator, io: Io, root: []const u8, max: usize) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer freeStrings(gpa, out.items);
    var dir = try Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var w = try dir.walkSelectively(gpa);
    defer w.deinit();
    while (try w.next(io)) |e| {
        if (out.items.len >= max) break;
        switch (e.kind) {
            .directory => if (!heavy(e.basename)) try w.enter(io, e),
            .file, .sym_link => {
                const p = try gpa.dupe(u8, e.path);
                std.mem.replaceScalar(u8, p, '\\', '/');
                try out.append(gpa, p);
            },
            else => {},
        }
    }
    return out.toOwnedSlice(gpa);
}

pub fn freeStrings(gpa: std.mem.Allocator, items: []const []const u8) void {
    for (items) |s| gpa.free(s);
    gpa.free(items);
}

test relative {
    try std.testing.expectEqualStrings("a/b.go", relative("/r", "/r/a/b.go"));
    try std.testing.expectEqualStrings("/x/a", relative("/r", "/x/a"));
}
