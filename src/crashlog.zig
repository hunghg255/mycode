//! What ended MyCode if it crashed, as crash.go keeps it: a release has no
//! console, so its error output (panics, a fault's stack) goes to
//! crash-zig.log in the data folder. A log left by the last run moves to
//! crashes/ as it starts, and the last 10 are kept.
const std = @import("std");
const builtin = @import("builtin");
const fs = @import("fs.zig");

extern "kernel32" fn GetStdHandle(which: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn SetStdHandle(which: u32, handle: ?*anyopaque) callconv(.winapi) i32;
const std_error_handle: u32 = @bitCast(@as(i32, -12));

pub fn start(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) void {
    if (builtin.os.tag != .windows) return;
    // Started from a terminal, the output stays there; from Explorer or the
    // Start menu a GUI app has none.
    const h = GetStdHandle(std_error_handle);
    if (h != null and @intFromPtr(h) != std.math.maxInt(usize)) return;
    const path = std.fs.path.join(gpa, &.{ dir, "crash-zig.log" }) catch return;
    defer gpa.free(path);
    keepLast(gpa, io, dir, path);
    const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch return;
    _ = SetStdHandle(std_error_handle, file.handle);
}

/// The last run's log, when it has something, goes to crashes/.
fn keepLast(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, path: []const u8) void {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return;
    if (st.size == 0) return;
    const crashes = std.fs.path.join(gpa, &.{ dir, "crashes" }) catch return;
    defer gpa.free(crashes);
    std.Io.Dir.cwd().createDirPath(io, crashes) catch return;
    const now = std.Io.Clock.real.now(io).toSeconds();
    var buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "zig-{d}.log", .{now}) catch return;
    const to = std.fs.path.join(gpa, &.{ crashes, name }) catch return;
    defer gpa.free(to);
    std.Io.Dir.cwd().rename(path, std.Io.Dir.cwd(), to, io) catch return;
    // At most 10.
    const list = fs.list(gpa, io, crashes) catch return;
    defer fs.freeList(gpa, list);
    var zig_logs: std.ArrayList([]const u8) = .empty;
    defer zig_logs.deinit(gpa);
    for (list) |e| if (std.mem.startsWith(u8, std.fs.path.basename(e.path), "zig-")) zig_logs.append(gpa, e.path) catch {};
    if (zig_logs.items.len <= 10) return;
    for (zig_logs.items[0 .. zig_logs.items.len - 10]) |old| std.Io.Dir.cwd().deleteFile(io, old) catch {};
}
