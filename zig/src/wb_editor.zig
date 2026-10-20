//! What a project shows of its tabs: the columns side by side, each tab's
//! body (an editor, a picture, a diff, a commit, a terminal), the
//! breadcrumbs with the blocks around the caret, the conflict bar, the
//! minimap, the keys the window takes itself, and the status bar.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const fs = @import("fs.zig");
const Workbench = @import("workbench.zig").Workbench;
const columns = @import("columns.zig");
const Doc = @import("doc.zig").Doc;
const viewer = @import("viewer.zig");
const symbols = @import("symbols.zig");
const icons = @import("icons.zig");
const keymap = @import("keymap.zig");
const commands = @import("commands.zig");
const Cmd = commands.Cmd;
const run_mod = @import("wb_run.zig");
const wbgit = @import("wb_git.zig");
const wbfiles = @import("wb_files.zig");
const jobs = @import("jobs.zig");
const themes = @import("themes.zig");
const peek = @import("peek.zig");

/// keybindings.json's keys, then the keys the window takes itself.
pub fn keys(wb: *Workbench, c: *ui.Context) void {
    const sh = wb.shell;
    const doc = wb.editors.currentDoc();
    const cur_id = if (wb.editors.current()) |it| it.area_id else 0;
    const editor_focus = doc != null and cur_id != 0 and c.focus == cur_id;
    const term_focus = terminalFocused(wb);
    // A terminal with the keyboard is offered keys before the menu bar
    // (off macOS): its shell keeps Ctrl+L, Ctrl+W, Ctrl+R.
    c.keys_first = term_focus and !ui.keys.mac;
    const cx: keymap.Context = .{
        .editor_focus = editor_focus,
        .terminal_focus = term_focus,
        .input_focus = c.focused_text != null and !editor_focus and !term_focus,
        .explorer_focus = wb.explorer.focused,
        .sidebar_visible = wb.sidebar_open,
        .terminal_open = wb.panel.open,
        .has_selection = if (doc) |d| d.editor.area.sel.anchor != d.editor.area.sel.caret else false,
    };
    if (sh.keymap.match(c, cx)) |b| {
        // runCommands' steps run in order, each on what the last left.
        for (b.steps) |st| runStep(wb, c, st);
        c.changed = true;
        return;
    }
    const S = ui.Shortcut;
    if (term_focus) return shellSkip(wb, c);
    // Recent folders and the column and tab numbers, anywhere but a field.
    if (!cx.input_focus) {
        if (c.shortcut(.{ .key = 'r', .ctrl = true })) return run_mod.run(wb, c, .open_recent);
        var n: u21 = 1;
        while (n <= 9) : (n += 1) {
            // Ctrl+Alt+N shows the Nth project (⌃⌘N on macOS).
            if (c.shortcut(.{ .key = '0' + n, .cmd = true, .alt = !ui.keys.mac, .ctrl = ui.keys.mac })) {
                wb.shell.show(n - 1);
                c.changed = true;
                return;
            }
            if (c.shortcut(.{ .key = '0' + n, .cmd = true })) {
                const ci = n - 1;
                if (ci < wb.editors.cols.items.len) {
                    wb.editors.focus = ci;
                    wb.editors.switched = true;
                } else if (wb.editors.currentLoc()) |l| wb.editors.splitRight(l);
                c.changed = true;
                return;
            }
            if (c.shortcut(.{ .key = '0' + n, .alt = true })) {
                const col = wb.editors.focusCol();
                if (col.items.items.len > 0) wb.editors.show(.{ .col = wb.editors.focus, .idx = @min(n - 1, col.items.items.len - 1) });
                c.changed = true;
                return;
            }
        }
    }
    if (!editor_focus) return;
    const table = [_]struct { ui.Shortcut, Cmd }{
        .{ .{ .key = S.up, .alt = true }, .move_line_up },
        .{ .{ .key = S.down, .alt = true }, .move_line_down },
        .{ .{ .key = S.up, .alt = true, .shift = true }, .copy_line_up },
        .{ .{ .key = S.down, .alt = true, .shift = true }, .copy_line_down },
        .{ .{ .key = 'k', .cmd = true, .shift = true }, .delete_line },
        .{ .{ .key = S.enter, .cmd = true }, .insert_line_below },
        .{ .{ .key = S.enter, .cmd = true, .shift = true }, .insert_line_above },
        .{ .{ .key = 'z', .alt = true }, .toggle_wrap },
        .{ .{ .key = 'v', .cmd = true, .shift = true }, .toggle_preview },
        .{ .{ .key = 'm', .cmd = true, .shift = true }, .add_review_comment },
        .{ .{ .key = 'o', .cmd = true, .shift = true }, .go_to_symbol },
    };
    for (table) |e| if (c.shortcut(e[0])) return run_mod.run(wb, c, e[1]);
}

