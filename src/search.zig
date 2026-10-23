//! Search: every file of the folder (as quick open lists them) searched off
//! the main thread, its results coming in a file at a time, with match case,
//! whole word and regular expressions, files to include and to exclude, and
//! replace. Files with unsaved edits are searched as the editor has them.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const fs = @import("fs.zig");
const git = @import("git.zig");
const glob = @import("glob.zig");
const jobs = @import("jobs.zig");
const findwidget = @import("findwidget.zig");
const icons = @import("icons.zig");

pub const max_matches = 20_000;
const max_file = 4 << 20;

pub const Match = struct {
    line: usize,
    /// The match's byte in the whole line.
    col: usize = 0,
    /// Bytes of `text`, the part of the line shown.
    start: usize,
    end: usize,
    text: []const u8,
};

pub const FileResult = struct {
    path: []const u8,
    matches: []Match,
    open: bool = true,
};

pub const Options = struct {
    query: []const u8,
    case: bool,
    word: bool,
    regex: bool,
};

/// Finds the matches of `o` in one line.
pub fn matchLine(a: std.mem.Allocator, o: Options, re: ?*const ui.Regex, line: []const u8, out: *std.ArrayList([2]usize)) void {
    if (o.query.len == 0) return;
    if (re) |r| {
        var from: usize = 0;
        while (from <= line.len) {
            const g = r.find(line, from) orelse break;
            const m = g[0] orelse break;
            if (m[1] == m[0]) {
                from = m[1] + 1;
                continue;
            }
            out.append(a, m) catch return;
            from = m[1];
        }
        return;
    }
    var i: usize = 0;
    while (i + o.query.len <= line.len) {
        const at = if (o.case) std.mem.indexOfPos(u8, line, i, o.query) else indexOfIgnoreCasePos(line, i, o.query);
        const s = at orelse break;
        const e = s + o.query.len;
        const ok = !o.word or ((s == 0 or !isWord(line[s - 1])) and (e >= line.len or !isWord(line[e])));
        if (ok) out.append(a, .{ s, e }) catch return;
        i = if (ok) e else s + 1;
    }
}

fn indexOfIgnoreCasePos(hay: []const u8, from: usize, needle: []const u8) ?usize {
    if (needle.len > hay.len) return null;
    var i = from;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn isWord(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_';
}

/// The replacement of one match: `$1` to `$9` are a regular expression's groups.
pub fn expand(a: std.mem.Allocator, replacement: []const u8, groups: ?[10]?[2]usize, line: []const u8) []const u8 {
    const gs = groups orelse return replacement;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < replacement.len) : (i += 1) {
        if (replacement[i] == '$' and i + 1 < replacement.len and std.ascii.isDigit(replacement[i + 1])) {
            const k = replacement[i + 1] - '0';
            if (gs[k]) |g| out.appendSlice(a, line[g[0]..g[1]]) catch {};
            i += 1;
        } else out.append(a, replacement[i]) catch {};
    }
    return out.items;
}

/// `text` with every match replaced; also the count.
pub fn replaceAll(a: std.mem.Allocator, o: Options, text: []const u8, replacement: []const u8) !struct { text: []u8, count: usize } {
    var re: ?ui.Regex = if (o.regex) try ui.Regex.compile(a, o.query, !o.case) else null;
    defer if (re) |*r| r.deinit();
    var out: std.ArrayList(u8) = .empty;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    var ms: std.ArrayList([2]usize) = .empty;
    while (it.next()) |line| {
        if (!first) try out.append(a, '\n');
        first = false;
        ms.clearRetainingCapacity();
        matchLine(a, o, if (re) |*r| r else null, line, &ms);
        var last: usize = 0;
        for (ms.items) |m| {
            try out.appendSlice(a, line[last..m[0]]);
            const groups = if (re) |*r| r.find(line, m[0]) else null;
            try out.appendSlice(a, expand(a, replacement, groups, line));
            last = m[1];
            count += 1;
        }
        try out.appendSlice(a, line[last..]);
    }
    return .{ .text = out.items, .count = count };
}

