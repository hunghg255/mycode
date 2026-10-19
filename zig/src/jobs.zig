//! Work off the main thread (Git commands, searches, blame): `work` runs on
//! a thread of its own, then `done` on the main thread, through the
//! mainthread plugin's queue. Nothing polls.
const std = @import("std");
const mainthread = @import("mainthread");

/// Runs `work(job)` on a thread, then `done(job)` on the main thread. The
/// job lives until `done`, which frees it.
pub fn spawn(comptime T: type, job: *T, comptime work: fn (*T) void, comptime done: fn (*T) void) !void {
    mainthread.init() catch {};
    const W = struct {
        fn thread(j: *T) void {
            work(j);
            if (!mainthread.post(j, back)) done(j);
        }
        fn back(ctx: ?*anyopaque) callconv(.c) void {
            done(@ptrCast(@alignCast(ctx.?)));
        }
    };
    const th = try std.Thread.spawn(.{ .stack_size = 8 << 20 }, W.thread, .{job});
    th.detach();
}

/// What is still there for a job's `done` to act on: a project closed while
/// its job ran is gone (main thread only).
var alive: std.AutoHashMapUnmanaged(usize, void) = .empty;

pub fn live(p: *const anyopaque, gpa: std.mem.Allocator) void {
    alive.put(gpa, @intFromPtr(p), {}) catch {};
}

pub fn gone(p: *const anyopaque) void {
    _ = alive.remove(@intFromPtr(p));
}

pub fn deinit(gpa: std.mem.Allocator) void {
    alive.deinit(gpa);
}

pub fn isAlive(p: *const anyopaque) bool {
    return alive.contains(@intFromPtr(p));
}

/// Posts `f(ctx)` to the main thread, from any thread.
pub fn post(ctx: *anyopaque, f: mainthread.Func) bool {
    return mainthread.post(ctx, f);
}
