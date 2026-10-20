//! A project's files and terminals: the Explorer's and search's events, new
//! files and folders, renames and the Recycle Bin, saving as, terminals in
//! the panel and in columns, and the boxes over the window.
const std = @import("std");
const tabdrag = @import("tabdrag.zig");
const myzig = @import("myzig");
const ui = myzig.ui;
const fs = @import("fs.zig");
const Workbench = @import("workbench.zig").Workbench;
const explorer_mod = @import("explorer.zig");
const search_mod = @import("search.zig");
const columns = @import("columns.zig");
const panel_mod = @import("panel.zig");
const Term = panel_mod.Term;
const Doc = @import("doc.zig").Doc;
const wbgit = @import("wb_git.zig");
const run_mod = @import("wb_run.zig");

pub fn explorerEvent(wb: *Workbench, c: *ui.Context, ev: explorer_mod.Event) void {
    if (ev == .none) return;
    c.changed = true;
    switch (ev) {
        .none => {},
        .open => |o| openPath(wb, o.path, o.preview),
        .new_file => |dir| askNewFile(wb, dir, false),
        .new_folder => |dir| askNewFile(wb, dir, true),
        .rename => |p| wb.prompt.ask(.rename, "Rename", std.fs.path.basename(p), p),
        .trash => |p| wb.ask(.trash, p, c.print("Delete “{s}”?", .{std.fs.path.basename(p)}), "It goes to the Recycle Bin.", &.{ "Cancel", "Delete" }),
        .open_changes => |p| wbgit.openChangesTab(wb, p, true),
        .open_terminal => |dir| newTerminalAt(wb, dir),
        .paste => |dir| pasteFiles(wb, dir),
        .press => |p| startFileDrag(wb, c, p),
    }
}

/// A file pressed in the Explorer, Source Control or Search: dragged far
/// enough, it goes where it is let go.
pub fn startFileDrag(wb: *Workbench, c: *ui.Context, path: []const u8) void {
    if (wb.file_drag) |fd| wb.gpa.free(fd.path);
    wb.file_drag = .{ .path = wb.gpa.dupe(u8, path) catch return, .start = c.input.mouse };
}

/// The file being dragged: its ghost follows the pointer; let go on a
/// column's strip or body it opens there, on a column's right edge in a
/// new column, on a terminal its path is typed.
pub fn fileDragFrame(wb: *Workbench, c: *ui.Context) void {
    const fd = &(wb.file_drag orelse return);
    if (c.input.down) {
        const m = c.input.mouse;
        if (!fd.moving and (@abs(m.x - fd.start.x) > 8 or @abs(m.y - fd.start.y) > 8)) fd.moving = true;
        if (fd.moving) {
            c.wants_moves = true;
            if (tabdrag.at(&wb.editors, m)) |t| tabdrag.marker(c, &wb.editors, t);
            const ghost = ui.div(c).row().absolute().offset(m.x + 10, m.y + 8).px(8).py(4).gap(6).itemsCenter().rounded(4).bg(c.theme.surface_hover).border(c.theme.border);
            @import("icons.zig").file(c, std.fs.path.basename(fd.path));
            ui.text(c, std.fs.path.basename(fd.path), .{ .size = 12 });
            ghost.end();
        }
        return;
    }
    defer {
        wb.gpa.free(fd.path);
        wb.file_drag = null;
    }
    if (!fd.moving) return;
    const p = c.input.mouse;
    const paths = [_][]const u8{fd.path};
    // A terminal: the path is typed into it.
    for (wb.panel.terms.items) |t| if (wb.panel.open and t.rect != null and t.rect.?.contains(p)) return t.typePaths(&paths);
    const ed = &wb.editors;
    const n = @min(ed.cols.items.len, ed.strip_rects.len);
    for (0..n) |ci| if (ed.cols.items[ci].current()) |it| switch (it.body) {
        .terminal => |t| if (t.rect != null and t.rect.?.contains(p)) return t.typePaths(&paths),
        else => {},
    };
    _ = dropFiles(wb, &paths, p);
    c.changed = true;
}

