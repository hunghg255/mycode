//! The menu bar, laid out as the Go app's: groups between separators,
//! submenus for the themes, conflicts, stashes and terminal profiles,
//! checks on what is on, and accelerators that keybindings.json hasn't
//! taken for itself.
const std = @import("std");
const myzig = @import("myzig");
const commands = @import("commands.zig");
const Cmd = commands.Cmd;
const Settings = @import("settings.zig").Settings;

pub const Entry = union(enum) {
    cmd: Cmd,
    sep,
    sub: Sub,
    /// File → Open Recent: the last ten folders, More… and Clear.
    recent,
    /// The terminal profiles: a new terminal of one, or the default.
    profiles_new,
    profiles_default,
};

pub const Sub = struct { label: []const u8, items: []const Entry };

fn c(cmd: Cmd) Entry {
    return .{ .cmd = cmd };
}

pub const layout = [_]Sub{
    .{ .label = "File", .items = &.{
        c(.new_file),          c(.open_file),        c(.open_folder),     c(.open_folder_new_window), .recent,
        .sep,                  c(.save),             c(.save_as),         c(.save_all),               c(.toggle_auto_save),
        c(.open_settings),     c(.open_keybindings), .sep,                c(.close_tab),              c(.close_all_tabs),
        c(.reopen_tab),        c(.close_folder),     c(.close_project),   .sep,                       c(.install_command),
        c(.uninstall_command), .sep,                 c(.quit),
    } },
    .{ .label = "Edit", .items = &.{
        c(.undo),          c(.redo),             .sep, c(.find), c(.replace), c(.find_next), c(.find_prev), .sep,
        c(.find_in_files), c(.replace_in_files),
    } },
    .{ .label = "Selection", .items = &.{
        c(.select_line),       .sep,                  c(.toggle_comment),   c(.indent_lines),    c(.outdent_lines),   .sep,
        c(.move_line_up),      c(.move_line_down),    c(.copy_line_up),     c(.copy_line_down),  .sep,                c(.insert_line_below),
        c(.insert_line_above), c(.delete_line),       .sep,                 c(.sort_lines_asc),  c(.sort_lines_desc), c(.camel_case),
        c(.snake_case),        c(.upper_case),        c(.lower_case),       c(.trim_whitespace),
    } },
    .{ .label = "View", .items = &.{
        c(.toggle_sidebar),         c(.toggle_sidebar_right), c(.show_explorer),    c(.show_search),     c(.show_scm),         .sep,
        c(.toggle_word_wrap),       c(.toggle_wrap),          c(.toggle_minimap),   c(.toggle_preview),  c(.toggle_project_tabs), c(.toggle_project_icons),
        .sep,                       c(.split_right),          c(.next_column),      c(.prev_column),     c(.move_tab_next),    c(.move_tab_prev),
        c(.toggle_column_lock),     .sep,                     c(.toggle_terminal),  c(.new_terminal),    .profiles_new,        .profiles_default,
        c(.terminal_tab),           c(.terminal_move),        c(.move_terminal_to_column), c(.kill_terminal), c(.maximize_panel), c(.next_terminal),
        c(.prev_terminal),          .sep,                     c(.zoom_in),          c(.zoom_out),        c(.zoom_reset),       .sep,
        .{ .sub = .{ .label = "Theme", .items = &.{
            c(.appearance_system), c(.appearance_light), c(.appearance_dark), .sep,
            c(.theme_mycode),      c(.theme_matrix),     c(.theme_claude),    c(.theme_qoder),
        } } },
        .{ .sub = .{ .label = "File Icon Theme", .items = &.{ c(.icons_material), c(.icons_lucide) } } },
    } },
    .{ .label = "Go", .items = &.{
        c(.quick_open), c(.command_palette), c(.go_to_symbol), c(.go_to_line), c(.go_to_bracket), .sep,
        c(.next_tab),   c(.prev_tab),        .sep,             c(.next_project), c(.prev_project),
    } },
    .{ .label = "Git", .items = &.{
        c(.git_commit),        c(.git_commit_push),   c(.git_commit_amend),  c(.git_undo_commit),   .sep,
        c(.open_changes),      c(.open_all_changes),  c(.next_change),       c(.prev_change),       .sep,
        c(.show_change),       c(.revert_change),     c(.stage_change),      .sep,                  c(.stage_file),
        c(.unstage_file),      c(.stage_all),         .sep,                  c(.git_switch_branch), c(.git_create_branch),
        c(.git_rename_branch), c(.git_delete_branch), c(.git_fetch),         .sep,                  c(.git_pull),
        c(.git_pull_rebase),   c(.git_pull_merge),    c(.git_push),          c(.git_force_push),    c(.git_sync),
        .sep,
        .{ .sub = .{ .label = "Merge Conflicts", .items = &.{
            c(.next_conflict),      c(.prev_conflict),       .sep,             c(.accept_current), c(.accept_incoming), c(.accept_both),
            .sep,                   c(.accept_all_current),  c(.accept_all_incoming), .sep,        c(.git_continue),    c(.git_abort),
        } } },
        .{ .sub = .{ .label = "Stash", .items = &.{
            c(.git_stash),       c(.git_stash_untracked), .sep,               c(.git_stash_apply_latest), c(.git_stash_pop), .sep,
            c(.git_stash_apply), c(.git_stash_pop_pick),  c(.git_stash_view), c(.git_stash_drop),
        } } },
        .sep,
        c(.toggle_blame),       c(.show_all_branches),  c(.scm_tree),    c(.git_refresh),   c(.git_init), .sep,
        c(.add_review_comment), c(.copy_review),        c(.send_review), c(.clear_review),
    } },
    .{ .label = "Help", .items = &.{c(.check_updates)} },
};

