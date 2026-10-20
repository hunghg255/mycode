//! A file open in a tab: its text in a code editor, saving and reloading,
//! the lines changed since the last commit (the gutter's marks), and what
//! the editor draws over its lines: other occurrences of the word at the
//! caret, conflict blocks and review comments.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const fs = @import("fs.zig");
const git = @import("git.zig");
const conflicts = @import("conflicts.zig");

pub const Mark = enum(u8) { none, added, changed, removed };

pub const MdImage = struct { bytes: []u8, key: []u8, mtime: i96 };

pub const Note = struct { line: usize, text: []const u8, color: ui.Color };

pub const Colors = struct {
    added: ui.Color = .hex(0x4fa86d),
    changed: ui.Color = .hex(0x5a8ee0),
    removed: ui.Color = .hex(0xe0607e),
    word: ui.Color = .{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 0.18 },
    current: ui.Color = .hex(0x4fa86d),
    incoming: ui.Color = .hex(0x5a8ee0),
    comment: ui.Color = .hex(0xe8b86d),
};

/// Shared by every file: the theme's colors for the marks.
pub var colors: Colors = .{};

pub const Doc = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Absolute; empty for an untitled file.
    path: []u8,
    editor: ui.CodeEditor,
    /// The document's version when last saved or read.
    saved: u64 = 0,
    /// The version auto save last saw, and when it changed.
    seen: u64 = 0,
    edited_at: f64 = 0,
    mtime: i96 = 0,
    binary: bool = false,
    crlf: bool = false,
    /// Word wrap set for this tab alone (Alt+Z), over the setting.
    own_wrap: ?bool = null,
    /// Markdown or SVG shown rendered rather than as text.
    rendered: bool = false,
    md: ?ui.Markdown = null,
    /// The local pictures its Markdown shows, read once: by path, the
    /// bytes and when they were read (`viewer.zig`).
    md_images: std.StringHashMapUnmanaged(MdImage) = .empty,
    /// The file as HEAD has it, read once; null outside Git or for a new file.
    base: ?[]u8 = null,
    base_read: bool = false,
    /// Per line: changed since HEAD.
    marks: std.ArrayList(Mark) = .empty,
    marks_version: u64 = std.math.maxInt(u64),
    /// Conflict blocks, found again as the text changes.
    blocks: []conflicts.Block = &.{},
    blocks_version: u64 = std.math.maxInt(u64),
    /// The tabs showing it: two columns can share a file's text and undo.
    refs: u32 = 1,
    /// The change whose HEAD lines show in a box (a gutter mark clicked).
    peek: ?usize = null,
    /// The file was deleted on the disk (`reloadIfChanged` saw it gone).
    disk_gone: bool = false,
    /// How far the editor is scrolled, as of the last frame, and a scroll
    /// to give it in the next (a tab opened again, a session restored).
    scroll_y: f32 = 0,
    restore_scroll: ?f32 = null,
    /// Its minimap's drags.
    mini: @import("minimap.zig").State = .{},
    /// The lines in view in the last frame.
    first_line: usize = 0,
    last_line: usize = 0,
    /// Lines with review comments (from 0), set by the workbench.
    comment_lines: []const [2]usize = &.{},
    /// Text after lines' ends, set by the workbench each frame: the caret
    /// line's blame, the review comments after their last line.
    notes: []const Note = &.{},

    pub fn create(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !*Doc {
        const d = try gpa.create(Doc);
        errdefer gpa.destroy(d);
        d.* = .{ .gpa = gpa, .io = io, .path = try gpa.dupe(u8, path), .editor = .init(gpa, "", if (path.len > 0) std.fs.path.basename(path) else null) };
        d.editor.extra = .{ .ctx = d, .marks = lineMarks, .gutter = gutterMark, .after = afterLine };
        if (path.len > 0) try d.read();
        d.saved = d.editor.area.doc.version;
        d.seen = d.saved;
        return d;
    }

    /// Another tab shows the file (Split Right): they share its text.
    pub fn retain(d: *Doc) *Doc {
        d.refs += 1;
        return d;
    }

    /// A tab lets go of it; the last frees it.
    pub fn release(d: *Doc) void {
        d.refs -= 1;
        if (d.refs == 0) d.destroy();
    }

    pub fn destroy(d: *Doc) void {
        d.editor.deinit();
        if (d.md) |*m| m.deinit();
        var mi = d.md_images.iterator();
        while (mi.next()) |e| {
            d.gpa.free(e.key_ptr.*);
            d.gpa.free(e.value_ptr.bytes);
            d.gpa.free(e.value_ptr.key);
        }
        d.md_images.deinit(d.gpa);
        if (d.base) |b| d.gpa.free(b);
        d.marks.deinit(d.gpa);
        d.gpa.free(d.blocks);
        d.gpa.free(d.path);
        d.gpa.destroy(d);
    }

    fn read(d: *Doc) !void {
        const data = try fs.read(d.gpa, d.io, d.path);
        defer d.gpa.free(data);
        d.binary = fs.binary(data);
        d.crlf = std.mem.indexOf(u8, data, "\r\n") != null;
        d.mtime = fs.mtime(d.io, d.path);
        if (d.binary) {
            d.editor.area.reset("This file is binary, and is not shown.");
            d.editor.read_only = true;
            return;
        }
        const body = try stripCr(d.gpa, data, d.crlf);
        defer if (d.crlf) d.gpa.free(body);
        d.editor.area.reset(body);
        if (indentedWithTabs(body)) d.editor.indent.unit = "\t";
    }

    pub fn name(d: *const Doc) []const u8 {
        return if (d.path.len == 0) "Untitled" else std.fs.path.basename(d.path);
    }

    pub fn dirty(d: *const Doc) bool {
        return d.editor.area.doc.version != d.saved;
    }

    pub fn text(d: *const Doc) []u8 {
        return d.editor.area.text(d.gpa);
    }

    pub fn save(d: *Doc) !void {
        if (d.path.len == 0 or d.binary or !d.dirty()) return;
        const t = d.text();
        defer d.gpa.free(t);
        if (d.crlf) {
            const out = try withCrlf(d.gpa, t);
            defer d.gpa.free(out);
            try fs.write(d.io, d.path, out);
        } else try fs.write(d.io, d.path, t);
        d.saved = d.editor.area.doc.version;
        d.mtime = fs.mtime(d.io, d.path);
    }

    pub fn setPath(d: *Doc, path: []const u8) !void {
        d.gpa.free(d.path);
        d.path = try d.gpa.dupe(u8, path);
        d.editor.setLanguage(std.fs.path.basename(path));
        d.saved = d.editor.area.doc.version +% 1;
        d.base_read = false;
    }

    /// Reads the file again when it changed on disk, unless it has edits.
    /// Reloading is a step of undo. True when the text changed.
    pub fn reloadIfChanged(d: *Doc) bool {
        if (d.path.len == 0 or d.binary) return false;
        const m = fs.mtime(d.io, d.path);
        // Gone from the disk: the status bar says so; its text stays.
        d.disk_gone = m == 0;
        if (m == 0 or m == d.mtime) return false;
        d.mtime = m;
        if (d.dirty()) return false;
        const data = fs.read(d.gpa, d.io, d.path) catch return false;
        defer d.gpa.free(data);
        const crlf = std.mem.indexOf(u8, data, "\r\n") != null;
        const t = stripCr(d.gpa, data, crlf) catch return false;
        defer if (crlf) d.gpa.free(t);
        const now = d.text();
        defer d.gpa.free(now);
        if (std.mem.eql(u8, now, t)) return false;
        d.editor.area.setText(t);
        d.crlf = crlf;
        d.saved = d.editor.area.doc.version;
        d.seen = d.saved;
        return true;
    }

    /// Forgets HEAD's text, so the marks are made again (after a commit).
    pub fn resetBase(d: *Doc) void {
        if (d.base) |b| d.gpa.free(b);
        d.base = null;
        d.base_read = false;
        d.marks_version = std.math.maxInt(u64);
    }

    /// The marks of the lines changed since HEAD, made again when the text changed.
    pub fn updateMarks(d: *Doc, top: ?[]const u8) void {
        const v = d.editor.area.doc.version;
        if (d.marks_version == v) return;
        d.marks_version = v;
        d.marks.clearRetainingCapacity();
        if (d.path.len == 0 or d.binary) return;
        const t = top orelse return;
        if (!d.base_read) {
            d.base_read = true;
            const rel = fs.relative(t, d.path);
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const spec = std.fmt.bufPrint(&buf, "HEAD:{s}", .{rel}) catch return;
            std.mem.replaceScalar(u8, spec, '\\', '/');
            const r = git.run(d.gpa, d.io, t, &.{ "show", spec }) catch return;
            d.gpa.free(r.stderr);
            if (r.ok) {
                if (std.mem.indexOf(u8, r.stdout, "\r\n") != null) {
                    d.base = std.mem.replaceOwned(u8, d.gpa, r.stdout, "\r\n", "\n") catch null;
                    d.gpa.free(r.stdout);
                } else d.base = r.stdout;
            } else d.gpa.free(r.stdout);
        }
        const now = d.text();
        defer d.gpa.free(now);
        const lines = d.editor.area.doc.lineCount();
        d.marks.appendNTimes(d.gpa, .none, lines) catch return;
        const base = d.base orelse return;
        if (base.len + now.len > 8 << 20) return;
        const a = ui.diff.splitLines(d.gpa, base) catch return;
        defer d.gpa.free(a);
        const b = ui.diff.splitLines(d.gpa, now) catch return;
        defer d.gpa.free(b);
        const hunks = ui.diff.lines(d.gpa, a, b) catch return;
        defer d.gpa.free(hunks);
        for (hunks) |h| {
            if (h.b0 == h.b1) {
                if (h.b0 < lines) d.marks.items[h.b0] = .removed else if (lines > 0) d.marks.items[lines - 1] = .removed;
                continue;
            }
            const m: Mark = if (h.a0 == h.a1) .added else .changed;
            for (h.b0..@min(h.b1, lines)) |i| d.marks.items[i] = m;
        }
    }

    pub fn updateConflicts(d: *Doc) void {
        const v = d.editor.area.doc.version;
        if (d.blocks_version == v) return;
        d.blocks_version = v;
        d.gpa.free(d.blocks);
        d.blocks = &.{};
        if (d.binary) return;
        const t = d.text();
        defer d.gpa.free(t);
        if (std.mem.indexOf(u8, t, "<<<<<<<") == null) return;
        d.blocks = conflicts.find(d.gpa, t) catch &.{};
    }

    /// The next change (or the previous) from the caret: its first line.
    pub fn nextChange(d: *Doc, forward: bool) ?usize {
        const caret = d.editor.area.caretLine();
        const m = d.marks.items;
        if (forward) {
            var i = caret;
            while (i < m.len and m[i] != .none) i += 1;
            while (i < m.len) : (i += 1) if (m[i] != .none) return i;
            // Around to the first.
            for (m, 0..) |x, k| if (x != .none) return if (k < caret) k else null;
        } else {
            var i = caret;
            while (i > 0 and m[i] != .none) i -= 1;
            while (i > 0) : (i -= 1) if (m[i] != .none) {
                var s = i;
                while (s > 0 and m[s - 1] == m[i]) s -= 1;
                return s;
            };
        }
        return null;
    }
};

