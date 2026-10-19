//! Git commands that take a while (fetch, pull, push, checkout, stash),
//! run off the main thread, one at a time, while a bar moves under the
//! title; the workbench hears how each went.
const std = @import("std");
const myzig = @import("myzig");
const git = @import("git.zig");
const jobs = @import("jobs.zig");

pub const Kind = enum {
    fetch,
    pull,
    pull_rebase,
    pull_merge,
    push,
    publish,
    force_push,
    sync,
    checkout,
    create_branch,
    rename_branch,
    delete_branch,
    delete_remote_branch,
    tag,
    stash,
    stash_apply,
    stash_pop,
    stash_drop,
    undo_commit,
    commit,
    commit_amend,
    other,
};

pub const Done = struct {
    kind: Kind,
    ok: bool,
    /// Git's words, for a toast: its error, or what it said.
    message: []const u8,
    /// What it acted on: a branch, a stash.
    subject: []const u8,
};

const Job = struct {
    runner: *Runner,
    gpa: std.mem.Allocator,
    /// The project the runner is in: gone, the job only frees itself.
    owner: *anyopaque,
    io: std.Io,
    kind: Kind,
    top: []u8,
    argv: [][]u8,
    subject: []u8,
    ok: bool = false,
    out: []u8 = &.{},

    fn free(j: *Job, gpa: std.mem.Allocator) void {
        for (j.argv) |a| gpa.free(a);
        gpa.free(j.argv);
        gpa.free(j.top);
        gpa.free(j.subject);
        gpa.free(j.out);
        gpa.destroy(j);
    }

    fn work(j: *Job) void {
        const gpa = j.gpa;
        // A sync is a pull, then a push.
        const steps: []const []const []const u8 = if (j.kind == .sync)
            &.{ &.{ "pull", "--ff-only" }, &.{"push"} }
        else
            &.{@ptrCast(j.argv)};
        for (steps) |args| {
            const r = git.run(gpa, j.io, j.top, args) catch |err| {
                j.out = std.fmt.allocPrint(gpa, "{s}", .{@errorName(err)}) catch &.{};
                j.ok = false;
                return;
            };
            defer gpa.free(r.stdout);
            defer gpa.free(r.stderr);
            j.ok = r.ok;
            gpa.free(j.out);
            const msg = std.mem.trim(u8, if (r.stderr.len > 0) r.stderr else r.stdout, " \r\n");
            j.out = gpa.dupe(u8, msg) catch &.{};
            if (!r.ok) return;
        }
    }

    fn done(j: *Job) void {
        if (!jobs.isAlive(j.owner)) return j.free(j.gpa);
        const r = j.runner;
        r.busy = false;
        if (r.on_done) |f| f(r.ctx.?, .{ .kind = j.kind, .ok = j.ok, .message = j.out, .subject = j.subject });
        j.free(r.gpa);
        if (r.window) |w| w.redraw();
    }
};

pub const Runner = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    window: ?*myzig.Window = null,
    busy: bool = false,
    ctx: ?*anyopaque = null,
    on_done: ?*const fn (ctx: *anyopaque, d: Done) void = null,

    /// Runs `git args...` in `top` off the main thread; false while busy.
    pub fn run(r: *Runner, kind: Kind, top: []const u8, args: []const []const u8, subject: []const u8) bool {
        if (r.busy) return false;
        const g = r.gpa;
        const j = g.create(Job) catch return false;
        j.* = .{ .runner = r, .gpa = g, .io = r.io, .owner = r.ctx.?, .kind = kind, .top = g.dupe(u8, top) catch return false, .argv = g.alloc([]u8, args.len) catch return false, .subject = g.dupe(u8, subject) catch return false };
        for (args, 0..) |a, i| j.argv[i] = g.dupe(u8, a) catch return false;
        r.busy = true;
        jobs.spawn(Job, j, Job.work, Job.done) catch {
            r.busy = false;
            j.free(g);
            return false;
        };
        return true;
    }
};
