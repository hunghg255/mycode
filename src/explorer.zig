//! The Explorer: a lazy file tree of the workspace's folder, read as folders
//! open, with Git's state of each file, ignored files faint, and a menu to
//! create, rename, trash and reveal files.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const fs = @import("fs.zig");
const git = @import("git.zig");
const glob = @import("glob.zig");
const icons = @import("icons.zig");

pub const Event = union(enum) {
    none,
    /// A single click: the preview tab; Enter or a double click keeps it.
    open: struct { path: []const u8, preview: bool },
    new_file: []const u8,
    new_folder: []const u8,
    rename: []const u8,
    trash: []const u8,
    open_changes: []const u8,
    open_terminal: []const u8,
    /// Files copied (in File Explorer, or here) pasted into a folder.
    paste: []const u8,
    /// A file pressed: it may be dragged into a column or a terminal.
    press: []const u8,
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
    /// Files and folders Git ignores (relative, with slashes; folders end in /).
    ignored: std.StringHashMapUnmanaged(void) = .empty,
    /// settings.filesExclude.
    excludes: []const []const u8 = &.{},
    menu: ui.Menu = .{},
    /// The menu of the space below the files: the workspace's.
    space_menu: ui.Menu = .{},
    menu_path: []const u8 = "",
    focused: bool = false,
    /// The rows as last laid out, and the tree's box: files of File
    /// Explorer dropped on a row copy into its folder (`dropTarget`).
    drop_rows: std.ArrayList(DropRow) = .empty,
    area_rect: ?ui.Rect = null,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, root: []const u8) Explorer {
        var e: Explorer = .{ .gpa = gpa, .io = io, .root = root };
        e.dirs.put(gpa, e.intern(root), {}) catch {};
        return e;
    }

    pub fn deinit(e: *Explorer) void {
        e.drop_rows.deinit(e.gpa);
        e.dropKids();
        e.kids.deinit(e.gpa);
        e.dirs.deinit(e.gpa);
        e.clearMarks();
        e.marks.deinit(e.gpa);
        e.marked_dirs.deinit(e.gpa);
        e.clearIgnored();
        e.ignored.deinit(e.gpa);
        e.state.deinit(e.gpa);
        var it = e.pool.keyIterator();
        while (it.next()) |k| e.gpa.free(k.*);
        e.pool.deinit(e.gpa);
    }

    pub fn intern(e: *Explorer, s: []const u8) []const u8 {
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

    fn excluded(e: *const Explorer, path: []const u8) bool {
        if (e.excludes.len == 0) return false;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const rel = fs.relative(e.root, path);
        if (rel.len > buf.len) return false;
        @memcpy(buf[0..rel.len], rel);
        std.mem.replaceScalar(u8, buf[0..rel.len], '\\', '/');
        for (e.excludes) |p| if (glob.matches(p, buf[0..rel.len])) return true;
        return false;
    }

    /// The outline's provider: a folder's entries, read once.
    pub fn children(e: *Explorer, item: []const u8) []const []const u8 {
        if (!e.dirs.contains(item)) return &.{};
        if (e.kids.get(item)) |k| return k;
        const entries = fs.list(e.gpa, e.io, item) catch &.{};
        defer if (entries.len > 0) fs.freeList(e.gpa, entries);
        var out: std.ArrayList([]const u8) = .empty;
        for (entries) |en| {
            if (e.excluded(en.path)) continue;
            const p = e.intern(en.path);
            if (en.dir) e.dirs.put(e.gpa, p, {}) catch {};
            out.append(e.gpa, p) catch {};
        }
        const slice = out.toOwnedSlice(e.gpa) catch return &.{};
        e.kids.put(e.gpa, item, slice) catch {
            e.gpa.free(slice);
            return &.{};
        };
        return slice;
    }

    fn clearMarks(e: *Explorer) void {
        var it = e.marks.keyIterator();
        while (it.next()) |k| e.gpa.free(k.*);
        e.marks.clearRetainingCapacity();
        var dit = e.marked_dirs.keyIterator();
        while (dit.next()) |k| e.gpa.free(k.*);
        e.marked_dirs.clearRetainingCapacity();
    }

    fn clearIgnored(e: *Explorer) void {
        var it = e.ignored.keyIterator();
        while (it.next()) |k| e.gpa.free(k.*);
        e.ignored.clearRetainingCapacity();
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
            var d = std.fs.path.dirname(gop.key_ptr.*);
            while (d) |dir| : (d = std.fs.path.dirname(dir)) {
                if (dir.len < e.root.len) break;
                if (e.marked_dirs.contains(dir)) break;
                const k = e.gpa.dupe(u8, dir) catch break;
                e.marked_dirs.put(e.gpa, k, {}) catch e.gpa.free(k);
            }
        }
    }

    /// Reads what Git ignores (`ls-files --ignored --directory`), shown faint.
    pub fn readIgnored(e: *Explorer, top: ?[]const u8) void {
        e.clearIgnored();
        const t = top orelse return;
        const r = git.run(e.gpa, e.io, t, &.{ "ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory" }) catch return;
        defer r.deinit(e.gpa);
        if (!r.ok) return;
        var it = std.mem.tokenizeScalar(u8, r.stdout, 0);
        var n: usize = 0;
        while (it.next()) |p| : (n += 1) {
            if (n > 20_000) break;
            const abs = joinNative(e.gpa, t, std.mem.trimEnd(u8, p, "/")) catch continue;
            e.ignored.put(e.gpa, abs, {}) catch e.gpa.free(abs);
        }
    }

    fn isIgnored(e: *const Explorer, path: []const u8) bool {
        if (e.ignored.count() == 0) return false;
        var p: ?[]const u8 = path;
        while (p) |x| : (p = std.fs.path.dirname(x)) {
            if (x.len < e.root.len) return false;
            if (e.ignored.contains(x)) return true;
        }
        return false;
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

    /// The folder new files go in: the one chosen, the chosen file's, else the root.
    pub fn targetDir(e: *const Explorer) []const u8 {
        const sel = e.state.selected orelse return e.root;
        if (e.dirs.contains(sel)) return sel;
        return std.fs.path.dirname(sel) orelse e.root;
    }

    /// Paths whose open state the session keeps.
    pub fn openFolders(e: *const Explorer, a: std.mem.Allocator) []const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var it = e.state.open.keyIterator();
        while (it.next()) |k| out.append(a, k.*) catch {};
        return out.items;
    }

    pub fn restoreOpen(e: *Explorer, folders: []const []const u8) void {
        for (folders) |f| {
            if (!fs.isDirectory(e.io, f)) continue;
            const k = e.intern(f);
            e.dirs.put(e.gpa, k, {}) catch {};
            e.state.setOpen(e.gpa, k, true);
        }
    }

    /// The folder files dropped at `p` copy into: a row's folder, the
    /// folder of a row's file, or the root below the rows; null outside.
    pub fn dropTarget(e: *const Explorer, p: ui.Point) ?[]const u8 {
        const area = e.area_rect orelse return null;
        if (!area.contains(p)) return null;
        for (e.drop_rows.items) |r| if (r.rect.contains(p)) {
            return if (e.dirs.contains(r.path)) r.path else std.fs.path.dirname(r.path) orelse e.root;
        };
        return e.root;
    }

    /// How rows look beyond Git's marks: the file shown, and the files with
    /// changes not saved, in the editor's color for them.
    pub const Look = struct {
        active: ?[]const u8 = null,
        dirty: []const []const u8 = &.{},
        modified: ui.Color = .transparent,
    };

    pub fn view(e: *Explorer, c: *ui.Context, faint: ui.Color, colors: StatusColors, look: Look) Event {
        const t = c.theme;
        var ev: Event = .none;
        e.drop_rows.clearRetainingCapacity();
        const roots = e.children(e.root);
        // The tree in a box of its own: a click on the space below the files
        // lets go of the file chosen, a right click there is the workspace's menu.
        const area = ui.div(c).column().wFull().grow();
        var rows = ui.outline([]const u8, c, &e.state, roots, e, .{ .row_height = 22, .indent = 12, .padding = .xy(0, 2) });
        while (rows.next()) |r| {
            const dir = e.dirs.contains(r.item);
            const name = std.fs.path.basename(r.item);
            const mark = e.marks.get(r.item);
            const ignored = mark == null and e.isIgnored(r.item);
            const unsaved = !dir and for (look.dirty) |d| {
                if (std.mem.eql(u8, d, r.item)) break true;
            } else false;
            const active = if (look.active) |a| std.mem.eql(u8, a, r.item) else false;
            // Changed in the editor, then ignored, then Git's mark; files
            // other than the one shown a little quieter.
            const color = if (unsaved) look.modified else if (ignored) faint else if (mark) |m| colors.of(m) else if (!dir and !active) t.text.mix(t.muted, 0.35) else t.text;
            const cell = ui.div(c).row().grow().h(22).gap(6).itemsCenter();
            if (dir) {
                icons.folder(c, name, e.state.isOpen(r.item));
            } else icons.file(c, name);
            ui.text(c, name, .{ .size = 13, .color = color });
            ui.spacer(c);
            if (mark) |m| {
                ui.text(c, c.print("{c}", .{@intFromEnum(m)}), .{ .size = 11, .color = color, .mono = true });
                _ = c.leaf(.{ .width = .{ .px = 8 } }, .none, null);
            } else if (dir and e.marked_dirs.contains(r.item)) {
                _ = c.leaf(.{ .width = .{ .px = 6 }, .height = .{ .px = 6 }, .radius = 3, .background = colors.modified }, .none, null);
                _ = c.leaf(.{ .width = .{ .px = 10 } }, .none, null);
            }
            const ia = cell.interaction();
            cell.end();
            if (ia.rect) |rr| e.drop_rows.append(e.gpa, .{ .rect = rr, .path = r.item }) catch {};
            if (ia.pressed and c.input.pressed and !dir and ev == .none) ev = .{ .press = r.item };
            if (ia.double_clicked) {
                if (!dir) ev = .{ .open = .{ .path = r.item, .preview = false } };
            } else if (ia.clicked) {
                e.state.selected = r.item;
                if (dir) e.state.setOpen(e.gpa, r.item, !e.state.isOpen(r.item)) else ev = .{ .open = .{ .path = r.item, .preview = true } };
                c.changed = true;
            }
            if (ui.contextMenu(c, &e.menu, ia)) |m| {
                defer m.end();
                e.menu_path = r.item;
                e.state.selected = r.item;
                const folder = if (dir) r.item else std.fs.path.dirname(r.item) orelse e.root;
                if (m.item("New File…", .{})) ev = .{ .new_file = folder };
                if (m.item("New Folder…", .{})) ev = .{ .new_folder = folder };
                m.separator();
                if (m.item("Reveal in File Explorer", .{})) myzig.shell.showInFolder(r.item);
                if (m.item("Open in Terminal", .{})) ev = .{ .open_terminal = folder };
                m.separator();
                if (mark != null and !dir) {
                    if (m.item("Open Changes", .{})) ev = .{ .open_changes = r.item };
                    m.separator();
                }
                if (m.item("Copy", .{ .shortcut = ui.keys.label("⌘C") })) myzig.clipboard.writeFiles(e.gpa, &.{r.item}) catch {};
                if (m.item("Paste", .{ .shortcut = ui.keys.label("⌘V") })) ev = .{ .paste = folder };
                m.separator();
                if (m.item("Copy Path", .{})) _ = myzig.clipboard.writeText(r.item);
                if (m.item("Copy Relative Path", .{})) {
                    const rel = c.print("{s}", .{fs.relative(e.root, r.item)});
                    std.mem.replaceScalar(u8, @constCast(rel), '\\', '/');
                    _ = myzig.clipboard.writeText(rel);
                }
                m.separator();
                if (m.item("Rename…", .{ .shortcut = "F2" })) ev = .{ .rename = r.item };
                if (m.item("Delete", .{ .shortcut = "Del" })) ev = .{ .trash = r.item };
            }
        }
        const res = rows.end();
        const ai = area.interaction();
        e.area_rect = ai.rect;
        area.end();
        if (ai.clicked and ev == .none) {
            e.state.selected = null;
            c.changed = true;
        }
        if (ui.contextMenu(c, &e.space_menu, ai)) |m| {
            defer m.end();
            if (m.item("New File…", .{})) ev = .{ .new_file = e.root };
            if (m.item("New Folder…", .{})) ev = .{ .new_folder = e.root };
            m.separator();
            if (m.item("Reveal in File Explorer", .{})) myzig.shell.showInFolder(e.root);
            if (m.item("Open in Terminal", .{})) ev = .{ .open_terminal = e.root };
            m.separator();
            if (m.item("Paste", .{ .shortcut = ui.keys.label("⌘V") })) ev = .{ .paste = e.root };
        }
        e.focused = res.focused;
        if (e.state.selected) |sel| {
            if (res.submitted and !e.dirs.contains(sel)) ev = .{ .open = .{ .path = sel, .preview = false } };
            if (res.focused) {
                if (c.shortcut(.{ .key = ui.Shortcut.f1 + 1 })) ev = .{ .rename = sel };
                if (c.shortcut(.{ .key = ui.Shortcut.delete })) ev = .{ .trash = sel };
                if (c.shortcut(.{ .key = ui.Shortcut.escape })) e.state.selected = null;
                if (c.shortcut(.{ .key = 'c', .cmd = true })) myzig.clipboard.writeFiles(e.gpa, &.{sel}) catch {};
                if (c.shortcut(.{ .key = 'v', .cmd = true })) ev = .{ .paste = if (e.dirs.contains(sel)) sel else std.fs.path.dirname(sel) orelse e.root };
            }
        }
        return ev;
    }
};

const DropRow = struct { rect: ui.Rect, path: []const u8 };

pub const StatusColors = struct {
    modified: ui.Color,
    added: ui.Color,
    deleted: ui.Color,
    conflict: ui.Color,
    muted: ui.Color,

    pub fn of(s: StatusColors, st: git.Status) ui.Color {
        return switch (st) {
            .modified, .renamed => s.modified,
            .added, .untracked => s.added,
            .deleted => s.deleted,
            .conflict => s.conflict,
            .ignored => s.muted,
        };
    }
};

pub fn joinNative(gpa: std.mem.Allocator, top: []const u8, rel: []const u8) ![]u8 {
    const p = try std.fs.path.join(gpa, &.{ top, rel });
    if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, p, '/', std.fs.path.sep);
    return p;
}
