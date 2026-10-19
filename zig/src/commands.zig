//! The app's commands, named once: the menu bar, the command palette,
//! keybindings.json and the keys all run them through `Workbench.run`, as
//! commands.go does. `accel` is the menu bar's accelerator, taken before
//! the window sees the key; `key` is a key the window takes itself (the
//! editor's, which text fields and terminals keep for themselves).
const std = @import("std");
const myzig = @import("myzig");

pub const Cmd = enum {
    // File
    new_file,
    open_file,
    open_folder,
    open_folder_new_window,
    open_recent,
    save,
    save_as,
    save_all,
    toggle_auto_save,
    close_tab,
    close_all_tabs,
    reopen_tab,
    close_project,
    open_settings,
    open_keybindings,
    install_command,
    uninstall_command,
    quit,
    // Edit
    find,
    replace,
    find_in_files,
    replace_in_files,
    // Selection
    move_line_up,
    move_line_down,
    copy_line_up,
    copy_line_down,
    delete_line,
    insert_line_below,
    insert_line_above,
    sort_lines_asc,
    sort_lines_desc,
    upper_case,
    lower_case,
    camel_case,
    snake_case,
    trim_whitespace,
    // View
    command_palette,
    toggle_sidebar,
    show_explorer,
    show_search,
    show_scm,
    toggle_terminal,
    new_terminal,
    maximize_panel,
    toggle_wrap,
    toggle_minimap,
    toggle_preview,
    split_right,
    toggle_column_lock,
    move_terminal_to_column,
    zoom_in,
    zoom_out,
    zoom_reset,
    theme_mycode,
    theme_matrix,
    theme_claude,
    theme_qoder,
    icons_material,
    icons_lucide,
    appearance_system,
    appearance_light,
    appearance_dark,
    toggle_sidebar_right,
    toggle_project_tabs,
    // Go
    quick_open,
    go_to_line,
    go_to_symbol,
    next_tab,
    prev_tab,
    next_column,
    next_change,
    prev_change,
    next_project,
    prev_project,
    next_terminal,
    prev_terminal,
    // Git
    git_commit,
    git_commit_amend,
    git_undo_commit,
    git_push,
    git_force_push,
    git_pull,
    git_pull_rebase,
    git_pull_merge,
    git_fetch,
    git_sync,
    git_switch_branch,
    git_create_branch,
    git_rename_branch,
    git_delete_branch,
    git_stash,
    git_stash_untracked,
    git_stash_apply_latest,
    git_stash_pop,
    git_stash_apply,
    git_stash_pop_pick,
    git_stash_view,
    git_stash_drop,
    open_changes,
    stage_change,
    revert_change,
    toggle_blame,
    accept_current,
    accept_incoming,
    accept_both,
    accept_all_current,
    accept_all_incoming,
    next_conflict,
    prev_conflict,
    add_review_comment,
    copy_review,
    send_review,
    clear_review,
    show_all_branches,
    scm_tree,
    git_init,
    git_refresh,
    // The palette's alone
    refresh_explorer,
    collapse_folders,
    reveal_active,
    copy_path,
    copy_relative_path,
    reveal_in_os,
    indent_tabs,
    indent_spaces_2,
    indent_spaces_4,
    indent_spaces_8,
    check_updates,
};

pub const Info = struct {
    title: []const u8,
    /// The menu bar's accelerator.
    accel: []const u8 = "",
    /// A key the window takes, with the Mac's symbols (`ui.keys.label`).
    key: []const u8 = "",
    /// The menu the command is in; the palette alone when empty.
    menu: []const u8 = "",
};

