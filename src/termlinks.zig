//! What a link clicked in a terminal names, as the Go app's `termlinks.go`:
//! a path (from a file URL too), with the `:line` or `:line:col` compilers
//! and agents print after it, Git Bash's `/c/...` and WSL's `/mnt/c/...`
//! as Windows names them, `~/` from the home folder, and the punctuation
//! that ends a sentence around it left out.
const std = @import("std");
const builtin = @import("builtin");

pub const Target = struct { path: []const u8, line: usize = 0, col: usize = 0 };

/// The path `link` names, in `buf`, with its line and column (1-based, 0
/// for none); null for a URL that is not a file's.
pub fn target(link: []const u8, is_path: bool, home: []const u8, buf: []u8) ?Target {
    var p = link;
    if (std.mem.startsWith(u8, p, "file://")) {
        const rest = p["file://".len..];
        p = if (std.mem.indexOfScalar(u8, rest, '/')) |s| rest[s..] else return null;
        // /C:/... on Windows.
        if (p.len >= 3 and p[2] == ':') p = p[1..];
    } else if (!is_path or std.mem.indexOf(u8, p, "://") != null or std.mem.startsWith(u8, p, "mailto:")) return null;
    p = std.mem.trimEnd(u8, p, ".,;");
    var t: Target = .{ .path = p };
    // :line or :line:col at the end.
    var nums: [2]usize = .{ 0, 0 };
    var n: usize = 0;
    while (n < 2) {
        const colon = std.mem.lastIndexOfScalar(u8, t.path, ':') orelse break;
        const v = std.fmt.parseInt(usize, t.path[colon + 1 ..], 10) catch break;
        // "C:" of a drive is not a line.
        if (colon == 1) break;
        nums[n] = v;
        n += 1;
        t.path = t.path[0..colon];
    }
    if (n == 2) {
        t.line = nums[1];
        t.col = nums[0];
    } else if (n == 1) t.line = nums[0];
    t.path = hostPath(t.path, buf[0..buf.len / 2]);
    if (std.mem.startsWith(u8, t.path, "~/") or std.mem.startsWith(u8, t.path, "~\\")) {
        if (home.len == 0) return null;
        t.path = std.fmt.bufPrint(buf[buf.len / 2 ..], "{s}{c}{s}", .{ home, std.fs.path.sep, t.path[2..] }) catch return null;
    }
    return t;
}

/// A path as this machine names it: on Windows, `/c/x` and `/mnt/c/x` are `C:/x`.
fn hostPath(p: []const u8, buf: []u8) []const u8 {
    if (builtin.os.tag != .windows) return p;
    const rest = if (std.mem.startsWith(u8, p, "/mnt/")) p[4..] else p;
    if (rest.len >= 2 and rest[0] == '/' and std.ascii.isAlphabetic(rest[1]) and (rest.len == 2 or rest[2] == '/')) {
        return std.fmt.bufPrint(buf, "{c}:{s}", .{ std.ascii.toUpper(rest[1]), rest[2..] }) catch p;
    }
    return p;
}

test target {
    var buf: [512]u8 = undefined;
    const a = target("src/main.zig:12:5", true, "", &buf).?;
    try std.testing.expectEqualStrings("src/main.zig", a.path);
    try std.testing.expectEqual(@as(usize, 12), a.line);
    try std.testing.expectEqual(@as(usize, 5), a.col);
    const b = target("a.go:7.", true, "", &buf).?;
    try std.testing.expectEqual(@as(usize, 7), b.line);
    try std.testing.expect(target("https://x.dev", false, "", &buf) == null);
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("C:/x/y.zig", target("/mnt/c/x/y.zig", true, "", &buf).?.path);
        try std.testing.expectEqualStrings("D:/p", target("/d/p", true, "", &buf).?.path);
        try std.testing.expectEqualStrings("C:/a.txt", target("file:///C:/a.txt", false, "", &buf).?.path);
        try std.testing.expectEqualStrings("C:\\x", target("C:\\x:3", true, "", &buf).?.path);
    }
}