/// Whether a command that turns something on or picks one of several has
/// it on; null for the others. The palette checks them too.
pub fn isOn(cmd: Cmd, s: *const Settings) ?bool {
    const eq = std.mem.eql;
    return switch (cmd) {
        .toggle_auto_save => s.autoSave,
        .toggle_word_wrap => s.wordWrap,
        .toggle_minimap => s.minimap,
        .toggle_sidebar_right => s.sidebarRight,
        .toggle_project_tabs => s.projectTabs,
        .toggle_project_icons => s.projectIcons,
        .toggle_blame => s.blame,
        .show_all_branches => s.scmAllBranches,
        .scm_tree => s.scmTree,
        .appearance_system => s.appearance.len == 0,
        .appearance_light => eq(u8, s.appearance, "light"),
        .appearance_dark => eq(u8, s.appearance, "dark"),
        .theme_mycode => s.theme.len == 0,
        .theme_matrix => eq(u8, s.theme, "matrix"),
        .theme_claude => eq(u8, s.theme, "claude"),
        .theme_qoder => eq(u8, s.theme, "qoder"),
        .icons_material => !eq(u8, s.iconTheme, "lucide"),
        .icons_lucide => eq(u8, s.iconTheme, "lucide"),
        else => null,
    };
}

fn radio(cmd: Cmd) bool {
    return switch (cmd) {
        .appearance_system, .appearance_light, .appearance_dark, .theme_mycode, .theme_matrix, .theme_claude, .theme_qoder, .icons_material, .icons_lucide => true,
        else => false,
    };
}

/// What the menu shows that changes: the recent folders, the profiles,
/// the settings and the accelerators keybindings.json leaves.
pub const Live = struct {
    recent: []const []const u8,
    profiles: []const []const u8,
    default_profile: usize,
    settings: *const Settings,
    /// Review comments wait to be sent.
    reviewing: bool,
    /// The accelerator of a command, "" where keybindings.json takes it.
    accel: *const fn (ctx: *anyopaque, cmd: Cmd) []const u8,
    ctx: *anyopaque,
};

/// The menu bar; its items are in `a`, kept while the menu shows. `Target`
/// has `queue(cmd)`, `recentHandler(k)`, `clearRecentItem` and
/// `profileHandler(k, new)`.
pub fn build(comptime Target: type, target: *Target, a: std.mem.Allocator, live: Live) ![]const myzig.MenuItem {
    var bar: std.ArrayList(myzig.MenuItem) = .empty;
    inline for (layout) |m| {
        try bar.append(a, .{ .label = m.label, .submenu = try items(Target, target, a, live, m.items) });
    }
    return bar.items;
}

fn items(comptime Target: type, target: *Target, a: std.mem.Allocator, live: Live, comptime list: []const Entry) ![]const myzig.MenuItem {
    var out: std.ArrayList(myzig.MenuItem) = .empty;
    inline for (list) |e| switch (e) {
        .sep => try out.append(a, .separator),
        .sub => |s| try out.append(a, .{ .label = s.label, .submenu = try items(Target, target, a, live, s.items) }),
        .cmd => |cmd| {
            const on = isOn(cmd, live.settings);
            const review = cmd == .copy_review or cmd == .send_review or cmd == .clear_review;
            try out.append(a, .{
                .label = commands.info(cmd).title,
                .accelerator = live.accel(live.ctx, cmd),
                .kind = if (on == null) .normal else if (radio(cmd)) .radio else .checkbox,
                .checked = on orelse false,
                .disabled = review and !live.reviewing,
                .click = .of(target, handler(Target, cmd)),
            });
        },
        .recent => {
            var sub: std.ArrayList(myzig.MenuItem) = .empty;
            inline for (0..10) |k| if (k < live.recent.len) {
                try sub.append(a, .{ .label = try a.dupe(u8, live.recent[k]), .click = .of(target, Target.recentHandler(k)) });
            };
            if (live.recent.len > 0) try sub.append(a, .separator);
            try sub.append(a, .{ .label = "More…", .click = .of(target, handler(Target, .open_recent)) });
            try sub.append(a, .{ .label = "Clear Recently Opened", .click = .of(target, Target.clearRecentItem) });
            try out.append(a, .{ .label = "Open Recent", .submenu = sub.items });
        },
        .profiles_new, .profiles_default => {
            const new = e == .profiles_new;
            var sub: std.ArrayList(myzig.MenuItem) = .empty;
            inline for (0..12) |k| if (k < live.profiles.len) {
                try sub.append(a, .{
                    .label = try a.dupe(u8, live.profiles[k]),
                    .kind = if (new) .normal else .radio,
                    .checked = !new and k == live.default_profile,
                    .click = .of(target, Target.profileHandler(k, new)),
                });
            };
            try out.append(a, .{ .label = if (new) "New Terminal with Profile" else "Default Terminal Profile", .submenu = sub.items });
        },
    };
    return out.items;
}

fn handler(comptime Target: type, comptime cmd: Cmd) fn (*Target, *myzig.menu.Item) void {
    return struct {
        fn f(t: *Target, _: *myzig.menu.Item) void {
            t.queue(cmd);
        }
    }.f;
}

test "every command in a menu is there once" {
    var seen: std.EnumSet(Cmd) = .empty;
    const S = struct {
        fn walk(set: *std.EnumSet(Cmd), list: []const Entry) !void {
            for (list) |e| switch (e) {
                .cmd => |cmd| {
                    try std.testing.expect(!set.contains(cmd));
                    set.insert(cmd);
                },
                .sub => |s| try walk(set, s.items),
                else => {},
            };
        }
    };
    for (layout) |m| try S.walk(&seen, m.items);
    try std.testing.expect(seen.contains(.git_abort));
}