/// A step of a binding: a command, text typed or sent, a file opened.
fn runStep(wb: *Workbench, c: *ui.Context, st: keymap.Step) void {
    switch (st.action) {
        .run => if (st.cmd) |cmd| run_mod.run(wb, c, cmd),
        .type_text => if (wb.editors.currentDoc()) |d| d.editor.area.insert(st.text),
        .send_sequence => wbfiles.sendToTerminal(wb, st.text),
        .open => {
            var p = st.text;
            if (std.mem.startsWith(u8, p, "~/") or std.mem.startsWith(u8, p, "~\\")) {
                const home = wb.shell.main.env.get("USERPROFILE") orelse wb.shell.main.env.get("HOME") orelse "";
                p = std.fs.path.join(c.alloc(), &.{ home, p[2..] }) catch return;
            } else if (!std.fs.path.isAbsolute(p)) {
                p = std.fs.path.join(c.alloc(), &.{ wb.root, p }) catch return;
            }
            wbfiles.openPath(wb, p, false);
        },
    }
}

/// A terminal of the panel or of a tab has the keyboard.
fn terminalFocused(wb: *Workbench) bool {
    for (wb.panel.terms.items) |t| if (t.focused()) return true;
    for (wb.editors.cols.items) |col| for (col.items.items) |it| switch (it.body) {
        .terminal => |t| if (t.focused()) return true,
        else => {},
    };
    return false;
}

/// The commands a terminal leaves its keys to, off macOS: the workbench's
/// own (quick open, the palette, tabs, the panel, the sidebar, zoom), any
/// with Ctrl and Shift but Copy and Paste's, any with a function key, and
/// Alt with a digit (a tab). The shell keeps the rest.
fn shellSkip(wb: *Workbench, c: *ui.Context) void {
    if (ui.keys.mac) return;
    const sc = c.input.shortcut orelse return;
    if (sc.alt and !sc.ctrl and !sc.cmd and sc.key >= '1' and sc.key <= '9') {
        const col = wb.editors.focusCol();
        _ = c.shortcut(sc);
        if (col.items.items.len > 0) wb.editors.show(.{ .col = wb.editors.focus, .idx = @min(sc.key - '1', col.items.items.len - 1) });
        c.changed = true;
        return;
    }
    const skips = [_]Cmd{ .quick_open, .command_palette, .next_tab, .prev_tab, .toggle_terminal, .new_terminal, .toggle_sidebar, .zoom_in, .zoom_out, .zoom_reset };
    const ctrl = sc.ctrl or sc.cmd;
    const ctrl_shift = ctrl and sc.shift and sc.key != 'c' and sc.key != 'v';
    const fkey = sc.key >= ui.Shortcut.f1 and sc.key < ui.Shortcut.f1 + 12;
    for (commands.all) |cmd| {
        const accel = commands.info(cmd).accel;
        if (accel.len == 0 or wb.shell.keymap.takesAccel(accel, cmd)) continue;
        const k = keymap.parseKey(accel) orelse continue;
        if (!keymap.sameKey(k, .{ .key = sc.key, .ctrl = sc.ctrl, .cmd = sc.cmd, .alt = sc.alt, .shift = sc.shift })) continue;
        if (std.mem.indexOfScalar(Cmd, &skips, cmd) == null and !ctrl_shift and !fkey) return;
        _ = c.shortcut(sc);
        return run_mod.run(wb, c, cmd);
    }
}

/// The columns side by side, splits nested: each column's width is its own,
/// the last takes the rest.
pub fn columnsView(wb: *Workbench, c: *ui.Context, chrome: ui.Color) void {
    const ed = &wb.editors;
    const n = ed.cols.items.len;
    // Columns share the room at first.
    const room = @max(c.size.w - (if (wb.sidebar_open) wb.sidebar_width else 0) - 60, 200);
    for (ed.cols.items) |col| if (col.width <= 0) {
        col.width = room / @as(f32, @floatFromInt(n));
    };
    nested(wb, c, chrome, 0);
}

fn nested(wb: *Workbench, c: *ui.Context, chrome: ui.Color, i: usize) void {
    const ed = &wb.editors;
    if (i + 1 >= ed.cols.items.len) return column(wb, c, chrome, i);
    var sp = ui.split(c, &ed.cols.items[i].width, .{ .min = 160 });
    column(wb, c, chrome, i);
    sp.second();
    nested(wb, c, chrome, i + 1);
    _ = sp.end();
}

