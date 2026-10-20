//! COMMITS in source control: the branch's last commits, newest first, on a
//! graph of their branches, each with its author's initials, its branches
//! and tags, and its age; a ring marks HEAD, a hollow dot a merge.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const icons = @import("icons.zig");
const git = @import("git.zig");

pub const Commit = struct {
    hash: []const u8,
    parents: []const []const u8,
    author: []const u8,
    age: []const u8,
    refs: []const u8,
    subject: []const u8,
    /// Its lane, and the lanes running past it (each a color index).
    lane: u8 = 0,
    lanes: []const u8 = &.{},
    head: bool = false,
    unpushed: bool = false,
};

pub const lane_colors = [_]u24{ 0x5a8ee0, 0xe8b86d, 0x4fa86d, 0xb99cf7, 0xe0607e, 0x7dcfe0, 0xf2a679 };

pub const Graph = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    commits: []Commit = &.{},
    limit: usize = 50,
    all: bool = false,
    menu: ui.Menu = .{},
    menu_at: usize = 0,
    /// The remotes' names, which tell a remote's branch from a local one.
    remotes: []const []const u8 = &.{},
    /// The branch checked out, and a command stopped for conflicts: what
    /// the menu offers.
    branch: []const u8 = "",
    op: []const u8 = "",

    pub fn init(gpa: std.mem.Allocator) Graph {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    /// A commit's branches and tags, from its decoration ("HEAD -> main,
    /// origin/main, tag: v1"), HEAD left out.
    pub fn refsOf(g: *const Graph, refs: []const u8, out: []Ref) []Ref {
        var n: usize = 0;
        var it = std.mem.tokenizeSequence(u8, refs, ", ");
        while (it.next()) |r0| {
            if (n == out.len) break;
            var r = r0;
            if (std.mem.startsWith(u8, r, "HEAD -> ")) r = r[8..];
            if (std.mem.eql(u8, r, "HEAD") or std.mem.endsWith(u8, r, "/HEAD")) continue;
            if (std.mem.startsWith(u8, r, "tag: ")) {
                out[n] = .{ .name = r[5..], .kind = .tag };
            } else {
                var remote = false;
                if (std.mem.indexOfScalar(u8, r, '/')) |slash| for (g.remotes) |rm| if (std.mem.eql(u8, rm, r[0..slash])) {
                    remote = true;
                };
                out[n] = .{ .name = r, .kind = if (remote) .remote else .branch };
            }
            n += 1;
        }
        return out[0..n];
    }

    pub fn deinit(g: *Graph) void {
        g.arena.deinit();
    }

    pub fn load(g: *Graph, io: std.Io, top: []const u8) void {
        _ = g.arena.reset(.retain_capacity);
        const a = g.arena.allocator();
        var nbuf: [16]u8 = undefined;
        const n = std.fmt.bufPrint(&nbuf, "-n{d}", .{g.limit}) catch "-n50";
        const args: []const []const u8 = if (g.all)
            &.{ "log", "--format=%H%x00%P%x00%an%x00%cr%x00%D%x00%s", n, "--all" }
        else
            &.{ "log", "--format=%H%x00%P%x00%an%x00%cr%x00%D%x00%s", n };
        const r = git.run(a, io, top, args) catch return;
        if (!r.ok) {
            g.commits = &.{};
            return;
        }
        var remotes: std.ArrayList([]const u8) = .empty;
        if (git.run(a, io, top, &.{"remote"})) |rm| {
            var it = std.mem.tokenizeAny(u8, rm.stdout, "\r\n");
            while (it.next()) |name| remotes.append(a, name) catch {};
        } else |_| {}
        g.remotes = remotes.items;
        // Commits not pushed: those after the upstream.
        var unpushed: std.StringHashMapUnmanaged(void) = .empty;
        if (git.run(a, io, top, &.{ "rev-list", "@{upstream}..HEAD" })) |u| {
            var it = std.mem.tokenizeAny(u8, u.stdout, "\r\n");
            while (it.next()) |h| unpushed.put(a, h, {}) catch {};
        } else |_| {}
        var list: std.ArrayList(Commit) = .empty;
        var it = std.mem.tokenizeScalar(u8, r.stdout, '\n');
        while (it.next()) |l| {
            var f = std.mem.splitScalar(u8, l, 0);
            const hash = f.next() orelse continue;
            const ps = f.next() orelse "";
            var parents: std.ArrayList([]const u8) = .empty;
            var pit = std.mem.tokenizeScalar(u8, ps, ' ');
            while (pit.next()) |p| parents.append(a, p) catch {};
            const author = f.next() orelse "";
            const age = f.next() orelse "";
            const refs = f.next() orelse "";
            list.append(a, .{
                .hash = hash,
                .parents = parents.items,
                .author = author,
                .age = age,
                .refs = refs,
                .subject = f.rest(),
                .head = std.mem.startsWith(u8, refs, "HEAD"),
                .unpushed = unpushed.contains(hash),
            }) catch {};
        }
        g.commits = list.items;
        layout(a, g.commits);
    }

    /// Gives each commit a lane: a commit takes the lane waiting for it, its
    /// first parent keeps it, other parents get lanes of their own.
    fn layout(a: std.mem.Allocator, commits: []Commit) void {
        var lanes: std.ArrayList(?[]const u8) = .empty;
        for (commits) |*c| {
            var mine: ?usize = null;
            for (lanes.items, 0..) |w, i| if (w) |h| if (std.mem.eql(u8, h, c.hash)) {
                if (mine == null) mine = i else lanes.items[i] = null; // merged lanes end
            };
            const lane = mine orelse blk: {
                for (lanes.items, 0..) |w, i| if (w == null) break :blk i;
                lanes.append(a, null) catch {};
                break :blk lanes.items.len - 1;
            };
            c.lane = @intCast(@min(lane, 255));
            const snap = a.alloc(u8, lanes.items.len) catch return;
            for (lanes.items, 0..) |w, i| snap[i] = if (w != null or i == lane) 1 else 0;
            c.lanes = snap;
            if (c.parents.len == 0) {
                lanes.items[lane] = null;
            } else {
                lanes.items[lane] = c.parents[0];
                for (c.parents[1..]) |p| {
                    var placed = false;
                    for (lanes.items) |w| if (w) |h| if (std.mem.eql(u8, h, p)) {
                        placed = true;
                    };
                    if (placed) continue;
                    for (lanes.items) |*w| if (w.* == null) {
                        w.* = p;
                        placed = true;
                        break;
                    };
                    if (!placed) lanes.append(a, p) catch {};
                }
            }
        }
    }

    pub const Event = union(enum) {
        none,
        open: []const u8,
        keep: []const u8,
        checkout: []const u8,
        branch_at: []const u8,
        tag_at: []const u8,
        undo,
        merge: []const u8,
        rebase: []const u8,
        reset: []const u8,
        revert: struct { hash: []const u8, merge: bool },
        cherry_pick: struct { hash: []const u8, merge: bool },
        continue_op,
        abort_op,
        rename_branch: []const u8,
        delete_branch: []const u8,
        delete_remote: []const u8,
        more,
    };

    pub fn view(g: *Graph, c: *ui.Context) Event {
        const t = c.theme;
        var ev: Event = .none;
        const lane_w: f32 = 12;
        for (g.commits, 0..) |cm, i| {
            c.keyed(cm.hash.ptr);
            const row = ui.div(c).row().wFull().h(24).pl(8).pr(8).gap(6).itemsCenter().hover(t.surface_hover);
            // The lanes, and the commit's dot on its own.
            const lanes_w = @as(f32, @floatFromInt(@max(cm.lanes.len, 1))) * lane_w;
            const lb = ui.div(c).w(lanes_w).h(24);
            for (cm.lanes, 0..) |on, li| if (on == 1) {
                const col = ui.Color.hex(lane_colors[li % lane_colors.len]);
                _ = c.leaf(.{ .absolute = true, .offset = .{ .x = @as(f32, @floatFromInt(li)) * lane_w + lane_w / 2 - 1, .y = 0 }, .width = .{ .px = 2 }, .height = .{ .px = 24 }, .background = col.alpha(0.7) }, .none, null);
            };
            const col = ui.Color.hex(lane_colors[cm.lane % lane_colors.len]);
            const x = @as(f32, @floatFromInt(cm.lane)) * lane_w + lane_w / 2;
            const merge = cm.parents.len > 1;
            const sz: f32 = if (cm.head) 10 else 8;
            _ = c.leaf(.{ .absolute = true, .offset = .{ .x = x - sz / 2, .y = 12 - sz / 2 }, .width = .{ .px = sz }, .height = .{ .px = sz }, .radius = sz, .background = if (merge) t.surface else col, .border = if (cm.head or merge) col else null, .border_width = 2 }, .none, null);
            lb.end();
            ui.text(c, initials(c, cm.author), .{ .size = 10, .weight = .semibold, .color = t.muted });
            if (cm.unpushed) icons.sym(c, "arrow.up", .{ .size = 9, .color = t.accent });
            ui.text(c, cm.subject, .{ .size = 12 });
            if (cm.refs.len > 0) refBadges(c, cm.refs);
            ui.spacer(c);
            ui.text(c, shortAge(c, cm.age), .{ .size = 11, .color = t.muted });
            const ri = row.interaction();
            row.end();
            // Its author, hash, and every branch and tag.
            ui.tooltip(c, ri, if (cm.refs.len > 0) c.print("{s}\n{s}\n{s}\n{s}", .{ cm.subject, cm.author, cm.hash, cm.refs }) else c.print("{s}\n{s}\n{s}", .{ cm.subject, cm.author, cm.hash }));
            if (ri.double_clicked) ev = .{ .keep = cm.hash } else if (ri.clicked) ev = .{ .open = cm.hash };
            if (ui.contextMenu(c, &g.menu, ri)) |m| {
                defer m.end();
                g.menu_at = i;
                const moving = g.op.len > 0;
                const br = if (g.branch.len > 0) g.branch else "HEAD";
                const is_merge = cm.parents.len > 1;
                if (m.item("Open Changes", .{})) ev = .{ .keep = cm.hash };
                m.separator();
                if (m.item("Check Out…", .{ .disabled = moving or cm.head })) ev = .{ .checkout = cm.hash };
                if (m.item(c.print("Merge into {s}…", .{br}), .{ .disabled = moving or cm.head })) ev = .{ .merge = cm.hash };
                if (m.item(c.print("Rebase {s} onto This Commit…", .{br}), .{ .disabled = moving or cm.head })) ev = .{ .rebase = cm.hash };
                m.separator();
                if (m.item("Create Tag Here…", .{})) ev = .{ .tag_at = cm.hash };
                if (m.item("Create Branch Here…", .{})) ev = .{ .branch_at = cm.hash };
                m.separator();
                if (m.item(c.print("Reset {s} to This Commit…", .{br}), .{ .disabled = moving or cm.head })) ev = .{ .reset = cm.hash };
                if (m.item("Revert Commit…", .{ .disabled = moving })) ev = .{ .revert = .{ .hash = cm.hash, .merge = is_merge } };
                if (m.item("Cherry-Pick Commit", .{ .disabled = moving or cm.head })) ev = .{ .cherry_pick = .{ .hash = cm.hash, .merge = is_merge } };
                if (moving) {
                    m.separator();
                    if (m.item(c.print("Continue {s}", .{g.op}), .{})) ev = .continue_op;
                    if (m.item(c.print("Abort {s}…", .{g.op}), .{})) ev = .abort_op;
                }
                m.separator();
                if (m.item("Copy Commit Hash", .{})) _ = myzig.clipboard.writeText(cm.hash);
                if (m.item("Copy Commit Message", .{})) _ = myzig.clipboard.writeText(cm.subject);
                // Each branch and tag: its name, and renaming or deleting it.
                var names: [12]Ref = undefined;
                const refs = g.refsOf(cm.refs, &names);
                for (refs) |rf| if (m.item(c.print("Copy “{s}”", .{rf.name}), .{})) {
                    _ = myzig.clipboard.writeText(rf.name);
                };
                var sep = false;
                for (refs) |rf| switch (rf.kind) {
                    .branch => {
                        if (!sep) m.separator();
                        sep = true;
                        if (m.item(c.print("Rename Branch “{s}”…", .{rf.name}), .{})) ev = .{ .rename_branch = rf.name };
                        if (m.item(c.print("Delete Branch “{s}”…", .{rf.name}), .{ .disabled = std.mem.eql(u8, rf.name, g.branch) })) ev = .{ .delete_branch = rf.name };
                    },
                    .remote => {
                        if (!sep) m.separator();
                        sep = true;
                        if (m.item(c.print("Delete Remote Branch “{s}”…", .{rf.name}), .{})) ev = .{ .delete_remote = rf.name };
                    },
                    .tag => {},
                };
                if (cm.head) {
                    m.separator();
                    if (m.item("Undo Last Commit", .{ .disabled = moving })) ev = .undo;
                }
            }
        }
        if (g.commits.len >= g.limit) {
            const more = ui.div(c).row().wFull().h(24).px(12).itemsCenter().hover(t.surface_hover);
            ui.text(c, "Show More Commits", .{ .size = 12, .color = t.accent });
            if (more.clicked()) ev = .more;
            more.end();
        }
        return ev;
    }
};