fn gutterMark(ctx: *anyopaque, _: *ui.Context, line: usize) ?ui.Color {
    const d: *Doc = @ptrCast(@alignCast(ctx));
    for (d.comment_lines) |r| if (line >= r[0] and line <= r[1]) return colors.comment;
    if (line >= d.marks.items.len) return null;
    return switch (d.marks.items[line]) {
        .none => null,
        .added => colors.added,
        .changed => colors.changed,
        .removed => colors.removed,
    };
}

fn afterLine(ctx: *anyopaque, _: *ui.Context, line: usize) ?ui.TextAfter {
    const d: *Doc = @ptrCast(@alignCast(ctx));
    for (d.notes) |n| if (n.line == line) return .{ .text = n.text, .color = n.color };
    return null;
}

fn isWordByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_' or b >= 0x80;
}

fn lineMarks(ctx: *anyopaque, c: *ui.Context, line: usize, start: usize, str: []const u8) []const ui.TextMark {
    const d: *Doc = @ptrCast(@alignCast(ctx));
    var out: std.ArrayList(ui.TextMark) = .empty;
    const a = c.alloc();
    // Conflict blocks: the current side and the incoming one tinted.
    for (d.blocks) |b| if (line >= b.start and line <= b.end) {
        const col: ?ui.Color = if (line == b.start or line == b.end or line == b.sep or (b.base != null and line == b.base.?))
            colors.word
        else if (line < (b.base orelse b.sep))
            colors.current.alpha(0.16)
        else if (line > b.sep)
            colors.incoming.alpha(0.16)
        else
            colors.word;
        if (col) |cc| out.append(a, .{ .start = 0, .end = ui.TextMark.whole, .color = cc }) catch {};
    };
    // Other occurrences of the word at the caret.
    const ta = &d.editor.area;
    if (ta.sel.anchor == ta.sel.caret and str.len < 2000) {
        const w = ta.wordAt(ta.sel.caret);
        const wl = w[1] - w[0];
        if (wl >= 2 and wl <= 64) {
            var buf: [64]u8 = undefined;
            const word = ta.doc.slice(a, w[0], w[1]);
            if (word.len == wl and isWordByte(word[0])) {
                @memcpy(buf[0..wl], word);
                var i: usize = 0;
                while (std.mem.indexOfPos(u8, str, i, buf[0..wl])) |at| : (i = at + wl) {
                    const before_ok = at == 0 or !isWordByte(str[at - 1]);
                    const after_ok = at + wl >= str.len or !isWordByte(str[at + wl]);
                    if (before_ok and after_ok and start + at != w[0])
                        out.append(a, .{ .start = @intCast(at), .end = @intCast(at + wl), .color = colors.word }) catch break;
                }
            }
        }
    }
    return out.items;
}

