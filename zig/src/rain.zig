//! The rain of The Matrix, behind the welcome page, as rain.go has it:
//! columns of glyphs that fall at their own speeds, the head of each bright
//! and its trail fading. It steps rather than glides, as the film's does,
//! and holds still while the window hasn't the keyboard.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;

const cell_w: f32 = 16;
const cell_h: f32 = 18;
const size: f32 = 13;
const step_seconds: f64 = 0.07;

/// Half-width katakana and digits, as UTF-8.
const glyphs = blk: {
    var out: [0xff9d - 0xff66 + 1 + 10][]const u8 = undefined;
    var i: usize = 0;
    var r: u21 = 0xff66;
    while (r <= 0xff9d) : (r += 1) {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(r, &buf) catch unreachable;
        const final = buf[0..n].*;
        out[i] = &final;
        i += 1;
    }
    for ("0123456789") |d| {
        out[i] = &[_]u8{d};
        i += 1;
    }
    break :blk out;
};

fn hash3(a: u32, b: u32, c: u32) u32 {
    var h = a *% 0x9e3779b1 ^ b *% 0x85ebca77 ^ c *% 0xc2b2ae3d;
    h ^= h >> 15;
    h *%= 0x2c1b3c6d;
    h ^= h >> 12;
    h *%= 0x297a2d39;
    h ^= h >> 15;
    return h;
}

/// The step the rain is at: it moves on while `moving`.
pub const Rain = struct {
    step: i64 = 0,
};

/// Paints the rain over a w×h area at the top left of the box it is in.
pub fn draw(c: *ui.Context, rs: *Rain, w: f32, h: f32, text: ui.Color, accent: ui.Color, moving: bool) void {
    if (moving) {
        rs.step = @intFromFloat(c.time / step_seconds);
        c.frameIn(@floatCast(step_seconds));
    }
    const head = text.mix(.white, 0.55).alpha(0.5);
    const cols: usize = @intFromFloat(w / cell_w + 1);
    const rows: usize = @intFromFloat(h / cell_h + 1);
    const box = ui.div(c).absolute().offset(0, 0).w(w).h(h).clip();
    defer box.end();
    for (0..cols) |i| {
        const ci: u32 = @intCast(i);
        // Each column has its speed, its trail and a pause between drops.
        const speed = 0.25 + @as(f64, @floatFromInt(hash3(ci, 1, 0) % 1000)) / 1000 * 0.75;
        const trail: usize = 6 + hash3(ci, 2, 0) % 18;
        const cycle: usize = rows + trail + hash3(ci, 3, 0) % @as(u32, @intCast(rows + 1));
        const at: usize = @intFromFloat(@mod(@as(f64, @floatFromInt(rs.step)) * speed + @as(f64, @floatFromInt(hash3(ci, 4, 0) % 997)), @as(f64, @floatFromInt(cycle))));
        const x = @as(f32, @floatFromInt(i)) * cell_w;
        for (0..trail) |k| {
            if (k > at) break;
            const row = at - k;
            if (row >= rows) continue;
            // A glyph changes now and then where it is, the head each step.
            const every: i64 = @intCast(4 + hash3(ci, @intCast(row), 5) % 12);
            const tick: u32 = @truncate(@as(u64, @bitCast(if (k == 0) rs.step else @divTrunc(rs.step, every))));
            const g = glyphs[hash3(ci, @intCast(row), tick) % glyphs.len];
            const col = if (k == 0) head else accent.alpha(0.26 * (1 - @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(trail))));
            _ = c.leaf(.{ .absolute = true, .offset = .{ .x = x, .y = @as(f32, @floatFromInt(row)) * cell_h } }, .{ .text = .{ .str = g, .style = .{ .size = size, .mono = true }, .color = col } }, null);
        }
    }
}
