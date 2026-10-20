//! The status bar, as the Go app's: the branch with its menu, what Git is
//! doing, the folder, review comments, the blame; then, for the tab shown,
//! a file's caret, lines, indentation, encoding, line endings and language,
//! a picture's size and zoom, a diff's summary, or a terminal's folder and
//! size in cells.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const Workbench = @import("workbench.zig").Workbench;
const Doc = @import("doc.zig").Doc;
const DiffList = @import("difflist.zig").DiffList;
const gitops = @import("gitops.zig");
const icons = @import("icons.zig");
const editing = @import("editing.zig");
const commands = @import("commands.zig");
const Cmd = commands.Cmd;
const run_mod = @import("wb_run.zig");
const wbeditor = @import("wb_editor.zig");

/// A part of the bar: a button when `tip` is given (its tooltip), else
/// text; true when clicked.
fn item(c: *ui.Context, icon: ?[]const u8, label: []const u8, tip: ?[]const u8) bool {
    const t = c.theme;
    const it = ui.div(c).row().h(20).px(5).gap(5).itemsCenter().rounded(3);
    if (tip != null) _ = it.hover(t.surface_hover);
    if (icon) |n| icons.sym(c, n, .{ .size = 10.5, .color = t.muted });
    ui.text(c, label, .{ .size = 12, .color = t.muted });
    const ii = it.interaction();
    it.end();
    const tt = tip orelse return false;
    if (tt.len > 0) ui.tooltip(c, ii, tt);
    return ii.clicked;
}

/// A part of the bar that opens a menu: its interaction.
fn menuItem(c: *ui.Context, label: []const u8, tip: []const u8) ui.Interaction {
    const it = ui.div(c).row().h(20).px(5).itemsCenter().rounded(3).hover(c.theme.surface_hover);
    ui.text(c, label, .{ .size = 12, .color = c.theme.muted });
    const ii = it.interaction();
    it.end();
    ui.tooltip(c, ii, tip);
    return ii;
}

/// What the status bar says Git is doing, as the Go app's `gitDo` names it.
pub fn busyText(c: *ui.Context, kind: gitops.Kind, subject: []const u8) []const u8 {
    return switch (kind) {
        .fetch => "Fetching…",
        .pull, .pull_rebase, .pull_merge => "Pulling…",
        .push, .publish => "Pushing…",
        .force_push => "Force pushing…",
        .sync => "Syncing…",
        .checkout => c.print("Switching to {s}…", .{subject}),
        .create_branch => c.print("Creating {s}…", .{subject}),
        .rename_branch => c.print("Renaming {s}…", .{subject}),
        .delete_branch, .delete_remote_branch => c.print("Deleting {s}…", .{subject}),
        .tag => "Tagging…",
        .stash => "Stashing…",
        .stash_apply, .stash_pop => c.print("Restoring {s}…", .{subject}),
        .stash_drop => c.print("Dropping {s}…", .{subject}),
        .undo_commit => "Undoing the last commit…",
        .commit, .commit_amend => "Committing…",
        .continue_op => "Continuing…",
        .abort_op => "Aborting…",
        .merge => "Merging…",
        .rebase => "Rebasing…",
        .reset => "Resetting…",
        .revert => "Reverting…",
        .cherry_pick => "Cherry-picking…",
        .other => "Running Git…",
    };
}

/// A diff's summary, as the Go app's `diffStatus`: its files, changes
/// and lines added and removed.
fn diffSummary(c: *ui.Context, dl: *const DiffList) ?[]const u8 {
    var files: usize = 0;
    var hunk_n: usize = 0;
    var add: usize = 0;
    var del: usize = 0;
    var all = true;
    for (dl.entries.items, 0..) |e, i| {
        // A file both staged and changed counts once.
        const seen = for (dl.entries.items[0..i]) |o| {
            if (std.mem.eql(u8, o.path, e.path)) break true;
        } else false;
        if (!seen) files += 1;
        if (!e.loaded) {
            all = false;
            continue;
        }
        add += e.added;
        del += e.deleted;
        if (e.dv) |d| hunk_n += d.hunks.len;
    }
    if (files == 0) return null;
    const f = c.print("{d} file{s}", .{ files, if (files == 1) "" else "s" });
    if (!all) return f;
    if (hunk_n == 0) return c.print("{s} · no changes in the text", .{f});
    return c.print("{s} · {d} change{s} · +{d} −{d}", .{ f, hunk_n, if (hunk_n == 1) "" else "s", add, del });
}