fn column(wb: *Workbench, c: *ui.Context, chrome: ui.Color, ci: usize) void {
    const ed = &wb.editors;
    const col = ed.cols.items[ci];
    const box = ui.div(c).column().wFull().hFull();
    defer {
        const bi = box.interaction();
        if (ci < ed.body_rects.len) if (bi.rect) |r| {
            ed.body_rects[ci] = r;
        };
        // A press in a column gives it the keyboard.
        if (bi.pressed and ed.focus != ci) {
            ed.focus = ci;
            ed.switched = true;
        }
        box.end();
    }
    const it = col.current() orelse {
        if (col.locked) {
            ed.strip(c, ci, chrome);
            ui.column(c, .{ .width = .fill, .grow = 1, .align_items = .center, .justify = .center, .gap = 8 });
            defer ui.end(c);
            ui.text(c, "This column is locked for terminals.", .{ .size = 12, .color = c.theme.muted });
            if (ui.button(c, "New Terminal", .{ .variant = .primary, .size = 12 }).clicked) wbfiles.newTerminalIn(wb, ci, null, wb.root);
            return;
        }
        if (ed.cols.items.len == 1) return welcome(wb, c);
        ed.strip(c, ci, chrome);
        return;
    };
    ed.strip(c, ci, chrome);
    c.keyed(it);
    switch (it.body) {
        .file => |d| {
            // A file in two columns: each tab its own selection.
            // and its own preview or source (Markdown, SVG).
            if (d.refs > 1) {
                if (it.sel) |s| d.editor.area.sel = s;
                if (it.rendered) |r| d.rendered = r;
            }
            fileBody(wb, c, d, chrome);
            it.area_id = d.editor.area.id;
            if (d.refs > 1) {
                it.sel = d.editor.area.sel;
                it.rendered = d.rendered;
            }
        },
        .image => |im| im.view(c),
        .changes => |ch| {
            ch.rebuild(wb.scm.changes, wb.scm.generation);
            // The diff follows the open files as they are typed.
            var versions: u64 = 0;
            for (wb.editors.cols.items) |cc| for (cc.items.items) |o| switch (o.body) {
                .file => |d| versions +%= d.editor.area.doc.version *% @intFromPtr(d),
                else => {},
            };
            if (versions != ch.versions) {
                ch.versions = versions;
                ch.list.follow(wbgit.reader(wb));
            }
            const before = ch.list.top_entry;
            diffList(wb, c, &ch.list, chrome);
            // Source control chooses the file scrolled to the top.
            if (ch.list.top_entry) |te| if (before != te and te < ch.list.entries.items.len) wb.scm.follow(ch.list.entries.items[te].path);
        },
        .commit => |cv| {
            cv.header(c, chrome);
            diffList(wb, c, &cv.list, chrome);
        },
        .terminal => |t| t.view(c),
    }
}

/// A list of diffs in the layout, font and colors of the settings; the
/// Layout button's choice is kept in them.
fn diffList(wb: *Workbench, c: *ui.Context, dl: *@import("difflist.zig").DiffList, chrome: ui.Color) void {
    const st = wb.shell.store;
    const want = st.s.diffLayout;
    dl.layout = if (std.mem.eql(u8, want, "split")) .split else if (std.mem.eql(u8, want, "inline")) .inline_ else .auto;
    dl.features = st.s.fontFeatures;
    dl.wrap_setting = st.s.wordWrap;
    dl.reviewing = wb.review.list.items.len > 0;
    dl.weight = @intFromFloat(st.s.fontWeight);
    const ev = dl.view(c, wbgit.reader(wb), chrome, &wb.review, themes.syntax(wb.shell.palette));
    if (dl.layout_chosen) {
        dl.layout_chosen = false;
        st.setString("diffLayout", switch (dl.layout) {
            .auto => "",
            .split => "split",
            .inline_ => "inline",
        });
    }
    wbgit.diffEvent(wb, c, dl, ev);
}