/// What a search's thread shares with it: it outlives the search (a
/// project closed while its thread runs), freed by the last to let go.
const Shared = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    gen: std.atomic.Value(u64) = .init(0),
    refs: std.atomic.Value(u32) = .init(1),
    /// Null once the search is gone (main thread only).
    search: ?*Search,

    fn retain(sh: *Shared) void {
        _ = sh.refs.fetchAdd(1, .acq_rel);
    }

    fn release(sh: *Shared) void {
        if (sh.refs.fetchSub(1, .acq_rel) == 1) sh.gpa.destroy(sh);
    }
};

const Batch = struct {
    shared: *Shared,
    gen: u64,
    arena: std.heap.ArenaAllocator,
    results: std.ArrayList(FileResult) = .empty,
    done: bool = false,

    fn deliver(ctx: ?*anyopaque) callconv(.c) void {
        const b: *Batch = @ptrCast(@alignCast(ctx.?));
        const sh = b.shared;
        defer {
            b.arena.deinit();
            sh.gpa.destroy(b);
            sh.release();
        }
        const s = sh.search orelse return;
        if (b.gen == sh.gen.load(.acquire)) {
            const a = s.arena.allocator();
            for (b.results.items) |r| {
                const ms = a.alloc(Match, r.matches.len) catch continue;
                for (r.matches, ms) |m, *o| o.* = .{ .line = m.line, .col = m.col, .start = m.start, .end = m.end, .text = a.dupe(u8, m.text) catch "" };
                s.results.append(s.gpa, .{ .path = a.dupe(u8, r.path) catch "", .matches = ms }) catch {};
                s.total += ms.len;
            }
            if (b.done) s.running = false;
            if (s.window) |w| w.redraw();
        }
    }
};

const Work = struct {
    shared: *Shared,
    gen: u64,
    root: []u8,
    o: Options,
    files: [][]const u8,
    include: []u8,
    exclude: []u8,
    excludes: [][]u8,
    /// Texts of files with unsaved edits, by relative path.
    overrides: std.StringHashMapUnmanaged([]u8) = .empty,

    fn run(w: *Work) void {
        const s = w.shared;
        const gpa = s.gpa;
        defer w.free();
        var re: ?ui.Regex = if (w.o.regex) ui.Regex.compile(gpa, w.o.query, !w.o.case) catch null else null;
        defer if (re) |*r| r.deinit();
        if (w.o.regex and re == null) {
            w.post(true, null);
            return;
        }
        var batch = w.newBatch();
        var total: usize = 0;
        var ms: std.ArrayList([2]usize) = .empty;
        defer ms.deinit(gpa);
        for (w.files) |rel| {
            if (s.gen.load(.acquire) != w.gen) return;
            if (w.include.len > 0 and !glob.matchesAny(w.include, rel)) continue;
            if (w.exclude.len > 0 and glob.matchesAny(w.exclude, rel)) continue;
            var skip = false;
            for (w.excludes) |p| if (glob.matches(p, rel)) {
                skip = true;
            };
            if (skip) continue;
            const ba = batch.arena.allocator();
            const data = if (w.overrides.get(rel)) |t| t else blk: {
                const abs = std.fs.path.join(ba, &.{ w.root, rel }) catch continue;
                const d = std.Io.Dir.cwd().readFileAlloc(s.io, abs, ba, .limited(max_file)) catch continue;
                break :blk d;
            };
            if (fs.binary(data)) continue;
            var found: std.ArrayList(Match) = .empty;
            var it = std.mem.splitScalar(u8, data, '\n');
            var ln: usize = 0;
            while (it.next()) |line0| : (ln += 1) {
                const line = std.mem.trimEnd(u8, line0, "\r");
                ms.clearRetainingCapacity();
                matchLine(gpa, w.o, if (re) |*r| r else null, line, &ms);
                for (ms.items) |m| {
                    // A long line shows around its match, cut between characters.
                    var from = if (m[0] > 60) m[0] - 60 else 0;
                    while (from > 0 and line[from] & 0xc0 == 0x80) from -= 1;
                    var to = @min(line.len, m[1] + 120);
                    while (to < line.len and line[to] & 0xc0 == 0x80) to += 1;
                    found.append(ba, .{ .line = ln, .col = m[0], .start = m[0] - from, .end = m[1] - from, .text = ba.dupe(u8, line[from..to]) catch "" }) catch break;
                    total += 1;
                }
                if (total >= max_matches) break;
            }
            if (found.items.len > 0) batch.results.append(ba, .{ .path = ba.dupe(u8, rel) catch continue, .matches = found.items }) catch {};
            if (total >= max_matches) break;
            if (batch.results.items.len >= 20) {
                w.post(false, batch);
                batch = w.newBatch();
            }
        }
        w.post(true, batch);
    }

    fn newBatch(w: *Work) *Batch {
        const b = w.shared.gpa.create(Batch) catch @panic("out of memory");
        w.shared.retain();
        b.* = .{ .shared = w.shared, .gen = w.gen, .arena = .init(w.shared.gpa) };
        return b;
    }

    fn post(w: *Work, done: bool, batch: ?*Batch) void {
        const b = batch orelse w.newBatch();
        b.done = done;
        if (!jobs.post(b, Batch.deliver)) {
            b.arena.deinit();
            w.shared.gpa.destroy(b);
            w.shared.release();
        }
    }

    fn free(w: *Work) void {
        const gpa = w.shared.gpa;
        const shared = w.shared;
        defer shared.release();
        fs.freeStrings(gpa, w.files);
        gpa.free(w.root);
        gpa.free(w.include);
        gpa.free(w.exclude);
        for (w.excludes) |e| gpa.free(e);
        gpa.free(w.excludes);
        gpa.free(w.o.query);
        var it = w.overrides.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            gpa.free(e.value_ptr.*);
        }
        w.overrides.deinit(gpa);
        gpa.destroy(w);
    }
};

