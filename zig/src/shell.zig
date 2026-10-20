//! A window: its projects (a rail of them on the left with project tabs on),
//! the theme, and the window's own commands: folders, settings, zoom,
//! themes. The app's state (settings, keys, recent folders) is `Main`'s.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const fs = @import("fs.zig");
const commands = @import("commands.zig");
const Cmd = commands.Cmd;
const themes = @import("themes.zig");
const Workbench = @import("workbench.zig").Workbench;
const Main = @import("main.zig").Main;
const panel_mod = @import("panel.zig");
const Profile = @import("termprofiles.zig").Profile;
const keymap = @import("keymap.zig");
const quickopen = @import("quickopen.zig");
const winshell = @import("winshell.zig");

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

    pub fn closeProject(sh: *Shell, wb: *Workbench) void {
        if (!sh.store.s.autoSave and wb.editors.anyDirty()) {
            wb.ask(.close_project, "", "Close the project?", "It has unsaved changes, which are lost.", &.{ "Cancel", "Close" });
            return;
        }
        sh.closeProjectNow(wb);
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

    fn openLink(ctx: *anyopaque, link: []const u8, is_path: bool) bool {
        const sh: *Shell = @ptrCast(@alignCast(ctx));
        if (!is_path) return false;
        const wb = sh.active() orelse return false;
        // path:line:col
        var path = link;
        var line: usize = 0;
        var parts = std.mem.splitBackwardsScalar(u8, link, ':');
        var nums: [2]usize = .{ 0, 0 };
        var n: usize = 0;
        while (parts.next()) |p| {
            const v = std.fmt.parseInt(usize, p, 10) catch break;
            if (n < 2) nums[n] = v;
            n += 1;
            path = link[0 .. @intFromPtr(p.ptr) - @intFromPtr(link.ptr) -| 1];
        }
        if (n > 0) line = nums[n - 1];
        const abs = if (std.fs.path.isAbsolute(path)) sh.gpa.dupe(u8, path) catch return false else std.fs.path.join(sh.gpa, &.{ wb.root, path }) catch return false;
        defer sh.gpa.free(abs);
        if (fs.isDirectory(sh.io, abs)) {
            wb.sidebar_open = true;
            wb.side = .explorer;
            wb.explorer.reveal(abs);
            return true;
        }
        if (!fs.exists(sh.io, abs)) return false;
        const it = wb.editors.openFile(abs, false) catch return false;
        switch (it.body) {
            .file => |d| if (line > 0) d.editor.goToLine(line),
            else => {},
        }
        if (sh.window) |w| w.redraw();
        return true;
    }

    /// The window's own commands; false for a project's.
    pub fn run(sh: *Shell, c: *ui.Context, cmd: Cmd) bool {
        const st = sh.store;
        switch (cmd) {
            .open_folder, .open_folder_new_window => {
                const paths = (myzig.dialog.open(sh.gpa, .{ .title = "Open Folder", .files = false, .directories = true }) catch return true) orelse return true;
                defer myzig.dialog.freePaths(sh.gpa, paths);
                if (paths.len > 0) sh.openFolder(paths[0], cmd == .open_folder_new_window);
            },
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

    fn applyTheme(sh: *Shell, c: *ui.Context) void {
        const s = sh.store.s;
        // The window's own light or dark (the system's), before the theme's.
        const dark = if (std.mem.eql(u8, s.theme, "matrix")) true else if (std.mem.eql(u8, s.appearance, "light")) false else if (std.mem.eql(u8, s.appearance, "dark")) true else c.theme.dark;
        sh.palette = themes.palette(s.theme, dark);
        @import("icons.zig").palette = sh.palette;
        @import("icons.zig").lucide_theme = std.mem.eql(u8, s.iconTheme, "lucide");
        const fam = std.mem.trim(u8, std.mem.sliceTo(s.fontFamily, ','), " ");
        const mono: ?[]const u8 = if (std.ascii.eqlIgnoreCase(fam, "monospace") or fam.len == 0) null else fam;
        ui.themes.apply(c, themes.uiTheme(sh.palette, mono));
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
        sh.applyTheme(c);
        sh.updateTitle();
        ui.row(c, .{ .width = .fill, .height = .fill, .align_items = .stretch, .background = .hex(sh.palette.editor) });
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
        // Projects out of sight that rang their terminal's bell.
        for (sh.projects.items, 0..) |wb, i| if (i != sh.current) for (wb.panel.terms.items) |t| if (t.bell) {
            wb.bell = true;
        };
    }

    fn initials(c: *ui.Context, name: []const u8) []const u8 {
        var out: std.ArrayList(u8) = .empty;
        var it = std.mem.tokenizeAny(u8, name, " -_.");
        while (it.next()) |w| {
            if (out.items.len == 2) break;
            out.append(c.alloc(), std.ascii.toUpper(w[0])) catch {};
        }
        if (out.items.len == 1 and name.len > 1) out.append(c.alloc(), name[1]) catch {};
        return out.items;
    }

    fn rail(sh: *Shell, c: *ui.Context) void {
        const t = c.theme;
        const p = sh.palette;
        const col = ui.div(c).column().w(48).hFull().py(8).gap(8).itemsCenter().bg(.hex(p.chrome)).border(.hex(p.border));
        defer col.end();
        var go: ?usize = null;
        for (sh.projects.items, 0..) |wb, i| {
            c.keyed(wb);
            const on = i == sh.current;
            const wrap = ui.div(c).row().w(48).h(36).itemsCenter().justifyCenter();
            if (on) _ = c.leaf(.{ .absolute = true, .offset = .{ .x = 0, .y = 6 }, .width = .{ .px = 3 }, .height = .{ .px = 24 }, .radius = 2, .background = t.text }, .none, null);
            const sq = ui.div(c).w(34).h(34).center().rounded(8).bg(if (on) t.accent else t.surface_hover).hover(t.accent.alpha(0.6));
            if (sh.store.s.projectIcons and !wb.logo_read) {
                wb.logo_read = true;
                wb.logo = @import("logo.zig").find(sh.gpa, sh.io, wb.root);
            }
            const project_logo = if (sh.store.s.projectIcons) wb.logo else null;
            if (project_logo) |l| {
                const key = c.print("logo:{s}", .{wb.root});
                const shown = if (l.svg) ui.svg(c, l.bytes, .{ .width = 22, .height = 22, .key = key }) else ui.image(c, .{ .key = key, .bytes = l.bytes, .max_width = 22, .max_height = 22, .radius = 4 });
                if (!shown) ui.text(c, initials(c, wb.name()), .{ .size = 13, .weight = .semibold, .color = if (on) t.accent_text else t.text });
            } else ui.text(c, initials(c, wb.name()), .{ .size = 13, .weight = .semibold, .color = if (on) t.accent_text else t.text });
            if (wb.editors.anyDirty() or wb.bell) _ = c.leaf(.{ .absolute = true, .offset = .{ .x = 26, .y = 2 }, .width = .{ .px = 7 }, .height = .{ .px = 7 }, .radius = 4, .background = if (wb.bell) t.accent else t.text }, .none, null);
            const si = sq.interaction();
            sq.end();
            wrap.end();
            ui.tooltip(c, si, if (i < 9) c.print("{s}\n{s}\n{s}", .{ wb.name(), wb.root, c.print("Ctrl+Alt+{d}", .{i + 1}) }) else c.print("{s}\n{s}", .{ wb.name(), wb.root }));
            if (si.clicked) go = i;
            if (ui.contextMenu(c, &sh.rail_menu, si)) |m| {
                defer m.end();
                sh.rail_at = i;
                if (m.item("Reveal in File Explorer", .{})) myzig.shell.showInFolder(wb.root);
                if (m.item("Copy Path", .{})) _ = myzig.clipboard.writeText(wb.root);
                if (m.item("Project Icons", .{ .checked = sh.store.s.projectIcons })) sh.store.setBool("projectIcons", !sh.store.s.projectIcons);
                if (i > 0) if (m.item("Move Up", .{})) std.mem.swap(*Workbench, &sh.projects.items[i], &sh.projects.items[i - 1]);
                if (i + 1 < sh.projects.items.len) if (m.item("Move Down", .{})) std.mem.swap(*Workbench, &sh.projects.items[i], &sh.projects.items[i + 1]);
                m.separator();
                if (m.item("Close Project", .{})) wb.queue(.close_project);
                if (m.item("Close Other Projects", .{})) {
                    for (sh.projects.items) |o| if (o != wb) o.queue(.close_project);
                }
            }
        }
        if (go) |i| sh.show(i);
        const plus = ui.div(c).w(34).h(34).center().rounded(8).hover(t.surface_hover);
        ui.icon(c, "plus", .{ .size = 14, .color = t.muted });
        if (plus.clicked()) sh.queue(.open_folder);
        plus.end();
        ui.spacer(c);
        if (sh.active()) |wb| sh.manageButton(c, wb);
    }

    /// The gear: the Manage menu, as VS Code's.
    pub fn manageButton(sh: *Shell, c: *ui.Context, wb: *Workbench) void {
        const t = c.theme;
        const g = ui.div(c).w(30).h(22).center().rounded(4).hover(t.surface_hover);
        ui.icon(c, "wrench.and.screwdriver", .{ .size = 12, .color = t.muted });
        const gi = g.interaction();
        g.end();
        if (ui.buttonMenu(c, &sh.manage_menu, gi)) |m| {
            defer m.end();
            const items = [_]Cmd{ .command_palette, .open_settings, .open_keybindings };
            for (items) |cmd| if (m.item(commands.info(cmd).title, .{})) wb.queue(cmd);
            if (m.submenu("Theme")) |sub| {
                defer sub.end();
                const ts = [_]Cmd{ .theme_mycode, .theme_matrix, .theme_claude, .theme_qoder };
                for (ts, 0..) |cmd, i| if (sub.item(themes.titles[i], .{ .checked = std.mem.eql(u8, sh.store.s.theme, themes.names[i]) })) wb.queue(cmd);
                sub.separator();
                const as = [_]struct { Cmd, []const u8, []const u8 }{ .{ .appearance_system, "Follow System", "" }, .{ .appearance_light, "Light", "light" }, .{ .appearance_dark, "Dark", "dark" } };
                for (as) |a| if (sub.item(a[1], .{ .checked = std.mem.eql(u8, sh.store.s.appearance, a[2]) })) wb.queue(a[0]);
            }
            if (m.submenu("Default Terminal")) |sub| {
                defer sub.end();
                for (sh.profiles, 0..) |pr, i| if (sub.item(pr.name, .{ .checked = i == sh.defaultProfile() })) sh.setDefaultProfile(i);
            }
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
            ui.icon(c, "folder", .{ .size = 12, .color = t.muted });
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
        for (paths) |p| {
            if (fs.isDirectory(sh.io, p)) {
                sh.openFolder(p, false);
            } else if (sh.active()) |wb| {
                @import("wb_files.zig").openPath(wb, p, false);
            }
        }
        w.redraw();
    }

    pub fn onClose(sh: *Shell, _: *myzig.Window) void {
        sh.main.closeShell(sh);
    }
};
