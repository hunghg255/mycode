//! Quick open (⌘P), as the Go app's: files by a fuzzy match, recent ones
//! first, the characters matched in the accent; `>` runs a command by name
//! ("Group: Title", with its keys as keycaps, and a terminal of each
//! profile), `@` goes to a symbol of the file shown (nested as in it until
//! a name is typed), `:42` or `:42:7` to a line and column; a footer names
//! the keys and the prefixes.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const fs = @import("fs.zig");
const git = @import("git.zig");
const commands = @import("commands.zig");
const icons = @import("icons.zig");
const symbols = @import("symbols.zig");

pub const Pick = union(enum) {
    /// Relative to the workspace, with slashes.
    file: []const u8,
    command: commands.Cmd,
    /// A line, from 1, and a column, from 1 (0: none).
    line: struct { line: usize, col: usize = 0 },
    /// A symbol's line, from 0.
    symbol: usize,
    /// A new terminal of a profile, or the profile made the default.
    new_terminal: usize,
    default_terminal: usize,
};

const Hit = struct { index: usize, score: i32 };

/// A row of `>`: a command, or a terminal profile's.
const Entry = union(enum) { cmd: commands.Cmd, new_terminal: usize, default_terminal: usize };

const max_results = 200;

pub const QuickOpen = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    dialog: ui.OverlayState = .{},
    query: ui.TextBuffer = .{},
    files: [][]const u8 = &.{},
    hits: std.ArrayList(Hit) = .empty,
    entries: std.ArrayList(Entry) = .empty,
    /// Files opened, newest first, relative.
    recent: std.ArrayList([]u8) = .empty,
    /// Commands run, newest first.
    recent_cmds: std.ArrayList(commands.Cmd) = .empty,
    selected: usize = 0,
    /// The selection moved by a key: its row scrolls into view.
    moved: bool = false,
    /// Builds left in which the field takes the keyboard: the dialog
    /// clears the focus as it opens.
    focus: u8 = 0,
    filtered_for: [1024]u8 = undefined,
    filtered_len: ?usize = null,
    /// The symbols of the file shown, for `@`; set by the workbench.
    syms: []const symbols.Symbol = &.{},
    sym_hits: std.ArrayList(usize) = .empty,
    /// The file shown's lines, for `:` (0: no file shown); set by the workbench.
    lines: usize = 0,
    /// The terminal profiles' names, and the default's index.
    profiles: []const @import("termprofiles.zig").Profile = &.{},
    default_profile: usize = 0,
    /// What `>` shows by a command: its key (from keybindings.json or its own).
    key_label: ?*const fn (ctx: *anyopaque, c: *ui.Context, cmd: commands.Cmd) []const u8 = null,
    key_ctx: *anyopaque = undefined,
    /// Whether a command that turns something on has it on, for a check.
    is_on: ?*const fn (ctx: *anyopaque, cmd: commands.Cmd) bool = null,

    pub fn deinit(q: *QuickOpen) void {
        if (q.files.len > 0) fs.freeStrings(q.gpa, q.files);
        q.hits.deinit(q.gpa);
        q.entries.deinit(q.gpa);
        q.sym_hits.deinit(q.gpa);
        for (q.recent.items) |r| q.gpa.free(r);
        q.recent.deinit(q.gpa);
        q.recent_cmds.deinit(q.gpa);
    }

    /// Opens it with `prefix` typed: "" for files, ">" for commands, ":" for a line.
    pub fn show(q: *QuickOpen, prefix: []const u8) void {
        q.reload();
        q.query.set(prefix);
        q.selected = 0;
        q.filtered_len = null;
        q.focus = 6;
        q.dialog.show();
    }

    /// Lists the files again: Git's, else a walk of the folder.
    pub fn reload(q: *QuickOpen) void {
        const files = git.listFiles(q.gpa, q.io, q.root) catch fs.walk(q.gpa, q.io, q.root, 50_000) catch return;
        if (q.files.len > 0) fs.freeStrings(q.gpa, q.files);
        q.files = files;
    }

    pub fn noteOpened(q: *QuickOpen, rel: []const u8) void {
        for (q.recent.items, 0..) |r, i| if (std.mem.eql(u8, r, rel)) {
            q.gpa.free(q.recent.orderedRemove(i));
            break;
        };
        const d = q.gpa.dupe(u8, rel) catch return;
        q.recent.insert(q.gpa, 0, d) catch q.gpa.free(d);
        if (q.recent.items.len > 50) q.gpa.free(q.recent.pop().?);
    }

    pub fn noteRan(q: *QuickOpen, cmd: commands.Cmd) void {
        for (q.recent_cmds.items, 0..) |r, i| if (r == cmd) {
            _ = q.recent_cmds.orderedRemove(i);
            break;
        };
        q.recent_cmds.insert(q.gpa, 0, cmd) catch {};
    }

    fn recentRank(q: *const QuickOpen, rel: []const u8) ?usize {
        for (q.recent.items, 0..) |r, i| if (std.mem.eql(u8, r, rel)) return i;
        return null;
    }

    /// A command's title as the palette shows it: "Group: Title", and
    /// where its title starts (the group in muted text before it).
    fn entryTitle(q: *const QuickOpen, c: *ui.Context, e: Entry) struct { []const u8, usize } {
        return switch (e) {
            .cmd => |cmd| blk: {
                const inf = commands.info(cmd);
                if (inf.menu.len == 0) break :blk .{ inf.title, 0 };
                break :blk .{ c.print("{s}: {s}", .{ inf.menu, inf.title }), inf.menu.len + 2 };
            },
            .new_terminal => |k| .{ c.print("Terminal: New Terminal: {s}", .{q.profiles[k].name}), 10 },
            .default_terminal => |k| .{ c.print("Terminal: Set Default Terminal: {s}", .{q.profiles[k].name}), 10 },
        };
    }

    fn filter(q: *QuickOpen, c: *ui.Context) void {
        const text = q.query.text();
        if (q.filtered_len) |n| if (n == text.len and std.mem.eql(u8, q.filtered_for[0..n], text)) return;
        @memcpy(q.filtered_for[0..@min(text.len, q.filtered_for.len)], text[0..@min(text.len, q.filtered_for.len)]);
        q.filtered_len = @min(text.len, q.filtered_for.len);
        q.selected = 0;
        q.hits.clearRetainingCapacity();
        q.entries.clearRetainingCapacity();
        q.sym_hits.clearRetainingCapacity();
        if (std.mem.startsWith(u8, text, "@")) {
            const needle = std.mem.trim(u8, text[1..], " ");
            for (q.syms, 0..) |sy, i| if (score(sy.name, needle) != null) q.sym_hits.append(q.gpa, i) catch {};
            return;
        }
        if (std.mem.startsWith(u8, text, ">")) {
            const needle = std.mem.trim(u8, text[1..], " ");
            // The commands run last first, until a name is typed.
            if (needle.len == 0) for (q.recent_cmds.items) |cmd| q.entries.append(q.gpa, .{ .cmd = cmd }) catch {};
            var scored: std.ArrayList(struct { Entry, i32 }) = .empty;
            defer scored.deinit(q.gpa);
            for (commands.all) |cmd| {
                if (needle.len == 0 and std.mem.indexOfScalar(commands.Cmd, q.recent_cmds.items, cmd) != null) continue;
                const s = score(q.entryTitle(c, .{ .cmd = cmd })[0], needle) orelse continue;
                scored.append(q.gpa, .{ .{ .cmd = cmd }, s }) catch {};
            }
            for (0..q.profiles.len) |k| {
                for ([_]Entry{ .{ .new_terminal = k }, .{ .default_terminal = k } }) |e| {
                    const s = score(q.entryTitle(c, e)[0], needle) orelse continue;
                    scored.append(q.gpa, .{ e, s }) catch {};
                }
            }
            // In the palette's order until a name is typed, then by how well they match.
            if (needle.len > 0) std.mem.sort(@TypeOf(scored.items[0]), scored.items, {}, struct {
                fn lt(_: void, a: @TypeOf(scored.items[0]), b: @TypeOf(scored.items[0])) bool {
                    return a[1] > b[1];
                }
            }.lt);
            for (scored.items) |e| q.entries.append(q.gpa, e[0]) catch {};
            return;
        }
        if (std.mem.startsWith(u8, text, ":")) return;
        for (q.files, 0..) |f, i| {
            var s = score(f, text) orelse continue;
            if (q.recentRank(f)) |r| s += 1000 - @as(i32, @intCast(r));
            q.hits.append(q.gpa, .{ .index = i, .score = s }) catch break;
        }
        std.mem.sort(Hit, q.hits.items, q, struct {
            fn lt(qq: *QuickOpen, a: Hit, b: Hit) bool {
                if (a.score != b.score) return a.score > b.score;
                return qq.files[a.index].len < qq.files[b.index].len;
            }
        }.lt);
        if (q.hits.items.len > max_results) q.hits.shrinkRetainingCapacity(max_results);
    }

    fn count(q: *const QuickOpen) usize {
        const text = q.query.text();
        if (std.mem.startsWith(u8, text, ">")) return q.entries.items.len;
        if (std.mem.startsWith(u8, text, "@")) return q.sym_hits.items.len;
        if (std.mem.startsWith(u8, text, ":")) return 0;
        return q.hits.items.len;
    }

    pub fn view(q: *QuickOpen, c: *ui.Context) ?Pick {
        const d = ui.dialog(c, &q.dialog, .{ .width = .{ .px = 600 }, .padding = .all(0), .gap = 0 }) orelse return null;
        defer d.end();
        // Under the title bar, as the Go app's, rather than in the middle.
        d.backdropStyle().justify = .start;
        d.backdropStyle().padding.top = c.title_bar_height + 8;
        d.panelStyle().radius = 10;
        d.panelStyle().clip = true;
        const t = c.theme;
        const text = q.query.text();
        const mode: enum { files, commands, symbols, line } = if (std.mem.startsWith(u8, text, ">"))
            .commands
        else if (std.mem.startsWith(u8, text, "@"))
            .symbols
        else if (std.mem.startsWith(u8, text, ":"))
            .line
        else
            .files;
        var pick: ?Pick = null;
        // The field, with the mode's icon.
        const head = ui.div(c).row().wFull().px(14).py(10).gap(10).itemsCenter();
        icons.sym(c, switch (mode) {
            .commands => "chevron.right",
            .symbols => "circle",
            else => "magnifyingglass",
        }, .{ .size = 12, .color = t.muted });
        const fid = c.peekId(null);
        if (q.focus > 0) {
            if (c.focus != fid) c.changed = true;
            c.focus = fid;
            q.focus -= 1;
        }
        const field = ui.textField(c, &q.query, .{ .width = .fill, .bare = true, .size = 14, .label = "Quick Open", .placeholder = switch (mode) {
            .commands => "Run a command by name",
            .symbols => "Go to a symbol by name",
            else => "Search files by name",
        } });
        head.end();
        _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = t.border }, .none, null);
        q.filter(c);
        const n = q.count();
        if (c.shortcut(.{ .key = ui.Shortcut.down })) {
            q.selected = if (n == 0) 0 else @min(q.selected + 1, n - 1);
            q.moved = true;
        }
        if (c.shortcut(.{ .key = ui.Shortcut.up })) {
            q.selected -|= 1;
            q.moved = true;
        }
        if (mode == .line) {
            const lc = lineCol(text);
            const hint = if (q.lines == 0)
                "Open a file to go to a line"
            else if (lc.line > 0)
                (if (lc.col > 0) c.print("Go to line {d}, column {d}", .{ lc.line, lc.col }) else c.print("Go to line {d}", .{lc.line}))
            else
                c.print("Type a line number between 1 and {d}", .{q.lines});
            emptyText(c, hint);
            if (field.submitted and lc.line > 0 and q.lines > 0) pick = .{ .line = .{ .line = lc.line, .col = lc.col } };
        } else if (n == 0) {
            emptyText(c, switch (mode) {
                .commands => "No matching commands",
                .symbols => if (q.lines == 0) "Open a file to go to its symbols" else "No matching symbols",
                else => "No matching files",
            });
        } else {
            // The row chosen by a key, scrolled into view.
            const list_h = @min(@as(f32, @floatFromInt(n)) * 30 + 12, 380);
            const lid = c.peekId(null);
            var scroll_to: ?f32 = null;
            if (q.moved) {
                const at = c.scroll.get(lid) orelse 0;
                const top = @as(f32, @floatFromInt(q.selected)) * 30;
                if (top < at) scroll_to = top else if (top + 30 + 12 > at + list_h) scroll_to = top + 30 + 12 - list_h;
            }
            var rows = ui.list(c, .{ .count = n, .row_height = 30, .height = .{ .px = list_h }, .padding = .all(6), .scroll_to = scroll_to });
            while (rows.next()) |i| {
                const on = i == q.selected;
                const row = ui.div(c).row().wFull().h(30).px(10).gap(10).itemsCenter().rounded(6).bg(if (on) t.accent.alpha(0.2) else .transparent).hover(t.surface_hover);
                switch (mode) {
                    .commands => q.commandRow(c, q.entries.items[i], std.mem.trim(u8, text[1..], " ")),
                    .symbols => q.symbolRow(c, q.syms[q.sym_hits.items[i]], std.mem.trim(u8, text[1..], " ")),
                    else => fileRow(c, q.files[q.hits.items[i].index], text),
                }
                const ri = row.interaction();
                row.end();
                if (ri.clicked) {
                    q.selected = i;
                    pick = q.pickAt(i);
                }
            }
            rows.end();
            q.moved = false;
        }
        footer(c, mode == .line, switch (mode) {
            .commands => "run",
            .symbols => "go to",
            else => "open",
        }, "", mode == .files);
        if (field.submitted and n > 0 and mode != .line) pick = q.pickAt(q.selected);
        if (pick != null) q.dialog.close();
        return pick;
    }

    fn commandRow(q: *QuickOpen, c: *ui.Context, e: Entry, needle: []const u8) void {
        const t = c.theme;
        const title, const group = q.entryTitle(c, e);
        const box = ui.div(c).grow().w(0).clip();
        matched(c, title, needle, 0, title.len, group, 13, t.text);
        box.end();
        switch (e) {
            .cmd => |cmd| {
                if (q.is_on) |f| if (f(q.key_ctx, cmd)) icons.sym(c, "checkmark", .{ .size = 12, .color = t.accent });
                const keys = if (q.key_label) |f| f(q.key_ctx, c, cmd) else "";
                keycaps(c, keys);
            },
            .default_terminal => |k| if (k == q.default_profile) icons.sym(c, "checkmark", .{ .size = 12, .color = t.accent }),
            else => {},
        }
    }

    fn symbolRow(_: *QuickOpen, c: *ui.Context, sy: symbols.Symbol, needle: []const u8) void {
        const t = c.theme;
        // Listed in order, symbols are indented as in the file.
        if (needle.len == 0 and sy.indent > 0) _ = c.leaf(.{ .width = .{ .px = @as(f32, @floatFromInt(@min(sy.indent / 2, 24))) * 4 } }, .none, null);
        icons.sym(c, switch (sy.kind) {
            .function => "chevron.left.forwardslash.chevron.right",
            .type => "cube",
            .heading => "textformat",
            .other => "circle",
        }, .{ .size = 11, .color = t.accent });
        const box = ui.div(c).grow().w(0).clip();
        matched(c, sy.name, needle, 0, sy.name.len, 0, 13, t.text);
        box.end();
        ui.text(c, c.print("{d}", .{sy.line + 1}), .{ .size = 11.5, .color = t.muted.alpha(0.7) });
    }

    fn pickAt(q: *QuickOpen, i: usize) ?Pick {
        const text = q.query.text();
        if (std.mem.startsWith(u8, text, ">")) {
            if (i >= q.entries.items.len) return null;
            return switch (q.entries.items[i]) {
                .cmd => |cmd| blk: {
                    q.noteRan(cmd);
                    break :blk .{ .command = cmd };
                },
                .new_terminal => |k| .{ .new_terminal = k },
                .default_terminal => |k| .{ .default_terminal = k },
            };
        }
        if (std.mem.startsWith(u8, text, "@")) {
            if (i >= q.sym_hits.items.len) return null;
            return .{ .symbol = q.syms[q.sym_hits.items[i]].line };
        }
        if (i >= q.hits.items.len) return null;
        return .{ .file = q.files[q.hits.items[i].index] };
    }
};

