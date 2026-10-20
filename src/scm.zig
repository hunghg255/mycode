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
const scmtree = @import("scmtree.zig");
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
    /// A commit's menu: a merge, a rebase, a reset, branches renamed...
    graph: Graph.Event,
    /// A change pressed: it may be dragged into a column (relative path).
    press: []const u8,
    /// The Changes tab of every change.
    open_all,
    /// A change shown in the Explorer, its path copied (relative).
    reveal: []const u8,
    copy_path: []const u8,
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
    /// The repository has a remote: fetching, pulling and pushing show.
    has_remote: bool = false,
    /// The branch's upstream, as `origin/main`.
    upstream: ?[]u8 = null,
    row_menu: ui.Menu = .{},
    /// The files chosen (Shift and Ctrl clicks), and where a range began.
    chosen: std.ArrayList([]u8) = .empty,
    anchor: ?[]u8 = null,
    /// The rows in order, this frame (for ranges and Ctrl+A).
    order: std.ArrayList([]const u8) = .empty,
    /// The group of each row of `order` (a file can be staged and changed).
    order_g: std.ArrayList(Group) = .empty,
    list_focus: bool = false,
    list_id: u64 = 0,
    /// The Git folder, and the command stopped part way in it.
    git_dir: ?[]u8 = null,
    op: Op = .none,
    /// The next commit amends the last one.
    amending: bool = false,
    /// The folders closed in the tree, by group.
    closed: [4]std.StringHashMapUnmanaged(void) = .{ .empty, .empty, .empty, .empty },

    pub fn init(gpa: std.mem.Allocator, io: std.Io, root: []const u8) Scm {
        return .{ .gpa = gpa, .io = io, .root = root, .graph = .init(gpa) };
    }

    pub fn deinit(s: *Scm) void {
        if (s.upstream) |u| s.gpa.free(u);
        s.clear();
        s.clearChosen();
        s.chosen.deinit(s.gpa);
        s.order.deinit(s.gpa);
        s.order_g.deinit(s.gpa);
        if (s.top) |t| s.gpa.free(t);
        if (s.git_dir) |d| s.gpa.free(d);
        for (&s.closed) |*m| {
            var it = m.keyIterator();
            while (it.next()) |k| s.gpa.free(k.*);
            m.deinit(s.gpa);
        }
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

    /// Chooses `path` alone: the file the Changes tab shows at its top.
    pub fn follow(s: *Scm, path: []const u8) void {
        if (s.chosen.items.len == 1 and std.mem.eql(u8, s.chosen.items[0], path)) return;
        s.clearChosen();
        s.choose(path);
        s.setAnchor(path);
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
        const top = s.locate() orelse return;
        s.applyStatus(readStatus(s.gpa, s.io, top, s.commits_open, s.graph.all, s.graph.limit));
    }

    /// The work tree's top and its Git folder, found once.
    pub fn locate(s: *Scm) ?[]const u8 {
        if (s.top == null) s.top = git.topLevel(s.gpa, s.io, s.root);
        if (s.top) |t| if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, t, '/', std.fs.path.sep);
        const top = s.top orelse return null;
        if (s.git_dir == null) s.git_dir = git.line(s.gpa, s.io, top, &.{ "rev-parse", "--absolute-git-dir" });
        return top;
    }

    /// What `refresh` reads of Git, from any thread; `applyStatus` takes it
    /// on the main thread.
    pub const Status = struct {
        changes: []git.Change = &.{},
        buf: []u8 = &.{},
        branch: ?[]u8 = null,
        ab: branches.AheadBehind = .{},
        upstream: ?[]u8 = null,
        has_remote: bool = false,
        graph: ?Graph.Raw = null,
        /// What Git ignores, for the Explorer, when asked for.
        ignored: ?[]u8 = null,

        pub fn deinit(st: Status, gpa: std.mem.Allocator) void {
            if (st.ignored) |i| gpa.free(i);
            if (st.changes.len > 0) gpa.free(st.changes);
            if (st.buf.len > 0) gpa.free(st.buf);
            if (st.branch) |b| gpa.free(b);
            if (st.upstream) |u| gpa.free(u);
            if (st.graph) |g| g.deinit(gpa);
        }
    };

    pub fn readStatus(gpa: std.mem.Allocator, io: std.Io, top: []const u8, commits: bool, all: bool, limit: usize) Status {
        var st: Status = .{};
        var buf: []u8 = &.{};
        st.changes = git.status(gpa, io, top, &buf) catch &.{};
        st.buf = buf;
        st.branch = git.branch(gpa, io, top);
        st.ab = branches.aheadBehind(gpa, io, top);
        st.upstream = if (st.ab.upstream) git.line(gpa, io, top, &.{ "rev-parse", "--abbrev-ref", "@{upstream}" }) else null;
        if (git.line(gpa, io, top, &.{"remote"})) |r| {
            st.has_remote = r.len > 0;
            gpa.free(r);
        }
        if (commits) st.graph = Graph.fetch(gpa, io, top, all, limit);
        return st;
    }

    /// Takes a status read (owned).
    pub fn applyStatus(s: *Scm, st: Status) void {
        s.clear();
        s.changes = st.changes;
        s.buf = st.buf;
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
        s.branch = st.branch;
        s.ab = st.ab;
        if (s.upstream) |u| s.gpa.free(u);
        s.upstream = st.upstream;
        s.has_remote = st.has_remote;
        s.op = if (s.git_dir) |d| Op.of(s.io, d) else .none;
        if (st.graph) |g| {
            s.graph.loadRaw(g);
            g.deinit(s.gpa);
        }
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
        icons.sym(c, "arrow.triangle.branch", .{ .size = 11, .color = tint });
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
            // As the Go app's: what that means, and a button to make it one.
            const col = ui.div(c).column().wFull().pt(28).px(20).pb(16).gap(8).itemsCenter();
            defer col.end();
            ring(c, "arrow.triangle.branch", t.muted, t.text.alpha(0.06));
            ui.text(c, "No Git Repository", .{ .size = 13, .weight = .semibold, .color = t.text });
            centered(c, "The folder is not in a Git repository. Make it one to track and commit its changes.");
            _ = c.leaf(.{ .height = .{ .px = 4 } }, .none, null);
            if (ui.button(c, "Initialize Repository", .{ .variant = .primary, .width = .fill, .size = 13 }).clicked) ev = .{ .run = .git_init };
            return ev;
        }
        ui.column(c, .{ .width = .fill, .height = .fill });
        defer ui.end(c);
        if (busy) _ = c.leaf(.{ .width = .fill, .height = .{ .px = 2 }, .background = t.accent.alpha(0.6) }, .none, null);
        // The branch, which a click switches, and the buttons of its remote,
        // which say how many commits they would bring.
        {
            const bar = ui.div(c).row().wFull().h(30).px(8).gap(2).itemsCenter();
            defer bar.end();
            const b = ui.div(c).row().h(24).px(6).gap(5).itemsCenter().rounded(5).hover(t.surface_hover);
            icons.sym(c, "arrow.triangle.branch", .{ .size = 10.5, .color = t.muted });
            ui.text(c, s.branch orelse "No Branch", .{ .size = 12.5, .weight = .medium });
            icons.sym(c, "chevron.down", .{ .size = 8.5, .color = t.muted.alpha(0.7) });
            const bi = b.interaction();
            b.end();
            ui.tooltip(c, bi, "Switch Branch…");
            if (bi.clicked and !busy) ev = .{ .run = .git_switch_branch };
            ui.spacer(c);
            if (s.has_remote) {
                if (syncButton(c, "icloud.and.arrow.down", "Fetch", 0, busy)) ev = .{ .run = .git_fetch };
                if (!s.ab.upstream and s.branch != null) {
                    if (syncButton(c, "square.and.arrow.up", "Publish Branch", 0, busy)) ev = .{ .run = .git_push };
                } else {
                    const behind = s.ab.behind;
                    const ahead = s.ab.ahead;
                    if (syncButton(c, "square.and.arrow.down", if (behind > 0) c.print("Pull {d} commit{s}", .{ behind, plural(behind) }) else "Pull", behind, busy)) ev = .{ .run = .git_pull };
                    if (syncButton(c, "square.and.arrow.up", if (ahead > 0) c.print("Push {d} commit{s}", .{ ahead, plural(ahead) }) else "Push", ahead, busy)) ev = .{ .run = .git_push };
                }
            }
        }
        if (s.amending) {
            const bar = ui.div(c).row().wFull().px(10).py(2);
            const box = ui.div(c).row().wFull().gap(6).itemsCenter().pl(8).pr(4).py(4).rounded(5).bg(t.accent.alpha(0.12));
            icons.sym(c, "pencil", .{ .size = 11, .color = t.accent });
            ui.text(c, "Amending last commit", .{ .size = 11.5 });
            ui.spacer(c);
            if (ui.button(c, "Cancel", .{ .variant = .ghost, .size = 11 }).clicked) {
                s.amending = false;
                s.message.clear();
            }
            box.end();
            bar.end();
        }
        if (s.op != .none) ev = s.opBanner(c, ev);
        // The message and the commit button.
        {
            ui.column(c, .{ .width = .fill, .padding = .xy(10, 4), .gap = 6 });
            defer ui.end(c);
            const r = ui.textField(c, &s.message, .{ .width = .fill, .placeholder = c.print("Message ({s} to commit)", .{ui.keys.label("⌘↵")}), .size = 13 });
            // The first line's length, once past what a summary should be.
            const summary = std.mem.trimEnd(u8, std.mem.sliceTo(s.message.text(), '\n'), " \t\r");
            const chars = std.unicode.utf8CountCodepoints(summary) catch summary.len;
            if (chars > 50) {
                const long = chars > 72;
                const note = ui.div(c).row().wFull().px(2);
                const col = if (long) colors.modified else t.muted.alpha(0.7);
                const words = ui.div(c).grow();
                ui.text(c, if (long) "Summary is long" else "Summary", .{ .size = 11, .color = col });
                words.end();
                ui.text(c, c.print("{d}/72", .{chars}), .{ .size = 11, .color = col, .mono = true });
                note.end();
            }
            const nothing_staged = s.count(.staged) == 0;
            const label = if (s.amending) "Amend Commit" else if (nothing_staged and s.changes.len > 0) "Commit All" else "Commit";
            ui.row(c, .{ .width = .fill, .gap = 2 });
            const cbi = ui.button(c, label, .{ .variant = .primary, .width = .fill, .size = 13, .icon = "checkmark" });
            ui.tooltip(c, cbi, if (s.amending)
                "Amend the last commit with the staged changes (Ctrl+Enter)"
            else if (nothing_staged and s.changes.len > 0)
                "Stage every change and commit it (Ctrl+Enter)"
            else
                "Commit the staged changes (Ctrl+Enter)");
            if (cbi.clicked or
                (r.focused and c.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true })) or r.submitted)
                ev = .{ .commit = .{ .all = nothing_staged and !s.amending, .amend = s.amending, .push = false } };
            if (ui.menuButton(c, "", &s.commit_menu, .{ .size = 12 })) |m| {
                defer m.end();
                if (m.item("Commit & Push", .{})) ev = .{ .commit = .{ .all = nothing_staged, .amend = false, .push = true } };
                if (m.item("Amend Last Commit", .{ .checked = s.amending })) {
                    if (s.amending) {
                        s.amending = false;
                        s.message.clear();
                    } else ev = .amend_fill;
                }
                if (m.item("Undo Last Commit", .{})) ev = .undo_commit;
            }
            ui.end(c);
            if (s.err) |e| ui.text(c, e, .{ .size = 11, .color = t.danger, .wrap = true });
        }
        s.order.clearRetainingCapacity();
        s.order_g.clearRetainingCapacity();
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
            // As the Go app's: that it is clean, how the branch stands with
            // its upstream, and a button to bring them level.
            const col = ui.div(c).column().wFull().pt(24).px(20).pb(16).gap(6).itemsCenter();
            ring(c, "checkmark", colors.added, colors.added.alpha(0.13));
            _ = c.leaf(.{ .height = .{ .px = 2 } }, .none, null);
            ui.text(c, "No Changes", .{ .size = 13, .weight = .semibold, .color = t.text });
            const br = s.branch orelse "";
            const ab = s.ab;
            const up = s.upstream orelse "its upstream";
            centered(c, if (br.len == 0)
                "The working tree is clean."
            else if (!ab.upstream and !s.has_remote)
                c.print("{s} is clean.", .{br})
            else if (!ab.upstream)
                c.print("{s} is clean, and not yet published.", .{br})
            else if (ab.ahead > 0 and ab.behind > 0)
                c.print("{s} is clean, {d} commit{s} ahead of {s} and {d} commit{s} behind.", .{ br, ab.ahead, plural(ab.ahead), up, ab.behind, plural(ab.behind) })
            else if (ab.ahead > 0)
                c.print("{s} is clean, {d} commit{s} ahead of {s}.", .{ br, ab.ahead, plural(ab.ahead), up })
            else if (ab.behind > 0)
                c.print("{s} is clean, {d} commit{s} behind {s}.", .{ br, ab.behind, plural(ab.behind), up })
            else
                c.print("{s} is clean and up to date with {s}.", .{ br, up }));
            const opts: ui.ButtonOptions = .{ .variant = .primary, .width = .fill, .size = 13, .disabled = busy };
            if (br.len > 0) {
                if (!ab.upstream and s.has_remote) {
                    _ = c.leaf(.{ .height = .{ .px = 4 } }, .none, null);
                    if (ui.button(c, "Publish Branch", withIcon(opts, "square.and.arrow.up")).clicked) ev = .{ .run = .git_push };
                } else if (ab.upstream and ab.behind > 0 and ab.ahead > 0) {
                    _ = c.leaf(.{ .height = .{ .px = 4 } }, .none, null);
                    if (ui.button(c, c.print("Sync ({d}↓ {d}↑)", .{ ab.behind, ab.ahead }), withIcon(opts, "square.and.arrow.down")).clicked) ev = .{ .run = .git_sync };
                } else if (ab.upstream and ab.behind > 0) {
                    _ = c.leaf(.{ .height = .{ .px = 4 } }, .none, null);
                    if (ui.button(c, c.print("Pull {d} Commit{s}", .{ ab.behind, plural(ab.behind) }), withIcon(opts, "square.and.arrow.down")).clicked) ev = .{ .run = .git_pull };
                } else if (ab.upstream and ab.ahead > 0) {
                    _ = c.leaf(.{ .height = .{ .px = 4 } }, .none, null);
                    if (ui.button(c, c.print("Push {d} Commit{s}", .{ ab.ahead, plural(ab.ahead) }), withIcon(opts, "square.and.arrow.up")).clicked) ev = .{ .run = .git_push };
                }
            }
            col.end();
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
                const head = ui.div(c).row().wFull().h(22).px(8).gap(4).itemsCenter().hover(t.surface_hover);
                icons.sym(c, if (s.open[gi]) "chevron.down" else "chevron.right", .{ .size = 9, .color = t.muted });
                // In the frame's memory: the text is drawn after this returns.
                const upper = c.print("{s}", .{title});
                for (@constCast(upper)) |*ch| ch.* = std.ascii.toUpper(ch.*);
                ui.text(c, upper, .{ .size = 11, .weight = .semibold, .color = t.muted });
                ui.text(c, c.print("{d}", .{n}), .{ .size = 10, .color = t.muted });
                ui.spacer(c);
                var acted = false;
                if (head.hovered()) switch (g) {
                    .staged => {
                        if (rowButtonTip(c, "doc.on.doc", "Open Staged Changes")) {
                            ev = .open_all;
                            acted = true;
                        }
                        if (rowButtonTip(c, "minus", "Unstage All Changes")) {
                            ev = .unstage_all;
                            acted = true;
                        }
                    },
                    .merge => if (rowButtonTip(c, "plus", "Stage All Merge Changes")) {
                        ev = .{ .stage_all = g };
                        acted = true;
                    },
                    else => {
                        if (rowButtonTip(c, "doc.on.doc", "Open Changes")) {
                            ev = .open_all;
                            acted = true;
                        }
                        if (rowButtonTip(c, "arrow.clockwise", "Discard All Changes…")) {
                            ev = .{ .discard_all = g };
                            acted = true;
                        }
                        if (rowButtonTip(c, "plus", "Stage All Changes")) {
                            ev = .{ .stage_all = g };
                            acted = true;
                        }
                    },
                };
                if (head.clicked() and !acted) s.open[gi] = !s.open[gi];
                head.end();
                if (s.open[gi]) {
                    if (s.tree) {
                        const a = s.treeRows(c, g, gi, colors);
                        if (a != .none) ev = a;
                    } else for (s.changes) |ch| if (groupOf(ch, g)) {
                        const a = s.changeRow(c, ch, g, colors, 22);
                        if (a != .none) ev = a;
                    };
                }
            }
        }
        if (sci.focused) if (s.listKeys(c)) |a| {
            ev = a;
        };
        // COMMITS.
        {
            const head = ui.div(c).row().wFull().h(24).px(8).gap(6).itemsCenter().hover(t.surface_hover);
            icons.sym(c, if (s.commits_open) "chevron.down" else "chevron.right", .{ .size = 9, .color = t.muted });
            ui.text(c, "COMMITS", .{ .size = 11, .weight = .semibold, .color = t.muted });
            ui.spacer(c);
            var acted = false;
            const all_b = ui.div(c).w(20).h(20).center().rounded(3).hover(t.surface);
            icons.sym(c, "arrow.triangle.branch", .{ .size = 10, .color = if (s.graph.all) t.accent else t.muted });
            const abi = all_b.interaction();
            all_b.end();
            ui.tooltip(c, abi, if (s.graph.all) "Show Current Branch Only" else "Show All Branches");
            if (abi.clicked) {
                ev = .{ .run = .show_all_branches };
                acted = true;
            }
            if (head.clicked() and !acted) {
                s.commits_open = !s.commits_open;
                if (s.commits_open) if (s.top) |top| s.graph.load(s.io, top);
            }
            head.end();
            s.graph.branch = s.branch orelse "";
            s.graph.op = s.op.title();
            const gev: Graph.Event = if (s.commits_open) s.graph.view(c) else .none;
            switch (gev) {
                .none => {},
                .open => |h| ev = .{ .commit_open = .{ .hash = h, .keep = false } },
                .keep => |h| ev = .{ .commit_open = .{ .hash = h, .keep = true } },
                .checkout => |h| ev = .{ .commit_checkout = h },
                .branch_at => |h| ev = .{ .branch_at = h },
                .tag_at => |h| ev = .{ .tag_at = h },
                .undo => ev = .undo_commit,
                .continue_op => ev = .continue_op,
                .abort_op => ev = .abort_op,
                .merge, .rebase, .reset, .revert, .cherry_pick, .rename_branch, .delete_branch, .delete_remote => ev = .{ .graph = gev },
                .more => {
                    s.graph.limit += 50;
                    if (s.top) |top| s.graph.load(s.io, top);
                },
            }
        }
        return ev;
    }

    /// The list's keys, on the rows as this frame built them: Up and Down
    /// choose the next row (Shift: a range from the anchor), Home and End
    /// the first and the last, Enter opens the chosen change.
    /// The menu of the view's actions, as the Go app's `scmMenu`, opened by
    /// the button beside the sidebar's title.
    pub fn moreMenu(s: *Scm, c: *ui.Context, mi: ui.Interaction, busy: bool) Event {
        var ev: Event = .none;
        const m = ui.buttonMenu(c, &s.more_menu, mi) orelse return ev;
        defer m.end();
        const staged = s.count(.staged);
        const others = s.count(.changes) + s.count(.untracked);
        if (m.item("Commit", .{ .disabled = busy })) ev = .{ .commit = .{ .all = staged == 0, .amend = false, .push = false } };
        if (m.item("Commit & Push", .{ .disabled = busy })) ev = .{ .commit = .{ .all = staged == 0, .amend = false, .push = true } };
        if (m.item("Amend Last Commit", .{})) ev = .amend_fill;
        if (m.item("Undo Last Commit", .{ .disabled = busy })) ev = .undo_commit;
        m.separator();
        if (m.item("Open All Changes", .{ .disabled = staged + others == 0 })) ev = .open_all;
        m.separator();
        if (m.item("Stage All Changes", .{ .disabled = others + s.count(.merge) == 0 })) ev = .{ .stage_all = .changes };
        if (m.item("Unstage All Changes", .{ .disabled = staged == 0 })) ev = .unstage_all;
        if (m.item("Discard All Changes…", .{ .disabled = others == 0 })) ev = .{ .discard_all = .changes };
        m.separator();
        if (m.item("Fetch", .{ .disabled = busy })) ev = .{ .run = .git_fetch };
        if (m.item("Pull", .{ .disabled = busy })) ev = .{ .run = .git_pull };
        if (m.item("Push", .{ .disabled = busy })) ev = .{ .run = .git_push };
        if (m.submenu("Pull, Push")) |sub| {
            defer sub.end();
            const more = [_]struct { []const u8, @import("commands.zig").Cmd }{
                .{ "Pull (Rebase)", .git_pull_rebase }, .{ "Pull (Merge)", .git_pull_merge }, .{ "Force Push…", .git_force_push }, .{ "Sync", .git_sync },
            };
            for (more) |it| if (sub.item(it[0], .{ .disabled = busy })) {
                ev = .{ .run = it[1] };
            };
        }
        if (m.submenu("Branch")) |sub| {
            defer sub.end();
            const more = [_]struct { []const u8, @import("commands.zig").Cmd }{
                .{ "Switch Branch…", .git_switch_branch }, .{ "Create Branch…", .git_create_branch }, .{ "Rename Branch…", .git_rename_branch }, .{ "Delete Branch…", .git_delete_branch },
            };
            for (more) |it| if (sub.item(it[0], .{})) {
                ev = .{ .run = it[1] };
            };
        }
        m.separator();
        if (m.submenu("Stash")) |sub| {
            defer sub.end();
            const st = [_]struct { []const u8, @import("commands.zig").Cmd }{
                .{ "Stash…", .git_stash },                 .{ "Stash (Include Untracked)…", .git_stash_untracked },
                .{ "Apply Latest Stash", .git_stash_apply_latest }, .{ "Pop Latest Stash", .git_stash_pop },
                .{ "Apply Stash…", .git_stash_apply },     .{ "Pop Stash…", .git_stash_pop_pick },
                .{ "View Stash…", .git_stash_view },       .{ "Drop Stash…", .git_stash_drop },
            };
            for (st, 0..) |it, k| {
                if (k == 2 or k == 4) sub.separator();
                if (sub.item(it[0], .{})) ev = .{ .run = it[1] };
            }
        }
        m.separator();
        if (m.item("View as Tree", .{ .checked = s.tree })) ev = .{ .run = .scm_tree };
        if (m.item("Show All Branches", .{ .checked = s.graph.all })) ev = .{ .run = .show_all_branches };
        if (m.item("Refresh", .{})) ev = .{ .run = .git_refresh };
        return ev;
    }

    fn listKeys(s: *Scm, c: *ui.Context) ?Event {
        const n = s.order.items.len;
        if (n == 0) return null;
        const S = ui.Shortcut;
        var at: ?usize = null;
        if (s.anchor) |a| for (s.order.items, 0..) |p, k| if (std.mem.eql(u8, p, a)) {
            at = k;
            break;
        };
        // Where the caret of the choice is: the last chosen row.
        var cur = at;
        if (s.chosen.items.len > 0) for (s.order.items, 0..) |p, k| if (std.mem.eql(u8, p, s.chosen.items[s.chosen.items.len - 1])) {
            cur = k;
        };
        var to: ?usize = null;
        var extend = false;
        if (c.shortcut(.{ .key = S.down })) to = if (cur) |k| @min(k + 1, n - 1) else 0;
        if (c.shortcut(.{ .key = S.up })) to = if (cur) |k| k -| 1 else 0;
        if (c.shortcut(.{ .key = S.down, .shift = true })) {
            to = if (cur) |k| @min(k + 1, n - 1) else 0;
            extend = true;
        }
        if (c.shortcut(.{ .key = S.up, .shift = true })) {
            to = if (cur) |k| k -| 1 else 0;
            extend = true;
        }
        if (c.shortcut(.{ .key = S.home })) to = 0;
        if (c.shortcut(.{ .key = S.end })) to = n - 1;
        if (to) |k| {
            if (extend and at != null) {
                s.clearChosenKeepAnchor();
                const a = at.?;
                var i = @min(a, k);
                while (i <= @max(a, k)) : (i += 1) if (i != k) s.choose(s.order.items[i]);
                s.choose(s.order.items[k]);
            } else {
                s.clearChosen();
                s.choose(s.order.items[k]);
                s.setAnchor(s.order.items[k]);
            }
            c.changed = true;
            return null;
        }
        if (c.shortcut(.{ .key = S.enter })) if (cur) |k| {
            return .{ .open = .{ .path = s.order.items[k], .staged = s.order_g.items[k] == .staged } };
        };
        return null;
    }

    fn clearChosenKeepAnchor(s: *Scm) void {
        for (s.chosen.items) |p| s.gpa.free(p);
        s.chosen.clearRetainingCapacity();
    }

    /// A group's changes as a tree: folders that close, with buttons for
    /// every file under them.
    fn treeRows(s: *Scm, c: *ui.Context, g: Group, gi: usize, colors: StatusColors) Event {
        const t = c.theme;
        const a = c.alloc();
        var ev: Event = .none;
        var list: std.ArrayList(git.Change) = .empty;
        for (s.changes) |ch| if (groupOf(ch, g)) list.append(a, ch) catch {};
        std.mem.sort(git.Change, list.items, {}, struct {
            fn lt(_: void, x: git.Change, y: git.Change) bool {
                return std.mem.lessThan(u8, x.path, y.path);
            }
        }.lt);
        const paths = a.alloc([]const u8, list.items.len) catch return ev;
        for (list.items, paths) |ch, *p| p.* = ch.path;
        for (scmtree.build(a, paths, &s.closed[gi])) |nd| {
            const indent = 22 + @as(f32, @floatFromInt(nd.depth)) * 12;
            if (!nd.folder) {
                const r = s.changeRow(c, list.items[nd.lo], g, colors, indent);
                if (r != .none) ev = r;
                continue;
            }
            ui.keyed(c, .{ gi, std.hash.Wyhash.hash(1, nd.path) });
            const open = !s.closed[gi].contains(nd.path);
            const row = ui.div(c).row().wFull().h(22).pl(indent - 14).pr(6).gap(6).itemsCenter().hover(t.surface_hover);
            icons.sym(c, if (open) "chevron.down" else "chevron.right", .{ .size = 9, .color = t.muted });
            icons.sym(c, "folder", .{ .size = 12, .color = t.muted });
            ui.text(c, nd.name, .{ .size = 13 });
            ui.spacer(c);
            var acted = false;
            if (row.hovered()) {
                const under = paths[nd.lo..nd.hi];
                switch (g) {
                    .staged => if (rowButton(c, "minus")) {
                        ev = .{ .unstage = under };
                        acted = true;
                    },
                    else => {
                        if (g != .merge and rowButton(c, "arrow.clockwise")) {
                            ev = .{ .discard = under };
                            acted = true;
                        }
                        if (rowButton(c, "plus")) {
                            ev = .{ .stage = under };
                            acted = true;
                        }
                    },
                }
            }
            if (row.clicked() and !acted) {
                if (open) {
                    if (s.gpa.dupe(u8, nd.path)) |k| s.closed[gi].put(s.gpa, k, {}) catch s.gpa.free(k) else |_| {}
                } else if (s.closed[gi].fetchRemove(nd.path)) |kv| s.gpa.free(kv.key);
                c.changed = true;
            }
            row.end();
        }
        return ev;
    }

    fn changeRow(s: *Scm, c: *ui.Context, ch: git.Change, g: Group, colors: StatusColors, indent: f32) Event {
        const t = c.theme;
        var act: Event = .none;
        ui.keyed(c, .{ @intFromEnum(g), std.hash.Wyhash.hash(0, ch.path) });
        s.order.append(s.gpa, ch.path) catch {};
        s.order_g.append(s.gpa, g) catch {};
        const on = s.isChosen(ch.path);
        const row = ui.div(c).row().wFull().h(22).pl(indent).pr(6).gap(6).itemsCenter().bg(if (on) t.accent.alpha(0.15) else .transparent).hover(t.surface_hover);
        const name = std.fs.path.basenamePosix(ch.path);
        if (ch.sub) icons.sym(c, "folder", .{ .size = 13, .color = t.accent }) else icons.file(c, name);
        const st = ch.status();
        ui.text(c, name, .{ .size = 13, .color = colors.of(st) });
        if (!s.tree) if (std.fs.path.dirnamePosix(ch.path)) |d| ui.text(c, d, .{ .size = 11, .color = t.muted });
        ui.spacer(c);
        if (row.hovered()) {
            if (rowButtonTip(c, if (ch.sub) "folder" else "doc.text", if (ch.sub) "Open Folder" else "Open File")) act = .{ .open_file = ch.path };
            switch (g) {
                .staged => if (rowButtonTip(c, "minus", "Unstage Changes")) {
                    act = .{ .unstage = s.targets(c, ch.path) };
                },
                else => {
                    if (g != .merge and !ch.sub and rowButtonTip(c, "arrow.clockwise", "Discard Changes…")) act = .{ .discard = s.targets(c, ch.path) };
                    if (rowButtonTip(c, "plus", "Stage Changes")) act = .{ .stage = s.targets(c, ch.path) };
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
            if (m.item(if (ch.sub) "Open Folder" else "Open File", .{})) act = .{ .open_file = ch.path };
            m.separator();
            if (g == .staged) {
                if (m.item("Unstage Changes", .{})) act = .{ .unstage = s.targets(c, ch.path) };
            } else {
                if (m.item("Stage Changes", .{})) act = .{ .stage = s.targets(c, ch.path) };
                if (g != .merge and !ch.sub) if (m.item("Discard Changes…", .{})) {
                    act = .{ .discard = s.targets(c, ch.path) };
                };
            }
            if (!ch.sub) if (m.item("Stash Changes…", .{})) {
                act = .{ .stash_files = s.targets(c, ch.path) };
            };
            m.separator();
            if (m.item("Reveal in Explorer", .{})) act = .{ .reveal = ch.path };
            if (m.item("Copy Path", .{})) act = .{ .copy_path = ch.path };
        }
        return act;
    }
};

/// A row's button, as the Go app's small ones: 20 by 20; discarding is
/// an arrow back.
fn rowButton(c: *ui.Context, icon_name: []const u8) bool {
    const icon = if (std.mem.eql(u8, icon_name, "arrow.clockwise")) "arrow.uturn.backward" else icon_name;
    const b = ui.div(c).w(20).h(20).center().rounded(4).hover(c.theme.surface);
    icons.sym(c, icon, .{ .size = 10, .color = if (b.hovered()) c.theme.text else c.theme.muted });
    const clicked = b.clicked();
    b.end();
    return clicked;
}

/// A row's button with its tooltip.
fn rowButtonTip(c: *ui.Context, icon_name: []const u8, tip: []const u8) bool {
    const icon = if (std.mem.eql(u8, icon_name, "arrow.clockwise")) "arrow.uturn.backward" else icon_name;
    const b = ui.div(c).w(20).h(20).center().rounded(4).hover(c.theme.surface);
    icons.sym(c, icon, .{ .size = 10, .color = if (b.hovered()) c.theme.text else c.theme.muted });
    const bi = b.interaction();
    b.end();
    ui.tooltip(c, bi, tip);
    return bi.clicked;
}

/// A button of the branch's remote, with the count of the commits it
/// would move beside its icon when there are any.
fn syncButton(c: *ui.Context, icon: []const u8, tip: []const u8, n: usize, busy: bool) bool {
    const t = c.theme;
    const b = ui.div(c).row().h(24).minW(26).px(5).gap(3).center().rounded(5);
    if (n > 0) _ = b.bg(t.accent.alpha(if (b.hovered()) 0.2 else 0.12)) else _ = b.hover(t.surface_hover);
    const col = if (n > 0) t.accent else if (b.hovered()) t.text else t.muted;
    icons.sym(c, icon, .{ .size = 10.5, .color = if (busy) t.muted.alpha(0.5) else col });
    if (n > 0) ui.text(c, c.print("{d}", .{n}), .{ .size = 11, .weight = .semibold, .color = col });
    const bi = b.interaction();
    b.end();
    ui.tooltip(c, bi, tip);
    return bi.clicked and !busy;
}

/// The round mark heading an empty state, as the Go app's.
fn ring(c: *ui.Context, icon: []const u8, color: ui.Color, ground: ui.Color) void {
    const r = ui.div(c).w(44).h(44).roundedFull().center().bg(ground);
    icons.sym(c, icon, .{ .size = 16, .color = color });
    r.end();
}

/// A note of an empty state: wrapped to the width it had, each line centered.
pub fn centered(c: *ui.Context, text: []const u8) void {
    const box = ui.div(c).column().wFull().itemsCenter().gap(2);
    defer box.end();
    const style: ui.TextStyle = .{ .size = 12, .color = c.theme.muted };
    const width = if (c.rects.get(box.interaction().id)) |r| r.w else 240;
    var start: usize = 0;
    var end: usize = 0;
    var it = std.mem.tokenizeScalar(u8, text, ' ');
    while (it.next()) |word| {
        const w_end = @intFromPtr(word.ptr) - @intFromPtr(text.ptr) + word.len;
        if (end > start and c.text.width(text[start..w_end], style) > width) {
            ui.text(c, text[start..end], style);
            start = @intFromPtr(word.ptr) - @intFromPtr(text.ptr);
        }
        end = w_end;
    }
    if (end > start) ui.text(c, text[start..end], style);
}

fn withIcon(o: ui.ButtonOptions, icon: []const u8) ui.ButtonOptions {
    var r = o;
    r.icon = icon;
    return r;
}

fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}
