//! The icons of files and folders, as icons.go and materialicons.go have
//! them: the Material Icon Theme's (the default), in their own colors, or
//! Lucide's in a color for each language (`iconTheme: "lucide"`, and
//! always under The Matrix).
const std = @import("std");
const go_icons = @import("lucide.zig");
const myzig = @import("myzig");
const ui = myzig.ui;
const material = @import("material");
const themes = @import("themes.zig");

/// Set by the window each frame.
pub var lucide_theme: bool = false;
pub var palette: *const themes.Palette = themes.palette("", true);

fn lucideSvg(comptime body: []const u8) []const u8 {
    return "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"24\" height=\"24\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\">" ++ body ++ "</svg>";
}

const lucide = struct {
    const file = lucideSvg("<path d=\"M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z\"/><path d=\"M14 2v4a2 2 0 0 0 2 2h4\"/>");
    const file_code = lucideSvg("<path d=\"M10 12.5 8 15l2 2.5\"/><path d=\"m14 12.5 2 2.5-2 2.5\"/><path d=\"M14 2v4a2 2 0 0 0 2 2h4\"/><path d=\"M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z\"/>");
    const file_text = lucideSvg("<path d=\"M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z\"/><path d=\"M14 2v4a2 2 0 0 0 2 2h4\"/><path d=\"M10 9H8\"/><path d=\"M16 13H8\"/><path d=\"M16 17H8\"/>");
    const file_json = lucideSvg("<path d=\"M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z\"/><path d=\"M14 2v4a2 2 0 0 0 2 2h4\"/><path d=\"M10 12a1 1 0 0 0-1 1v1a1 1 0 0 1-1 1 1 1 0 0 1 1 1v1a1 1 0 0 0 1 1\"/><path d=\"M14 18a1 1 0 0 0 1-1v-1a1 1 0 0 1 1-1 1 1 0 0 1-1-1v-1a1 1 0 0 0-1-1\"/>");
    const image = lucideSvg("<rect width=\"18\" height=\"18\" x=\"3\" y=\"3\" rx=\"2\" ry=\"2\"/><circle cx=\"9\" cy=\"9\" r=\"2\"/><path d=\"m21 15-3.086-3.086a2 2 0 0 0-2.828 0L6 21\"/>");
    const settings = lucideSvg("<path d=\"M20 7h-9\"/><path d=\"M14 17H5\"/><circle cx=\"17\" cy=\"17\" r=\"3\"/><circle cx=\"7\" cy=\"7\" r=\"3\"/>");
    const lock = lucideSvg("<rect width=\"18\" height=\"11\" x=\"3\" y=\"11\" rx=\"2\" ry=\"2\"/><path d=\"M7 11V7a5 5 0 0 1 10 0v4\"/>");
    const terminal = lucideSvg("<path d=\"m4 17 6-6-6-6\"/><path d=\"M12 19h8\"/>");
    const folder = lucideSvg("<path d=\"M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z\"/>");
    const folder_open = lucideSvg("<path d=\"m6 14 1.5-2.9A2 2 0 0 1 9.24 10H20a2 2 0 0 1 1.94 2.5l-1.54 6a2 2 0 0 1-1.95 1.5H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h3.9a2 2 0 0 1 1.69.9l.81 1.2a2 2 0 0 0 1.67.9H18a2 2 0 0 1 2 2v2\"/>");
};

const Maps = struct {
    fileExtensions: std.json.ArrayHashMap([]const u8) = .{},
    fileNames: std.json.ArrayHashMap([]const u8) = .{},
    folderNames: std.json.ArrayHashMap([]const u8) = .{},
    folderNamesExpanded: std.json.ArrayHashMap([]const u8) = .{},
};

const Manifest = struct {
    file: []const u8 = "file",
    folder: []const u8 = "folder",
    folderExpanded: []const u8 = "folder-open",
    fileExtensions: std.json.ArrayHashMap([]const u8) = .{},
    fileNames: std.json.ArrayHashMap([]const u8) = .{},
    folderNames: std.json.ArrayHashMap([]const u8) = .{},
    folderNamesExpanded: std.json.ArrayHashMap([]const u8) = .{},
    light: Maps = .{},
};