pub fn emptyText(c: *ui.Context, msg: []const u8) void {
    const b = ui.div(c).wFull().px(16).py(12);
    ui.text(c, msg, .{ .size = 13, .color = c.theme.muted });
    b.end();
}

/// A file of the results: its icon, its name with the characters the query
/// matched in the accent color, and its folder.
fn fileRow(c: *ui.Context, rel: []const u8, needle: []const u8) void {
    const t = c.theme;
    const base = if (std.mem.lastIndexOfScalar(u8, rel, '/')) |i| i + 1 else 0;
    icons.file(c, rel[base..]);
    matched(c, rel, needle, base, rel.len, 0, 13, t.text);
    if (base > 0) {
        const box = ui.div(c).grow().w(0).clip();
        matched(c, rel, needle, 0, base - 1, 0, 12, t.muted.alpha(0.7));
        box.end();
    }
}

/// `s[from..end]`, with the characters the query matched in the accent,
/// and before `group` (a command's menu) muted.
pub fn matched(c: *ui.Context, s: []const u8, needle: []const u8, from: usize, end: usize, group: usize, size: f32, color: ui.Color) void {
    const t = c.theme;
    var pos: [64]usize = undefined;
    const hits = positions(s, needle, &pos);
    var spans: std.ArrayList(ui.Span) = .empty;
    // The group muted between the characters matched, which are the accent's.
    var at = from;
    for (hits) |p| if (p >= from and p < end) {
        if (at < @min(group, p)) spans.append(c.alloc(), .{ .start = @intCast(at - from), .end = @intCast(@min(group, p) - from), .color = t.muted }) catch {};
        spans.append(c.alloc(), .{ .start = @intCast(p - from), .end = @intCast(p - from + 1), .color = t.accent, .weight = .semibold }) catch {};
        at = p + 1;
    };
    if (at < @min(group, end)) spans.append(c.alloc(), .{ .start = @intCast(at - from), .end = @intCast(@min(group, end) - from), .color = t.muted }) catch {};
    ui.richText(c, s[from..end], spans.items, .{ .size = size, .color = color });
}

