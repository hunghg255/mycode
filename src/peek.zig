//! A change seen as it was: a click on a mark in the gutter opens a box
//! under the change with HEAD's lines, from which the change is reverted
//! (a step of undo) or staged, as Go MyCode's gutter does.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const Doc = @import("doc.zig").Doc;
const hunks = @import("hunks.zig");

pub const Action = enum { none, revert, stage, next, prev, close };

/// The hunk from HEAD's text to the file's at a line, if there is one.
pub fn hunkAt(a: std.mem.Allocator, d: *Doc, line: usize) ?hunks.Hunk {
    const base = d.base orelse return null;
    const now = d.editor.area.text(a);
    const hs = hunks.hunksOf(a, base, now) catch return null;
    for (hs) |h| {
        if (line >= h.b0 and line < h.b1) return h;
        // A deletion shows on the line after it (or the last).
        if (h.b0 == h.b1 and (line == h.b0 or line + 1 == h.b0)) return h;
    }
    return null;
}

/// The box, placed under the change's last line.
pub fn view(c: *ui.Context, d: *Doc, line: usize, size: f32, leading: f32, x: f32) Action {
    const t = c.theme;
    const h = hunkAt(c.alloc(), d, line) orelse return .close;
    const base = d.base orelse return .close;
    const old = ui.diff.splitLines(c.alloc(), base) catch return .close;
    const row_h = c.text.lineHeight(.{ .size = size, .mono = true, .leading = leading });
    const below = @max(h.b1, h.b0 + 1);
    const rows_old: f32 = @floatFromInt(@min(h.a1 -| h.a0, 30) + 2);
    var y = (@as(f32, @floatFromInt(below)) - @as(f32, @floatFromInt(d.first_line))) * row_h + 6;
    // No room under it: above the change.
    const room = c.size.h - 160;
    if (y + rows_old * row_h > room) y = (@as(f32, @floatFromInt(h.b0)) - @as(f32, @floatFromInt(d.first_line))) * row_h - rows_old * row_h - 6;
    y = std.math.clamp(y, 0, @max(room - rows_old * row_h, 0));
    var act: Action = .none;
    const box = ui.div(c).column().absolute().offset(x, y).w(@max(c.size.w * 0.55, 380)).bg(t.surface).border(t.border).rounded(6).shadowMd().clip();
    defer box.end();
    {
        // As the Go app's: what the change is and which of them, and its buttons.
        const bar = ui.div(c).row().wFull().h(26).pl(10).pr(4).gap(2).itemsCenter();
        defer bar.end();
        const what = if (h.a0 == h.a1) "Added" else if (h.b0 == h.b1) "Removed" else "Changed";
        var k: usize = 0;
        var total: usize = 0;
        if (d.base) |b| if (hunks.hunksOf(c.alloc(), b, d.editor.area.text(c.alloc()))) |hs| {
            total = hs.len;
            for (hs, 0..) |o, i| if (o.b0 == h.b0 and o.a0 == h.a0) {
                k = i;
            };
        } else |_| {};
        const words = ui.div(c).grow().w(0).clip();
        ui.text(c, c.print("{s} · change {d} of {d} since HEAD", .{ what, k + 1, total }), .{ .size = 11.5, .color = t.muted });
        words.end();
        if (iconButton(c, "plus", "Stage Change")) act = .stage;
        if (iconButton(c, "arrow.uturn.backward", "Revert Change")) act = .revert;
        if (iconButton(c, "arrow.up", "Previous Change (Shift+Alt+F5)")) act = .prev;
        if (iconButton(c, "arrow.down", "Next Change (Alt+F5)")) act = .next;
        if (iconButton(c, "xmark", "Close (Esc)")) act = .close;
    }
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = t.border }, .none, null);
    // HEAD's lines, a dozen at most.
    const n = @min(h.a1, old.len) -| h.a0;
    if (n > 0) {
        ui.column(c, .{ .width = .fill, .padding = .xy(0, 3), .background = t.danger.alpha(0.10) });
        for (old[h.a0..@min(h.a1, old.len)][0..@min(n, 12)]) |l| {
            ui.row(c, .{ .width = .fill, .padding = .xy(10, 0) });
            ui.text(c, if (l.len > 0) l else " ", .{ .size = size, .mono = true, .leading = leading });
            ui.end(c);
        }
        if (n > 12) {
            ui.row(c, .{ .width = .fill, .padding = .xy(10, 2) });
            ui.text(c, c.print("{d} more lines", .{n - 12}), .{ .size = 11, .color = t.muted });
            ui.end(c);
        }
        ui.end(c);
    }
    if (c.shortcut(.{ .key = ui.Shortcut.escape })) act = .close;
    return act;
}

fn iconButton(c: *ui.Context, icon: []const u8, tip: []const u8) bool {
    const b = ui.div(c).w(22).h(20).center().rounded(4).hover(c.theme.surface_hover);
    @import("icons.zig").sym(c, icon, .{ .size = 10, .color = if (b.hovered()) c.theme.text else c.theme.muted });
    const bi = b.interaction();
    b.end();
    ui.tooltip(c, bi, tip);
    return bi.clicked;
}

/// Reverts the change at a line: its lines back to HEAD's, as a step of undo.
pub fn revert(a: std.mem.Allocator, d: *Doc, line: usize) bool {
    const h = hunkAt(a, d, line) orelse return false;
    const base = d.base orelse return false;
    const now = d.editor.area.text(a);
    const out = hunks.apply(a, .{ .a = base, .b = now }, h, .a) catch return false;
    const caret = d.editor.area.sel.caret;
    d.editor.area.setText(out);
    d.editor.area.collapse(@min(caret, out.len));
    return true;
}
