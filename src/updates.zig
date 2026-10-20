//! Updates, as Go MyCode has them: release builds look at GitHub's latest
//! release once a day, ten seconds after they start, and Help → Check for
//! Updates… looks at once. A box shows the release notes and offers to
//! install it (the installer runs, MyCode quits), skip that version or wait.
//! What the user chose is in updater.json; development builds never look.
const std = @import("std");
const builtin = @import("builtin");
const myzig = @import("myzig");
const ui = myzig.ui;
const build_options = @import("build_options");
const fs = @import("fs.zig");
const jobs = @import("jobs.zig");

pub const version = build_options.version;
const repo = "hunghg255/mycode";
const day: i64 = 24 * 60 * 60;

pub const Prefs = struct {
    auto: bool = true,
    skipped: []const u8 = "",
    last_check: i64 = 0,
};

pub const Release = struct {
    tag: []u8,
    notes: []u8,
    url: []u8,
    /// The installer's download, when the release has one.
    setup: ?[]u8 = null,
};

pub const Updates = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []u8,
    prefs: Prefs = .{},
    arena: std.heap.ArenaAllocator,
    window: ?*myzig.Window = null,
    dialog: ui.OverlayState = .{},
    busy: bool = false,
    /// The release offered, and whether the user asked (then "up to date" shows too).
    found: ?Release = null,
    asked: bool = false,
    message: ?[]const u8 = null,
    md: ?ui.Markdown = null,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) Updates {
        var u: Updates = .{ .gpa = gpa, .io = io, .path = std.fs.path.join(gpa, &.{ dir, "updater.json" }) catch &.{}, .arena = .init(gpa) };
        if (fs.read(gpa, io, u.path)) |data| {
            defer gpa.free(data);
            u.prefs = std.json.parseFromSliceLeaky(Prefs, u.arena.allocator(), data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch .{};
        } else |_| {}
        return u;
    }

    pub fn deinit(u: *Updates) void {
        u.freeFound();
        if (u.md) |*m| m.deinit();
        u.arena.deinit();
        u.gpa.free(u.path);
    }

    fn freeFound(u: *Updates) void {
        const r = u.found orelse return;
        u.gpa.free(r.tag);
        u.gpa.free(r.notes);
        u.gpa.free(r.url);
        if (r.setup) |s| u.gpa.free(s);
        u.found = null;
    }

    fn save(u: *Updates) void {
        const out = std.fmt.allocPrint(u.gpa, "{f}\n", .{std.json.fmt(u.prefs, .{ .whitespace = .indent_2 })}) catch return;
        defer u.gpa.free(out);
        fs.write(u.io, u.path, out) catch {};
    }

    /// Whether this build looks by itself: a release, with checks on.
    pub fn automatic(u: *const Updates) bool {
        return builtin.mode != .debug and u.prefs.auto;
    }

    /// Looks once a day, ten seconds after the start (from App.after).
    pub fn startTimer(u: *Updates) void {
        if (!u.automatic()) return;
        const now = std.Io.Clock.real.now(u.io).toSeconds();
        if (now - u.prefs.last_check < day) return;
        myzig.App.after(10_000, u, struct {
            fn f(ctx: ?*anyopaque) callconv(.c) void {
                const self: *Updates = @ptrCast(@alignCast(ctx.?));
                self.check(false);
            }
        }.f);
    }

    /// Looks for a newer release, off the main thread.
    pub fn check(u: *Updates, asked: bool) void {
        if (u.busy) return;
        u.busy = true;
        u.asked = asked;
        const j = u.gpa.create(Job) catch return;
        j.* = .{ .u = u };
        jobs.spawn(Job, j, Job.work, Job.done) catch {
            u.busy = false;
            u.gpa.destroy(j);
        };
    }

    const Job = struct {
        u: *Updates,
        out: []u8 = &.{},
        ok: bool = false,

        fn work(j: *Job) void {
            const r = std.process.run(j.u.gpa, j.u.io, .{
                .argv = &.{ "curl.exe", "-sSL", "--max-time", "20", "-H", "Accept: application/vnd.github+json", "-H", "User-Agent: MyCode", "https://api.github.com/repos/" ++ repo ++ "/releases/latest" },
                .stdout_limit = .limited(4 << 20),
            }) catch return;
            j.u.gpa.free(r.stderr);
            j.ok = r.term.success();
            j.out = r.stdout;
        }

        fn done(j: *Job) void {
            const u = j.u;
            defer {
                u.gpa.free(j.out);
                u.gpa.destroy(j);
            }
            u.busy = false;
            u.prefs.last_check = std.Io.Clock.real.now(u.io).toSeconds();
            u.save();
            if (!j.ok) return u.say("Couldn't reach GitHub to look for updates.");
            u.take(j.out);
            if (u.window) |w| w.redraw();
        }
    };

    fn say(u: *Updates, msg: []const u8) void {
        if (!u.asked) return;
        u.message = msg;
        u.dialog.show();
        if (u.window) |w| w.redraw();
    }

    /// The latest release from GitHub's answer: offered when newer.
    fn take(u: *Updates, json: []const u8) void {
        var arena: std.heap.ArenaAllocator = .init(u.gpa);
        defer arena.deinit();
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{}) catch return u.say("GitHub's answer didn't read.");
        if (v != .object) return u.say("No release was found.");
        const tag_v = v.object.get("tag_name") orelse return u.say("No release was found.");
        if (tag_v != .string) return;
        const tag = std.mem.trimStart(u8, tag_v.string, "v");
        if (!newer(tag, version)) return u.say("MyCode is up to date.");
        if (!u.asked and std.mem.eql(u8, tag, u.prefs.skipped)) return;
        u.freeFound();
        var setup: ?[]u8 = null;
        if (v.object.get("assets")) |assets| if (assets == .array) for (assets.array.items) |a| {
            if (a != .object) continue;
            const name = a.object.get("name") orelse continue;
            const url = a.object.get("browser_download_url") orelse continue;
            if (name != .string or url != .string) continue;
            if (std.mem.indexOf(u8, name.string, "Setup") != null and std.mem.endsWith(u8, name.string, ".exe")) setup = u.gpa.dupe(u8, url.string) catch null;
        };
        const body = if (v.object.get("body")) |b| (if (b == .string) b.string else "") else "";
        const url = if (v.object.get("html_url")) |h| (if (h == .string) h.string else "") else "";
        u.found = .{
            .tag = u.gpa.dupe(u8, tag) catch return,
            .notes = u.gpa.dupe(u8, body) catch return,
            .url = u.gpa.dupe(u8, url) catch return,
            .setup = setup,
        };
        u.message = null;
        if (u.md) |*m| m.deinit();
        u.md = ui.Markdown.init(u.gpa);
        u.dialog.show();
    }

    /// The box; true when MyCode should quit (the installer runs).
    pub fn view(u: *Updates, c: *ui.Context) bool {
        const d = ui.dialog(c, &u.dialog, .{ .width = .{ .px = 560 } }) orelse return false;
        defer d.end();
        const t = c.theme;
        var quit = false;
        if (u.found) |r| {
            ui.text(c, c.print("MyCode {s} is available", .{r.tag}), .{ .size = 16, .weight = .bold });
            ui.text(c, c.print("You have {s}.", .{version}), .{ .size = 12, .color = t.muted });
            const sc = ui.div(c).column().wFull().h(260).scrollY().bg(t.surface).rounded(6).p(10);
            _ = ui.markdown(c, r.notes, .{ .state = if (u.md) |*m| m else null });
            sc.end();
            ui.row(c, .{ .gap = 8, .justify = .end, .width = .fill });
            defer ui.end(c);
            if (ui.button(c, "Skip This Version", .{}).clicked) {
                u.prefs.skipped = u.arena.allocator().dupe(u8, r.tag) catch "";
                u.save();
                u.dialog.close();
            }
            if (ui.button(c, "Remind Me Later", .{}).clicked) u.dialog.close();
            if (ui.button(c, if (r.setup != null) "Install" else "Open the Release", .{ .variant = .primary }).clicked) {
                if (r.setup) |url| {
                    quit = u.install(url);
                } else _ = myzig.shell.openUrl(r.url);
                u.dialog.close();
            }
        } else {
            ui.text(c, u.message orelse "Looking for updates…", .{ .size = 14 });
            ui.row(c, .{ .gap = 8, .justify = .end, .width = .fill });
            defer ui.end(c);
            if (ui.button(c, "OK", .{ .variant = .primary }).clicked) u.dialog.close();
        }
        return quit;
    }

    /// Downloads the installer and starts it; MyCode then quits, for the
    /// installer to replace it (its finish page starts it again).
    fn install(u: *Updates, url: []const u8) bool {
        const temp = myzig.appPath(u.gpa, .temp, "MyCode") catch return false;
        defer u.gpa.free(temp);
        const file = std.fs.path.join(u.gpa, &.{ temp, "MyCode-Setup.exe" }) catch return false;
        defer u.gpa.free(file);
        const r = std.process.run(u.gpa, u.io, .{ .argv = &.{ "curl.exe", "-sSL", "--max-time", "600", "-o", file, url } }) catch return false;
        u.gpa.free(r.stdout);
        u.gpa.free(r.stderr);
        if (!r.term.success()) return false;
        var child = std.process.spawn(u.io, .{ .argv = &.{file}, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch return false;
        _ = &child;
        return true;
    }
};

/// Whether version `a` ("1.2.3") is newer than `b`.
pub fn newer(a: []const u8, b: []const u8) bool {
    var ai = std.mem.tokenizeAny(u8, a, ".-");
    var bi = std.mem.tokenizeAny(u8, b, ".-");
    for (0..4) |_| {
        const x = std.fmt.parseInt(u32, ai.next() orelse "0", 10) catch 0;
        const y = std.fmt.parseInt(u32, bi.next() orelse "0", 10) catch 0;
        if (x != y) return x > y;
    }
    return false;
}

test newer {
    try std.testing.expect(newer("0.7.0", "0.6.0"));
    try std.testing.expect(!newer("0.6.0", "0.6.0"));
    try std.testing.expect(newer("1.0", "0.9.9"));
    try std.testing.expect(!newer("0.5.9", "0.6"));
}
