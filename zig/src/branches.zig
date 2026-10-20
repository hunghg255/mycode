//! Branches: the box of Switch Branch… (and Delete Branch…), local and of
//! the remotes, the one checked out first, then by the last commit, each
//! with its last commit's subject and age; typing a new name creates one.
//! Also the stash's box.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const icons = @import("icons.zig");
const git = @import("git.zig");
const quickopen = @import("quickopen.zig");

pub const Branch = struct {
    /// refs/heads/x or refs/remotes/origin/x.
    ref: []const u8,
    name: []const u8,
    subject: []const u8,
    age: []const u8,
    upstream: []const u8,
    remote: bool,
    head: bool,
};

pub const Mode = enum { switch_branch, delete_branch, stash_apply, stash_pop, stash_view, stash_drop };

pub const Pick = union(enum) {
    checkout: Branch,
    create: []const u8,
    delete: Branch,
    rename: Branch,
    stash: struct { mode: Mode, name: []const u8 },
};

pub const Picker = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    dialog: ui.OverlayState = .{},
    query: ui.TextBuffer = .{},
    mode: Mode = .switch_branch,
    arena: std.heap.ArenaAllocator,
    branches: []Branch = &.{},
    /// A stash's entries: `stash@{n}` and its message.
    stashes: [][2][]const u8 = &.{},
    shown: std.ArrayList(usize) = .empty,
    selected: usize = 0,
    /// Builds left in which the field takes the keyboard: the dialog
    /// clears the focus as it opens.
    focus: u8 = 0,
    /// Shown this frame: an Enter now chose what opened it.
    fresh: bool = false,
    menu: ui.Menu = .{},

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Picker {
        return .{ .gpa = gpa, .io = io, .arena = .init(gpa) };
    }

    pub fn deinit(p: *Picker) void {
        p.arena.deinit();
        p.shown.deinit(p.gpa);
    }

    pub fn show(p: *Picker, top: []const u8, mode: Mode) void {
        _ = p.arena.reset(.retain_capacity);
        p.mode = mode;
        p.query.clear();
        p.selected = 0;
        p.focus = 6;
        p.fresh = true;
        switch (mode) {
            .switch_branch, .delete_branch => p.branches = list(p.arena.allocator(), p.io, top) catch &.{},
            else => p.stashes = stashList(p.arena.allocator(), p.io, top) catch &.{},
        }
        p.dialog.show();
    }

    fn filter(p: *Picker) void {
        p.shown.clearRetainingCapacity();
        const q = std.mem.trim(u8, p.query.text(), " ");
        switch (p.mode) {
            .switch_branch, .delete_branch => for (p.branches, 0..) |b, i| {
                if (p.mode == .delete_branch and b.head) continue;
                if (quickopen.score(b.name, q) != null) p.shown.append(p.gpa, i) catch {};
            },
            else => for (p.stashes, 0..) |s, i| if (quickopen.score(s[1], q) != null or quickopen.score(s[0], q) != null) p.shown.append(p.gpa, i) catch {},
        }
    }

    pub fn view(p: *Picker, c: *ui.Context) ?Pick {
        const d = ui.dialog(c, &p.dialog, .{ .width = .{ .px = 560 }, .padding = .all(8), .gap = 6 }) orelse return null;
        defer d.end();
        const t = c.theme;
        const fid = c.peekId(null);
        if (p.focus > 0) {
            if (c.focus != fid) c.changed = true;
            c.focus = fid;
            p.focus -= 1;
        }
        const placeholder = switch (p.mode) {
            .switch_branch => "Select a branch to check out, or type a name to create one",
            .delete_branch => "Select a branch to delete",
            else => "Select a stash entry",
        };
        const field = ui.textField(c, &p.query, .{ .width = .fill, .placeholder = placeholder, .size = 14 });
        p.filter();
        const q = std.mem.trim(u8, p.query.text(), " ");
        const creating = p.mode == .switch_branch and q.len > 0 and !p.exists(q);
        const n = p.shown.items.len + @intFromBool(creating);
        if (c.shortcut(.{ .key = ui.Shortcut.down })) p.selected = if (n == 0) 0 else (p.selected + 1) % n;
        if (c.shortcut(.{ .key = ui.Shortcut.up })) p.selected = if (n == 0) 0 else (p.selected + n - 1) % n;
        if (p.selected >= n) p.selected = 0;
        var pick: ?Pick = null;
        var rows = ui.list(c, .{ .count = n, .row_height = 28, .height = .{ .px = @min(@as(f32, @floatFromInt(n)) * 28, 420) } });
        while (rows.next()) |i| {
            const on = i == p.selected;
            const row = ui.div(c).row().wFull().h(28).px(8).gap(8).itemsCenter().rounded(4).bg(if (on) t.accent.alpha(0.25) else .transparent).hover(t.surface_hover);
            if (creating and i == 0) {
                icons.sym(c, "plus", .{ .size = 12, .color = t.muted });
                ui.text(c, c.print("Create branch “{s}”", .{q}), .{ .size = 13 });
            } else {
                const k = p.shown.items[i - @intFromBool(creating)];
                switch (p.mode) {
                    .switch_branch, .delete_branch => {
                        const b = p.branches[k];
                        icons.sym(c, if (b.remote) "globe" else "arrow.triangle.branch", .{ .size = 12, .color = t.muted });
                        ui.text(c, b.name, .{ .size = 13, .weight = if (b.head) .semibold else .regular });
                        if (b.head) ui.text(c, "current", .{ .size = 11, .color = t.accent });
                        ui.text(c, b.subject, .{ .size = 11, .color = t.muted });
                        ui.spacer(c);
                        ui.text(c, b.age, .{ .size = 11, .color = t.muted });
                    },
                    else => {
                        const s = p.stashes[k];
                        ui.text(c, s[0], .{ .size = 12, .mono = true, .color = t.muted });
                        ui.text(c, s[1], .{ .size = 13 });
                    },
                }
            }
            const ri = row.interaction();
            row.end();
            if (ri.clicked) {
                p.selected = i;
                pick = p.pickAt(i, creating, q);
            }
            if (!(creating and i == 0) and (p.mode == .switch_branch)) if (ui.contextMenu(c, &p.menu, ri)) |m| {
                defer m.end();
                const b = p.branches[p.shown.items[i - @intFromBool(creating)]];
                if (m.item("Check Out", .{})) pick = .{ .checkout = b };
                if (!b.remote) if (m.item("Rename…", .{})) {
                    pick = .{ .rename = b };
                };
                if (!b.head) if (m.item("Delete…", .{})) {
                    pick = .{ .delete = b };
                };
            };
        }
        rows.end();
        if (n == 0) ui.text(c, "Nothing matches.", .{ .size = 12, .color = t.muted });
        // The Enter that chose the command opening the picker isn't its own.
        if (field.submitted and n > 0 and !p.fresh) pick = p.pickAt(p.selected, creating, q);
        p.fresh = false;
        if (pick != null) p.dialog.close();
        return pick;
    }

    fn exists(p: *const Picker, name: []const u8) bool {
        for (p.branches) |b| if (std.mem.eql(u8, b.name, name)) return true;
        return false;
    }

    fn pickAt(p: *Picker, i: usize, creating: bool, q: []const u8) ?Pick {
        if (creating and i == 0) return .{ .create = q };
        const k = p.shown.items[i - @intFromBool(creating)];
        return switch (p.mode) {
            .switch_branch => .{ .checkout = p.branches[k] },
            .delete_branch => .{ .delete = p.branches[k] },
            else => .{ .stash = .{ .mode = p.mode, .name = p.stashes[k][0] } },
        };
    }
};