/// A terminal's chip dragged from the panel: let go over the columns, the
/// terminal goes into one, where it lands.
pub fn panelDragFrame(wb: *Workbench, c: *ui.Context) void {
    const dg = &(wb.panel.drag orelse return);
    const ed = &wb.editors;
    const m = c.input.mouse;
    if (c.input.down) {
        if (!dg.moving and (@abs(m.x - dg.start.x) > 8 or @abs(m.y - dg.start.y) > 8)) dg.moving = true;
        if (dg.moving) {
            c.wants_moves = true;
            if (tabdrag.at(ed, m)) |t| tabdrag.marker(c, ed, t);
            const ghost = ui.div(c).row().absolute().offset(m.x + 10, m.y + 8).px(8).py(4).gap(6).itemsCenter().rounded(4).bg(c.theme.surface_hover).border(c.theme.border);
            ui.icon(c, "terminal", .{ .size = 11, .color = c.theme.muted });
            ui.text(c, dg.term.name(), .{ .size = 12 });
            ghost.end();
        }
        return;
    }
    defer wb.panel.drag = null;
    if (!dg.moving) return;
    const t = tabdrag.at(ed, m) orelse return;
    const i = std.mem.indexOfScalar(*Term, wb.panel.terms.items, dg.term) orelse return;
    const ci = tabdrag.column(ed, t, null) orelse return;
    const term = wb.panel.take(i);
    const it = ed.newItem(.{ .terminal = term }, false) catch return wb.panel.add(term);
    term.focus = true;
    const col = ed.cols.items[ci];
    const at = @min(t.idx orelse col.items.items.len, col.items.items.len);
    col.items.insert(wb.gpa, at, it) catch {
        it.destroy(wb.gpa);
        return;
    };
    ed.show(.{ .col = ci, .idx = at });
    c.changed = true;
}

/// Files let go at `p` over the columns: each opens where it lands,
/// between tabs, in a column, or in a new one at a column's edge. False
/// when `p` is over no column.
pub fn dropFiles(wb: *Workbench, paths: []const []const u8, p: ui.Point) bool {
    const ed = &wb.editors;
    const t = tabdrag.at(ed, p) orelse return false;
    const ci = tabdrag.column(ed, t, null) orelse return false;
    var idx = t.idx;
    for (paths) |path| {
        openIn(wb, path, ci, idx);
        if (idx) |i| idx = i + 1;
    }
    return true;
}

/// Opens a file in a column (a locked one too, when dropped there), at
/// place `idx` of its strip or after the tab shown.
fn openIn(wb: *Workbench, path: []const u8, col: usize, idx: ?usize) void {
    const ed = &wb.editors;
    if (ed.findPath(path)) |l| {
        if (l.col != col or idx != null) ed.move(l, col, if (idx) |i| (if (l.col == col and i > l.idx) i - 1 else i) else null) else ed.show(l);
        return;
    }
    const body: @import("columns.zig").Body = if (@import("viewer.zig").isImage(path))
        .{ .image = @import("viewer.zig").Image.create(wb.gpa, wb.io, path) catch return }
    else
        .{ .file = @import("doc.zig").Doc.create(wb.gpa, wb.io, path) catch return };
    const it = ed.newItem(body, false) catch return;
    const l = ed.add(it, col) catch return;
    if (idx) |i| if (i != l.idx) ed.move(l, col, if (i > l.idx) i - 1 else i);
}

/// Copies the files on the clipboard into a folder; a name taken gets
/// " copy" (then " copy 2"...) before its extension.
fn pasteFiles(wb: *Workbench, dir: []const u8) void {
    const files = (myzig.clipboard.readFiles(wb.gpa) catch null) orelse return;
    defer {
        for (files) |f| wb.gpa.free(f);
        wb.gpa.free(files);
    }
    var last: ?[]u8 = null;
    defer if (last) |l| wb.gpa.free(l);
    for (files) |src| {
        const to = freeName(wb, dir, std.fs.path.basename(src)) orelse continue;
        copyTree(wb, src, to) catch |err| {
            wb.toastError("Couldn't paste", @errorName(err));
            wb.gpa.free(to);
            continue;
        };
        if (last) |l| wb.gpa.free(l);
        last = to;
    }
    wb.explorer.refresh();
    if (last) |l| wb.explorer.reveal(l);
}

