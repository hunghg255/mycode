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
    stage: []const u8,
    unstage: []const u8,
    discard: []const u8,
    stage_all: Group,
    unstage_all,
    discard_all: Group,
    stash_files: []const u8,
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
    selected: ?[]const u8 = null,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, root: []const u8) Scm {
        return .{ .gpa = gpa, .io = io, .root = root, .graph = .init(gpa) };
    }

    pub fn deinit(s: *Scm) void {
        s.clear();
        if (s.top) |t| s.gpa.free(t);
        if (s.err) |e| s.gpa.free(e);
        if (s.branch) |b| s.gpa.free(b);
        s.graph.deinit();
    }

    fn clear(s: *Scm) void {
        if (s.changes.len > 0) s.gpa.free(s.changes);
        if (s.buf.len > 0) s.gpa.free(s.buf);
        s.changes = &.{};
        s.buf = &.{};
        s.selected = null;
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
        s.generation += 1;
        if (s.branch) |b| s.gpa.free(b);
        s.branch = git.branch(s.gpa, s.io, top);
        s.ab = branches.aheadBehind(s.gpa, s.io, top);
        if (s.commits_open) s.graph.load(s.io, top);
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
                    .{ "Push", .git_push },                  .{ "Force Push…", .git_force_push },        .{ "Sync", .git_sync },
                    .{ "Switch Branch…", .git_switch_branch }, .{ "Create Branch…", .git_create_branch }, .{ "Delete Branch…", .git_delete_branch },
                };
                for (items, 0..) |it, k| {
                    if (k == 3 or k == 9) m.separator();
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
                if (m.item("View as Tree", .{ .checked = s.tree })) s.tree = !s.tree;
                if (m.item("Show All Branches", .{ .checked = s.graph.all })) ev = .{ .run = .show_all_branches };
                if (m.item("Refresh", .{})) ev = .{ .run = .git_refresh };
            }
        }
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
        ui.scroll(c, .{ .width = .fill, .grow = 1 });
        defer ui.end(c);
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
        const on = if (s.selected) |sel| std.mem.eql(u8, sel, ch.path) else false;
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
                    act = .{ .unstage = ch.path };
                },
                else => {
                    if (g != .merge and rowButton(c, "arrow.clockwise")) act = .{ .discard = ch.path };
                    if (rowButton(c, "plus")) act = .{ .stage = ch.path };
                },
            }
        }
        const letter: u8 = @intFromEnum(st);
        ui.text(c, c.print("{c}", .{letter}), .{ .size = 11, .mono = true, .color = colors.of(st) });
        const ri = row.interaction();
        row.end();
        if ((ri.clicked or ri.double_clicked) and act == .none) {
            s.selected = ch.path;
            act = .{ .open = .{ .path = ch.path, .staged = g == .staged } };
        }
        if (ui.contextMenu(c, &s.row_menu, ri)) |m| {
            defer m.end();
            if (m.item("Open Changes", .{})) act = .{ .open = .{ .path = ch.path, .staged = g == .staged } };
            if (m.item("Open File", .{})) act = .{ .open_file = ch.path };
            m.separator();
            if (g == .staged) {
                if (m.item("Unstage Changes", .{})) act = .{ .unstage = ch.path };
            } else {
                if (m.item("Stage Changes", .{})) act = .{ .stage = ch.path };
                if (g != .merge) if (m.item("Discard Changes", .{})) {
                    act = .{ .discard = ch.path };
                };
            }
            if (m.item("Stash Changes…", .{})) act = .{ .stash_files = ch.path };
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