/// Where `needle`'s characters matched in `hay`, as `score` matches them.
fn positions(hay: []const u8, needle: []const u8, out: []usize) []usize {
    var n: usize = 0;
    var hi: usize = 0;
    for (needle) |nc| {
        if (nc == ' ') continue;
        const want = std.ascii.toLower(nc);
        while (hi < hay.len and std.ascii.toLower(hay[hi]) != want) hi += 1;
        if (hi == hay.len or n == out.len) break;
        out[n] = hi;
        n += 1;
        hi += 1;
    }
    return out[0..n];
}

/// `:42` or `:42:7`: a line and a column (0 when not given).
fn lineCol(text: []const u8) struct { line: usize, col: usize } {
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, text[1..], " "), ':');
    const line = std.fmt.parseInt(usize, std.mem.trim(u8, it.next() orelse "", " "), 10) catch 0;
    const col = std.fmt.parseInt(usize, std.mem.trim(u8, it.next() orelse "", " "), 10) catch 0;
    return .{ .line = line, .col = col };
}

/// Keys as the caps of a keyboard, one a cap.
fn keycaps(c: *ui.Context, label: []const u8) void {
    if (label.len == 0) return;
    const t = c.theme;
    const row = ui.div(c).row().gap(3);
    defer row.end();
    var it = std.mem.splitScalar(u8, label, '+');
    while (it.next()) |k0| {
        const k = if (k0.len == 0) "+" else k0;
        const cap = ui.div(c).h(18).minW(18).px(4).center().rounded(4).bg(t.surface_hover).border(t.border);
        ui.text(c, k, .{ .size = 11, .color = t.muted });
        cap.end();
    }
}