fn fileBody(wb: *Workbench, c: *ui.Context, d: *Doc, chrome: ui.Color) void {
    const t = c.theme;
    const sh = wb.shell;
    const s = sh.store.s;
    d.updateMarks(wb.scm.top);
    d.updateConflicts();
    const rel = c.print("{s}", .{if (d.path.len == 0) "Untitled" else fs.relative(wb.root, d.path)});
    std.mem.replaceScalar(u8, @constCast(rel), '\\', '/');
    d.comment_lines = wb.review.ranges(c.alloc(), rel);
    if (wb.review.list.items.len > 0 and d.editor.area.doc.version != d.seen) {
        wb.review.follow(rel, d.editor.area.text(c.alloc()));
    }
    updateSymbols(wb, d);
    const previewable = viewer.isMarkdown(d.path) or viewer.isSvg(d.path);
    // The breadcrumbs: the path, then the blocks around the caret.
    {
        const crumbs = ui.div(c).row().wFull().h(24).px(12).gap(4).itemsCenter();
        defer crumbs.end();
        var it = std.mem.tokenizeScalar(u8, rel, '/');
        var first = true;
        while (it.next()) |part| {
            if (!first) ui.icon(c, "chevron.right", .{ .size = 8, .color = t.muted });
            first = false;
            ui.text(c, part, .{ .size = 12, .color = t.muted });
        }
        var buf: [8]symbols.Symbol = undefined;
        for (symbols.around(&buf, wb.syms, d.editor.area.caretLine())) |sy| {
            ui.icon(c, "chevron.right", .{ .size = 8, .color = t.muted });
            const b = ui.div(c).row().h(20).px(3).itemsCenter().rounded(3).hover(t.surface_hover);
            ui.text(c, sy.name, .{ .size = 12, .color = t.muted });
            if (b.clicked()) d.editor.goToLine(sy.line + 1);
            b.end();
        }
        ui.spacer(c);
        if (previewable) if (ui.button(c, if (d.rendered) "Source" else "Preview", .{ .variant = .ghost, .size = 11 }).clicked) {
            d.rendered = !d.rendered;
        };
    }
    if (d.rendered and viewer.isMarkdown(d.path)) {
        if (viewer.markdown(c, d)) |url| {
            if (std.mem.startsWith(u8, url, "http")) {
                _ = myzig.shell.openUrl(url);
            } else {
                // A file of the project, from the file's folder or the root for "/".
                const base = if (std.mem.startsWith(u8, url, "/")) wb.scm.top orelse wb.root else std.fs.path.dirname(d.path) orelse wb.root;
                const p = std.fs.path.join(c.alloc(), &.{ base, std.mem.trimStart(u8, url, "/") }) catch return;
                if (fs.exists(wb.io, p)) wbfiles.openPath(wb, p, false);
            }
        }
        return;
    }
    if (d.rendered and viewer.isSvg(d.path)) return viewer.svgPreview(c, d);
    d.editor.wrap = d.own_wrap orelse s.wordWrap;
    d.editor.background = .hex(sh.palette.editor);
    d.editor.syntax.colors = themes.syntax(sh.palette);
    d.editor.guides = c.theme.text.alpha(if (sh.palette.dark) 0.08 else 0.1);
    d.editor.whitespace = c.theme.muted.alpha(0.6);
    notes(wb, c, d, rel);
    {
        const row = ui.div(c).row().wFull().grow().itemsStretch();
        defer row.end();
        stickyAndEditor(wb, c, d, chrome);
        // The minimap, while the text keeps its room beside it.
        const mm = @import("minimap.zig");
        var text_w: f32 = if (d.editor.area.scroll_id != 0) (c.rects.get(d.editor.area.scroll_id) orelse ui.Rect{ .w = 1e4 }).w else 1e4;
        if (!d.mini.shown) text_w -= s.minimapWidth;
        d.mini.shown = s.minimap and text_w >= mm.room;
        if (d.mini.shown) if (mm.view(c, d, s.minimapWidth, sh.palette)) |kept| sh.store.setNumber("minimapWidth", kept);
    }
    if (wb.review.list.items.len > 0) reviewStrip(wb, c, d, rel);
}

