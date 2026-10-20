//! Review comments: notes on lines of files, kept until MyCode quits, copied
//! or pasted into the terminal in one go for an agent to read. A comment
//! follows its lines as the file changes, and says when they are gone.
const std = @import("std");
const myzig = @import("myzig");

pub const Comment = struct {
    /// Relative to the folder, with slashes.
    path: []u8,
    /// Lines, from 0, as the file has them now.
    first: usize,
    last: usize,
    /// The lines as they were when commented on.
    snippet: []u8,
    text: []u8,
    outdated: bool = false,
    /// Made in a diff: its snippet is the rows, with + and -.
    diff: bool = false,
};

pub const Review = struct {
    gpa: std.mem.Allocator,
    list: std.ArrayList(Comment) = .empty,
    menu_open: bool = false,

    pub fn deinit(r: *Review) void {
        r.clear();
        r.list.deinit(r.gpa);
    }

    pub fn clear(r: *Review) void {
        for (r.list.items) |c| free(r.gpa, c);
        r.list.clearRetainingCapacity();
    }

    fn free(gpa: std.mem.Allocator, c: Comment) void {
        gpa.free(c.path);
        gpa.free(c.snippet);
        gpa.free(c.text);
    }

    /// Adds a comment, or replaces the one on the same lines.
    pub fn put(r: *Review, path: []const u8, first: usize, last: usize, snippet: []const u8, text: []const u8) !void {
        for (r.list.items) |*c| if (std.mem.eql(u8, c.path, path) and c.first == first and c.last == last) {
            r.gpa.free(c.text);
            c.text = try r.gpa.dupe(u8, text);
            return;
        };
        try r.list.append(r.gpa, .{
            .path = try r.gpa.dupe(u8, path),
            .first = first,
            .last = last,
            .snippet = try r.gpa.dupe(u8, snippet),
            .text = try r.gpa.dupe(u8, text),
        });
    }

    /// A comment on rows of a diff.
    pub fn putDiff(r: *Review, path: []const u8, first: usize, last: usize, snippet: []const u8, text: []const u8) !void {
        try r.put(path, first, last, snippet, text);
        for (r.list.items) |*c| if (std.mem.eql(u8, c.path, path) and c.first == first and c.last == last) {
            c.diff = true;
        };
    }

    pub fn remove(r: *Review, i: usize) void {
        free(r.gpa, r.list.orderedRemove(i));
    }

    /// The comment on a line of a file, if there is one.
    pub fn at(r: *const Review, path: []const u8, line: usize) ?usize {
        for (r.list.items, 0..) |c, i| if (!c.outdated and std.mem.eql(u8, c.path, path) and line >= c.first and line <= c.last) return i;
        return null;
    }

    /// The line ranges commented on in a file, in `a`.
    pub fn ranges(r: *const Review, a: std.mem.Allocator, path: []const u8) []const [2]usize {
        var out: std.ArrayList([2]usize) = .empty;
        for (r.list.items) |c| if (!c.outdated and std.mem.eql(u8, c.path, path)) out.append(a, .{ c.first, c.last }) catch {};
        return out.items;
    }

    /// Finds each comment's lines again in a file's new text.
    pub fn follow(r: *Review, path: []const u8, text: []const u8) void {
        for (r.list.items) |*c| {
            if (c.diff or !std.mem.eql(u8, c.path, path)) continue;
            const at_ = std.mem.indexOf(u8, text, c.snippet) orelse {
                c.outdated = true;
                continue;
            };
            c.outdated = false;
            const first = std.mem.count(u8, text[0..at_], "\n");
            c.last = first + (c.last - c.first);
            c.first = first;
        }
    }

    /// Every comment, as they are copied and sent: where, the lines, the comment.
    pub fn format(r: *const Review, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        const numbered = r.list.items.len > 1;
        for (r.list.items, 0..) |c, i| {
            if (i > 0) try out.appendSlice(gpa, "\n");
            if (numbered) try out.print(gpa, "{d}. ", .{i + 1});
            if (c.first == c.last) try out.print(gpa, "{s}:{d}", .{ c.path, c.first + 1 }) else try out.print(gpa, "{s}:{d}-{d}", .{ c.path, c.first + 1, c.last + 1 });
            if (c.outdated) try out.appendSlice(gpa, " (outdated)");
            const lang = if (c.diff) "diff" else std.mem.trimStart(u8, std.fs.path.extension(c.path), ".");
            try out.print(gpa, "\n```{s}\n{s}", .{ lang, c.snippet });
            if (c.snippet.len == 0 or c.snippet[c.snippet.len - 1] != '\n') try out.append(gpa, '\n');
            try out.print(gpa, "```\n{s}\n", .{c.text});
        }
        return out.toOwnedSlice(gpa);
    }
};

test "comments follow their lines" {
    const gpa = std.testing.allocator;
    var r: Review = .{ .gpa = gpa };
    defer r.deinit();
    try r.put("a.go", 1, 1, "b\n", "why b?");
    r.follow("a.go", "x\ny\na\nb\nc\n");
    try std.testing.expectEqual(@as(usize, 3), r.list.items[0].first);
    r.follow("a.go", "gone\n");
    try std.testing.expect(r.list.items[0].outdated);
    const f = try r.format(gpa);
    defer gpa.free(f);
    try std.testing.expect(std.mem.startsWith(u8, f, "a.go:4 (outdated)\n```go\nb\n```\nwhy b?\n"));
}

/// The head of a comment's card, as the Go app's: a stripe of its color down
/// the left (put by the caller), its icon, "Comment on lines 3–5", an
/// Outdated pill, and buttons to edit and delete it.
pub const CardAction = enum { none, edit, delete };

pub fn cardHead(c: *myzig.ui.Context, cm: Comment) CardAction {
    const ui = myzig.ui;
    const icons = @import("icons.zig");
    const t = c.theme;
    var act: CardAction = .none;
    const color = if (cm.outdated) t.warning else t.accent;
    const row = ui.div(c).row().wFull().h(22).gap(6).itemsCenter();
    defer row.end();
    icons.sym(c, "text.bubble", .{ .size = 10, .color = color });
    ui.text(c, "Comment", .{ .size = 11.5, .weight = .semibold });
    const where = if (cm.first == cm.last) c.print("on line {d}", .{cm.first + 1}) else c.print("on lines {d}–{d}", .{ cm.first + 1, cm.last + 1 });
    ui.text(c, where, .{ .size = 11.5, .color = t.muted });
    if (cm.outdated) {
        const pill = ui.div(c).h(16).px(6).center().roundedFull().bg(t.warning.alpha(0.14));
        ui.text(c, "Outdated", .{ .size = 10.5, .weight = .semibold, .color = t.warning });
        const pi = pill.interaction();
        pill.end();
        ui.tooltip(c, pi, "The lines have changed since");
    }
    ui.spacer(c);
    inline for (.{ .{ "pencil", "Edit Comment", CardAction.edit }, .{ "trash", "Delete Comment", CardAction.delete } }) |b| {
        const btn = ui.div(c).w(22).h(20).center().rounded(4).hover(t.surface_hover);
        icons.sym(c, b[0], .{ .size = 10, .color = if (btn.hovered()) t.text else t.muted });
        const bi = btn.interaction();
        btn.end();
        ui.tooltip(c, bi, b[1]);
        if (bi.clicked) act = b[2];
    }
    return act;
}
