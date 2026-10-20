//! The image viewer, and Markdown and SVG files shown rendered.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const fs = @import("fs.zig");
const Doc = @import("doc.zig").Doc;

const image_exts = [_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".ico" };

pub fn isImage(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    for (image_exts) |e| if (std.ascii.eqlIgnoreCase(e, ext)) return true;
    return false;
}

pub fn isMarkdown(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    return std.ascii.eqlIgnoreCase(ext, ".md") or std.ascii.eqlIgnoreCase(ext, ".markdown");
}

pub fn isSvg(path: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".svg");
}

/// The zooms a step goes through, as viewer.go has them.
const zoom_steps = [_]f32{ 0.05, 0.1, 0.25, 1.0 / 3.0, 0.5, 2.0 / 3.0, 1, 1.5, 2, 3, 4, 6, 8, 12, 16, 24, 32 };
const fit_margin: f32 = 24;
/// The checkerboard's checks, in points.
const check: f32 = 8;

pub const Image = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []u8,
    bytes: []u8 = &.{},
    /// Its key for myzig's picture cache: changes when the file is read again.
    key: []u8 = &.{},
    gen: u32 = 0,
    mtime: i96 = 0,
    /// Its scale, or 0 for fitted to the pane; how far it is moved from
    /// the pane's middle; where a drag holds it.
    zoom: f32 = 0,
    pan_x: f32 = 0,
    pan_y: f32 = 0,
    grab: ?ui.Point = null,
    /// The picture's size (its pixels as points) and the pane's, last frame.
    w: f32 = 0,
    h: f32 = 0,
    pane_w: f32 = 800,
    pane_h: f32 = 600,

    pub fn create(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !*Image {
        const im = try gpa.create(Image);
        im.* = .{ .gpa = gpa, .io = io, .path = try gpa.dupe(u8, path) };
        im.read();
        return im;
    }

    pub fn destroy(im: *Image) void {
        im.gpa.free(im.bytes);
        im.gpa.free(im.key);
        im.gpa.free(im.path);
        im.gpa.destroy(im);
    }

    fn read(im: *Image) void {
        im.gpa.free(im.bytes);
        im.bytes = fs.read(im.gpa, im.io, im.path) catch &.{};
        im.mtime = fs.mtime(im.io, im.path);
        im.gen += 1;
        im.gpa.free(im.key);
        im.key = std.fmt.allocPrint(im.gpa, "{s}#{d}", .{ im.path, im.gen }) catch &.{};
    }

    pub fn reloadIfChanged(im: *Image) void {
        const m = fs.mtime(im.io, im.path);
        if (m != 0 and m != im.mtime) im.read();
    }

    fn fitScale(im: *const Image, w0: f32, h0: f32) f32 {
        if (im.w <= 0 or im.h <= 0) return 1;
        var w = w0;
        var h = h0;
        if (w > 8 * fit_margin and h > 8 * fit_margin) {
            w -= 2 * fit_margin;
            h -= 2 * fit_margin;
        }
        return @min(1, @min(w / im.w, h / im.h));
    }

    fn scale(im: *const Image) f32 {
        return if (im.zoom == 0) im.fitScale(im.pane_w, im.pane_h) else im.zoom;
    }

    /// Where the picture shows in the pane, kept from being dragged out.
    fn place(im: *Image) ui.Rect {
        const s = im.scale();
        const iw = im.w * s;
        const ih = im.h * s;
        const mx = @max(iw - im.pane_w, 0) / 2;
        const my = @max(ih - im.pane_h, 0) / 2;
        im.pan_x = std.math.clamp(im.pan_x, -mx, mx);
        im.pan_y = std.math.clamp(im.pan_y, -my, my);
        return .{ .x = (im.pane_w - iw) / 2 + im.pan_x, .y = (im.pane_h - ih) / 2 + im.pan_y, .w = iw, .h = ih };
    }

    /// Zooms to `s`, keeping the point (x, y) of the pane on the picture.
    fn zoomAt(im: *Image, s0: f32, x: f32, y: f32) void {
        const old = im.scale();
        const s = std.math.clamp(s0, zoom_steps[0], zoom_steps[zoom_steps.len - 1]);
        const dx = x - im.pane_w / 2 - im.pan_x;
        const dy = y - im.pane_h / 2 - im.pan_y;
        im.pan_x = x - im.pane_w / 2 - dx * s / old;
        im.pan_y = y - im.pane_h / 2 - dy * s / old;
        im.zoom = s;
    }

    /// A step in or out around the pane's middle, or fitted again for 0:
    /// the Zoom commands while a picture shows.
    pub fn zoomStep(im: *Image, step: i32) void {
        if (step == 0) {
            im.zoom = 0;
            im.pan_x = 0;
            im.pan_y = 0;
            return;
        }
        const now = im.scale();
        var next = now;
        if (step > 0) {
            for (zoom_steps) |z| if (z > now * 1.001) {
                next = z;
                break;
            };
        } else {
            var k = zoom_steps.len;
            while (k > 0) {
                k -= 1;
                if (zoom_steps[k] < now * 0.999) {
                    next = zoom_steps[k];
                    break;
                }
            }
        }
        im.zoomAt(next, im.pane_w / 2, im.pane_h / 2);
    }

    /// The tile of checks, made once a theme (`checks.zig`).
    var tiles: [2]?[]u8 = .{ null, null };

    fn tile(gpa: std.mem.Allocator, dark: bool) []const u8 {
        const k: usize = @intFromBool(dark);
        if (tiles[k] == null) tiles[k] = @import("checks.zig").png(gpa, dark) catch null;
        return tiles[k] orelse "";
    }

    pub fn view(im: *Image, c: *ui.Context) void {
        const t = c.theme;
        const pane = ui.div(c).wFull().grow().clip().bg(t.background);
        defer pane.end();
        const pi = pane.interaction();
        if (pi.rect) |r| {
            im.pane_w = r.w;
            im.pane_h = r.h;
        }
        const size = ui.imageSize(c, im.key, im.bytes) orelse {
            const msg = ui.div(c).column().wFull().hFull().center().gap(12);
            ui.icon(c, "photo", .{ .size = 32, .color = t.muted.alpha(0.5) });
            ui.text(c, c.print("Cannot show {s}", .{std.fs.path.basename(im.path)}), .{ .size = 13, .color = t.muted });
            msg.end();
            return;
        };
        if (size.w != im.w or size.h != im.h) {
            // Another picture: fitted.
            if (im.w != 0) im.zoomStep(0);
            im.w = size.w;
            im.h = size.h;
        }
        const at = im.place();
        // Within the pane: what shows of the picture, on its checks.
        const vis_x = @max(at.x, 0);
        const vis_y = @max(at.y, 0);
        const vis_w = @min(at.x + at.w, im.pane_w) - vis_x;
        const vis_h = @min(at.y + at.h, im.pane_h) - vis_y;
        if (vis_w > 0 and vis_h > 0) {
            const holder = ui.div(c).absolute().offset(vis_x, vis_y).w(vis_w).h(vis_h).clip();
            // The checks start at the picture's corner, as it moves: tiles
            // of one picture, which the image atlas keeps once.
            const pts = @as(f32, @floatFromInt(@import("checks.zig").side)) / 2;
            const bytes = tile(im.gpa, t.dark);
            const key = if (t.dark) "mycode:checks-dark" else "mycode:checks-light";
            const ox = at.x - vis_x;
            const oy = at.y - vis_y;
            var ty = oy + @floor(-oy / pts) * pts;
            var n: usize = 0;
            while (ty < vis_h) : (ty += pts) {
                var tx = ox + @floor(-ox / pts) * pts;
                while (tx < vis_w) : (tx += pts) {
                    n += 1;
                    c.keyed(n);
                    const cell = ui.div(c).absolute().offset(tx, ty);
                    _ = ui.image(c, .{ .key = key, .bytes = bytes, .size = .{ .w = pts, .h = pts }, .max_width = pts, .max_height = pts, .radius = 0 });
                    cell.end();
                }
            }
            const img = ui.div(c).absolute().offset(at.x - vis_x, at.y - vis_y);
            _ = ui.image(c, .{ .key = im.key, .bytes = im.bytes, .size = .{ .w = at.w, .h = at.h }, .max_width = at.w, .max_height = at.h, .radius = 0, .label = std.fs.path.basename(im.path) });
            img.end();
            holder.end();
        }
        // A hairline sets a picture smaller than the pane off from it.
        if (at.w < im.pane_w and at.h < im.pane_h) _ = c.leaf(.{ .absolute = true, .offset = .{ .x = at.x - 1, .y = at.y - 1 }, .width = .{ .px = at.w + 2 }, .height = .{ .px = at.h + 2 }, .border = t.border, .border_width = 1 }, .none, null);
        const r = pi.rect orelse return;
        const mx = c.input.mouse.x - r.x;
        const my = c.input.mouse.y - r.y;
        // The wheel with Ctrl zooms around the pointer; without, it moves it.
        if (pi.hovered and (c.input.scroll.y != 0 or c.input.scroll.x != 0)) {
            if (c.input.ctrl or c.input.cmd) {
                im.zoomAt(im.scale() * @exp(c.input.scroll.y / 200), mx, my);
            } else {
                im.pan_x += c.input.scroll.x;
                im.pan_y += c.input.scroll.y;
            }
            c.input.scroll = .{};
            c.changed = true;
        }
        if (pi.double_clicked) {
            if (im.zoom == 0 and im.fitScale(im.pane_w, im.pane_h) < 1) im.zoomAt(1, mx, my) else im.zoomStep(0);
            c.changed = true;
        } else if (pi.pressed and c.input.pressed) im.grab = c.input.mouse;
        if (im.grab) |g| {
            if (!c.input.down) im.grab = null else {
                c.wants_moves = true;
                im.pan_x += c.input.mouse.x - g.x;
                im.pan_y += c.input.mouse.y - g.y;
                im.grab = c.input.mouse;
                c.changed = true;
            }
        }
        if (pi.hovered and (at.w > im.pane_w + 0.5 or at.h > im.pane_h + 0.5)) c.cursor = .hand;
    }
};

