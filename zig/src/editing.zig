//! Editing commands on a text area, each one step of undo: moving, copying,
//! deleting and inserting lines, sorting them, changing case.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;

const Span = struct { first: usize, last: usize, a: usize, b: usize };

/// The lines the selection covers (a selection ending at a line's start
/// leaves that line out), and their bytes with the last newline.
fn span(ta: *const ui.TextArea) Span {
    const lo = ta.sel.lo();
    const hi = ta.sel.hi();
    const first = ta.doc.lineOf(lo);
    var last = ta.doc.lineOf(hi);
    if (last > first and hi == ta.doc.lineStart(last)) last -= 1;
    return .{ .first = first, .last = last, .a = ta.doc.lineStart(first), .b = ta.lineRange(last)[1] };
}

fn withNewline(gpa: std.mem.Allocator, s: []const u8) []u8 {
    if (s.len > 0 and s[s.len - 1] == '\n') return gpa.dupe(u8, s) catch &.{};
    var out = gpa.alloc(u8, s.len + 1) catch return &.{};
    @memcpy(out[0..s.len], s);
    out[s.len] = '\n';
    return out;
}

/// Replaces [a, b) and selects [sel_a, sel_b) after, in one step.
fn replaceKeeping(ta: *ui.TextArea, a: usize, b: usize, s: []const u8, sel_a: usize, sel_b: usize) void {
    ta.replaceRange(a, b, s, .other);
    ta.select(sel_a, sel_b);
}

pub fn moveLines(ta: *ui.TextArea, gpa: std.mem.Allocator, up: bool) void {
    const sp = span(ta);
    const n = ta.doc.lineCount();
    if (up and sp.first == 0) return;
    if (!up and sp.last + 1 >= n) return;
    const block = withNewline(gpa, ta.doc.slice(gpa, sp.a, sp.b));
    defer gpa.free(block);
    const off_anchor = ta.sel.anchor - sp.a;
    const off_caret = ta.sel.caret - sp.a;
    if (up) {
        const pr = ta.lineRange(sp.first - 1);
        const prev = withNewline(gpa, ta.doc.slice(gpa, pr[0], pr[1]));
        defer gpa.free(prev);
        const joined = std.mem.concat(gpa, u8, &.{ block, prev }) catch return;
        defer gpa.free(joined);
        const end = if (sp.b == ta.len() and (sp.b == 0 or ta.doc.byteAt(sp.b - 1) != '\n')) joined[0 .. joined.len - 1] else joined;
        ta.replaceRange(pr[0], sp.b, end, .other);
        ta.select(pr[0] + off_anchor, pr[0] + off_caret);
    } else {
        const nr = ta.lineRange(sp.last + 1);
        const next = withNewline(gpa, ta.doc.slice(gpa, nr[0], nr[1]));
        defer gpa.free(next);
        const joined = std.mem.concat(gpa, u8, &.{ next, block }) catch return;
        defer gpa.free(joined);
        const end = if (nr[1] == ta.len() and (nr[1] == 0 or ta.doc.byteAt(nr[1] - 1) != '\n')) joined[0 .. joined.len - 1] else joined;
        ta.replaceRange(sp.a, nr[1], end, .other);
        const shift = sp.a + next.len;
        ta.select(shift + off_anchor, shift + off_caret);
    }
}

/// Selects the lines of the selection, with their newlines; again, the
/// next line too (Ctrl+L).
pub fn selectLines(ta: *ui.TextArea) void {
    const sp = span(ta);
    var b = sp.b;
    if (ta.sel.lo() == sp.a and ta.sel.hi() == sp.b and sp.last + 1 < ta.doc.lineCount()) b = ta.lineRange(sp.last + 1)[1];
    ta.select(sp.a, b);
}

pub fn copyLines(ta: *ui.TextArea, gpa: std.mem.Allocator, up: bool) void {
    const sp = span(ta);
    const block = withNewline(gpa, ta.doc.slice(gpa, sp.a, sp.b));
    defer gpa.free(block);
    const anchor = ta.sel.anchor;
    const caret = ta.sel.caret;
    if (sp.b == ta.len() and (sp.b == 0 or ta.doc.byteAt(sp.b - 1) != '\n')) {
        // The last line has no newline: put one before the copy.
        const s = std.mem.concat(gpa, u8, &.{ "\n", block[0 .. block.len - 1] }) catch return;
        defer gpa.free(s);
        ta.replaceRange(sp.b, sp.b, s, .other);
    } else ta.replaceRange(sp.b, sp.b, block, .other);
    if (up) ta.select(anchor, caret) else ta.select(anchor + block.len, caret + block.len);
}

pub fn deleteLines(ta: *ui.TextArea) void {
    const sp = span(ta);
    var a = sp.a;
    const b = sp.b;
    // The last line: take the newline before it instead.
    if (b == ta.len() and a > 0 and (b == 0 or ta.doc.byteAt(b - 1) != '\n')) a -= 1;
    ta.replaceRange(a, b, "", .other);
    ta.collapse(@min(sp.a, ta.len()));
}

