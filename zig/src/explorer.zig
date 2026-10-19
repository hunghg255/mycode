//! The Explorer: a lazy file tree of the workspace's folder, read as folders
//! open, with Git's state of each file.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const fs = @import("fs.zig");
const git = @import("git.zig");
const icons = @import("icons.zig");

pub const Open = struct {
    path: []const u8,
    /// A single click: the preview tab; Enter or a double click keeps it.
    preview: bool,
};

pub const Explorer = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    state: ui.OutlineState([]const u8) = .{},
    /// Every path the tree has shown, kept until deinit so the outline's
    /// state can name them across refreshes.
    pool: std.StringHashMapUnmanaged(void) = .empty,
    /// A folder's children, read when it first opens.
    kids: std.StringHashMapUnmanaged([]const []const u8) = .empty,
    dirs: std.StringHashMapUnmanaged(void) = .empty,
    /// Git's state of each changed file, and the folders holding changes.
    marks: std.StringHashMapUnmanaged(git.Status) = .empty,
    marked_dirs: std.StringHashMapUnmanaged(void) = .empty,
    menu: ui.Menu = .{},
    menu_path: ?[]const u8 = null,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, root: []const u8) Explorer {
        var e: Explorer = .{ .gpa = gpa, .io = io, .root = root };
        e.dirs.put(gpa, e.intern(root), {}) catch {};
        return e;
    }

    pub fn deinit(e: *Explorer) void {
        e.dropKids();
        e.kids.deinit(e.gpa);
        e.dirs.deinit(e.gpa);
        e.clearMarks();
        e.marks.deinit(e.gpa);
        e.marked_dirs.deinit(e.gpa);
        e.state.deinit(e.gpa);
        var it = e.pool.keyIterator();
        while (it.next()) |k| e.gpa.free(k.*);
        e.pool.deinit(e.gpa);
    }

    fn intern(e: *Explorer, s: []const u8) []const u8 {
        if (e.pool.getKey(s)) |k| return k;
        const d = e.gpa.dupe(u8, s) catch return s;
        e.pool.put(e.gpa, d, {}) catch {
            e.gpa.free(d);
            return s;
        };
        return d;
    }

    fn dropKids(e: *Explorer) void {
        var it = e.kids.valueIterator();
        while (it.next()) |v| e.gpa.free(v.*);
        e.kids.clearRetainingCapacity();
    }

    /// Reads every open folder again on its next showing.
    pub fn refresh(e: *Explorer) void {
        e.dropKids();
    }

    pub fn isDir(e: *const Explorer, path: []const u8) bool {
        return e.dirs.contains(path);
    }

    /// The outline's provider: a folder's entries, read once.
    pub fn children(e: *Explorer, item: []const u8) []const []const u8 {
        if (!e.dirs.contains(item)) return &.{};
        if (e.kids.get(item)) |k| return k;
        const entries = fs.list(e.gpa, e.io, item) catch &.{};
        defer if (entries.len > 0) fs.freeList(e.gpa, entries);
        const out = e.gpa.alloc([]const u8, entries.len) catch return &.{};
        for (entries, out) |en, *o| {
            o.* = e.intern(en.path);
            if (en.dir) e.dirs.put(e.gpa, o.*, {}) catch {};
        }
        e.kids.put(e.gpa, item, out) catch {
            e.gpa.free(out);
            return &.{};
        };
        return out;
    }

    fn clearMarks(e: *Explorer) void {
        var it = e.marks.keyIterator();
        while (it.next()) |k| e.gpa.free(k.*);
        e.marks.clearRetainingCapacity();
        var dit = e.marked_dirs.keyIterator();
        while (dit.next()) |k| e.gpa.free(k.*);
        e.marked_dirs.clearRetainingCapacity();
    }

    /// Takes Git's changes, their paths relative to the work tree's `top`.
    pub fn setChanges(e: *Explorer, top: []const u8, changes: []const git.Change) void {
        e.clearMarks();
        for (changes) |ch| {
            const st = ch.status();
            if (st == .ignored) continue;
            const abs = joinNative(e.gpa, top, ch.path) catch continue;
            const gop = e.marks.getOrPut(e.gpa, abs) catch {
                e.gpa.free(abs);
                continue;
            };
            if (gop.found_existing) e.gpa.free(abs);
            gop.value_ptr.* = st;
            // Every folder above it, up to the workspace's.
            var d = std.fs.path.dirname(gop.key_ptr.*);
            while (d) |dir| : (d = std.fs.path.dirname(dir)) {
                if (dir.len < e.root.len) break;
                if (e.marked_dirs.contains(dir)) break;
                const k = e.gpa.dupe(u8, dir) catch break;
                e.marked_dirs.put(e.gpa, k, {}) catch e.gpa.free(k);
            }
        }
    }

    /// Opens the folders down to `path` and chooses it.
    pub fn reveal(e: *Explorer, path: []const u8) void {
        var d = std.fs.path.dirname(path);
        while (d) |dir| : (d = std.fs.path.dirname(dir)) {
            if (dir.len < e.root.len) break;
            const k = e.intern(dir);
            e.dirs.put(e.gpa, k, {}) catch {};
            e.state.setOpen(e.gpa, k, true);
        }
        e.state.selected = e.intern(path);
    }

    pub fn collapseAll(e: *Explorer) void {
        e.state.open.clearRetainingCapacity();
    }

    pub fn view(e: *Explorer, c: *ui.Context) ?Open {
        const t = c.theme;
        var opened: ?Open = null;
        const roots = e.children(e.root);
        var rows = ui.outline([]const u8, c, &e.state, roots, e, .{ .row_height = 22, .indent = 12, .padding = .xy(0, 2) });
        while (rows.next()) |r| {
            const dir = e.dirs.contains(r.item);
            const name = std.fs.path.basename(r.item);
            const mark = e.marks.get(r.item);
            const color = if (mark) |m| statusColor(t, m) else t.text;
            if (dir) {
                ui.icon(c, "folder", .{ .size = 12, .color = t.muted });
            } else {
                icons.file(c, name);
            }
            ui.text(c, name, .{ .size = 13, .color = color, .wrap = false });
            ui.spacer(c);
            if (mark) |m| {
                ui.text(c, c.print("{c}", .{@intFromEnum(m)}), .{ .size = 11, .color = color, .mono = true });
                _ = c.leaf(.{ .width = .{ .px = 8 } }, .none, null);
            } else if (dir and e.marked_dirs.contains(r.item)) {
                _ = c.leaf(.{ .width = .{ .px = 6 }, .height = .{ .px = 6 }, .radius = 3, .background = t.muted }, .none, null);
                _ = c.leaf(.{ .width = .{ .px = 8 } }, .none, null);
            }
        }
        const res = rows.end();
        if (e.state.selected) |sel| {
            if (res.submitted) {
                if (e.dirs.contains(sel)) {
                    e.state.setOpen(e.gpa, sel, !e.state.isOpen(sel));
                } else opened = .{ .path = sel, .preview = false };
            } else if (res.changed and !e.dirs.contains(sel)) {
                opened = .{ .path = sel, .preview = true };
            }
        }
        return opened;
    }
};

pub fn statusColor(t: ui.Theme, s: git.Status) ui.Color {
    return switch (s) {
        .modified, .renamed => .hex(0xe2c08d),
        .added, .untracked => .hex(0x73c991),
        .deleted => t.danger,
        .conflict => .hex(0xe4676b),
        .ignored => t.muted,
    };
}

pub fn joinNative(gpa: std.mem.Allocator, top: []const u8, rel: []const u8) ![]u8 {
    const p = try std.fs.path.join(gpa, &.{ top, rel });
    if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, p, '/', std.fs.path.sep);
    return p;
}
