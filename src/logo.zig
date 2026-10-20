//! A project's favicon or logo, for its square on the rail (View → Project
//! Icons), as projects.go finds it: its well-known icon files, then a mygo
//! or myzig app's icon.
const std = @import("std");
const fs = @import("fs.zig");

const candidates = [_][]const u8{
    "favicon.svg",                "favicon.ico",              "favicon.png",            "favicon.webp",
    "logo.svg",                   "logo.png",                 "logo.webp",              "icon.svg",
    "icon.png",                   "icon.webp",                "public/favicon.svg",     "public/favicon.ico",
    "public/favicon.png",         "public/favicon.webp",      "public/logo.svg",        "public/logo.png",
    "public/logo.webp",           "public/icon.svg",          "public/icon.png",        "public/icon.webp",
    "public/apple-touch-icon.png", "app/favicon.ico",          "app/favicon.png",        "app/favicon.webp",
    "app/icon.svg",               "app/icon.png",             "app/icon.webp",          "app/icon.ico",
    "app/apple-icon.png",         "src/favicon.ico",          "src/favicon.svg",        "src/app/favicon.ico",
    "src/app/icon.svg",           "src/app/icon.png",         "src/app/icon.ico",       "src/app/apple-icon.png",
    "src/assets/logo.svg",        "src/assets/logo.png",      "assets/icon.svg",        "assets/icon.png",
    "assets/logo.svg",            "assets/logo.png",          "static/logo.svg",        "static/logo.png",
    // A mygo or myzig app's icon.
    "resources/icon.png",
};

pub const Logo = struct {
    bytes: []u8,
    svg: bool,
};

/// The first logo file a folder has, read (at most 2 MB), or null.
pub fn find(gpa: std.mem.Allocator, io: std.Io, root: []const u8) ?Logo {
    // mygo.json's "icon" first: the app says which it is.
    if (fs.read(gpa, io, std.fs.path.join(gpa, &.{ root, "mygo.json" }) catch return null)) |data| {
        defer gpa.free(data);
        if (iconOfConfig(gpa, data)) |rel| {
            defer gpa.free(rel);
            if (load(gpa, io, root, rel)) |l| return l;
        }
    } else |_| {}
    for (candidates) |rel| if (load(gpa, io, root, rel)) |l| return l;
    return null;
}

fn load(gpa: std.mem.Allocator, io: std.Io, root: []const u8, rel: []const u8) ?Logo {
    const p = std.fs.path.join(gpa, &.{ root, rel }) catch return null;
    defer gpa.free(p);
    const data = std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(2 << 20)) catch return null;
    return .{ .bytes = data, .svg = std.ascii.endsWithIgnoreCase(rel, ".svg") };
}

fn iconOfConfig(gpa: std.mem.Allocator, data: []const u8) ?[]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), data, .{}) catch return null;
    if (v != .object) return null;
    const icon = v.object.get("icon") orelse return null;
    if (icon != .string) return null;
    return gpa.dupe(u8, icon.string) catch null;
}