/// The branches, local then of the remotes, the one checked out first,
/// each group by its last commit, newest first.
pub fn list(a: std.mem.Allocator, io: std.Io, top: []const u8) ![]Branch {
    const r = try git.run(a, io, top, &.{ "for-each-ref", "--sort=-committerdate", "--format=%(refname)%00%(refname:short)%00%(subject)%00%(committerdate:relative)%00%(upstream:short)%00%(HEAD)", "refs/heads", "refs/remotes" });
    if (!r.ok) return error.GitFailed;
    var out: std.ArrayList(Branch) = .empty;
    var it = std.mem.tokenizeScalar(u8, r.stdout, '\n');
    while (it.next()) |l| {
        var f = std.mem.splitScalar(u8, l, 0);
        const ref = f.next() orelse continue;
        if (std.mem.endsWith(u8, ref, "/HEAD")) continue;
        const b: Branch = .{
            .ref = ref,
            .name = f.next() orelse "",
            .subject = f.next() orelse "",
            .age = f.next() orelse "",
            .upstream = f.next() orelse "",
            .remote = std.mem.startsWith(u8, ref, "refs/remotes/"),
            .head = std.mem.eql(u8, std.mem.trim(u8, f.next() orelse "", " "), "*"),
        };
        try out.append(a, b);
    }
    // The branch checked out first, local ones before the remotes'.
    std.mem.sort(Branch, out.items, {}, struct {
        fn lt(_: void, x: Branch, y: Branch) bool {
            if (x.head != y.head) return x.head;
            return !x.remote and y.remote;
        }
    }.lt);
    return out.items;
}

pub fn stashList(a: std.mem.Allocator, io: std.Io, top: []const u8) ![][2][]const u8 {
    const r = try git.run(a, io, top, &.{ "stash", "list", "--format=%gd%x00%s" });
    var out: std.ArrayList([2][]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, r.stdout, '\n');
    while (it.next()) |l| {
        var f = std.mem.splitScalar(u8, l, 0);
        try out.append(a, .{ f.next() orelse "", f.rest() });
    }
    return out.items;
}

pub const AheadBehind = struct { ahead: usize = 0, behind: usize = 0, upstream: bool = false };

/// How far the branch is ahead of its upstream and behind it.
pub fn aheadBehind(gpa: std.mem.Allocator, io: std.Io, top: []const u8) AheadBehind {
    const l = git.line(gpa, io, top, &.{ "rev-list", "--left-right", "--count", "HEAD...@{upstream}" }) orelse return .{};
    defer gpa.free(l);
    var it = std.mem.tokenizeAny(u8, l, " \t");
    const a = std.fmt.parseInt(usize, it.next() orelse "0", 10) catch 0;
    const b = std.fmt.parseInt(usize, it.next() orelse "0", 10) catch 0;
    return .{ .ahead = a, .behind = b, .upstream = true };
}
