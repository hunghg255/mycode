//! A commit in a tab: its message, author, date, hash, branches and tags,
//! then each file it changed from its first parent.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const git = @import("git.zig");
const DiffList = @import("difflist.zig").DiffList;

pub const CommitView = struct {
    gpa: std.mem.Allocator,
    /// The full hash; a stash's name (`stash@{0}`) for a stash.
    hash: []u8,
    author: []u8 = &.{},
    date: []u8 = &.{},
    refs: []u8 = &.{},
    message: []u8 = &.{},
    list: DiffList,
    list_height: f32 = 160,

    pub fn create(gpa: std.mem.Allocator, io: std.Io, top: []const u8, rev: []const u8) !*CommitView {
        const cv = try gpa.create(CommitView);
        errdefer gpa.destroy(cv);
        cv.* = .{ .gpa = gpa, .hash = try gpa.dupe(u8, rev), .list = .{ .gpa = gpa, .editable = false } };
        const meta = try git.run(gpa, io, top, &.{ "show", "-s", "--format=%H%x00%an <%ae>%x00%ad%x00%D%x00%B", "--date=format:%Y-%m-%d %H:%M", rev });
        defer meta.deinit(gpa);
        if (!meta.ok) return error.NoSuchCommit;
        var it = std.mem.splitScalar(u8, meta.stdout, 0);
        const full = it.next() orelse "";
        if (rev.len == 0 or std.mem.indexOfScalar(u8, rev, '@') == null) {
            gpa.free(cv.hash);
            cv.hash = try gpa.dupe(u8, std.mem.trim(u8, full, " \n"));
        }
        cv.author = try gpa.dupe(u8, it.next() orelse "");
        cv.date = try gpa.dupe(u8, it.next() orelse "");
        cv.refs = try gpa.dupe(u8, it.next() orelse "");
        cv.message = try gpa.dupe(u8, std.mem.trim(u8, it.rest(), " \n"));
        // The files, from the first parent (or none, for a root commit).
        const files = try git.run(gpa, io, top, &.{ "diff-tree", "--no-commit-id", "-r", "-M", "--root", "--name-status", "-z", rev });
        defer files.deinit(gpa);
        var fit = std.mem.splitScalar(u8, files.stdout, 0);
        var buf: [std.fs.max_path_bytes + 80]u8 = undefined;
        var buf2: [std.fs.max_path_bytes + 80]u8 = undefined;
        while (fit.next()) |st| {
            if (st.len == 0) continue;
            const kind = st[0];
            var old_path = fit.next() orelse break;
            var new_path = old_path;
            if (kind == 'R' or kind == 'C') new_path = fit.next() orelse break else old_path = new_path;
            const old = std.fmt.bufPrint(&buf, "{s}^:{s}", .{ rev, old_path }) catch continue;
            const new = std.fmt.bufPrint(&buf2, "{s}:{s}", .{ rev, new_path }) catch continue;
            try cv.list.add(new_path, if (kind == 'R') old_path else null, kind, "Files", false, if (kind == 'A') "" else old, if (kind == 'D') "" else new);
        }
        return cv;
    }

    pub fn destroy(cv: *CommitView) void {
        cv.list.deinit();
        for ([_][]u8{ cv.hash, cv.author, cv.date, cv.refs, cv.message }) |s| cv.gpa.free(s);
        cv.gpa.destroy(cv);
    }

    pub fn subject(cv: *const CommitView) []const u8 {
        const s = std.mem.sliceTo(cv.message, '\n');
        return s[0..@min(s.len, 40)];
    }

    pub fn header(cv: *CommitView, c: *ui.Context, chrome: ui.Color) void {
        const t = c.theme;
        ui.column(c, .{ .width = .fill, .padding = .xy(16, 12), .gap = 6, .background = chrome });
        defer ui.end(c);
        ui.text(c, cv.message, .{ .size = 13, .wrap = true });
        ui.row(c, .{ .gap = 14, .align_items = .center });
        ui.text(c, cv.author, .{ .size = 12, .color = t.muted });
        ui.text(c, cv.date, .{ .size = 12, .color = t.muted });
        ui.text(c, cv.hash, .{ .size = 11, .mono = true, .color = t.muted });
        if (cv.refs.len > 0) ui.text(c, cv.refs, .{ .size = 11, .color = t.accent });
        ui.end(c);
    }
};
