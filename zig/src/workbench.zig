//! A project: one folder's sidebar (Explorer, Search, Source Control), its
//! editor columns, its terminal panel and its status bar. A window shows one
//! project at a time; the others keep running out of sight.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const fs = @import("fs.zig");
const git = @import("git.zig");
const commands = @import("commands.zig");
const Cmd = commands.Cmd;
const state_mod = @import("state.zig");
const themes = @import("themes.zig");
const Shell = @import("shell.zig").Shell;
const Explorer = @import("explorer.zig").Explorer;
const StatusColors = @import("explorer.zig").StatusColors;
const columns = @import("columns.zig");
const Editors = columns.Editors;
const QuickOpen = @import("quickopen.zig").QuickOpen;
const panel_mod = @import("panel.zig");
const Panel = panel_mod.Panel;
const Scm = @import("scm.zig").Scm;
const Search = @import("search.zig").Search;
const Prompt = @import("prompt.zig").Prompt;
const Picker = @import("branches.zig").Picker;
const Review = @import("review.zig").Review;
const gitops = @import("gitops.zig");
const FsWatch = @import("fswatch.zig").FsWatch;
const symbols = @import("symbols.zig");
const viewer = @import("viewer.zig");
const doc_mod = @import("doc.zig");
const icons = @import("icons.zig");
const run_mod = @import("wb_run.zig");
const wbgit = @import("wb_git.zig");
const wbfiles = @import("wb_files.zig");
const wbeditor = @import("wb_editor.zig");

pub const Side = enum { explorer, search, scm };

/// What a confirmation is for, and its subject.
pub const Confirm = enum {
    discard_file,
    discard_all,
    trash,
    force_push,
    pull_diverged,
    delete_branch,
    delete_branch_force,
    delete_upstream,
    stash_drop,
    commit_all,
    checkout_detached,
    close_project,
    discard_hunk_closed,
};