pub fn insertLine(ta: *ui.TextArea, gpa: std.mem.Allocator, above: bool) void {
    const line = ta.caretLine();
    const r = ta.lineRange(line);
    const text = ta.doc.slice(gpa, r[0], r[1]);
    defer gpa.free(text);
    var ind: usize = 0;
    while (ind < text.len and (text[ind] == ' ' or text[ind] == '\t')) ind += 1;
    if (above) {
        const s = std.mem.concat(gpa, u8, &.{ text[0..ind], "\n" }) catch return;
        defer gpa.free(s);
        ta.replaceRange(r[0], r[0], s, .other);
        ta.collapse(r[0] + ind);
    } else {
        const end = ta.doc.lineEnd(line);
        const s = std.mem.concat(gpa, u8, &.{ "\n", text[0..ind] }) catch return;
        defer gpa.free(s);
        ta.replaceRange(end, end, s, .other);
        ta.collapse(end + s.len);
    }
}

/// Sorts the lines selected, or every line.
pub fn sortLines(ta: *ui.TextArea, gpa: std.mem.Allocator, descending: bool) void {
    const whole = ta.sel.lo() == ta.sel.hi();
    const a = if (whole) 0 else span(ta).a;
    const b = if (whole) ta.len() else span(ta).b;
    const text = ta.doc.slice(gpa, a, b);
    defer gpa.free(text);
    const trailing = text.len > 0 and text[text.len - 1] == '\n';
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, if (trailing) text[0 .. text.len - 1] else text, '\n');
    while (it.next()) |l| lines.append(gpa, l) catch return;
    const Ctx = struct {
        desc: bool,
        fn lt(cx: @This(), x: []const u8, y: []const u8) bool {
            return if (cx.desc) std.mem.order(u8, y, x) == .lt else std.mem.order(u8, x, y) == .lt;
        }
    };
    std.mem.sort([]const u8, lines.items, Ctx{ .desc = descending }, Ctx.lt);
    var out = std.mem.join(gpa, "\n", lines.items) catch return;
    defer gpa.free(out);
    if (trailing) {
        const o2 = std.mem.concat(gpa, u8, &.{ out, "\n" }) catch return;
        gpa.free(out);
        out = o2;
    }
    replaceKeeping(ta, a, b, out, a, a + out.len);
}

pub const Case = enum { upper, lower, camel, snake, title };

/// Changes the case of the words selected, or of the word at the caret.
pub fn changeCase(ta: *ui.TextArea, gpa: std.mem.Allocator, case: Case) void {
    var a = ta.sel.lo();
    var b = ta.sel.hi();
    if (a == b) {
        const w = ta.wordAt(a);
        a = w[0];
        b = w[1];
    }
    const text = ta.doc.slice(gpa, a, b);
    defer gpa.free(text);
    const out = transform(gpa, text, case) catch return;
    defer gpa.free(out);
    replaceKeeping(ta, a, b, out, a, a + out.len);
}

pub fn transform(gpa: std.mem.Allocator, s: []const u8, case: Case) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    switch (case) {
        .upper => for (s) |ch| try out.append(gpa, std.ascii.toUpper(ch)),
        .lower => for (s) |ch| try out.append(gpa, std.ascii.toLower(ch)),
        .camel, .snake, .title => {
            // Words split at spaces, _, - and lower-to-upper turns.
            var start_word = true;
            var first = true;
            for (s, 0..) |ch, i| {
                if (ch == '_' or ch == '-' or ch == ' ') {
                    if (ch == ' ' and case == .title) try out.append(gpa, ' ');
                    start_word = true;
                    continue;
                }
                const turn = i > 0 and std.ascii.isUpper(ch) and std.ascii.isLower(s[i - 1]);
                if (turn) start_word = true;
                if (start_word and !first and case == .snake) try out.append(gpa, '_');
                const up = start_word and (case == .title or (case == .camel and !first));
                try out.append(gpa, if (case == .snake) std.ascii.toLower(ch) else if (up) std.ascii.toUpper(ch) else if (start_word or case == .camel) std.ascii.toLower(ch) else ch);
                start_word = false;
                first = false;
            }
        },
    }
    return out.toOwnedSlice(gpa);
}

pub fn trimTrailingWhitespace(ta: *ui.TextArea, gpa: std.mem.Allocator) void {
    const text = ta.text(gpa);
    defer gpa.free(text);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |l| {
        if (!first) out.append(gpa, '\n') catch return;
        first = false;
        out.appendSlice(gpa, std.mem.trimEnd(u8, l, " \t\r")) catch return;
    }
    if (std.mem.eql(u8, out.items, text)) return;
    const caret = @min(ta.sel.caret, out.items.len);
    ta.replaceRange(0, ta.len(), out.items, .other);
    ta.collapse(caret);
}

test transform {
    const gpa = std.testing.allocator;
    const cases = [_]struct { []const u8, Case, []const u8 }{
        .{ "hello_world", .camel, "helloWorld" },
        .{ "HelloWorld", .snake, "hello_world" },
        .{ "some-name here", .camel, "someNameHere" },
        .{ "abc", .upper, "ABC" },
    };
    for (cases) |cs| {
        const o = try transform(gpa, cs[0], cs[1]);
        defer gpa.free(o);
        try std.testing.expectEqualStrings(cs[2], o);
    }
}

test selectLines {
    var ta: ui.TextArea = .init(std.testing.allocator, "one\ntwo\nthree");
    defer ta.deinit();
    ta.collapse(1);
    selectLines(&ta);
    try std.testing.expectEqual(@as(usize, 0), ta.sel.lo());
    try std.testing.expectEqual(@as(usize, 4), ta.sel.hi());
    selectLines(&ta);
    try std.testing.expectEqual(@as(usize, 8), ta.sel.hi());
}
