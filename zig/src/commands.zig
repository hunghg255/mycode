//! The app's commands, named once: the menu bar, the command palette and
//! the shortcuts all run them through `Workbench.run`, as commands.go does.
const std = @import("std");
const myzig = @import("myzig");

pub const Cmd = enum {
    new_file,
    open_folder,
    save,
    save_as,
    save_all,
    close_tab,
    reopen_tab,
    toggle_auto_save,
    quit,
    find,
    replace,
    go_to_line,
    quick_open,
    command_palette,
    toggle_sidebar,
    show_explorer,
    show_scm,
    toggle_terminal,
    new_terminal,
    toggle_wrap,
    theme_system,
    theme_light,
    theme_dark,
    next_tab,
    prev_tab,
    refresh_explorer,
    collapse_folders,
    reveal_active,
    copy_path,
    copy_relative_path,
    reveal_in_os,
    git_refresh,
};

pub const Info = struct {
    title: []const u8,
    /// The menu bar's accelerator, also shown by the palette.
    accel: []const u8 = "",
    /// The menu the command is in; the palette alone when empty.
    menu: []const u8 = "",
};

pub fn info(cmd: Cmd) Info {
    return switch (cmd) {
        .new_file => .{ .title = "New File", .accel = "CmdOrCtrl+N", .menu = "File" },
        .open_folder => .{ .title = "Open Folder…", .accel = "CmdOrCtrl+O", .menu = "File" },
        .save => .{ .title = "Save", .accel = "CmdOrCtrl+S", .menu = "File" },
        .save_as => .{ .title = "Save As…", .accel = "CmdOrCtrl+Shift+S", .menu = "File" },
        .save_all => .{ .title = "Save All", .accel = "CmdOrCtrl+Alt+S", .menu = "File" },
        .close_tab => .{ .title = "Close Tab", .accel = "CmdOrCtrl+W", .menu = "File" },
        .reopen_tab => .{ .title = "Reopen Closed Tab", .accel = "CmdOrCtrl+Shift+T", .menu = "File" },
        .toggle_auto_save => .{ .title = "Auto Save", .menu = "File" },
        .quit => .{ .title = "Exit", .menu = "File" },
        .find => .{ .title = "Find", .menu = "Edit" },
        .replace => .{ .title = "Replace", .menu = "Edit" },
        .go_to_line => .{ .title = "Go to Line…", .accel = "Ctrl+G", .menu = "Go" },
        .quick_open => .{ .title = "Go to File…", .accel = "CmdOrCtrl+P", .menu = "Go" },
        .command_palette => .{ .title = "Command Palette…", .accel = "CmdOrCtrl+Shift+P", .menu = "View" },
        .toggle_sidebar => .{ .title = "Toggle Sidebar", .accel = "CmdOrCtrl+B", .menu = "View" },
        .show_explorer => .{ .title = "Explorer", .accel = "CmdOrCtrl+Shift+E", .menu = "View" },
        .show_scm => .{ .title = "Source Control", .accel = "Ctrl+Shift+G", .menu = "View" },
        .toggle_terminal => .{ .title = "Toggle Terminal", .accel = "Ctrl+`", .menu = "View" },
        .new_terminal => .{ .title = "New Terminal", .accel = "Ctrl+Shift+`", .menu = "View" },
        .toggle_wrap => .{ .title = "Word Wrap", .accel = "Alt+Z", .menu = "View" },
        .theme_system => .{ .title = "Theme: Follow System", .menu = "View" },
        .theme_light => .{ .title = "Theme: Light", .menu = "View" },
        .theme_dark => .{ .title = "Theme: Dark", .menu = "View" },
        .next_tab => .{ .title = "Next Tab", .accel = "Ctrl+PageDown", .menu = "Go" },
        .prev_tab => .{ .title = "Previous Tab", .accel = "Ctrl+PageUp", .menu = "Go" },
        .refresh_explorer => .{ .title = "Refresh Explorer" },
        .collapse_folders => .{ .title = "Collapse Folders in Explorer" },
        .reveal_active => .{ .title = "Reveal Active File in Explorer" },
        .copy_path => .{ .title = "Copy Path of Active File" },
        .copy_relative_path => .{ .title = "Copy Relative Path of Active File" },
        .reveal_in_os => .{ .title = "Reveal Active File in File Explorer" },
        .git_refresh => .{ .title = "Git: Refresh", .menu = "Git" },
    };
}

pub const all = std.enums.values(Cmd);

/// What the menu bar's items call: they queue the command for the next frame.
pub fn Handler(comptime Target: type) type {
    return struct {
        pub fn of(comptime cmd: Cmd) fn (*Target, *myzig.menu.Item) void {
            return struct {
                fn f(t: *Target, _: *myzig.menu.Item) void {
                    t.queue(cmd);
                }
            }.f;
        }
    };
}

/// The menu bar, built from the commands' menus, in order.
pub fn menuBar(comptime Target: type, target: *Target) [5]myzig.MenuItem {
    const H = Handler(Target);
    const names = [_][]const u8{ "File", "Edit", "View", "Go", "Git" };
    var bar: [5]myzig.MenuItem = undefined;
    inline for (names, 0..) |menu_name, mi| {
        const items = comptime blk: {
            @setEvalBranchQuota(20_000);
            var n: usize = 0;
            for (all) |cmd| if (std.mem.eql(u8, info(cmd).menu, menu_name)) {
                n += 1;
            };
            var cmds: [n]Cmd = undefined;
            var i: usize = 0;
            for (all) |cmd| if (std.mem.eql(u8, info(cmd).menu, menu_name)) {
                cmds[i] = cmd;
                i += 1;
            };
            const final = cmds;
            break :blk final;
        };
        const Static = struct {
            var list: [items.len]myzig.MenuItem = undefined;
        };
        inline for (items, 0..) |cmd, i| {
            const inf = comptime info(cmd);
            Static.list[i] = .{ .label = inf.title, .accelerator = inf.accel, .click = .of(target, H.of(cmd)) };
        }
        bar[mi] = .{ .label = menu_name, .submenu = &Static.list };
    }
    return bar;
}