fn stickyAndEditor(wb: *Workbench, c: *ui.Context, d: *Doc, chrome: ui.Color) void {
    _ = chrome;
    const t = c.theme;
    const s = wb.shell.store.s;
    const box = ui.div(c).column().grow().hFull();
    var tops: []const ui.TextLineTop = &.{};
    var row_h: f32 = 0;
    defer {
        // The overview ruler over the editor's right edge, and the buttons
        // of each conflict on its first line, as last laid out.
        if (box.interaction().rect) |br| if (c.rects.get(d.editor.area.scroll_id)) |er| {
            const at: ui.Rect = .{ .x = er.x - br.x, .y = er.y - br.y, .w = er.w, .h = er.h };
            @import("ruler.zig").view(c, d, at, wb.shell.palette);
            conflictButtons(wb, c, d, at, tops, row_h);
        };
        box.end();
    }
    // Sticky scroll: the lines opening the blocks around the first line in view.
    var buf: [4]symbols.Symbol = undefined;
    const pinned = symbols.around(&buf, wb.syms, d.first_line);
    for (pinned) |sy| if (sy.line < d.first_line) {
        const b = ui.div(c).row().wFull().h(20).px(48).itemsCenter().bg(.hex(wb.shell.palette.chrome)).hover(t.surface_hover);
        const line = d.editor.area.doc.line(c.alloc(), sy.line);
        ui.text(c, std.mem.trimEnd(u8, line, "\r"), .{ .size = s.fontSize * 0.95, .mono = true, .color = t.muted });
        if (b.clicked()) d.editor.goToLine(sy.line + 1);
        b.end();
    };
    if (d.restore_scroll) |y| if (d.editor.area.scroll_id != 0) {
        c.scroll.put(c.gpa, d.editor.area.scroll_id, y) catch {};
        d.restore_scroll = null;
        // The rows in view are those of the last layout's scroll: again.
        c.animationFrame();
    };
    const r = ui.codeEditor(c, &d.editor, .{ .size = s.fontSize, .leading = s.lineHeight, .weight = weightOf(s.fontWeight), .weight_value = @intFromFloat(s.fontWeight), .features = s.fontFeatures });
    d.scroll_y = c.scroll.get(d.editor.area.scroll_id) orelse 0;
    d.first_line = r.first_line;
    d.last_line = r.last_line;
    tops = r.lines;
    row_h = r.row_h;
    // A mark clicked in the gutter shows the change as HEAD had it.
    if (d.editor.area.gutter_press) |l| {
        d.editor.area.gutter_press = null;
        d.peek = if (l < d.marks.items.len and d.marks.items[l] != .none) l else null;
    }
    if (d.peek) |l| switch (peek.view(c, d, l, s.fontSize, s.lineHeight, 56)) {
        .none => {},
        .close => d.peek = null,
        .revert => {
            _ = peek.revert(c.alloc(), d, l);
            d.peek = null;
            c.changed = true;
        },
        .stage => {
            d.editor.area.collapse(d.editor.area.doc.lineStart(@min(l, d.editor.area.doc.lineCount() - 1)));
            wbgit.hunkAtCaret(wb, true);
            d.peek = null;
            c.changed = true;
        },
        .next, .prev => |a| {
            d.editor.area.collapse(d.editor.area.doc.lineStart(@min(l, d.editor.area.doc.lineCount() - 1)));
            if (d.nextChange(a == .next)) |nl| {
                d.peek = nl;
                d.editor.goToLine(nl + 1);
            }
            c.changed = true;
        },
    };
}

/// The whole file, small, in rows of its lines' lengths, with the lines
/// changed since HEAD along its left edge and the view as a slider.
/// Accept Current, Accept Incoming and Accept Both on the first line of
/// each conflict in view, at the editor's right (`at`, within the box
/// over it), as conflicts.go has them.
fn conflictButtons(wb: *Workbench, c: *ui.Context, d: *Doc, at: ui.Rect, tops: []const ui.TextLineTop, row_h: f32) void {
    if (d.blocks.len == 0 or row_h <= 0) return;
    const t = c.theme;
    for (d.blocks) |b| for (tops) |top| if (top.line == b.start) {
        if (top.y < 0 or top.y > at.h - row_h) break;
        c.keyed(b.start);
        const bar = ui.div(c).row().absolute().offset(at.x, at.y + top.y).w(@max(at.w - 28, 0)).h(row_h).gap(2).itemsCenter();
        defer bar.end();
        ui.spacer(c);
        const sides = [_]struct { []const u8, @import("conflicts.zig").Side }{ .{ "Accept Current", .current }, .{ "Accept Incoming", .incoming }, .{ "Accept Both", .both } };
        for (sides) |sd| {
            const btn = ui.div(c).row().h(@max(row_h - 2, 16)).px(7).itemsCenter().rounded(4).bg(.hex(wb.shell.palette.chrome)).border(t.border).hover(t.surface_hover);
            ui.text(c, sd[0], .{ .size = 11.5, .color = if (btn.hovered()) t.text else t.muted });
            const clicked = btn.clicked();
            btn.end();
            if (clicked) {
                // By its first line: the caret goes there, then it is resolved.
                d.editor.area.collapse(d.editor.area.doc.lineStart(b.start));
                wbgit.acceptConflict(wb, sd[1], false);
                c.changed = true;
            }
        }
        break;
    };
}

