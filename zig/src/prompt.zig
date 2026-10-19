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
        p.err = null;
        p.focus = 6;
        p.dialog.show();
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
        const d = ui.dialog(c, &p.dialog, .{ .width = .{ .px = if (p.purpose == .review_comment) 520 else 420 } }) orelse {
            if (p.area) |*a| if (!p.dialog.open) {
                a.deinit();
                p.area = null;
            };
            return null;
        };
        defer d.end();
        ui.text(c, p.title[0..p.title_len], .{ .size = 14, .weight = .semibold });
        var answer: ?[]const u8 = null;
        if (p.purpose == .review_comment) {
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
            const r = ui.textField(c, &p.field, .{ .width = .fill });
            if (r.submitted) answer = p.field.text();
        }
        if (p.err) |e| ui.text(c, e, .{ .size = 12, .color = c.theme.danger, .wrap = true });
        ui.row(c, .{ .gap = 8, .justify = .end, .width = .fill });
        if (ui.button(c, "Cancel", .{}).clicked) p.dialog.close();
        if (ui.button(c, "OK", .{ .variant = .primary }).clicked) answer = if (p.area) |*a| a.text(c.alloc()) else p.field.text();
        ui.end(c);
        if (answer) |a| {
            const trimmed = std.mem.trim(u8, a, " \t\r\n");
            if (trimmed.len == 0 and p.purpose != .stash and p.purpose != .stash_untracked) return null;
            p.dialog.close();
            return trimmed;
        }
        return null;
    }
};
