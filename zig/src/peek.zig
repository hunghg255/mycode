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
    const box = ui.div(c).column().absolute().offset(x, y).w(@max(c.size.w * 0.45, 360)).bg(t.surface).border(t.border).rounded(6).shadowMd().clip();
    defer box.end();
    {
        const bar = ui.div(c).row().wFull().h(28).px(8).gap(6).itemsCenter().bg(t.surface_hover);
        defer bar.end();
        ui.text(c, if (h.a0 == h.a1) "Added lines" else if (h.b0 == h.b1) c.print("{d} lines removed", .{h.a1 - h.a0}) else "Changed lines", .{ .size = 12, .weight = .semibold });
        ui.text(c, "as HEAD has them", .{ .size = 11, .color = t.muted });
        ui.spacer(c);
        if (ui.button(c, "↑", .{ .variant = .ghost, .size = 11 }).clicked) act = .prev;
        if (ui.button(c, "↓", .{ .variant = .ghost, .size = 11 }).clicked) act = .next;
        if (ui.button(c, "Revert", .{ .variant = .ghost, .size = 11 }).clicked) act = .revert;
        if (ui.button(c, "Stage", .{ .variant = .ghost, .size = 11 }).clicked) act = .stage;
        if (ui.button(c, "×", .{ .variant = .ghost, .size = 11 }).clicked) act = .close;
    }
    const n = @min(h.a1, old.len) -| h.a0;
    if (n == 0) {
        ui.row(c, .{ .padding = .xy(10, 6) });
        ui.text(c, "Nothing was here at HEAD.", .{ .size = 12, .color = t.muted });
        ui.end(c);
    }
    for (old[h.a0..@min(h.a1, old.len)][0..@min(n, 30)]) |l| {
        ui.row(c, .{ .width = .fill, .padding = .xy(10, 0), .background = t.danger.alpha(0.12) });
        ui.text(c, if (l.len > 0) l else " ", .{ .size = size, .mono = true, .leading = leading });
        ui.end(c);
    }
    if (n > 30) ui.text(c, c.print("  … {d} more", .{n - 30}), .{ .size = 11, .color = t.muted });
    if (c.shortcut(.{ .key = ui.Shortcut.escape })) act = .close;
    return act;
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