/// The file's review comments, under the editor.
fn reviewStrip(wb: *Workbench, c: *ui.Context, d: *Doc, rel: []const u8) void {
    const t = c.theme;
    var any = false;
    for (wb.review.list.items) |cm| if (std.mem.eql(u8, cm.path, rel)) {
        any = true;
    };
    if (!any) return;
    ui.column(c, .{ .width = .fill, .padding = .xy(12, 6), .gap = 4, .background = t.warning.alpha(0.08) });
    defer ui.end(c);
    var remove: ?usize = null;
    for (wb.review.list.items, 0..) |cm, i| if (std.mem.eql(u8, cm.path, rel)) {
        c.keyed(cm.text.ptr);
        const row = ui.div(c).row().wFull().gap(8).itemsCenter();
        ui.text(c, c.print("{d}{s}", .{ cm.first + 1, if (cm.outdated) " (outdated)" else "" }), .{ .size = 11, .mono = true, .color = t.muted });
        const b = ui.div(c).row().grow().rounded(3).hover(t.surface_hover);
        ui.text(c, cm.text, .{ .size = 12, .wrap = true });
        if (b.clicked()) {
            d.editor.goToLine(cm.first + 1);
            d.editor.area.select(d.editor.area.doc.lineStart(cm.first), d.editor.area.lineRange(@min(cm.last, d.editor.area.doc.lineCount() - 1))[1]);
            wbfiles.askComment(wb, d);
        }
        b.end();
        if (ui.button(c, "Delete", .{ .variant = .ghost, .size = 11 }).clicked) remove = i;
        row.end();
    };
    if (remove) |i| wb.review.remove(i);
}

/// fontWeight (100 to 900) as a weight of the font.
fn weightOf(w: f32) @FieldType(ui.TextStyle, "weight") {
    return if (w >= 650) .bold else if (w >= 550) .semibold else if (w >= 450) .medium else .regular;
}

/// What shows after lines' ends: the caret line's blame, and each review
/// comment after its last line.
fn notes(wb: *Workbench, c: *ui.Context, d: *Doc, rel: []const u8) void {
    var list: std.ArrayList(@import("doc.zig").Note) = .empty;
    const t = c.theme;
    if (wb.blame.items.len > 0 and wb.shell.store.s.blame) {
        list.append(c.alloc(), .{ .line = d.editor.area.caretLine(), .text = c.print("{s}", .{wb.blame.items}), .color = t.muted.alpha(0.7) }) catch {};
    }
    for (wb.review.list.items) |cm| if (!cm.outdated and std.mem.eql(u8, cm.path, rel)) {
        const first = std.mem.sliceTo(cm.text, '\n');
        list.append(c.alloc(), .{ .line = cm.last, .text = c.print("● {s}", .{first[0..@min(first.len, 120)]}), .color = .hex(wb.shell.palette.modified) }) catch {};
    };
    d.notes = list.items;
}

fn updateSymbols(wb: *Workbench, d: *Doc) void {
    const v = d.editor.area.doc.version;
    if (wb.syms_doc == d and wb.syms_version == v) return;
    wb.syms_doc = d;
    wb.syms_version = v;
    wb.gpa.free(wb.syms);
    wb.gpa.free(wb.syms_text);
    wb.syms_text = d.text();
    wb.syms = symbols.find(wb.gpa, wb.syms_text, viewer.isMarkdown(d.path)) catch &.{};
    wb.quick.syms = wb.syms;
}

