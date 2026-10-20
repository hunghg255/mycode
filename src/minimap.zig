//! The minimap along the right of an editor, as minimap.go draws it: each
//! line of the file in blocks of its colors, the lines changed since the
//! last commit, the selection, and the slider over the lines in view. A
//! click scrolls there, a drag moves the slider, the wheel scrolls the
//! editor, and the handle along its left edge makes it wider or narrower.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const Doc = @import("doc.zig").Doc;
const themes = @import("themes.zig");

const row_h: f32 = 2; // a line's height
const char_w: f32 = 1; // a column's width
const pad_l: f32 = 6; // left of the text, where the Git marks go
const tab_w = 4;
pub const min_width: f32 = 40;
pub const max_width: f32 = 400;
/// How wide an editor's text stays, at least, beside its minimap.
pub const room: f32 = 320;

/// What a minimap keeps between frames: the drags of its slider and of
/// its edge, and its height.
pub const State = struct {
    dragging: bool = false,
    grab: f32 = 0,
    resizing: bool = false,
    resize_x: f32 = 0,
    resize_w: f32 = 0,
    /// The width while its edge is dragged, kept when let go.
    width: ?f32 = null,
    height: f32 = 600,
    /// It showed in the last frame (the editor's text then lacks its width).
    shown: bool = false,
};

/// Where the file sits in a minimap `h` high, scrolled with the editor
/// as VS Code's: when it is taller than the minimap, its top shows at the
/// editor's top and its end at its end.
const Geo = struct {
    top: f32,
    slider_y: f32,
    slider_h: f32,
    /// The minimap's height of the whole file.
    map_h: f32,
    /// The slider's travel for each point the editor scrolls.
    q: f32,
    end: f32,
    h: f32,

    fn of(lines: usize, scroll: f32, end: f32, h: f32) Geo {
        const map_h = @as(f32, @floatFromInt(lines)) * row_h;
        const content = end + h;
        const over = @max(0, map_h - h);
        const top = if (end > 0) scroll / end * over else 0;
        const k = map_h / content;
        return .{
            .top = top,
            .slider_y = scroll * k - top,
            .slider_h = @max(h * k, 4),
            .map_h = map_h,
            .q = if (end > 0) k - over / end else 0,
            .end = end,
            .h = h,
        };
    }

    /// How far the editor scrolls for the slider's top to be at `y`.
    fn scrollFor(g: Geo, y: f32) f32 {
        if (g.end <= 0) return 0;
        if (g.q <= 0.0001) return std.math.clamp(y / g.h * g.end, 0, g.end);
        return std.math.clamp(y / g.q, 0, g.end);
    }
};

const Paint = struct {
    d: *Doc,
    g: Geo,
    pal: *const themes.Palette,
    theme: ui.Theme,
    slider: ui.Color,
    dark: bool,
    arena: std.mem.Allocator,

    fn draw(p: *const Paint, pt: *ui.Painter) void {
        const d = p.d;
        const ta = &d.editor.area;
        const doc = &ta.doc;
        const n = doc.lineCount();
        const w = pt.size.w;
        const first: usize = @intFromFloat(@max(0, p.g.top / row_h));
        const last = @min(n -| 1, first + @as(usize, @intFromFloat(p.g.h / row_h)) + 1);
        const y0 = -p.g.top;
        // The selection, over the whole width of its lines.
        if (ta.sel.lo() != ta.sel.hi()) {
            const from = @max(doc.lineOf(ta.sel.lo()), first);
            const to = @min(doc.lineOf(ta.sel.hi()), last);
            var i = from;
            while (i <= to) : (i += 1) pt.fillRect(.{ .x = 0, .y = y0 + @as(f32, @floatFromInt(i)) * row_h, .w = w, .h = row_h }, p.theme.accent.alpha(0.3));
        }
        // The text: a block for each run of a color, one path a color.
        const cols: usize = @intFromFloat(@max(0, (w - pad_l) / char_w));
        var paths: std.AutoArrayHashMapUnmanaged([4]u32, ui.Path) = .empty;
        var i = first;
        while (i <= last and n > 0) : (i += 1) {
            const str = doc.line(p.arena, i);
            const spans = if (str.len < 2000) d.editor.syntax.spans(p.arena, doc, i, str, p.dark) else &.{};
            const y = y0 + @as(f32, @floatFromInt(i)) * row_h;
            var col: usize = 0;
            var from: ?usize = null;
            var run: ui.Color = p.theme.text;
            var k: usize = 0;
            for (str, 0..) |ch, bi| {
                if (ch == '\n' or ch == '\r') break;
                // UTF-8 continuation bytes take no column.
                if (ch & 0xC0 == 0x80) continue;
                while (k < spans.len and spans[k].end <= bi) k += 1;
                const color = if (k < spans.len and spans[k].start <= bi) spans[k].color orelse p.theme.text else p.theme.text;
                const blank = ch == ' ' or ch == '\t';
                if (from) |f| if (blank or !std.meta.eql(color, run)) {
                    block(&paths, pt, run, f, col, y);
                    from = null;
                };
                if (!blank and from == null) {
                    from = col;
                    run = color;
                }
                col = if (ch == '\t') (col / tab_w + 1) * tab_w else col + 1;
                if (col >= cols) break;
            }
            if (from) |f| block(&paths, pt, run, f, @min(col, cols), y);
        }
        var it = paths.iterator();
        while (it.next()) |e| {
            const k = e.key_ptr.*;
            const color: ui.Color = .{ .r = @bitCast(k[0]), .g = @bitCast(k[1]), .b = @bitCast(k[2]), .a = @bitCast(k[3]) };
            pt.fill(e.value_ptr, .color(color.alpha(0.75)));
        }
        // The lines changed since the last commit, along the left edge.
        i = first;
        while (i <= @min(last, d.marks.items.len -| 1) and d.marks.items.len > 0) : (i += 1) {
            const y = y0 + @as(f32, @floatFromInt(i)) * row_h;
            switch (d.marks.items[i]) {
                .none => {},
                .added => pt.fillRect(.{ .x = 1, .y = y, .w = 2, .h = row_h }, .hex(p.pal.added)),
                .changed => pt.fillRect(.{ .x = 1, .y = y, .w = 2, .h = row_h }, .hex(p.pal.changed)),
                else => pt.fillRect(.{ .x = 1, .y = y - 1, .w = 3, .h = 2 }, .hex(p.pal.removed)),
            }
        }
        pt.fillRect(.{ .x = 0, .y = p.g.slider_y, .w = w, .h = p.g.slider_h }, p.slider);
    }

    fn block(paths: *std.AutoArrayHashMapUnmanaged([4]u32, ui.Path), pt: *ui.Painter, color: ui.Color, x0: usize, x1: usize, y: f32) void {
        const key: [4]u32 = .{ @bitCast(color.r), @bitCast(color.g), @bitCast(color.b), @bitCast(color.a) };
        const gop = paths.getOrPut(pt.arena, key) catch return;
        if (!gop.found_existing) gop.value_ptr.* = pt.path();
        const l = pad_l + @as(f32, @floatFromInt(x0)) * char_w;
        gop.value_ptr.rect(l, y, @as(f32, @floatFromInt(x1 - x0)) * char_w, row_h - 0.5);
    }
};

