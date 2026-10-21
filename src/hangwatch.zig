//! What the main thread was doing when MyCode stopped answering, for
//! crash-zig.log: a thread of its own pings the main thread's queue every two
//! seconds, and when a ping waits five, it stops the main thread a moment,
//! reads where it is, lets it go on, and writes that stack. Once a stall.
//! A crash has its own stack; a hang leaves none without this.
const std = @import("std");
const builtin = @import("builtin");
const mainthread = @import("mainthread");

const windows = std.os.windows;
const HANDLE = windows.HANDLE;

extern "kernel32" fn OpenThread(access: u32, inherit: i32, id: u32) callconv(.winapi) ?HANDLE;
extern "kernel32" fn SuspendThread(h: HANDLE) callconv(.winapi) u32;
extern "kernel32" fn ResumeThread(h: HANDLE) callconv(.winapi) u32;
extern "kernel32" fn GetThreadContext(h: HANDLE, ctx: *windows.CONTEXT) callconv(.winapi) i32;
extern "kernel32" fn RtlLookupFunctionEntry(pc: u64, image_base: *u64, history: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn RtlVirtualUnwind(kind: u32, image_base: u64, pc: u64, entry: *anyopaque, ctx: *windows.CONTEXT, data: *?*anyopaque, frame: *u64, pointers: ?*anyopaque) callconv(.winapi) ?*anyopaque;

const thread_suspend_resume: u32 = 0x0002;
const thread_get_context: u32 = 0x0008;
const thread_query_information: u32 = 0x0040;
/// CONTEXT_AMD64 | CONTROL | INTEGER | FLOATING_POINT.
const context_full: u32 = 0x10000B;

/// Pings sent and answered: the main thread answers the last it saw.
var sent = std.atomic.Value(u64).init(0);
var answered = std.atomic.Value(u64).init(0);

pub fn start(io: std.Io) void {
    if (builtin.os.tag != .windows or builtin.cpu.arch != .x86_64) return;
    const main = OpenThread(thread_suspend_resume | thread_get_context | thread_query_information, 0, windows.GetCurrentThreadId()) orelse return;
    const t = std.Thread.spawn(.{ .stack_size = 1 << 20 }, watch, .{ io, main }) catch return;
    t.detach();
}

fn pong(ctx: ?*anyopaque) callconv(.c) void {
    answered.store(@intFromPtr(ctx), .release);
}

fn watch(io: std.Io, main: HANDLE) void {
    var since: u64 = 0;
    var reported = false;
    while (true) {
        io.sleep(.fromSeconds(1), .awake) catch {};
        const s = sent.load(.acquire);
        if (answered.load(.acquire) >= s) {
            // Answered: the next ping, and a stall may be reported again.
            reported = false;
            since = 0;
            const n = s + 1;
            sent.store(n, .release);
            if (!mainthread.post(@ptrFromInt(n), pong)) return;
            continue;
        }
        since += 1;
        if (since >= 5 and !reported) {
            reported = true;
            report(main, since);
        }
    }
}

fn report(main: HANDLE, seconds: u64) void {
    var addrs: [64]usize = undefined;
    var n: usize = 0;
    // Stopped only to read its registers and walk its stack: nothing
    // allocates meanwhile (it may hold the allocator's lock).
    if (SuspendThread(main) == std.math.maxInt(u32)) return;
    var ctx: windows.CONTEXT = std.mem.zeroes(windows.CONTEXT);
    ctx.ContextFlags = context_full;
    if (GetThreadContext(main, &ctx) != 0) {
        // x64's unwinding, as debuggers do: each function's unwind data, or
        // a leaf's return address on top of the stack.
        while (n < addrs.len and ctx.Rip != 0) {
            addrs[n] = ctx.Rip;
            n += 1;
            var base: u64 = 0;
            if (RtlLookupFunctionEntry(ctx.Rip, &base, null)) |entry| {
                var data: ?*anyopaque = null;
                var frame: u64 = 0;
                _ = RtlVirtualUnwind(0, base, ctx.Rip, entry, &ctx, &data, &frame, null);
            } else {
                ctx.Rip = @as(*const u64, @ptrFromInt(ctx.Rsp)).*;
                ctx.Rsp += 8;
            }
        }
    }
    _ = ResumeThread(main);
    std.debug.print("MyCode stopped answering for {d} s; the main thread was at:\n", .{seconds});
    // Return addresses, as a trace prints them: the first is where it is.
    if (n > 0) addrs[0] += 1;
    std.debug.dumpStackTrace(&.{ .return_addresses = addrs[0..n], .skipped = .none });
}
