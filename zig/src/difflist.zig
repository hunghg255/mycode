//! Diffs of several files in one scroll, as Go MyCode's Changes tab: each
//! file under a header with its path, its state and the lines added and
//! removed (folded by a click, and at first past 2,000 lines), each run of
//! changes under an `@@` line with buttons to stage, unstage or discard it,
//! three unchanged lines around them, side by side or in one column, and
//! review comments under their lines. Files are read as they come into view.
//! The keys are a pager's. A commit's tab is made of it too.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const icons = @import("icons.zig");
const hunks = @import("hunks.zig");
const symbols = @import("symbols.zig");
const Review = @import("review.zig").Review;

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
    syms: []symbols.Symbol = &.{},
    added: usize = 0,
    deleted: usize = 0,
    loaded: bool = false,
    folded: bool = false,
    /// A submodule: its sides are the commits it is at; it opens as a
    /// folder and isn't discarded.
    sub: bool = false,
};

pub const Event = union(enum) {
    none,
    /// Opens the file (relative) at a line (from 1).
    open: struct { path: []const u8, line: usize },
    stage_hunk: struct { entry: usize, hunk: usize },
    unstage_hunk: struct { entry: usize, hunk: usize },
    discard_hunk: struct { entry: usize, hunk: usize },
    stage_file: usize,
    unstage_file: usize,
    discard_file: usize,
    /// Comment on rows: the new file's lines, and the rows as a diff.
    comment: struct { entry: usize, first: usize, last: usize, snippet: []const u8 },
    delete_comment: usize,
    edit_comment: usize,
    send_review,
};

/// Reads a side's text: the app's (a blob, or the open file's text).
pub const Reader = struct {
    ctx: *anyopaque,
    read: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, spec: []const u8, path: []const u8) []u8,
};

pub const Layout = enum { auto, split, inline_ };

/// A row of the scroll.
const Ref = union(enum) {
    header: usize,
    loading: usize,
    hunk: struct { entry: usize, hunk: usize, row: usize },
    /// A row of a diff, or a piece of it past the first when lines wrap.
    row: struct { entry: usize, row: usize, part: u16 = 0 },
    comment: struct { entry: usize, index: usize },
};

