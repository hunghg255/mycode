//! A window: its projects (a rail of them on the left with project tabs on),
//! the theme, and the window's own commands: folders, settings, zoom,
//! themes. The app's state (settings, keys, recent folders) is `Main`'s.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const termlinks = @import("termlinks.zig");
const fs = @import("fs.zig");
const commands = @import("commands.zig");
const Cmd = commands.Cmd;
const themes = @import("themes.zig");
const Workbench = @import("workbench.zig").Workbench;
const Main = @import("main.zig").Main;
const panel_mod = @import("panel.zig");
const Profile = @import("termprofiles.zig").Profile;
const keymap = @import("keymap.zig");
const icons = @import("icons.zig");
const quickopen = @import("quickopen.zig");
const winshell = @import("winshell.zig");

const Dialog = enum { none, folder, folder_new_window, file };

pub const Shell = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    main: *Main,
    store: *@import("settings.zig").Store,
    state: *@import("state.zig").State,
    keymap: *keymap.Keymap,
    profiles: []const Profile,
    window: ?*myzig.Window = null,
    host: panel_mod.Host,
    projects: std.ArrayList(*Workbench) = .empty,
    current: usize = 0,
    palette: *const themes.Palette = themes.palette("", true),
    title: ?[]u8 = null,
    title_dirty: bool = true,
    rail_menu: ui.Menu = .{},
    rail_at: usize = 0,
    /// The square under the pointer.
    rail_hot: ?usize = null,
    /// A square of the rail pressed, dragged to another place.
    rail_drag: ?struct { from: usize, start: ui.Point, moving: bool = false } = null,
    /// The squares as last laid out, for where a drag lets go.
    rail_rects: [32]ui.Rect = undefined,
    manage_menu: ui.Menu = .{},
    recent: ui.OverlayState = .{},
    recent_query: ui.TextBuffer = .{},
    recent_sel: usize = 0,
    /// Builds left in which the field takes the keyboard: the dialog
    /// clears the focus as it opens.
    recent_focus: u8 = 0,
    zoom: f32 = 1,
    rain: @import("rain.zig").Rain = .{},
    /// The window has the keyboard (the rain moves only then).
    has_focus: bool = true,
    /// An open dialog asked for, shown after the frame (`askLater`).
    dialog: Dialog = .none,
    /// The family of `fontFamily`'s list that is installed, for the
    /// settings' version it was looked for in.
    mono_family: ?[]const u8 = null,
    /// The keybindings.json load whose errors were told.
    keys_told: u32 = 0,
    mono_version: u64 = 0,
    /// Where the pointer was last seen over the window (where files dropped).
    last_mouse: ui.Point = .{ .x = -1, .y = -1 },

    pub fn create(main: *Main) !*Shell {
        const sh = try main.gpa.create(Shell);
        sh.* = .{
            .gpa = main.gpa,
            .io = main.io,
            .main = main,
            .store = &main.store,
            .state = &main.state,
            .keymap = &main.keymap,
            .profiles = main.profiles,
            .host = .{ .ctx = undefined, .open_link = openLink },
        };
        sh.host.ctx = sh;
        sh.host.prepare(main.gpa, main.io);
        return sh;
    }

    pub fn destroy(sh: *Shell) void {
        for (sh.projects.items) |wb| wb.destroy();
        sh.projects.deinit(sh.gpa);
        if (sh.title) |t| sh.gpa.free(t);
        sh.gpa.destroy(sh);
    }

    pub fn attach(sh: *Shell, w: *myzig.Window) void {
        sh.window = w;
        sh.host.window = w;
        for (sh.projects.items) |wb| {
            wb.runner.window = w;
            wb.search.window = w;
        }
    }

    pub fn active(sh: *Shell) ?*Workbench {
        if (sh.projects.items.len == 0) return null;
        return sh.projects.items[@min(sh.current, sh.projects.items.len - 1)];
    }

    pub fn queue(sh: *Shell, cmd: Cmd) void {
        if (sh.active()) |wb| wb.queue(cmd);
    }

    pub fn titleChanged(sh: *Shell) void {
        sh.title_dirty = true;
    }

    /// Adds a project for a folder, or shows it when it is here.
    pub fn addProject(sh: *Shell, root: []const u8) !*Workbench {
        for (sh.projects.items, 0..) |wb, i| if (std.mem.eql(u8, wb.root, root)) {
            sh.show(i);
            return wb;
        };
        const wb = try Workbench.create(sh, root);
        if (sh.state.session(root)) |s| wb.restore(s) else if (sh.active()) |cur| {
            // A new project starts with the layout of the one shown.
            wb.sidebar_open = cur.sidebar_open;
            wb.sidebar_width = cur.sidebar_width;
            wb.panel.height = cur.panel.height;
        }
        try sh.projects.append(sh.gpa, wb);
        sh.state.noteRecent(root);
        sh.show(sh.projects.items.len - 1);
        if (sh.window) |w| {
            wb.runner.window = w;
            wb.search.window = w;
        }
        return wb;
    }

    pub fn show(sh: *Shell, i: usize) void {
        if (i >= sh.projects.items.len) return;
        // Leaving a project saves its files.
        if (sh.active()) |cur| if (sh.store.s.autoSave) cur.editors.saveAll();
        sh.current = i;
        sh.projects.items[i].bell = false;
        sh.projects.items[i].refresh_next = true;
        sh.title_dirty = true;
        if (sh.window) |w| w.redraw();
    }

    /// Closes a project, asking first about each change it would lose.
    pub fn closeProject(sh: *Shell, wb: *Workbench) void {
        if (sh.store.s.autoSave) wb.editors.saveAll();
        if (wb.editors.askAll()) {
            wb.close_then = .close_project;
            if (std.mem.indexOfScalar(*Workbench, sh.projects.items, wb)) |i| sh.show(i);
            return;
        }
        sh.closeProjectNow(wb);
    }

    /// Whether the window may close now: its projects' changes are saved,
    /// or asked about first (the window closes once they are settled).
    pub fn mayClose(sh: *Shell, _: *myzig.Window) bool {
        return !sh.settle(.close_window);
    }

    /// Closes the window once nothing would be lost (`mayClose`).
    pub fn tryClose(sh: *Shell) void {
        if (sh.settle(.close_window)) return;
        if (sh.window) |w| w.close();
    }

    /// Saves what auto save saves, then asks about the first project's
    /// changes that would be lost, `then` waiting for them; true if it asks.
    pub fn settle(sh: *Shell, then: @FieldType(Workbench, "close_then")) bool {
        for (sh.projects.items, 0..) |wb, i| {
            if (sh.store.s.autoSave) wb.editors.saveAll();
            if (wb.editors.askAll()) {
                wb.close_then = then;
                sh.show(i);
                if (sh.window) |w| w.focus();
                return true;
            }
        }
        return false;
    }

    pub fn closeProjectNow(sh: *Shell, wb: *Workbench) void {
        const i = std.mem.indexOfScalar(*Workbench, sh.projects.items, wb) orelse return;
        sh.main.keepSession(wb);
        _ = sh.projects.orderedRemove(i);
        wb.destroy();
        if (sh.projects.items.len == 0) {
            if (sh.window) |w| w.close();
            return;
        }
        sh.current = @min(sh.current, sh.projects.items.len - 1);
        sh.title_dirty = true;
        sh.main.saveState();
    }

    /// Opens a folder: as a project here, or in a window of its own.
    pub fn openFolder(sh: *Shell, path: []const u8, new_window: bool) void {
        if (!fs.isDirectory(sh.io, path)) return;
        if (sh.main.focusFolder(path)) return;
        if (new_window or !sh.store.s.projectTabs) {
            if (!sh.store.s.projectTabs and !new_window and sh.projects.items.len == 1) {
                // Without project tabs a folder takes the window's place.
                const old = sh.projects.items[0];
                sh.main.keepSession(old);
                _ = sh.projects.orderedRemove(0);
                old.destroy();
                _ = sh.addProject(path) catch {};
                return;
            }
            sh.main.newWindow(&.{path}) catch {};
            return;
        }
        _ = sh.addProject(path) catch {};
        sh.main.saveState();
    }

    pub fn defaultProfile(sh: *const Shell) usize {
        const want = sh.store.s.terminalProfile;
        for (sh.profiles, 0..) |p, i| if (std.mem.eql(u8, p.name, want)) return i;
        return 0;
    }

    pub fn setDefaultProfile(sh: *Shell, i: usize) void {
        if (i < sh.profiles.len) sh.store.setString("terminalProfile", sh.profiles[i].name);
    }

    /// settings.json and keybindings.json apply as they are saved here.
    pub fn fileSaved(sh: *Shell, path: []const u8) void {
        if (std.ascii.eqlIgnoreCase(path, sh.store.settings_path)) _ = sh.store.reload();
        if (std.ascii.eqlIgnoreCase(path, sh.store.keys_path)) sh.main.loadKeys();
    }

    /// A check by a command in the palette that has its setting on.
    pub fn isOn(ctx: *anyopaque, cmd: Cmd) bool {
        const sh: *Shell = @ptrCast(@alignCast(ctx));
        return @import("menubar.zig").isOn(cmd, &sh.store.s) orelse false;
    }

    /// A key shown by a command in the palette: keybindings.json's, or its own.
    pub fn keyLabel(ctx: *anyopaque, c: *ui.Context, cmd: Cmd) []const u8 {
        const sh: *Shell = @ptrCast(@alignCast(ctx));
        if (sh.keymap.keyFor(cmd)) |k| return ui.shortcutLabel(c, k.shortcut());
        const inf = commands.info(cmd);
        if (inf.accel.len > 0) return if (sh.keymap.takesAccel(inf.accel, cmd)) "" else quickopen.accelLabel(c, inf.accel);
        if (inf.key.len > 0) return keyText(c, inf.key);
        return "";
    }

    fn keyText(c: *ui.Context, k: []const u8) []const u8 {
        if (ui.keys.mac) return k;
        var out: std.ArrayList(u8) = .empty;
        const a = c.alloc();
        const utf8 = std.unicode.Utf8View.init(k) catch return k;
        var it = utf8.iterator();
        while (it.nextCodepointSlice()) |cp| {
            const r: []const u8 = if (std.mem.eql(u8, cp, "⌘")) "Ctrl+" else if (std.mem.eql(u8, cp, "⌃")) "Ctrl+" else if (std.mem.eql(u8, cp, "⌥")) "Alt+" else if (std.mem.eql(u8, cp, "⇧")) "Shift+" else if (std.mem.eql(u8, cp, "↑")) "Up" else if (std.mem.eql(u8, cp, "↓")) "Down" else if (std.mem.eql(u8, cp, "↵")) "Enter" else cp;
            out.appendSlice(a, r) catch {};
        }
        return out.items;
    }

    /// Opens what a Ctrl+click on a terminal's link names, as the Go app's
    /// `openTermLink`: a file at its line and column, or a folder of the
    /// project in the Explorer; false leaves a URL to the browser.
    fn openLink(ctx: *anyopaque, link: []const u8, is_path: bool, dirs: []const []const u8) bool {
        const sh: *Shell = @ptrCast(@alignCast(ctx));
        const wb = sh.active() orelse return false;
        const home = sh.main.env.get("USERPROFILE") orelse sh.main.env.get("HOME") orelse "";
        var buf: [4096]u8 = undefined;
        const target = termlinks.target(link, is_path, home, &buf) orelse return false;
        // A relative path is the program's, as of where the shell is now,
        // or else where it started, or the project.
        var abs: ?[]u8 = null;
        defer if (abs) |a| sh.gpa.free(a);
        if (std.fs.path.isAbsolute(target.path)) {
            abs = sh.gpa.dupe(u8, target.path) catch return false;
            if (!fs.exists(sh.io, abs.?)) return false;
        } else for ([_][]const u8{ if (dirs.len > 0) dirs[0] else "", if (dirs.len > 1) dirs[1] else "", wb.root }) |dir| {
            if (dir.len == 0) continue;
            const p = std.fs.path.join(sh.gpa, &.{ dir, target.path }) catch continue;
            if (fs.exists(sh.io, p)) {
                abs = p;
                break;
            }
            sh.gpa.free(p);
        }
        const path = abs orelse return false;
        const line = target.line;
        if (fs.isDirectory(sh.io, path)) {
            if (fs.relative(wb.root, path).ptr == path.ptr) return false;
            const abs_dir = path;
            wb.sidebar_open = true;
            wb.side = .explorer;
            wb.explorer.reveal(abs_dir);
            return true;
        }
        const it = wb.editors.openFile(path, false) catch return false;
        switch (it.body) {
            .file => |d| if (line > 0) {
                d.editor.goToLine(line);
                if (target.col > 1) {
                    const ta = &d.editor.area;
                    const l = ta.caretLine();
                    ta.collapse(@min(ta.doc.lineStart(l) + target.col - 1, ta.lineRange(l)[1]));
                }
            },
            else => {},
        }
        if (sh.window) |w| w.redraw();
        return true;
    }

    /// The window's own commands; false for a project's.
    pub fn run(sh: *Shell, c: *ui.Context, cmd: Cmd) bool {
        const st = sh.store;
        switch (cmd) {
            .open_folder, .open_folder_new_window, .open_file => sh.askLater(switch (cmd) {
                .open_folder => .folder,
                .open_folder_new_window => .folder_new_window,
                else => .file,
            }),
            .open_recent => {
                sh.recent_query.clear();
                sh.recent_sel = 0;
                sh.recent_focus = 6;
                sh.recent.show();
            },
            .open_settings => if (sh.active()) |wb| {
                if (!fs.exists(sh.io, st.settings_path)) fs.write(sh.io, st.settings_path, "{\n}\n") catch {};
                _ = wb.editors.openFile(st.settings_path, false) catch {};
            },
            .open_keybindings => if (sh.active()) |wb| {
                _ = wb.editors.openFile(st.keys_path, false) catch {};
            },
            .install_command, .uninstall_command => {
                if (!winshell.supported) {
                    if (sh.active()) |wb| _ = wb.toasts.show("Only on Windows, so far");
                    return true;
                }
                const exe = std.process.executablePathAlloc(sh.io, sh.gpa) catch return true;
                defer sh.gpa.free(exe);
                if (cmd == .install_command) {
                    const ok = winshell.ensure(sh.gpa, sh.io, sh.main.env, st.dir, exe, true);
                    if (sh.active()) |wb| _ = wb.toasts.show(if (ok) "Installed: open a new terminal to use 'mycode'" else "Couldn't install the command");
                } else {
                    winshell.uninstall(sh.gpa, sh.io, sh.main.env, st.dir);
                    if (sh.active()) |wb| _ = wb.toasts.show("The command and the Explorer menu are gone");
                }
            },
            .quit => sh.main.quit(),
            .zoom_in => st.setNumber("fontSize", @min(st.s.fontSize + 1, 28)),
            .zoom_out => st.setNumber("fontSize", @max(st.s.fontSize - 1, 9)),
            .zoom_reset => st.setNumber("fontSize", 13),
            .theme_mycode => st.setString("theme", ""),
            .theme_matrix => st.setString("theme", "matrix"),
            .theme_claude => st.setString("theme", "claude"),
            .theme_qoder => st.setString("theme", "qoder"),
            .icons_material => st.setString("iconTheme", ""),
            .icons_lucide => st.setString("iconTheme", "lucide"),
            .appearance_system => st.setString("appearance", ""),
            .appearance_light => st.setString("appearance", "light"),
            .appearance_dark => st.setString("appearance", "dark"),
            .toggle_sidebar_right => st.setBool("sidebarRight", !st.s.sidebarRight),
            .toggle_minimap => st.setBool("minimap", !st.s.minimap),
            .toggle_project_icons => st.setBool("projectIcons", !st.s.projectIcons),
            .toggle_project_tabs => {
                st.setBool("projectTabs", !st.s.projectTabs);
                sh.main.regroup();
            },
            .next_project, .prev_project => {
                const n = sh.projects.items.len;
                if (n > 1) sh.show(if (cmd == .next_project) (sh.current + 1) % n else (sh.current + n - 1) % n);
            },
            .check_updates => sh.main.updates.check(true),
            else => return false,
        }
        c.changed = true;
        return true;
    }

    /// Says once what of keybindings.json couldn't be read.
    fn tellKeyErrors(sh: *Shell) void {
        const k = sh.keymap;
        if (k.loads == sh.keys_told) return;
        sh.keys_told = k.loads;
        if (k.errors.len == 0) return;
        const wb = sh.active() orelse return;
        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(sh.gpa);
        for (k.errors, 0..) |e, i| {
            if (i > 0) msg.appendSlice(sh.gpa, "; ") catch {};
            msg.appendSlice(sh.gpa, e) catch {};
        }
        wb.toastError("keybindings.json: MyCode doesn't know", msg.items);
    }

    /// The first family of a CSS-like list ("JetBrains Mono, Consolas,
    /// monospace") that is installed; null for the system's monospace.
    fn installedFamily(c: *ui.Context, list: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, list, ',');
        while (it.next()) |raw| {
            const fam = std.mem.trim(u8, raw, " '\"");
            if (fam.len == 0) continue;
            if (std.ascii.eqlIgnoreCase(fam, "monospace")) return null;
            const TS = @TypeOf(c.text.*);
            if (!@hasDecl(TS, "familyInstalled") or c.text.familyInstalled(fam)) return fam;
        }
        return null;
    }

    fn applyTheme(sh: *Shell, c: *ui.Context) void {
        const s = sh.store.s;
        // The window's own light or dark (the system's), before the theme's.
        const dark = if (std.mem.eql(u8, s.theme, "matrix")) true else if (std.mem.eql(u8, s.appearance, "light")) false else if (std.mem.eql(u8, s.appearance, "dark")) true else c.theme.dark;
        sh.palette = themes.palette(s.theme, dark);
        @import("icons.zig").palette = sh.palette;
        @import("icons.zig").lucide_theme = std.mem.eql(u8, s.iconTheme, "lucide");
        if (sh.mono_version != sh.store.version) {
            sh.mono_version = sh.store.version;
            sh.mono_family = installedFamily(c, s.fontFamily);
        }
        ui.themes.apply(c, themes.uiTheme(sh.palette, sh.mono_family));
        // The terminals' font: its own family, else the editor's.
        sh.host.font = .{
            .size = if (s.terminalFontSize > 0) s.terminalFontSize else s.fontSize - 0.5,
            .family = if (s.terminalFontFamily.len > 0) (installedFamily(c, s.terminalFontFamily) orelse sh.mono_family) else sh.mono_family,
            .features = s.fontFeatures,
            .weight = @intFromFloat(s.fontWeight),
            .copy_on_select = s.terminalCopyOnSelect,
        };
    }

    fn updateTitle(sh: *Shell) void {
        if (!sh.title_dirty) return;
        sh.title_dirty = false;
        const w = sh.window orelse return;
        const wb = sh.active() orelse return;
        const title = if (wb.editors.current()) |it| switch (it.body) {
            .file => |d| std.fmt.allocPrint(sh.gpa, "{s} — {s} — MyCode", .{ d.name(), wb.name() }),
            else => std.fmt.allocPrint(sh.gpa, "{s} — MyCode", .{wb.name()}),
        } catch return else std.fmt.allocPrint(sh.gpa, "{s} — MyCode", .{wb.name()}) catch return;
        w.setTitle(title);
        if (sh.title) |old| sh.gpa.free(old);
        sh.title = title;
    }

    pub fn view(sh: *Shell, c: *ui.Context) void {
        if (c.input.mouse.x > -1e5) sh.last_mouse = c.input.mouse;
        if (sh.store.reload()) {}
        sh.main.menuIfChanged();
        sh.tellKeyErrors();
        sh.applyTheme(c);
        sh.updateTitle();
        const whole = ui.div(c).column().wFull().hFull().bg(.hex(sh.palette.editor));
        defer whole.end();
        sh.titleBar(c);
        ui.row(c, .{ .width = .fill, .grow = 1, .align_items = .stretch });
        defer ui.end(c);
        if (sh.store.s.projectTabs) sh.rail(c);
        if (sh.active()) |wb| {
            c.keyed(wb);
            const box = ui.div(c).column().grow().hFull();
            wb.view(c);
            box.end();
        }
        sh.recentBox(c);
        if (sh.main.focused == sh or sh.main.shells.items.len == 1) if (sh.main.updates.view(c)) sh.main.quit();
        // Projects out of sight whose terminals rang or asked attention:
        // their squares are marked, their tips say what for.
        for (sh.projects.items, 0..) |wb, i| if (i != sh.current) {
            for (wb.panel.terms.items) |t| if (t.bell) noteAlert(wb, t);
            for (wb.editors.cols.items) |col| for (col.items.items) |it| switch (it.body) {
                .terminal => |t| if (t.bell) noteAlert(wb, t),
                else => {},
            };
        };
    }

    /// Shows an open dialog after the frame, from the event loop: a dialog
    /// runs its own loop, which would deliver the background jobs' results
    /// while the frame is half built.
    fn askLater(sh: *Shell, kind: Dialog) void {
        if (sh.dialog != .none) return;
        sh.dialog = kind;
        if (!@import("jobs.zig").post(sh, showDialog)) sh.dialog = .none;
    }

    fn showDialog(ctx: ?*anyopaque) callconv(.c) void {
        const sh: *Shell = @ptrCast(@alignCast(ctx.?));
        const kind = sh.dialog;
        sh.dialog = .none;
        // It opens in the project's folder.
        const dir: []const u8 = if (sh.active()) |wb| wb.root else "";
        const paths = (myzig.dialog.open(sh.gpa, if (kind == .file)
            .{ .title = "Open File", .directory = dir, .multiple = true }
        else
            .{ .title = "Open Folder", .files = false, .directories = true, .directory = dir }) catch return) orelse return;
        defer myzig.dialog.freePaths(sh.gpa, paths);
        switch (kind) {
            .none => {},
            .folder, .folder_new_window => if (paths.len > 0) sh.openFolder(paths[0], kind == .folder_new_window),
            .file => if (sh.active()) |wb| for (paths) |p| @import("wb_files.zig").openPath(wb, p, false),
        }
        if (sh.window) |w| w.redraw();
    }

    /// The title bar the window draws itself, as the Go app's: the sidebar's
    /// button, the command center (the file and the folder; a click opens
    /// quick open) and the panel's button, beside Windows' caption buttons.
    /// Its empty space moves the window.
    fn titleBar(sh: *Shell, c: *ui.Context) void {
        const t = c.theme;
        const p = sh.palette;
        const area = if (sh.window) |w| w.titleBar() else myzig.TitleBarArea{};
        const h: f32 = @floatCast(@max(area.height, 38));
        c.title_bar_height = h;
        const bar = ui.div(c).row().wFull().h(h).pl(@as(f32, @floatCast(area.left)) + 10).pr(@as(f32, @floatCast(area.right)) + 8).itemsCenter().bg(.hex(p.chrome));
        defer {
            bar.end();
            _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = .hex(p.border) }, .none, null);
        }
        const wb = sh.active();
        const right = sh.store.s.sidebarRight;
        const sidebar_on = if (wb) |w| w.sidebar_open else false;
        const panel_on = if (wb) |w| w.panel.open else false;
        {
            const side = ui.div(c).row().w(0).grow().gap(2).itemsCenter();
            defer side.end();
            if (!right and titleButton(c, .sidebar, sidebar_on, "Toggle Sidebar")) sh.queue(.toggle_sidebar);
        }
        // The command center.
        {
            const cc = ui.div(c).row().w(420).h(24).px(10).gap(8).center().rounded(6).bg(t.surface).border(.hex(p.border)).hover(t.surface_hover);
            const hovered = cc.hovered();
            icons.sym(c, "magnifyingglass", .{ .size = 11, .color = if (hovered) t.muted else t.muted.alpha(0.7) });
            const name: []const u8 = if (wb) |w| if (w.editors.current()) |it| it.title(c) else "" else "";
            const dirty = if (wb) |w| if (w.editors.current()) |it| it.dirty() else false else false;
            const folder: []const u8 = if (wb) |w| std.fs.path.basename(w.root) else "";
            if (name.len > 0) {
                ui.text(c, if (dirty) c.print("● {s}", .{name}) else name, .{ .size = 12, .weight = .medium });
                if (folder.len > 0) ui.text(c, folder, .{ .size = 12, .color = t.muted.alpha(0.7) });
            } else ui.text(c, if (folder.len > 0) folder else "MyCode", .{ .size = 12, .weight = .medium, .color = t.muted });
            const ci = cc.interaction();
            cc.end();
            ui.tooltip(c, ci, "Quick Open (Ctrl+P)");
            if (ci.clicked) sh.queue(.quick_open);
        }
        {
            const side = ui.div(c).row().w(0).grow().gap(2).itemsCenter().justifyEnd();
            defer side.end();
            if (titleButton(c, .panel, panel_on, "Toggle Terminal (Ctrl+`)")) sh.queue(.toggle_terminal);
            if (right and titleButton(c, .sidebar_right, sidebar_on, "Toggle Sidebar")) sh.queue(.toggle_sidebar);
        }
    }

    fn titleButton(c: *ui.Context, g: icons.Glyph, on: bool, tip: []const u8) bool {
        const t = c.theme;
        const b = ui.div(c).w(26).h(24).center().rounded(5).hover(t.surface_hover);
        icons.glyph(c, g, 14, if (on) t.text else t.muted);
        const bi = b.interaction();
        b.end();
        ui.tooltip(c, bi, tip);
        return bi.clicked;
    }

    fn noteAlert(wb: *Workbench, t: *const @import("panel.zig").Term) void {
        wb.bell = true;
        const a = t.alert();
        const n = @min(a.len, wb.alert_buf.len);
        @memcpy(wb.alert_buf[0..n], a[0..n]);
        wb.alert_len = n;
    }

    /// The first letters of a project's first two words, as the Go app
    /// takes them: words split at "-", "_", "." and before a capital after
    /// a lowercase letter ("hisWeb", "his-web": "HW"; "myzig": "M").
    fn initials(c: *ui.Context, name: []const u8) []const u8 {
        var out: std.ArrayList(u8) = .empty;
        var start = true;
        var prev: u8 = 0;
        for (name) |ch| {
            if (out.items.len == 2) break;
            const sep = ch == '-' or ch == '_' or ch == '.' or ch == ' ';
            const camel = std.ascii.isUpper(ch) and std.ascii.isLower(prev);
            if (!sep and (start or camel)) out.append(c.alloc(), std.ascii.toUpper(ch)) catch {};
            start = sep;
            prev = ch;
        }
        if (out.items.len == 0) return "?";
        return out.items;
    }

    /// A project's color, by its folder, among the palette's: the Go app's
    /// `avatarColor`.
    fn projectColor(p: *const themes.Palette, dir: []const u8) ui.Color {
        var h: u32 = 2166136261;
        for (dir) |b| h = (h ^ b) *% 16777619;
        const cols = [_]u24{ p.accent, p.added, p.changed, p.modified, p.removed, p.type };
        return .hex(cols[h % cols.len]);
    }

    /// The rail's ground: a shade off the sidebar's, as an activity bar is.
    fn railGround(p: *const themes.Palette) ui.Color {
        const chrome: ui.Color = .hex(p.chrome);
        return if (p.dark) chrome.mix(.hex(0x000000), 0.18) else chrome.mix(.hex(p.border), 0.22);
    }

    fn rail(sh: *Shell, c: *ui.Context) void {
        const t = c.theme;
        const p = sh.palette;
        const col = ui.div(c).column().w(48).hFull().pt(8).gap(6).itemsCenter().bg(railGround(p));
        defer {
            col.end();
            _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .fill, .background = .hex(p.border) }, .none, null);
        }
        var go: ?usize = null;
        for (sh.projects.items, 0..) |wb, i| {
            c.keyed(wb);
            const on = i == sh.current;
            const wrap = ui.div(c).row().w(48).h(36).itemsCenter().justifyCenter();
            const pc = projectColor(p, wb.root);
            const hot = sh.rail_hot == i;
            // Along the rail's edge, as the activity bar marks the view shown.
            if (on or hot) {
                const pill: f32 = if (on) 20 else 8;
                _ = c.leaf(.{ .absolute = true, .offset = .{ .x = -2, .y = (36 - pill) / 2 }, .width = .{ .px = 5 }, .height = .{ .px = pill }, .radius = 2.5, .background = if (on) t.accent else t.muted }, .none, null);
            }
            const sq = ui.div(c).w(32).h(32).center().rounded(9).bg(pc.alpha(if (on) 0.30 else if (hot) 0.22 else 0.14)).border(if (on) pc.alpha(0.75) else .transparent);
            const ink = if (on or hot) pc else pc.mix(t.muted, 0.25);
            if (sh.store.s.projectIcons and !wb.logo_read) {
                wb.logo_read = true;
                wb.logo = @import("logo.zig").find(sh.gpa, sh.io, wb.root);
            }
            const project_logo = if (sh.store.s.projectIcons) wb.logo else null;
            if (project_logo) |l| {
                const key = c.print("logo:{s}", .{wb.root});
                const shown = if (l.svg) ui.svg(c, l.bytes, .{ .width = 22, .height = 22, .key = key }) else ui.image(c, .{ .key = key, .bytes = l.bytes, .max_width = 22, .max_height = 22, .radius = 4 });
                if (!shown) ui.text(c, initials(c, wb.name()), .{ .size = 12, .weight = .bold, .color = ink });
            } else ui.text(c, initials(c, wb.name()), .{ .size = 12, .weight = .bold, .color = ink });
            // Unsaved changes at the top right, an alert at the bottom right,
            // each cut out of the square by a ring of the rail's ground.
            if (wb.editors.anyDirty()) dot(c, 25, -5, t.text.alpha(0.85), railGround(p));
            if (wb.bell) dot(c, 25, 25, t.accent, railGround(p));
            const si = sq.interaction();
            if (si.hovered) sh.rail_hot = i else if (sh.rail_hot == i) sh.rail_hot = null;
            sq.end();
            const wi = wrap.interaction();
            wrap.end();
            if (i < sh.rail_rects.len) if (wi.rect) |r| {
                sh.rail_rects[i] = r;
            };
            if (si.pressed and c.input.pressed and sh.rail_drag == null) sh.rail_drag = .{ .from = i, .start = c.input.mouse };
            const alert = if (wb.bell and wb.alert_len > 0) c.print("\n{s}", .{wb.alert_buf[0..wb.alert_len]}) else "";
            ui.tooltip(c, si, if (i < 9) c.print("{s}\n{s}\n{s}{s}", .{ wb.name(), wb.root, c.print("Ctrl+Alt+{d}", .{i + 1}), alert }) else c.print("{s}\n{s}{s}", .{ wb.name(), wb.root, alert }));
            if (si.clicked) go = i;
            if (ui.contextMenu(c, &sh.rail_menu, si)) |m| {
                defer m.end();
                sh.rail_at = i;
                if (m.item("Reveal in File Explorer", .{})) myzig.shell.showInFolder(wb.root);
                if (m.item("Copy Path", .{})) _ = myzig.clipboard.writeText(wb.root);
                if (m.item("Project Icons", .{ .checked = sh.store.s.projectIcons })) sh.store.setBool("projectIcons", !sh.store.s.projectIcons);
                if (i > 0) if (m.item("Move Up", .{})) sh.moveProject(i, i - 1);
                if (i + 1 < sh.projects.items.len) if (m.item("Move Down", .{})) sh.moveProject(i, i + 1);
                m.separator();
                if (m.item("Close Project", .{})) wb.queue(.close_project);
                if (m.item("Close Other Projects", .{})) {
                    for (sh.projects.items) |o| if (o != wb) o.queue(.close_project);
                }
            }
        }
        if (go) |i| if (sh.rail_drag == null or !sh.rail_drag.?.moving) sh.show(i);
        sh.railDrag(c);
        _ = c.leaf(.{ .width = .{ .px = 20 }, .height = .{ .px = 1 }, .background = .hex(p.border) }, .none, null);
        // Open Folder: a square of dashes, as the Go app draws it.
        const plus = ui.div(c).w(32).h(32).center().rounded(9).border(.hex(p.faint)).hover(t.accent.alpha(0.14));
        icons.sym(c, "plus", .{ .size = 12, .color = if (plus.hovered()) t.accent else t.muted });
        const pi = plus.interaction();
        plus.end();
        ui.tooltip(c, pi, "Open Folder… (Ctrl+O)");
        if (pi.clicked) sh.queue(.open_folder);
        ui.spacer(c);
        // At its foot, as VS Code's activity bar has it.
        if (sh.active()) |wb| sh.manageButton(c, wb);
    }

    fn dot(c: *ui.Context, x: f32, y: f32, color: ui.Color, ground: ui.Color) void {
        _ = c.leaf(.{ .absolute = true, .offset = .{ .x = x - 2, .y = y - 2 }, .width = .{ .px = 14 }, .height = .{ .px = 14 }, .radius = 7, .background = ground }, .none, null);
        _ = c.leaf(.{ .absolute = true, .offset = .{ .x = x, .y = y }, .width = .{ .px = 10 }, .height = .{ .px = 10 }, .radius = 5, .background = color }, .none, null);
    }

    /// Moves project `from` to place `to` of the rail, the one shown staying shown.
    fn moveProject(sh: *Shell, from: usize, to: usize) void {
        if (from == to or from >= sh.projects.items.len) return;
        const shown = sh.active();
        const wb = sh.projects.orderedRemove(from);
        sh.projects.insert(sh.gpa, @min(to, sh.projects.items.len), wb) catch {
            sh.projects.append(sh.gpa, wb) catch {};
        };
        if (shown) |s| if (std.mem.indexOfScalar(*Workbench, sh.projects.items, s)) |k| {
            sh.current = k;
        };
        sh.main.saveState();
    }

    /// A square dragged along the rail: a bar shows where it goes, and it
    /// goes there as it is let go.
    fn railDrag(sh: *Shell, c: *ui.Context) void {
        const dg = &(sh.rail_drag orelse return);
        const n = @min(sh.projects.items.len, sh.rail_rects.len);
        const y = c.input.mouse.y;
        // The place before the first square whose middle is below the pointer.
        var to: usize = n;
        for (0..n) |k| if (y < sh.rail_rects[k].y + sh.rail_rects[k].h / 2) {
            to = k;
            break;
        };
        if (c.input.down) {
            if (!dg.moving and @abs(y - dg.start.y) > 6) dg.moving = true;
            if (dg.moving and n > 0) {
                c.wants_moves = true;
                const ry = if (to < n) sh.rail_rects[to].y else sh.rail_rects[n - 1].y + sh.rail_rects[n - 1].h;
                _ = c.leaf(.{ .absolute = true, .offset = .{ .x = 6, .y = ry - sh.rail_rects[0].y + 6 }, .width = .{ .px = 36 }, .height = .{ .px = 2 }, .background = c.theme.accent }, .none, null);
            }
            return;
        }
        defer sh.rail_drag = null;
        if (!dg.moving) return;
        // Past its own place, the places after it move up by one.
        sh.moveProject(dg.from, if (to > dg.from) to - 1 else to);
        c.changed = true;
    }

    /// The gear: the Manage menu, as the Go app's.
    pub fn manageButton(sh: *Shell, c: *ui.Context, wb: *Workbench) void {
        const t = c.theme;
        const g = ui.div(c).w(40).h(36).center().rounded(6).hover(t.surface_hover);
        icons.sym(c, "gear", .{ .size = 14, .color = if (g.hovered()) t.text else t.muted });
        const gi = g.interaction();
        g.end();
        ui.tooltip(c, gi, "Manage");
        if (ui.buttonMenu(c, &sh.manage_menu, gi)) |m| {
            defer m.end();
            const s = &sh.store.s;
            if (m.item("Command Palette…", .{ .shortcut = Shell.keyLabel(sh, c, .command_palette) })) wb.queue(.command_palette);
            m.separator();
            if (m.item("Settings", .{ .shortcut = Shell.keyLabel(sh, c, .open_settings) })) wb.queue(.open_settings);
            if (m.item("Keyboard Shortcuts", .{})) wb.queue(.open_keybindings);
            m.separator();
            if (m.submenu("Theme")) |sub| {
                defer sub.end();
                const ts = [_]Cmd{ .theme_mycode, .theme_matrix, .theme_claude, .theme_qoder };
                for (ts, 0..) |cmd, i| if (sub.item(themes.titles[i], .{ .checked = std.mem.eql(u8, s.theme, themes.names[i]) })) wb.queue(cmd);
                sub.separator();
                // The Matrix is dark whatever the system is.
                const matrix = std.mem.eql(u8, s.theme, "matrix");
                const as = [_]struct { Cmd, []const u8, []const u8 }{ .{ .appearance_system, "System", "" }, .{ .appearance_light, "Light", "light" }, .{ .appearance_dark, "Dark", "dark" } };
                for (as) |a| if (sub.item(a[1], .{ .checked = std.mem.eql(u8, s.appearance, a[2]), .disabled = matrix })) wb.queue(a[0]);
            }
            if (m.submenu("File Icon Theme")) |sub| {
                defer sub.end();
                if (sub.item("Material", .{ .checked = !std.mem.eql(u8, s.iconTheme, "lucide") })) wb.queue(.icons_material);
                if (sub.item("Lucide", .{ .checked = std.mem.eql(u8, s.iconTheme, "lucide") })) wb.queue(.icons_lucide);
            }
            if (m.submenu("Default Terminal Profile")) |sub| {
                defer sub.end();
                for (sh.profiles, 0..) |pr, i| if (sub.item(pr.name, .{ .checked = i == sh.defaultProfile() })) sh.setDefaultProfile(i);
            }
            m.separator();
            if (m.item("Project Tabs", .{ .checked = s.projectTabs })) wb.queue(.toggle_project_tabs);
            if (m.item("Auto Save", .{ .checked = s.autoSave })) wb.queue(.toggle_auto_save);
            m.separator();
            if (m.item("Check for Updates…", .{})) wb.queue(.check_updates);
        }
    }

    /// MyCode's logo, or the theme's mascot in its place.
    pub fn logo(sh: *Shell, c: *ui.Context, size: f32) void {
        const th = sh.store.s.theme;
        if (std.mem.eql(u8, th, "claude") or std.mem.eql(u8, th, "qoder")) return sh.mascot(c, size);
        _ = ui.image(c, .{ .key = "mycode-logo", .bytes = @embedFile("icon_png"), .max_width = size, .max_height = size, .radius = size * 0.22, .label = "MyCode" });
    }

    /// Clawd under the Claude theme, Qoder's duck under Qoder's: blinking
    /// now and then, hopping while Git runs.
    pub fn mascot(sh: *Shell, c: *ui.Context, size: f32) void {
        const th = sh.store.s.theme;
        const claude = std.mem.eql(u8, th, "claude");
        const qoder = std.mem.eql(u8, th, "qoder");
        if (!claude and !qoder) return;
        const busy = if (sh.active()) |wb| wb.runner.busy or wb.search.running else false;
        const phase = @mod(c.time, 4.0);
        const blink = phase > 3.85;
        const hop: f32 = if (busy) @abs(@sin(@as(f32, @floatCast(c.time)) * 9)) * size * 0.15 else 0;
        if (busy) c.animationFrame() else c.frameIn(@floatCast(if (phase < 3.85) 3.85 - phase else 4.0 - phase));
        const body: ui.Color = if (claude) .hex(0xd97757) else .hex(0xf5c542);
        const box = ui.div(c).w(size).h(size);
        defer box.end();
        _ = c.leaf(.{ .absolute = true, .offset = .{ .x = 0, .y = size * 0.15 - hop }, .width = .{ .px = size }, .height = .{ .px = size * 0.7 }, .radius = if (claude) size * 0.12 else size * 0.35, .background = body }, .none, null);
        const eye_h: f32 = if (blink) size * 0.04 else size * 0.16;
        for ([_]f32{ 0.28, 0.62 }) |x| {
            _ = c.leaf(.{ .absolute = true, .offset = .{ .x = size * x, .y = size * 0.35 - hop + (size * 0.16 - eye_h) / 2 }, .width = .{ .px = size * 0.1 }, .height = .{ .px = eye_h }, .radius = size * 0.05, .background = .hex(0x1f1e1d) }, .none, null);
        }
        if (qoder) _ = c.leaf(.{ .absolute = true, .offset = .{ .x = size * 0.78, .y = size * 0.45 - hop }, .width = .{ .px = size * 0.26 }, .height = .{ .px = size * 0.14 }, .radius = size * 0.07, .background = .hex(0xf08a24) }, .none, null);
    }

    /// Ctrl+R: the recent folders, found by name; Enter opens one here,
    /// Ctrl+Enter in a new window.
    fn recentBox(sh: *Shell, c: *ui.Context) void {
        const d = ui.dialog(c, &sh.recent, .{ .width = .{ .px = 560 }, .padding = .all(8), .gap = 6 }) orelse return;
        defer d.end();
        const t = c.theme;
        const fid = c.peekId(null);
        if (sh.recent_focus > 0) {
            if (c.focus != fid) c.changed = true;
            c.focus = fid;
            sh.recent_focus -= 1;
        }
        const field = ui.textField(c, &sh.recent_query, .{ .width = .fill, .placeholder = "Open a recent folder", .size = 14 });
        var shown: std.ArrayList([]const u8) = .empty;
        for (sh.state.f.recent) |r| {
            if (!fs.isDirectory(sh.io, r)) continue;
            if (quickopen.score(r, sh.recent_query.text()) != null) shown.append(c.alloc(), r) catch {};
        }
        const n = shown.items.len;
        if (c.shortcut(.{ .key = ui.Shortcut.down })) sh.recent_sel = if (n == 0) 0 else (sh.recent_sel + 1) % n;
        if (c.shortcut(.{ .key = ui.Shortcut.up })) sh.recent_sel = if (n == 0) 0 else (sh.recent_sel + n - 1) % n;
        if (sh.recent_sel >= n) sh.recent_sel = 0;
        var pick: ?[]const u8 = null;
        var new_window = false;
        for (shown.items, 0..) |r, i| {
            const row = ui.div(c).row().wFull().h(28).px(8).gap(8).itemsCenter().rounded(4).bg(if (i == sh.recent_sel) t.accent.alpha(0.25) else .transparent).hover(t.surface_hover);
            icons.sym(c, "folder", .{ .size = 12, .color = t.muted });
            ui.text(c, std.fs.path.basename(r), .{ .size = 13 });
            ui.text(c, r, .{ .size = 11, .color = t.muted });
            if (row.clicked()) {
                pick = r;
                new_window = c.input.ctrl or c.input.cmd;
            }
            row.end();
        }
        if (n == 0) ui.text(c, "No recent folders.", .{ .size = 12, .color = t.muted });
        if (c.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true }) and n > 0) {
            pick = shown.items[sh.recent_sel];
            new_window = true;
        }
        if (field.submitted and n > 0) pick = shown.items[sh.recent_sel];
        if (ui.button(c, "Clear Recently Opened", .{ .variant = .ghost, .size = 11 }).clicked) sh.state.clearRecent();
        if (pick) |p| {
            sh.recent.close();
            const path = c.print("{s}", .{p});
            sh.openFolder(path, new_window);
        }
    }

    pub fn onWindowEvent(sh: *Shell, w: *myzig.Window, ev: myzig.WindowEvent) void {
        switch (ev) {
            // Auto save when the window loses the keyboard; look again when it comes back.
            .blur => {
                sh.has_focus = false;
                if (sh.store.s.autoSave) if (sh.active()) |wb| wb.editors.saveAll();
                sh.main.saveState();
            },
            .focus => {
                sh.has_focus = true;
                sh.main.focused = sh;
                if (sh.store.reload()) {}
                sh.main.loadKeysIfChanged();
                if (sh.active()) |wb| wb.refresh_next = true;
                w.redraw();
            },
            else => {},
        }
    }

    pub fn onDrop(sh: *Shell, w: *myzig.Window, paths: []const []const u8) void {
        // On a terminal, the paths are typed into it.
        if (sh.active()) |wb| {
            const m = sh.last_mouse;
            for (wb.panel.terms.items) |t| if (wb.panel.open and t.rect != null and t.rect.?.contains(m)) return t.typePaths(paths);
            for (wb.editors.cols.items) |col| if (col.current()) |it| switch (it.body) {
                .terminal => |t| if (t.rect != null and t.rect.?.contains(m)) return t.typePaths(paths),
                else => {},
            };
        }
        // On the Explorer, they copy into the folder they land on.
        if (sh.active()) |wb| if (wb.sidebar_open and wb.side == .explorer) if (wb.explorer.dropTarget(sh.last_mouse)) |dir| {
            @import("wb_files.zig").copyInto(wb, paths, dir);
            w.redraw();
            return;
        };
        // Folders open as projects; files where they land over the columns.
        var files: std.ArrayList([]const u8) = .empty;
        defer files.deinit(sh.gpa);
        for (paths) |p| {
            if (fs.isDirectory(sh.io, p)) sh.openFolder(p, false) else files.append(sh.gpa, p) catch {};
        }
        if (sh.active()) |wb| if (files.items.len > 0) {
            const wbfiles = @import("wb_files.zig");
            if (!wbfiles.dropFiles(wb, files.items, sh.last_mouse)) for (files.items) |p| wbfiles.openPath(wb, p, false);
        };
        w.redraw();
    }

    pub fn onClose(sh: *Shell, _: *myzig.Window) void {
        sh.main.closeShell(sh);
    }
};
