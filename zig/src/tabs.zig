//! The editor's tabs: each a file's text in a code editor, saved and
//! auto-saved, with one preview tab that the next file chosen replaces.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const fs = @import("fs.zig");
const icons = @import("icons.zig");

pub const Tab = struct {
    /// Absolute; empty for an untitled file.
    path: []u8,
    editor: ui.CodeEditor,
    /// The document's version when last saved or read.
    saved: u64,
    /// The version auto save last saw, and when it changed.
    seen: u64,
    edited_at: f64 = 0,
    mtime: i96 = 0,
    preview: bool = false,
    binary: bool = false,
    crlf: bool = false,

    pub fn name(t: *const Tab) []const u8 {
        return if (t.path.len == 0) "Untitled" else std.fs.path.basename(t.path);
    }

    pub fn dirty(t: *const Tab) bool {
        return t.editor.area.doc.version != t.saved;
    }
};

pub const Tabs = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    list: std.ArrayList(*Tab) = .empty,
    active: usize = 0,
    auto_save: bool = true,
    /// Paths of the tabs closed, last first, for Reopen Closed Tab.
    closed: std.ArrayList([]u8) = .empty,
    menu: ui.Menu = .{},
    menu_tab: usize = 0,
    /// Set when the tab shown changed, so the window's title follows.
    switched: bool = true,
    err: ?[]const u8 = null,

    pub fn deinit(s: *Tabs) void {
        for (s.list.items) |t| s.free(t);
        s.list.deinit(s.gpa);
        for (s.closed.items) |p| s.gpa.free(p);
        s.closed.deinit(s.gpa);
    }

    fn free(s: *Tabs, t: *Tab) void {
        t.editor.deinit();
        s.gpa.free(t.path);
        s.gpa.destroy(t);
    }

    pub fn current(s: *Tabs) ?*Tab {
        if (s.list.items.len == 0) return null;
        return s.list.items[@min(s.active, s.list.items.len - 1)];
    }

    pub fn find(s: *Tabs, path: []const u8) ?usize {
        for (s.list.items, 0..) |t, i| if (std.mem.eql(u8, t.path, path)) return i;
        return null;
    }

    pub fn show(s: *Tabs, i: usize) void {
        if (i >= s.list.items.len) return;
        if (s.current()) |old| if (old != s.list.items[i] and s.auto_save) s.save(old) catch {};
        s.active = i;
        s.switched = true;
    }

    /// Opens a file, or shows its tab. A preview takes the preview tab's place.
    pub fn open(s: *Tabs, path: []const u8, preview: bool) !*Tab {
        if (s.find(path)) |i| {
            if (!preview) s.list.items[i].preview = false;
            s.show(i);
            return s.list.items[i];
        }
        const data = try fs.read(s.gpa, s.io, path);
        defer s.gpa.free(data);
        const t = try s.gpa.create(Tab);
        errdefer s.gpa.destroy(t);
        const bin = fs.binary(data);
        const text = if (bin) "This file is binary, and is not shown." else data;
        t.* = .{
            .path = try s.gpa.dupe(u8, path),
            .editor = .init(s.gpa, "", std.fs.path.basename(path)),
            .saved = 0,
            .seen = 0,
            .preview = preview,
            .binary = bin,
            .crlf = std.mem.indexOf(u8, data, "\r\n") != null,
            .mtime = fs.mtime(s.io, path),
        };
        t.editor.area.reset(text);
        t.editor.read_only = bin;
        if (std.mem.indexOf(u8, data[0..@min(data.len, 64 << 10)], "\n\t") != null) t.editor.indent.unit = "\t";
        t.saved = t.editor.area.doc.version;
        t.seen = t.saved;
        // A preview replaces the preview tab, unless that one was edited.
        if (preview) for (s.list.items, 0..) |o, i| if (o.preview and !o.dirty()) {
            s.free(o);
            s.list.items[i] = t;
            s.show(i);
            return t;
        };
        const at = if (s.list.items.len == 0) 0 else @min(s.active + 1, s.list.items.len);
        try s.list.insert(s.gpa, at, t);
        s.show(at);
        return t;
    }

    pub fn newUntitled(s: *Tabs) !void {
        const t = try s.gpa.create(Tab);
        t.* = .{ .path = try s.gpa.dupe(u8, ""), .editor = .init(s.gpa, "", null), .saved = 0, .seen = 0 };
        t.saved = t.editor.area.doc.version;
        t.seen = t.saved;
        try s.list.append(s.gpa, t);
        s.show(s.list.items.len - 1);
    }

    pub fn save(s: *Tabs, t: *Tab) !void {
        if (t.path.len == 0 or t.binary or !t.dirty()) return;
        const text = t.editor.area.text(s.gpa);
        defer s.gpa.free(text);
        if (t.crlf) {
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(s.gpa);
            var it = std.mem.splitScalar(u8, text, '\n');
            var first = true;
            while (it.next()) |line| {
                if (!first) try out.appendSlice(s.gpa, "\r\n");
                first = false;
                try out.appendSlice(s.gpa, std.mem.trimEnd(u8, line, "\r"));
            }
            try fs.write(s.io, t.path, out.items);
        } else try fs.write(s.io, t.path, text);
        t.saved = t.editor.area.doc.version;
        t.preview = false;
        t.mtime = fs.mtime(s.io, t.path);
    }

    pub fn saveAs(s: *Tabs, t: *Tab, path: []const u8) !void {
        s.gpa.free(t.path);
        t.path = try s.gpa.dupe(u8, path);
        t.editor.setLanguage(std.fs.path.basename(path));
        t.saved = t.editor.area.doc.version +% 1; // dirty, so save writes it
        try s.save(t);
        s.switched = true;
    }

    pub fn saveAll(s: *Tabs) void {
        for (s.list.items) |t| s.save(t) catch {};
    }

    /// Closes a tab, saving it first when auto save is on.
    pub fn close(s: *Tabs, i: usize) void {
        if (i >= s.list.items.len) return;
        const t = s.list.items[i];
        if (s.auto_save) s.save(t) catch {};
        if (t.path.len > 0) if (s.gpa.dupe(u8, t.path)) |p| s.closed.append(s.gpa, p) catch s.gpa.free(p) else |_| {};
        _ = s.list.orderedRemove(i);
        s.free(t);
        if (s.active > i or s.active >= s.list.items.len) s.active -|= 1;
        s.switched = true;
    }

    pub fn closeOthers(s: *Tabs, keep: usize) void {
        const k = s.list.items[keep];
        var i: usize = s.list.items.len;
        while (i > 0) {
            i -= 1;
            if (s.list.items[i] != k) s.close(i);
        }
        s.active = 0;
    }

    pub fn reopenClosed(s: *Tabs) void {
        const p = s.closed.pop() orelse return;
        defer s.gpa.free(p);
        _ = s.open(p, false) catch {};
    }

    /// Reloads tabs whose files changed on disk, unless they have edits.
    pub fn reloadChanged(s: *Tabs) void {
        for (s.list.items) |t| {
            if (t.path.len == 0 or t.binary) continue;
            const m = fs.mtime(s.io, t.path);
            if (m == 0 or m == t.mtime) continue;
            t.mtime = m;
            if (t.dirty()) continue;
            const data = fs.read(s.gpa, s.io, t.path) catch continue;
            defer s.gpa.free(data);
            const now = t.editor.area.text(s.gpa);
            defer s.gpa.free(now);
            if (std.mem.eql(u8, now, data)) continue;
            // Reloading is a step of undo, as in the Go app.
            t.editor.area.setText(data);
            t.saved = t.editor.area.doc.version;
            t.seen = t.saved;
        }
    }

    /// Saves files a second after their last edit.
    pub fn tick(s: *Tabs, c: *ui.Context) void {
        for (s.list.items) |t| {
            const v = t.editor.area.doc.version;
            if (v != t.seen) {
                t.seen = v;
                t.edited_at = c.time;
                t.preview = false;
            }
            if (!s.auto_save or !t.dirty() or t.path.len == 0) continue;
            const left = t.edited_at + 1.0 - c.time;
            if (left <= 0) s.save(t) catch {} else c.frameIn(@floatCast(left));
        }
    }

    /// The strip of tabs above the editor.
    pub fn strip(s: *Tabs, c: *ui.Context) void {
        const t = c.theme;
        const bar = ui.div(c).row().wFull().h(34).bg(t.surface).itemsStretch();
        defer bar.end();
        var close_at: ?usize = null;
        var others_at: ?usize = null;
        for (s.list.items, 0..) |tab, i| {
            c.keyed(tab);
            const on = i == s.active;
            const cell = ui.div(c).row().h(34).px(10).gap(6).itemsCenter().bg(if (on) t.background else t.surface).hover(if (on) t.background else t.surface_hover);
            icons.file(c, tab.name());
            ui.text(c, tab.name(), .{ .size = 13, .italic = tab.preview, .color = if (on) t.text else t.muted });
            // A dot for unsaved edits, a cross on hover.
            const x = ui.div(c).w(16).h(16).center().rounded(4).hover(t.surface_hover);
            if (tab.dirty() and !cell.hovered()) {
                _ = c.leaf(.{ .width = .{ .px = 7 }, .height = .{ .px = 7 }, .radius = 4, .background = t.text }, .none, null);
            } else if (cell.hovered() or on) {
                ui.icon(c, "xmark", .{ .size = 9, .color = t.muted });
            }
            const x_clicked = x.clicked();
            x.end();
            const it = cell.interaction();
            cell.end();
            if (x_clicked) {
                close_at = i;
            } else if (it.double_clicked) {
                tab.preview = false;
            } else if (it.clicked) {
                s.show(i);
            }
            if (ui.contextMenu(c, &s.menu, it)) |m| {
                defer m.end();
                s.menu_tab = i;
                if (m.item("Close", .{ .shortcut = ui.keys.label("⌘W") })) close_at = i;
                if (m.item("Close Others", .{})) others_at = i;
                if (m.item("Keep Open", .{ .disabled = !tab.preview })) tab.preview = false;
            }
        }
        if (close_at) |i| {
            s.close(i);
            c.changed = true;
        } else if (others_at) |i| {
            s.closeOthers(i);
            c.changed = true;
        }
    }
};