pub fn info(cmd: Cmd) Info {
    return switch (cmd) {
        .new_file => .{ .title = "New File", .accel = "CmdOrCtrl+N", .menu = "File" },
        .open_file => .{ .title = "Open File…", .menu = "File" },
        .open_folder => .{ .title = "Open Folder…", .accel = "CmdOrCtrl+O", .menu = "File" },
        .open_folder_new_window => .{ .title = "Open Folder in New Window…", .accel = "CmdOrCtrl+Alt+O", .menu = "File" },
        .open_recent => .{ .title = "Open Recent…", .key = "⌃R", .menu = "File" },
        .save => .{ .title = "Save", .accel = "CmdOrCtrl+S", .menu = "File" },
        .save_as => .{ .title = "Save As…", .accel = "CmdOrCtrl+Shift+S", .menu = "File" },
        .save_all => .{ .title = "Save All", .accel = "CmdOrCtrl+Alt+S", .menu = "File" },
        .toggle_auto_save => .{ .title = "Auto Save", .menu = "File" },
        .close_tab => .{ .title = "Close Tab", .accel = "CmdOrCtrl+W", .menu = "File" },
        .close_all_tabs => .{ .title = "Close All Tabs", .menu = "File" },
        .reopen_tab => .{ .title = "Reopen Closed Tab", .accel = "CmdOrCtrl+Shift+T", .menu = "File" },
        .close_project => .{ .title = "Close Project", .menu = "File" },
        .open_settings => .{ .title = "Open Settings", .accel = "CmdOrCtrl+,", .menu = "File" },
        .open_keybindings => .{ .title = "Open Keyboard Shortcuts", .menu = "File" },
        .install_command => .{ .title = "Install 'mycode' Command and Explorer Menu", .menu = "File" },
        .uninstall_command => .{ .title = "Uninstall 'mycode' Command and Explorer Menu", .menu = "File" },
        .quit => .{ .title = "Exit", .menu = "File" },
        .find => .{ .title = "Find", .key = "⌘F", .menu = "Edit" },
        .replace => .{ .title = "Replace", .key = "⌥⌘F", .menu = "Edit" },
        .find_in_files => .{ .title = "Find in Files", .accel = "CmdOrCtrl+Shift+F", .menu = "Edit" },
        .replace_in_files => .{ .title = "Replace in Files", .accel = "CmdOrCtrl+Shift+H", .menu = "Edit" },
        .move_line_up => .{ .title = "Move Line Up", .key = "⌥↑", .menu = "Selection" },
        .move_line_down => .{ .title = "Move Line Down", .key = "⌥↓", .menu = "Selection" },
        .copy_line_up => .{ .title = "Copy Line Up", .key = "⇧⌥↑", .menu = "Selection" },
        .copy_line_down => .{ .title = "Copy Line Down", .key = "⇧⌥↓", .menu = "Selection" },
        .delete_line => .{ .title = "Delete Line", .key = "⇧⌘K", .menu = "Selection" },
        .insert_line_below => .{ .title = "Insert Line Below", .key = "⌘↵", .menu = "Selection" },
        .insert_line_above => .{ .title = "Insert Line Above", .key = "⇧⌘↵", .menu = "Selection" },
        .sort_lines_asc => .{ .title = "Sort Lines Ascending", .menu = "Selection" },
        .sort_lines_desc => .{ .title = "Sort Lines Descending", .menu = "Selection" },
        .upper_case => .{ .title = "Transform to Uppercase", .menu = "Selection" },
        .lower_case => .{ .title = "Transform to Lowercase", .menu = "Selection" },
        .camel_case => .{ .title = "Transform to Camel Case", .menu = "Selection" },
        .snake_case => .{ .title = "Transform to Snake Case", .menu = "Selection" },
        .trim_whitespace => .{ .title = "Trim Trailing Whitespace", .menu = "Selection" },
        .command_palette => .{ .title = "Command Palette…", .accel = "CmdOrCtrl+Shift+P", .menu = "View" },
        .toggle_sidebar => .{ .title = "Toggle Sidebar", .accel = "CmdOrCtrl+B", .menu = "View" },
        .show_explorer => .{ .title = "Explorer", .accel = "CmdOrCtrl+Shift+E", .menu = "View" },
        .show_search => .{ .title = "Search", .menu = "View" },
        .show_scm => .{ .title = "Source Control", .accel = "Ctrl+Shift+G", .menu = "View" },
        .toggle_terminal => .{ .title = "Toggle Terminal", .accel = "Ctrl+`", .menu = "View" },
        .new_terminal => .{ .title = "New Terminal", .accel = "Ctrl+Shift+`", .menu = "View" },
        .maximize_panel => .{ .title = "Maximize Panel", .menu = "View" },
        .toggle_wrap => .{ .title = "Word Wrap", .key = "⌥Z", .menu = "View" },
        .toggle_minimap => .{ .title = "Minimap", .menu = "View" },
        .toggle_preview => .{ .title = "Toggle Preview", .key = "⇧⌘V", .menu = "View" },
        .split_right => .{ .title = "Split Editor Right", .accel = "CmdOrCtrl+\\", .menu = "View" },
        .toggle_column_lock => .{ .title = "Toggle Column Lock", .menu = "View" },
        .move_terminal_to_column => .{ .title = "Move Terminal to Locked Right Column", .menu = "View" },
        .zoom_in => .{ .title = "Zoom In", .accel = "CmdOrCtrl+=", .menu = "View" },
        .zoom_out => .{ .title = "Zoom Out", .accel = "CmdOrCtrl+-", .menu = "View" },
        .zoom_reset => .{ .title = "Reset Zoom", .accel = "CmdOrCtrl+0", .menu = "View" },
        .theme_mycode => .{ .title = "Theme: MyCode", .menu = "View" },
        .theme_matrix => .{ .title = "Theme: The Matrix", .menu = "View" },
        .theme_claude => .{ .title = "Theme: Claude", .menu = "View" },
        .theme_qoder => .{ .title = "Theme: Qoder", .menu = "View" },
        .icons_material => .{ .title = "File Icon Theme: Material", .menu = "View" },
        .icons_lucide => .{ .title = "File Icon Theme: Lucide", .menu = "View" },
        .appearance_system => .{ .title = "Appearance: Follow System", .menu = "View" },
        .appearance_light => .{ .title = "Appearance: Light", .menu = "View" },
        .appearance_dark => .{ .title = "Appearance: Dark", .menu = "View" },
        .toggle_sidebar_right => .{ .title = "Sidebar on Right", .menu = "View" },
        .toggle_project_tabs => .{ .title = "Project Tabs", .menu = "View" },
        .quick_open => .{ .title = "Go to File…", .accel = "CmdOrCtrl+P", .menu = "Go" },
        .go_to_line => .{ .title = "Go to Line…", .key = "⌃G", .menu = "Go" },
        .go_to_symbol => .{ .title = "Go to Symbol…", .accel = "CmdOrCtrl+Shift+O", .menu = "Go" },
        .next_tab => .{ .title = "Next Tab", .accel = "Ctrl+Tab", .menu = "Go" },
        .prev_tab => .{ .title = "Previous Tab", .accel = "Ctrl+Shift+Tab", .menu = "Go" },
        .next_column => .{ .title = "Next Column", .menu = "Go" },
        .next_change => .{ .title = "Next Change", .accel = "Alt+F5", .menu = "Go" },
        .prev_change => .{ .title = "Previous Change", .accel = "Shift+Alt+F5", .menu = "Go" },
        .next_project => .{ .title = "Next Project", .accel = "CmdOrCtrl+Shift+]", .menu = "Go" },
        .prev_project => .{ .title = "Previous Project", .accel = "CmdOrCtrl+Shift+[", .menu = "Go" },
        .next_terminal => .{ .title = "Next Terminal", .menu = "Go" },
        .prev_terminal => .{ .title = "Previous Terminal", .menu = "Go" },
        .git_commit => .{ .title = "Commit", .menu = "Git" },
        .git_commit_amend => .{ .title = "Amend Last Commit", .menu = "Git" },
        .git_undo_commit => .{ .title = "Undo Last Commit", .menu = "Git" },
        .git_push => .{ .title = "Push", .menu = "Git" },
        .git_force_push => .{ .title = "Force Push…", .menu = "Git" },
        .git_pull => .{ .title = "Pull", .menu = "Git" },
        .git_pull_rebase => .{ .title = "Pull (Rebase)", .menu = "Git" },
        .git_pull_merge => .{ .title = "Pull (Merge)", .menu = "Git" },
        .git_fetch => .{ .title = "Fetch", .menu = "Git" },
        .git_sync => .{ .title = "Sync", .menu = "Git" },
        .git_switch_branch => .{ .title = "Switch Branch…", .menu = "Git" },
        .git_create_branch => .{ .title = "Create Branch…", .menu = "Git" },
        .git_rename_branch => .{ .title = "Rename Branch…", .menu = "Git" },
        .git_delete_branch => .{ .title = "Delete Branch…", .menu = "Git" },
        .git_stash => .{ .title = "Stash…", .menu = "Git" },
        .git_stash_untracked => .{ .title = "Stash (Include Untracked)…", .menu = "Git" },
        .git_stash_apply_latest => .{ .title = "Apply Latest Stash", .menu = "Git" },
        .git_stash_pop => .{ .title = "Pop Latest Stash", .menu = "Git" },
        .git_stash_apply => .{ .title = "Apply Stash…", .menu = "Git" },
        .git_stash_pop_pick => .{ .title = "Pop Stash…", .menu = "Git" },
        .git_stash_view => .{ .title = "View Stash…", .menu = "Git" },
        .git_stash_drop => .{ .title = "Drop Stash…", .menu = "Git" },
        .open_changes => .{ .title = "Open Changes", .menu = "Git" },
        .stage_change => .{ .title = "Stage Change at Caret", .menu = "Git" },
        .revert_change => .{ .title = "Revert Change at Caret", .menu = "Git" },
        .toggle_blame => .{ .title = "Inline Blame", .menu = "Git" },
        .accept_current => .{ .title = "Accept Current Change", .menu = "Git" },
        .accept_incoming => .{ .title = "Accept Incoming Change", .menu = "Git" },
        .accept_both => .{ .title = "Accept Both Changes", .menu = "Git" },
        .accept_all_current => .{ .title = "Accept All Current Changes", .menu = "Git" },
        .accept_all_incoming => .{ .title = "Accept All Incoming Changes", .menu = "Git" },
        .next_conflict => .{ .title = "Next Conflict", .menu = "Git" },
        .prev_conflict => .{ .title = "Previous Conflict", .menu = "Git" },
        .add_review_comment => .{ .title = "Add Review Comment", .key = "⇧⌘M", .menu = "Git" },
        .copy_review => .{ .title = "Copy Review Comments", .menu = "Git" },
        .send_review => .{ .title = "Send Review Comments to Terminal", .menu = "Git" },
        .clear_review => .{ .title = "Clear Review Comments", .menu = "Git" },
        .show_all_branches => .{ .title = "Show All Branches", .menu = "Git" },
        .scm_tree => .{ .title = "View Changes as Tree", .menu = "Git" },
        .git_init => .{ .title = "Initialize Repository", .menu = "Git" },
        .git_refresh => .{ .title = "Refresh", .menu = "Git" },
        .refresh_explorer => .{ .title = "Refresh Explorer" },
        .collapse_folders => .{ .title = "Collapse Folders in Explorer" },
        .reveal_active => .{ .title = "Reveal Active File in Explorer" },
        .copy_path => .{ .title = "Copy Path of Active File" },
        .copy_relative_path => .{ .title = "Copy Relative Path of Active File" },
        .reveal_in_os => .{ .title = "Reveal Active File in File Explorer" },
        .indent_tabs => .{ .title = "Indent Using Tabs" },
        .indent_spaces_2 => .{ .title = "Indent Using 2 Spaces" },
        .indent_spaces_4 => .{ .title = "Indent Using 4 Spaces" },
        .indent_spaces_8 => .{ .title = "Indent Using 8 Spaces" },
        .check_updates => .{ .title = "Check for Updates…", .menu = "Help" },
    };
}

