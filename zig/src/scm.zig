//! Source control: the work tree's changes, grouped as merge changes, staged
//! changes, changes and untracked files (by path, or as a tree), the commit
//! box and its button's menu, the branch with fetch, pull and push, and the
//! COMMITS graph under them.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const git = @import("git.zig");
const icons = @import("icons.zig");
const branches = @import("branches.zig");
const Graph = @import("graph.zig").Graph;
const StatusColors = @import("explorer.zig").StatusColors;

pub const Group = enum { merge, staged, changes, untracked };

/// A command stopped part way for conflicts, by the files it leaves in the
/// Git folder; a rebase picks commits as a cherry-pick does, so it is
/// looked for first.
pub const Op = enum {
    none,
    rebase,
    cherry_pick,
    revert,
    merge,

    pub fn title(op: Op) []const u8 {
        return switch (op) {
            .none => "",
            .rebase => "Rebase",
            .cherry_pick => "Cherry-Pick",
            .revert => "Revert",
            .merge => "Merge",
        };
    }

    /// Its git command: `git <name> --continue`.
    pub fn name(op: Op) []const u8 {
        return switch (op) {
            .none => "",
            .rebase => "rebase",
            .cherry_pick => "cherry-pick",
            .revert => "revert",
            .merge => "merge",
        };
    }

    pub fn of(io: std.Io, git_dir: []const u8) Op {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const marks = [_]struct { []const u8, Op }{
            .{ "rebase-merge", .rebase }, .{ "rebase-apply", .rebase }, .{ "CHERRY_PICK_HEAD", .cherry_pick },
            .{ "REVERT_HEAD", .revert },  .{ "MERGE_HEAD", .merge },
        };
        for (marks) |m| {
            const p = std.fmt.bufPrint(&buf, "{s}{c}{s}", .{ git_dir, std.fs.path.sep, m[0] }) catch continue;
            std.Io.Dir.cwd().access(io, p, .{}) catch continue;
            return m[1];
        }
        return .none;
    }
};

pub const Event = union(enum) {
    none,
    /// A change chosen (relative path), to show in the Changes tab.
    open: struct { path: []const u8, staged: bool },
    open_file: []const u8,
    commit: struct { all: bool, amend: bool, push: bool },
    undo_commit,
    amend_fill,
    run: @import("commands.zig").Cmd,
    commit_open: struct { hash: []const u8, keep: bool },
    commit_checkout: []const u8,
    branch_at: []const u8,
    tag_at: []const u8,
    /// The files chosen, or the one the button or menu is on (in the frame's memory).
    stage: []const []const u8,
    unstage: []const []const u8,
    discard: []const []const u8,
    stage_all: Group,
    unstage_all,
    discard_all: Group,
    stash_files: []const []const u8,
    continue_op,
    abort_op,
    /// A change pressed: it may be dragged into a column (relative path).
    press: []const u8,
};

