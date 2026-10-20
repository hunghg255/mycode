//! The overview ruler along an editor's right edge, where the scroll bar
//! goes, as editor.go paints it: the whole file, with the lines changed
//! since the last commit, find's matches, the review comments and the
//! caret's line, each at its height in the file.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const Doc = @import("doc.zig").Doc;
const themes = @import("themes.zig");

const Paint = struct {
    d: *Doc,
    pal: *const themes.Palette,
    theme: ui.Theme,

    fn draw(p: *const Paint, pt: *ui.Painter) void {
        const d = p.d;
        const ta = &d.editor.area;
        const lines: f32 = @floatFromInt(@max(ta.doc.lineCount(), 1));
        const h = pt.size.h;
        // Runs of the lines changed, by their kind.
        const marks = d.marks.items;
        var i: usize = 0;
        while (i < marks.len) {
            const k = marks[i];
            var j = i + 1;
            if (k == .added or k == .changed) while (j < marks.len and marks[j] == k) : (j += 1) {};
            if (k != .none) {
                const y = @as(f32, @floatFromInt(i)) / lines * h;
                const run_h = @max(@as(f32, @floatFromInt(j - i)) / lines * h, 2);
                switch (k) {
                    .added => pt.fillRect(.{ .x = 0, .y = y, .w = 3, .h = run_h }, .hex(p.pal.added)),
                    .changed => pt.fillRect(.{ .x = 0, .y = y, .w = 3, .h = run_h }, .hex(p.pal.changed)),
                    else => pt.fillRect(.{ .x = 0, .y = y - 1, .w = 3, .h = 3 }, .hex(p.pal.removed)),
                }
            }
            i = j;
        }
        // Find's matches, one a pixel row at most.
        const f = &d.editor.find;
        if (f.open) {
            var last: f32 = -2;
            for (f.matches.items) |m| {
                if (m[0] > ta.len()) break;
                const y = @as(f32, @floatFromInt(ta.doc.lineOf(m[0]))) / lines * h;
                if (y - last < 1) continue;
                last = y;
                pt.fillRect(.{ .x = 4, .y = y, .w = 5, .h = 2 }, p.theme.warning.alpha(0.9));
            }
        }
        for (d.comment_lines) |r| pt.fillRect(.{ .x = 4, .y = @as(f32, @floatFromInt(r[0])) / lines * h - 1, .w = 5, .h = 3 }, p.theme.accent);
        const caret = @as(f32, @floatFromInt(ta.caretLine())) / lines * h;
        pt.fillRect(.{ .x = 0, .y = caret - 1, .w = 9, .h = 2 }, p.theme.text.alpha(0.6));
    }
};

/// The ruler over the right edge of the editor of `d`, which is `rect`
/// within its parent (a box of `ui.div(...).absolute()` children).
pub fn view(c: *ui.Context, d: *Doc, rect: ui.Rect, pal: *const themes.Palette) void {
    if (d.editor.area.doc.lineCount() <= 1 or rect.h <= 0) return;
    const has = d.marks.items.len > 0 or d.comment_lines.len > 0 or (d.editor.find.open and d.editor.find.matches.items.len > 0);
    if (!has) return;
    const pa = c.alloc().create(Paint) catch return;
    pa.* = .{ .d = d, .pal = pal, .theme = c.theme };
    const holder = ui.div(c).absolute().offset(rect.x + rect.w - 10, rect.y).w(9).h(rect.h);
    defer holder.end();
    _ = ui.canvas(c, .{ .w = 9, .h = rect.h }, .{}, @as(*const Paint, pa), Paint.draw);
}
