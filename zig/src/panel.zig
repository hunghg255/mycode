//! Terminals, through the myzig terminal plugin (Ghostty's emulator, ConPTY
//! on Windows): `Term` is one, shown in the bottom panel or in a column's
//! tab; `Panel` is the bottom panel with its chips, profiles and buttons.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const terminal = @import("terminal");
const Profile = @import("termprofiles.zig").Profile;

/// What terminals report to: the window to redraw, links Ctrl+click opens.
pub const Host = struct {
    window: ?*myzig.Window = null,
    ctx: *anyopaque,
    open_link: *const fn (ctx: *anyopaque, link: []const u8, path: bool) bool,
    /// The libraries are downloaded once into the user's cache, off the main
    /// thread: 0 while, 1 done, 2 failed.
    ready: std.atomic.Value(u8) = .init(0),
    /// The settings' terminal font and copy on select, which open terminals
    /// follow as they change (set by the window each frame).
    font: Font = .{},

    pub const Font = struct {
        size: f32 = 13,
        family: ?[]const u8 = null,
        features: []const u8 = "",
        weight: u16 = 0,
        copy_on_select: bool = true,
    };

    pub fn prepare(h: *Host, gpa: std.mem.Allocator, io: std.Io) void {
        const th = std.Thread.spawn(.{}, fetch, .{ h, gpa, io }) catch {
            h.ready.store(2, .release);
            return;
        };
        th.detach();
    }

    fn fetch(h: *Host, gpa: std.mem.Allocator, io: std.Io) void {
        terminal.download.fetchAll(gpa, io) catch |err| {
            std.log.warn("terminal: {s}", .{@errorName(err)});
            h.ready.store(2, .release);
            if (h.window) |w| w.redraw();
            return;
        };
        h.ready.store(1, .release);
        if (h.window) |w| w.redraw();
    }
};

pub const Term = struct {
    gpa: std.mem.Allocator,
    host: *Host,
    t: *terminal.Terminal,
    title_buf: [64]u8 = undefined,
    title_len: usize = 0,
    profile_buf: [32]u8 = undefined,
    profile_len: usize = 0,
    dir: []u8,
    argv: [][]const u8,
    exited: bool = false,
    /// Where it was drawn last, for files dropped on it.
    rect: ?ui.Rect = null,
    /// Rang its bell or asked for attention while out of sight.
    bell: bool = false,
    /// What it asked attention for last: a notification's text (OSC 9,
    /// OSC 777), or its bell.
    alert_buf: [256]u8 = undefined,
    alert_len: usize = 0,
    focus: bool = true,

    pub const Options = struct {
        dir: []const u8,
        profile: ?Profile = null,
        font_size: f32 = 13,
        copy_on_select: bool = true,
    };

    pub fn create(gpa: std.mem.Allocator, io: std.Io, host: *Host, opts: Options) !*Term {
        const term = try gpa.create(Term);
        errdefer gpa.destroy(term);
        term.* = .{ .gpa = gpa, .host = host, .t = undefined, .dir = try gpa.dupe(u8, opts.dir), .argv = &.{} };
        errdefer gpa.free(term.dir);
        if (opts.profile) |p| {
            term.argv = try gpa.alloc([]const u8, p.args.len + 1);
            term.argv[0] = try gpa.dupe(u8, p.path);
            for (p.args, 1..) |a, i| term.argv[i] = try gpa.dupe(u8, a);
            const n = @min(p.name.len, term.profile_buf.len);
            @memcpy(term.profile_buf[0..n], p.name[0..n]);
            term.profile_len = n;
        }
        term.t = try terminal.Terminal.create(gpa, io, .{
            .command = term.argv,
            .dir = term.dir,
            .font_size = opts.font_size,
            .on_event = .{ .ctx = term, .func = onEvent },
            .open_link = openLink,
            .open_link_ctx = term,
            .copy_on_select = opts.copy_on_select,
            .read_clipboard = readClipboard,
            .read_clipboard_ctx = term,
        });
        return term;
    }

    /// It has the keyboard (as of the last frame).
    pub fn focused(term: *const Term) bool {
        return term.t.view_state.focused;
    }

    pub fn destroy(term: *Term) void {
        term.t.destroy();
        for (term.argv) |a| term.gpa.free(a);
        term.gpa.free(term.argv);
        term.gpa.free(term.dir);
        term.gpa.destroy(term);
    }

    fn setAlert(term: *Term, parts: []const []const u8) void {
        var w: std.Io.Writer = .fixed(&term.alert_buf);
        for (parts) |p| w.writeAll(p) catch {};
        term.alert_len = w.buffered().len;
    }

    pub fn alert(term: *const Term) []const u8 {
        return term.alert_buf[0..term.alert_len];
    }

    pub fn name(term: *const Term) []const u8 {
        if (term.title_len > 0) return term.title_buf[0..term.title_len];
        if (term.profile_len > 0) return term.profile_buf[0..term.profile_len];
        return "Terminal";
    }

    fn onEvent(ctx: ?*anyopaque, t: *terminal.Terminal, ev: terminal.Event) void {
        const term: *Term = @ptrCast(@alignCast(ctx.?));
        switch (ev) {
            .output => {},
            .bell => {
                term.bell = true;
                term.setAlert(&.{ "Bell from ", term.name() });
            },
            .notify => {
                term.bell = true;
                const n = t.notification();
                if (n.len > 0) term.setAlert(&.{n}) else term.setAlert(&.{ "Notification from ", term.name() });
            },
            .title => {
                const title = t.title(term.gpa) catch return;
                defer term.gpa.free(title);
                const n = @min(title.len, term.title_buf.len);
                @memcpy(term.title_buf[0..n], title[0..n]);
                term.title_len = n;
            },
            .exit => term.exited = true,
        }
        if (term.host.window) |w| w.redraw();
    }

    /// What a paste pastes: the clipboard's text; with only a picture on it
    /// an empty bracketed paste, as VS Code's terminal sends, so that Claude
    /// Code reads the picture itself; files copied, as their quoted paths.
    fn readClipboard(ctx: ?*anyopaque, gpa: std.mem.Allocator) ?[]u8 {
        const term: *Term = @ptrCast(@alignCast(ctx.?));
        if (myzig.clipboard.readText(gpa) catch null) |text| {
            if (text.len > 0) return text;
            gpa.free(text);
        }
        if (myzig.clipboard.readFiles(gpa) catch null) |files| {
            defer {
                for (files) |f| gpa.free(f);
                gpa.free(files);
            }
            return quotePaths(gpa, files) catch null;
        }
        if (myzig.clipboard.readImage(gpa) catch null) |img| {
            gpa.free(img);
            term.t.paste("");
        }
        return null;
    }

    /// Types paths into the program, each quoted for the shell.
    pub fn typePaths(term: *Term, paths: []const []const u8) void {
        const s = quotePaths(term.gpa, paths) catch return;
        defer term.gpa.free(s);
        term.t.paste(s);
        term.focus = true;
    }

    fn openLink(ctx: ?*anyopaque, link: []const u8, path: bool) bool {
        const term: *Term = @ptrCast(@alignCast(ctx.?));
        return term.host.open_link(term.host.ctx, link, path);
    }

    pub fn view(term: *Term, c: *ui.Context) void {
        c.keyed(term);
        const box = ui.div(c).wFull().grow();
        defer {
            if (box.interaction().rect) |r| term.rect = r;
            box.end();
        }
        const f = term.host.font;
        const o = &term.t.opts;
        o.font_size = f.size;
        o.font_family = f.family;
        o.font_features = f.features;
        o.font_weight = f.weight;
        o.copy_on_select = f.copy_on_select;
        terminal.view(c, term.t, .{ .autofocus = term.focus });
        term.focus = false;
        term.bell = false;
    }
};