fn freeName(wb: *Workbench, dir: []const u8, name: []const u8) ?[]u8 {
    const first = std.fs.path.join(wb.gpa, &.{ dir, name }) catch return null;
    if (!fs.exists(wb.io, first)) return first;
    wb.gpa.free(first);
    const ext = std.fs.path.extension(name);
    const stem = name[0 .. name.len - ext.len];
    var n: usize = 1;
    while (n < 100) : (n += 1) {
        const candidate = if (n == 1)
            std.fmt.allocPrint(wb.gpa, "{s}{c}{s} copy{s}", .{ dir, std.fs.path.sep, stem, ext }) catch return null
        else
            std.fmt.allocPrint(wb.gpa, "{s}{c}{s} copy {d}{s}", .{ dir, std.fs.path.sep, stem, n, ext }) catch return null;
        if (!fs.exists(wb.io, candidate)) return candidate;
        wb.gpa.free(candidate);
    }
    return null;
}

fn copyTree(wb: *Workbench, src: []const u8, dst: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    if (!fs.isDirectory(wb.io, src)) return cwd.copyFile(src, cwd, dst, wb.io, .{});
    try cwd.createDirPath(wb.io, dst);
    const list = try fs.list(wb.gpa, wb.io, src);
    defer fs.freeList(wb.gpa, list);
    for (list) |e| {
        const to = try std.fs.path.join(wb.gpa, &.{ dst, std.fs.path.basename(e.path) });
        defer wb.gpa.free(to);
        try copyTree(wb, e.path, to);
    }
}

pub fn openPath(wb: *Workbench, path: []const u8, preview: bool) void {
    _ = wb.editors.openFile(path, preview) catch |err| {
        wb.toastError("Couldn't open the file", @errorName(err));
        return;
    };
    wb.quick.noteOpened(fs.relative(wb.root, path));
}

pub fn askNewFile(wb: *Workbench, dir: []const u8, folder: bool) void {
    wb.sidebar_open = true;
    wb.side = .explorer;
    wb.prompt.ask(if (folder) .new_folder else .new_file, if (folder) "A new folder's name" else "A new file's name (a/b.txt makes its folders)", "", dir);
}

pub fn askComment(wb: *Workbench, d: *Doc) void {
    const ta = &d.editor.area;
    const first = ta.doc.lineOf(ta.sel.lo());
    var last = ta.doc.lineOf(ta.sel.hi());
    if (last > first and ta.sel.hi() == ta.doc.lineStart(last)) last -= 1;
    const rel = fs.relative(wb.root, d.path);
    const existing = if (wb.review.at(rel, first)) |i| wb.review.list.items[i].text else "";
    var buf: [64]u8 = undefined;
    const target = std.fmt.bufPrint(&buf, "{d}:{d}", .{ first, last }) catch return;
    wb.prompt.askText(wb.gpa, .review_comment, if (first == last) "A comment on this line" else "A comment on these lines", existing, target);
}

fn answer(wb: *Workbench, c: *ui.Context, a: []const u8) void {
    const p = &wb.prompt;
    const target = p.targetPath();
    c.changed = true;
    switch (p.purpose) {
        .new_file, .new_folder => {
            const path = std.fs.path.join(wb.gpa, &.{ target, a }) catch return;
            defer wb.gpa.free(path);
            if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, path, '/', std.fs.path.sep);
            if (fs.exists(wb.io, path)) {
                wb.toastError("It's there already", path);
                return;
            }
            if (p.purpose == .new_folder) {
                std.Io.Dir.cwd().createDirPath(wb.io, path) catch |err| return wb.toastError("Couldn't create the folder", @errorName(err));
            } else {
                if (std.fs.path.dirname(path)) |d| std.Io.Dir.cwd().createDirPath(wb.io, d) catch {};
                fs.write(wb.io, path, "") catch |err| return wb.toastError("Couldn't create the file", @errorName(err));
            }
            wb.explorer.refresh();
            wb.explorer.reveal(path);
            if (p.purpose == .new_file) openPath(wb, path, false);
        },
        .rename => {
            const dir = std.fs.path.dirname(target) orelse wb.root;
            const to = std.fs.path.join(wb.gpa, &.{ dir, a }) catch return;
            defer wb.gpa.free(to);
            std.Io.Dir.cwd().rename(target, std.Io.Dir.cwd(), to, wb.io) catch |err| return wb.toastError("Couldn't rename", @errorName(err));
            // An open file follows its new name.
            if (wb.editors.findDoc(target)) |d| d.setPath(to) catch {};
            wb.editors.switched = true;
            wb.explorer.refresh();
            wb.explorer.reveal(to);
        },
        .review_comment => {
            var it = std.mem.splitScalar(u8, target, ':');
            const first = std.fmt.parseInt(usize, it.next() orelse "0", 10) catch 0;
            const last = std.fmt.parseInt(usize, it.next() orelse "0", 10) catch first;
            const d = wb.editors.currentDoc() orelse return;
            const ta = &d.editor.area;
            const a0 = ta.doc.lineStart(first);
            const a1 = ta.lineRange(@min(last, ta.doc.lineCount() - 1))[1];
            const snippet = ta.doc.slice(c.alloc(), a0, a1);
            const rel = c.print("{s}", .{fs.relative(wb.root, d.path)});
            std.mem.replaceScalar(u8, @constCast(rel), '\\', '/');
            wb.review.put(rel, first, last, snippet, a) catch {};
        },
        .diff_comment => {
            var it = std.mem.splitScalar(u8, target, ':');
            const first = std.fmt.parseInt(usize, it.next() orelse "0", 10) catch 0;
            const last = std.fmt.parseInt(usize, it.next() orelse "0", 10) catch first;
            wb.review.putDiff(it.rest(), first, last, wb.diff_comment.items, a) catch {};
        },
        else => _ = wbgit.promptAnswer(wb, p.purpose, a, target),
    }
}