var manifest: ?Manifest = null;

/// The manifest, read the first time an icon is asked for (main thread).
fn man() ?*const Manifest {
    if (manifest == null) {
        manifest = std.json.parseFromSliceLeaky(Manifest, std.heap.page_allocator, material.manifest, .{ .ignore_unknown_fields = true }) catch return null;
    }
    return &manifest.?;
}

fn svgOf(name: []const u8) ?[]const u8 {
    var lo: usize = 0;
    var hi: usize = material.names.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        switch (std.mem.order(u8, material.names[mid], name)) {
            .eq => return material.svgs[mid],
            .lt => lo = mid + 1,
            .gt => hi = mid,
        }
    }
    return null;
}

fn lookup(dark: bool, light: std.json.ArrayHashMap([]const u8), base: std.json.ArrayHashMap([]const u8), key: []const u8) ?[]const u8 {
    if (!dark) if (light.map.get(key)) |v| return v;
    return base.map.get(key);
}

/// The Material icon's name of a file: by its whole name, then by its
/// longest extension (".d.ts" before ".ts").
pub fn materialFileName(buf: []u8, name: []const u8, dark: bool) []const u8 {
    const m = man() orelse return "file";
    const lower = std.ascii.lowerString(buf[0..@min(buf.len, name.len)], name[0..@min(buf.len, name.len)]);
    if (lookup(dark, m.light.fileNames, m.fileNames, lower)) |v| return v;
    for (lower, 0..) |ch, i| if (ch == '.') {
        if (lookup(dark, m.light.fileExtensions, m.fileExtensions, lower[i + 1 ..])) |v| return v;
    };
    return m.file;
}

fn materialFolderName(buf: []u8, name: []const u8, open: bool, dark: bool) []const u8 {
    const m = man() orelse return "folder";
    const lower = std.ascii.lowerString(buf[0..@min(buf.len, name.len)], name[0..@min(buf.len, name.len)]);
    if (open) return lookup(dark, m.light.folderNamesExpanded, m.folderNamesExpanded, lower) orelse m.folderExpanded;
    return lookup(dark, m.light.folderNames, m.folderNames, lower) orelse m.folder;
}

fn useLucide() bool {
    return lucide_theme or palette.mono;
}

fn drawSvg(c: *ui.Context, key: []const u8, bytes: []const u8, color: ?ui.Color, size: f32) void {
    const box = ui.div(c).w(size + 2).h(size + 2).center();
    defer box.end();
    // Keys of their own: myzig's line icons are cached by name too.
    _ = ui.svg(c, bytes, .{ .width = size, .height = size, .color = color, .key = c.print("mycode-icon:{s}", .{key}) });
}

/// An icon by the name myzig gives it ("xmark", "chevron.down"), drawn
/// as the Go app draws it, from Lucide (`lucide.zig`), a little larger
/// than myzig's line icons of the same size, as the Go app sizes them;
/// myzig's own for a name without one.
pub fn sym(c: *ui.Context, name: []const u8, opts: ui.IconOptions) void {
    const i = go_icons.named(name) orelse return ui.icon(c, name, opts);
    const size = @round(opts.size * 1.3);
    const box = ui.div(c).w(opts.frame orelse size).h(opts.frame orelse size).center();
    defer box.end();
    _ = ui.svg(c, go_icons.svg(i), .{ .width = size, .height = size, .color = opts.color orelse c.theme.text, .key = c.print("lucide:{s}", .{@tagName(i)}) });
}

/// The title bar's glyphs, Lucide's as the Go app has them.
pub const Glyph = enum { sidebar, sidebar_right, panel };