pub const Panel = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    host: *Host,
    terms: std.ArrayList(*Term) = .empty,
    active: usize = 0,
    open: bool = false,
    maximized: bool = false,
    height: f32 = 260,
    err: ?[]const u8 = null,
    profile_menu: ui.Menu = .{},
    chip_menu: ui.Menu = .{},
    chip_at: usize = 0,
    /// Asked of the workbench: a new terminal (of a profile), a move to a column.
    request: ?Request = null,
    /// A chip pressed, dragged to a column (`wb_files.panelDragFrame`).
    drag: ?struct { term: *Term, start: ui.Point, moving: bool = false } = null,
    /// Where it was drawn last: tabs of terminals dropped there come in.
    rect: ?ui.Rect = null,

    pub const Request = union(enum) { new: ?usize, to_column: *Term, set_default: usize };

    pub fn deinit(p: *Panel) void {
        for (p.terms.items) |t| t.destroy();
        p.terms.deinit(p.gpa);
    }

    pub fn add(p: *Panel, t: *Term) void {
        p.terms.append(p.gpa, t) catch return;
        p.active = p.terms.items.len - 1;
        p.open = true;
        t.focus = true;
    }

    pub fn take(p: *Panel, i: usize) *Term {
        const t = p.terms.orderedRemove(i);
        if (p.active >= p.terms.items.len) p.active = p.terms.items.len -| 1;
        if (p.terms.items.len == 0) p.open = false;
        return t;
    }

    pub fn current(p: *Panel) ?*Term {
        if (p.terms.items.len == 0) return null;
        return p.terms.items[@min(p.active, p.terms.items.len - 1)];
    }

    pub fn cycle(p: *Panel, forward: bool) void {
        const n = p.terms.items.len;
        if (n == 0) return;
        p.active = if (forward) (p.active + 1) % n else (p.active + n - 1) % n;
        p.terms.items[p.active].focus = true;
    }

    pub fn view(p: *Panel, c: *ui.Context, profiles: []const Profile, default_profile: usize, chrome: ui.Color) void {
        const t = c.theme;
        var i: usize = p.terms.items.len;
        while (i > 0) {
            i -= 1;
            if (p.terms.items[i].exited) p.take(i).destroy();
        }
        const whole = ui.div(c).column().wFull().hFull().bg(t.background);
        defer {
            if (whole.interaction().rect) |r| p.rect = r;
            whole.end();
        }
        {
            const bar = ui.div(c).row().wFull().h(30).px(8).gap(4).itemsCenter().bg(chrome);
            defer bar.end();
            ui.text(c, "TERMINAL", .{ .size = 11, .weight = .semibold, .color = t.muted });
            _ = c.leaf(.{ .width = .{ .px = 8 } }, .none, null);
            var close_at: ?usize = null;
            for (p.terms.items, 0..) |term, k| {
                c.keyed(term);
                const on = k == p.active;
                const chip = ui.div(c).row().h(22).px(8).gap(6).itemsCenter().rounded(4).bg(if (on) t.surface_hover else .transparent).hover(t.surface_hover);
                ui.icon(c, "terminal", .{ .size = 11, .color = if (term.bell) t.accent else t.muted });
                ui.text(c, c.print("{d}: {s}", .{ k + 1, term.name() }), .{ .size = 12, .color = if (on) t.text else t.muted });
                const x = ui.div(c).w(14).h(14).center().rounded(3).hover(t.surface);
                ui.icon(c, "xmark", .{ .size = 8, .color = t.muted });
                if (x.clicked()) close_at = k;
                x.end();
                const ci = chip.interaction();
                chip.end();
                if (ci.clicked) {
                    p.active = k;
                    term.focus = true;
                }
                if (ci.pressed and c.input.pressed and p.drag == null) p.drag = .{ .term = term, .start = c.input.mouse };
                if (ui.contextMenu(c, &p.chip_menu, ci)) |m| {
                    defer m.end();
                    p.chip_at = k;
                    if (m.item("Move to Editor Column", .{})) p.request = .{ .to_column = term };
                    if (m.item("Kill Terminal", .{})) close_at = k;
                }
            }
            if (close_at) |k| {
                p.take(k).destroy();
                c.changed = true;
            }
            if (p.terms.items.len >= 2) {
                if (smallButton(c, "chevron.up", false)) p.cycle(false);
                if (smallButton(c, "chevron.down", false)) p.cycle(true);
            }
            ui.spacer(c);
            if (smallButton(c, "plus", false)) p.request = .{ .new = null };
            const more = ui.div(c).w(22).h(22).center().rounded(4).hover(t.surface_hover);
            ui.icon(c, "chevron.down", .{ .size = 10, .color = t.muted });
            const mi = more.interaction();
            more.end();
            if (ui.buttonMenu(c, &p.profile_menu, mi)) |m| {
                defer m.end();
                for (profiles, 0..) |pr, k| if (m.item(c.print("New {s}", .{pr.name}), .{})) {
                    p.request = .{ .new = k };
                };
                m.separator();
                if (m.submenu("Default Profile")) |sub| {
                    defer sub.end();
                    for (profiles, 0..) |pr, k| if (sub.item(pr.name, .{ .checked = k == default_profile })) {
                        p.request = .{ .set_default = k };
                    };
                }
            }
            if (smallButton(c, if (p.maximized) "chevron.down" else "chevron.up", false)) p.maximized = !p.maximized;
            if (smallButton(c, "xmark", false)) {
                p.open = false;
                p.maximized = false;
            }
        }
        switch (p.host.ready.load(.acquire)) {
            0 => ui.text(c, "  Downloading the terminal's libraries…", .{ .size = 12, .color = t.muted }),
            2 => ui.text(c, "  The terminal's libraries could not be downloaded. Set MYZIG_GHOSTTY_VT, or put them next to mycode.exe.", .{ .size = 12, .color = t.danger, .wrap = true }),
            else => if (p.current()) |term| term.view(c) else if (p.err) |e| ui.text(c, c.print("  Could not start a shell: {s}", .{e}), .{ .size = 12, .color = t.danger }),
        }
    }
};