pub const Event = union(enum) {
    none,
    /// A match chosen: open the file (relative) with it selected.
    open: struct { path: []const u8, line: usize, col: usize, len: usize, keep: bool },
    replace_all,
    replace_file: usize,
    replace_match: struct { file: usize, match: usize },
    /// A match pressed: its file may be dragged into a column (relative path).
    press: []const u8,
};

pub const Search = struct {
    /// The fields' ids (query, replacement, include, exclude), from the
    /// last build: their frames show which has the keyboard.
    ids: [4]u64 = .{ 0, 0, 0, 0 },
    gpa: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    window: ?*myzig.Window = null,
    query: ui.TextBuffer = .{},
    replacement: ui.TextBuffer = .{},
    include: ui.TextBuffer = .{},
    exclude: ui.TextBuffer = .{},
    case: bool = false,
    word: bool = false,
    regex: bool = false,
    show_replace: bool = false,
    show_filters: bool = false,
    results: std.ArrayList(FileResult) = .empty,
    arena: std.heap.ArenaAllocator,
    total: usize = 0,
    shared: *Shared,
    running: bool = false,
    /// What was searched last, to search again when it changes.
    last_key: u64 = 0,
    focus_query: bool = false,
    selected: ?[2]usize = null,
    /// The keys of the query go through the matches (Down came there).
    in_results: bool = false,
    confirm: ui.OverlayState = .{},
    message: ?[]const u8 = null,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, root: []const u8) Search {
        const sh = gpa.create(Shared) catch @panic("out of memory");
        sh.* = .{ .gpa = gpa, .io = io, .search = null };
        return .{ .gpa = gpa, .io = io, .root = root, .arena = .init(gpa), .shared = sh };
    }

    pub fn deinit(s: *Search) void {
        _ = s.shared.gen.fetchAdd(1, .release);
        s.shared.search = null;
        s.shared.release();
        s.results.deinit(s.gpa);
        s.arena.deinit();
    }

    pub fn options(s: *const Search) Options {
        return .{ .query = s.query.text(), .case = s.case, .word = s.word, .regex = s.regex };
    }

    fn key(s: *const Search) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(s.query.text());
        h.update(s.include.text());
        h.update(s.exclude.text());
        h.update(&.{ @intFromBool(s.case), @intFromBool(s.word), @intFromBool(s.regex) });
        return h.final();
    }

    /// Searches again: `overrides` are the texts of files with unsaved edits.
    pub fn start(s: *Search, excludes: []const []const u8, overrides: []const [2][]const u8) void {
        s.shared.search = s;
        const g = s.shared.gen.fetchAdd(1, .acq_rel) + 1;
        s.results.clearRetainingCapacity();
        _ = s.arena.reset(.retain_capacity);
        s.total = 0;
        s.selected = null;
        s.last_key = s.key();
        const q = s.query.text();
        if (q.len == 0) {
            s.running = false;
            return;
        }
        const gpa = s.gpa;
        const files = git.listFiles(gpa, s.io, s.root) catch fs.walk(gpa, s.io, s.root, 100_000) catch return;
        const w = gpa.create(Work) catch return;
        w.* = .{
            .shared = s.shared,
            .gen = g,
            .root = gpa.dupe(u8, s.root) catch return,
            .o = .{ .query = gpa.dupe(u8, q) catch return, .case = s.case, .word = s.word, .regex = s.regex },
            .files = files,
            .include = gpa.dupe(u8, s.include.text()) catch return,
            .exclude = gpa.dupe(u8, s.exclude.text()) catch return,
            .excludes = gpa.alloc([]u8, excludes.len) catch return,
        };
        for (excludes, 0..) |e, i| w.excludes[i] = gpa.dupe(u8, e) catch &.{};
        for (overrides) |o| {
            const k = gpa.dupe(u8, o[0]) catch continue;
            const v = gpa.dupe(u8, o[1]) catch {
                gpa.free(k);
                continue;
            };
            w.overrides.put(gpa, k, v) catch {
                gpa.free(k);
                gpa.free(v);
            };
        }
        s.running = true;
        s.shared.retain();
        const th = std.Thread.spawn(.{ .stack_size = 8 << 20 }, Work.run, .{w}) catch {
            s.running = false;
            w.free();
            return;
        };
        th.detach();
    }

    pub fn changed(s: *const Search) bool {
        return s.key() != s.last_key;
    }

    pub fn focus(s: *Search, selection: []const u8) void {
        if (selection.len > 0 and std.mem.indexOfScalar(u8, selection, '\n') == null) s.query.set(selection);
        s.focus_query = true;
    }

    /// The keys of the matches while the query has the keyboard: Down
    /// shows the next match (opening it as a preview), Up the one before
    /// (on the first, back to the query), Enter keeps it open, Escape
    /// leaves the matches.
    fn matchKeys(s: *Search, c: *ui.Context) ?Event {
        const S = ui.Shortcut;
        if (s.in_results and (c.shortcut(.{ .key = S.escape }))) {
            s.in_results = false;
            s.selected = null;
            return null;
        }
        var step: i32 = 0;
        if (c.shortcut(.{ .key = S.down })) step = 1;
        if (s.in_results and c.shortcut(.{ .key = S.up })) step = -1;
        const keep = s.in_results and c.shortcut(.{ .key = S.enter });
        if (step == 0 and !keep) return null;
        // The matches in order, of the files open.
        var flat: std.ArrayList([2]usize) = .empty;
        for (s.results.items, 0..) |r, fi| if (r.open) for (0..r.matches.len) |k| flat.append(c.alloc(), .{ fi, k }) catch {};
        if (flat.items.len == 0) return null;
        var at: ?usize = null;
        if (s.selected) |sel| for (flat.items, 0..) |f, i| if (f[0] == sel[0] and f[1] == sel[1]) {
            at = i;
        };
        var to: usize = 0;
        if (!s.in_results) {
            s.in_results = true;
        } else if (step < 0) {
            if (at == null or at.? == 0) {
                s.in_results = false;
                s.selected = null;
                return null;
            }
            to = at.? - 1;
        } else if (step > 0) {
            to = if (at) |a| @min(a + 1, flat.items.len - 1) else 0;
        } else to = at orelse 0;
        const f = flat.items[to];
        s.selected = f;
        const r = s.results.items[f[0]];
        const m = r.matches[f[1]];
        c.changed = true;
        return .{ .open = .{ .path = r.path, .line = m.line, .col = m.col, .len = m.end - m.start, .keep = keep } };
    }

    pub fn view(s: *Search, c: *ui.Context) Event {
        const t = c.theme;
        var ev: Event = .none;
        ui.column(c, .{ .width = .fill, .height = .fill });
        defer ui.end(c);
        {
            ui.column(c, .{ .width = .fill, .padding = .{ .top = 0, .right = 12, .bottom = 6, .left = 6 }, .gap = 5 });
            defer ui.end(c);
            ui.row(c, .{ .width = .fill, .gap = 2, .align_items = .stretch });
            const arrow = ui.div(c).w(18).center().rounded(4).hover(t.surface_hover);
            icons.sym(c, if (s.show_replace) "chevron.down" else "chevron.right", .{ .size = 9, .color = t.muted });
            const ai = arrow.interaction();
            arrow.end();
            ui.tooltip(c, ai, "Toggle Replace (Ctrl+Shift+H)");
            if (ai.clicked) s.show_replace = !s.show_replace;
            ui.column(c, .{ .grow = 1, .gap = 5 });
            {
                const frame = field(c, s.ids[0]);
                const qid = c.peekId(null);
                s.ids[0] = qid;
                if (s.focus_query) {
                    c.focus = qid;
                    c.changed = true;
                    s.focus_query = false;
                }
                // Down from the query goes through the matches; Up on the first,
                // or Escape, back to the query.
                if (c.focus == qid) if (s.matchKeys(c)) |e| {
                    ev = e;
                };
                _ = ui.textField(c, &s.query, .{ .width = .fill, .placeholder = "Search", .size = 12.5, .bare = true, .label = "Search" });
                findwidget.toggle(c, "case", "Match Case", &s.case);
                findwidget.toggle(c, "word", "Match Whole Word", &s.word);
                findwidget.toggle(c, "regex", "Use Regular Expression", &s.regex);
                frame.end();
            }
            if (s.show_replace) {
                const frame = field(c, s.ids[1]);
                s.ids[1] = c.peekId(null);
                const r = ui.textField(c, &s.replacement, .{ .width = .fill, .placeholder = "Replace", .size = 12.5, .bare = true, .label = "Replace" });
                const rb = ui.div(c).w(22).h(20).center().rounded(4).hover(t.surface_hover);
                icons.sym(c, "replace_all", .{ .size = 11, .color = t.muted });
                const rbi = rb.interaction();
                rb.end();
                ui.tooltip(c, rbi, "Replace All");
                if ((rbi.clicked or r.submitted) and s.total > 0) s.confirm.show();
                frame.end();
            }
            ui.end(c);
            ui.end(c);
            // What the search found, and the details' button.
            ui.row(c, .{ .width = .fill, .gap = 6, .align_items = .center, .padding = .{ .left = 20 } });
            const files = s.results.items.len;
            const filtered = s.include.text().len > 0 or s.exclude.text().len > 0;
            const status = if (s.message) |m|
                m
            else if (s.query.text().len == 0)
                ""
            else if (s.total > 0)
                (if (s.total >= max_matches)
                    c.print("The first {d} results in {d} file{s}{s}", .{ max_matches, files, if (files == 1) "" else "s", if (s.running) "…" else "" })
                else
                    c.print("{d} result{s} in {d} file{s}{s}", .{ s.total, if (s.total == 1) "" else "s", files, if (files == 1) "" else "s", if (s.running) "…" else "" }))
            else if (s.running)
                "Searching…"
            else if (filtered)
                "No results found in the files to include and exclude"
            else
                "No results found";
            const sb = ui.div(c).grow().w(0).clip();
            ui.text(c, status, .{ .size = 11.5, .color = if (s.message != null) t.danger else t.muted });
            sb.end();
            const db = ui.div(c).w(22).h(18).center().rounded(4).bg(if (s.show_filters) t.accent.alpha(0.18) else .transparent).hover(t.surface_hover);
            icons.sym(c, "ellipsis", .{ .size = 10, .color = t.muted });
            const dbi = db.interaction();
            db.end();
            ui.tooltip(c, dbi, "Toggle Search Details");
            if (dbi.clicked) s.show_filters = !s.show_filters;
            ui.end(c);
            if (s.show_filters) {
                ui.column(c, .{ .width = .fill, .gap = 4, .padding = .{ .left = 20 } });
                ui.text(c, "files to include", .{ .size = 11, .color = t.muted });
                const f1 = field(c, s.ids[2]);
                s.ids[2] = c.peekId(null);
                _ = ui.textField(c, &s.include, .{ .width = .fill, .placeholder = "e.g. *.go, src/**", .size = 12.5, .bare = true, .label = "files to include" });
                f1.end();
                ui.text(c, "files to exclude", .{ .size = 11, .color = t.muted });
                const f2 = field(c, s.ids[3]);
                s.ids[3] = c.peekId(null);
                _ = ui.textField(c, &s.exclude, .{ .width = .fill, .placeholder = "e.g. *.test.ts, testdata", .size = 12.5, .bare = true, .label = "files to exclude" });
                f2.end();
                ui.end(c);
            }
        }
        // Before a query: what the view does, and its keys.
        if (s.query.text().len == 0) {
            ui.column(c, .{ .width = .fill, .padding = .{ .top = 10, .right = 14, .bottom = 0, .left = 26 }, .gap = 6 });
            ui.text(c, "Find text in the folder's files.", .{ .size = 12, .color = t.muted });
            const keys = [_][2][]const u8{ .{ "↓", "Go to the results" }, .{ "⏎", "Open the match" }, .{ "Ctrl+Shift+H", "Replace" } };
            for (keys) |k| {
                const row = ui.div(c).row().gap(8).itemsCenter();
                const cap = ui.div(c).h(18).minW(22).px(5).center().rounded(4).bg(t.surface_hover);
                ui.text(c, k[0], .{ .size = 11, .color = t.muted });
                cap.end();
                ui.text(c, k[1], .{ .size = 11.5, .color = t.muted.alpha(0.7) });
                row.end();
            }
            ui.end(c);
        }
        if (s.running) _ = c.leaf(.{ .width = .fill, .height = .{ .px = 2 }, .background = t.accent.alpha(0.6) }, .none, null);
        // A regular expression's groups, for the replacements shown.
        var re: ?ui.Regex = if (s.show_replace and s.regex) ui.Regex.compile(c.gpa, s.query.text(), !s.case) catch null else null;
        defer if (re) |*r| r.deinit();
        // The results: a header for each file, a row for each match.
        var nrows: usize = 0;
        for (s.results.items) |r| nrows += 1 + (if (r.open) r.matches.len else 0);
        var rows = ui.list(c, .{ .count = nrows, .row_height = 22 });
        while (rows.next()) |ri| {
            var k = ri;
            for (s.results.items, 0..) |*r, fi| {
                if (k == 0) {
                    const head = ui.div(c).row().wFull().h(22).px(8).gap(6).itemsCenter().hover(t.surface_hover);
                    icons.sym(c, if (r.open) "chevron.down" else "chevron.right", .{ .size = 8, .color = t.muted });
                    icons.file(c, std.fs.path.basename(r.path));
                    ui.text(c, std.fs.path.basename(r.path), .{ .size = 12 });
                    if (std.fs.path.dirname(r.path)) |d| ui.text(c, d, .{ .size = 11, .color = t.muted });
                    ui.spacer(c);
                    if (s.show_replace and head.hovered()) {
                        const b = ui.div(c).w(18).h(18).center().rounded(3).hover(t.surface);
                        icons.sym(c, "arrow.clockwise", .{ .size = 9, .color = t.muted });
                        if (b.clicked()) ev = .{ .replace_file = fi };
                        b.end();
                    }
                    ui.text(c, c.print("{d}", .{r.matches.len}), .{ .size = 10, .color = t.muted });
                    if (head.clicked() and ev == .none) r.open = !r.open;
                    head.end();
                    break;
                }
                k -= 1;
                if (!r.open) continue;
                if (k < r.matches.len) {
                    const m = r.matches[k];
                    const on = if (s.selected) |sel| sel[0] == fi and sel[1] == k else false;
                    const row = ui.div(c).row().wFull().h(22).pl(30).pr(8).gap(0).itemsCenter().bg(if (on) t.accent.alpha(0.2) else .transparent).hover(t.surface_hover);
                    // The line's text clips, so the line number keeps its place.
                    const texts = ui.div(c).row().w(0).grow().clip().itemsCenter();
                    const pre = std.mem.trimStart(u8, m.text[0..m.start], " \t");
                    ui.text(c, pre, .{ .size = 12, .color = t.muted });
                    const hit = m.text[m.start..m.end];
                    if (s.show_replace and s.replacement.text().len >= 0) {
                        const hb = ui.div(c).bg(t.danger.alpha(0.2));
                        ui.text(c, hit, .{ .size = 12 });
                        hb.end();
                        const with = if (re) |*rx| expand(c.alloc(), s.replacement.text(), rx.find(m.text, m.start), m.text) else s.replacement.text();
                        if (with.len > 0) {
                            const rb = ui.div(c).bg(t.success.alpha(0.25));
                            ui.text(c, with, .{ .size = 12 });
                            rb.end();
                        }
                    } else {
                        const hb = ui.div(c).bg(ui.Color.hex(0xe8b86d).alpha(0.35)).rounded(2);
                        ui.text(c, hit, .{ .size = 12 });
                        hb.end();
                    }
                    ui.text(c, m.text[m.end..], .{ .size = 12, .color = t.muted });
                    texts.end();
                    if (s.show_replace and row.hovered()) {
                        const b = ui.div(c).w(18).h(18).center().rounded(3).hover(t.surface);
                        icons.sym(c, "arrow.clockwise", .{ .size = 9, .color = t.muted });
                        if (b.clicked()) ev = .{ .replace_match = .{ .file = fi, .match = k } };
                        b.end();
                    } else {
                        // Its line, to tell apart the matches of lines alike.
                        ui.text(c, c.print("{d}", .{m.line + 1}), .{ .size = 10.5, .color = t.muted.alpha(0.7) });
                    }
                    const ia = row.interaction();
                    row.end();
                    if (ev == .none and ia.pressed and c.input.pressed) ev = .{ .press = r.path };
                    if (ev == .none and (ia.clicked or ia.double_clicked)) {
                        s.selected = .{ fi, k };
                        ev = .{ .open = .{ .path = r.path, .line = m.line, .col = m.col, .len = m.end - m.start, .keep = ia.double_clicked } };
                    }
                    break;
                }
                k -= r.matches.len;
            }
        }
        rows.end();
        switch (ui.alertDialog(c, &s.confirm, "Replace all?", c.print("Replace {d} matches in {d} files? Files not open are written at once, which can't be undone.", .{ s.total, s.results.items.len }), &.{ "Cancel", "Replace" })) {
            .chosen => |i| if (i == 1) {
                ev = .replace_all;
            },
            else => {},
        }
        return ev;
    }
};

/// A field of the view in its frame, its border in the accent while the
/// field `id` has the keyboard.
fn field(c: *ui.Context, id: u64) ui.Div {
    const t = c.theme;
    const focused = c.focus == id and id != 0;
    return ui.div(c).row().wFull().h(26).pl(8).pr(4).gap(2).itemsCenter().rounded(5).bg(t.background).border(if (focused) t.accent.alpha(0.7) else t.border);
}

/// Folds every file's matches, or opens them all again.
pub fn collapseAll(s: *Search) void {
    var all = s.results.items.len > 0;
    for (s.results.items) |r| all = all and !r.open;
    for (s.results.items) |*r| r.open = all;
}

test matchLine {
    const a = std.testing.allocator;
    var out: std.ArrayList([2]usize) = .empty;
    defer out.deinit(a);
    matchLine(a, .{ .query = "foo", .case = false, .word = true, .regex = false }, null, "Foo food foo", &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const r = try replaceAll(arena.allocator(), .{ .query = "(\\w+)@x", .case = true, .word = false, .regex = true }, "ab@x cd@x\nzz", "<$1>");
    try std.testing.expectEqualStrings("<ab> <cd>\nzz", r.text);
    try std.testing.expectEqual(@as(usize, 2), r.count);
}