/// The keys of quick open (and the boxes like it), and at its end a tip or the prefixes that make it search
/// something else.
pub fn footer(c: *ui.Context, line: bool, open: []const u8, tip: []const u8, prefixes: bool) void {
    const t = c.theme;
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = t.border }, .none, null);
    const row = ui.div(c).row().wFull().h(30).px(14).gap(14).itemsCenter().bg(t.surface_hover);
    defer row.end();
    const hint = struct {
        fn f(cc: *ui.Context, keys: []const u8, label: []const u8) void {
            const h = ui.div(cc).row().gap(6).itemsCenter();
            const cap = ui.div(cc).h(18).minW(18).px(4).center().rounded(4).bg(cc.theme.background).border(cc.theme.border);
            ui.text(cc, keys, .{ .size = 11, .color = cc.theme.muted });
            cap.end();
            ui.text(cc, label, .{ .size = 11.5, .color = cc.theme.muted });
            h.end();
        }
    }.f;
    if (line) {
        hint(c, "⏎", "go to line");
    } else {
        hint(c, "↑↓", "navigate");
        hint(c, "⏎", open);
    }
    hint(c, "esc", "close");
    ui.spacer(c);
    if (tip.len > 0) {
        ui.text(c, tip, .{ .size = 11.5, .color = t.muted.alpha(0.7) });
    } else if (prefixes and !line) {
        hint(c, ">", "commands");
        hint(c, ":", "line");
        hint(c, "@", "symbol");
    }
}

