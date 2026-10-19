//! Source control: the work tree's changes, grouped as merge changes, staged
//! changes, changes and untracked files, with stage, unstage, discard and
//! commit.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const git = @import("git.zig");
const icons = @import("icons.zig");
const statusColor = @import("explorer.zig").statusColor;

const Group = enum { merge, staged, changes, untracked };

const Action = enum { none, open, stage, unstage, discard };

pub const Scm = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    window: ?*myzig.Window = null,
    /// The work tree's top folder, or null outside one.
    top: ?[]u8 = null,
    changes: []git.Change = &.{},
    buf: []u8 = &.{},
    message: ui.TextBuffer = .{},
    open: [4]bool = .{ true, true, true, true },
    /// Set after a commit, for the workbench's toast.
    committed: bool = false,
    err: ?[]u8 = null,
    discard_alert: ui.OverlayState = .{},
    discard_path: ?[]u8 = null,
    commit_all_alert: ui.OverlayState = .{},

    pub fn deinit(s: *Scm) void {
        s.clear();
        if (s.top) |t| s.gpa.free(t);
        if (s.err) |e| s.gpa.free(e);
        if (s.discard_path) |p| s.gpa.free(p);
    }

    fn clear(s: *Scm) void {
        if (s.changes.len > 0) s.gpa.free(s.changes);
        if (s.buf.len > 0) s.gpa.free(s.buf);
        s.changes = &.{};
        s.buf = &.{};
    }

    pub fn refresh(s: *Scm) void {
        if (s.top == null) s.top = git.topLevel(s.gpa, s.io, s.root);
        const top = s.top orelse return;
        s.clear();
        var buf: []u8 = &.{};
        s.changes = git.status(s.gpa, s.io, top, &buf) catch &.{};
        s.buf = buf;
    }

    fn setError(s: *Scm, r: git.Result) void {
        if (s.err) |e| s.gpa.free(e);
        s.err = s.gpa.dupe(u8, std.mem.trim(u8, if (r.stderr.len > 0) r.stderr else r.stdout, " \r\n")) catch null;
    }

    /// Runs git in the work tree, keeping its error to show; then refreshes.
    fn git_(s: *Scm, args: []const []const u8) bool {
        const top = s.top orelse return false;
        const r = git.run(s.gpa, s.io, top, args) catch return false;
        defer r.deinit(s.gpa);
        if (!r.ok) s.setError(r) else if (s.err) |e| {
            s.gpa.free(e);
            s.err = null;
        }
        s.refresh();
        return r.ok;
    }

    fn groupOf(ch: git.Change, g: Group) bool {
        return switch (g) {
            .merge => ch.status() == .conflict,
            .staged => ch.staged(),
            .changes => ch.unstaged(),
            .untracked => ch.status() == .untracked,
        };
    }

    fn count(s: *const Scm, g: Group) usize {
        var n: usize = 0;
        for (s.changes) |ch| if (groupOf(ch, g)) {
            n += 1;
        };
        return n;
    }

    pub fn commit(s: *Scm) void {
        const msg = std.mem.trim(u8, s.message.text(), " \r\n\t");
        if (msg.len == 0) {
            if (s.err) |e| s.gpa.free(e);
            s.err = s.gpa.dupe(u8, "Write a commit message first.") catch null;
            return;
        }
        if (s.count(.staged) == 0) {
            s.commit_all_alert.show();
            return;
        }
        s.commitNow(false);
    }

    fn commitNow(s: *Scm, all: bool) void {
        const msg = std.mem.trim(u8, s.message.text(), " \r\n\t");
        const ok = if (all) s.git_(&.{ "commit", "-a", "-m", msg }) else s.git_(&.{ "commit", "-m", msg });
        if (ok) {
            s.message.clear();
            s.committed = true;
        }
    }

    /// Returns the path (relative to the top) of a change clicked.
    pub fn view(s: *Scm, c: *ui.Context) ?[]const u8 {
        const t = c.theme;
        var picked: ?[]const u8 = null;
        var act: Action = .none;
        var act_path: []const u8 = "";
        if (s.top == null) {
            ui.column(c, .{ .width = .fill, .padding = .all(12), .gap = 10 });
            defer ui.end(c);
            ui.text(c, "The folder isn't in a Git repository.", .{ .size = 12, .color = t.muted, .wrap = true });
            if (ui.button(c, "Initialize Repository", .{ .variant = .primary, .width = .fill, .size = 13 }).clicked) {
                const r = git.run(s.gpa, s.io, s.root, &.{"init"}) catch return null;
                r.deinit(s.gpa);
                s.refresh();
            }
            return null;
        }
        ui.column(c, .{ .width = .fill, .height = .fill });
        defer ui.end(c);
        {
            ui.column(c, .{ .width = .fill, .padding = .xy(10, 6), .gap = 6 });
            defer ui.end(c);
            const r = ui.textField(c, &s.message, .{ .width = .fill, .placeholder = c.print("Message ({s} to commit)", .{ui.keys.label("⌘↵")}), .size = 13 });
            const summary = std.mem.sliceTo(s.message.text(), '\n');
            if (summary.len > 50) ui.text(c, c.print("{d} characters in the summary", .{summary.len}), .{ .size = 11, .color = if (summary.len > 72) t.danger else t.muted });
            const label = if (s.count(.staged) == 0 and s.changes.len > 0) "Commit All" else "Commit";
            if (ui.button(c, label, .{ .variant = .primary, .width = .fill, .size = 13 }).clicked or
                (r.focused and c.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true })) or r.submitted) s.commit();
            if (s.err) |e| ui.text(c, e, .{ .size = 11, .color = t.danger, .wrap = true });
        }
        ui.scroll(c, .{ .width = .fill, .grow = 1 });
        defer ui.end(c);
        if (s.changes.len == 0) {
            ui.column(c, .{ .width = .fill, .padding = .all(12) });
            ui.text(c, "No changes.", .{ .size = 12, .color = t.muted });
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
                if (head.hovered()) {
                    if (g == .staged) {
                        if (rowButton(c, "minus", "Unstage All")) _ = s.git_(&.{ "reset", "-q", "HEAD", "--", "." });
                    } else {
                        if (rowButton(c, "plus", "Stage All")) _ = s.git_(&.{ "add", "-A", "--", "." });
                    }
                }
                if (head.clicked()) s.open[gi] = !s.open[gi];
                head.end();
                if (s.open[gi]) for (s.changes) |ch| if (groupOf(ch, g)) {
                    const a = s.changeRow(c, ch, g);
                    if (a != .none) {
                        act = a;
                        act_path = ch.path;
                    }
                };
            }
        }
        // Act after the rows: git refreshes the changes the rows show.
        switch (act) {
            .none => {},
            .open => picked = c.print("{s}", .{act_path}),
            .stage => _ = s.git_(&.{ "add", "--", c.print("{s}", .{act_path}) }),
            .unstage => _ = s.git_(&.{ "reset", "-q", "HEAD", "--", c.print("{s}", .{act_path}) }),
            .discard => {
                if (s.discard_path) |p| s.gpa.free(p);
                s.discard_path = s.gpa.dupe(u8, act_path) catch null;
                s.discard_alert.show();
            },
        }
        if (act != .none) c.changed = true;
        if (ui.alertDialog(c, &s.discard_alert, "Discard changes?", c.print("{s}\nThis can't be undone.", .{s.discard_path orelse ""}), &.{ "Cancel", "Discard" }) == .chosen) {
            if (s.discard_path) |p| s.discard(p);
        }
        switch (ui.alertDialog(c, &s.commit_all_alert, "Commit all changes?", "Nothing is staged. Stage every change and commit it?", &.{ "Cancel", "Commit All" })) {
            .chosen => |i| if (i == 1) s.commitNow(true),
            else => {},
        }
        return picked;
    }

    fn changeRow(s: *Scm, c: *ui.Context, ch: git.Change, g: Group) Action {
        _ = s;
        const t = c.theme;
        var act: Action = .none;
        ui.keyed(c, .{ @intFromEnum(g), std.hash.Wyhash.hash(0, ch.path) });
        const row = ui.div(c).row().wFull().h(22).pl(22).pr(6).gap(6).itemsCenter().hover(t.surface_hover);
        const name = std.fs.path.basename(ch.path);
        icons.file(c, name);
        const st = ch.status();
        ui.text(c, name, .{ .size = 13, .color = statusColor(t, st) });
        if (std.fs.path.dirname(ch.path)) |d| ui.text(c, d, .{ .size = 11, .color = t.muted });
        ui.spacer(c);
        if (row.hovered()) {
            switch (g) {
                .staged => if (rowButton(c, "minus", "Unstage")) {
                    act = .unstage;
                },
                else => {
                    if (rowButton(c, "arrow.clockwise", "Discard")) act = .discard;
                    if (rowButton(c, "plus", "Stage")) act = .stage;
                },
            }
        }
        const letter: u8 = @intFromEnum(st);
        ui.text(c, c.print("{c}", .{letter}), .{ .size = 11, .mono = true, .color = statusColor(t, st) });
        if (row.clicked() and act == .none) act = .open;
        row.end();
        return act;
    }

    /// Discards a file's changes: an untracked file goes to the Trash.
    fn discard(s: *Scm, rel: []const u8) void {
        const top = s.top orelse return;
        for (s.changes) |ch| if (std.mem.eql(u8, ch.path, rel)) {
            if (ch.status() == .untracked) {
                const abs = @import("explorer.zig").joinNative(s.gpa, top, rel) catch return;
                defer s.gpa.free(abs);
                _ = myzig.shell.trash(abs);
                s.refresh();
            } else _ = s.git_(&.{ "checkout", "-q", "--", rel });
            return;
        };
    }
};

fn rowButton(c: *ui.Context, icon: []const u8, _: []const u8) bool {
    const b = ui.div(c).w(18).h(18).center().rounded(3).hover(c.theme.surface);
    ui.icon(c, icon, .{ .size = 10, .color = c.theme.muted });
    const clicked = b.clicked();
    b.end();
    return clicked;
}
