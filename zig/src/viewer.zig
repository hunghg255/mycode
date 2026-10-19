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

pub const Image = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []u8,
    bytes: []u8 = &.{},
    /// Its key for myzig's picture cache: changes when the file is read again.
    key: []u8 = &.{},
    gen: u32 = 0,
    mtime: i96 = 0,
    /// Fitted to the view, or this many times its fitted size.
    fit: bool = true,
    zoom: f32 = 1,

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

    pub fn zoomBy(im: *Image, f: f32) void {
        im.fit = false;
        im.zoom = std.math.clamp(im.zoom * f, 0.1, 16);
    }

    pub fn view(im: *Image, c: *ui.Context) void {
        const t = c.theme;
        if (c.shortcut(.{ .key = '=', .cmd = true }) or c.shortcut(.{ .key = '+', .cmd = true })) im.zoomBy(1.25);
        if (c.shortcut(.{ .key = '-', .cmd = true })) im.zoomBy(0.8);
        if (c.shortcut(.{ .key = '0', .cmd = true })) {
            im.fit = true;
            im.zoom = 1;
        }
        const box = ui.div(c).column().wFull().grow().clip();
        defer box.end();
        {
            const bar = ui.div(c).row().wFull().h(28).px(10).gap(10).itemsCenter();
            defer bar.end();
            ui.text(c, c.print("{d} KB", .{im.bytes.len / 1024}), .{ .size = 12, .color = t.muted });
            ui.text(c, if (im.fit) "Fit" else c.print("{d:.0}%", .{im.zoom * 100}), .{ .size = 12, .color = t.muted });
            ui.spacer(c);
            if (ui.button(c, "−", .{ .variant = .ghost, .size = 12 }).clicked) im.zoomBy(0.8);
            if (ui.button(c, "+", .{ .variant = .ghost, .size = 12 }).clicked) im.zoomBy(1.25);
            if (ui.button(c, "Fit", .{ .variant = .ghost, .size = 12 }).clicked) {
                im.fit = true;
                im.zoom = 1;
            }
        }
        const sc = ui.div(c).column().wFull().grow().center().scrollY().bg(t.surface);
        defer sc.end();
        const w = @max(c.size.w * 0.6, 200) * (if (im.fit) 1 else im.zoom);
        const h = @max(c.size.h * 0.7, 200) * (if (im.fit) 1 else im.zoom);
        const shown = ui.image(c, .{ .key = im.key, .bytes = im.bytes, .max_width = w, .max_height = h, .radius = 0, .label = std.fs.path.basename(im.path) });
        if (!shown) ui.text(c, "This picture can't be shown here: on Windows, myzig decodes PNG pictures.", .{ .size = 13, .color = t.muted });
        if (sc.interaction().double_clicked) {
            im.fit = !im.fit;
            im.zoom = if (im.fit) 1 else 2;
        }
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
