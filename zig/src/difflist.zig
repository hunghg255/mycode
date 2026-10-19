//! A list of files changed, each read as it is chosen, and the diff of the
//! one chosen below it, unified or side by side, with its runs of changes
//! to step through. The Changes tab and a commit's tab are made of it.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const icons = @import("icons.zig");
const hunks = @import("hunks.zig");

pub const Entry = struct {
    /// Relative to the work tree's top, with slashes.
    path: []u8,
    orig: ?[]u8 = null,
    /// M, A, D, R, U (untracked), C (conflict).
    badge: u8,
    /// The group's title: "Staged Changes", "Changes", ...
    group: []const u8,
    staged: bool = false,
    /// What the sides are: a blob's spec (`HEAD:p`, `:p`, `<hash>:p`), "" for
    /// nothing, or "@" for the file in the work tree.
    old_spec: []u8,
    new_spec: []u8,
    dv: ?ui.DiffView = null,
    old_text: []u8 = &.{},
    new_text: []u8 = &.{},
    added: usize = 0,
    deleted: usize = 0,
    loaded: bool = false,
};

pub const Event = union(enum) {
    none,
    /// Opens the file (relative) at a line (from 1).
    open: struct { path: []const u8, line: usize },
    stage_hunk: usize,
    unstage_hunk: usize,
    discard_hunk: usize,
    stage_file,
    unstage_file,
    discard_file,
};

/// Reads a side's text: the app's (a blob, or the open file's text).
pub const Reader = struct {
    ctx: *anyopaque,
    read: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, spec: []const u8, path: []const u8) []u8,
};

