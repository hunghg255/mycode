//! The editor's columns, side by side, each with its own tabs and preview
//! tab. Tabs hold files, pictures, diffs, commits and terminals. A tab drags
//! along its strip, into another column, or to a column's right edge for a
//! new column; a locked column keeps its terminals.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const fs = @import("fs.zig");
const icons = @import("icons.zig");
const Doc = @import("doc.zig").Doc;
const viewer = @import("viewer.zig");
const Changes = @import("changes.zig").Changes;
const CommitView = @import("commitview.zig").CommitView;
const Term = @import("panel.zig").Term;

pub const Body = union(enum) {
    file: *Doc,
    image: *viewer.Image,
    changes: *Changes,
    commit: *CommitView,
    terminal: *Term,
};

pub const Item = struct {
    body: Body,
    preview: bool = false,
    /// A file's selection in this tab, when another tab shows the file too
    /// (each keeps its own caret; they share the text).
    sel: ?ui.TextSel = null,
    /// Its preview shown rather than its source, likewise.
    rendered: ?bool = null,
    /// Its editor's id in the last frame (which tab's text has the keyboard).
    area_id: u64 = 0,

    pub fn title(it: *const Item, c: *ui.Context) []const u8 {
        return switch (it.body) {
            .file => |d| d.name(),
            .image => |im| std.fs.path.basename(im.path),
            .changes => "Changes",
            .commit => |cv| if (std.mem.startsWith(u8, cv.hash, "stash@")) cv.hash else c.print("{s} {s}", .{ cv.hash[0..@min(7, cv.hash.len)], cv.subject() }),
            .terminal => |t| t.name(),
        };
    }

    /// The file's path, for a file or a picture.
    pub fn path(it: *const Item) ?[]const u8 {
        return switch (it.body) {
            .file => |d| if (d.path.len > 0) d.path else null,
            .image => |im| im.path,
            else => null,
        };
    }

    pub fn dirty(it: *const Item) bool {
        return switch (it.body) {
            .file => |d| d.dirty(),
            else => false,
        };
    }

    pub fn destroy(it: *Item, gpa: std.mem.Allocator) void {
        switch (it.body) {
            .file => |d| d.release(),
            .image => |im| im.destroy(),
            .changes => |ch| ch.destroy(),
            .commit => |cv| cv.destroy(),
            .terminal => |t| t.destroy(),
        }
        gpa.destroy(it);
    }
};

pub const Column = struct {
    items: std.ArrayList(*Item) = .empty,
    active: usize = 0,
    locked: bool = false,
    /// The tab last brought into view in the strip.
    revealed: ?*const Item = null,
    /// Its width in points, but the last column's, which takes the rest.
    width: f32 = 0,

    pub fn current(col: *Column) ?*Item {
        if (col.items.items.len == 0) return null;
        return col.items.items[@min(col.active, col.items.items.len - 1)];
    }
};

pub const Loc = struct { col: usize, idx: usize };

/// A tab closed, to open again: a file with its caret and scroll, or a
/// terminal (a new shell in its folder, `path`).
const Closed = struct { path: []u8, col: usize, idx: usize, caret: usize = 0, scroll: f32 = 0, terminal: bool = false };

pub const Drag = struct { from: Loc, start: ui.Point, moving: bool = false };

pub const TabRect = struct { col: usize, idx: usize, rect: ui.Rect };