pub fn searchEvent(wb: *Workbench, c: *ui.Context, ev: search_mod.Event) void {
    if (ev == .none) return;
    c.changed = true;
    switch (ev) {
        .none => {},
        .open => |o| {
            const abs = std.fs.path.join(wb.gpa, &.{ wb.root, o.path }) catch return;
            defer wb.gpa.free(abs);
            if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, abs, '/', std.fs.path.sep);
            const it = wb.editors.openFile(abs, !o.keep) catch return;
            switch (it.body) {
                .file => |d| {
                    const ta = &d.editor.area;
                    if (o.line < ta.doc.lineCount()) {
                        const ls = ta.doc.lineStart(o.line);
                        const le = ta.doc.lineEnd(o.line);
                        ta.select(@min(ls + o.col, le), @min(ls + o.col + o.len, le));
                        ta.reveal = true;
                    }
                },
                else => {},
            }
        },
        .replace_all => replaceIn(wb, c, null),
        .replace_file => |fi| replaceIn(wb, c, fi),
        .replace_match => |m| replaceIn(wb, c, m.file),
        .press => |rel| {
            const abs = std.fs.path.join(wb.gpa, &.{ wb.root, rel }) catch return;
            defer wb.gpa.free(abs);
            if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, abs, '/', std.fs.path.sep);
            startFileDrag(wb, c, abs);
        },
    }
}

/// Replaces matches in one file of the results, or every file: an open file
/// as a step of its undo, the others written at once.
fn replaceIn(wb: *Workbench, c: *ui.Context, only: ?usize) void {
    const s = &wb.search;
    const o = s.options();
    const rep = s.replacement.text();
    var total: usize = 0;
    for (s.results.items, 0..) |r, fi| {
        if (only) |k| if (k != fi) continue;
        const abs = std.fs.path.join(c.alloc(), &.{ wb.root, r.path }) catch continue;
        if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, abs, '/', std.fs.path.sep);
        if (wb.editors.findDoc(abs)) |d| {
            const text = d.editor.area.text(c.alloc());
            const out = search_mod.replaceAll(c.alloc(), o, text, rep) catch continue;
            if (out.count > 0) d.editor.area.setText(out.text);
            total += out.count;
        } else {
            const data = fs.read(c.alloc(), wb.io, abs) catch continue;
            const crlf = std.mem.indexOf(u8, data, "\r\n") != null;
            const plain = if (crlf) std.mem.replaceOwned(u8, c.alloc(), data, "\r\n", "\n") catch continue else data;
            const out = search_mod.replaceAll(c.alloc(), o, plain, rep) catch continue;
            if (out.count == 0) continue;
            const final = if (crlf) std.mem.replaceOwned(u8, c.alloc(), out.text, "\n", "\r\n") catch continue else out.text;
            fs.write(wb.io, abs, final) catch continue;
            total += out.count;
        }
    }
    _ = wb.toasts.show(c.print("Replaced {d} matches", .{total}));
    s.start(wb.shell.store.s.filesExclude, wb.dirtyTexts(c.alloc()));
}

