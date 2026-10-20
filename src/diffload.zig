//! Reading a diff list's files off the main thread: `git show` takes tens
//! of milliseconds a side on Windows, and the Changes tab reads every file
//! again as Git's status changes. What only the main thread has (an open
//! file's text) is taken as the read is asked for; the rest is read on a
//! thread, and the entry, found again by its id, takes the texts after.
const std = @import("std");
const jobs = @import("jobs.zig");
const difflist = @import("difflist.zig");
const DiffList = difflist.DiffList;
const Entry = difflist.Entry;
const Reader = difflist.Reader;

/// Reads at most this many files at once, a list.
const max_pending = 4;

const Job = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    dl: *DiffList,
    id: u64,
    side: *const fn (gpa: std.mem.Allocator, io: std.Io, top: []const u8, spec: []const u8, path: []const u8) []u8,
    top: []u8,
    path: []u8,
    old_spec: []u8,
    new_spec: []u8,
    old: ?[]u8,
    new: ?[]u8,
    wake: ?*const fn (ctx: *anyopaque) void,
    wake_ctx: *anyopaque,

    fn work(j: *Job) void {
        if (j.old == null) j.old = j.side(j.gpa, j.io, j.top, j.old_spec, j.path);
        if (j.new == null) j.new = j.side(j.gpa, j.io, j.top, j.new_spec, j.path);
    }

    fn done(j: *Job) void {
        defer j.free();
        // The list closed while it read.
        if (!jobs.isAlive(j.dl)) return;
        for (j.dl.entries.items) |*e| if (e.id == j.id) {
            e.pending = false;
            e.stale = false;
            j.dl.apply(e, j.old.?, j.new.?);
            j.old = null;
            j.new = null;
            break;
        };
        if (j.wake) |w| w(j.wake_ctx);
    }

    fn free(j: *Job) void {
        const g = j.gpa;
        if (j.old) |o| g.free(o);
        if (j.new) |n| g.free(n);
        g.free(j.top);
        g.free(j.path);
        g.free(j.old_spec);
        g.free(j.new_spec);
        g.destroy(j);
    }
};

/// Reads an entry not read yet, or read before Git's status changed, in
/// the background; at once where the reader has no background side.
pub fn request(dl: *DiffList, e: *Entry, r: Reader) void {
    if (e.pending) return;
    const side = r.side orelse {
        dl.load(e, r);
        e.stale = false;
        return;
    };
    var pending: usize = 0;
    for (dl.entries.items) |x| pending += @intFromBool(x.pending);
    if (pending >= max_pending) return;
    if (!dl.registered) {
        jobs.live(dl, dl.gpa);
        dl.registered = true;
    }
    const g = dl.gpa;
    const j = g.create(Job) catch return;
    j.* = .{
        .gpa = g,
        .io = r.io,
        .dl = dl,
        .id = e.id,
        .side = side,
        .top = g.dupe(u8, r.top) catch return g.destroy(j),
        .path = g.dupe(u8, e.path) catch return g.destroy(j),
        .old_spec = g.dupe(u8, e.old_spec) catch return g.destroy(j),
        .new_spec = g.dupe(u8, e.new_spec) catch return g.destroy(j),
        // An open file's text, as it is now.
        .old = if (r.capture) |f| f(r.ctx, g, e.old_spec, e.path) else null,
        .new = if (r.capture) |f| f(r.ctx, g, e.new_spec, e.path) else null,
        .wake = r.wake,
        .wake_ctx = r.ctx,
    };
    e.pending = true;
    jobs.spawn(Job, j, Job.work, Job.done) catch {
        e.pending = false;
        j.free();
        dl.load(e, r);
        e.stale = false;
    };
}
