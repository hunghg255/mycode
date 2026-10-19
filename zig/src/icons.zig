//! File icons: a line icon tinted by the file's kind.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;

const Kind = struct { exts: []const []const u8, color: u24, icon: []const u8 = "doc.text" };

const kinds = [_]Kind{
    .{ .exts = &.{".go"}, .color = 0x00add8 },
    .{ .exts = &.{".zig", ".zon"}, .color = 0xf7a41d },
    .{ .exts = &.{ ".ts", ".tsx", ".mts", ".cts" }, .color = 0x3178c6 },
    .{ .exts = &.{ ".js", ".jsx", ".mjs", ".cjs" }, .color = 0xe8d44d },
    .{ .exts = &.{".py"}, .color = 0x4b8bbe },
    .{ .exts = &.{ ".json", ".jsonc" }, .color = 0xcbcb41 },
    .{ .exts = &.{ ".md", ".markdown" }, .color = 0x519aba },
    .{ .exts = &.{ ".sh", ".bash", ".zsh", ".ps1", ".cmd", ".bat" }, .color = 0x89e051, .icon = "terminal" },
    .{ .exts = &.{ ".html", ".htm" }, .color = 0xe44d26, .icon = "code" },
    .{ .exts = &.{ ".css", ".scss" }, .color = 0x563d7c, .icon = "code" },
    .{ .exts = &.{ ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".svg", ".ico" }, .color = 0xa074c4, .icon = "photo" },
    .{ .exts = &.{ ".yml", ".yaml", ".toml" }, .color = 0xcb171e },
};

/// The language's name, for the status bar.
pub fn languageName(name: []const u8) []const u8 {
    const ext = std.fs.path.extension(name);
    const names = [_][2][]const u8{
        .{ ".go", "Go" },             .{ ".zig", "Zig" },           .{ ".zon", "Zig" },
        .{ ".ts", "TypeScript" },     .{ ".tsx", "TypeScript JSX" }, .{ ".js", "JavaScript" },
        .{ ".jsx", "JavaScript JSX" }, .{ ".mjs", "JavaScript" },     .{ ".py", "Python" },
        .{ ".json", "JSON" },         .{ ".md", "Markdown" },       .{ ".sh", "Shell Script" },
        .{ ".html", "HTML" },         .{ ".css", "CSS" },           .{ ".yml", "YAML" },
        .{ ".yaml", "YAML" },         .{ ".toml", "TOML" },         .{ ".ps1", "PowerShell" },
    };
    for (names) |n| if (std.ascii.eqlIgnoreCase(n[0], ext)) return n[1];
    return "Plain Text";
}

pub fn file(c: *ui.Context, name: []const u8) void {
    const ext = std.fs.path.extension(name);
    for (kinds) |k| for (k.exts) |e| if (std.ascii.eqlIgnoreCase(e, ext)) {
        ui.icon(c, k.icon, .{ .size = 12, .frame = 14, .color = .hex(k.color) });
        return;
    };
    ui.icon(c, "doc", .{ .size = 12, .frame = 14, .color = c.theme.muted });
}
