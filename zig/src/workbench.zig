//! The workbench: the sidebar (Explorer or Source Control), the editor's
//! tabs, the terminal panel and the status bar, for one folder.
const std = @import("std");
const builtin = @import("builtin");
const myzig = @import("myzig");
const ui = myzig.ui;
const fs = @import("fs.zig");
const git = @import("git.zig");
const commands = @import("commands.zig");
const Cmd = commands.Cmd;
const Explorer = @import("explorer.zig").Explorer;
const Tabs = @import("tabs.zig").Tabs;
const QuickOpen = @import("quickopen.zig").QuickOpen;
const Panel = @import("panel.zig").Panel;
const Scm = @import("scm.zig").Scm;

pub const ThemeMode = enum { system, light, dark };

pub const Workbench = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    app: *myzig.App,
    /// The folder, absolute.
    root: []u8,
    window: ?*myzig.Window = null,
    explorer: Explorer,
    tabs: Tabs,
    quick: QuickOpen,
    panel: Panel,
    scm: Scm,
    sidebar_open: bool = true,
    sidebar_width: f32 = 260,
    side: enum { explorer, scm } = .explorer,
    theme_mode: ThemeMode = .system,
    /// Commands from the menu bar, run at the next frame.
    pending: std.ArrayList(Cmd) = .empty,
    toasts: ui.Toasts = .{},
    branch: ?[]u8 = null,
    /// The window's title, kept until the next one is set.
    title: ?[]u8 = null,
    /// Refresh Git and the files at the next frame (the window took the keyboard).
    refresh_next: bool = true,

    pub fn create(gpa: std.mem.Allocator, io: std.Io, app: *myzig.App, root: []const u8) !*Workbench {
        const wb = try gpa.create(Workbench);
        const r = try gpa.dupe(u8, root);
        wb.* = .{
            .gpa = gpa,
            .io = io,
            .app = app,
            .root = r,
            .explorer = .init(gpa, io, r),
            .tabs = .{ .gpa = gpa, .io = io },
            .quick = .{ .gpa = gpa, .io = io, .root = r },
            .panel = .{ .gpa = gpa, .io = io, .root = r },
            .scm = .{ .gpa = gpa, .io = io, .root = r },
        };
        wb.panel.prepare();
        return wb;
    }

    pub fn destroy(wb: *Workbench) void {
        wb.tabs.saveAll();
        wb.explorer.deinit();
        wb.tabs.deinit();
        wb.quick.deinit();
        wb.panel.deinit();
        wb.scm.deinit();
        wb.pending.deinit(wb.gpa);
        if (wb.branch) |b| wb.gpa.free(b);
        if (wb.title) |t| wb.gpa.free(t);
        wb.gpa.free(wb.root);
        wb.gpa.destroy(wb);
    }

    pub fn attach(wb: *Workbench, w: *myzig.Window) void {
        wb.window = w;
        wb.panel.window = w;
        wb.scm.window = w;
    }

    /// Queues a command from outside the view (the menu bar).
    pub fn queue(wb: *Workbench, cmd: Cmd) void {
        wb.pending.append(wb.gpa, cmd) catch return;
        if (wb.window) |w| w.redraw();
    }

    pub fn onWindowEvent(wb: *Workbench, w: *myzig.Window, ev: myzig.WindowEvent) void {
        switch (ev) {
            // Auto save when the window loses the keyboard; look again when it comes back.
            .blur => if (wb.tabs.auto_save) wb.tabs.saveAll(),
            .focus => {
                wb.refresh_next = true;
                w.redraw();
            },
            else => {},
        }
    }

    pub fn onDrop(wb: *Workbench, w: *myzig.Window, paths: []const []const u8) void {
        for (paths) |p| if (!fs.isDirectory(wb.io, p)) {
            _ = wb.tabs.open(p, false) catch {};
        };
        w.redraw();
    }

    /// Opens a file in a tab, noting it for quick open and revealing it.
    pub fn openFile(wb: *Workbench, path: []const u8, preview: bool) void {
        _ = wb.tabs.open(path, preview) catch |err| {
            _ = wb.toasts.add(.{ .title = "Couldn't open the file", .description = @errorName(err), .kind = .@"error" });
            return;
        };
        wb.quick.noteOpened(fs.relative(wb.root, path));
    }

    pub fn refreshGit(wb: *Workbench) void {
        if (wb.branch) |b| wb.gpa.free(b);
        wb.branch = git.branch(wb.gpa, wb.io, wb.root);
        wb.scm.refresh();
        if (wb.scm.top) |top| wb.explorer.setChanges(top, wb.scm.changes) else wb.explorer.setChanges(wb.root, &.{});
    }

    pub fn run(wb: *Workbench, c: *ui.Context, cmd: Cmd) void {
        c.changed = true;
        const cur = wb.tabs.current();
        switch (cmd) {
            .new_file => wb.tabs.newUntitled() catch {},
            .open_folder => wb.openFolder(),
            .save => if (cur) |t| {
                if (t.path.len == 0) wb.saveAs(t) else wb.tabs.save(t) catch |err| {
                    _ = wb.toasts.add(.{ .title = "Couldn't save", .description = @errorName(err), .kind = .@"error" });
                };
                wb.refreshGit();
            },
            .save_as => if (cur) |t| wb.saveAs(t),
            .save_all => {
                wb.tabs.saveAll();
                wb.refreshGit();
            },
            .close_tab => if (wb.tabs.list.items.len > 0) wb.tabs.close(wb.tabs.active),
            .reopen_tab => wb.tabs.reopenClosed(),
            .toggle_auto_save => {
                wb.tabs.auto_save = !wb.tabs.auto_save;
                _ = wb.toasts.show(if (wb.tabs.auto_save) "Auto Save is on" else "Auto Save is off");
            },
            .quit => wb.app.quit(),
            .find => if (cur) |t| t.editor.openFind(false),
            .replace => if (cur) |t| t.editor.openFind(true),
            .go_to_line => wb.quick.show(":"),
            .quick_open => wb.quick.show(""),
            .command_palette => wb.quick.show(">"),
            .toggle_sidebar => wb.sidebar_open = !wb.sidebar_open,
            .show_explorer => {
                wb.sidebar_open = true;
                wb.side = .explorer;
            },
            .show_scm => {
                wb.sidebar_open = true;
                wb.side = .scm;
                wb.refreshGit();
            },
            .toggle_terminal => wb.panel.toggle(),
            .new_terminal => wb.panel.newTerminal(),
            .toggle_wrap => if (cur) |t| {
                t.editor.wrap = !t.editor.wrap;
            },
            .theme_system => wb.theme_mode = .system,
            .theme_light => wb.theme_mode = .light,
            .theme_dark => wb.theme_mode = .dark,
            .next_tab => if (wb.tabs.list.items.len > 0) wb.tabs.show((wb.tabs.active + 1) % wb.tabs.list.items.len),
            .prev_tab => if (wb.tabs.list.items.len > 0) wb.tabs.show((wb.tabs.active + wb.tabs.list.items.len - 1) % wb.tabs.list.items.len),
            .refresh_explorer => wb.explorer.refresh(),
            .collapse_folders => wb.explorer.collapseAll(),
            .reveal_active => if (cur) |t| if (t.path.len > 0) {
                wb.sidebar_open = true;
                wb.side = .explorer;
                wb.explorer.reveal(t.path);
            },
            .copy_path => if (cur) |t| {
                _ = myzig.clipboard.writeText(t.path);
            },
            .copy_relative_path => if (cur) |t| {
                _ = myzig.clipboard.writeText(fs.relative(wb.root, t.path));
            },
            .reveal_in_os => if (cur) |t| if (t.path.len > 0) myzig.shell.showInFolder(t.path),
            .git_refresh => wb.refreshGit(),
        }
    }

    fn openFolder(wb: *Workbench) void {
        const paths = (myzig.dialog.open(wb.gpa, .{ .title = "Open Folder", .files = false, .directories = true }) catch return) orelse return;
        defer myzig.dialog.freePaths(wb.gpa, paths);
        if (paths.len == 0) return;
        // A folder opens in a new process, as `mycode <dir>` does.
        const exe = std.process.executablePathAlloc(wb.io, wb.gpa) catch return;
        defer wb.gpa.free(exe);
        var child = std.process.spawn(wb.io, .{ .argv = &.{ exe, paths[0] }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch return;
        _ = &child;
    }

    fn saveAs(wb: *Workbench, t: *@import("tabs.zig").Tab) void {
        const path = (myzig.dialog.save(wb.gpa, .{ .directory = wb.root, .name = t.name() }) catch return) orelse return;
        defer wb.gpa.free(path);
        wb.tabs.saveAs(t, path) catch |err| {
            _ = wb.toasts.add(.{ .title = "Couldn't save", .description = @errorName(err), .kind = .@"error" });
        };
    }

    fn applyTheme(wb: *Workbench, c: *ui.Context) void {
        const dark = switch (wb.theme_mode) {
            .system => c.theme.dark,
            .light => false,
            .dark => true,
        };
        var th = if (dark) ui.Theme.dark_theme else ui.Theme.light;
        if (dark) {
            th.background = .hex(0x1e1f22);
            th.surface = .hex(0x181a1c);
            th.surface_hover = .hex(0x2b2d31);
            th.border = .hex(0x2f3136);
        }
        ui.themes.apply(c, th);
    }

    fn updateTitle(wb: *Workbench) void {
        if (!wb.tabs.switched) return;
        wb.tabs.switched = false;
        const w = wb.window orelse return;
        const folder = std.fs.path.basename(wb.root);
        const title = if (wb.tabs.current()) |t|
            std.fmt.allocPrint(wb.gpa, "{s} — {s} — MyCode", .{ t.name(), folder }) catch return
        else
            std.fmt.allocPrint(wb.gpa, "{s} — MyCode", .{folder}) catch return;
        w.setTitle(title);
        if (wb.title) |old| wb.gpa.free(old);
        wb.title = title;
    }

    pub fn view(wb: *Workbench, c: *ui.Context) void {
        wb.applyTheme(c);
        const t = c.theme;
        if (wb.refresh_next) {
            wb.refresh_next = false;
            wb.tabs.reloadChanged();
            wb.explorer.refresh();
            wb.refreshGit();
        }
        while (wb.pending.items.len > 0) wb.run(c, wb.pending.orderedRemove(0));
        wb.tabs.tick(c);
        wb.updateTitle();

        ui.column(c, .{ .width = .fill, .height = .fill, .background = t.background });
        {
            ui.row(c, .{ .width = .fill, .grow = 1, .align_items = .stretch });
            defer ui.end(c);
            if (wb.sidebar_open) {
                var sp = ui.split(c, &wb.sidebar_width, .{ .min = 160 });
                wb.sidebar(c);
                sp.second();
                wb.main(c);
                _ = sp.end();
            } else wb.main(c);
        }
        wb.statusBar(c);
        ui.end(c);

        if (wb.quick.view(c)) |pick| switch (pick) {
            .file => |rel| {
                const abs = std.fs.path.join(wb.gpa, &.{ wb.root, rel }) catch return;
                defer wb.gpa.free(abs);
                if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, abs, '/', std.fs.path.sep);
                wb.openFile(abs, false);
                c.changed = true;
            },
            .command => |cmd| wb.run(c, cmd),
            .line => |line| if (wb.tabs.current()) |tab| {
                tab.editor.goToLine(line);
                c.changed = true;
            },
        };
        _ = ui.toasts(c, &wb.toasts);
    }

    fn sidebar(wb: *Workbench, c: *ui.Context) void {
        const t = c.theme;
        ui.column(c, .{ .width = .fill, .height = .fill, .background = t.surface });
        defer ui.end(c);
        {
            const head = ui.div(c).row().wFull().h(34).px(10).gap(4).itemsCenter();
            defer head.end();
            const views = [_]struct { label: []const u8, icon: []const u8, side: @TypeOf(wb.side) }{
                .{ .label = "EXPLORER", .icon = "doc.on.doc", .side = .explorer },
                .{ .label = "SOURCE CONTROL", .icon = "arrow.triangle.branch", .side = .scm },
            };
            for (views) |v| {
                const on = wb.side == v.side;
                const b = ui.div(c).row().h(24).px(6).gap(5).itemsCenter().rounded(4).hover(t.surface_hover);
                ui.icon(c, v.icon, .{ .size = 12, .color = if (on) t.text else t.muted });
                if (on) ui.text(c, v.label, .{ .size = 11, .weight = .semibold, .color = t.text });
                if (v.side == .scm and wb.scm.changes.len > 0)
                    ui.text(c, c.print("{d}", .{wb.scm.changes.len}), .{ .size = 10, .color = t.accent });
                if (b.clicked()) {
                    wb.side = v.side;
                    if (v.side == .scm) wb.refreshGit();
                }
                b.end();
            }
            ui.spacer(c);
            if (wb.side == .explorer) {
                if (iconButton(c, "plus.square", "New File")) wb.run(c, .new_file);
                if (iconButton(c, "arrow.clockwise", "Refresh")) wb.run(c, .refresh_explorer);
                if (iconButton(c, "rectangle.on.rectangle", "Collapse Folders")) wb.run(c, .collapse_folders);
            } else {
                if (iconButton(c, "arrow.clockwise", "Refresh")) wb.refreshGit();
            }
        }
        switch (wb.side) {
            .explorer => if (wb.explorer.view(c)) |o| {
                wb.openFile(o.path, o.preview);
                c.changed = true;
            },
            .scm => if (wb.scm.view(c)) |rel| {
                const top = wb.scm.top orelse wb.root;
                const abs = @import("explorer.zig").joinNative(wb.gpa, top, rel) catch return;
                defer wb.gpa.free(abs);
                if (!fs.exists(wb.io, abs)) return;
                wb.openFile(abs, true);
                c.changed = true;
            },
        }
        if (wb.scm.committed) {
            wb.scm.committed = false;
            wb.refreshGit();
            _ = wb.toasts.add(.{ .title = "Committed", .kind = .success });
        }
    }

    fn main(wb: *Workbench, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill });
        defer ui.end(c);
        if (wb.panel.open) {
            var sp = ui.split(c, &wb.panel.height, .{ .vertical = true, .min = 80 });
            wb.editorArea(c);
            sp.second();
            wb.panel.view(c);
            _ = sp.end();
        } else wb.editorArea(c);
    }

    fn editorArea(wb: *Workbench, c: *ui.Context) void {
        const t = c.theme;
        ui.column(c, .{ .width = .fill, .height = .fill });
        defer ui.end(c);
        const tab = wb.tabs.current() orelse return wb.welcome(c);
        wb.tabs.strip(c);
        const crumbs = ui.div(c).row().wFull().h(24).px(12).gap(4).itemsCenter();
        const rel = if (tab.path.len == 0) "Untitled" else fs.relative(wb.root, tab.path);
        var it = std.mem.tokenizeAny(u8, rel, "/\\");
        var first = true;
        while (it.next()) |part| {
            if (!first) ui.icon(c, "chevron.right", .{ .size = 8, .color = t.muted });
            first = false;
            ui.text(c, part, .{ .size = 12, .color = t.muted });
        }
        crumbs.end();
        c.keyed(tab);
        _ = ui.codeEditor(c, &tab.editor, .{ .size = 13 });
    }

    fn welcome(wb: *Workbench, c: *ui.Context) void {
        const t = c.theme;
        ui.column(c, .{ .width = .fill, .height = .fill, .align_items = .center, .justify = .center, .gap = 10 });
        defer ui.end(c);
        ui.text(c, "MyCode", .{ .size = 40, .weight = .bold, .color = t.muted });
        ui.text(c, std.fs.path.basename(wb.root), .{ .size = 14, .color = t.muted });
        _ = c.leaf(.{ .height = .{ .px = 12 } }, .none, null);
        const rows = [_]struct { label: []const u8, keys: []const u8, cmd: Cmd }{
            .{ .label = "Go to File", .keys = ui.keys.label("⌘P"), .cmd = .quick_open },
            .{ .label = "Show All Commands", .keys = ui.keys.label("⇧⌘P"), .cmd = .command_palette },
            .{ .label = "Open Folder", .keys = ui.keys.label("⌘O"), .cmd = .open_folder },
            .{ .label = "Toggle Terminal", .keys = "Ctrl+`", .cmd = .toggle_terminal },
        };
        for (rows) |r| {
            const row = ui.div(c).row().w(300).h(26).px(8).gap(8).itemsCenter().rounded(4).hover(t.surface_hover);
            ui.text(c, r.label, .{ .size = 13, .color = t.muted });
            ui.spacer(c);
            ui.text(c, r.keys, .{ .size = 12, .color = t.muted, .mono = true });
            if (row.clicked()) wb.run(c, r.cmd);
            row.end();
        }
    }

    fn statusBar(wb: *Workbench, c: *ui.Context) void {
        const t = c.theme;
        const bar = ui.div(c).row().wFull().h(24).px(8).gap(14).itemsCenter().bg(t.surface);
        defer bar.end();
        if (wb.branch) |b| {
            const br = ui.div(c).row().h(20).px(4).gap(4).itemsCenter().rounded(3).hover(t.surface_hover);
            ui.icon(c, "arrow.triangle.branch", .{ .size = 11, .color = t.muted });
            ui.text(c, b, .{ .size = 12, .color = t.muted });
            if (br.clicked()) wb.run(c, .show_scm);
            br.end();
        }
        if (wb.scm.changes.len > 0) ui.text(c, c.print("{d} changes", .{wb.scm.changes.len}), .{ .size = 12, .color = t.muted });
        ui.spacer(c);
        const tab = wb.tabs.current() orelse return;
        const ta = &tab.editor.area;
        const line = ta.caretLine();
        const col = ta.sel.caret - ta.doc.lineStart(line);
        if (statusItem(c, c.print("Ln {d}, Col {d}", .{ line + 1, col + 1 }))) wb.run(c, .go_to_line);
        const unit = tab.editor.indent.unit;
        if (statusItem(c, if (std.mem.eql(u8, unit, "\t")) "Tab Size: 4" else c.print("Spaces: {d}", .{unit.len})))
            tab.editor.indent.unit = if (std.mem.eql(u8, unit, "\t")) "    " else "\t";
        if (statusItem(c, if (tab.crlf) "CRLF" else "LF")) {
            tab.crlf = !tab.crlf;
            tab.saved +%= 1; // the line endings changed: save writes them
        }
        if (statusItem(c, if (tab.editor.wrap) "Wrap" else "No Wrap")) tab.editor.wrap = !tab.editor.wrap;
        _ = statusItem(c, @import("icons.zig").languageName(tab.name()));
        if (statusItem(c, if (wb.tabs.auto_save) "Auto Save" else "Auto Save Off")) wb.run(c, .toggle_auto_save);
    }
};

fn statusItem(c: *ui.Context, label: []const u8) bool {
    const it = ui.div(c).row().h(20).px(4).itemsCenter().rounded(3).hover(c.theme.surface_hover);
    ui.text(c, label, .{ .size = 12, .color = c.theme.muted });
    const clicked = it.clicked();
    it.end();
    return clicked;
}

pub fn iconButton(c: *ui.Context, icon: []const u8, _: []const u8) bool {
    const b = ui.div(c).w(22).h(22).center().rounded(4).hover(c.theme.surface_hover);
    ui.icon(c, icon, .{ .size = 12, .color = c.theme.muted });
    const clicked = b.clicked();
    b.end();
    return clicked;
}