pub fn glyph(c: *ui.Context, g: Glyph, size: f32, color: ui.Color) void {
    const bytes = switch (g) {
        .sidebar => lucideSvg("<rect width=\"18\" height=\"18\" x=\"3\" y=\"3\" rx=\"2\"/><path d=\"M9 3v18\"/>"),
        .sidebar_right => lucideSvg("<rect width=\"18\" height=\"18\" x=\"3\" y=\"3\" rx=\"2\"/><path d=\"M15 3v18\"/>"),
        .panel => lucideSvg("<rect width=\"18\" height=\"18\" x=\"3\" y=\"3\" rx=\"2\"/><path d=\"M3 15h18\"/>"),
    };
    drawSvg(c, @tagName(g), bytes, color, size);
}

/// A file's icon, by its name.
pub fn file(c: *ui.Context, name: []const u8) void {
    fileSized(c, name, 14);
}

pub fn fileSized(c: *ui.Context, name: []const u8, size: f32) void {
    if (useLucide()) {
        const l = lucideFor(name);
        return drawSvg(c, l.svg, l.svg, l.color, size);
    }
    var buf: [256]u8 = undefined;
    const icon = materialFileName(&buf, name, palette.dark);
    const bytes = svgOf(icon) orelse svgOf("file") orelse return;
    drawSvg(c, icon, bytes, null, size);
}

/// A folder's icon, open or closed.
pub fn folder(c: *ui.Context, name: []const u8, open: bool) void {
    if (useLucide()) return drawSvg(c, if (open) lucide.folder_open else lucide.folder, if (open) lucide.folder_open else lucide.folder, .hex(palette.accent), 14);
    var buf: [256]u8 = undefined;
    const icon = materialFolderName(&buf, name, open, palette.dark);
    const bytes = svgOf(icon) orelse svgOf(if (open) "folder-open" else "folder") orelse return;
    drawSvg(c, icon, bytes, null, 14);
}

const Lucide = struct { svg: []const u8, color: ui.Color };

fn langColor(dark: u24, light: u24) ui.Color {
    const p = palette;
    if (p.mono) {
        const col: ui.Color = .hex(dark);
        const luma = 0.299 * col.r + 0.587 * col.g + 0.114 * col.b;
        return ui.Color.hex(p.muted).mix(.hex(p.accent), luma);
    }
    return .hex(if (p.dark) dark else light);
}

