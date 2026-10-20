//! Where a tab, a file from the Explorer or files from the system land
//! when let go over the columns: between two tabs of a strip (a marker
//! shows where), in a column's body, or on its left or right edge, which
//! makes a new column there, as columns.go has it.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const columns = @import("columns.zig");
const Editors = columns.Editors;

/// How near a column's side a drop makes a new column.
const edge = 60;

pub const Target = struct {
    col: usize,
    /// The place in the strip, or null for after the tab shown.
    idx: ?usize = null,
    /// A new column on that side of `col`.
    side: enum { none, left, right } = .none,
};

/// The target under `p`, or null when it is over no column.
pub fn at(e: *const Editors, p: ui.Point) ?Target {
    const n = @min(e.cols.items.len, e.strip_rects.len);
    for (0..n) |ci| {
        const strip = e.strip_rects[ci];
        if (strip.contains(p)) {
            // Before the first tab whose middle is right of the pointer.
            var idx: usize = e.cols.items[ci].items.items.len;
            for (e.tab_rects.items) |tr| if (tr.col == ci and p.x < tr.rect.x + tr.rect.w / 2 and tr.idx < idx) {
                idx = tr.idx;
            };
            return .{ .col = ci, .idx = idx };
        }
        const body = e.body_rects[ci];
        if (body.contains(p)) {
            if (p.x > body.x + body.w - edge) return .{ .col = ci, .side = .right };
            if (p.x < body.x + edge) return .{ .col = ci, .side = .left };
            return .{ .col = ci };
        }
    }
    return null;
}

/// Shows where a drop at `t` goes: a bar between tabs, or the side of
/// the column a new one takes.
pub fn marker(c: *ui.Context, e: *const Editors, t: Target) void {
    const accent = c.theme.accent;
    if (t.side != .none) {
        const body = e.body_rects[t.col];
        const x = if (t.side == .right) body.x + body.w - edge else body.x;
        _ = c.leaf(.{ .absolute = true, .offset = .{ .x = x, .y = body.y }, .width = .{ .px = edge }, .height = .{ .px = body.h }, .background = accent.alpha(0.15) }, .none, null);
        return;
    }
    const idx = t.idx orelse return;
    const strip = e.strip_rects[t.col];
    var x = strip.x + 2;
    for (e.tab_rects.items) |tr| if (tr.col == t.col) {
        if (tr.idx == idx) x = tr.rect.x;
        if (tr.idx + 1 == idx) x = tr.rect.x + tr.rect.w;
    };
    _ = c.leaf(.{ .absolute = true, .offset = .{ .x = x - 1, .y = strip.y + 4 }, .width = .{ .px = 2 }, .height = .{ .px = strip.h - 8 }, .background = accent }, .none, null);
}

/// The column a drop at `t` goes into, made when it is a new one; `from`
/// is moved along when the new column comes before it.
pub fn column(e: *Editors, t: Target, from: ?*columns.Loc) ?usize {
    switch (t.side) {
        .none => return t.col,
        .left, .right => {
            const ni = e.addColumn(if (t.side == .right) t.col + 1 else t.col) catch return null;
            if (from) |f| if (f.col >= ni) {
                f.col += 1;
            };
            return ni;
        },
    }
}

/// Ends a tab drag as the pointer is let go; while it moves, the tab's
/// ghost follows the pointer and a marker shows where it would go.
pub fn endDrag(e: *Editors, c: *ui.Context) void {
    const dg = &(e.drag orelse return);
    if (c.input.down) {
        const d = c.input.mouse;
        if (!dg.moving and (@abs(d.x - dg.start.x) > 6 or @abs(d.y - dg.start.y) > 6)) dg.moving = true;
        if (dg.moving) {
            c.wants_moves = true;
            if (at(e, d)) |t| marker(c, e, t);
            const ghost = ui.div(c).absolute().offset(d.x + 8, d.y + 8).px(10).py(4).rounded(4).bg(c.theme.surface_hover).border(c.theme.border);
            ui.text(c, e.at(dg.from).title(c), .{ .size = 12 });
            ghost.end();
        }
        return;
    }
    defer e.drag = null;
    if (!dg.moving) return;
    const t = at(e, c.input.mouse) orelse return;
    var from = dg.from;
    // A tab alone in its column has nowhere new to go beside it.
    if (t.side != .none and t.col == from.col and e.cols.items[from.col].items.items.len == 1) return;
    const ci = column(e, t, &from) orelse return;
    var idx = t.idx;
    // Within its own strip, the places after it move up by one as it leaves.
    if (ci == from.col) if (idx) |i| {
        if (i == from.idx or i == from.idx + 1) return;
        if (i > from.idx) idx = i - 1;
    };
    e.move(from, ci, idx);
    c.changed = true;
}
