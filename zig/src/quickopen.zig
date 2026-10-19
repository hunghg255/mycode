//! Quick open (⌘P): files by a fuzzy match, recent ones first; `>` runs a
//! command by name, `:42` goes to a line.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const fs = @import("fs.zig");
const git = @import("git.zig");
const commands = @import("commands.zig");
const icons = @import("icons.zig");

pub const Pick = union(enum) {
    /// Relative to the workspace, with slashes.
    file: []const u8,
    command: commands.Cmd,
    line: usize,
};

const Hit = struct { index: usize, score: i32 };

const max_results = 200;

pub const QuickOpen = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    dialog: ui.OverlayState = .{},
    query: ui.TextBuffer = .{},
    files: [][]const u8 = &.{},
    hits: std.ArrayList(Hit) = .empty,
    cmds: std.ArrayList(commands.Cmd) = .empty,
    /// Files opened, newest first, relative.
    recent: std.ArrayList([]u8) = .empty,
    /// Commands run, newest first.
    recent_cmds: std.ArrayList(commands.Cmd) = .empty,
    selected: usize = 0,
    focus: bool = false,
    filtered_for: [1024]u8 = undefined,
    filtered_len: ?usize = null,

    pub fn deinit(q: *QuickOpen) void {
        if (q.files.len > 0) fs.freeStrings(q.gpa, q.files);
        q.hits.deinit(q.gpa);
        q.cmds.deinit(q.gpa);
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
        q.focus = true;
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

    fn filter(q: *QuickOpen) void {
        const text = q.query.text();
        if (q.filtered_len) |n| if (n == text.len and std.mem.eql(u8, q.filtered_for[0..n], text)) return;
        @memcpy(q.filtered_for[0..text.len], text);
        q.filtered_len = text.len;
        q.selected = 0;
        q.hits.clearRetainingCapacity();
        q.cmds.clearRetainingCapacity();
        if (std.mem.startsWith(u8, text, ">")) {
            const needle = std.mem.trim(u8, text[1..], " ");
            for (q.recent_cmds.items) |cmd| if (score(commands.info(cmd).title, needle) != null) q.cmds.append(q.gpa, cmd) catch {};
            for (commands.all) |cmd| {
                if (std.mem.indexOfScalar(commands.Cmd, q.recent_cmds.items, cmd) != null) continue;
                if (score(commands.info(cmd).title, needle) != null) q.cmds.append(q.gpa, cmd) catch {};
            }
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
        if (std.mem.startsWith(u8, text, ">")) return q.cmds.items.len;
        if (std.mem.startsWith(u8, text, ":")) return 1;
        return q.hits.items.len;
    }

    pub fn view(q: *QuickOpen, c: *ui.Context) ?Pick {
        const d = ui.dialog(c, &q.dialog, .{ .width = .{ .px = 600 }, .padding = .all(8), .gap = 6 }) orelse return null;
        defer d.end();
        const t = c.theme;
        const fid = c.peekId(null);
        if (q.focus) {
            c.focus = fid;
            c.changed = true;
            q.focus = false;
        }
        const field = ui.textField(c, &q.query, .{ .width = .fill, .placeholder = "Search files by name (> for commands, : for a line)", .size = 14 });
        q.filter();
        const n = q.count();
        if (c.shortcut(.{ .key = ui.Shortcut.down })) q.selected = if (n == 0) 0 else (q.selected + 1) % n;
        if (c.shortcut(.{ .key = ui.Shortcut.up })) q.selected = if (n == 0) 0 else (q.selected + n - 1) % n;
        var pick: ?Pick = null;
        const text = q.query.text();
        var rows = ui.list(c, .{ .count = n, .row_height = 26, .height = .{ .px = @min(@as(f32, @floatFromInt(n)) * 26, 420) } });
        while (rows.next()) |i| {
            const on = i == q.selected;
            const row = ui.div(c).row().wFull().h(26).px(8).gap(8).itemsCenter().rounded(4).bg(if (on) t.accent.alpha(0.25) else .transparent).hover(t.surface_hover);
            if (std.mem.startsWith(u8, text, ">")) {
                const inf = commands.info(q.cmds.items[i]);
                ui.text(c, inf.title, .{ .size = 13 });
                ui.spacer(c);
                if (inf.menu.len > 0) ui.text(c, inf.menu, .{ .size = 11, .color = t.muted });
                if (inf.accel.len > 0) ui.text(c, accelLabel(c, inf.accel), .{ .size = 11, .color = t.muted, .mono = true });
            } else if (std.mem.startsWith(u8, text, ":")) {
                ui.text(c, c.print("Go to line {s}", .{text[1..]}), .{ .size = 13 });
            } else {
                const f = q.files[q.hits.items[i].index];
                icons.file(c, std.fs.path.basename(f));
                ui.text(c, std.fs.path.basename(f), .{ .size = 13 });
                if (std.fs.path.dirname(f)) |dir| ui.text(c, dir, .{ .size = 11, .color = t.muted });
            }
            if (row.clicked()) {
                q.selected = i;
                pick = q.pickAt(i);
            }
            row.end();
        }
        rows.end();
        if (n == 0) ui.text(c, "No matching results", .{ .size = 12, .color = t.muted });
        if (field.submitted and n > 0) pick = q.pickAt(q.selected);
        if (pick != null) q.dialog.close();
        return pick;
    }

    fn pickAt(q: *QuickOpen, i: usize) ?Pick {
        const text = q.query.text();
        if (std.mem.startsWith(u8, text, ">")) {
            if (i >= q.cmds.items.len) return null;
            q.noteRan(q.cmds.items[i]);
            return .{ .command = q.cmds.items[i] };
        }
        if (std.mem.startsWith(u8, text, ":")) {
            const line = std.fmt.parseInt(usize, std.mem.trim(u8, text[1..], " "), 10) catch return null;
            return .{ .line = line };
        }
        if (i >= q.hits.items.len) return null;
        return .{ .file = q.files[q.hits.items[i].index] };
    }
};

/// Writes an accelerator as the platform does: "CmdOrCtrl+S" as Ctrl+S.
fn accelLabel(c: *ui.Context, accel: []const u8) []const u8 {
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
