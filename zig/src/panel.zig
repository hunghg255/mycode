//! The bottom panel: terminals running the user's shell in the workspace's
//! folder, through the myzig terminal plugin (Ghostty's emulator).
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const terminal = @import("terminal");

pub const Panel = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    window: ?*myzig.Window = null,
    terms: std.ArrayList(*Term) = .empty,
    active: usize = 0,
    open: bool = false,
    height: f32 = 260,
    /// The libraries are downloaded once into the user's cache, off the main thread.
    ready: std.atomic.Value(u8) = .init(0),
    err: ?[]const u8 = null,
    focus_term: bool = false,

    const Term = struct {
        panel: *Panel,
        t: *terminal.Terminal,
        title: [64]u8 = undefined,
        title_len: usize = 0,
        exited: bool = false,
    };

    pub fn deinit(p: *Panel) void {
        for (p.terms.items) |t| {
            t.t.destroy();
            p.gpa.destroy(t);
        }
        p.terms.deinit(p.gpa);
    }

    /// Fetches libghostty-vt (and ConPTY on Windows) when missing, on a thread.
    pub fn prepare(p: *Panel) void {
        const th = std.Thread.spawn(.{}, fetch, .{p}) catch {
            p.ready.store(2, .release);
            return;
        };
        th.detach();
    }

    fn fetch(p: *Panel) void {
        terminal.download.fetchAll(p.gpa, p.io) catch |err| {
            std.log.warn("terminal: {s}", .{@errorName(err)});
            p.ready.store(2, .release);
            if (p.window) |w| w.redraw();
            return;
        };
        p.ready.store(1, .release);
        if (p.window) |w| w.redraw();
    }

    pub fn toggle(p: *Panel) void {
        p.open = !p.open;
        if (p.open and p.terms.items.len == 0) p.newTerminal();
        p.focus_term = p.open;
    }

    pub fn newTerminal(p: *Panel) void {
        p.open = true;
        if (p.ready.load(.acquire) == 0) return; // started once the libraries are there
        const term = p.gpa.create(Term) catch return;
        term.* = .{ .panel = p, .t = undefined };
        term.t = terminal.Terminal.create(p.gpa, p.io, .{
            .dir = p.root,
            .on_event = .{ .ctx = term, .func = onEvent },
        }) catch |err| {
            p.err = @errorName(err);
            p.gpa.destroy(term);
            return;
        };
        p.terms.append(p.gpa, term) catch {
            term.t.destroy();
            p.gpa.destroy(term);
            return;
        };
        p.active = p.terms.items.len - 1;
        p.focus_term = true;
    }

    fn onEvent(ctx: ?*anyopaque, t: *terminal.Terminal, ev: terminal.Event) void {
        const term: *Term = @ptrCast(@alignCast(ctx.?));
        const p = term.panel;
        switch (ev) {
            .output, .bell => {},
            .title => {
                const title = t.title(p.gpa) catch return;
                defer p.gpa.free(title);
                const n = @min(title.len, term.title.len);
                @memcpy(term.title[0..n], title[0..n]);
                term.title_len = n;
            },
            .exit => term.exited = true,
        }
        if (p.window) |w| w.redraw();
    }

    fn closeAt(p: *Panel, i: usize) void {
        const term = p.terms.orderedRemove(i);
        term.t.destroy();
        p.gpa.destroy(term);
        if (p.active >= p.terms.items.len) p.active = p.terms.items.len -| 1;
        if (p.terms.items.len == 0) p.open = false;
    }

    /// Sends text to the terminal used last, opening one when there is none.
    pub fn send(p: *Panel, text: []const u8) void {
        if (p.terms.items.len == 0) p.newTerminal();
        if (p.terms.items.len == 0) return;
        p.open = true;
        p.terms.items[p.active].t.send(text);
    }

    pub fn view(p: *Panel, c: *ui.Context) void {
        const t = c.theme;
        // Terminals whose shell exited go.
        var i: usize = p.terms.items.len;
        while (i > 0) {
            i -= 1;
            if (p.terms.items[i].exited) p.closeAt(i);
        }
        if (p.open and p.terms.items.len == 0 and p.ready.load(.acquire) == 1) p.newTerminal();

        ui.column(c, .{ .width = .fill, .height = .fill, .background = t.background });
        defer ui.end(c);
        {
            const bar = ui.div(c).row().wFull().h(30).px(8).gap(4).itemsCenter();
            defer bar.end();
            ui.text(c, "TERMINAL", .{ .size = 11, .weight = .semibold, .color = t.muted });
            _ = c.leaf(.{ .width = .{ .px = 8 } }, .none, null);
            var close_at: ?usize = null;
            for (p.terms.items, 0..) |term, k| {
                c.keyed(term);
                const on = k == p.active;
                const chip = ui.div(c).row().h(22).px(8).gap(6).itemsCenter().rounded(4).bg(if (on) t.surface_hover else .transparent).hover(t.surface_hover);
                ui.icon(c, "terminal", .{ .size = 11, .color = t.muted });
                const title = if (term.title_len > 0) term.title[0..term.title_len] else "shell";
                ui.text(c, c.print("{d}: {s}", .{ k + 1, title }), .{ .size = 12, .color = if (on) t.text else t.muted });
                const x = ui.div(c).w(14).h(14).center().rounded(3).hover(t.surface);
                ui.icon(c, "xmark", .{ .size = 8, .color = t.muted });
                if (x.clicked()) close_at = k;
                x.end();
                if (chip.clicked()) {
                    p.active = k;
                    p.focus_term = true;
                }
                chip.end();
            }
            if (close_at) |k| {
                p.closeAt(k);
                c.changed = true;
            }
            ui.spacer(c);
            const plus = ui.div(c).w(22).h(22).center().rounded(4).hover(t.surface_hover);
            ui.icon(c, "plus", .{ .size = 12, .color = t.muted });
            if (plus.clicked()) p.newTerminal();
            plus.end();
            const hide = ui.div(c).w(22).h(22).center().rounded(4).hover(t.surface_hover);
            ui.icon(c, "xmark", .{ .size = 11, .color = t.muted });
            if (hide.clicked()) p.open = false;
            hide.end();
        }
        switch (p.ready.load(.acquire)) {
            0 => ui.text(c, "  Downloading the terminal's libraries…", .{ .size = 12, .color = t.muted }),
            2 => ui.text(c, "  The terminal's libraries could not be downloaded. Set MYZIG_GHOSTTY_VT, or put them next to mycode.exe.", .{ .size = 12, .color = t.danger, .wrap = true }),
            else => if (p.terms.items.len > 0) {
                const term = p.terms.items[@min(p.active, p.terms.items.len - 1)];
                c.keyed(term);
                const box = ui.div(c).wFull().grow();
                defer box.end();
                terminal.view(c, term.t, .{ .autofocus = p.focus_term });
                p.focus_term = false;
            } else if (p.err) |e| ui.text(c, c.print("  Could not start a shell: {s}", .{e}), .{ .size = 12, .color = t.danger }),
        }
    }
};
