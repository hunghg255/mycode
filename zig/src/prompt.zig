//! A box that asks for a line of text (a name, a message) or for a choice,
//! over the window; the workbench says what the answer is for.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;

pub const Purpose = enum {
    new_file,
    new_folder,
    rename,
    stash,
    stash_untracked,
    stash_files,
    new_branch,
    new_branch_at,
    rename_branch,
    new_tag,
    review_comment,
    diff_comment,
    commit_message,
};

pub const Prompt = struct {
    dialog: ui.OverlayState = .{},
    field: ui.TextBuffer = .{},
    /// A comment's text: several lines.
    area: ?ui.TextArea = null,
    purpose: Purpose = .new_file,
    title: [128]u8 = undefined,
    title_len: usize = 0,
    /// What the answer acts on: a folder, a path, a commit.
    target: [std.fs.max_path_bytes]u8 = undefined,
    target_len: usize = 0,
    /// Builds left in which the field takes the keyboard: the dialog
    /// clears the focus as it opens.
    focus: u8 = 0,
    err: ?[]const u8 = null,
    /// Beside the title, faint: where a new file goes, the branch a new
    /// one starts from.
    hint_buf: [256]u8 = undefined,
    hint_len: usize = 0,
    /// The disk, to say before closing that a name is taken.
    io: ?std.Io = null,

    pub fn deinit(p: *Prompt) void {
        if (p.area) |*a| a.deinit();
    }

    pub fn ask(p: *Prompt, purpose: Purpose, title: []const u8, initial: []const u8, target: []const u8) void {
        p.purpose = purpose;
        p.title_len = @min(title.len, p.title.len);
        @memcpy(p.title[0..p.title_len], title[0..p.title_len]);
        p.target_len = @min(target.len, p.target.len);
        @memcpy(p.target[0..p.target_len], target[0..p.target_len]);
        p.field.set(initial);
        // A name chosen without its extension, as File Explorer does.
        if (purpose == .rename) {
            const ext = std.fs.path.extension(initial);
            p.field.select(0, if (ext.len > 0 and ext.len < initial.len) initial.len - ext.len else initial.len);
        }
        p.err = null;
        p.hint_len = 0;
        p.focus = 6;
        p.dialog.show();
    }

    /// Sets the text beside the title.
    pub fn hint(p: *Prompt, text: []const u8) void {
        p.hint_len = @min(text.len, p.hint_buf.len);
        @memcpy(p.hint_buf[0..p.hint_len], text[0..p.hint_len]);
    }

    /// Why a name won't do, said in the box rather than after it closes.
    fn check(p: *const Prompt, name: []const u8) ?[]const u8 {
        const optional = p.purpose == .stash or p.purpose == .stash_untracked or p.purpose == .stash_files;
        if (name.len == 0) return if (optional) null else "Enter a name.";
        switch (p.purpose) {
            .new_file, .new_folder, .rename => {
                if (p.purpose == .rename and std.mem.indexOfAny(u8, name, "/\\") != null) return "Enter a name without slashes.";
                const io = p.io orelse return null;
                const dir = if (p.purpose == .rename) std.fs.path.dirname(p.targetPath()) orelse "" else p.targetPath();
                if (p.purpose == .rename and std.mem.eql(u8, std.fs.path.basename(p.targetPath()), name)) return null;
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                const path = std.fmt.bufPrint(&buf, "{s}{c}{s}", .{ dir, std.fs.path.sep, name }) catch return null;
                if (@import("fs.zig").exists(io, path)) return "A file or folder with that name exists.";
            },
            .new_branch, .new_branch_at, .rename_branch, .new_tag => if (std.mem.indexOfAny(u8, name, " ~^:?*[\\") != null) return "A branch or tag's name has no spaces, nor ~ ^ : ? * [ \\.",
            else => {},
        }
        return null;
    }

    pub fn askText(p: *Prompt, gpa: std.mem.Allocator, purpose: Purpose, title: []const u8, initial: []const u8, target: []const u8) void {
        p.ask(purpose, title, "", target);
        if (p.area) |*a| a.deinit();
        p.area = ui.TextArea.init(gpa, initial);
    }

    pub fn targetPath(p: *const Prompt) []const u8 {
        return p.target[0..p.target_len];
    }

    /// The answer, in the frame it is given; null otherwise.
    pub fn view(p: *Prompt, c: *ui.Context) ?[]const u8 {
        const d = ui.dialog(c, &p.dialog, .{ .width = .{ .px = if (p.area != null) 520 else 420 } }) orelse {
            if (p.area) |*a| if (!p.dialog.open) {
                a.deinit();
                p.area = null;
            };
            return null;
        };
        defer d.end();
        // Under the title bar, as the Go app's.
        d.backdropStyle().justify = .start;
        d.backdropStyle().padding.top = c.title_bar_height + 8;
        d.panelStyle().radius = 10;
        d.panelStyle().padding = .{ .top = 14, .right = 16, .bottom = 14, .left = 16 };
        d.panelStyle().gap = 10;
        const t = c.theme;
        const title = p.title[0..p.title_len];
        {
            const head = ui.div(c).row().wFull().gap(8).itemsCenter();
            ui.text(c, title, .{ .size = 13, .weight = .semibold });
            const h = ui.div(c).grow().w(0).clip();
            ui.text(c, p.hint_buf[0..p.hint_len], .{ .size = 12, .color = t.muted.alpha(0.7) });
            h.end();
            head.end();
        }
        var answer: ?[]const u8 = null;
        if (p.purpose == .review_comment or p.purpose == .diff_comment) {
            const a = &(p.area.?);
            const id = c.peekId(null);
            if (p.focus > 0) {
                if (c.focus != id) c.changed = true;
                c.focus = id;
                p.focus -= 1;
            }
            _ = ui.textArea(c, a, .{ .height = .{ .px = 140 }, .placeholder = "A comment on these lines" });
            if (c.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true })) answer = a.text(c.alloc());
        } else {
            const id = c.peekId(null);
            if (p.focus > 0) {
                if (c.focus != id) c.changed = true;
                c.focus = id;
                p.focus -= 1;
            }
            const r = ui.textField(c, &p.field, .{ .width = .fill, .size = 13, .label = title });
            if (r.changed) p.err = null;
            if (r.submitted) answer = p.field.text();
        }
        if (p.err) |e| ui.text(c, e, .{ .size = 12, .color = t.danger, .wrap = true });
        const empty = std.mem.trim(u8, if (p.area) |*a| a.text(c.alloc()) else p.field.text(), " \t\r\n").len == 0;
        const optional = p.purpose == .stash or p.purpose == .stash_untracked or p.purpose == .stash_files;
        ui.row(c, .{ .gap = 8, .justify = .end, .width = .fill });
        if (ui.button(c, "Cancel", .{}).clicked) p.dialog.close();
        // Named for what it does, as the title says it.
        const ok = std.mem.trimEnd(u8, std.mem.trimEnd(u8, title, "…"), ".");
        if (ui.button(c, ok, .{ .variant = .primary, .disabled = empty and !optional }).clicked) answer = if (p.area) |*a| a.text(c.alloc()) else p.field.text();
        ui.end(c);
        if (answer) |a| {
            const trimmed = std.mem.trim(u8, a, " \t\r\n");
            if (p.check(trimmed)) |why| {
                p.err = why;
                return null;
            }
            p.dialog.close();
            return trimmed;
        }
        return null;
    }
};