pub const Ref = struct { name: []const u8, kind: enum { branch, remote, tag } };

fn initials(c: *ui.Context, name: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, name, " .-_");
    while (it.next()) |w| {
        if (out.items.len == 2) break;
        out.append(c.alloc(), std.ascii.toUpper(w[0])) catch {};
    }
    return out.items;
}

/// "3 days ago" as "3d".
fn shortAge(c: *ui.Context, age: []const u8) []const u8 {
    var it = std.mem.tokenizeScalar(u8, age, ' ');
    const n = it.next() orelse return age;
    const unit = it.next() orelse return age;
    const u: []const u8 = if (std.mem.startsWith(u8, unit, "sec")) "s" else if (std.mem.startsWith(u8, unit, "min")) "m" else if (std.mem.startsWith(u8, unit, "hour")) "h" else if (std.mem.startsWith(u8, unit, "day")) "d" else if (std.mem.startsWith(u8, unit, "week")) "w" else if (std.mem.startsWith(u8, unit, "month")) "mo" else if (std.mem.startsWith(u8, unit, "year")) "y" else return age;
    return c.print("{s}{s}", .{ n, u });
}

/// The branches and tags of a commit, a local branch and its remote's
/// sharing one badge, as `main ⇄ origin`.
fn refBadges(c: *ui.Context, refs: []const u8) void {
    const t = c.theme;
    var it = std.mem.tokenizeSequence(u8, refs, ", ");
    var shown: usize = 0;
    var names: [16][]const u8 = undefined;
    var n: usize = 0;
    while (it.next()) |r0| {
        var r = r0;
        if (std.mem.startsWith(u8, r, "HEAD -> ")) r = r[8..];
        if (std.mem.eql(u8, r, "HEAD") or std.mem.endsWith(u8, r, "/HEAD")) continue;
        if (n < names.len) {
            names[n] = r;
            n += 1;
        }
    }
    for (names[0..n], 0..) |r, i| {
        // A remote's branch whose local one is here goes into its badge.
        if (std.mem.indexOfScalar(u8, r, '/')) |slash| {
            var dup = false;
            for (names[0..n], 0..) |o, j| if (j != i and std.mem.eql(u8, o, r[slash + 1 ..])) {
                dup = true;
            };
            if (dup) continue;
        }
        if (shown == 3) {
            ui.text(c, c.print("+{d}", .{n - i}), .{ .size = 10, .color = t.muted });
            return;
        }
        var label: []const u8 = r;
        for (names[0..n]) |o| if (std.mem.indexOfScalar(u8, o, '/')) |slash| if (std.mem.eql(u8, o[slash + 1 ..], r)) {
            label = c.print("{s} ⇄ {s}", .{ r, o[0..slash] });
        };
        const tag = std.mem.startsWith(u8, r, "tag: ");
        const b = ui.div(c).px(5).h(16).itemsCenter().rounded(3).bg(t.accent.alpha(if (tag) 0.12 else 0.2));
        ui.text(c, if (tag) label[5..] else label, .{ .size = 10, .color = t.text });
        b.end();
        shown += 1;
    }
}