/// A tooltip naming a command's key, as "Go to Line (Ctrl+G)".
fn withKey(wb: *Workbench, c: *ui.Context, label: []const u8, cmd: Cmd) []const u8 {
    const k = @import("shell.zig").Shell.keyLabel(wb.shell, c, cmd);
    return if (k.len == 0) label else c.print("{s} ({s})", .{ label, k });
}

fn sizeText(c: *ui.Context, n: usize) []const u8 {
    const f: f64 = @floatFromInt(n);
    if (n < 1000) return c.print("{d} B", .{n});
    if (n < 1000 * 1000) return c.print("{d:.1} KB", .{f / 1000});
    return c.print("{d:.1} MB", .{f / 1000 / 1000});
}

pub fn view(wb: *Workbench, c: *ui.Context) void {
    const t = c.theme;
    const p = wb.shell.palette;
    const bar = ui.div(c).row().wFull().h(24).px(6).gap(4).itemsCenter().bg(.hex(p.chrome));
    defer bar.end();
    if (!wb.shell.store.s.projectTabs) wb.shell.manageButton(c, wb);
    wb.shell.mascot(c, 16);
    if (wb.scm.branch) |b| {
        const br = ui.div(c).row().h(20).px(5).gap(4).itemsCenter().rounded(3).hover(t.surface_hover);
        icons.sym(c, "arrow.triangle.branch", .{ .size = 11, .color = t.muted });
        ui.text(c, b, .{ .size = 12, .color = t.muted });
        if (wb.scm.ab.ahead > 0) ui.text(c, c.print("↑{d}", .{wb.scm.ab.ahead}), .{ .size = 11, .color = t.muted });
        if (wb.scm.ab.behind > 0) ui.text(c, c.print("↓{d}", .{wb.scm.ab.behind}), .{ .size = 11, .color = t.muted });
        const bi = br.interaction();
        br.end();
        ui.tooltip(c, bi, c.print("Branch {s}: switch, fetch, pull or push", .{b}));
        if (ui.buttonMenu(c, &wb.status_menu, bi)) |m| {
            defer m.end();
            const items = [_]Cmd{ .git_switch_branch, .git_create_branch, .git_rename_branch, .git_delete_branch, .git_fetch, .git_pull, .git_push, .git_sync };
            for (items, 0..) |cmd, k| {
                if (k == 4) m.separator();
                if (m.item(commands.info(cmd).title, .{})) run_mod.run(wb, c, cmd);
            }
        }
    }
    if (wb.runner.busy) {
        const busy = ui.div(c).row().h(20).px(5).gap(5).itemsCenter();
        // Under a theme with a character, it hops instead.
        const th = wb.shell.store.s.theme;
        if (!std.mem.eql(u8, th, "claude") and !std.mem.eql(u8, th, "qoder")) ui.spinner(c, .{ .size = 11 });
        ui.text(c, busyText(c, wb.runner.now, wb.runner.nowSubject()), .{ .size = 12, .color = t.muted });
        busy.end();
    }
    if (wb.shell.keymap.chord_len > 0)
        _ = item(c, "keyboard", c.print("({s}) was pressed. Waiting for the next key…", .{wb.shell.keymap.chordText(c)}), null);
    if (item(c, "folder", wb.name(), c.print("Reveal {s} in File Explorer", .{wb.root}))) myzig.shell.showInFolder(wb.root);
    wbeditor.reviewStatus(wb, c);
    const doc = wb.editors.currentDoc();
    if (doc) |d| wbeditor.blame(wb, c, d);
    ui.spacer(c);
    const cur = wb.editors.current() orelse return;
    switch (cur.body) {
        .file => |d| fileStatus(wb, c, d),
        .image => |im| {
            if (im.w > 0) {
                _ = item(c, null, c.print("{d} × {d}", .{ @as(u32, @intFromFloat(@round(im.w))), @as(u32, @intFromFloat(@round(im.h))) }), null);
                if (im.bytes.len > 0) _ = item(c, null, sizeText(c, im.bytes.len), null);
                if (item(c, null, c.print("{d}%", .{@as(u32, @intFromFloat(@round(im.currentScale() * 100)))}), "Fit to the View")) im.zoomStep(0);
            }
        },
        .changes => |ch| if (diffSummary(c, &ch.list)) |s| {
            _ = item(c, "diff", s, null);
        },
        .commit => |cv| if (diffSummary(c, &cv.list)) |s| {
            _ = item(c, "diff", s, null);
        },
        .terminal => |term| {
            _ = item(c, "terminal", term.dir, null);
            const size = term.t.size;
            if (size[0] > 0) _ = item(c, null, c.print("{d} × {d}", .{ size[0], size[1] }), null);
        },
    }
}

