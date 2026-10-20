//! MyCode, drawn by myzig: `mycode [folder-or-file...]`. One instance runs:
//! later launches hand their folders and files to it.
const std = @import("std");
const builtin = @import("builtin");
const myzig = @import("myzig");
const fs = @import("fs.zig");
const git = @import("git.zig");
const commands = @import("commands.zig");
const menubar = @import("menubar.zig");
const settings = @import("settings.zig");
const state_mod = @import("state.zig");
const keymap = @import("keymap.zig");
const termprofiles = @import("termprofiles.zig");
const Shell = @import("shell.zig").Shell;
const Workbench = @import("workbench.zig").Workbench;

pub const Main = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    app: *myzig.App,
    env: *const std.process.Environ.Map,
    store: settings.Store,
    state: state_mod.State,
    keymap: keymap.Keymap,
    keys_mtime: i96 = -1,
    profiles_arena: std.heap.ArenaAllocator,
    profiles: []const termprofiles.Profile = &.{},
    shells: std.ArrayList(*Shell) = .empty,
    focused: ?*Shell = null,
    quitting: bool = false,
    updates: @import("updates.zig").Updates,
    /// The menu bar's labels, and what its recent folders were made of.
    menu_arena: std.heap.ArenaAllocator,
    menu_recent_len: usize = 0,
    menu_recent_first: u64 = 0,
    /// The settings, keys and review comments the menu bar was made of.
    menu_settings: u64 = 0,
    menu_keys: i96 = -1,
    menu_reviewing: bool = false,
    /// Set as main returns: windows closing then find their state gone.
    ending: bool = false,

    pub fn queue(m: *Main, cmd: commands.Cmd) void {
        const sh = m.focused orelse (if (m.shells.items.len > 0) m.shells.items[0] else return);
        sh.queue(cmd);
    }

    /// The menu bar again, with the recent folders as they are now.
    pub fn buildMenu(m: *Main) !void {
        var recent: std.ArrayList([]const u8) = .empty;
        defer recent.deinit(m.gpa);
        for (m.state.f.recent) |r| {
            if (recent.items.len == 10) break;
            // Not the window's own, nor one gone from the disk.
            if (m.focused) |sh| if (sh.active()) |wb| if (std.mem.eql(u8, wb.root, r)) continue;
            if (!fs.isDirectory(m.io, r)) continue;
            try recent.append(m.gpa, r);
        }
        // The labels outlive this build: the old menu goes first.
        var next: std.heap.ArenaAllocator = .init(m.gpa);
        errdefer next.deinit();
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(m.gpa);
        for (m.profiles) |p| try names.append(m.gpa, p.name);
        const sh = m.focused orelse (if (m.shells.items.len > 0) m.shells.items[0] else null);
        const bar = try menubar.build(Main, m, next.allocator(), .{
            .recent = recent.items,
            .profiles = names.items,
            .default_profile = if (sh) |s| s.defaultProfile() else 0,
            .settings = &m.store.s,
            .reviewing = m.reviewing(),
            .accel = menuAccel,
            .ctx = m,
        });
        try m.app.setMenu(bar);
        m.menu_arena.deinit();
        m.menu_arena = next;
        m.menu_recent_len = m.state.f.recent.len;
        m.menu_recent_first = if (m.state.f.recent.len > 0) std.hash.Wyhash.hash(0, m.state.f.recent[0]) else 0;
        m.menu_settings = m.store.version;
        m.menu_keys = m.keys_mtime;
        m.menu_reviewing = m.reviewing();
    }

    /// Review comments wait in the project shown.
    fn reviewing(m: *Main) bool {
        const sh = m.focused orelse return false;
        const wb = sh.active() orelse return false;
        return wb.review.list.items.len > 0;
    }

    /// A command's accelerator in the menu bar: none when keybindings.json
    /// binds its keys, which the menu would take first, or takes them away
    /// from it.
    fn menuAccel(ctx: *anyopaque, cmd: commands.Cmd) []const u8 {
        const m: *Main = @ptrCast(@alignCast(ctx));
        const accel = commands.info(cmd).accel;
        if (accel.len == 0) return "";
        if (m.keymap.takesAccel(accel, cmd)) return "";
        return accel;
    }

    /// Builds the menu again when what it shows changed: the recent
    /// folders, the settings, the keys, whether review comments wait.
    pub fn menuIfChanged(m: *Main) void {
        const first = if (m.state.f.recent.len > 0) std.hash.Wyhash.hash(0, m.state.f.recent[0]) else 0;
        if (m.state.f.recent.len == m.menu_recent_len and first == m.menu_recent_first and
            m.store.version == m.menu_settings and m.keys_mtime == m.menu_keys and m.reviewing() == m.menu_reviewing) return;
        m.buildMenu() catch {};
    }

    /// File → New Terminal with Profile, and Default Terminal Profile.
    pub fn profileHandler(comptime k: usize, comptime new: bool) fn (*Main, *myzig.menu.Item) void {
        return struct {
            fn f(m: *Main, _: *myzig.menu.Item) void {
                const sh = m.focused orelse return;
                if (!new) return sh.setDefaultProfile(k);
                const wb = sh.active() orelse return;
                @import("wb_files.zig").newTerminal(wb, k);
                if (sh.window) |w| w.redraw();
            }
        }.f;
    }

    pub fn recentHandler(comptime k: usize) fn (*Main, *myzig.menu.Item) void {
        return struct {
            fn f(m: *Main, item: *myzig.menu.Item) void {
                _ = item;
                const sh = m.focused orelse return;
                // The item's label is the folder.
                var n: usize = 0;
                for (m.state.f.recent) |r| {
                    if (sh.active()) |wb| if (std.mem.eql(u8, wb.root, r)) continue;
                    if (!fs.isDirectory(m.io, r)) continue;
                    if (n == k) {
                        const p = m.gpa.dupe(u8, r) catch return;
                        defer m.gpa.free(p);
                        sh.openFolder(p, false);
                        return;
                    }
                    n += 1;
                }
            }
        }.f;
    }

    pub fn clearRecentItem(m: *Main, _: *myzig.menu.Item) void {
        m.state.clearRecent();
        m.state.save();
        m.buildMenu() catch {};
    }

    pub fn loadKeys(m: *Main) void {
        m.keys_mtime = fs.mtime(m.io, m.store.keys_path);
        const data = fs.read(m.gpa, m.io, m.store.keys_path) catch return;
        defer m.gpa.free(data);
        m.keymap.load(data);
    }

    pub fn loadKeysIfChanged(m: *Main) void {
        if (fs.mtime(m.io, m.store.keys_path) != m.keys_mtime) m.loadKeys();
    }

    /// A window for these folders (their projects, or one each without
    /// project tabs).
    pub fn newWindow(m: *Main, roots: []const []const u8) !void {
        const sh = try Shell.create(m);
        errdefer sh.destroy();
        for (roots) |r| _ = try sh.addProject(r);
        if (sh.projects.items.len == 0) return error.NoFolder;
        try m.shells.append(m.gpa, sh);
        const first = m.shells.items.len == 1;
        const w = try m.app.newWindow(.{
            .title = "MyCode",
            .width = 1280,
            .height = 820,
            .min_width = 640,
            .min_height = 400,
            .state = if (first) myzig.windowState("main") else null,
            .on_event = .of(sh, Shell.onWindowEvent),
            .on_drop = .of(sh, Shell.onDrop),
            .on_close = .{ .ctx = sh, .func = struct {
                fn f(ctx: *anyopaque, w: *myzig.Window) void {
                    Shell.onClose(@ptrCast(@alignCast(ctx)), w);
                }
            }.f },
            .content = .{ .view = .init(sh, Shell.view) },
        });
        sh.attach(w);
        m.focused = sh;
        m.saveState();
    }

    /// Shows the window and project of a folder, when one has it.
    pub fn focusFolder(m: *Main, path: []const u8) bool {
        for (m.shells.items) |sh| for (sh.projects.items, 0..) |wb, i| if (std.mem.eql(u8, wb.root, path)) {
            sh.show(i);
            if (sh.window) |w| w.focus();
            return true;
        };
        return false;
    }

    pub fn keepSession(m: *Main, wb: *Workbench) void {
        var arena: std.heap.ArenaAllocator = .init(m.gpa);
        defer arena.deinit();
        m.state.putSession(wb.session(arena.allocator()));
    }

    /// Writes the projects open and their sessions.
    pub fn saveState(m: *Main) void {
        var roots: std.ArrayList([]const u8) = .empty;
        defer roots.deinit(m.gpa);
        var active: usize = 0;
        for (m.shells.items) |sh| for (sh.projects.items, 0..) |wb, i| {
            m.keepSession(wb);
            if (sh == m.focused and i == sh.current) active = roots.items.len;
            roots.append(m.gpa, wb.root) catch {};
        };
        if (!m.quitting or roots.items.len > 0) m.state.setProjects(roots.items, active);
        m.state.save();
        m.menuIfChanged();
    }

    pub fn closeShell(m: *Main, sh: *Shell) void {
        if (m.ending) return;
        const i = std.mem.indexOfScalar(*Shell, m.shells.items, sh) orelse return;
        // The last window's projects open again at the next start.
        if (m.shells.items.len == 1) m.saveState() else for (sh.projects.items) |wb| m.keepSession(wb);
        _ = m.shells.orderedRemove(i);
        if (m.focused == sh) m.focused = if (m.shells.items.len > 0) m.shells.items[0] else null;
        sh.destroy();
        if (m.shells.items.len == 0) {
            if (!m.ending) m.app.quit();
        } else m.saveState();
    }

    pub fn quit(m: *Main) void {
        m.quitting = true;
        for (m.shells.items) |sh| for (sh.projects.items) |wb| wb.editors.saveAll();
        m.saveState();
        m.app.quit();
    }

    /// Project tabs turned on gather the windows' projects into the one in
    /// front; turned off, they part into a window each.
    pub fn regroup(m: *Main) void {
        const front = m.focused orelse return;
        m.saveState();
        if (m.store.s.projectTabs) {
            var roots: std.ArrayList([]u8) = .empty;
            defer {
                for (roots.items) |r| m.gpa.free(r);
                roots.deinit(m.gpa);
            }
            for (m.shells.items) |sh| if (sh != front) for (sh.projects.items) |wb| {
                roots.append(m.gpa, m.gpa.dupe(u8, wb.root) catch continue) catch {};
            };
            var i = m.shells.items.len;
            while (i > 0) {
                i -= 1;
                const sh = m.shells.items[i];
                if (sh != front) if (sh.window) |w| w.close();
            }
            for (roots.items) |r| _ = front.addProject(r) catch {};
        } else {
            var roots: std.ArrayList([]u8) = .empty;
            defer {
                for (roots.items) |r| m.gpa.free(r);
                roots.deinit(m.gpa);
            }
            while (front.projects.items.len > 1) {
                const wb = front.projects.pop().?;
                m.keepSession(wb);
                roots.append(m.gpa, m.gpa.dupe(u8, wb.root) catch continue) catch {};
                wb.destroy();
            }
            front.current = 0;
            for (roots.items) |r| m.newWindow(&.{r}) catch {};
        }
    }

    /// A later launch's folders and files.
    fn second(m: *Main, s: myzig.SecondInstance) void {
        m.openArgs(s.working_dir, s.args);
    }

    fn openArgs(m: *Main, cwd: []const u8, args: []const []const u8) void {
        for (args) |a| {
            if (std.mem.startsWith(u8, a, "--")) continue;
            const abs = if (std.fs.path.isAbsolute(a)) m.gpa.dupe(u8, a) catch continue else std.fs.path.join(m.gpa, &.{ cwd, a }) catch continue;
            defer m.gpa.free(abs);
            const real = fs.absolute(m.gpa, m.io, abs) catch continue;
            defer m.gpa.free(real);
            if (fs.isDirectory(m.io, real)) {
                if (m.focusFolder(real)) continue;
                if (m.focused) |sh| sh.openFolder(real, false) else m.newWindow(&.{real}) catch {};
            } else {
                // A file opens in the project whose folder holds it.
                var done = false;
                for (m.shells.items) |sh| for (sh.projects.items, 0..) |wb, i| if (!done and std.mem.startsWith(u8, real, wb.root)) {
                    sh.show(i);
                    @import("wb_files.zig").openPath(wb, real, false);
                    if (sh.window) |w| w.focus();
                    done = true;
                };
                if (!done) {
                    const dir = std.fs.path.dirname(real) orelse continue;
                    if (m.focused) |sh| sh.openFolder(dir, false) else m.newWindow(&.{dir}) catch continue;
                    if (m.focused) |sh| if (sh.active()) |wb| @import("wb_files.zig").openPath(wb, real, false);
                }
            }
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var m: Main = undefined;
    const app = try myzig.App.create(init, .{
        .name = "MyCode",
        .id = "com.hunghg255.mycode",
        .on_second_instance = .of(&m, Main.second),
    });
    defer app.destroy();
    // Snapshots and scripts of the dev flags run in this instance alone.
    const dev = for (try init.minimal.args.toSlice(init.arena.allocator())) |a| {
        if (std.mem.startsWith(u8, a, "--myzig-")) break true;
    } else false;
    if (!dev and !app.requestSingleInstanceLock()) return;
    try git.init(init.arena.allocator(), init.environ_map);
    // Threads (search, Git, watching) hand their results to the main thread.
    try @import("mainthread").init();

    m = .{
        .gpa = gpa,
        .io = io,
        .app = app,
        .env = init.environ_map,
        .store = try settings.Store.init(gpa, io, init.environ_map),
        .state = undefined,
        .keymap = .init(gpa),
        .profiles_arena = .init(gpa),
        .menu_arena = .init(gpa),
        .updates = undefined,
    };
    m.updates = .init(gpa, io, m.store.dir);
    defer {
        // Each window closing frees its shell (closeShell).
        while (m.shells.items.len > 0) {
            const sh = m.shells.items[m.shells.items.len - 1];
            if (sh.window) |w| w.close() else {
                _ = m.shells.pop();
                sh.destroy();
            }
        }
        m.ending = true;
        @import("jobs.zig").deinit(gpa);
        m.shells.deinit(gpa);
        m.keymap.deinit();
        m.state.deinit();
        m.store.deinit();
        m.profiles_arena.deinit();
        m.menu_arena.deinit();
        m.updates.deinit();
    }
    @import("crashlog.zig").start(gpa, io, m.store.dir);
    m.state = .load(gpa, io, m.store.state_path);
    m.profiles = termprofiles.find(m.profiles_arena.allocator(), io, init.environ_map, m.store.s.terminalProfiles);
    m.loadKeys();

    // The folders: those named, else the projects open when MyCode quit,
    // else the working directory.
    var roots: std.ArrayList([]const u8) = .empty;
    var files: std.ArrayList([]const u8) = .empty;
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--")) continue;
        const real = fs.absolute(a, io, arg) catch continue;
        if (fs.isDirectory(io, real)) try roots.append(a, real) else {
            try files.append(a, real);
            if (roots.items.len == 0) try roots.append(a, std.fs.path.dirname(real) orelse real);
        }
    }
    if (roots.items.len == 0) for (m.state.f.projects) |p| if (fs.isDirectory(io, p)) try roots.append(a, try a.dupe(u8, p));
    if (roots.items.len == 0) try roots.append(a, try fs.absolute(a, io, "."));

    try m.buildMenu();
    if (m.store.s.projectTabs) {
        try m.newWindow(roots.items);
        if (m.focused) |sh| sh.show(@min(m.state.f.active, sh.projects.items.len - 1));
    } else for (roots.items) |r| try m.newWindow(&.{r});
    for (files.items) |f| if (m.focused) |sh| if (sh.active()) |wb| @import("wb_files.zig").openPath(wb, f, false);
    if (m.focused) |sh| m.updates.window = sh.window;
    m.updates.startTimer();
    try app.run();
}

test {
    _ = fs;
    _ = git;
    _ = settings;
    _ = state_mod;
    _ = keymap;
    _ = @import("quickopen.zig");
    _ = @import("glob.zig");
    _ = @import("conflicts.zig");
    _ = @import("hunks.zig");
    _ = @import("editing.zig");
    _ = @import("symbols.zig");
    _ = @import("review.zig");
    _ = @import("search.zig");
    _ = @import("doc.zig");
    _ = @import("viewer.zig");
    _ = @import("updates.zig");
    _ = commands;
    _ = menubar;
    _ = @import("panel.zig");
    _ = @import("minimap.zig");
    _ = @import("tabdrag.zig");
    _ = @import("scmtree.zig");
}