pub const DiffList = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    /// The row chosen, and where a range of rows began.
    sel: usize = 0,
    anchor: usize = 0,
    /// Buttons to stage and discard: the Changes tab's, not a commit's.
    editable: bool = true,
    layout: Layout = .auto,
    /// Set when the Layout button chose another, for the app to keep.
    layout_chosen: bool = false,
    layout_menu: ui.Menu = .{},
    /// The editor's font: OpenType features and weight.
    features: []const u8 = "",
    weight: u16 = 0,
    /// Long lines wrap: this tab's choice, else the Word Wrap setting's.
    wrap: ?bool = null,
    wrap_setting: bool = false,
    /// Every unchanged line shows, rather than three around the changes.
    full: bool = false,
    /// Characters a side has room for, as lines wrap.
    cols: usize = 0,
    /// The entry at the top of the view, which source control follows.
    top_entry: ?usize = null,
    /// Review comments wait to be sent (the bar's Send button).
    reviewing: bool = false,
    /// The rows of the last frame, and those built.
    refs: std.ArrayList(Ref) = .empty,
    first_built: usize = 0,
    last_built: usize = 0,
    width: f32 = 800,
    /// Show this entry's header at the top in the next frame.
    reveal_entry: ?usize = null,
    scroll_to: ?usize = null,
    focus_id: u64 = 0,
    menu: ui.Menu = .{},
    selected_entry: usize = 0,

    pub fn deinit(dl: *DiffList) void {
        dl.clear();
        dl.entries.deinit(dl.gpa);
        dl.refs.deinit(dl.gpa);
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
        gpa.free(e.syms);
    }

    /// Marks the entry added last as a submodule, or not.
    pub fn markSub(dl: *DiffList, sub: bool) void {
        if (dl.entries.items.len > 0) dl.entries.items[dl.entries.items.len - 1].sub = sub;
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

    /// The entry the selection is in.
    pub fn current(dl: *DiffList) ?*Entry {
        if (dl.entries.items.len == 0) return null;
        return &dl.entries.items[@min(dl.selected_entry, dl.entries.items.len - 1)];
    }

    /// Shows the entry of a path (the first, staged before unstaged).
    pub fn select(dl: *DiffList, path: []const u8) void {
        for (dl.entries.items, 0..) |e, i| if (std.mem.eql(u8, e.path, path)) {
            dl.selected_entry = i;
            dl.reveal_entry = i;
            return;
        };
    }

    /// Reads the sides again of the entries read (a file changed).
    pub fn reload(dl: *DiffList, r: Reader) void {
        for (dl.entries.items) |*e| if (e.loaded) dl.load(e, r);
    }

    /// Reads again the work tree's side of the entries showing it: the
    /// diff follows a file as it is typed.
    pub fn follow(dl: *DiffList, r: Reader) void {
        for (dl.entries.items) |*e| if (e.loaded and std.mem.eql(u8, e.new_spec, "@")) {
            const new = r.read(r.ctx, dl.gpa, e.new_spec, e.path);
            if (std.mem.eql(u8, new, e.new_text)) {
                dl.gpa.free(new);
                continue;
            }
            dl.gpa.free(e.new_text);
            e.new_text = new;
            if (e.dv) |*d| {
                d.set(e.old_text, new) catch {};
                const st = d.stats();
                e.added = st.added;
                e.deleted = st.deleted;
            }
        };
    }

    pub fn load(dl: *DiffList, e: *Entry, r: Reader) void {
        const old = r.read(r.ctx, dl.gpa, e.old_spec, e.path);
        const new = r.read(r.ctx, dl.gpa, e.new_spec, e.path);
        if (e.loaded and std.mem.eql(u8, old, e.old_text) and std.mem.eql(u8, new, e.new_text)) {
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
        dl.gpa.free(e.syms);
        e.syms = symbols.find(dl.gpa, e.new_text, std.mem.endsWith(u8, e.path, ".md")) catch &.{};
        if (e.dv) |*d| {
            const st = d.stats();
            if (!e.loaded and st.added + st.deleted > 2000) e.folded = true;
            e.added = st.added;
            e.deleted = st.deleted;
        }
        e.loaded = true;
    }

    fn split(dl: *const DiffList, c: *ui.Context, size: f32) bool {
        return switch (dl.layout) {
            .split => true,
            .inline_ => false,
            // Side by side when each side has room for 80 columns.
            .auto => dl.width / 2 >= 80 * c.text.width("0", .{ .size = size, .mono = true }) + 70,
        };
    }

    /// The rows of every entry, made again each frame.
    fn build(dl: *DiffList, c: *ui.Context, review: ?*const Review, split_mode: bool) void {
        dl.refs.clearRetainingCapacity();
        for (dl.entries.items, 0..) |*e, ei| {
            dl.refs.append(dl.gpa, .{ .header = ei }) catch return;
            if (e.folded) continue;
            if (!e.loaded) {
                dl.refs.append(dl.gpa, .{ .loading = ei }) catch return;
                continue;
            }
            const d = &(e.dv orelse continue);
            d.setMode(if (split_mode) .split else .unified);
            d.build();
            if (dl.full) for (d.rows.items) |row| if (row.kind == .gap and row.hidden > 0) {
                d.expandAll();
                d.build();
                break;
            };
            const wrap = dl.wrap orelse dl.wrap_setting;
            if (wrap) dl.cols = ui.diffWrapColumns(c, d, .{ .size = 12.5, .digits = 4 }, dl.width, split_mode);
            var hunk: usize = 0;
            var prev_change = false;
            for (d.rows.items, 0..) |row, ri| {
                const change = row.kind == .added or row.kind == .deleted or row.new_kind == .added;
                if (change and !prev_change) {
                    dl.refs.append(dl.gpa, .{ .hunk = .{ .entry = ei, .hunk = hunk, .row = ri } }) catch return;
                    hunk += 1;
                }
                prev_change = change;
                const parts = if (wrap) ui.diffRowParts(d, ri, dl.cols) else 1;
                for (0..parts) |part| dl.refs.append(dl.gpa, .{ .row = .{ .entry = ei, .row = ri, .part = @intCast(part) } }) catch return;
                // Comments end on a new line: under it.
                if (review) |rv| if (row.new) |n| for (rv.list.items, 0..) |cm, ci| {
                    if (cm.outdated or cm.last != n or !std.mem.eql(u8, cm.path, e.path)) continue;
                    dl.refs.append(dl.gpa, .{ .comment = .{ .entry = ei, .index = ci } }) catch return;
                };
            }
        }
        if (dl.sel >= dl.refs.items.len) dl.sel = dl.refs.items.len -| 1;
        if (dl.anchor >= dl.refs.items.len) dl.anchor = dl.sel;
    }

    fn entryOf(dl: *const DiffList, i: usize) usize {
        return switch (dl.refs.items[i]) {
            .header => |e| e,
            .loading => |e| e,
            .hunk => |h| h.entry,
            .row => |r| r.entry,
            .comment => |cm| cm.entry,
        };
    }

    /// The hunk a row is in (the last `@@` at or above it, in its entry).
    fn hunkAt(dl: *const DiffList, i: usize) ?struct { entry: usize, hunk: usize } {
        const ei = dl.entryOf(i);
        var k = i + 1;
        while (k > 0) {
            k -= 1;
            switch (dl.refs.items[k]) {
                .hunk => |h| return .{ .entry = h.entry, .hunk = h.hunk },
                .header => return null,
                else => {},
            }
            if (dl.entryOf(k) != ei) return null;
        }
        return null;
    }

    fn moveTo(dl: *DiffList, i: usize, extend: bool) void {
        dl.sel = @min(i, dl.refs.items.len -| 1);
        if (!extend) dl.anchor = dl.sel;
        dl.selected_entry = if (dl.refs.items.len > 0) dl.entryOf(dl.sel) else 0;
        // Keep it in view.
        if (dl.sel < dl.first_built + 4 or dl.sel + 4 > dl.last_built) dl.scroll_to = dl.sel -| 4;
    }

    fn next(dl: *const DiffList, comptime tag: std.meta.Tag(Ref), forward: bool) ?usize {
        var i = dl.sel;
        while (true) {
            if (forward) {
                i += 1;
                if (i >= dl.refs.items.len) return null;
            } else {
                if (i == 0) return null;
                i -= 1;
            }
            if (dl.refs.items[i] == tag) return i;
        }
    }

    /// The new file's line of a row: its own, or the nearest above.
    fn newLine(dl: *const DiffList, i: usize) ?usize {
        var k = i + 1;
        while (k > 0) {
            k -= 1;
            switch (dl.refs.items[k]) {
                .row => |r| {
                    const e = &dl.entries.items[r.entry];
                    const d = &(e.dv orelse return null);
                    if (d.rows.items[r.row].new) |n| return n;
                },
                .header => return null,
                else => {},
            }
        }
        return null;
    }

    /// The rows chosen, as a diff (for a comment, for the clipboard).
    fn chosenText(dl: *const DiffList, c: *ui.Context, with_place: bool) ?struct { entry: usize, first: usize, last: usize, text: []const u8 } {
        const lo = @min(dl.sel, dl.anchor);
        const hi = @max(dl.sel, dl.anchor);
        const ei = dl.entryOf(lo);
        var out: std.ArrayList(u8) = .empty;
        const a = c.alloc();
        var first: ?usize = null;
        var last: usize = 0;
        for (lo..hi + 1) |i| switch (dl.refs.items[i]) {
            .row => |r| {
                if (r.entry != ei or r.part > 0) continue;
                const d = &(dl.entries.items[r.entry].dv orelse continue);
                const row = d.rows.items[r.row];
                if (row.kind == .gap) continue;
                if (row.old) |o| if (row.kind == .deleted) {
                    out.print(a, "-{s}\n", .{d.old_lines[o]}) catch {};
                };
                if (row.new) |n| {
                    const k: u8 = if (row.kind == .added or row.new_kind == .added) '+' else ' ';
                    out.print(a, "{c}{s}\n", .{ k, d.new_lines[n] }) catch {};
                    if (first == null) first = n;
                    last = n;
                }
            },
            else => {},
        };
        const f = first orelse (dl.newLine(lo) orelse return null);
        if (first == null) last = f;
        if (with_place) {
            const e = &dl.entries.items[ei];
            const place = if (f == last) c.print("{s}:{d}\n", .{ e.path, f + 1 }) else c.print("{s}:{d}-{d}\n", .{ e.path, f + 1, last + 1 });
            return .{ .entry = ei, .first = f, .last = last, .text = std.mem.concat(a, u8, &.{ place, "```diff\n", out.items, "```\n" }) catch out.items };
        }
        return .{ .entry = ei, .first = f, .last = last, .text = out.items };
    }

    pub fn view(dl: *DiffList, c: *ui.Context, r: Reader, chrome: ui.Color, review: ?*const Review, colors: ?ui.SyntaxColors) Event {
        const t = c.theme;
        var ev: Event = .none;
        const size: f32 = 12.5;
        const opts: ui.DiffViewOptions = .{ .size = size, .colors = colors, .digits = 4, .features = dl.features, .weight_value = dl.weight };
        const row_h = ui.diffRowHeight(c, opts);
        const split_mode = dl.split(c, size);
        dl.build(c, review, split_mode);
        const n = dl.refs.items.len;

        const box = c.open(.{ .direction = .column, .width = .fill, .height = .fill }, null);
        defer c.end();
        const bi = c.interact(box, .{ .focusable = true });
        dl.focus_id = bi.id;
        if (bi.rect) |rc| dl.width = rc.w;
        const focused = bi.focused;
        if (dl.entries.items.len == 0) {
            // As source control says it: the work tree is clean.
            ui.column(c, .{ .width = .fill, .grow = 1, .align_items = .center, .justify = .center, .gap = 6 });
            const ring = ui.div(c).w(52).h(52).roundedFull().center().bg(t.success.alpha(0.13));
            icons.sym(c, "checkmark", .{ .size = 19, .color = t.success });
            ring.end();
            _ = c.leaf(.{ .height = .{ .px = 2 } }, .none, null);
            ui.text(c, "No Changes", .{ .size = 14, .weight = .semibold, .color = t.text });
            ui.text(c, if (dl.editable) "The working tree matches the last commit." else "The commit changes no files.", .{ .size = 12.5, .color = t.muted });
            ui.end(c);
            return ev;
        }
        if (focused) ev = dl.keys(c, n, row_h);
        // The bar: the file in view, the counts, the layout.
        {
            const cur = dl.current().?;
            const bar = ui.div(c).row().wFull().h(30).px(10).gap(8).itemsCenter().bg(chrome);
            defer bar.end();
            icons.file(c, std.fs.path.basename(cur.path));
            ui.text(c, cur.path, .{ .size = 12, .weight = .semibold });
            ui.spacer(c);
            var added: usize = 0;
            var deleted: usize = 0;
            for (dl.entries.items) |e| {
                added += e.added;
                deleted += e.deleted;
            }
            ui.text(c, c.print("{d} file{s}  +{d} −{d}", .{ dl.entries.items.len, if (dl.entries.items.len == 1) "" else "s", added, deleted }), .{ .size = 11, .color = t.muted });
            // As the Go app's: icons with their tooltips.
            if (iconTool(c, "arrow.up", "Previous Change ([)", false)) if (dl.next(.hunk, false)) |i| dl.moveTo(i, false);
            if (iconTool(c, "arrow.down", "Next Change (])", false)) if (dl.next(.hunk, true)) |i| dl.moveTo(i, false);
            if (iconTool(c, "unfold", "Show Full Files", dl.full)) {
                dl.full = !dl.full;
                if (!dl.full) for (dl.entries.items) |*e| if (e.dv) |*d| d.collapseAll();
            }
            const wrapping = dl.wrap orelse dl.wrap_setting;
            if (iconTool(c, "wrap", "Toggle Word Wrap (Alt+Z)", wrapping)) dl.wrap = !wrapping;
            const lb = ui.div(c).h(26).px(6).center().rounded(4).hover(t.surface_hover);
            icons.sym(c, if (dl.layout == .inline_) "rows" else "columns", .{ .size = 10.5, .color = t.muted });
            const li = lb.interaction();
            lb.end();
            ui.tooltip(c, li, "Layout");
            if (ui.buttonMenu(c, &dl.layout_menu, li)) |m| {
                defer m.end();
                const layouts = [_]struct { Layout, []const u8 }{ .{ .auto, "Side by Side When Wide" }, .{ .split, "Side by Side" }, .{ .inline_, "Inline" } };
                for (layouts) |l| if (m.item(l[1], .{ .checked = dl.layout == l[0] })) {
                    dl.layout = l[0];
                    dl.layout_chosen = true;
                };
                m.separator();
                if (m.item("Fold All Files", .{})) for (dl.entries.items) |*e| {
                    e.folded = true;
                };
                if (m.item("Unfold All Files", .{})) for (dl.entries.items) |*e| {
                    e.folded = false;
                };
            }
            if (iconTool(c, if (cur.sub) "folder" else "doc.text", if (cur.sub) "Open Folder (E)" else "Open File (E)", false)) ev = .{ .open = .{ .path = cur.path, .line = 1 } };
            if (dl.reviewing and ui.button(c, "Send Review", .{ .variant = .primary, .size = 11 }).clicked) ev = .send_review;
        }
        // Where to scroll: an entry to show, a row to keep in view.
        if (dl.reveal_entry) |re| {
            dl.reveal_entry = null;
            for (dl.refs.items, 0..) |rf, i| if (rf == .header and rf.header == re) {
                dl.sel = i;
                dl.anchor = i;
                dl.scroll_to = i;
                break;
            };
        }
        const to: ?f32 = if (dl.scroll_to) |i| @as(f32, @floatFromInt(i)) * row_h else null;
        dl.scroll_to = null;
        const list_id = c.peekId(null);
        const top_row: usize = @intFromFloat(@max(0, @floor((to orelse c.scroll.get(list_id) orelse 0) / row_h)));
        dl.top_entry = if (top_row < n) dl.entryOf(top_row) else null;
        const sel_hunk = if (dl.sel < n) dl.hunkAt(dl.sel) else null;
        var rows = ui.list(c, .{ .count = n, .row_height = row_h, .scroll_to = to });
        var first: usize = std.math.maxInt(usize);
        var last: usize = 0;
        var to_load: ?usize = null;
        while (rows.next()) |i| {
            first = @min(first, i);
            last = @max(last, i);
            const rf = dl.refs.items[i];
            const chosen = focused and i >= @min(dl.sel, dl.anchor) and i <= @max(dl.sel, dl.anchor);
            const cell = ui.div(c).row().wFull().h(row_h).bg(if (chosen) t.accent.alpha(0.14) else .transparent);
            switch (rf) {
                .header => |ei| {
                    const a = dl.header(c, ei, row_h, chrome);
                    if (a != .none) ev = a;
                },
                .loading => |ei| {
                    to_load = to_load orelse ei;
                    ui.text(c, "   Reading…", .{ .size = 11, .color = t.muted });
                },
                .hunk => |h| {
                    const a = dl.hunkRow(c, h.entry, h.hunk, row_h);
                    if (a != .none) ev = a;
                },
                .row => |rr| {
                    const e = &dl.entries.items[rr.entry];
                    if (e.dv) |*d| {
                        ui.diffRowPart(c, d, rr.row, opts, rr.part, if (dl.wrap orelse dl.wrap_setting) dl.cols else 0);
                        const row = d.rows.items[rr.row];
                        // The change the selection is in: a bar along the left.
                        const change = row.kind == .added or row.kind == .deleted or row.new_kind == .added;
                        if (change and sel_hunk != null) if (dl.hunkAt(i)) |h| if (h.entry == sel_hunk.?.entry and h.hunk == sel_hunk.?.hunk) {
                            _ = c.leaf(.{ .absolute = true, .offset = .{ .x = 0, .y = 0 }, .width = .{ .px = 3 }, .height = .fill, .background = t.accent }, .none, null);
                        };
                        // A comment on the line under the pointer: "+".
                        if (rr.part == 0 and row.new != null and cell.hovered()) {
                            const plus = ui.div(c).absolute().offset(2, 1).w(row_h - 2).h(row_h - 2).center().rounded(4).bg(t.accent);
                            ui.text(c, "+", .{ .size = 11, .weight = .bold, .color = t.accent_text });
                            if (plus.clicked()) {
                                dl.sel = i;
                                dl.anchor = i;
                                if (dl.chosenText(c, false)) |ct| ev = .{ .comment = .{ .entry = ct.entry, .first = ct.first, .last = ct.last, .snippet = ct.text } };
                            }
                            plus.end();
                        }
                    }
                },
                .comment => |cm| if (review) |rv| if (cm.index < rv.list.items.len) {
                    const k = rv.list.items[cm.index];
                    // A card, as the Go app's: a stripe of its color, its head, its text's first line.
                    ui.row(c, .{ .grow = 1, .height = .fill, .padding = .{ .top = 0, .right = 8, .bottom = 0, .left = 0 }, .gap = 10, .align_items = .center, .background = t.surface });
                    _ = c.leaf(.{ .width = .{ .px = 3 }, .height = .fill, .background = if (k.outdated) t.warning else t.accent }, .none, null);
                    const head = ui.div(c).w(0).grow();
                    switch (@import("review.zig").cardHead(c, k)) {
                        .edit => ev = .{ .edit_comment = cm.index },
                        .delete => ev = .{ .delete_comment = cm.index },
                        .none => {},
                    }
                    head.end();
                    const words = ui.div(c).w(0).grow().clip();
                    ui.text(c, std.mem.sliceTo(k.text, '\n'), .{ .size = 12 });
                    words.end();
                    ui.end(c);
                },
            }
            const ci = cell.interaction();
            cell.end();
            if (ci.double_clicked) {
                if (dl.lineOf(i)) |line| ev = .{ .open = .{ .path = dl.entries.items[dl.entryOf(i)].path, .line = line + 1 } };
            } else if (ci.pressed and c.input.pressed) {
                dl.sel = i;
                if (!c.input.shift) dl.anchor = i;
                dl.selected_entry = dl.entryOf(i);
                c.focus = dl.focus_id;
            }
        }
        rows.end();
        // The header of the file at the top, kept there as its rows scroll.
        if (dl.top_entry) |te| if (top_row < n and dl.refs.items[top_row] != .header) {
            const pin = ui.div(c).absolute().offset(0, 30).wFull().h(row_h);
            const a = dl.header(c, te, row_h, chrome);
            if (a != .none) ev = a;
            pin.end();
        };
        if (first != std.math.maxInt(usize)) {
            dl.first_built = first;
            dl.last_built = last;
        }
        // Files are read as they come into view, one a frame.
        if (to_load) |ei| {
            dl.load(&dl.entries.items[ei], r);
            c.changed = true;
        }
        return ev;
    }

    /// The new file's line a row shows (for opening the file there).
    fn lineOf(dl: *const DiffList, i: usize) ?usize {
        return switch (dl.refs.items[i]) {
            .row, .comment => dl.newLine(i),
            .hunk => |h| blk: {
                const e = &dl.entries.items[h.entry];
                const d = &(e.dv orelse break :blk null);
                if (h.hunk < d.hunks.len) break :blk d.hunks[h.hunk].b0;
                break :blk null;
            },
            else => 0,
        };
    }

    fn header(dl: *DiffList, c: *ui.Context, ei: usize, row_h: f32, chrome: ui.Color) Event {
        const t = c.theme;
        var ev: Event = .none;
        const e = &dl.entries.items[ei];
        const row = ui.div(c).row().wFull().h(row_h).px(8).gap(6).itemsCenter().bg(chrome).hover(t.surface_hover);
        icons.sym(c, if (e.folded) "chevron.right" else "chevron.down", .{ .size = 9, .color = t.muted });
        if (e.sub) icons.sym(c, "folder", .{ .size = 12, .color = t.accent }) else icons.file(c, std.fs.path.basename(e.path));
        if (std.fs.path.dirnamePosix(e.path)) |d| ui.text(c, c.print("{s}/", .{d}), .{ .size = 12, .color = t.muted });
        ui.text(c, std.fs.path.basenamePosix(e.path), .{ .size = 12, .weight = .semibold });
        const badge = ui.div(c).px(5).h(16).itemsCenter().rounded(3).bg(t.accent.alpha(0.16));
        ui.text(c, if (e.orig) |o| c.print("{c} ← {s}", .{ e.badge, o }) else c.print("{c}", .{e.badge}), .{ .size = 10 });
        badge.end();
        if (e.staged) ui.text(c, "staged", .{ .size = 10, .color = t.muted });
        if (e.loaded) {
            ui.text(c, c.print("+{d}", .{e.added}), .{ .size = 11, .color = t.success, .mono = true });
            ui.text(c, c.print("−{d}", .{e.deleted}), .{ .size = 11, .color = t.danger, .mono = true });
            // A bar of five blocks: green for lines added, red for removed.
            const total = e.added + e.deleted;
            const green = if (total == 0) 0 else (e.added * 5 + total / 2) / total;
            for (0..5) |k| _ = c.leaf(.{ .width = .{ .px = 7 }, .height = .{ .px = 7 }, .radius = 1, .background = if (total == 0) t.border else if (k < green) t.success else t.danger }, .none, null);
        }
        ui.spacer(c);
        var acted = false;
        if (row.hovered() or ei == dl.selected_entry) {
            if (iconTool(c, if (e.sub) "folder" else "doc.text", if (e.sub) "Open Folder" else "Open File", false)) {
                ev = .{ .open = .{ .path = e.path, .line = 1 } };
                acted = true;
            }
            if (dl.editable) {
                if (e.staged) {
                    if (iconTool(c, "minus", "Unstage Changes", false)) {
                        ev = .{ .unstage_file = ei };
                        acted = true;
                    }
                } else {
                    if (e.badge != 'C' and !e.sub and iconTool(c, "arrow.uturn.backward", "Discard Changes…", false)) {
                        ev = .{ .discard_file = ei };
                        acted = true;
                    }
                    if (iconTool(c, "plus", "Stage Changes", false)) {
                        ev = .{ .stage_file = ei };
                        acted = true;
                    }
                }
            }
        }
        if (row.clicked() and !acted) {
            e.folded = !e.folded;
            c.changed = true;
        }
        row.end();
        return ev;
    }

    fn hunkRow(dl: *DiffList, c: *ui.Context, ei: usize, k: usize, row_h: f32) Event {
        const t = c.theme;
        var ev: Event = .none;
        const e = &dl.entries.items[ei];
        const d = &(e.dv orelse return ev);
        const row = ui.div(c).row().wFull().h(row_h).px(10).gap(8).itemsCenter().bg(t.accent.alpha(0.06)).hover(t.accent.alpha(0.12));
        if (k < d.hunks.len) {
            const h = d.hunks[k];
            ui.text(c, c.print("@@ -{d},{d} +{d},{d} @@", .{ h.a0 + 1, h.a1 - h.a0, h.b0 + 1, h.b1 - h.b0 }), .{ .size = 11, .mono = true, .color = t.muted });
            var buf: [4]symbols.Symbol = undefined;
            const around = symbols.around(&buf, e.syms, h.b0);
            if (around.len > 0) ui.text(c, around[around.len - 1].name, .{ .size = 11, .color = t.muted });
        }
        ui.spacer(c);
        if (dl.editable and (row.hovered() or dl.hunkAt(dl.sel) != null and dl.hunkAt(dl.sel).?.entry == ei and dl.hunkAt(dl.sel).?.hunk == k)) {
            if (e.staged) {
                if (hunkTool(c, "minus", "Unstage")) ev = .{ .unstage_hunk = .{ .entry = ei, .hunk = k } };
            } else if (e.badge != 'U' and e.badge != 'C') {
                if (hunkTool(c, "plus", "Stage")) ev = .{ .stage_hunk = .{ .entry = ei, .hunk = k } };
                if (hunkTool(c, "arrow.uturn.backward", "Discard")) ev = .{ .discard_hunk = .{ .entry = ei, .hunk = k } };
            }
        }
        row.end();
        return ev;
    }

    fn keys(dl: *DiffList, c: *ui.Context, n: usize, row_h: f32) Event {
        if (n == 0) return .none;
        const S = ui.Shortcut;
        const page = @max(@as(usize, @intFromFloat(@max(c.size.h - 120, 100) / row_h)) -| 2, 1);
        if (c.shortcut(.{ .key = 'j' }) or c.shortcut(.{ .key = S.down })) dl.moveTo(dl.sel + 1, false);
        if (c.shortcut(.{ .key = 'k' }) or c.shortcut(.{ .key = S.up })) dl.moveTo(dl.sel -| 1, false);
        if (c.shortcut(.{ .key = 'j', .shift = true }) or c.shortcut(.{ .key = S.down, .shift = true })) dl.moveTo(dl.sel + 1, true);
        if (c.shortcut(.{ .key = 'k', .shift = true }) or c.shortcut(.{ .key = S.up, .shift = true })) dl.moveTo(dl.sel -| 1, true);
        if (c.shortcut(.{ .key = ']' })) if (dl.next(.hunk, true)) |i| dl.moveTo(i, false);
        if (c.shortcut(.{ .key = '[' })) if (dl.next(.hunk, false)) |i| dl.moveTo(i, false);
        if (c.shortcut(.{ .key = '.' })) if (dl.next(.header, true)) |i| dl.moveTo(i, false);
        if (c.shortcut(.{ .key = ',' })) if (dl.next(.header, false)) |i| dl.moveTo(i, false);
        if (c.shortcut(.{ .key = ' ' }) or c.shortcut(.{ .key = 'f' }) or c.shortcut(.{ .key = S.page_down })) dl.moveTo(dl.sel + page, false);
        if (c.shortcut(.{ .key = 'b' }) or c.shortcut(.{ .key = S.page_up })) dl.moveTo(dl.sel -| page, false);
        if (c.shortcut(.{ .key = 'd' })) dl.moveTo(dl.sel + page / 2, false);
        if (c.shortcut(.{ .key = 'u' })) dl.moveTo(dl.sel -| (page / 2), false);
        if (c.shortcut(.{ .key = 'g' }) or c.shortcut(.{ .key = S.home })) dl.moveTo(0, false);
        if (c.shortcut(.{ .key = 'g', .shift = true }) or c.shortcut(.{ .key = S.end })) dl.moveTo(n - 1, false);
        if (c.shortcut(.{ .key = S.escape })) dl.anchor = dl.sel;
        const rf = dl.refs.items[dl.sel];
        if (c.shortcut(.{ .key = 'z' }) or c.shortcut(.{ .key = S.enter })) {
            switch (rf) {
                .header => |ei| dl.entries.items[ei].folded = !dl.entries.items[ei].folded,
                .row => |rr| {
                    const d = &(dl.entries.items[rr.entry].dv orelse return .none);
                    const row = d.rows.items[rr.row];
                    if (row.kind == .gap and row.hidden > 0) d.expand(row.run) else if (dl.lineOf(dl.sel)) |line| return .{ .open = .{ .path = dl.entries.items[rr.entry].path, .line = line + 1 } };
                },
                else => {},
            }
            c.changed = true;
        }
        if (c.shortcut(.{ .key = 'e' })) if (dl.lineOf(dl.sel)) |line| return .{ .open = .{ .path = dl.entries.items[dl.entryOf(dl.sel)].path, .line = line + 1 } };
        if (dl.editable and c.shortcut(.{ .key = 's' })) if (dl.hunkAt(dl.sel)) |h| {
            return if (dl.entries.items[h.entry].staged) .{ .unstage_hunk = .{ .entry = h.entry, .hunk = h.hunk } } else .{ .stage_hunk = .{ .entry = h.entry, .hunk = h.hunk } };
        };
        if (c.shortcut(.{ .key = 'c' })) {
            if (rf == .comment) return .{ .edit_comment = rf.comment.index };
            if (dl.chosenText(c, false)) |ct| return .{ .comment = .{ .entry = ct.entry, .first = ct.first, .last = ct.last, .snippet = ct.text } };
        }
        if (c.shortcut(.{ .key = S.delete }) or c.shortcut(.{ .key = S.backspace })) if (rf == .comment) return .{ .delete_comment = rf.comment.index };
        if (c.shortcut(.{ .key = 'c', .cmd = true })) if (dl.chosenText(c, true)) |ct| {
            _ = myzig.clipboard.writeText(ct.text);
        };
        return .none;
    }
};

/// A button of a change: its icon and name, on a ground of its own, its
/// tooltip "Stage this change".
fn hunkTool(c: *ui.Context, icon: []const u8, label: []const u8) bool {
    const t = c.theme;
    const b = ui.div(c).row().h(20).px(7).gap(4).itemsCenter().rounded(4).bg(t.background).border(t.border).hover(t.surface_hover);
    const hot = b.hovered();
    icons.sym(c, icon, .{ .size = 9, .color = if (hot) t.text else t.muted });
    ui.text(c, label, .{ .size = 11.5, .color = if (hot) t.text else t.muted });
    const bi = b.interaction();
    b.end();
    ui.tooltip(c, bi, c.print("{s} this change", .{label}));
    return bi.clicked;
}

/// A button of the diff's bar: its icon, its tooltip, pressed while `on`.
fn iconTool(c: *ui.Context, icon: []const u8, tip: []const u8, on: bool) bool {
    const t = c.theme;
    const b = ui.div(c).h(26).px(6).center().rounded(4).bg(if (on) t.accent.alpha(0.18) else .transparent).hover(t.surface_hover);
    icons.sym(c, icon, .{ .size = 10.5, .color = if (on) t.text else t.muted });
    const bi = b.interaction();
    b.end();
    ui.tooltip(c, bi, tip);
    return bi.clicked;
}

fn tool(c: *ui.Context, label: []const u8) bool {
    return ui.button(c, label, .{ .variant = .ghost, .size = 11 }).clicked;
}