pub fn saveAs(wb: *Workbench, d: *Doc) void {
    const path = (myzig.dialog.save(wb.gpa, .{ .directory = wb.root, .name = d.name() }) catch return) orelse return;
    defer wb.gpa.free(path);
    d.setPath(path) catch return;
    d.save() catch |err| wb.toastError("Couldn't save", @errorName(err));
    wb.editors.switched = true;
    wb.explorer.refresh();
}

pub fn afterSave(wb: *Workbench, d: *Doc) void {
    wb.refreshGit();
    // settings.json and keybindings.json apply as they are saved.
    wb.shell.fileSaved(d.path);
}

pub fn openFileDialog(wb: *Workbench) void {
    const paths = (myzig.dialog.open(wb.gpa, .{ .title = "Open File", .directory = wb.root }) catch return) orelse return;
    defer myzig.dialog.freePaths(wb.gpa, paths);
    for (paths) |p| openPath(wb, p, false);
}

/// A new terminal in the panel, of a profile (the default when null).
pub fn newTerminal(wb: *Workbench, profile: ?usize) void {
    const t = makeTerm(wb, profile, wb.root) orelse return;
    wb.panel.add(t);
}

fn newTerminalAt(wb: *Workbench, dir: []const u8) void {
    const t = makeTerm(wb, null, dir) orelse return;
    wb.panel.add(t);
}

fn makeTerm(wb: *Workbench, profile: ?usize, dir: []const u8) ?*Term {
    const host = &wb.shell.host;
    if (host.ready.load(.acquire) != 1) {
        wb.panel.open = true;
        return null;
    }
    const profiles = wb.shell.profiles;
    const pi = profile orelse wb.shell.defaultProfile();
    const s = wb.shell.store.s;
    return Term.create(wb.gpa, wb.io, host, .{
        .dir = dir,
        .profile = if (pi < profiles.len) profiles[pi] else null,
        .font_size = if (s.terminalFontSize > 0) s.terminalFontSize else s.fontSize - 0.5,
        .copy_on_select = s.terminalCopyOnSelect,
    }) catch |err| {
        wb.panel.err = @errorName(err);
        wb.panel.open = true;
        return null;
    };
}

/// A terminal in a column's tab (a locked column keeps terminals).
pub fn newTerminalIn(wb: *Workbench, col: usize, profile: ?usize, dir: []const u8) void {
    const t = makeTerm(wb, profile, if (dir.len > 0 and fs.isDirectory(wb.io, dir)) dir else wb.root) orelse return;
    const it = wb.editors.newItem(.{ .terminal = t }, false) catch return t.destroy();
    _ = wb.editors.add(it, @min(col, wb.editors.cols.items.len - 1)) catch {};
}

/// Moves the terminal of the panel into the focused column, after its tab;
/// a terminal tab shown goes to the panel.
pub fn moveTerminal(wb: *Workbench) void {
    const ed = &wb.editors;
    if (ed.current()) |it| if (it.body == .terminal and !(wb.panel.open and panelFocused(wb))) {
        const t = it.body.terminal;
        const l = ed.currentLoc().?;
        _ = ed.take(l);
        wb.gpa.destroy(it);
        wb.panel.add(t);
        return;
    };
    if (wb.panel.terms.items.len == 0) return;
    const t = wb.panel.take(wb.panel.active);
    const it = ed.newItem(.{ .terminal = t }, false) catch return wb.panel.add(t);
    t.focus = true;
    const col = ed.focusCol();
    col.items.insert(wb.gpa, @min(col.active + 1, col.items.items.len), it) catch {
        it.destroy(wb.gpa);
        return;
    };
    ed.show(.{ .col = ed.focus, .idx = @min(col.active + 1, col.items.items.len - 1) });
}

/// The panel's terminal has the keyboard.
fn panelFocused(wb: *Workbench) bool {
    for (wb.panel.terms.items) |t| if (t.focused()) return true;
    return false;
}

/// Ends the panel's terminal shown, and its shell.
pub fn killTerminal(wb: *Workbench) void {
    if (wb.panel.terms.items.len == 0) return;
    const t = wb.panel.take(wb.panel.active);
    t.destroy();
    if (wb.panel.current()) |n| n.focus = true;
}

/// Moves the panel's terminal into a locked column on the right, made when
/// there is none.
pub fn terminalToLockedColumn(wb: *Workbench) void {
    if (wb.panel.terms.items.len == 0) return;
    const t = wb.panel.take(wb.panel.active);
    toLockedColumn(wb, t);
}

