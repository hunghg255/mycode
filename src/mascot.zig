//! A theme's character, as the Go app's `mascot.go`: Clawd in Claude and
//! Qoduck in Qoder take the logo's place on the welcome page and sit at the
//! start of the status bar. It blinks now and then and bobs once in a
//! while, and while Git or a search works it hops, in place of the
//! spinner. It steps rather than glides, and holds still while the window
//! has not the keyboard or the system asks for less motion.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;

pub const Kind = enum { clawd, qoduck };

/// The character of a theme, or null.
pub fn of(theme: []const u8) ?Kind {
    if (std.mem.eql(u8, theme, "claude")) return .clawd;
    if (std.mem.eql(u8, theme, "qoder")) return .qoduck;
    return null;
}

pub fn name(k: Kind) []const u8 {
    return switch (k) {
        .clawd => "Claude",
        .qoduck => "Qoder",
    };
}

/// A moment of the character's: its eyes shut, its body lifted by a part
/// of its headroom, which step of the hop.
const Pose = struct { blink: bool = false, lift: f32 = 0, step: u1 = 0 };

const period: i64 = 4200; // between blinks, in milliseconds
const blink_ms: i64 = 140;
const bob_at: i64 = 2100; // into every third period
const bob_ms: i64 = 260;
const hop_ms: i64 = 130; // a step of the hop

/// The pose at a moment, and how long it holds (milliseconds).
fn poseAt(ms: i64, busy: bool) struct { Pose, i64 } {
    if (busy) {
        const k = @divFloor(ms, hop_ms);
        const step: u1 = @intCast(@mod(k, 2));
        return .{ .{ .lift = @floatFromInt(step), .step = step }, hop_ms - @mod(ms, hop_ms) };
    }
    const in = @mod(ms, period);
    const n = @divFloor(ms, period);
    if (in < blink_ms) return .{ .{ .blink = true }, blink_ms - in };
    if (@mod(n, 3) == 0) {
        if (in < bob_at) return .{ .{}, bob_at - in };
        if (in < bob_at + bob_ms) return .{ .{ .lift = 0.5 }, bob_at + bob_ms - in };
    }
    return .{ .{}, period - in };
}

/// The character in cells of a width (1 in the status bar, 4 on the
/// welcome page), on `bg` (Clawd's eyes are cut in it), `tip` under the
/// pointer.
pub fn view(c: *ui.Context, k: Kind, cell: f32, accent: ui.Color, bg: ui.Color, busy: bool, still: bool, tip: []const u8) void {
    var pose: Pose = .{};
    if (!still) {
        const ms: i64 = @intFromFloat(c.time * 1000);
        const p, const hold = poseAt(ms, busy);
        pose = p;
        c.frameIn(@as(f32, @floatFromInt(@max(hold, 16))) / 1000);
    }
    const box = switch (k) {
        .clawd => clawd(c, cell, accent, bg, pose),
        .qoduck => qoduck(c, cell, c.theme.dark, pose),
    };
    const bi = box.interaction();
    box.end();
    ui.tooltip(c, bi, tip);
}

// Clawd, Claude Code's character, in quarter blocks: its body a cell to a
// character, a cell twice as tall as it is wide; its eyes cut from it, its
// legs apart as it hops.
const clawd_art = [_][]const u8{
    "   ############   ",
    "   ############   ",
    " ################ ",
    "   ############   ",
};
const clawd_cols = 18;
const clawd_rows = 5; // the body's and the legs'
const clawd_eyes = [_]usize{ 5, 12 };
const clawd_legs = [2][4]usize{ .{ 4, 6, 11, 13 }, .{ 3, 5, 12, 14 } };

fn clawd(c: *ui.Context, cell: f32, body: ui.Color, bg: ui.Color, p: Pose) ui.Div {
    const ch = 2 * cell;
    const w = clawd_cols * cell;
    const h = (clawd_rows + 1) * ch;
    const box = ui.div(c).w(w).h(h);
    // A cell of headroom over the body, for the hop.
    const y0 = ch * (1 - p.lift);
    const rect = struct {
        fn f(cc: *ui.Context, x: f32, y: f32, rw: f32, rh: f32, color: ui.Color) void {
            _ = cc.leaf(.{ .absolute = true, .offset = .{ .x = x, .y = y }, .width = .{ .px = rw }, .height = .{ .px = rh }, .background = color }, .none, null);
        }
    }.f;
    for (clawd_art, 0..) |line, row| {
        // A run of cells at a time, so the body has no seams.
        var i: usize = 0;
        while (i < clawd_cols) {
            if (line[i] != '#') {
                i += 1;
                continue;
            }
            var j = i;
            while (j < clawd_cols and line[j] == '#') j += 1;
            rect(c, @as(f32, @floatFromInt(i)) * cell, y0 + @as(f32, @floatFromInt(row)) * ch, @as(f32, @floatFromInt(j - i)) * cell, ch, body);
            i = j;
        }
    }
    // The eyes, cut from the second row: shut, a slit.
    const eh = if (p.blink) ch * 0.25 else ch;
    const ey = if (p.blink) y0 + ch * 1.5 else y0 + ch;
    for (clawd_eyes) |col| rect(c, @as(f32, @floatFromInt(col)) * cell, ey, cell, eh, bg);
    const leg_y = y0 + @as(f32, @floatFromInt(clawd_art.len)) * ch;
    for (clawd_legs[p.step]) |col| rect(c, @as(f32, @floatFromInt(col)) * cell, leg_y, cell, ch * (1 + p.lift), body);
    return box;
}

