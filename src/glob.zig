//! Globs as VS Code's files.exclude and search's include and exclude take
//! them: `*` and `?` within a name, `**` any folders, `{a,b}` either. A
//! pattern without a slash matches a name anywhere; one with a slash matches
//! from the folder's top. A folder that matches takes the files in it.
const std = @import("std");

/// Whether `path` (relative, with slashes) or a folder above it matches `pattern`.
pub fn matches(pattern_in: []const u8, path: []const u8) bool {
    var pattern = std.mem.trim(u8, pattern_in, " ");
    if (pattern.len == 0) return false;
    if (std.mem.startsWith(u8, pattern, "./")) pattern = pattern[2..];
    pattern = std.mem.trimEnd(u8, pattern, "/");
    const anchored = std.mem.indexOfScalar(u8, pattern, '/') != null;
    // The path and each folder above it.
    var end: usize = path.len;
    while (true) {
        const sub = path[0..end];
        if (anchored) {
            if (match(pattern, sub)) return true;
        } else {
            // Any trailing run of names, as `**/pattern`.
            var start: usize = 0;
            while (true) {
                if (match(pattern, sub[start..])) return true;
                const slash = std.mem.indexOfScalarPos(u8, sub, start, '/') orelse break;
                start = slash + 1;
            }
        }
        end = std.mem.lastIndexOfScalar(u8, path[0..end], '/') orelse break;
    }
    return false;
}

/// Whether any of the comma-separated patterns match.
pub fn matchesAny(patterns: []const u8, path: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, patterns, ',');
    while (it.next()) |p| if (matches(p, path)) return true;
    return false;
}

/// Matches a whole string against a glob.
pub fn match(p: []const u8, s: []const u8) bool {
    // Braces: try each alternative.
    if (std.mem.indexOfScalar(u8, p, '{')) |open| if (std.mem.indexOfScalarPos(u8, p, open, '}')) |close| {
        var buf: [512]u8 = undefined;
        var it = std.mem.splitScalar(u8, p[open + 1 .. close], ',');
        while (it.next()) |alt| {
            const np = std.fmt.bufPrint(&buf, "{s}{s}{s}", .{ p[0..open], alt, p[close + 1 ..] }) catch return false;
            if (match(np, s)) return true;
        }
        return false;
    };
    return matchAt(p, s);
}

fn matchAt(p: []const u8, s: []const u8) bool {
    if (p.len == 0) return s.len == 0;
    if (std.mem.startsWith(u8, p, "**")) {
        var rest = p[2..];
        if (std.mem.startsWith(u8, rest, "/")) rest = rest[1..];
        if (rest.len == 0) return true;
        var i: usize = 0;
        while (i <= s.len) : (i += 1) {
            if ((i == 0 or s[i - 1] == '/') and matchAt(rest, s[i..])) return true;
        }
        return false;
    }
    switch (p[0]) {
        '*' => {
            var i: usize = 0;
            while (i <= s.len) : (i += 1) {
                if (matchAt(p[1..], s[i..])) return true;
                if (i < s.len and s[i] == '/') break;
            }
            return false;
        },
        '?' => return s.len > 0 and s[0] != '/' and matchAt(p[1..], s[1..]),
        else => return s.len > 0 and (p[0] == s[0] or (std.ascii.toLower(p[0]) == std.ascii.toLower(s[0]) and @import("builtin").os.tag == .windows)) and matchAt(p[1..], s[1..]),
    }
}

test matches {
    try std.testing.expect(matches("*.log", "a/b/x.log"));
    try std.testing.expect(matches("node_modules", "web/node_modules/x/y.js"));
    try std.testing.expect(matches("**/dist", "a/dist/b.js"));
    try std.testing.expect(matches("build/**", "build/x/y"));
    try std.testing.expect(!matches("build/**", "src/build/x"));
    try std.testing.expect(matches("*.{ts,tsx}", "src/a.tsx"));
    try std.testing.expect(!matches("*.go", "a/b.zig"));
    try std.testing.expect(matchesAny("*.go, web/**", "web/a.js"));
}