fn welcome(wb: *Workbench, c: *ui.Context) void {
    const t = c.theme;
    ui.column(c, .{ .width = .fill, .height = .fill, .align_items = .center, .justify = .center, .gap = 10, .clip = true });
    defer ui.end(c);
    // The Matrix's rain falls behind it while the window has the keyboard.
    if (std.mem.eql(u8, wb.shell.store.s.theme, "matrix")) {
        const p = wb.shell.palette;
        // Still where the system asks for less motion.
        @import("rain.zig").draw(c, &wb.shell.rain, c.size.w, c.size.h, .hex(p.text), .hex(p.accent), wb.shell.has_focus and !ui.motion.reduced(c));
    }
    wb.shell.logo(c, 96);
    ui.text(c, "MyCode", .{ .size = 36, .weight = .bold, .color = t.muted });
    ui.text(c, wb.name(), .{ .size = 14, .color = t.muted });
    _ = c.leaf(.{ .height = .{ .px = 12 } }, .none, null);
    const rows = [_]struct { label: []const u8, keys: []const u8, cmd: Cmd }{
        .{ .label = "Go to File", .keys = ui.keys.label("⌘P"), .cmd = .quick_open },
        .{ .label = "Show All Commands", .keys = ui.keys.label("⇧⌘P"), .cmd = .command_palette },
        .{ .label = "Find in Files", .keys = ui.keys.label("⇧⌘F"), .cmd = .find_in_files },
        .{ .label = "Open Folder", .keys = ui.keys.label("⌘O"), .cmd = .open_folder },
        .{ .label = "Open Recent", .keys = "Ctrl+R", .cmd = .open_recent },
        .{ .label = "Toggle Terminal", .keys = "Ctrl+`", .cmd = .toggle_terminal },
    };
    for (rows) |r| {
        const row = ui.div(c).row().w(320).h(26).px(8).gap(8).itemsCenter().rounded(4).hover(t.surface_hover);
        ui.text(c, r.label, .{ .size = 13, .color = t.muted });
        ui.spacer(c);
        ui.text(c, r.keys, .{ .size = 12, .color = t.muted, .mono = true });
        if (row.clicked()) run_mod.run(wb, c, r.cmd);
        row.end();
    }
    // The recent folders.
    const recent = wb.shell.state.f.recent;
    var others: usize = 0;
    for (recent) |r| if (!std.mem.eql(u8, r, wb.root)) {
        others += 1;
    };
    if (others > 0) {
        _ = c.leaf(.{ .height = .{ .px = 10 } }, .none, null);
        ui.text(c, "Recent", .{ .size = 12, .weight = .semibold, .color = t.muted });
        for (recent[0..@min(recent.len, 6)]) |r| {
            if (std.mem.eql(u8, r, wb.root)) continue;
            c.keyed(r.ptr);
            const row = ui.div(c).row().w(320).h(24).px(8).gap(8).itemsCenter().rounded(4).hover(t.surface_hover);
            ui.text(c, std.fs.path.basename(r), .{ .size = 13, .color = t.accent });
            ui.text(c, r, .{ .size = 11, .color = t.muted });
            // Ctrl+click (⌘ on macOS): in a new window.
            if (row.clicked()) wb.shell.openFolder(r, c.input.ctrl or c.input.cmd);
            row.end();
        }
    }
}

fn statusItem(c: *ui.Context, label: []const u8) bool {
    const it = ui.div(c).row().h(20).px(4).itemsCenter().rounded(3).hover(c.theme.surface_hover);
    ui.text(c, label, .{ .size = 12, .color = c.theme.muted });
    const clicked = it.clicked();
    it.end();
    return clicked;
}