// Qoduck, Qoder's duck, as its icon draws it, a little rounder, in units
// of half a cell in a square of 30 of them, with two cells of headroom.
fn qoduck(c: *ui.Context, cell: f32, dark: bool, p: Pose) ui.Div {
    const u = cell / 2;
    const w = 30 * u;
    const h = 30 * u + 2 * cell;
    const box = ui.div(c).w(w).h(h);
    const dy = 4 * (1 - p.lift);
    const droop: f32 = 0.8 * @as(f32, @floatFromInt(p.step));
    const eh: f32 = if (p.blink) 0.9 else 3.75;
    const edge = @max(0.8, 1 / @max(u, 0.01));
    const light = !dark;
    var buf: [3000]u8 = undefined;
    var edge_buf: [400]u8 = undefined;
    const svg = std.fmt.bufPrint(&buf,
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 30 34"><g transform="translate(0 {d:.2})">
        \\{s}
        \\<path d="M16.5 6.5 Q16.2 3.8 16.9 {d:.2} M14 6.8 Q13.2 4.6 12.6 {d:.2} M19 6.8 Q19.8 4.6 20.6 {d:.2}" fill="none" stroke="#ffd966" stroke-width="2.2" stroke-linecap="round"/>
        \\<path d="M3.5 14 C3.5 8.6 9.2 5.6 16 5.6 C22.8 5.6 29.5 8.6 29.5 14.5 C29.5 23.9 26 29.2 17 29.2 L9.9 29.2 C6.3 29.2 3.5 26.2 3.5 22.6 Z" fill="#ffd966"{s}/>
        \\<path d="M10.9 11.5 Q14.8 14.6 19.6 12.1" fill="none" stroke="#0f0d0c" stroke-width="1.4" stroke-linecap="round"/>
        \\<rect x="{d:.3}" y="{d:.3}" width="2.75" height="{d:.2}" rx="{d:.3}" fill="#0f0d0c"/>
        \\<rect x="{d:.3}" y="{d:.3}" width="2.75" height="{d:.2}" rx="{d:.3}" fill="#0f0d0c"/>
        \\<ellipse cx="7.4" cy="20.4" rx="7.2" ry="4.6" transform="rotate(18 7.4 20.4)" fill="#f87825"{s}/>
        \\</g></svg>
    , .{
        dy,
        // On a light window the tuft is edged too, under it.
        if (light) std.fmt.bufPrint(&edge_buf, "<path d=\"M16.5 6.5 Q16.2 3.8 16.9 {d:.2} M14 6.8 Q13.2 4.6 12.6 {d:.2} M19 6.8 Q19.8 4.6 20.6 {d:.2}\" fill=\"none\" stroke=\"#e3b13a\" stroke-width=\"{d:.2}\" stroke-linecap=\"round\"/>", .{ 1.8 + droop, 3.4 + droop, 3.6 + droop, 2.2 + 2 * edge }) catch "" else "",
        1.8 + droop,
        3.4 + droop,
        3.6 + droop,
        if (light) " stroke=\"#e3b13a\" stroke-width=\"1.6\"" else "",
        11.4 - 1.375,
        16.1 - eh / 2,
        eh,
        @min(2.75, eh) / 2,
        17.15 - 1.375,
        16.9 - eh / 2,
        eh,
        @min(2.75, eh) / 2,
        if (light) " stroke=\"#d6611a\" stroke-width=\"1.6\"" else "",
    }) catch return box;
    const key = c.print("qoduck:{d}:{d}:{}:{}", .{ p.step, @as(u8, @intFromFloat(p.lift * 2)), p.blink, light });
    _ = ui.svg(c, svg, .{ .width = w, .height = h, .key = key });
    return box;
}

test poseAt {
    try std.testing.expect(poseAt(10, false)[0].blink);
    try std.testing.expect(!poseAt(500, false)[0].blink);
    try std.testing.expectEqual(@as(f32, 0.5), poseAt(bob_at + 10, false)[0].lift);
    try std.testing.expectEqual(@as(u1, 1), poseAt(hop_ms + 1, true)[0].step);
}