pub const DiffList = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    selected: usize = 0,
    hunk: usize = 0,
    split: bool = false,
    list_height: f32 = 180,
    /// Buttons to stage and discard: the Changes tab's, not a commit's.
    editable: bool = true,

    pub fn deinit(dl: *DiffList) void {
        dl.clear();
        dl.entries.deinit(dl.gpa);
    }

    pub fn clear(dl: *DiffList) void {
        for (dl.entries.items) |*e| freeEntry(dl.gpa, e);
        dl.entries.clearRetainingCapacity();
    }

    fn freeEntry(gpa: std.mem.Allocator, e: *Entry) void {
        if (e.dv) |*d| d.deinit();
        gpa.free(e.path);
        if (e.orig) |o| gpa.free(o);
        gpa.free(e.old_spec);
        gpa.free(e.new_spec);
        gpa.free(e.old_text);
        gpa.free(e.new_text);
    }

    pub fn add(dl: *DiffList, path: []const u8, orig: ?[]const u8, badge: u8, group: []const u8, staged: bool, old_spec: []const u8, new_spec: []const u8) !void {
        const g = dl.gpa;
        try dl.entries.append(g, .{
            .path = try g.dupe(u8, path),
            .orig = if (orig) |o| try g.dupe(u8, o) else null,
            .badge = badge,
            .group = group,
            .staged = staged,
            .old_spec = try g.dupe(u8, old_spec),
            .new_spec = try g.dupe(u8, new_spec),
        });
    }

    pub fn current(dl: *DiffList) ?*Entry {
        if (dl.entries.items.len == 0) return null;
        dl.selected = @min(dl.selected, dl.entries.items.len - 1);
        return &dl.entries.items[dl.selected];
    }

    /// Chooses the entry of a path (the first, staged before unstaged).
    pub fn select(dl: *DiffList, path: []const u8) void {
        for (dl.entries.items, 0..) |e, i| if (std.mem.eql(u8, e.path, path)) {
            dl.selected = i;
            dl.hunk = 0;
            return;
        };
    }

    /// Reads an entry's sides again (when the file changed).
    pub fn reload(dl: *DiffList, r: Reader) void {
        for (dl.entries.items) |*e| if (e.loaded) dl.load(e, r);
    }

    fn load(dl: *DiffList, e: *Entry, r: Reader) void {
        const old = r.read(r.ctx, dl.gpa, e.old_spec, e.path);
        const new = r.read(r.ctx, dl.gpa, e.new_spec, e.path);
        const same = e.loaded and std.mem.eql(u8, old, e.old_text) and std.mem.eql(u8, new, e.new_text);
        if (same) {
            dl.gpa.free(old);
            dl.gpa.free(new);
            return;
        }
        dl.gpa.free(e.old_text);
        dl.gpa.free(e.new_text);
        e.old_text = old;
        e.new_text = new;
        if (e.dv) |*d| {
            d.set(old, new) catch {};
        } else e.dv = ui.DiffView.init(dl.gpa, old, new, std.fs.path.basename(e.path)) catch null;
        if (e.dv) |*d| {
            d.setMode(if (dl.split) .split else .unified);
            const st = d.stats();
            e.added = st.added;
            e.deleted = st.deleted;
        }
        e.loaded = true;
    }

    /// The hunks of the entry chosen, in the frame's memory.
    pub fn hunksOf(_: *DiffList, c: *ui.Context, e: *const Entry) []const hunks.Hunk {
        return hunks.hunksOf(c.alloc(), e.old_text, e.new_text) catch &.{};
    }

    fn scrollToHunk(e: *Entry, h: hunks.Hunk) void {
        const d = &(e.dv orelse return);
        d.build();
        for (d.rows.items, 0..) |row, i| {
            if (row.kind == .same or row.kind == .gap) continue;
            const hit = if (row.new) |n| n >= h.b0 and n <= h.b1 else if (row.old) |o| o >= h.a0 and o <= h.a1 else false;
            if (hit) {
                d.scroll_to = @intCast(i -| 3);
                return;
            }
        }
    }

    pub fn view(dl: *DiffList, c: *ui.Context, r: Reader, chrome: ui.Color) Event {
        const t = c.theme;
        var ev: Event = .none;
        const n = dl.entries.items.len;
        // The list takes the keyboard when clicked: then keys work as a pager's.
        const box = c.open(.{ .direction = .column, .width = .fill, .height = .fill }, null);
        defer c.end();
        const focused = c.interact(box, .{ .focusable = true }).focused;
        if (focused) {
            if (c.shortcut(.{ .key = '.' })) dl.choose(@min(dl.selected + 1, n -| 1));
            if (c.shortcut(.{ .key = ',' })) dl.choose(dl.selected -| 1);
            if (c.shortcut(.{ .key = 'j' }) or c.shortcut(.{ .key = ui.Shortcut.down })) dl.choose(@min(dl.selected + 1, n -| 1));
            if (c.shortcut(.{ .key = 'k' }) or c.shortcut(.{ .key = ui.Shortcut.up })) dl.choose(dl.selected -| 1);
        }
        if (n == 0) {
            ui.column(c, .{ .width = .fill, .grow = 1, .align_items = .center, .justify = .center });
            ui.text(c, "No changes", .{ .size = 13, .color = t.muted });
            ui.end(c);
            return ev;
        }
        var sp = ui.split(c, &dl.list_height, .{ .vertical = true, .min = 60 });
        {
            ui.scroll(c, .{ .width = .fill, .height = .fill, .background = chrome });
            defer ui.end(c);
            var last_group: []const u8 = "";
            for (dl.entries.items, 0..) |*e, i| {
                if (!std.mem.eql(u8, e.group, last_group)) {
                    last_group = e.group;
                    ui.row(c, .{ .width = .fill, .padding = .xy(10, 4) });
                    ui.text(c, e.group, .{ .size = 11, .weight = .semibold, .color = t.muted });
                    ui.end(c);
                }
                c.keyed(e);
                const on = i == dl.selected;
                const row = ui.div(c).row().wFull().h(24).px(12).gap(8).itemsCenter().bg(if (on) t.accent.alpha(0.18) else .transparent).hover(t.surface_hover);
                icons.file(c, std.fs.path.basename(e.path));
                ui.text(c, e.path, .{ .size = 12 });
                if (e.orig) |o| ui.text(c, c.print("← {s}", .{o}), .{ .size = 11, .color = t.muted });
                ui.spacer(c);
                if (e.loaded) {
                    ui.text(c, c.print("+{d}", .{e.added}), .{ .size = 11, .color = .hex(0x4fa86d), .mono = true });
                    ui.text(c, c.print("−{d}", .{e.deleted}), .{ .size = 11, .color = .hex(0xe0607e), .mono = true });
                }
                ui.text(c, c.print("{c}", .{e.badge}), .{ .size = 11, .mono = true, .color = t.muted });
                if (row.clicked()) dl.choose(i);
                row.end();
            }
        }
        sp.second();
        const e = dl.current().?;
        if (!e.loaded) dl.load(e, r);
        const hs = dl.hunksOf(c, e);
        if (dl.hunk >= hs.len) dl.hunk = hs.len -| 1;
        {
            const bar = ui.div(c).row().wFull().h(30).px(10).gap(8).itemsCenter().bg(chrome);
            defer bar.end();
            icons.file(c, std.fs.path.basename(e.path));
            ui.text(c, e.path, .{ .size = 12, .weight = .semibold });
            ui.text(c, c.print("+{d} −{d}", .{ e.added, e.deleted }), .{ .size = 11, .color = t.muted });
            ui.spacer(c);
            if (hs.len > 0) {
                ui.text(c, c.print("Change {d} of {d}", .{ dl.hunk + 1, hs.len }), .{ .size = 11, .color = t.muted });
                if (tool(c, "↑")) dl.stepHunk(e, hs, false);
                if (tool(c, "↓")) dl.stepHunk(e, hs, true);
                if (dl.editable) {
                    if (e.staged) {
                        if (tool(c, "Unstage Change")) ev = .{ .unstage_hunk = dl.hunk };
                    } else if (e.badge != 'U') {
                        if (tool(c, "Stage Change")) ev = .{ .stage_hunk = dl.hunk };
                        if (tool(c, "Discard Change")) ev = .{ .discard_hunk = dl.hunk };
                    }
                }
            }
            if (dl.editable) {
                if (e.staged) {
                    if (tool(c, "Unstage File")) ev = .unstage_file;
                } else {
                    if (tool(c, "Stage File")) ev = .stage_file;
                    if (tool(c, "Discard File")) ev = .discard_file;
                }
            }
            if (tool(c, if (dl.split) "Inline" else "Side by Side")) dl.setSplit(!dl.split);
            if (tool(c, "Open File")) ev = .{ .open = .{ .path = e.path, .line = if (hs.len > 0) hs[dl.hunk].b0 + 1 else 1 } };
        }
        if (focused) {
            if (c.shortcut(.{ .key = ']' })) dl.stepHunk(e, hs, true);
            if (c.shortcut(.{ .key = '[' })) dl.stepHunk(e, hs, false);
            if (dl.editable and c.shortcut(.{ .key = 's' }) and hs.len > 0) ev = if (e.staged) .{ .unstage_hunk = dl.hunk } else .{ .stage_hunk = dl.hunk };
            if (c.shortcut(.{ .key = 'e' }) or c.shortcut(.{ .key = ui.Shortcut.enter })) ev = .{ .open = .{ .path = e.path, .line = if (hs.len > 0) hs[dl.hunk].b0 + 1 else 1 } };
        }
        if (e.dv) |*d| ui.diffView(c, d, .{ .size = 12.5 }) else ui.text(c, "  The file can't be read.", .{ .size = 12, .color = t.muted });
        _ = sp.end();
        return ev;
    }

    fn choose(dl: *DiffList, i: usize) void {
        if (i == dl.selected) return;
        dl.selected = i;
        dl.hunk = 0;
    }

    fn stepHunk(dl: *DiffList, e: *Entry, hs: []const hunks.Hunk, forward: bool) void {
        if (hs.len == 0) return;
        if (forward) {
            if (dl.hunk + 1 < hs.len) dl.hunk += 1 else if (dl.selected + 1 < dl.entries.items.len) {
                dl.choose(dl.selected + 1);
                return;
            }
        } else if (dl.hunk > 0) dl.hunk -= 1 else if (dl.selected > 0) {
            dl.choose(dl.selected - 1);
            return;
        }
        scrollToHunk(e, hs[dl.hunk]);
    }

    pub fn setSplit(dl: *DiffList, on: bool) void {
        dl.split = on;
        for (dl.entries.items) |*e| if (e.dv) |*d| d.setMode(if (on) .split else .unified);
    }
};

fn tool(c: *ui.Context, label: []const u8) bool {
    return ui.button(c, label, .{ .variant = .ghost, .size = 11 }).clicked;
}
