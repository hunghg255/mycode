//! Runs a command in a project: the menu bar's, the palette's, the keys'.
//! The window's own (themes, projects, settings) go to the shell.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const fs = @import("fs.zig");
const Cmd = @import("commands.zig").Cmd;
const Workbench = @import("workbench.zig").Workbench;
const editing = @import("editing.zig");
const viewer = @import("viewer.zig");
const wbgit = @import("wb_git.zig");
const wbfiles = @import("wb_files.zig");

pub fn run(wb: *Workbench, c: *ui.Context, cmd: Cmd) void {
    c.changed = true;
    // Zoom zooms the picture shown, else the text.
    if (cmd == .zoom_in or cmd == .zoom_out or cmd == .zoom_reset) if (wb.editors.current()) |it| if (it.body == .image) {
        it.body.image.zoomStep(switch (cmd) {
            .zoom_in => 1,
            .zoom_out => -1,
            else => 0,
        });
        return;
    };
    if (wb.shell.run(c, cmd)) return;
    const ed = &wb.editors;
    const doc = ed.currentDoc();
    const gpa = wb.gpa;
    switch (cmd) {
        .new_file => ed.newUntitled() catch {},
        .save => if (doc) |d| {
            if (d.path.len == 0) wbfiles.saveAs(wb, d) else d.save() catch |err| wb.toastError("Couldn't save", @errorName(err));
            wbfiles.afterSave(wb, d);
        },
        .save_as => if (doc) |d| wbfiles.saveAs(wb, d),
        .save_all => {
            ed.saveAll();
            wb.refreshGit();
        },
        .toggle_auto_save => wb.shell.store.setBool("autoSave", !wb.shell.store.s.autoSave),
        .close_tab => if (ed.currentLoc()) |l| ed.close(l) else if (!ed.closeColumnIfEmpty()) wb.shell.closeProject(wb),
        .close_all_tabs => {
            var ci = ed.cols.items.len;
            while (ci > 0) {
                ci -= 1;
                if (ci < ed.cols.items.len) ed.closeWhere(ci, null, .all);
            }
        },
        .reopen_tab => ed.reopenClosed(),
        .close_project, .close_folder => wb.shell.closeProject(wb),
        .clear_recent => {
            wb.shell.state.clearRecent();
            wb.shell.state.save();
        },
        .undo => if (doc) |d| d.editor.area.undo(),
        .redo => if (doc) |d| d.editor.area.redo(),
        .find_next, .find_prev => if (doc) |d| d.editor.findNext(cmd == .find_prev),
        .select_line => if (doc) |d| editing.selectLines(&d.editor.area),
        .toggle_comment => if (doc) |d| d.editor.toggleComment(),
        .indent_lines, .outdent_lines => if (doc) |d| d.editor.indentLines(cmd == .outdent_lines),
        .go_to_bracket => if (doc) |d| d.editor.goToBracket(),
        .toggle_word_wrap => wb.shell.store.setBool("wordWrap", !wb.shell.store.s.wordWrap),
        .terminal_tab => wbfiles.newTerminalIn(wb, ed.focus, null, wb.root),
        .terminal_move => wbfiles.moveTerminal(wb),
        .kill_terminal => wbfiles.killTerminal(wb),
        .prev_column => {
            ed.focus = (ed.focus + ed.cols.items.len - 1) % ed.cols.items.len;
            ed.switched = true;
        },
        .move_tab_next, .move_tab_prev => if (ed.currentLoc()) |l| {
            const next = cmd == .move_tab_next;
            if (next and l.col + 1 < ed.cols.items.len) {
                ed.move(l, l.col + 1, null);
            } else if (!next and l.col > 0) {
                ed.move(l, l.col - 1, null);
            } else if (ed.cols.items[l.col].items.items.len > 1) {
                // A new column on that side.
                const ni = ed.addColumn(if (next) l.col + 1 else l.col) catch return;
                const from: @TypeOf(l) = .{ .col = if (ni <= l.col) l.col + 1 else l.col, .idx = l.idx };
                ed.move(from, ni, 0);
            }
        },
        .open_all_changes => wbgit.openChangesTab(wb, null, true),
        .show_change => if (doc) |d| {
            d.updateMarks(wb.scm.top);
            const line = d.editor.area.caretLine();
            if (line < d.marks.items.len and d.marks.items[line] != .none) d.peek = line;
        },
        .find => if (doc) |d| d.editor.openFind(false),
        .replace => if (doc) |d| d.editor.openFind(true),
        .find_in_files, .replace_in_files, .show_search => {
            wb.sidebar_open = true;
            wb.side = .search;
            const sel = if (doc) |d| d.editor.area.selectedText(c.alloc()) else "";
            wb.search.focus(sel);
            if (cmd == .replace_in_files) wb.search.show_replace = true;
        },
        .move_line_up, .move_line_down => if (doc) |d| editing.moveLines(&d.editor.area, gpa, cmd == .move_line_up),
        .copy_line_up, .copy_line_down => if (doc) |d| editing.copyLines(&d.editor.area, gpa, cmd == .copy_line_up),
        .delete_line => if (doc) |d| editing.deleteLines(&d.editor.area),
        .insert_line_below, .insert_line_above => if (doc) |d| editing.insertLine(&d.editor.area, gpa, cmd == .insert_line_above),
        .sort_lines_asc, .sort_lines_desc => if (doc) |d| editing.sortLines(&d.editor.area, gpa, cmd == .sort_lines_desc),
        .upper_case => if (doc) |d| editing.changeCase(&d.editor.area, gpa, .upper),
        .lower_case => if (doc) |d| editing.changeCase(&d.editor.area, gpa, .lower),
        .camel_case => if (doc) |d| editing.changeCase(&d.editor.area, gpa, .camel),
        .snake_case => if (doc) |d| editing.changeCase(&d.editor.area, gpa, .snake),
        .trim_whitespace => if (doc) |d| editing.trimTrailingWhitespace(&d.editor.area, gpa),
        .command_palette => wb.quick.show(">"),
        .quick_open => wb.quick.show(""),
        .go_to_line => wb.quick.show(":"),
        .go_to_symbol => wb.quick.show("@"),
        .toggle_sidebar => wb.sidebar_open = !wb.sidebar_open,
        .show_explorer => {
            if (wb.sidebar_open and wb.side == .explorer) wb.sidebar_open = false else {
                wb.sidebar_open = true;
                wb.side = .explorer;
            }
        },
        .show_scm => {
            if (wb.sidebar_open and wb.side == .scm) wb.sidebar_open = false else {
                wb.sidebar_open = true;
                wb.side = .scm;
                wb.refreshGit();
            }
        },
        .toggle_terminal => {
            if (wb.panel.open) {
                wb.panel.open = false;
            } else if (wb.panel.terms.items.len == 0) {
                wbfiles.newTerminal(wb, null);
            } else {
                wb.panel.open = true;
                if (wb.panel.current()) |t| t.focus = true;
            }
        },
        .new_terminal => wbfiles.newTerminal(wb, null),
        .maximize_panel => {
            wb.panel.open = true;
            wb.panel.maximized = !wb.panel.maximized;
        },
        .next_terminal => wb.panel.cycle(true),
        .prev_terminal => wb.panel.cycle(false),
        .toggle_wrap => if (doc) |d| {
            d.own_wrap = !(d.own_wrap orelse wb.shell.store.s.wordWrap);
        } else if (ed.current()) |it| switch (it.body) {
            // A diff's lines wrap, in this tab.
            .changes => |ch| ch.list.wrap = !(ch.list.wrap orelse wb.shell.store.s.wordWrap),
            .commit => |cv| cv.list.wrap = !(cv.list.wrap orelse wb.shell.store.s.wordWrap),
            else => {},
        },
        .toggle_preview => if (doc) |d| if (viewer.isMarkdown(d.path) or viewer.isSvg(d.path)) {
            d.rendered = !d.rendered;
            // A file in two columns: this tab's alone.
            if (ed.current()) |it| if (it.rendered != null) {
                it.rendered = d.rendered;
            };
        },
        .split_right => if (ed.currentLoc()) |l| ed.splitRight(l),
        .toggle_column_lock => ed.focusCol().locked = !ed.focusCol().locked,
        .move_terminal_to_column => wbfiles.terminalToLockedColumn(wb),
        .next_tab => {
            const col = ed.focusCol();
            if (col.items.items.len > 0) ed.show(.{ .col = ed.focus, .idx = (col.active + 1) % col.items.items.len });
        },
        .prev_tab => {
            const col = ed.focusCol();
            const n = col.items.items.len;
            if (n > 0) ed.show(.{ .col = ed.focus, .idx = (col.active + n - 1) % n });
        },
        .next_column => {
            ed.focus = (ed.focus + 1) % ed.cols.items.len;
            ed.switched = true;
        },
        .next_change, .prev_change => if (doc) |d| {
            d.updateMarks(wb.scm.top);
            if (d.nextChange(cmd == .next_change)) |line| d.editor.goToLine(line + 1);
        },
        .stage_change, .revert_change => wbgit.hunkAtCaret(wb, cmd == .stage_change),
        .open_changes => wbgit.openChangesTab(wb, if (doc) |d| d.path else null, true),
        .accept_current, .accept_incoming, .accept_both => wbgit.acceptConflict(wb, switch (cmd) {
            .accept_current => .current,
            .accept_incoming => .incoming,
            else => .both,
        }, false),
        .accept_all_current => wbgit.acceptConflict(wb, .current, true),
        .accept_all_incoming => wbgit.acceptConflict(wb, .incoming, true),
        .next_conflict, .prev_conflict => if (doc) |d| {
            d.updateConflicts();
            const line = d.editor.area.caretLine();
            var target: ?usize = null;
            if (cmd == .next_conflict) {
                for (d.blocks) |b| if (b.start > line) {
                    target = b.start;
                    break;
                };
                if (target == null and d.blocks.len > 0) target = d.blocks[0].start;
            } else {
                var i = d.blocks.len;
                while (i > 0) {
                    i -= 1;
                    if (d.blocks[i].start < line) {
                        target = d.blocks[i].start;
                        break;
                    }
                }
                if (target == null and d.blocks.len > 0) target = d.blocks[d.blocks.len - 1].start;
            }
            if (target) |tl| d.editor.goToLine(tl + 1);
        },
        .add_review_comment => if (doc) |d| wbfiles.askComment(wb, d),
        .copy_review => {
            const text = wb.review.format(gpa) catch return;
            defer gpa.free(text);
            _ = myzig.clipboard.writeText(text);
            _ = wb.toasts.show("Review comments copied");
        },
        .send_review => {
            if (wb.review.list.items.len == 0) return;
            const text = wb.review.format(gpa) catch return;
            defer gpa.free(text);
            wbfiles.sendToTerminal(wb, text);
            wb.review.clear();
        },
        .clear_review => wb.review.clear(),
        .refresh_explorer => wb.explorer.refresh(),
        .collapse_folders => wb.explorer.collapseAll(),
        .reveal_active => if (ed.current()) |it| if (it.path()) |p| {
            wb.sidebar_open = true;
            wb.side = .explorer;
            wb.explorer.reveal(p);
        },
        .copy_path => if (ed.current()) |it| if (it.path()) |p| {
            _ = myzig.clipboard.writeText(p);
        },
        .copy_relative_path => if (ed.current()) |it| if (it.path()) |p| {
            const rel = c.print("{s}", .{fs.relative(wb.root, p)});
            std.mem.replaceScalar(u8, @constCast(rel), '\\', '/');
            _ = myzig.clipboard.writeText(rel);
        },
        .reveal_in_os => if (ed.current()) |it| if (it.path()) |p| myzig.shell.showInFolder(p),
        .indent_tabs => if (doc) |d| {
            d.editor.indent.unit = "\t";
        },
        .indent_spaces_2 => if (doc) |d| {
            d.editor.indent.unit = "  ";
        },
        .indent_spaces_4 => if (doc) |d| {
            d.editor.indent.unit = "    ";
        },
        .indent_spaces_8 => if (doc) |d| {
            d.editor.indent.unit = "        ";
        },
        else => wbgit.run(wb, c, cmd),
    }
}