/// A Markdown file shown rendered: its text, read as it is in the editor.
pub fn markdown(c: *ui.Context, d: *Doc) ?[]const u8 {
    if (d.md == null) d.md = ui.Markdown.init(d.gpa);
    const text = d.editor.area.text(c.alloc());
    const body = stripFrontMatter(text);
    const sc = ui.div(c).column().wFull().grow().scrollY().px(32).py(20);
    defer sc.end();
    const col = ui.div(c).column().wFull().maxW(860);
    defer col.end();
    const res = ui.markdown(c, body, .{ .state = &d.md.? });
    return res.link;
}

/// An SVG file shown as a picture, updated as it is typed.
pub fn svgPreview(c: *ui.Context, d: *Doc) void {
    const text = d.editor.area.text(c.alloc());
    const sc = ui.div(c).column().wFull().grow().center().bg(c.theme.surface);
    defer sc.end();
    if (!ui.svg(c, text, .{ .width = @min(c.size.w * 0.5, 600) })) ui.text(c, "The SVG doesn't parse.", .{ .size = 13, .color = c.theme.muted });
}

fn stripFrontMatter(text: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, text, "---\n")) return text;
    const end = std.mem.indexOfPos(u8, text, 4, "\n---") orelse return text;
    const after = std.mem.indexOfScalarPos(u8, text, end + 4, '\n') orelse return "";
    return text[after + 1 ..];
}

test stripFrontMatter {
    try std.testing.expectEqualStrings("# Hi\n", stripFrontMatter("---\ntitle: x\n---\n# Hi\n"));
    try std.testing.expectEqualStrings("# Hi", stripFrontMatter("# Hi"));
}
