//! Follows the folder on disk with the watch plugin, on a thread of its own:
//! files changed or the Git state changed reach the workbench on the main
//! thread, which reads them again. Heavy folders (node_modules, build output)
//! are left out; a folder too big to watch is read again as the window
//! takes the keyboard instead.
const std = @import("std");
const watch = @import("watch");
const fs = @import("fs.zig");
const jobs = @import("jobs.zig");

pub const Changes = struct {
    files: bool = false,
    git: bool = false,
};

pub const FsWatch = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    root: []u8,
    w: ?*watch.Watcher = null,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    files: std.atomic.Value(bool) = .init(false),
    git: std.atomic.Value(bool) = .init(false),
    posted: std.atomic.Value(bool) = .init(false),
    ctx: *anyopaque,
    notify: *const fn (ctx: *anyopaque) void,

    pub fn start(gpa: std.mem.Allocator, io: std.Io, root: []const u8, ctx: *anyopaque, notify: *const fn (*anyopaque) void) ?*FsWatch {
        const f = gpa.create(FsWatch) catch return null;
        f.* = .{ .gpa = gpa, .io = io, .root = gpa.dupe(u8, root) catch return null, .ctx = ctx, .notify = notify };
        // Not the default 16 MB stack, which Windows commits whole: one
        // watcher a project.
        f.thread = std.Thread.spawn(.{ .stack_size = 1 << 20 }, run, .{f}) catch {
            gpa.free(f.root);
            gpa.destroy(f);
            return null;
        };
        return f;
    }

    pub fn stop(f: *FsWatch) void {
        f.stopping.store(true, .release);
        if (f.w) |w| w.close();
        if (f.thread) |t| t.join();
        if (f.w) |w| w.deinit();
        f.w = null;
        // A delivery still queued for the main thread reads it: then it stays.
        if (f.posted.load(.acquire)) return;
        f.gpa.free(f.root);
        f.gpa.destroy(f);
    }

    /// What changed since the last call.
    pub fn take(f: *FsWatch) Changes {
        f.posted.store(false, .release);
        return .{ .files = f.files.swap(false, .acq_rel), .git = f.git.swap(false, .acq_rel) };
    }

    fn ignore(_: ?*anyopaque, path: []const u8, is_dir: bool) bool {
        if (!is_dir) return false;
        const name = std.fs.path.basenamePosix(path);
        // .git itself is watched (for commits and checkouts), not its objects.
        if (std.mem.startsWith(u8, path, ".git/")) return !std.mem.eql(u8, path, ".git/refs") and !std.mem.startsWith(u8, path, ".git/refs/");
        if (std.mem.eql(u8, name, ".git")) return false;
        return fs.heavy(name);
    }

    fn run(f: *FsWatch) void {
        const w = watch.Watcher.init(f.gpa, f.io, f.root, .{ .recursive = true, .ignore = ignore, .debounce_ms = 150 }) catch return;
        // `stop` closes and frees it; it may have looked before it was set.
        f.w = w;
        if (f.stopping.load(.acquire)) return;
        var arena: std.heap.ArenaAllocator = .init(f.gpa);
        defer arena.deinit();
        while (!f.stopping.load(.acquire)) {
            _ = arena.reset(.retain_capacity);
            const events = w.next(arena.allocator()) catch break;
            var any = false;
            for (events) |e| {
                if (std.mem.startsWith(u8, e.path, ".git/") or std.mem.eql(u8, e.path, ".git")) {
                    f.git.store(true, .release);
                } else {
                    f.files.store(true, .release);
                    f.git.store(true, .release);
                }
                any = true;
            }
            if (any and !f.posted.swap(true, .acq_rel)) {
                if (!jobs.post(f, deliver)) f.posted.store(false, .release);
            }
        }
    }

    fn deliver(ctx: ?*anyopaque) callconv(.c) void {
        const f: *FsWatch = @ptrCast(@alignCast(ctx.?));
        if (f.stopping.load(.acquire)) return;
        f.notify(f.ctx);
    }
};