pub fn statusBar(wb: *Workbench, c: *ui.Context) void {
    const t = c.theme;
    const p = wb.shell.palette;
    const bar = ui.div(c).row().wFull().h(24).px(6).gap(10).itemsCenter().bg(.hex(p.chrome));
    defer bar.end();
    if (!wb.shell.store.s.projectTabs) wb.shell.manageButton(c, wb);
    wb.shell.mascot(c, 16);
    if (wb.scm.branch) |b| {
        const br = ui.div(c).row().h(20).px(4).gap(4).itemsCenter().rounded(3).hover(t.surface_hover);
        ui.icon(c, "arrow.triangle.branch", .{ .size = 11, .color = t.muted });
        ui.text(c, b, .{ .size = 12, .color = t.muted });
        if (wb.scm.ab.ahead > 0) ui.text(c, c.print("↑{d}", .{wb.scm.ab.ahead}), .{ .size = 11, .color = t.muted });
        if (wb.scm.ab.behind > 0) ui.text(c, c.print("↓{d}", .{wb.scm.ab.behind}), .{ .size = 11, .color = t.muted });
        const bi = br.interaction();
        br.end();
        if (ui.buttonMenu(c, &wb.status_menu, bi)) |m| {
            defer m.end();
            const items = [_]Cmd{ .git_switch_branch, .git_create_branch, .git_rename_branch, .git_delete_branch, .git_fetch, .git_pull, .git_push, .git_sync };
            for (items, 0..) |cmd, k| {
                if (k == 4) m.separator();
                if (m.item(commands.info(cmd).title, .{})) run_mod.run(wb, c, cmd);
            }
        }
    }
    if (wb.runner.busy) ui.text(c, "Git…", .{ .size = 11, .color = t.accent });
    if (wb.review.list.items.len > 0) {
        const rv = ui.div(c).row().h(20).px(4).gap(4).itemsCenter().rounded(3).hover(t.surface_hover);
        ui.icon(c, "pencil", .{ .size = 11, .color = .hex(p.modified) });
        ui.text(c, c.print("{d} comments", .{wb.review.list.items.len}), .{ .size = 12, .color = t.muted });
        const ri = rv.interaction();
        rv.end();
        if (ui.buttonMenu(c, &wb.review_menu, ri)) |m| {
            defer m.end();
            for (wb.review.list.items) |cm| if (m.item(c.print("{s}:{d}  {s}", .{ cm.path, cm.first + 1, cm.text[0..@min(cm.text.len, 40)] }), .{})) {
                const abs = std.fs.path.join(c.alloc(), &.{ wb.root, cm.path }) catch continue;
                if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, abs, '/', std.fs.path.sep);
                if (wb.editors.openFile(abs, false)) |it| switch (it.body) {
                    .file => |d| d.editor.goToLine(cm.first + 1),
                    else => {},
                } else |_| {}
            };
            m.separator();
            if (m.item("Send to Terminal", .{})) run_mod.run(wb, c, .send_review);
            if (m.item("Copy", .{})) run_mod.run(wb, c, .copy_review);
            if (m.item("Clear", .{})) run_mod.run(wb, c, .clear_review);
        }
    }
    const doc = wb.editors.currentDoc();
    if (doc) |d| blame(wb, c, d);
    ui.spacer(c);
    if (wb.shell.keymap.chord_len > 0) ui.text(c, c.print("({s}) was pressed. Waiting for the next key…", .{wb.shell.keymap.chordText(c)}), .{ .size = 11, .color = t.accent });
    const d = doc orelse return;
    const ta = &d.editor.area;
    const line = ta.caretLine();
    const col = ta.sel.caret - ta.doc.lineStart(line);
    const sel_n = ta.sel.hi() - ta.sel.lo();
    if (statusItem(c, if (sel_n > 0) c.print("Ln {d}, Col {d} ({d} selected)", .{ line + 1, col + 1, sel_n }) else c.print("Ln {d}, Col {d}", .{ line + 1, col + 1 }))) run_mod.run(wb, c, .go_to_line);
    const unit = d.editor.indent.unit;
    const ind = ui.div(c).row().h(20).px(4).itemsCenter().rounded(3).hover(t.surface_hover);
    ui.text(c, if (std.mem.eql(u8, unit, "\t")) "Tab Size: 4" else c.print("Spaces: {d}", .{unit.len}), .{ .size = 12, .color = t.muted });
    const ii = ind.interaction();
    ind.end();
    if (ui.buttonMenu(c, &wb.indent_menu, ii)) |m| {
        defer m.end();
        const items = [_]Cmd{ .indent_tabs, .indent_spaces_2, .indent_spaces_4, .indent_spaces_8 };
        for (items) |cmd| if (m.item(commands.info(cmd).title, .{})) run_mod.run(wb, c, cmd);
    }
    if (statusItem(c, if (d.crlf) "CRLF" else "LF")) {
        d.crlf = !d.crlf;
        d.saved +%= 1; // the line endings changed: save writes them
    }
    _ = statusItem(c, "UTF-8");
    _ = statusItem(c, icons.languageName(d.name()));
    if (statusItem(c, if (d.editor.wrap) "Wrap" else "No Wrap")) run_mod.run(wb, c, .toggle_wrap);
    if (statusItem(c, if (wb.shell.store.s.autoSave) "Auto Save" else "Auto Save Off")) run_mod.run(wb, c, .toggle_auto_save);
}

/// Who changed the caret's line last, read a moment after the caret stops.
fn blame(wb: *Workbench, c: *ui.Context, d: *Doc) void {
    if (!wb.shell.store.s.blame or d.path.len == 0) return;
    const top = wb.scm.top orelse return;
    const line = d.editor.area.caretLine();
    var h = std.hash.Wyhash.init(0);
    h.update(std.mem.asBytes(&d));
    h.update(std.mem.asBytes(&line));
    h.update(std.mem.asBytes(&d.saved));
    const key = h.final();
    if (key != wb.blame_key) {
        wb.blame_key = key;
        wb.blame_at = c.time;
        wb.blame.clearRetainingCapacity();
    }
    // The text shows after the caret's line (`notes`).
    if (wb.blame.items.len > 0) return;
    if (d.dirty() or wb.blame_busy or wb.blame_tried == key) return;
    const wait = wb.blame_at + 0.6 - c.time;
    if (wait > 0) return c.frameIn(@floatCast(wait));
    const rel = wb.gpa.dupe(u8, fs.relative(top, d.path)) catch return;
    const j = wb.gpa.create(wbgit.BlameJob) catch return wb.gpa.free(rel);
    j.* = .{ .wb = wb, .gpa = wb.gpa, .io = wb.io, .key = key, .top = wb.gpa.dupe(u8, top) catch return, .path = rel, .line = line };
    wb.blame_busy = true;
    wb.blame_tried = key;
    jobs.spawn(wbgit.BlameJob, j, wbgit.BlameJob.work, wbgit.BlameJob.done) catch {
        wb.blame_busy = false;
    };
}