fn toLockedColumn(wb: *Workbench, t: *Term) void {
    const ed = &wb.editors;
    var target: ?usize = null;
    var i = ed.cols.items.len;
    while (i > 0) {
        i -= 1;
        if (ed.cols.items[i].locked) {
            target = i;
            break;
        }
    }
    const ci = target orelse blk: {
        const ni = ed.addColumn(ed.cols.items.len) catch return;
        ed.cols.items[ni].locked = true;
        break :blk ni;
    };
    const it = ed.newItem(.{ .terminal = t }, false) catch return;
    t.focus = true;
    _ = ed.add(it, ci) catch {};
}

pub fn tabRequest(wb: *Workbench, c: *ui.Context, req: columns.Editors.Request) void {
    switch (req) {
        .reveal => |p| {
            wb.sidebar_open = true;
            wb.side = .explorer;
            wb.explorer.reveal(p);
        },
        .open_changes => |p| wbgit.openChangesTab(wb, p, true),
        .to_panel => |t| wb.panel.add(t),
        .to_locked => |t| toLockedColumn(wb, t),
        .copy_path => |p| _ = myzig.clipboard.writeText(p),
        .new_terminal_in => |ci| newTerminalIn(wb, ci, null, wb.root),
        .reopen_terminal => |l| {
            const ed = &wb.editors;
            const dir = ed.reopen_dir orelse wb.root;
            newTerminalIn(wb, l.col, null, dir);
            if (ed.reopen_dir) |d| wb.gpa.free(d);
            ed.reopen_dir = null;
            if (ed.currentLoc()) |at| if (at.col == l.col and at.idx != l.idx) ed.move(at, l.col, l.idx);
        },
    }
    c.changed = true;
}

pub fn panelRequest(wb: *Workbench, req: panel_mod.Panel.Request) void {
    switch (req) {
        .new => |p| newTerminal(wb, p),
        .to_column => |t| {
            if (std.mem.indexOfScalar(*Term, wb.panel.terms.items, t)) |i| _ = wb.panel.take(i);
            toLockedColumn(wb, t);
        },
        .set_default => |i| wb.shell.setDefaultProfile(i),
    }
}

/// Pastes text into the terminal used last, without Enter.
pub fn sendToTerminal(wb: *Workbench, text: []const u8) void {
    if (wb.panel.current() == null) newTerminal(wb, null);
    const t = wb.panel.current() orelse return;
    wb.panel.open = true;
    t.t.paste(text);
    t.focus = true;
}

/// The boxes over the window: quick open, prompts, pickers, questions, toasts.
pub fn overlays(wb: *Workbench, c: *ui.Context) void {
    if (wb.quick.view(c)) |pick| switch (pick) {
        .file => |rel| {
            const abs = std.fs.path.join(wb.gpa, &.{ wb.root, rel }) catch return;
            defer wb.gpa.free(abs);
            if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, abs, '/', std.fs.path.sep);
            openPath(wb, abs, false);
            c.changed = true;
        },
        .command => |cmd| run_mod.run(wb, c, cmd),
        .line => |line| if (wb.editors.currentDoc()) |d| {
            d.editor.goToLine(line);
            c.changed = true;
        },
        .symbol => |line| if (wb.editors.currentDoc()) |d| {
            d.editor.goToLine(line + 1);
            c.changed = true;
        },
    };
    if (wb.prompt.view(c)) |a| answer(wb, c, a);
    if (wb.picker.view(c)) |pick| wbgit.pickerEvent(wb, c, pick);
    const buttons = wb.confirm_buttons[0..wb.confirm_n];
    switch (ui.alertDialog(c, &wb.confirm, wb.confirm_title.items, wb.confirm_text.items, buttons)) {
        .chosen => |i| wbgit.confirmed(wb, c, i),
        else => {},
    }
    const r = ui.toasts(c, &wb.toasts);
    if (r.action) |id| {
        if (id == wb.toast_undo_commit) wbgit.undoCommit(wb);
        if (id == wb.toast_pop_stash) @import("wb_run.zig").run(wb, c, .git_stash_pop);
        if (id == wb.toast_stage_conflicts) wbgit.stageCurrentFile(wb);
        if (id == wb.toast_restore_branch) wbgit.restoreDeletedBranch(wb);
        c.changed = true;
    }
}
