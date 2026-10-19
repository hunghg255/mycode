//! MyCode's themes, as theme.go has them: MyCode, The Matrix, Claude and
//! Qoder, each light and dark but The Matrix, always dark.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;

/// What the workbench paints beyond myzig's theme.
pub const Palette = struct {
    dark: bool,
    mono: bool = false,
    editor: u24,
    chrome: u24,
    panel: u24,
    border: u24,
    text: u24,
    muted: u24,
    faint: u24,
    accent: u24,
    fill: u24,
    fill_text: u24,
    surface: u24,
    surface_hover: u24,
    danger: u24,
    modified: u24,
    added: u24,
    changed: u24,
    removed: u24,
    keyword: u24,
    type: u24,
    function: u24,
    string: u24,
    number: u24,
    comment: u24,

    pub fn color(_: Palette, v: u24) ui.Color {
        return .hex(v);
    }
};

const mycode_dark: Palette = .{ .dark = true, .editor = 0x18181d, .chrome = 0x131317, .panel = 0x151519, .border = 0x26262e, .text = 0xd6d6de, .muted = 0x8c8c99, .faint = 0x666672, .accent = 0x8b7cf6, .fill = 0x7260e3, .fill_text = 0xffffff, .surface = 0x202027, .surface_hover = 0x272730, .danger = 0xf0718b, .modified = 0xe8b86d, .added = 0x4fa86d, .changed = 0x5a8ee0, .removed = 0xe0607e, .keyword = 0xb99cf7, .type = 0x7dcfe0, .function = 0x8fb4ff, .string = 0xa9d48f, .number = 0xf2a679, .comment = 0x747481 };
const mycode_light: Palette = .{ .dark = false, .editor = 0xfcfcfd, .chrome = 0xf4f4f7, .panel = 0xf8f8fa, .border = 0xe4e4ea, .text = 0x2a2a33, .muted = 0x6c6c79, .faint = 0x8e8e9a, .accent = 0x6d5bd0, .fill = 0x6d5bd0, .fill_text = 0xffffff, .surface = 0xffffff, .surface_hover = 0xf2f2f6, .danger = 0xd0365a, .modified = 0xc4862a, .added = 0x3fa363, .changed = 0x4a7fd4, .removed = 0xd6456a, .keyword = 0x7c3bd6, .type = 0x0b7c99, .function = 0x2a5bd7, .string = 0x3d8a28, .number = 0xc2571a, .comment = 0x868692 };
const matrix: Palette = .{ .dark = true, .mono = true, .editor = 0x050a06, .chrome = 0x020503, .panel = 0x040806, .border = 0x0f2a16, .text = 0x4af07a, .muted = 0x2a9d4c, .faint = 0x1a5c2e, .accent = 0x00ff41, .fill = 0x00d43a, .fill_text = 0x000000, .surface = 0x08140b, .surface_hover = 0x0c1d10, .danger = 0xff4a5a, .modified = 0xd9b44a, .added = 0x00d43a, .changed = 0x3fd0b0, .removed = 0xe0505e, .keyword = 0xb6ffc8, .type = 0x00ff9c, .function = 0x66ff8a, .string = 0x8fd94a, .number = 0xc8ff5a, .comment = 0x1f7a3a };
const claude_dark: Palette = .{ .dark = true, .editor = 0x1f1e1d, .chrome = 0x191918, .panel = 0x1c1b1a, .border = 0x2e2c2a, .text = 0xe8e6dc, .muted = 0xa39e93, .faint = 0x75716a, .accent = 0xd97757, .fill = 0xb8573a, .fill_text = 0xffffff, .surface = 0x262523, .surface_hover = 0x2d2b29, .danger = 0xe8705f, .modified = 0xe3b25f, .added = 0x7ba05b, .changed = 0x6a9bcc, .removed = 0xd9634f, .keyword = 0xd97757, .type = 0x7fbfb3, .function = 0x8fb6dd, .string = 0xb3c98a, .number = 0xd4a27f, .comment = 0x7d786f };
const claude_light: Palette = .{ .dark = false, .editor = 0xfaf9f5, .chrome = 0xf0eee6, .panel = 0xf5f4ee, .border = 0xe3dfd3, .text = 0x141413, .muted = 0x6b675f, .faint = 0x938d82, .accent = 0xc96442, .fill = 0xb8573a, .fill_text = 0xffffff, .surface = 0xffffff, .surface_hover = 0xf5f3ec, .danger = 0xbf4d3a, .modified = 0xb5791f, .added = 0x5e8a3a, .changed = 0x4a7fb5, .removed = 0xc4513c, .keyword = 0xb8573a, .type = 0x2f8378, .function = 0x3b6ea8, .string = 0x5e8a3a, .number = 0xa85a1f, .comment = 0x938d82 };
const qoder_light: Palette = .{ .dark = false, .editor = 0xffffff, .chrome = 0xf2f4f2, .panel = 0xf5f7f5, .border = 0xe3e6e3, .text = 0x141414, .muted = 0x636261, .faint = 0x838280, .accent = 0x4b6f5a, .fill = 0x4b6f5a, .fill_text = 0xfdfdfd, .surface = 0xffffff, .surface_hover = 0xf6f6f6, .danger = 0xc9363e, .modified = 0xb77a0a, .added = 0x579b6e, .changed = 0x3b81e9, .removed = 0xea7485, .keyword = 0x2f7550, .type = 0x0b7f78, .function = 0x0969a8, .string = 0x8a5a00, .number = 0xb85a1f, .comment = 0x848c86 };
const qoder_dark: Palette = .{ .dark = true, .editor = 0x191b1a, .chrome = 0x242624, .panel = 0x1c1f1d, .border = 0x363c37, .text = 0xd9dcd9, .muted = 0x949d96, .faint = 0x6b736d, .accent = 0x8ee5a1, .fill = 0x4d9c61, .fill_text = 0x080807, .surface = 0x222523, .surface_hover = 0x2d332e, .danger = 0xff6b70, .modified = 0xfaad14, .added = 0x73cd94, .changed = 0x5a9fe0, .removed = 0xe86a70, .keyword = 0x73cd94, .type = 0x82d2ce, .function = 0x87c3ff, .string = 0xd8c07a, .number = 0xefb080, .comment = 0x758077 };

