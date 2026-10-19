//! MyCode's memory: the projects open, recent folders, and each folder's
//! session (its columns and tabs, carets, layout and the folders open in the
//! Explorer), written as JSON beside settings.json.
const std = @import("std");
const fs = @import("fs.zig");

pub const TabState = struct {
    /// A file's path; a commit's hash for "commit"; "" for "changes" and terminals.
    path: []const u8 = "",
    kind: []const u8 = "file",
    caret: usize = 0,
    preview: bool = false,
    wrap: ?bool = null,
    /// Markdown and SVG shown as a preview rather than text.
    rendered: bool = false,
};

pub const ColumnState = struct {
    tabs: []const TabState = &.{},
    active: usize = 0,
    width: f32 = 0,
    locked: bool = false,
};

pub const Session = struct {
    path: []const u8,
    columns: []const ColumnState = &.{},
    focus: usize = 0,
    side: []const u8 = "explorer",
    sidebar_open: bool = true,
    sidebar_width: f32 = 260,
    panel_open: bool = false,
    panel_height: f32 = 260,
    open_folders: []const []const u8 = &.{},
};

pub const File = struct {
    recent: []const []const u8 = &.{},
    projects: []const []const u8 = &.{},
    active: usize = 0,
    sessions: []const Session = &.{},
};

pub const State = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    arena: std.heap.ArenaAllocator,
    f: File = .{},

    pub fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8) State {
        var st: State = .{ .gpa = gpa, .io = io, .path = path, .arena = .init(gpa) };
        const data = fs.read(gpa, io, path) catch return st;
        defer gpa.free(data);
        st.f = std.json.parseFromSliceLeaky(File, st.arena.allocator(), data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch .{};
        return st;
    }

    pub fn deinit(st: *State) void {
        st.arena.deinit();
    }

    pub fn session(st: *const State, path: []const u8) ?Session {
        for (st.f.sessions) |s| if (std.mem.eql(u8, s.path, path)) return s;
        return null;
    }

    fn dupeAll(a: std.mem.Allocator, list: []const []const u8) []const []const u8 {
        const out = a.alloc([]const u8, list.len) catch return &.{};
        for (list, out) |s, *o| o.* = a.dupe(u8, s) catch "";
        return out;
    }

    /// Copies a session deep into the state's arena.
    fn dupeSession(a: std.mem.Allocator, s: Session) Session {
        var d = s;
        d.path = a.dupe(u8, s.path) catch "";
        d.side = a.dupe(u8, s.side) catch "explorer";
        d.open_folders = dupeAll(a, s.open_folders);
        const cols = a.alloc(ColumnState, s.columns.len) catch return d;
        for (s.columns, cols) |c, *oc| {
            oc.* = c;
            const tabs = a.alloc(TabState, c.tabs.len) catch {
                oc.tabs = &.{};
                continue;
            };
            for (c.tabs, tabs) |t, *ot| {
                ot.* = t;
                ot.path = a.dupe(u8, t.path) catch "";
                ot.kind = a.dupe(u8, t.kind) catch "file";
            }
            oc.tabs = tabs;
        }
        d.columns = cols;
        return d;
    }

    /// Keeps a folder's session, the newest first, at most 30.
    pub fn putSession(st: *State, s: Session) void {
        const a = st.arena.allocator();
        var list: std.ArrayList(Session) = .empty;
        list.append(a, dupeSession(a, s)) catch return;
        for (st.f.sessions) |o| {
            if (std.mem.eql(u8, o.path, s.path)) continue;
            if (list.items.len >= 30) break;
            list.append(a, o) catch break;
        }
        st.f.sessions = list.items;
    }

    /// Puts a folder first among the recent ones, at most 20.
    pub fn noteRecent(st: *State, path: []const u8) void {
        const a = st.arena.allocator();
        var list: std.ArrayList([]const u8) = .empty;
        list.append(a, a.dupe(u8, path) catch return) catch return;
        for (st.f.recent) |r| {
            if (std.mem.eql(u8, r, path)) continue;
            if (list.items.len >= 20) break;
            list.append(a, r) catch break;
        }
        st.f.recent = list.items;
    }

    pub fn clearRecent(st: *State) void {
        st.f.recent = &.{};
    }

    pub fn setProjects(st: *State, paths: []const []const u8, active: usize) void {
        st.f.projects = dupeAll(st.arena.allocator(), paths);
        st.f.active = active;
    }

    pub fn save(st: *State) void {
        const out = std.fmt.allocPrint(st.gpa, "{f}\n", .{std.json.fmt(st.f, .{ .whitespace = .indent_2 })}) catch return;
        defer st.gpa.free(out);
        fs.write(st.io, st.path, out) catch {};
    }
};

test "a state goes through JSON" {
    const gpa = std.testing.allocator;
    var st: State = .{ .gpa = gpa, .io = std.testing.io, .path = "", .arena = .init(gpa) };
    defer st.deinit();
    st.noteRecent("/a");
    st.noteRecent("/b");
    st.noteRecent("/a");
    try std.testing.expectEqualStrings("/a", st.f.recent[0]);
    try std.testing.expectEqual(@as(usize, 2), st.f.recent.len);
    st.putSession(.{ .path = "/a", .columns = &.{.{ .tabs = &.{.{ .path = "/a/x.go", .caret = 3 }} }} });
    const out = try std.fmt.allocPrint(gpa, "{f}", .{std.json.fmt(st.f, .{})});
    defer gpa.free(out);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const back = try std.json.parseFromSliceLeaky(File, arena.allocator(), out, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(usize, 3), back.sessions[0].columns[0].tabs[0].caret);
}