/// The minimap of `d`, beside its editor; `width` is the setting's.
/// Returns a width to keep when its edge was let go.
pub fn view(c: *ui.Context, d: *Doc, width_setting: f32, pal: *const themes.Palette) ?f32 {
    const m = &d.mini;
    const width = m.width orelse width_setting;
    const box = ui.div(c).w(width).hFull().clip().bg(.hex(pal.editor));
    defer box.end();
    const id = d.editor.area.scroll_id;
    const scroll = c.scroll.get(id) orelse 0;
    const end = c.scroll_max.get(id) orelse 0;
    var g: Geo = .of(d.editor.area.doc.lineCount(), scroll, end, m.height);
    const hovered = box.hovered();
    const pa: *Paint = c.alloc().create(Paint) catch return null;
    pa.* = .{
        .d = d,
        .g = g,
        .pal = pal,
        .theme = c.theme,
        .slider = c.theme.text.alpha(if (m.dragging) 0.16 else if (hovered) 0.11 else 0.07),
        .dark = pal.dark,
        .arena = c.alloc(),
    };
    const cv = ui.canvas(c, .{ .w = 0, .h = 0 }, .{}, @as(*const Paint, pa), Paint.draw);
    const ia = c.interact(cv, .{});
    if (ia.rect) |r| m.height = r.h;
    // A press holds the slider where it is, or brings its middle there.
    if (ia.pressed and !m.resizing) if (ia.rect) |r| {
        const y = c.input.mouse.y - r.y;
        m.dragging = true;
        m.grab = if (y >= g.slider_y and y < g.slider_y + g.slider_h) y - g.slider_y else g.slider_h / 2;
    };
    if (m.dragging) {
        if (!c.input.down) m.dragging = false else if (ia.rect) |r| {
            c.wants_moves = true;
            const to = g.scrollFor(c.input.mouse.y - r.y - m.grab);
            c.scroll.put(c.gpa, id, to) catch {};
            g = .of(d.editor.area.doc.lineCount(), to, end, m.height);
            c.changed = true;
        }
    }
    // The wheel over it scrolls the editor.
    if (hovered and c.input.scroll.y != 0) {
        c.scroll.put(c.gpa, id, std.math.clamp(scroll - c.input.scroll.y, 0, end)) catch {};
        c.input.scroll = .{};
        c.changed = true;
    }
    // The handle along its left edge.
    const handle = ui.div(c).absolute().offset(0, 0).w(4).hFull();
    const hi = handle.interaction();
    handle.end();
    if (hi.hovered or m.resizing) c.cursor = .resize_left_right;
    if (hi.pressed) {
        m.resizing = true;
        m.resize_x = c.input.mouse.x;
        m.resize_w = width;
    }
    if (m.resizing) {
        if (c.input.down) {
            c.wants_moves = true;
            m.width = std.math.clamp(m.resize_w - (c.input.mouse.x - m.resize_x), min_width, max_width);
            c.changed = true;
        } else {
            m.resizing = false;
            const kept = m.width;
            m.width = null;
            return kept;
        }
    }
    return null;
}

test Geo {
    // A short file: the slider moves as far as the editor scrolls.
    const g: Geo = .of(100, 50, 100, 400);
    try std.testing.expect(g.top == 0);
    try std.testing.expectApproxEqAbs(@as(f32, 50), g.scrollFor(g.slider_y), 0.01);
    // A long one scrolls the minimap too.
    const l: Geo = .of(5000, 1000, 80000, 600);
    try std.testing.expect(l.top > 0);
    try std.testing.expectApproxEqAbs(@as(f32, 1000), l.scrollFor(l.slider_y), 0.5);
}
