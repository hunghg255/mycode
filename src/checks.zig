//! The checkerboard behind pictures, which shows what is transparent: one
//! tile of checks, made once as a PNG (stored, not compressed) and drawn
//! as often as the picture needs it, so the image atlas keeps one copy.
const std = @import("std");

/// The tile's side in pixels, and a check's: 16 checks across, 8 points
/// each at 2×.
pub const side: u32 = 256;
const cell: u32 = 16;

/// A PNG of the tile, in two grays: light or dark.
pub fn png(gpa: std.mem.Allocator, dark: bool) ![]u8 {
    const a: u8 = if (dark) 0x2e else 0xff;
    const b: u8 = if (dark) 0x26 else 0xe8;
    // The raw rows: a filter byte (none), then gray pixels.
    const row = side + 1;
    const raw = try gpa.alloc(u8, row * side);
    defer gpa.free(raw);
    for (0..side) |y| {
        raw[y * row] = 0;
        for (0..side) |x| raw[y * row + 1 + x] = if (((x / cell) + (y / cell)) % 2 == 0) a else b;
    }
    // zlib: stored blocks of at most 65,535 bytes.
    var z: std.ArrayList(u8) = .empty;
    defer z.deinit(gpa);
    try z.appendSlice(gpa, &.{ 0x78, 0x01 });
    var i: usize = 0;
    while (i < raw.len) {
        const n = @min(raw.len - i, 65535);
        const last: u8 = @intFromBool(i + n == raw.len);
        const len: u16 = @intCast(n);
        try z.append(gpa, last);
        try z.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, len)));
        try z.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, ~len)));
        try z.appendSlice(gpa, raw[i..][0..n]);
        i += n;
    }
    try z.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u32, std.hash.Adler32.hash(raw))));

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], side, .big);
    std.mem.writeInt(u32, ihdr[4..8], side, .big);
    ihdr[8] = 8; // bits
    ihdr[9] = 0; // gray
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try chunk(gpa, &out, "IHDR", &ihdr);
    try chunk(gpa, &out, "IDAT", z.items);
    try chunk(gpa, &out, "IEND", "");
    return out.toOwnedSlice(gpa);
}

fn chunk(gpa: std.mem.Allocator, out: *std.ArrayList(u8), kind: *const [4]u8, data: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try out.appendSlice(gpa, &len);
    try out.appendSlice(gpa, kind);
    try out.appendSlice(gpa, data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    var sum: [4]u8 = undefined;
    std.mem.writeInt(u32, &sum, crc.final(), .big);
    try out.appendSlice(gpa, &sum);
}

test png {
    const p = try png(std.testing.allocator, false);
    defer std.testing.allocator.free(p);
    try std.testing.expect(std.mem.startsWith(u8, p, "\x89PNG"));
    try std.testing.expect(std.mem.endsWith(u8, p[0 .. p.len - 4], "IEND"));
}