/// Lucide's icon of a file and its color, as lucideFileIcon has them.
fn lucideFor(name: []const u8) Lucide {
    var buf: [256]u8 = undefined;
    const lower = std.ascii.lowerString(buf[0..@min(buf.len, name.len)], name[0..@min(buf.len, name.len)]);
    const ext = std.mem.trimStart(u8, std.fs.path.extension(lower), ".");
    const eq = std.mem.eql;
    const P = palette;
    const named = [_]struct { []const []const u8, []const u8, u24, u24 }{
        .{ &.{ "go.mod", "go.sum", "go.work" }, lucide.file_code, 0x00add8, 0x00809f },
        .{ &.{ "package.json", "tsconfig.json", "bun.lock", "package-lock.json", "yarn.lock", "pnpm-lock.yaml" }, lucide.file_json, 0xcbcb41, 0x9a8a00 },
        .{ &.{ "makefile", "dockerfile", "justfile" }, lucide.settings, 0xe37933, 0xb5571a },
        .{ &.{ "license", "license.md", "license.txt" }, lucide.file_text, 0xd4af37, 0xa07d10 },
    };
    for (named) |n| for (n[0]) |x| if (eq(u8, lower, x)) return .{ .svg = n[1], .color = langColor(n[2], n[3]) };
    if (std.mem.startsWith(u8, lower, ".env")) return .{ .svg = lucide.lock, .color = langColor(0xe8c482, 0xa86a0c) };
    if (std.mem.startsWith(u8, lower, ".") and eq(u8, ext, lower[1..])) return .{ .svg = lucide.settings, .color = .hex(P.muted) };
    const exts = [_]struct { []const []const u8, []const u8, u24, u24 }{
        .{ &.{"go"}, lucide.file_code, 0x00add8, 0x00809f },
        .{ &.{ "ts", "tsx", "mts", "cts" }, lucide.file_code, 0x4d8fdf, 0x2f6fc0 },
        .{ &.{ "js", "jsx", "mjs", "cjs" }, lucide.file_code, 0xe8d44d, 0xa68f00 },
        .{ &.{"rs"}, lucide.file_code, 0xdea584, 0xb0643a },
        .{ &.{"py"}, lucide.file_code, 0x5a9fd4, 0x3572a5 },
        .{ &.{"rb"}, lucide.file_code, 0xe0525a, 0xc0303a },
        .{ &.{"swift"}, lucide.file_code, 0xf0814b, 0xd0602a },
        .{ &.{"zig"}, lucide.file_code, 0xf7a41d, 0xc0790a },
        .{ &.{ "c", "h", "cpp", "cc", "hpp", "m", "mm" }, lucide.file_code, 0x7aa6da, 0x4a76b0 },
        .{ &.{ "java", "kt", "kts", "scala" }, lucide.file_code, 0xe76f51, 0xc04a2b },
        .{ &.{ "html", "htm", "vue", "svelte", "astro" }, lucide.file_code, 0xe8714a, 0xc4492a },
        .{ &.{ "css", "scss", "sass", "less" }, lucide.file_code, 0xa074c4, 0x7a4fa8 },
        .{ &.{ "sh", "bash", "zsh", "fish", "ps1" }, lucide.terminal, 0x89e051, 0x4f9a1f },
        .{ &.{ "json", "jsonc", "json5" }, lucide.file_json, 0xcbcb41, 0x9a8a00 },
        .{ &.{ "yaml", "yml", "toml", "ini", "conf", "cfg", "xml", "plist" }, lucide.settings, 0xc9a0dc, 0x8a5aa8 },
        .{ &.{ "md", "mdx", "markdown", "txt", "rst" }, lucide.file_text, 0x6ba4d8, 0x3d78ad },
        .{ &.{ "png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "icns", "bmp" }, lucide.image, 0xa6c56a, 0x5f8a26 },
    };
    for (exts) |e| for (e[0]) |x| if (eq(u8, ext, x)) return .{ .svg = e[1], .color = langColor(e[2], e[3]) };
    if (eq(u8, ext, "lock") or eq(u8, ext, "sum")) return .{ .svg = lucide.lock, .color = .hex(P.faint) };
    return .{ .svg = lucide.file, .color = .hex(P.muted) };
}

/// The language's name, for the status bar.
pub fn languageName(name: []const u8) []const u8 {
    const ext = std.fs.path.extension(name);
    const names = [_][2][]const u8{
        .{ ".go", "Go" },              .{ ".zig", "Zig" },           .{ ".zon", "Zig" },
        .{ ".ts", "TypeScript" },      .{ ".tsx", "TypeScript JSX" }, .{ ".js", "JavaScript" },
        .{ ".jsx", "JavaScript JSX" }, .{ ".mjs", "JavaScript" },     .{ ".py", "Python" },
        .{ ".json", "JSON" },          .{ ".md", "Markdown" },       .{ ".sh", "Shell Script" },
        .{ ".html", "HTML" },          .{ ".css", "CSS" },           .{ ".yml", "YAML" },
        .{ ".yaml", "YAML" },          .{ ".toml", "TOML" },         .{ ".ps1", "PowerShell" },
        .{ ".rs", "Rust" },            .{ ".c", "C" },               .{ ".h", "C" },
        .{ ".cpp", "C++" },            .{ ".java", "Java" },         .{ ".kt", "Kotlin" },
        .{ ".cs", "C#" },              .{ ".rb", "Ruby" },           .{ ".php", "PHP" },
        .{ ".lua", "Lua" },            .{ ".sql", "SQL" },           .{ ".swift", "Swift" },
    };
    for (names) |n| if (std.ascii.eqlIgnoreCase(n[0], ext)) return n[1];
    return "Plain Text";
}

test materialFileName {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("go", materialFileName(&buf, "main.go", true));
    try std.testing.expect(svgOf("go") != null);
    try std.testing.expect(svgOf("folder") != null);
}