pub const Workbench = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    shell: *Shell,
    /// The folder, absolute.
    root: []u8,
    explorer: Explorer,
    editors: Editors,
    quick: QuickOpen,
    panel: Panel,
    scm: Scm,
    search: Search,
    prompt: Prompt = .{},
    picker: Picker,
    review: Review,
    runner: gitops.Runner,
    watcher: ?*FsWatch = null,
    side: Side = .explorer,
    sidebar_open: bool = true,
    sidebar_width: f32 = 260,
    toasts: ui.Toasts = .{},
    /// Commands from the menu bar and keys, run at the next frame.
    pending: std.ArrayList(Cmd) = .empty,
    refresh_next: bool = true,
    /// The Changes tab follows Git's status by its generation.
    confirm: ui.OverlayState = .{},
    confirm_kind: Confirm = .discard_file,
    confirm_arg: std.ArrayList(u8) = .empty,
    confirm_title: std.ArrayList(u8) = .empty,
    confirm_text: std.ArrayList(u8) = .empty,
    confirm_buttons: [3][]const u8 = .{ "", "", "" },
    confirm_n: usize = 2,
    /// Toasts with buttons, by what their button does.
    toast_undo_commit: u64 = 0,
    toast_pop_stash: u64 = 0,
    toast_stage_conflicts: u64 = 0,
    toast_restore_branch: u64 = 0,
    restore_branch: std.ArrayList(u8) = .empty,
    /// A file dragged from the sidebar.
    file_drag: ?struct { path: []u8, start: ui.Point, moving: bool = false } = null,
    /// The rows of a diff a comment is being written on.
    diff_comment: std.ArrayList(u8) = .empty,
    /// The caret's line's last change (inline blame), and what it was asked for.
    blame: std.ArrayList(u8) = .empty,
    blame_key: u64 = 0,
    blame_at: f64 = 0,
    blame_busy: bool = false,
    blame_tried: u64 = 0,
    /// The file shown's symbols, made again when its text changes.
    syms: []symbols.Symbol = &.{},
    syms_doc: ?*doc_mod.Doc = null,
    syms_version: u64 = std.math.maxInt(u64),
    syms_text: []u8 = &.{},
    status_menu: ui.Menu = .{},
    review_menu: ui.Menu = .{},
    indent_menu: ui.Menu = .{},
    bell: bool = false,
    /// The project's favicon or logo, read once for the rail.
    logo: ?@import("logo.zig").Logo = null,
    logo_read: bool = false,

    pub fn create(shell: *Shell, root: []const u8) !*Workbench {
        const gpa = shell.gpa;
        const io = shell.io;
        const wb = try gpa.create(Workbench);
        errdefer gpa.destroy(wb);
        const r = try gpa.dupe(u8, root);
        wb.* = .{
            .gpa = gpa,
            .io = io,
            .shell = shell,
            .root = r,
            .explorer = .init(gpa, io, r),
            .editors = .init(gpa, io),
            .quick = .{ .gpa = gpa, .io = io, .root = r },
            .panel = .{ .gpa = gpa, .io = io, .host = &shell.host },
            .scm = .init(gpa, io, r),
            .search = .init(gpa, io, r),
            .picker = .init(gpa, io),
            .review = .{ .gpa = gpa },
            .runner = .{ .gpa = gpa, .io = io },
        };
        wb.runner.ctx = wb;
        wb.runner.on_done = wbgit.onGitDone;
        wb.runner.window = shell.window;
        wb.search.window = shell.window;
        wb.quick.key_label = Shell.keyLabel;
        wb.quick.key_ctx = shell;
        wb.watcher = FsWatch.start(gpa, io, r, wb, onDiskChange);
        @import("jobs.zig").live(wb, gpa);
        return wb;
    }

    pub fn destroy(wb: *Workbench) void {
        @import("jobs.zig").gone(wb);
        if (wb.watcher) |w| w.stop();
        wb.editors.saveAll();
        wb.explorer.deinit();
        wb.editors.deinit();
        wb.quick.deinit();
        wb.panel.deinit();
        wb.scm.deinit();
        wb.search.deinit();
        wb.prompt.deinit();
        wb.picker.deinit();
        wb.review.deinit();
        wb.pending.deinit(wb.gpa);
        wb.confirm_arg.deinit(wb.gpa);
        wb.confirm_title.deinit(wb.gpa);
        wb.confirm_text.deinit(wb.gpa);
        wb.restore_branch.deinit(wb.gpa);
        wb.diff_comment.deinit(wb.gpa);
        if (wb.file_drag) |fd| wb.gpa.free(fd.path);
        wb.blame.deinit(wb.gpa);
        wb.gpa.free(wb.syms);
        wb.gpa.free(wb.syms_text);
        if (wb.logo) |l| wb.gpa.free(l.bytes);
        wb.gpa.free(wb.root);
        wb.gpa.destroy(wb);
    }

    fn onDiskChange(ctx: *anyopaque) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        const ch = if (wb.watcher) |w| w.take() else return;
        if (ch.files) {
            wb.explorer.refresh();
            wb.editors.reloadChanged();
        }
        if (ch.git or ch.files) wb.refreshGit();
        if (wb.shell.active() == wb) if (wb.shell.window) |w| w.redraw();
    }

    pub fn name(wb: *const Workbench) []const u8 {
        return std.fs.path.basename(wb.root);
    }

    pub fn queue(wb: *Workbench, cmd: Cmd) void {
        wb.pending.append(wb.gpa, cmd) catch return;
        if (wb.shell.window) |w| w.redraw();
    }

    pub fn statusColors(wb: *const Workbench) StatusColors {
        const p = wb.shell.palette;
        return .{ .modified = .hex(p.modified), .added = .hex(p.added), .deleted = .hex(p.removed), .conflict = .hex(p.danger), .muted = .hex(p.faint) };
    }

    pub fn refreshGit(wb: *Workbench) void {
        wb.scm.refresh();
        if (wb.scm.top) |top| wb.explorer.setChanges(top, wb.scm.changes) else wb.explorer.setChanges(wb.root, &.{});
        // Files' marks are made again against HEAD (it may have moved).
        for (wb.editors.cols.items) |col| for (col.items.items) |it| switch (it.body) {
            .file => |d| d.resetBase(),
            else => {},
        };
    }

    /// Asks a question in the window, then `wb_git.confirmed` acts on it.
    pub fn ask(wb: *Workbench, kind: Confirm, arg: []const u8, title: []const u8, text: []const u8, buttons: []const []const u8) void {
        wb.confirm_kind = kind;
        wb.confirm_arg.clearRetainingCapacity();
        wb.confirm_arg.appendSlice(wb.gpa, arg) catch {};
        wb.confirm_title.clearRetainingCapacity();
        wb.confirm_title.appendSlice(wb.gpa, title) catch {};
        wb.confirm_text.clearRetainingCapacity();
        wb.confirm_text.appendSlice(wb.gpa, text) catch {};
        wb.confirm_n = @min(buttons.len, 3);
        for (buttons[0..wb.confirm_n], 0..) |b, i| wb.confirm_buttons[i] = b;
        wb.confirm.show();
    }

    pub fn toastError(wb: *Workbench, title: []const u8, err: []const u8) void {
        _ = wb.toasts.add(.{ .title = title, .description = err, .kind = .@"error" });
    }

    /// The text of the open files with unsaved edits, for search.
    pub fn dirtyTexts(wb: *Workbench, a: std.mem.Allocator) []const [2][]const u8 {
        var out: std.ArrayList([2][]const u8) = .empty;
        for (wb.editors.cols.items) |col| for (col.items.items) |it| switch (it.body) {
            .file => |d| if (d.dirty() and d.path.len > 0) {
                const rel = a.dupe(u8, fs.relative(wb.root, d.path)) catch continue;
                std.mem.replaceScalar(u8, rel, '\\', '/');
                out.append(a, .{ rel, d.editor.area.text(a) }) catch {};
            },
            else => {},
        };
        return out.items;
    }

    /// The session to keep for the next start.
    pub fn session(wb: *Workbench, a: std.mem.Allocator) state_mod.Session {
        var cols: std.ArrayList(state_mod.ColumnState) = .empty;
        for (wb.editors.cols.items) |col| {
            var tabs: std.ArrayList(state_mod.TabState) = .empty;
            for (col.items.items) |it| switch (it.body) {
                .file => |d| if (d.path.len > 0) tabs.append(a, .{ .path = d.path, .caret = d.editor.area.sel.caret, .preview = it.preview, .wrap = d.own_wrap, .rendered = d.rendered }) catch {},
                .image => |im| tabs.append(a, .{ .path = im.path, .kind = "file", .preview = it.preview }) catch {},
                .changes => tabs.append(a, .{ .kind = "changes" }) catch {},
                .commit => |cv| tabs.append(a, .{ .kind = "commit", .path = cv.hash }) catch {},
                .terminal => |t| tabs.append(a, .{ .kind = "terminal", .path = t.dir }) catch {},
            };
            cols.append(a, .{ .tabs = tabs.items, .active = col.active, .width = col.width, .locked = col.locked }) catch {};
        }
        return .{
            .path = wb.root,
            .columns = cols.items,
            .focus = wb.editors.focus,
            .side = @tagName(wb.side),
            .sidebar_open = wb.sidebar_open,
            .sidebar_width = wb.sidebar_width,
            .panel_open = wb.panel.open,
            .panel_height = wb.panel.height,
            .open_folders = wb.explorer.openFolders(a),
        };
    }

    pub fn restore(wb: *Workbench, s: state_mod.Session) void {
        // The Changes tab and commits need the work tree's state.
        wb.refreshGit();
        wb.side = std.meta.stringToEnum(Side, s.side) orelse .explorer;
        wb.sidebar_open = s.sidebar_open;
        wb.sidebar_width = std.math.clamp(s.sidebar_width, 160, 800);
        wb.panel.height = std.math.clamp(s.panel_height, 80, 1200);
        wb.explorer.restoreOpen(s.open_folders);
        for (s.columns, 0..) |cs, ci| {
            if (ci > 0) _ = wb.editors.addColumn(ci) catch break;
            const col = wb.editors.cols.items[ci];
            col.locked = cs.locked;
            col.width = cs.width;
            wb.editors.focus = ci;
            for (cs.tabs) |ts| {
                if (std.mem.eql(u8, ts.kind, "file")) {
                    if (!fs.exists(wb.io, ts.path) or fs.isDirectory(wb.io, ts.path)) continue;
                    const it = wb.editors.openFile(ts.path, ts.preview) catch continue;
                    switch (it.body) {
                        .file => |d| {
                            const at = @min(ts.caret, d.editor.area.len());
                            d.editor.goToLine(d.editor.area.doc.lineOf(at) + 1);
                            d.editor.area.collapse(at);
                            d.own_wrap = ts.wrap;
                            d.rendered = ts.rendered;
                        },
                        else => {},
                    }
                } else if (std.mem.eql(u8, ts.kind, "changes")) {
                    wbgit.openChangesTab(wb, null, false);
                } else if (std.mem.eql(u8, ts.kind, "commit")) {
                    wbgit.openCommit(wb, ts.path, false);
                } else if (std.mem.eql(u8, ts.kind, "terminal")) {
                    wbfiles.newTerminalIn(wb, ci, null, ts.path);
                }
            }
            col.active = @min(cs.active, col.items.items.len -| 1);
        }
        wb.editors.focus = @min(s.focus, wb.editors.cols.items.len - 1);
        if (s.panel_open) wb.panel.open = true;
    }

    pub fn view(wb: *Workbench, c: *ui.Context) void {
        const sh = wb.shell;
        const p = sh.palette;
        const t = c.theme;
        doc_mod.colors = .{
            .added = .hex(p.added),
            .changed = .hex(p.changed),
            .removed = .hex(p.removed),
            .word = t.text.alpha(if (p.dark) 0.09 else 0.07),
            .current = .hex(p.added),
            .incoming = .hex(p.changed),
            .comment = .hex(p.modified),
        };
        if (wb.refresh_next) {
            wb.refresh_next = false;
            wb.editors.reloadChanged();
            wb.explorer.refresh();
            wb.refreshGit();
            wb.explorer.readIgnored(wb.scm.top);
        }
        wb.explorer.excludes = sh.store.s.filesExclude;
        wb.editors.auto_save = sh.store.s.autoSave;
        // Keys of keybindings.json first, then the window's own.
        wbeditor.keys(wb, c);
        while (wb.pending.items.len > 0) run_mod.run(wb, c, wb.pending.orderedRemove(0));
        wb.editors.tick(c);
        if (wb.editors.switched) {
            wb.editors.switched = false;
            sh.titleChanged();
        }
        if (wb.editors.request) |req| {
            wb.editors.request = null;
            wbfiles.tabRequest(wb, c, req);
        }
        if (wb.panel.request) |req| {
            wb.panel.request = null;
            wbfiles.panelRequest(wb, req);
        }

        const chrome: ui.Color = .hex(p.chrome);
        ui.column(c, .{ .width = .fill, .height = .fill, .background = t.background });
        {
            ui.row(c, .{ .width = .fill, .grow = 1, .align_items = .stretch });
            defer ui.end(c);
            const right = sh.store.s.sidebarRight;
            if (wb.sidebar_open and !(wb.panel.open and wb.panel.maximized)) {
                if (right) {
                    var other = @max(c.size.w - wb.sidebar_width, 200);
                    var sp = ui.split(c, &other, .{ .min = 160 });
                    wb.main(c, chrome);
                    sp.second();
                    wb.sidebar(c, chrome);
                    if (sp.end().changed) wb.sidebar_width = @max(c.size.w - other, 160);
                } else {
                    var sp = ui.split(c, &wb.sidebar_width, .{ .min = 160 });
                    wb.sidebar(c, chrome);
                    sp.second();
                    wb.main(c, chrome);
                    _ = sp.end();
                }
            } else wb.main(c, chrome);
        }
        wbeditor.statusBar(wb, c);
        ui.end(c);
        wb.editors.endDrag(c);
        wbfiles.fileDragFrame(wb, c);
        wbfiles.overlays(wb, c);
    }

    fn sidebar(wb: *Workbench, c: *ui.Context, chrome: ui.Color) void {
        const t = c.theme;
        ui.column(c, .{ .width = .fill, .height = .fill, .background = chrome });
        defer ui.end(c);
        {
            const head = ui.div(c).row().wFull().h(34).px(8).gap(2).itemsCenter();
            defer head.end();
            const views = [_]struct { label: []const u8, icon: []const u8, side: Side }{
                .{ .label = "EXPLORER", .icon = "doc.on.doc", .side = .explorer },
                .{ .label = "SEARCH", .icon = "magnifyingglass", .side = .search },
                .{ .label = "SOURCE CONTROL", .icon = "arrow.triangle.branch", .side = .scm },
            };
            for (views) |v| {
                const on = wb.side == v.side;
                const b = ui.div(c).row().h(24).px(6).gap(5).itemsCenter().rounded(4).hover(t.surface_hover);
                ui.icon(c, v.icon, .{ .size = 12, .color = if (on) t.text else t.muted });
                if (on) ui.text(c, v.label, .{ .size = 11, .weight = .semibold, .color = t.text });
                if (v.side == .scm and wb.scm.changes.len > 0)
                    ui.text(c, c.print("{d}", .{wb.scm.changes.len}), .{ .size = 10, .color = t.accent });
                if (b.clicked()) run_mod.run(wb, c, switch (v.side) {
                    .explorer => .show_explorer,
                    .search => .show_search,
                    .scm => .show_scm,
                });
                b.end();
            }
            ui.spacer(c);
            if (wb.side == .explorer and head.hovered()) {
                if (panel_mod.smallButton(c, "plus.square", false)) wbfiles.askNewFile(wb, wb.explorer.targetDir(), false);
                if (panel_mod.smallButton(c, "folder", false)) wbfiles.askNewFile(wb, wb.explorer.targetDir(), true);
                if (panel_mod.smallButton(c, "arrow.clockwise", false)) run_mod.run(wb, c, .refresh_explorer);
                if (panel_mod.smallButton(c, "rectangle.on.rectangle", false)) run_mod.run(wb, c, .collapse_folders);
            }
        }
        switch (wb.side) {
            .explorer => {
                // The folder's row.
                const top = ui.div(c).row().wFull().h(22).px(10).itemsCenter();
                ui.text(c, c.print("{s}", .{wb.name()}), .{ .size = 11, .weight = .semibold, .color = t.muted });
                if (top.clicked()) wb.explorer.state.selected = null;
                top.end();
                wbfiles.explorerEvent(wb, c, wb.explorer.view(c, .hex(wb.shell.palette.faint), wb.statusColors()));
            },
            .search => {
                if (wb.search.changed()) wb.search.start(wb.shell.store.s.filesExclude, wb.dirtyTexts(c.alloc()));
                wbfiles.searchEvent(wb, c, wb.search.view(c));
            },
            .scm => wbgit.scmEvent(wb, c, wb.scm.view(c, wb.runner.busy, wb.statusColors())),
        }
    }

    fn main(wb: *Workbench, c: *ui.Context, chrome: ui.Color) void {
        ui.column(c, .{ .width = .fill, .height = .fill });
        defer ui.end(c);
        if (wb.panel.open and wb.panel.maximized) {
            wb.panel.view(c, wb.shell.profiles, wb.shell.defaultProfile(), chrome);
            return;
        }
        if (wb.panel.open) {
            // The split's size is the first pane's: the panel is the second.
            const room = c.size.h - 24;
            var first = @max(room - wb.panel.height, 80);
            var sp = ui.split(c, &first, .{ .vertical = true, .min = 80 });
            wbeditor.columnsView(wb, c, chrome);
            sp.second();
            wb.panel.view(c, wb.shell.profiles, wb.shell.defaultProfile(), chrome);
            if (sp.end().changed) wb.panel.height = @max(room - first, 80);
        } else wbeditor.columnsView(wb, c, chrome);
    }
};