fn gone(c: *ui.Context) void {
    const g = ui.div(c).row().h(20).px(6).gap(5).itemsCenter();
    icons.sym(c, "trash", .{ .size = 9.5, .color = c.theme.danger });
    ui.text(c, "Deleted on disk", .{ .size = 12, .color = c.theme.danger });
    g.end();
}

fn fileStatus(wb: *Workbench, c: *ui.Context, d: *Doc) void {
    if (d.disk_gone) gone(c);
    const ta = &d.editor.area;
    const line = ta.caretLine();
    const col = ta.sel.caret - ta.doc.lineStart(line);
    const sel_n = ta.sel.hi() - ta.sel.lo();
    const pos = if (sel_n > 0) c.print("Ln {d}, Col {d} ({d} selected)", .{ line + 1, col + 1, sel_n }) else c.print("Ln {d}, Col {d}", .{ line + 1, col + 1 });
    if (item(c, null, pos, withKey(wb, c, "Go to Line", .go_to_line))) run_mod.run(wb, c, .go_to_line);
    const lines = ta.doc.lineCount();
    _ = item(c, null, c.print("{d} line{s}", .{ lines, if (lines == 1) "" else "s" }), null);
    // Indentation: the style, and converting the file's to tabs or spaces.
    const unit = d.editor.indent.unit;
    const tabs = std.mem.eql(u8, unit, "\t");
    const ii = menuItem(c, if (tabs) "Tab Size: 4" else c.print("Spaces: {d}", .{unit.len}), "Indentation");
    if (ui.buttonMenu(c, &wb.indent_menu, ii)) |m| {
        defer m.end();
        if (m.item("Indent Using Tabs", .{ .checked = tabs })) run_mod.run(wb, c, .indent_tabs);
        const sizes = [_]struct { usize, Cmd }{ .{ 2, .indent_spaces_2 }, .{ 4, .indent_spaces_4 }, .{ 8, .indent_spaces_8 } };
        for (sizes) |sz| if (m.item(commands.info(sz[1]).title, .{ .checked = !tabs and unit.len == sz[0] })) run_mod.run(wb, c, sz[1]);
        m.separator();
        if (m.item("Convert Indentation to Tabs", .{})) {
            editing.reindent(ta, wb.gpa, unit, "\t");
            run_mod.run(wb, c, .indent_tabs);
        }
        if (m.item("Convert Indentation to Spaces", .{})) {
            const to = if (tabs) "    " else unit;
            editing.reindent(ta, wb.gpa, unit, to);
            run_mod.run(wb, c, if (to.len == 2) .indent_spaces_2 else if (to.len == 8) .indent_spaces_8 else .indent_spaces_4);
        }
    }
    _ = item(c, null, "UTF-8", null);
    const ei = menuItem(c, if (d.crlf) "CRLF" else "LF", "Line Endings");
    if (ui.buttonMenu(c, &wb.eol_menu, ei)) |m| {
        defer m.end();
        for ([_]bool{ false, true }) |crlf| if (m.item(if (crlf) "CRLF" else "LF", .{ .checked = d.crlf == crlf }) and d.crlf != crlf) {
            d.crlf = crlf;
            d.saved +%= 1; // the line endings changed: save writes them
        };
    }
    _ = item(c, null, icons.languageName(d.name()), null);
}