pub fn smallButton(c: *ui.Context, icon: []const u8, on: bool) bool {
    const b = ui.div(c).w(22).h(22).center().rounded(4).bg(if (on) c.theme.surface_hover else .transparent).hover(c.theme.surface_hover);
    ui.icon(c, icon, .{ .size = 11, .color = if (on) c.theme.text else c.theme.muted });
    const clicked = b.clicked();
    b.end();
    return clicked;
}

/// Paths joined by spaces, each in double quotes when it needs them.
pub fn quotePaths(gpa: std.mem.Allocator, paths: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (paths, 0..) |p, i| {
        if (i > 0) try out.append(gpa, ' ');
        const plain = std.mem.indexOfAny(u8, p, " \t'\"&()[]{};$`") == null;
        if (plain) try out.appendSlice(gpa, p) else {
            try out.append(gpa, '"');
            for (p) |ch| {
                if (ch == '"') try out.append(gpa, '\\');
                try out.append(gpa, ch);
            }
            try out.append(gpa, '"');
        }
    }
    return out.toOwnedSlice(gpa);
}

test quotePaths {
    const gpa = std.testing.allocator;
    const s = try quotePaths(gpa, &.{ "C:\\a\\b.txt", "C:\\My Files\\c.png" });
    defer gpa.free(s);
    try std.testing.expectEqualStrings("C:\\a\\b.txt \"C:\\My Files\\c.png\"", s);
}