pub const Scm = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    /// The work tree's top folder, or null outside one.
    top: ?[]u8 = null,
    changes: []git.Change = &.{},
    buf: []u8 = &.{},
    /// Bumped when the status is read again.
    generation: u64 = 1,
    message: ui.TextBuffer = .{},
    open: [4]bool = .{ true, true, true, true },
    commits_open: bool = true,
    tree: bool = false,
    err: ?[]u8 = null,
    branch: ?[]u8 = null,
    ab: branches.AheadBehind = .{},
    graph: Graph,
    commit_menu: ui.Menu = .{},
    more_menu: ui.Menu = .{},
    row_menu: ui.Menu = .{},
    /// The files chosen (Shift and Ctrl clicks), and where a range began.
    chosen: std.ArrayList([]u8) = .empty,
    anchor: ?[]u8 = null,
    /// The rows in order, this frame (for ranges and Ctrl+A).
    order: std.ArrayList([]const u8) = .empty,
    list_focus: bool = false,
    list_id: u64 = 0,
    /// The Git folder, and the command stopped part way in it.
    git_dir: ?[]u8 = null,
    op: Op = .none,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, root: []const u8) Scm {
        return .{ .gpa = gpa, .io = io, .root = root, .graph = .init(gpa) };
    }

    pub fn deinit(s: *Scm) void {
        s.clear();
        s.clearChosen();
        s.chosen.deinit(s.gpa);
        s.order.deinit(s.gpa);
        if (s.top) |t| s.gpa.free(t);
        if (s.git_dir) |d| s.gpa.free(d);
        if (s.err) |e| s.gpa.free(e);
        if (s.branch) |b| s.gpa.free(b);
        s.graph.deinit();
    }

    fn clear(s: *Scm) void {
        if (s.changes.len > 0) s.gpa.free(s.changes);
        if (s.buf.len > 0) s.gpa.free(s.buf);
        s.changes = &.{};
        s.buf = &.{};
    }

    fn clearChosen(s: *Scm) void {
        for (s.chosen.items) |p| s.gpa.free(p);
        s.chosen.clearRetainingCapacity();
        if (s.anchor) |a| s.gpa.free(a);
        s.anchor = null;
    }

    fn isChosen(s: *const Scm, path: []const u8) bool {
        for (s.chosen.items) |p| if (std.mem.eql(u8, p, path)) return true;
        return false;
    }

    fn choose(s: *Scm, path: []const u8) void {
        if (s.isChosen(path)) return;
        const d = s.gpa.dupe(u8, path) catch return;
        s.chosen.append(s.gpa, d) catch s.gpa.free(d);
    }

    fn unchoose(s: *Scm, path: []const u8) void {
        for (s.chosen.items, 0..) |p, i| if (std.mem.eql(u8, p, path)) {
            s.gpa.free(s.chosen.orderedRemove(i));
            return;
        };
    }

    fn setAnchor(s: *Scm, path: []const u8) void {
        if (s.anchor) |a| s.gpa.free(a);
        s.anchor = s.gpa.dupe(u8, path) catch null;
    }

    /// What a row's button or menu acts on: the files chosen when the row is
    /// one of them, else the row's file alone.
    fn targets(s: *const Scm, c: *ui.Context, path: []const u8) []const []const u8 {
        const a = c.alloc();
        if (s.isChosen(path) and s.chosen.items.len > 1) {
            const out = a.alloc([]const u8, s.chosen.items.len) catch return &.{};
            for (s.chosen.items, out) |p, *o| o.* = a.dupe(u8, p) catch "";
            return out;
        }
        const out = a.alloc([]const u8, 1) catch return &.{};
        out[0] = a.dupe(u8, path) catch "";
        return out;
    }

    /// Reads the status, the branch, its distance from upstream and the commits.
    pub fn refresh(s: *Scm) void {
        if (s.top == null) s.top = git.topLevel(s.gpa, s.io, s.root);
        if (s.top) |t| if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, t, '/', std.fs.path.sep);
        const top = s.top orelse return;
        s.clear();
        var buf: []u8 = &.{};
        s.changes = git.status(s.gpa, s.io, top, &buf) catch &.{};
        s.buf = buf;
        // The files chosen that are still changed stay chosen.
        var i: usize = s.chosen.items.len;
        while (i > 0) {
            i -= 1;
            var still = false;
            for (s.changes) |ch| if (std.mem.eql(u8, ch.path, s.chosen.items[i])) {
                still = true;
            };
            if (!still) s.gpa.free(s.chosen.orderedRemove(i));
        }
        s.generation += 1;
        if (s.branch) |b| s.gpa.free(b);
        s.branch = git.branch(s.gpa, s.io, top);
        s.ab = branches.aheadBehind(s.gpa, s.io, top);
        if (s.git_dir == null) s.git_dir = git.line(s.gpa, s.io, top, &.{ "rev-parse", "--absolute-git-dir" });
        s.op = if (s.git_dir) |d| Op.of(s.io, d) else .none;
        if (s.commits_open) s.graph.load(s.io, top);
    }

    /// Which command stopped for conflicts, and how many are left, with the
    /// buttons that go on with it and undo it.
    fn opBanner(s: *Scm, c: *ui.Context, ev_in: Event) Event {
        const t = c.theme;
        var ev = ev_in;
        const conflicts = s.count(.merge);
        const tint = if (conflicts > 0) t.danger else t.accent;
        const bar = ui.div(c).row().wFull().px(10).py(2);
        defer bar.end();
        const box = ui.div(c).row().wFull().gap(6).itemsCenter().pl(8).pr(4).py(4).rounded(5).bg(tint.alpha(0.12));
        defer box.end();
        ui.icon(c, "arrow.triangle.branch", .{ .size = 11, .color = tint });
        const label = if (conflicts > 0)
            c.print("{s} in progress · {d} conflict{s}", .{ s.op.title(), conflicts, if (conflicts == 1) "" else "s" })
        else
            c.print("{s} in progress", .{s.op.title()});
        ui.text(c, label, .{ .size = 11.5 });
        ui.spacer(c);
        if (ui.button(c, "Abort", .{ .variant = .ghost, .size = 11 }).clicked) ev = .abort_op;
        if (ui.button(c, "Continue", .{ .variant = .ghost, .size = 11 }).clicked) ev = .continue_op;
        return ev;
    }

    pub fn setError(s: *Scm, msg: []const u8) void {
        if (s.err) |e| s.gpa.free(e);
        s.err = if (msg.len == 0) null else s.gpa.dupe(u8, msg) catch null;
    }

    pub fn groupOf(ch: git.Change, g: Group) bool {
        return switch (g) {
            .merge => ch.status() == .conflict,
            .staged => ch.staged(),
            .changes => ch.unstaged(),
            .untracked => ch.status() == .untracked,
        };
    }

    pub fn count(s: *const Scm, g: Group) usize {
        var n: usize = 0;
        for (s.changes) |ch| if (groupOf(ch, g)) {
            n += 1;
        };
        return n;
    }

    pub fn view(s: *Scm, c: *ui.Context, busy: bool, colors: StatusColors) Event {
        const t = c.theme;
        var ev: Event = .none;
        if (s.top == null) {
            ui.column(c, .{ .width = .fill, .padding = .all(12), .gap = 10 });
            defer ui.end(c);
            ui.text(c, "The folder isn't in a Git repository.", .{ .size = 12, .color = t.muted, .wrap = true });
            if (ui.button(c, "Initialize Repository", .{ .variant = .primary, .width = .fill, .size = 13 }).clicked) ev = .{ .run = .git_init };
            return ev;
        }
        ui.column(c, .{ .width = .fill, .height = .fill });
        defer ui.end(c);
        if (busy) _ = c.leaf(.{ .width = .fill, .height = .{ .px = 2 }, .background = t.accent.alpha(0.6) }, .none, null);
        // The branch, with fetch, pull and push.
        {
            const bar = ui.div(c).row().wFull().h(28).px(10).gap(4).itemsCenter();
            defer bar.end();
            const b = ui.div(c).row().h(22).px(4).gap(4).itemsCenter().rounded(4).hover(t.surface_hover);
            ui.icon(c, "arrow.triangle.branch", .{ .size = 11, .color = t.muted });
            ui.text(c, s.branch orelse "(no branch)", .{ .size = 12 });
            if (b.clicked()) ev = .{ .run = .git_switch_branch };
            b.end();
            ui.spacer(c);
            if (!s.ab.upstream and s.branch != null) {
                if (ui.button(c, "Publish Branch", .{ .variant = .ghost, .size = 11 }).clicked) ev = .{ .run = .git_push };
            } else {
                if (ui.button(c, "Fetch", .{ .variant = .ghost, .size = 11 }).clicked) ev = .{ .run = .git_fetch };
                if (ui.button(c, c.print("↓{d}", .{s.ab.behind}), .{ .variant = .ghost, .size = 11 }).clicked) ev = .{ .run = .git_pull };
                if (ui.button(c, c.print("↑{d}", .{s.ab.ahead}), .{ .variant = .ghost, .size = 11 }).clicked) ev = .{ .run = .git_push };
            }
            const more = ui.div(c).w(22).h(22).center().rounded(4).hover(t.surface_hover);
            ui.text(c, "⋯", .{ .size = 12, .color = t.muted });
            const mi = more.interaction();
            more.end();
            if (ui.buttonMenu(c, &s.more_menu, mi)) |m| {
                defer m.end();
                const items = [_]struct { []const u8, @import("commands.zig").Cmd }{
                    .{ "Commit", .git_commit },              .{ "Amend Last Commit", .git_commit_amend }, .{ "Undo Last Commit", .git_undo_commit },
                    .{ "Fetch", .git_fetch },                .{ "Pull", .git_pull },                      .{ "Pull (Rebase)", .git_pull_rebase },
                    .{ "Pull (Merge)", .git_pull_merge },    .{ "Push", .git_push },                      .{ "Force Push…", .git_force_push },
                    .{ "Sync", .git_sync },                  .{ "Switch Branch…", .git_switch_branch }, .{ "Create Branch…", .git_create_branch },
                    .{ "Rename Branch…", .git_rename_branch }, .{ "Delete Branch…", .git_delete_branch },
                };
                for (items, 0..) |it, k| {
                    if (k == 3 or k == 10) m.separator();
                    if (m.item(it[0], .{})) ev = .{ .run = it[1] };
                }
                if (m.submenu("Stash")) |sub| {
                    defer sub.end();
                    const st = [_]struct { []const u8, @import("commands.zig").Cmd }{
                        .{ "Stash…", .git_stash },                 .{ "Stash (Include Untracked)…", .git_stash_untracked },
                        .{ "Apply Latest Stash", .git_stash_apply_latest }, .{ "Pop Latest Stash", .git_stash_pop },
                        .{ "Apply Stash…", .git_stash_apply },     .{ "Pop Stash…", .git_stash_pop_pick },
                        .{ "View Stash…", .git_stash_view },       .{ "Drop Stash…", .git_stash_drop },
                    };
                    for (st) |it| if (sub.item(it[0], .{})) {
                        ev = .{ .run = it[1] };
                    };
                }
                m.separator();
                if (m.item("Stage All Changes", .{})) ev = .{ .stage_all = .changes };
                if (m.item("Unstage All Changes", .{})) ev = .unstage_all;
                if (m.item("Discard All Changes", .{})) ev = .{ .discard_all = .changes };
                m.separator();
                if (m.item("View as Tree", .{ .checked = s.tree })) ev = .{ .run = .scm_tree };
                if (m.item("Show All Branches", .{ .checked = s.graph.all })) ev = .{ .run = .show_all_branches };
                if (m.item("Refresh", .{})) ev = .{ .run = .git_refresh };
            }
        }
        if (s.op != .none) ev = s.opBanner(c, ev);
        // The message and the commit button.
        {
            ui.column(c, .{ .width = .fill, .padding = .xy(10, 4), .gap = 6 });
            defer ui.end(c);
            const r = ui.textField(c, &s.message, .{ .width = .fill, .placeholder = c.print("Message ({s} to commit)", .{ui.keys.label("⌘↵")}), .size = 13 });
            const summary = std.mem.sliceTo(s.message.text(), '\n');
            if (summary.len > 50) ui.text(c, c.print("{d} characters in the summary", .{summary.len}), .{ .size = 11, .color = if (summary.len > 72) t.danger else t.muted });
            const nothing_staged = s.count(.staged) == 0;
            const label = if (nothing_staged and s.changes.len > 0) "Commit All" else "Commit";
            ui.row(c, .{ .width = .fill, .gap = 2 });
            if (ui.button(c, label, .{ .variant = .primary, .width = .fill, .size = 13 }).clicked or
                (r.focused and c.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true })) or r.submitted)
                ev = .{ .commit = .{ .all = nothing_staged, .amend = false, .push = false } };
            if (ui.menuButton(c, "", &s.commit_menu, .{ .size = 12 })) |m| {
                defer m.end();
                if (m.item("Commit & Push", .{})) ev = .{ .commit = .{ .all = nothing_staged, .amend = false, .push = true } };
                if (m.item("Amend Last Commit", .{})) ev = .amend_fill;
                if (m.item("Undo Last Commit", .{})) ev = .undo_commit;
            }
            ui.end(c);
            if (s.err) |e| ui.text(c, e, .{ .size = 11, .color = t.danger, .wrap = true });
        }
        s.order.clearRetainingCapacity();
        // The list takes the keyboard when a row is clicked: Ctrl+A, Space.
        const sc = c.open(.{ .scroll = true, .direction = .column, .width = .fill, .grow = 1 }, null);
        defer c.end();
        const sci = c.interact(sc, .{ .focusable = true });
        s.list_focus = sci.focused;
        s.list_id = sci.id;
        if (sci.focused) {
            if (c.shortcut(.{ .key = 'a', .cmd = true })) {
                for (s.changes) |ch| s.choose(ch.path);
            }
            if (s.chosen.items.len > 0 and c.shortcut(.{ .key = ' ' })) {
                var any_unstaged = false;
                for (s.changes) |ch| if (s.isChosen(ch.path) and !ch.staged()) {
                    any_unstaged = true;
                };
                const chosen = s.targets(c, s.chosen.items[0]);
                ev = if (any_unstaged) .{ .stage = chosen } else .{ .unstage = chosen };
            }
            if (c.shortcut(.{ .key = ui.Shortcut.escape })) s.clearChosen();
        }
        if (s.changes.len == 0) {
            ui.column(c, .{ .width = .fill, .padding = .xy(12, 8), .gap = 6 });
            ui.text(c, "No changes.", .{ .size = 12, .color = t.muted });
            if (s.ab.ahead > 0 and s.ab.behind > 0) {
                if (ui.button(c, "Sync", .{ .size = 12, .width = .fill }).clicked) ev = .{ .run = .git_sync };
            } else if (s.ab.ahead > 0) {
                if (ui.button(c, c.print("Push {d} commits", .{s.ab.ahead}), .{ .size = 12, .width = .fill }).clicked) ev = .{ .run = .git_push };
            } else if (s.ab.behind > 0) {
                if (ui.button(c, c.print("Pull {d} commits", .{s.ab.behind}), .{ .size = 12, .width = .fill }).clicked) ev = .{ .run = .git_pull };
            }
            ui.end(c);
        }
        inline for (.{ Group.merge, Group.staged, Group.changes, Group.untracked }, 0..) |g, gi| {
            const n = s.count(g);
            if (n > 0) {
                const title = switch (g) {
                    .merge => "Merge Changes",
                    .staged => "Staged Changes",
                    .changes => "Changes",
                    .untracked => "Untracked",
                };
                const head = ui.div(c).row().wFull().h(24).px(8).gap(6).itemsCenter().hover(t.surface_hover);
                ui.icon(c, if (s.open[gi]) "chevron.down" else "chevron.right", .{ .size = 9, .color = t.muted });
                ui.text(c, title, .{ .size = 11, .weight = .semibold, .color = t.muted });
                ui.text(c, c.print("{d}", .{n}), .{ .size = 10, .color = t.muted });
                ui.spacer(c);
                var acted = false;
                if (head.hovered()) {
                    if (g == .staged) {
                        if (rowButton(c, "minus")) {
                            ev = .unstage_all;
                            acted = true;
                        }
                    } else {
                        if (g != .merge and rowButton(c, "arrow.clockwise")) {
                            ev = .{ .discard_all = g };
                            acted = true;
                        }
                        if (rowButton(c, "plus")) {
                            ev = .{ .stage_all = g };
                            acted = true;
                        }
                    }
                }
                if (head.clicked() and !acted) s.open[gi] = !s.open[gi];
                head.end();
                if (s.open[gi]) {
                    var last_dir: []const u8 = "\x00";
                    for (s.changes) |ch| if (groupOf(ch, g)) {
                        if (s.tree) {
                            const dir = std.fs.path.dirnamePosix(ch.path) orelse "";
                            if (!std.mem.eql(u8, dir, last_dir)) {
                                last_dir = dir;
                                if (dir.len > 0) {
                                    ui.row(c, .{ .width = .fill, .padding = .{ .left = 22, .top = 2, .bottom = 2 }, .gap = 6 });
                                    ui.icon(c, "folder", .{ .size = 11, .color = t.muted });
                                    ui.text(c, dir, .{ .size = 12, .color = t.muted });
                                    ui.end(c);
                                }
                            }
                        }
                        const a = s.changeRow(c, ch, g, colors);
                        if (a != .none) ev = a;
                    };
                }
            }
        }
        // COMMITS.
        {
            const head = ui.div(c).row().wFull().h(24).px(8).gap(6).itemsCenter().hover(t.surface_hover);
            ui.icon(c, if (s.commits_open) "chevron.down" else "chevron.right", .{ .size = 9, .color = t.muted });
            ui.text(c, "COMMITS", .{ .size = 11, .weight = .semibold, .color = t.muted });
            ui.spacer(c);
            var acted = false;
            const all_b = ui.div(c).w(20).h(20).center().rounded(3).hover(t.surface);
            ui.icon(c, "arrow.triangle.branch", .{ .size = 10, .color = if (s.graph.all) t.accent else t.muted });
            if (all_b.clicked()) {
                ev = .{ .run = .show_all_branches };
                acted = true;
            }
            all_b.end();
            if (head.clicked() and !acted) {
                s.commits_open = !s.commits_open;
                if (s.commits_open) if (s.top) |top| s.graph.load(s.io, top);
            }
            head.end();
            if (s.commits_open) switch (s.graph.view(c)) {
                .none => {},
                .open => |h| ev = .{ .commit_open = .{ .hash = h, .keep = false } },
                .keep => |h| ev = .{ .commit_open = .{ .hash = h, .keep = true } },
                .checkout => |h| ev = .{ .commit_checkout = h },
                .branch_at => |h| ev = .{ .branch_at = h },
                .tag_at => |h| ev = .{ .tag_at = h },
                .undo => ev = .undo_commit,
                .more => {
                    s.graph.limit += 50;
                    if (s.top) |top| s.graph.load(s.io, top);
                },
            };
        }
        return ev;
    }

    fn changeRow(s: *Scm, c: *ui.Context, ch: git.Change, g: Group, colors: StatusColors) Event {
        const t = c.theme;
        var act: Event = .none;
        ui.keyed(c, .{ @intFromEnum(g), std.hash.Wyhash.hash(0, ch.path) });
        s.order.append(c.alloc(), ch.path) catch {};
        const on = s.isChosen(ch.path);
        const row = ui.div(c).row().wFull().h(22).pl(if (s.tree) 36 else 22).pr(6).gap(6).itemsCenter().bg(if (on) t.accent.alpha(0.15) else .transparent).hover(t.surface_hover);
        const name = std.fs.path.basenamePosix(ch.path);
        icons.file(c, name);
        const st = ch.status();
        ui.text(c, name, .{ .size = 13, .color = colors.of(st) });
        if (!s.tree) if (std.fs.path.dirnamePosix(ch.path)) |d| ui.text(c, d, .{ .size = 11, .color = t.muted });
        ui.spacer(c);
        if (row.hovered()) {
            if (rowButton(c, "doc.text")) act = .{ .open_file = ch.path };
            switch (g) {
                .staged => if (rowButton(c, "minus")) {
                    act = .{ .unstage = s.targets(c, ch.path) };
                },
                else => {
                    if (g != .merge and rowButton(c, "arrow.clockwise")) act = .{ .discard = s.targets(c, ch.path) };
                    if (rowButton(c, "plus")) act = .{ .stage = s.targets(c, ch.path) };
                },
            }
        }
        const letter: u8 = @intFromEnum(st);
        ui.text(c, c.print("{c}", .{letter}), .{ .size = 11, .mono = true, .color = colors.of(st) });
        const ri = row.interaction();
        row.end();
        if (ri.pressed and c.input.pressed and act == .none and st != .deleted) act = .{ .press = ch.path };
        if ((ri.clicked or ri.double_clicked) and act == .none) {
            if (c.input.shift and s.anchor != null) {
                // A range, from where the last click was, in the rows' order.
                var a_i: ?usize = null;
                for (s.order.items, 0..) |p, k| if (std.mem.eql(u8, p, ch.path)) {
                    a_i = k;
                };
                var b_i: ?usize = null;
                for (s.order.items, 0..) |p, k| if (std.mem.eql(u8, p, s.anchor.?)) {
                    b_i = k;
                };
                if (a_i != null and b_i != null) {
                    for (@min(a_i.?, b_i.?)..@max(a_i.?, b_i.?) + 1) |k| s.choose(s.order.items[k]);
                } else s.choose(ch.path);
            } else if (c.input.ctrl or c.input.cmd) {
                if (s.isChosen(ch.path)) s.unchoose(ch.path) else s.choose(ch.path);
                s.setAnchor(ch.path);
            } else {
                s.clearChosen();
                s.choose(ch.path);
                s.setAnchor(ch.path);
                act = .{ .open = .{ .path = ch.path, .staged = g == .staged } };
            }
            c.focus = s.list_id;
        }
        if (ui.contextMenu(c, &s.row_menu, ri)) |m| {
            defer m.end();
            if (m.item("Open Changes", .{})) act = .{ .open = .{ .path = ch.path, .staged = g == .staged } };
            if (m.item("Open File", .{})) act = .{ .open_file = ch.path };
            m.separator();
            if (g == .staged) {
                if (m.item("Unstage Changes", .{})) act = .{ .unstage = s.targets(c, ch.path) };
            } else {
                if (m.item("Stage Changes", .{})) act = .{ .stage = s.targets(c, ch.path) };
                if (g != .merge) if (m.item("Discard Changes", .{})) {
                    act = .{ .discard = s.targets(c, ch.path) };
                };
            }
            if (m.item("Stash Changes…", .{})) act = .{ .stash_files = s.targets(c, ch.path) };
        }
        return act;
    }
};

fn rowButton(c: *ui.Context, icon: []const u8) bool {
    const b = ui.div(c).w(18).h(18).center().rounded(3).hover(c.theme.surface);
    ui.icon(c, icon, .{ .size = 10, .color = c.theme.muted });
    const clicked = b.clicked();
    b.end();
    return clicked;
}