pub const names = [_][]const u8{ "", "matrix", "claude", "qoder" };
pub const titles = [_][]const u8{ "MyCode", "The Matrix", "Claude", "Qoder" };

/// The palette of a theme (`settings.theme`) in a light or dark window.
pub fn palette(theme: []const u8, dark: bool) *const Palette {
    if (std.mem.eql(u8, theme, "matrix")) return &matrix;
    if (std.mem.eql(u8, theme, "claude")) return if (dark) &claude_dark else &claude_light;
    if (std.mem.eql(u8, theme, "qoder")) return if (dark) &qoder_dark else &qoder_light;
    return if (dark) &mycode_dark else &mycode_light;
}

/// myzig's theme made from a palette, for every widget.
pub fn uiTheme(p: *const Palette, mono_font: ?[]const u8) ui.Theme {
    var th = if (p.dark) ui.Theme.dark_theme else ui.Theme.light;
    th.background = .hex(p.editor);
    th.surface = .hex(p.chrome);
    th.surface_hover = .hex(p.surface_hover);
    th.text = .hex(p.text);
    th.muted = .hex(p.muted);
    th.border = .hex(p.border);
    th.accent = .hex(p.fill);
    th.accent_hover = ui.Color.hex(p.fill).mix(.white, 0.1);
    th.accent_text = .hex(p.fill_text);
    th.danger = .hex(p.danger);
    th.success = .hex(p.added);
    th.warning = .hex(p.modified);
    th.mono_font = mono_font;
    if (p.mono) th.font = mono_font orelse "Consolas";
    return th;
}

pub fn syntax(p: *const Palette) ui.SyntaxColors {
    return .{
        .keyword = .hex(p.keyword),
        .string = .hex(p.string),
        .number = .hex(p.number),
        .comment = .hex(p.comment),
        .function = .hex(p.function),
        .type = .hex(p.type),
        .key = .hex(p.function),
    };
}