fn indentedWithTabs(text: []const u8) bool {
    var tabs: usize = 0;
    var spaces: usize = 0;
    var it = std.mem.splitScalar(u8, text[0..@min(text.len, 64 << 10)], '\n');
    while (it.next()) |l| {
        if (l.len == 0) continue;
        if (l[0] == '\t') tabs += 1 else if (std.mem.startsWith(u8, l, "  ")) spaces += 1;
    }
    return tabs > spaces;
}

fn stripCr(gpa: std.mem.Allocator, data: []const u8, crlf: bool) ![]const u8 {
    if (!crlf) return data;
    const out = try gpa.alloc(u8, data.len);
    var n: usize = 0;
    for (data, 0..) |ch, i| {
        if (ch == '\r' and i + 1 < data.len and data[i + 1] == '\n') continue;
        out[n] = ch;
        n += 1;
    }
    return try gpa.realloc(out, n);
}

fn withCrlf(gpa: std.mem.Allocator, t: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (t) |ch| {
        if (ch == '\n') try out.append(gpa, '\r');
        try out.append(gpa, ch);
    }
    return out.toOwnedSlice(gpa);
}

test withCrlf {
    const gpa = std.testing.allocator;
    const o = try withCrlf(gpa, "a\nb\n");
    defer gpa.free(o);
    try std.testing.expectEqualStrings("a\r\nb\r\n", o);
    const s = try stripCr(gpa, o, true);
    defer gpa.free(s);
    try std.testing.expectEqualStrings("a\nb\n", s);
}