pub const Editors = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cols: std.ArrayList(*Column) = .empty,
    focus: usize = 0,
    /// The column files went to last, when a locked column has the keyboard.
    last_file_col: usize = 0,
    closed: std.ArrayList(Closed) = .empty,
    auto_save: bool = true,
    /// The tab shown changed: the title follows, and auto save saved the last.
    switched: bool = true,
    menu: ui.Menu = .{},
    menu_at: Loc = .{ .col = 0, .idx = 0 },
    drag: ?Drag = null,
    /// Each column's strip and body as last laid out, for drops.
    strip_rects: [16]ui.Rect = undefined,
    strip_menu: ui.Menu = .{},
    /// The project's folder: tabs' tooltips are their paths from it.
    root: []const u8 = "",
    body_rects: [16]ui.Rect = undefined,
    /// The panel as last laid out: a terminal's tab let go there goes to it.
    panel_rect: ?ui.Rect = null,
    /// Tabs being closed whose changes the user is asked about, in turn.
    ask_close: std.ArrayList(*Item) = .empty,
    /// Each tab as last laid out, for where a drop between tabs goes.
    tab_rects: std.ArrayList(TabRect) = .empty,
    /// Asked of the workbench by the tab menu.
    request: ?Request = null,
    /// The folder of the terminal `reopen_terminal` asks for, owned.
    reopen_dir: ?[]u8 = null,

    pub const Request = union(enum) { reveal: []const u8, open_changes: []const u8, to_panel: *Term, to_locked: *Term, copy_path: []const u8, new_terminal_in: usize, reopen_terminal: Loc };

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Editors {
        var e: Editors = .{ .gpa = gpa, .io = io };
        const col = gpa.create(Column) catch @panic("out of memory");
        col.* = .{};
        e.cols.append(gpa, col) catch @panic("out of memory");
        return e;
    }

    pub fn deinit(e: *Editors) void {
        for (e.cols.items) |col| {
            for (col.items.items) |it| it.destroy(e.gpa);
            col.items.deinit(e.gpa);
            e.gpa.destroy(col);
        }
        e.cols.deinit(e.gpa);
        if (e.reopen_dir) |d| e.gpa.free(d);
        e.tab_rects.deinit(e.gpa);
        e.ask_close.deinit(e.gpa);
        for (e.closed.items) |c| e.gpa.free(c.path);
        e.closed.deinit(e.gpa);
    }

    pub fn focusCol(e: *Editors) *Column {
        e.focus = @min(e.focus, e.cols.items.len - 1);
        return e.cols.items[e.focus];
    }

    pub fn current(e: *Editors) ?*Item {
        return e.focusCol().current();
    }

    pub fn currentDoc(e: *Editors) ?*Doc {
        const it = e.current() orelse return null;
        return switch (it.body) {
            .file => |d| d,
            else => null,
        };
    }

    pub fn currentLoc(e: *Editors) ?Loc {
        const col = e.focusCol();
        if (col.items.items.len == 0) return null;
        return .{ .col = e.focus, .idx = @min(col.active, col.items.items.len - 1) };
    }

    pub fn at(e: *Editors, l: Loc) *Item {
        return e.cols.items[l.col].items.items[l.idx];
    }

    /// Every tab, column by column.
    pub fn each(e: *Editors, buf: []*Item) []*Item {
        var n: usize = 0;
        for (e.cols.items) |col| for (col.items.items) |it| {
            if (n == buf.len) return buf[0..n];
            buf[n] = it;
            n += 1;
        };
        return buf[0..n];
    }

    pub fn findPath(e: *Editors, p: []const u8) ?Loc {
        // The focused column first.
        for (e.focusCol().items.items, 0..) |it, i| if (it.path()) |ip| if (std.mem.eql(u8, ip, p)) return .{ .col = e.focus, .idx = i };
        for (e.cols.items, 0..) |col, ci| for (col.items.items, 0..) |it, i| if (it.path()) |ip| if (std.mem.eql(u8, ip, p)) return .{ .col = ci, .idx = i };
        return null;
    }

    pub fn findDoc(e: *Editors, p: []const u8) ?*Doc {
        const l = e.findPath(p) orelse return null;
        return switch (e.at(l).body) {
            .file => |d| d,
            else => null,
        };
    }

    /// Where files open: the column with the keyboard, unless it is locked.
    pub fn fileColumn(e: *Editors) usize {
        if (!e.focusCol().locked) return e.focus;
        if (e.last_file_col < e.cols.items.len and !e.cols.items[e.last_file_col].locked) return e.last_file_col;
        for (e.cols.items, 0..) |col, i| if (!col.locked) return i;
        // Every column is locked: one more, unlocked.
        return e.addColumn(0) catch 0;
    }

    pub fn addColumn(e: *Editors, at_index: usize) !usize {
        if (e.cols.items.len >= 16) return error.TooManyColumns;
        const col = try e.gpa.create(Column);
        col.* = .{};
        const i = @min(at_index, e.cols.items.len);
        try e.cols.insert(e.gpa, i, col);
        for (e.cols.items) |cc| cc.width = 0; // shared again
        if (e.focus >= i and e.cols.items.len > 1 and e.focus != i) e.focus += 1;
        return i;
    }

    pub fn show(e: *Editors, l: Loc) void {
        const col = e.cols.items[l.col];
        if (l.idx >= col.items.items.len) return;
        if (e.auto_save) if (e.current()) |old| if (old != col.items.items[l.idx]) saveItem(old);
        col.active = l.idx;
        e.focus = l.col;
        if (!col.locked) e.last_file_col = l.col;
        e.switched = true;
    }

    /// Adds a tab to a column: a preview takes its preview tab's place.
    pub fn add(e: *Editors, it: *Item, col_i: usize) !Loc {
        const col = e.cols.items[col_i];
        if (it.preview) for (col.items.items, 0..) |o, i| if (o.preview and !o.dirty()) {
            o.destroy(e.gpa);
            col.items.items[i] = it;
            e.show(.{ .col = col_i, .idx = i });
            return .{ .col = col_i, .idx = i };
        };
        const i = if (col.items.items.len == 0) 0 else @min(col.active + 1, col.items.items.len);
        try col.items.insert(e.gpa, i, it);
        e.show(.{ .col = col_i, .idx = i });
        return .{ .col = col_i, .idx = i };
    }

    pub fn newItem(e: *Editors, body: Body, preview: bool) !*Item {
        const it = try e.gpa.create(Item);
        it.* = .{ .body = body, .preview = preview };
        return it;
    }

    /// Opens a file (a picture in the viewer), or shows its tab.
    pub fn openFile(e: *Editors, p: []const u8, preview: bool) !*Item {
        if (e.findPath(p)) |l| {
            const it = e.at(l);
            if (!preview) it.preview = false;
            e.show(l);
            return it;
        }
        const body: Body = if (viewer.isImage(p))
            .{ .image = try viewer.Image.create(e.gpa, e.io, p) }
        else
            .{ .file = try Doc.create(e.gpa, e.io, p) };
        const it = try e.newItem(body, preview);
        errdefer it.destroy(e.gpa);
        _ = try e.add(it, e.fileColumn());
        return it;
    }

    pub fn newUntitled(e: *Editors) !void {
        const it = try e.newItem(.{ .file = try Doc.create(e.gpa, e.io, "") }, false);
        _ = try e.add(it, e.fileColumn());
    }

    fn saveItem(it: *Item) void {
        switch (it.body) {
            .file => |d| d.save() catch {},
            else => {},
        }
    }

    pub fn saveAll(e: *Editors) void {
        for (e.cols.items) |col| for (col.items.items) |it| saveItem(it);
    }

    pub fn anyDirty(e: *Editors) bool {
        for (e.cols.items) |col| for (col.items.items) |it| if (it.dirty()) return true;
        return false;
    }

    /// Takes a tab out of its column, without freeing it.
    pub fn take(e: *Editors, l: Loc) *Item {
        const col = e.cols.items[l.col];
        const it = col.items.orderedRemove(l.idx);
        if (col.active > l.idx or col.active >= col.items.items.len) col.active -|= 1;
        e.switched = true;
        return it;
    }

    /// Closes a tab, saving it first when auto save is on, and drops an
    /// empty extra column.
    /// Whether closing a tab asks about its changes, as the Go app's
    /// `closeTab`: a file changed, shown in no other tab, that auto save
    /// doesn't save (it is off, or the file has no path yet).
    pub fn needsAsk(e: *const Editors, it: *const Item) bool {
        return switch (it.body) {
            .file => |d| d.dirty() and d.refs == 1 and !(e.auto_save and d.path.len > 0),
            else => false,
        };
    }

    /// Where an item is, if it is still open.
    pub fn locOf(e: *const Editors, it: *const Item) ?Loc {
        for (e.cols.items, 0..) |col, ci| for (col.items.items, 0..) |o, i| if (o == it) return .{ .col = ci, .idx = i };
        return null;
    }

    /// Asks about every tab whose changes closing would lose; true if any.
    pub fn askAll(e: *Editors) bool {
        for (e.cols.items) |col| for (col.items.items) |it| if (e.needsAsk(it) and std.mem.indexOfScalar(*Item, e.ask_close.items, it) == null) {
            e.ask_close.append(e.gpa, it) catch {};
        };
        return e.ask_close.items.len > 0;
    }

    /// Closes a tab: one whose changes would be lost waits for the question
    /// (`ask_close`), the others go, saved first when auto save is on.
    pub fn close(e: *Editors, l: Loc) void {
        const it = e.at(l);
        if (e.needsAsk(it)) {
            if (std.mem.indexOfScalar(*Item, e.ask_close.items, it) == null) e.ask_close.append(e.gpa, it) catch {};
            return;
        }
        e.closeNow(l, e.auto_save);
    }

    /// Closes a tab without asking, saving it first with `save`.
    pub fn closeNow(e: *Editors, l: Loc, save: bool) void {
        const it = e.at(l);
        if (save) saveItem(it);
        if (std.mem.indexOfScalar(*Item, e.ask_close.items, it)) |k| _ = e.ask_close.orderedRemove(k);
        const where: ?[]const u8 = switch (it.body) {
            .terminal => |t| t.dir,
            else => it.path(),
        };
        if (where) |p| if (e.gpa.dupe(u8, p)) |dp| {
            var cl: Closed = .{ .path = dp, .col = l.col, .idx = l.idx, .terminal = it.body == .terminal };
            switch (it.body) {
                .file => |d| {
                    cl.caret = d.editor.area.sel.caret;
                    cl.scroll = d.scroll_y;
                },
                else => {},
            }
            e.closed.append(e.gpa, cl) catch e.gpa.free(dp);
        } else |_| {};
        _ = e.take(l);
        it.destroy(e.gpa);
        e.dropEmpty(l.col);
    }

    /// An empty column goes, unless it is the last, or the last unlocked
    /// one beside locked ones, or locked (it offers a new terminal).
    fn dropEmpty(e: *Editors, ci: usize) void {
        const col = e.cols.items[ci];
        if (col.items.items.len > 0 or e.cols.items.len == 1 or col.locked) return;
        var unlocked: usize = 0;
        for (e.cols.items) |cc| if (!cc.locked) {
            unlocked += 1;
        };
        if (unlocked <= 1) return;
        col.items.deinit(e.gpa);
        e.gpa.destroy(col);
        _ = e.cols.orderedRemove(ci);
        for (e.cols.items) |cc| cc.width = 0;
        if (e.focus >= ci) e.focus -|= 1;
        if (e.last_file_col >= ci) e.last_file_col -|= 1;
        e.switched = true;
    }

    pub fn closeColumnIfEmpty(e: *Editors) bool {
        const col = e.focusCol();
        if (col.items.items.len > 0 or e.cols.items.len == 1) return false;
        col.locked = false;
        e.dropEmpty(e.focus);
        return true;
    }

    pub fn closeWhere(e: *Editors, ci: usize, keep: ?*Item, comptime which: enum { others, right, saved, all }) void {
        const col = e.cols.items[ci];
        const keep_at = if (keep) |k| std.mem.indexOfScalar(*Item, col.items.items, k) else null;
        var i: usize = col.items.items.len;
        while (i > 0) {
            i -= 1;
            const it = col.items.items[i];
            const go = switch (which) {
                .others => it != keep,
                .right => keep_at != null and i > keep_at.?,
                .saved => !it.dirty(),
                .all => true,
            };
            if (go) {
                if (col.items.items.len == 1 and e.cols.items[ci] == col and which != .all) {
                    e.close(.{ .col = ci, .idx = i });
                    return;
                }
                e.close(.{ .col = ci, .idx = i });
                if (ci >= e.cols.items.len or e.cols.items[ci] != col) return;
            }
        }
        if (keep) |k| if (std.mem.indexOfScalar(*Item, col.items.items, k)) |ki| {
            col.active = ki;
        };
    }

    /// Opens the tab closed last again where it was: a file at its caret
    /// and scroll, a terminal as a new shell in its folder.
    pub fn reopenClosed(e: *Editors) void {
        const c = e.closed.pop() orelse return;
        const col = @min(c.col, e.cols.items.len - 1);
        if (c.terminal) {
            if (e.reopen_dir) |d| e.gpa.free(d);
            e.reopen_dir = c.path;
            e.request = .{ .reopen_terminal = .{ .col = col, .idx = c.idx } };
            return;
        }
        defer e.gpa.free(c.path);
        if (!fs.exists(e.io, c.path)) return;
        e.focus = col;
        const it = e.openFile(c.path, false) catch return;
        // Back at its place in its column.
        if (e.currentLoc()) |l| if (l.col != col or l.idx != c.idx) e.move(l, col, c.idx);
        switch (it.body) {
            .file => |d| {
                d.editor.area.collapse(@min(c.caret, d.editor.area.len()));
                d.restore_scroll = c.scroll;
            },
            else => {},
        }
    }

    pub fn forgetClosed(e: *Editors) void {
        if (e.reopen_dir) |d| e.gpa.free(d);
        e.reopen_dir = null;
        for (e.closed.items) |c| e.gpa.free(c.path);
        e.closed.clearRetainingCapacity();
    }

    /// Moves a tab into another column (at `idx`, or its end).
    pub fn move(e: *Editors, from: Loc, to_col: usize, idx: ?usize) void {
        if (to_col >= e.cols.items.len) return;
        const src = e.cols.items[from.col];
        const it = e.take(from);
        it.preview = false;
        const dst = e.cols.items[to_col];
        const at_i = @min(idx orelse dst.items.items.len, dst.items.items.len);
        dst.items.insert(e.gpa, at_i, it) catch {
            src.items.append(e.gpa, it) catch {};
            return;
        };
        e.show(.{ .col = to_col, .idx = at_i });
        if (src.items.items.len == 0) {
            if (std.mem.indexOfScalar(*Column, e.cols.items, src)) |si| e.dropEmpty(si);
        }
    }

    /// Moves a tab to a new column right of `col_i`.
    pub fn splitRight(e: *Editors, from: Loc) void {
        const ni = e.addColumn(from.col + 1) catch return;
        const src_col = if (from.col >= ni) from.col + 1 else from.col;
        const it = e.cols.items[src_col].items.items[from.idx];
        switch (it.body) {
            // A file shows in both columns, sharing its text and undo.
            .file => |d| {
                const copy = e.newItem(.{ .file = d.retain() }, false) catch {
                    d.release();
                    return;
                };
                copy.sel = d.editor.area.sel;
                copy.rendered = d.rendered;
                e.cols.items[ni].items.append(e.gpa, copy) catch {
                    copy.destroy(e.gpa);
                    return;
                };
                e.show(.{ .col = ni, .idx = e.cols.items[ni].items.items.len - 1 });
            },
            else => e.move(.{ .col = src_col, .idx = from.idx }, ni, null),
        }
    }

    /// Saves files a second after their last edit; asks for a frame then.
    pub fn tick(e: *Editors, c: *ui.Context) void {
        for (e.cols.items) |col| for (col.items.items) |it| switch (it.body) {
            .file => |d| {
                const v = d.editor.area.doc.version;
                if (v != d.seen) {
                    d.seen = v;
                    d.edited_at = c.time;
                    it.preview = false;
                }
                if (!e.auto_save or !d.dirty() or d.path.len == 0) continue;
                const left = d.edited_at + 1.0 - c.time;
                if (left <= 0) d.save() catch {} else c.frameIn(@floatCast(left));
            },
            else => {},
        };
    }

    pub fn reloadChanged(e: *Editors) void {
        for (e.cols.items) |col| for (col.items.items) |it| switch (it.body) {
            .file => |d| _ = d.reloadIfChanged(),
            .image => |im| im.reloadIfChanged(),
            else => {},
        };
    }

    /// A column's strip of tabs.
    pub fn strip(e: *Editors, c: *ui.Context, ci: usize, chrome: ui.Color) void {
        const t = c.theme;
        const col = e.cols.items[ci];
        const bar = ui.div(c).row().wFull().h(34).bg(chrome).itemsCenter();
        var close_at: ?usize = null;
        // The tabs' places, made again as the strips are built.
        var k: usize = e.tab_rects.items.len;
        while (k > 0) {
            k -= 1;
            if (e.tab_rects.items[k].col == ci) _ = e.tab_rects.swapRemove(k);
        }
        // The strip's edge along the bottom, which the tab shown breaks to
        // join the text below it.
        _ = c.leaf(.{ .absolute = true, .offset = .{ .x = 0, .y = 33 }, .width = .fill, .height = .{ .px = 1 }, .background = t.border }, .none, null);
        // The tabs, scrolled sideways when they don't fit.
        c.keyed(col);
        const tabs = ui.div(c).row().grow().h(34).itemsStretch().scrollY();
        const tabs_id = tabs.interaction().id;
        const tabs_rect = c.rects.get(tabs_id);
        const focused_col = ci == e.focus;
        for (col.items.items, 0..) |it, i| {
            c.keyed(it);
            const on = i == col.active;
            const cell = ui.div(c).row().h(34).pl(12).pr(6).gap(7).itemsCenter().borderW(0).bg(if (on) t.background else chrome);
            const hovered = cell.hovered();
            if (!on and hovered) _ = cell.bg(chrome.mix(t.background, 0.5));
            // The strip's bottom edge under the tabs not shown.
            if (!on) _ = c.leaf(.{ .absolute = true, .offset = .{ .x = 0, .y = 33 }, .width = .fill, .height = .{ .px = 1 }, .background = t.border }, .none, null);
            // The accent along the top of the tab shown; faint in a column
            // without the keyboard.
            if (on) _ = c.leaf(.{ .absolute = true, .offset = .{ .x = 0, .y = 0 }, .width = .fill, .height = .{ .px = 2 }, .background = if (focused_col) t.accent else t.muted.alpha(0.4) }, .none, null);
            switch (it.body) {
                .file => |d| icons.file(c, d.name()),
                .image => |im| icons.file(c, std.fs.path.basename(im.path)),
                .changes => icons.sym(c, "diff", .{ .size = 11, .frame = 14, .color = t.warning }),
                .commit => icons.sym(c, "commit", .{ .size = 11, .frame = 14, .color = t.accent }),
                .terminal => icons.sym(c, "terminal", .{ .size = 11, .frame = 14, .color = t.muted }),
            }
            const gone = switch (it.body) {
                .file => |d| d.disk_gone,
                else => false,
            };
            const name_box = ui.div(c).maxW(220).clip();
            ui.text(c, it.title(c), .{ .size = 12.5, .italic = it.preview, .weight = if (on and !gone) .medium else .regular, .color = if (gone) t.danger else if (on) t.text else t.muted });
            // Deleted on disk: struck through.
            if (gone) _ = c.leaf(.{ .absolute = true, .offset = .{ .x = 0, .y = 9 }, .width = .fill, .height = .{ .px = 1 }, .background = t.danger }, .none, null);
            name_box.end();
            // The dot of unsaved changes turns into the cross under the pointer.
            const x = ui.div(c).w(18).h(18).center().rounded(4).hover(t.surface_hover);
            const x_hovered = x.hovered();
            if (it.dirty() and !x_hovered) {
                _ = c.leaf(.{ .width = .{ .px = 8 }, .height = .{ .px = 8 }, .radius = 4, .background = t.text.alpha(0.7) }, .none, null);
            } else if (on or hovered or x_hovered) {
                icons.sym(c, "xmark", .{ .size = 10, .color = t.muted });
            }
            const xi = x.interaction();
            x.end();
            ui.tooltip(c, xi, c.print("Close {s}", .{it.title(c)}));
            const ia = cell.interaction();
            cell.end();
            // A line between the tabs.
            _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .fill, .background = t.border }, .none, null);
            if (!xi.hovered) ui.tooltip(c, ia, switch (it.body) {
                .terminal => "Terminal",
                else => if (it.path()) |p| (if (e.root.len > 0) fs.relative(e.root, p) else p) else it.title(c),
            });
            if (ia.rect) |r| {
                e.tab_rects.append(e.gpa, .{ .col = ci, .idx = i, .rect = r }) catch {};
                // Bring the tab shown into view, once as it is chosen.
                if (on and col.revealed != it) if (tabs_rect) |tr| {
                    const now = c.scroll.get(tabs_id) orelse 0;
                    const left = r.x - tr.x + now;
                    const to = if (left < now) left else if (left + r.w > now + tr.w) left + r.w - tr.w else now;
                    c.scroll.put(c.gpa, tabs_id, @max(0, to)) catch {};
                    col.revealed = it;
                    if (to != now) c.changed = true;
                };
            }
            // The middle button closes a tab, as in browsers.
            if (xi.clicked or (ia.hovered and c.input.middle_pressed)) {
                close_at = i;
            } else if (ia.double_clicked) {
                it.preview = false;
            } else if (ia.clicked) {
                e.show(.{ .col = ci, .idx = i });
            }
            if (ia.pressed and e.drag == null and c.input.pressed) e.drag = .{ .from = .{ .col = ci, .idx = i }, .start = c.input.mouse };
            if (ui.contextMenu(c, &e.menu, ia)) |m| {
                defer m.end();
                e.menu_at = .{ .col = ci, .idx = i };
                e.tabMenu(c, m, it);
            }
        }
        tabs.end();
        // A Markdown or SVG file's preview, the column's lock and splitting it.
        const tools = ui.div(c).row().pl(4).pr(6).gap(2).itemsCenter();
        if (col.current()) |cur| switch (cur.body) {
            .file => |d| if (@import("viewer.zig").isMarkdown(d.path) or @import("viewer.zig").isSvg(d.path)) {
                const b = ui.div(c).row().h(24).px(7).gap(5).itemsCenter().rounded(4).hover(t.surface_hover);
                icons.sym(c, if (d.rendered) "chevron.left.forwardslash.chevron.right" else "photo", .{ .size = 10.5, .color = if (b.hovered()) t.text else t.muted });
                ui.text(c, if (d.rendered) "Source" else "Preview", .{ .size = 11.5, .color = if (b.hovered()) t.text else t.muted });
                const bi = b.interaction();
                b.end();
                ui.tooltip(c, bi, if (d.rendered) "Show Source (Ctrl+Shift+V)" else "Show Preview (Ctrl+Shift+V)");
                if (bi.clicked) {
                    d.rendered = !d.rendered;
                    // A file in two columns: this tab's alone.
                    if (cur.rendered != null) cur.rendered = d.rendered;
                    c.changed = true;
                }
            },
            else => {},
        };
        if (col.locked) if (toolButton(c, "lock", "Unlock Column")) {
            col.locked = false;
            c.changed = true;
        };
        if (toolButton(c, "columns", "Split Right (Ctrl+\\)")) if (col.items.items.len > 0) e.splitRight(.{ .col = ci, .idx = @min(col.active, col.items.items.len - 1) });
        tools.end();
        const bi = bar.interaction();
        bar.end();
        if (ci < e.strip_rects.len) if (bi.rect) |r| {
            e.strip_rects[ci] = r;
        };
        // The strip's own menu, past the tabs: the column's lock.
        if (ui.contextMenu(c, &e.strip_menu, bi)) |m| {
            defer m.end();
            if (m.item(if (col.locked) "Unlock Column" else "Lock Column", .{})) col.locked = !col.locked;
            c.changed = true;
        }
        if (close_at) |i| {
            e.close(.{ .col = ci, .idx = i });
            c.changed = true;
        }
    }

    fn toolButton(c: *ui.Context, icon: []const u8, tip: []const u8) bool {
        const b = ui.div(c).w(26).h(24).center().rounded(4).hover(c.theme.surface_hover);
        icons.sym(c, icon, .{ .size = 11.5, .color = if (b.hovered()) c.theme.text else c.theme.muted });
        const bi = b.interaction();
        b.end();
        ui.tooltip(c, bi, tip);
        return bi.clicked;
    }

    /// Moves a tab to the column beside it, `by` one right or left, making
    /// that column when there is none (the Go app's `moveTabBy`).
    fn moveBy(e: *Editors, l: Loc, right: bool) void {
        if (right) {
            if (l.col + 1 >= e.cols.items.len) {
                const ni = e.addColumn(l.col + 1) catch return;
                return e.move(l, ni, null);
            }
            return e.move(l, l.col + 1, null);
        }
        if (l.col == 0) {
            _ = e.addColumn(0) catch return;
            return e.move(.{ .col = 1, .idx = l.idx }, 0, null);
        }
        e.move(l, l.col - 1, null);
    }

    fn tabMenu(e: *Editors, c: *ui.Context, m: *ui.MenuPanel, it: *Item) void {
        const l = e.menu_at;
        const col = e.cols.items[l.col];
        const alone = col.items.items.len < 2;
        if (m.item("Close", .{ .shortcut = ui.keys.label("⌘W") })) {
            e.close(l);
            c.changed = true;
            return;
        }
        if (m.item("Close Others", .{ .disabled = alone })) e.closeWhere(l.col, it, .others);
        if (m.item("Close All", .{})) e.closeWhere(l.col, null, .all);
        m.separator();
        if (m.item(if (col.locked) "Unlock Column" else "Lock Column", .{})) col.locked = !col.locked;
        if (m.item("Split Right", .{ .shortcut = ui.keys.label("⌘\\") })) e.splitRight(l);
        if (m.item("Move to Next Column", .{ .disabled = alone and l.col + 1 == e.cols.items.len })) e.moveBy(l, true);
        if (m.item("Move to Previous Column", .{ .disabled = alone and l.col == 0 })) e.moveBy(l, false);
        switch (it.body) {
            .terminal => |t| {
                if (!col.locked) if (m.item("Move to Locked Right Column", .{})) {
                    _ = e.take(l);
                    e.gpa.destroy(it);
                    e.request = .{ .to_locked = t };
                };
                if (m.item("Move to Panel", .{})) {
                    _ = e.take(l);
                    e.gpa.destroy(it);
                    e.request = .{ .to_panel = t };
                }
            },
            else => {
                m.separator();
                const p = it.path();
                switch (it.body) {
                    .file => |d| if (@import("viewer.zig").isMarkdown(d.path) or @import("viewer.zig").isSvg(d.path)) {
                        if (m.item(if (d.rendered) "Show Source" else "Show Preview", .{})) {
                            d.rendered = !d.rendered;
                            if (it.rendered != null) it.rendered = d.rendered;
                        }
                    },
                    else => {},
                }
                if (p) |path| if (m.item("Open Changes", .{})) {
                    e.request = .{ .open_changes = path };
                };
                if (m.item("Reveal in Explorer", .{ .disabled = p == null })) e.request = .{ .reveal = p.? };
                if (m.item("Reveal in File Explorer", .{ .disabled = p == null })) myzig.shell.showInFolder(p.?);
                if (m.item("Copy Path", .{ .disabled = p == null })) e.request = .{ .copy_path = p.? };
            },
        }
        c.changed = true;
    }

    /// Ends a tab drag as the pointer is let go (`tabdrag.zig`).
    pub fn endDrag(e: *Editors, c: *ui.Context) void {
        @import("tabdrag.zig").endDrag(e, c);
    }
};
