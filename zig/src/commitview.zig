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
    /// When it was made, as "2 hours ago", and how many parents it has.
    ago: []u8 = &.{},
    parents: usize = 1,
    /// Its message's body shows whole rather than its first lines.
    unfolded: bool = false,
    list: DiffList,
    list_height: f32 = 160,

    pub fn create(gpa: std.mem.Allocator, io: std.Io, top: []const u8, rev: []const u8) !*CommitView {
        const cv = try gpa.create(CommitView);
        errdefer gpa.destroy(cv);
        cv.* = .{ .gpa = gpa, .hash = try gpa.dupe(u8, rev), .list = .{ .gpa = gpa, .editable = false } };
        const meta = try git.run(gpa, io, top, &.{ "show", "-s", "--format=%H%x00%an%x00%ad%x00%D%x00%ar%x00%P%x00%B", "--date=format:%b %d, %Y %H:%M", rev });
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
        cv.ago = try gpa.dupe(u8, it.next() orelse "");
        var pit = std.mem.tokenizeScalar(u8, it.next() orelse "", ' ');
        cv.parents = 0;
        while (pit.next()) |_| cv.parents += 1;
        cv.message = try gpa.dupe(u8, std.mem.trim(u8, it.rest(), " \n"));
        // The files, from the first parent (or none, for a root commit).
        const stash = std.mem.indexOf(u8, rev, "stash@") != null;
        var first_parent: [96]u8 = undefined;
        const parent = std.fmt.bufPrint(&first_parent, "{s}^1", .{rev}) catch rev;
        const files = if (stash)
            try git.run(gpa, io, top, &.{ "diff-tree", "-r", "-M", "--name-status", "-z", parent, rev })
        else
            try git.run(gpa, io, top, &.{ "diff-tree", "--no-commit-id", "-r", "-M", "--root", "--name-status", "-z", rev });
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
        for ([_][]u8{ cv.hash, cv.author, cv.date, cv.refs, cv.message, cv.ago }) |s| cv.gpa.free(s);
        cv.gpa.destroy(cv);
    }

    pub fn subject(cv: *const CommitView) []const u8 {
        const s = std.mem.sliceTo(cv.message, '\n');
        return s[0..@min(s.len, 40)];
    }

    /// The card at the top of a commit's diff, as the Go app's: its
    /// subject, who made it and when, its hash, which copies, its branches
    /// and tags, and the rest of its message, folded past its first lines.
    /// True when the hash was copied.
    pub fn header(cv: *CommitView, c: *ui.Context, chrome: ui.Color) bool {
        const t = c.theme;
        var copied = false;
        ui.column(c, .{ .width = .fill, .padding = .xy(16, 12), .gap = 8, .background = chrome });
        defer ui.end(c);
        const subj = std.mem.sliceTo(cv.message, '\n');
        ui.text(c, subj, .{ .size = 14, .weight = .semibold, .wrap = true });
        {
            const meta = ui.div(c).row().wFull().gap(6).itemsCenter();
            defer meta.end();
            // The author's initials in a circle, then the name.
            const av = ui.div(c).w(18).h(18).roundedFull().center().bg(t.accent.alpha(0.22));
            ui.text(c, initials(c, cv.author), .{ .size = 8.5, .weight = .semibold, .color = t.accent });
            av.end();
            ui.text(c, cv.author, .{ .size = 12, .weight = .semibold });
            if (cv.ago.len > 0) ui.text(c, c.print("committed {s} · {s}", .{ cv.ago, cv.date }), .{ .size = 12, .color = t.muted });
            ui.text(c, "·", .{ .size = 12, .color = t.muted.alpha(0.6) });
            if (cv.hash.len >= 7 and std.mem.indexOfScalar(u8, cv.hash, '@') == null) {
                const hb = ui.div(c).h(18).px(6).center().rounded(5);
                _ = hb.bg(t.accent.alpha(if (hb.hovered()) 0.2 else 0.1));
                ui.text(c, cv.hash[0..7], .{ .size = 11, .mono = true, .color = t.accent });
                const hi = hb.interaction();
                hb.end();
                ui.tooltip(c, hi, "Copy Commit Hash");
                if (hi.clicked) {
                    _ = myzig.clipboard.writeText(cv.hash);
                    copied = true;
                }
            } else ui.text(c, cv.hash, .{ .size = 11, .mono = true, .color = t.accent });
            var refs = std.mem.tokenizeSequence(u8, cv.refs, ", ");
            while (refs.next()) |r0| {
                // The branch checked out, in bold, without "HEAD -> ".
                const head = std.mem.startsWith(u8, r0, "HEAD");
                const r = if (std.mem.startsWith(u8, r0, "HEAD -> ")) r0[8..] else r0;
                const tag = std.mem.startsWith(u8, r, "tag: ");
                const remote = std.mem.indexOfScalar(u8, r, '/') != null and !std.mem.startsWith(u8, r, "HEAD");
                const rb = ui.div(c).h(18).px(6).center().rounded(5).bg(if (tag) t.surface_hover else t.accent.alpha(if (remote) 0.07 else 0.14));
                ui.text(c, if (tag) c.print("◆ {s}", .{r[5..]}) else r, .{ .size = 11, .weight = if (head) .bold else .medium, .color = if (tag) t.text else if (remote) t.accent.mix(t.muted, 0.4) else t.accent });
                rb.end();
            }
            if (cv.parents > 1) ui.text(c, c.print("· merge of {d} parents", .{cv.parents}), .{ .size = 12, .color = t.muted });
            const n = cv.list.entries.items.len;
            ui.text(c, c.print("· {d} file{s} changed", .{ n, if (n == 1) "" else "s" }), .{ .size = 12, .color = t.muted });
        }
        // The rest of the message, folded past six lines.
        const body = std.mem.trim(u8, cv.message[subj.len..], " \r\n");
        if (body.len > 0) {
            var lines: usize = 0;
            var end: usize = body.len;
            for (body, 0..) |ch, i| if (ch == '\n') {
                lines += 1;
                if (lines == 6 and end == body.len) end = i;
            };
            const folds = end < body.len;
            ui.text(c, if (folds and !cv.unfolded) body[0..end] else body, .{ .size = 12, .mono = true, .color = t.muted, .wrap = true });
            if (folds) {
                const more = ui.div(c).row().h(20).px(4).itemsCenter().rounded(4).hover(t.surface_hover);
                ui.text(c, if (cv.unfolded) "Show Less" else "Show More", .{ .size = 11.5, .color = t.accent });
                if (more.clicked()) cv.unfolded = !cv.unfolded;
                more.end();
            }
        }
        return copied;
    }

    fn initials(c: *ui.Context, name: []const u8) []const u8 {
        var out: std.ArrayList(u8) = .empty;
        var it = std.mem.tokenizeAny(u8, name, " .-_");
        while (it.next()) |w| {
            if (out.items.len == 2) break;
            out.append(c.alloc(), std.ascii.toUpper(w[0])) catch {};
        }
        return out.items;
    }
};