/// Writes an accelerator as the platform does: "CmdOrCtrl+S" as Ctrl+S.
pub fn accelLabel(c: *ui.Context, accel: []const u8) []const u8 {
    const mac = ui.keys.mac;
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, accel, '+');
    var first = true;
    while (it.next()) |part| {
        if (!first) out.append(c.alloc(), '+') catch {};
        first = false;
        const name = if (std.mem.eql(u8, part, "CmdOrCtrl")) (if (mac) "Cmd" else "Ctrl") else part;
        out.appendSlice(c.alloc(), name) catch {};
    }
    return out.items;
}

/// A fuzzy match of `needle`'s characters, in order, in `hay`, ignoring case;
/// higher is better, null when they are not all there. Matches in the file's
/// name, at word starts and in runs score higher.
pub fn score(hay: []const u8, needle: []const u8) ?i32 {
    if (needle.len == 0) return 0;
    const base = (std.mem.lastIndexOfAny(u8, hay, "/\\") orelse 0);
    var s: i32 = 0;
    var hi: usize = 0;
    var prev: ?usize = null;
    for (needle) |nc| {
        if (nc == ' ') continue;
        const want = std.ascii.toLower(nc);
        while (hi < hay.len and std.ascii.toLower(hay[hi]) != want) hi += 1;
        if (hi == hay.len) return null;
        s += 1;
        if (prev != null and prev.? + 1 == hi) s += 5;
        if (hi == 0 or std.mem.indexOfScalar(u8, "/\\_-. ", hay[hi - 1]) != null) s += 3;
        if (hi > base) s += 2;
        prev = hi;
        hi += 1;
    }
    // Shorter paths first among equals.
    s -= @intCast(@min(hay.len / 16, 10));
    return s;
}

test score {
    try std.testing.expect(score("cmd/mayoi/main.go", "main") != null);
    try std.testing.expect(score("cmd/mayoi/main.go", "xyz") == null);
    try std.testing.expect(score("src/main.zig", "main").? > score("src/m_a_i_n.zig", "main").?);
}

test lineCol {
    try std.testing.expectEqual(@as(usize, 42), lineCol(":42").line);
    try std.testing.expectEqual(@as(usize, 7), lineCol(":42:7").col);
    try std.testing.expectEqual(@as(usize, 0), lineCol(":").line);
}

test positions {
    var buf: [8]usize = undefined;
    const p = positions("src/main.zig", "mz", &buf);
    try std.testing.expectEqualSlices(usize, &.{ 4, 9 }, p);
}
