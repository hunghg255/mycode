//! A file's functions, types and headings, found by their lines' shapes,
//! for `@` in quick open, sticky scroll and the breadcrumbs.
const std = @import("std");

pub const Symbol = struct {
    name: []const u8,
    kind: Kind,
    line: usize,
    /// Its line's indentation, in columns: blocks nest by it.
    indent: usize,
};

pub const Kind = enum { function, type, heading, other };

const Rule = struct { prefix: []const u8, kind: Kind };

const rules = [_]Rule{
    .{ .prefix = "func ", .kind = .function },
    .{ .prefix = "fn ", .kind = .function },
    .{ .prefix = "pub fn ", .kind = .function },
    .{ .prefix = "export fn ", .kind = .function },
    .{ .prefix = "def ", .kind = .function },
    .{ .prefix = "async def ", .kind = .function },
    .{ .prefix = "function ", .kind = .function },
    .{ .prefix = "async function ", .kind = .function },
    .{ .prefix = "export function ", .kind = .function },
    .{ .prefix = "export async function ", .kind = .function },
    .{ .prefix = "export default function ", .kind = .function },
    .{ .prefix = "pub async fn ", .kind = .function },
    .{ .prefix = "async fn ", .kind = .function },
    .{ .prefix = "type ", .kind = .type },
    .{ .prefix = "class ", .kind = .type },
    .{ .prefix = "export class ", .kind = .type },
    .{ .prefix = "export default class ", .kind = .type },
    .{ .prefix = "interface ", .kind = .type },
    .{ .prefix = "export interface ", .kind = .type },
    .{ .prefix = "export type ", .kind = .type },
    .{ .prefix = "struct ", .kind = .type },
    .{ .prefix = "pub struct ", .kind = .type },
    .{ .prefix = "enum ", .kind = .type },
    .{ .prefix = "pub enum ", .kind = .type },
    .{ .prefix = "trait ", .kind = .type },
    .{ .prefix = "pub trait ", .kind = .type },
    .{ .prefix = "impl ", .kind = .type },
    .{ .prefix = "impl<", .kind = .type },
};

fn identEnd(s: []const u8) usize {
    var i: usize = 0;
    while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '_' or s[i] == '$' or s[i] == '.' or s[i] >= 0x80)) i += 1;
    return i;
}

/// The symbol a line declares, if it declares one.
pub fn ofLine(line: []const u8, markdown: bool) ?Symbol {
    var indent: usize = 0;
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) indent += if (line[i] == '\t') 4 else 1;
    const rest = line[i..];
    if (markdown) {
        if (!std.mem.startsWith(u8, rest, "#")) return null;
        var h: usize = 0;
        while (h < rest.len and rest[h] == '#') h += 1;
        if (h > 6 or h >= rest.len or rest[h] != ' ') return null;
        return .{ .name = std.mem.trim(u8, rest[h..], " #"), .kind = .heading, .line = 0, .indent = h };
    }
    for (rules) |r| if (std.mem.startsWith(u8, rest, r.prefix)) {
        var name = rest[r.prefix.len..];
        // A Go method: func (r *T) Name(
        if (std.mem.eql(u8, r.prefix, "func ") and name.len > 0 and name[0] == '(') {
            const close = std.mem.indexOfScalar(u8, name, ')') orelse return null;
            name = std.mem.trimStart(u8, name[close + 1 ..], " ");
        }
        const n = identEnd(name);
        if (n == 0) return null;
        return .{ .name = name[0..n], .kind = r.kind, .line = 0, .indent = indent };
    };
    // Zig's `const Name = struct {` and JS's `const name = (...) =>`.
    inline for (.{ "pub const ", "const ", "export const ", "let " }) |p| if (std.mem.startsWith(u8, rest, p)) {
        const name = rest[p.len..];
        const n = identEnd(name);
        if (n == 0) return null;
        const after = rest[p.len + n ..];
        if (std.mem.indexOf(u8, after, "struct") != null or std.mem.indexOf(u8, after, "enum") != null or std.mem.indexOf(u8, after, "union") != null)
            return .{ .name = name[0..n], .kind = .type, .line = 0, .indent = indent };
        if (std.mem.indexOf(u8, after, "=>") != null or std.mem.indexOf(u8, after, "function") != null)
            return .{ .name = name[0..n], .kind = .function, .line = 0, .indent = indent };
        return null;
    };
    return null;
}

/// Every symbol of a text; names are slices of it.
pub fn find(gpa: std.mem.Allocator, text: []const u8, markdown: bool) ![]Symbol {
    var out: std.ArrayList(Symbol) = .empty;
    errdefer out.deinit(gpa);
    var it = std.mem.splitScalar(u8, text, '\n');
    var ln: usize = 0;
    var in_fence = false;
    while (it.next()) |l| : (ln += 1) {
        if (markdown and std.mem.startsWith(u8, std.mem.trimStart(u8, l, " "), "```")) in_fence = !in_fence;
        if (in_fence) continue;
        if (ofLine(std.mem.trimEnd(u8, l, "\r"), markdown)) |s0| {
            var s = s0;
            s.line = ln;
            try out.append(gpa, s);
        }
    }
    return out.toOwnedSlice(gpa);
}

/// The symbols around a line: those above it at a smaller indentation,
/// outermost first (headings by their level).
pub fn around(buf: []Symbol, all: []const Symbol, line: usize) []Symbol {
    var n: usize = 0;
    var limit: usize = std.math.maxInt(usize);
    var i: usize = all.len;
    while (i > 0) {
        i -= 1;
        const s = all[i];
        if (s.line > line) continue;
        if (s.indent < limit) {
            if (n == buf.len) break;
            buf[n] = s;
            n += 1;
            limit = s.indent;
            if (limit == 0) break;
        }
    }
    std.mem.reverse(Symbol, buf[0..n]);
    return buf[0..n];
}

test find {
    const gpa = std.testing.allocator;
    const src = "package x\n\nfunc (a *App) Run() {\n}\n\ntype T struct{}\nconst Foo = struct {\n    fn bar() void {}\n};\n";
    const s = try find(gpa, src, false);
    defer gpa.free(s);
    try std.testing.expectEqual(@as(usize, 4), s.len);
    try std.testing.expectEqualStrings("Run", s[0].name);
    var buf: [8]Symbol = undefined;
    const ar = around(&buf, s, 7);
    try std.testing.expectEqual(@as(usize, 2), ar.len);
    try std.testing.expectEqualStrings("bar", ar[1].name);
}