pub const all = std.enums.values(Cmd);

/// A command by its id: its name, as `toggle_sidebar` or `mycode.toggle_sidebar`.
pub fn byId(id: []const u8) ?Cmd {
    const n = if (std.mem.startsWith(u8, id, "mycode.")) id[7..] else id;
    return std.meta.stringToEnum(Cmd, n);
}

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

const menu_names = [_][]const u8{ "File", "Edit", "Selection", "View", "Go", "Git", "Help" };

/// The menu bar, built from the commands' menus, in order, with the
/// recent folders under File → Open Recent. Its items are in `a`, kept
/// while the menu shows.
pub fn menuBar(comptime Target: type, target: *Target, a: std.mem.Allocator, recent: []const []const u8) ![]const myzig.MenuItem {
    const H = Handler(Target);
    var bar: std.ArrayList(myzig.MenuItem) = .empty;
    inline for (menu_names) |menu_name| {
        const items = comptime blk: {
            @setEvalBranchQuota(100_000);
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
        var list: std.ArrayList(myzig.MenuItem) = .empty;
        inline for (items) |cmd| {
            const inf = comptime info(cmd);
            if (cmd == .open_recent) {
                // The last ten folders, then More… and Clear.
                var sub: std.ArrayList(myzig.MenuItem) = .empty;
                inline for (0..10) |k| if (k < recent.len) {
                    try sub.append(a, .{ .label = try a.dupe(u8, recent[k]), .click = .of(target, Target.recentHandler(k)) });
                };
                if (recent.len > 0) try sub.append(a, .separator);
                try sub.append(a, .{ .label = "More…", .accelerator = "", .click = .of(target, H.of(.open_recent)) });
                try sub.append(a, .{ .label = "Clear Recently Opened", .click = .of(target, Target.clearRecentItem) });
                try list.append(a, .{ .label = "Open Recent", .submenu = sub.items });
            } else try list.append(a, .{ .label = inf.title, .accelerator = inf.accel, .click = .of(target, H.of(cmd)) });
        }
        try bar.append(a, .{ .label = menu_name, .submenu = list.items });
    }
    return bar.items;
}
