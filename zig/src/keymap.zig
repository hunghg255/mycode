//! keybindings.json, in VS Code's format (comments and trailing commas
//! too): keys and chords bound to MyCode's commands or VS Code's names for
//! them, with `when` conditions, applied on top of the built-in keys.
const std = @import("std");
const builtin = @import("builtin");
const myzig = @import("myzig");
const ui = myzig.ui;
const commands = @import("commands.zig");
const Cmd = commands.Cmd;

pub const Key = struct {
    key: u21,
    cmd: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,

    pub fn shortcut(k: Key) ui.Shortcut {
        return .{ .key = k.key, .cmd = k.cmd, .ctrl = k.ctrl, .alt = k.alt, .shift = k.shift };
    }
};

pub const Binding = struct {
    keys: [2]Key,
    len: u8,
    /// The command, or null for one taken away ("-command").
    cmd: ?Cmd,
    remove: bool = false,
    when: []const u8 = "",
    /// `type` and `sendSequence`'s text.
    text: []const u8 = "",
    action: Action = .run,
};

pub const Action = enum { run, type_text, send_sequence, open };

/// What `when` conditions read.
pub const Context = struct {
    editor_focus: bool = false,
    terminal_focus: bool = false,
    input_focus: bool = false,
    explorer_focus: bool = false,
    sidebar_visible: bool = false,
    terminal_open: bool = false,
    has_selection: bool = false,
};

pub const Keymap = struct {
    arena: std.heap.ArenaAllocator,
    bindings: []Binding = &.{},
    /// The first key of a chord, waiting for its second.
    pending: ?Key = null,
    /// Keys and conditions the file had that weren't understood.
    errors: []const []const u8 = &.{},

    pub fn init(gpa: std.mem.Allocator) Keymap {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(k: *Keymap) void {
        k.arena.deinit();
    }

    pub fn load(k: *Keymap, data: []const u8) void {
        _ = k.arena.reset(.retain_capacity);
        const a = k.arena.allocator();
        k.bindings = &.{};
        const clean = stripJsonc(a, data) catch return;
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, clean, .{}) catch return;
        if (v != .array) return;
        var list: std.ArrayList(Binding) = .empty;
        var errs: std.ArrayList([]const u8) = .empty;
        for (v.array.items) |e| {
            if (e != .object) continue;
            const key = e.object.get("key") orelse continue;
            const command = e.object.get("command") orelse continue;
            if (key != .string or command != .string) continue;
            var b: Binding = .{ .keys = undefined, .len = 0, .cmd = null };
            var it = std.mem.tokenizeScalar(u8, key.string, ' ');
            var ok = true;
            while (it.next()) |part| {
                if (b.len == 2) break;
                b.keys[b.len] = parseKey(part) orelse {
                    ok = false;
                    break;
                };
                b.len += 1;
            }
            if (!ok or b.len == 0) {
                errs.append(a, a.dupe(u8, key.string) catch "") catch {};
                continue;
            }
            var cmd_name = command.string;
            if (std.mem.startsWith(u8, cmd_name, "-")) {
                b.remove = true;
                cmd_name = cmd_name[1..];
            }
            if (std.mem.eql(u8, cmd_name, "type") or std.mem.eql(u8, cmd_name, "workbench.action.terminal.sendSequence")) {
                b.action = if (std.mem.eql(u8, cmd_name, "type")) .type_text else .send_sequence;
                if (e.object.get("args")) |args| if (args == .object) if (args.object.get("text")) |t| if (t == .string) {
                    b.text = t.string;
                };
            } else if (std.mem.eql(u8, cmd_name, "vscode.open")) {
                b.action = .open;
                if (e.object.get("args")) |args| if (args == .string) {
                    b.text = args.string;
                };
            } else {
                b.cmd = commandFor(cmd_name) orelse {
                    errs.append(a, a.dupe(u8, cmd_name) catch "") catch {};
                    continue;
                };
            }
            if (e.object.get("when")) |w| if (w == .string) {
                b.when = w.string;
            };
            list.append(a, b) catch {};
        }
        k.bindings = list.items;
        k.errors = errs.items;
    }

    /// The binding this event's key completes, if any; chords wait for their
    /// second key. Takes the key.
    pub fn match(k: *Keymap, c: *ui.Context, cx: Context) ?*const Binding {
        if (k.bindings.len == 0) return null;
        const sc = c.input.shortcut orelse return null;
        const pressed: Key = .{ .key = sc.key, .cmd = sc.cmd, .ctrl = sc.ctrl, .alt = sc.alt, .shift = sc.shift };
        if (k.pending) |first| {
            k.pending = null;
            var i = k.bindings.len;
            while (i > 0) {
                i -= 1;
                const b = &k.bindings[i];
                if (b.len == 2 and eqlKey(b.keys[0], first) and eqlKey(b.keys[1], pressed) and holds(b.when, cx)) {
                    _ = c.shortcut(sc);
                    return if (b.remove) null else b;
                }
            }
            _ = c.shortcut(sc); // a chord's unbound second key ends it
            return null;
        }
        // Later bindings win, as in VS Code.
        var i = k.bindings.len;
        while (i > 0) {
            i -= 1;
            const b = &k.bindings[i];
            if (!eqlKey(b.keys[0], pressed) or !holds(b.when, cx)) continue;
            if (b.len == 2) {
                k.pending = pressed;
                _ = c.shortcut(sc);
                return null;
            }
            if (b.remove) return null;
            _ = c.shortcut(sc);
            return b;
        }
        return null;
    }

    /// Whether the file binds the keys of accelerator `accel` (as the first
    /// of a chord too), or takes `cmd` off them: the menu then leaves them.
    pub fn takesAccel(k: *const Keymap, accel: []const u8, cmd: Cmd) bool {
        const key = parseKey(accel) orelse return false;
        for (k.bindings) |b| {
            if (b.remove and b.cmd == cmd) return true;
            if (!b.remove and eqlKey(b.keys[0], key)) return true;
        }
        return false;
    }

    /// The key the file binds a command to, for menus and the palette.
    pub fn keyFor(k: *const Keymap, cmd: Cmd) ?Key {
        var i = k.bindings.len;
        while (i > 0) {
            i -= 1;
            const b = k.bindings[i];
            if (b.cmd == cmd and !b.remove and b.len == 1) return b.keys[0];
        }
        return null;
    }
};

/// Two keys are the same, Command being Control off macOS.
pub fn sameKey(a: Key, b: Key) bool {
    return eqlKey(a, b);
}

fn eqlKey(a: Key, b: Key) bool {
    // Command is Control off macOS.
    const ac = a.cmd or (!ui.keys.mac and a.ctrl);
    const bc = b.cmd or (!ui.keys.mac and b.ctrl);
    const actrl = if (ui.keys.mac) a.ctrl else false;
    const bctrl = if (ui.keys.mac) b.ctrl else false;
    return std.ascii.toLower(@intCast(@min(a.key, 127))) == std.ascii.toLower(@intCast(@min(b.key, 127))) and
        (a.key > 127) == (b.key > 127) and (a.key <= 127 or a.key == b.key) and
        ac == bc and actrl == bctrl and a.alt == b.alt and a.shift == b.shift;
}

/// "ctrl+shift+p", "cmd+k", "alt+up", "f5".
pub fn parseKey(s: []const u8) ?Key {
    var k: Key = .{ .key = 0 };
    var it = std.mem.splitScalar(u8, s, '+');
    var last: []const u8 = "";
    while (it.next()) |part0| {
        const part = std.mem.trim(u8, part0, " ");
        if (part.len == 0) {
            last = "+";
            continue;
        }
        if (eq(part, "cmdorctrl") or eq(part, "commandorcontrol")) {
            k.cmd = true;
        } else if (eq(part, "cmd") or eq(part, "meta") or eq(part, "win")) {
            k.cmd = true;
        } else if (eq(part, "ctrl")) {
            if (ui.keys.mac) k.ctrl = true else k.cmd = true;
        } else if (eq(part, "alt") or eq(part, "option")) {
            k.alt = true;
        } else if (eq(part, "shift")) {
            k.shift = true;
        } else last = part;
    }
    k.key = named(last) orelse return null;
    return k;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn named(s: []const u8) ?u21 {
    if (s.len == 1) return std.ascii.toLower(s[0]);
    const S = ui.Shortcut;
    const pairs = [_]struct { []const u8, u21 }{
        .{ "up", S.up },         .{ "down", S.down },      .{ "left", S.left },   .{ "right", S.right },
        .{ "enter", S.enter },   .{ "escape", S.escape },  .{ "tab", S.tab },     .{ "backspace", S.backspace },
        .{ "delete", S.delete }, .{ "home", S.home },      .{ "end", S.end },     .{ "pageup", S.page_up },
        .{ "pagedown", S.page_down }, .{ "space", ' ' },   .{ "f1", S.f1 },       .{ "f2", S.f1 + 1 },
        .{ "f3", S.f1 + 2 },     .{ "f4", S.f1 + 3 },      .{ "f5", S.f1 + 4 },   .{ "f6", S.f1 + 5 },
        .{ "f7", S.f1 + 6 },     .{ "f8", S.f1 + 7 },      .{ "f9", S.f1 + 8 },   .{ "f10", S.f1 + 9 },
        .{ "f11", S.f1 + 10 },   .{ "f12", S.f1 + 11 },    .{ "oem_3", '`' },     .{ "backquote", '`' },
    };
    for (pairs) |p| if (eq(s, p[0])) return p[1];
    return null;
}

/// A `when` clause: names, `!`, `&&`, `||` and parentheses.
pub fn holds(when: []const u8, cx: Context) bool {
    if (std.mem.trim(u8, when, " ").len == 0) return true;
    var p: Parser = .{ .s = when, .cx = cx };
    return p.orExpr();
}

const Parser = struct {
    s: []const u8,
    i: usize = 0,
    cx: Context,

    fn skip(p: *Parser) void {
        while (p.i < p.s.len and p.s[p.i] == ' ') p.i += 1;
    }

    fn orExpr(p: *Parser) bool {
        var v = p.andExpr();
        while (true) {
            p.skip();
            if (std.mem.startsWith(u8, p.s[p.i..], "||")) {
                p.i += 2;
                const r = p.andExpr();
                v = v or r;
            } else return v;
        }
    }

    fn andExpr(p: *Parser) bool {
        var v = p.unary();
        while (true) {
            p.skip();
            if (std.mem.startsWith(u8, p.s[p.i..], "&&")) {
                p.i += 2;
                const r = p.unary();
                v = v and r;
            } else return v;
        }
    }

    fn unary(p: *Parser) bool {
        p.skip();
        if (p.i < p.s.len and p.s[p.i] == '!') {
            p.i += 1;
            return !p.unary();
        }
        if (p.i < p.s.len and p.s[p.i] == '(') {
            p.i += 1;
            const v = p.orExpr();
            p.skip();
            if (p.i < p.s.len and p.s[p.i] == ')') p.i += 1;
            return v;
        }
        const start = p.i;
        while (p.i < p.s.len and (std.ascii.isAlphanumeric(p.s[p.i]) or p.s[p.i] == '.' or p.s[p.i] == '_')) p.i += 1;
        return name(p.s[start..p.i], p.cx);
    }
};

fn name(n: []const u8, cx: Context) bool {
    const os = builtin.os.tag;
    const table = [_]struct { []const u8, bool }{
        .{ "editorTextFocus", cx.editor_focus },     .{ "editorFocus", cx.editor_focus },
        .{ "inputFocus", cx.input_focus },           .{ "textInputFocus", cx.input_focus or cx.editor_focus },
        .{ "filesExplorerFocus", cx.explorer_focus }, .{ "terminalFocus", cx.terminal_focus },
        .{ "terminalHasBeenCreated", cx.terminal_open }, .{ "terminalIsOpen", cx.terminal_open },
        .{ "sideBarVisible", cx.sidebar_visible },   .{ "editorHasSelection", cx.has_selection },
        .{ "isMac", os == .macos },                  .{ "isLinux", os == .linux },
        .{ "isWindows", os == .windows },            .{ "true", true },
    };
    for (table) |e| if (std.mem.eql(u8, e[0], n)) return e[1];
    return false;
}

/// Strips `//` and `/* */` comments and trailing commas, outside strings.
pub fn stripJsonc(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var in_str = false;
    while (i < s.len) {
        const ch = s[i];
        if (in_str) {
            try out.append(a, ch);
            if (ch == '\\' and i + 1 < s.len) {
                try out.append(a, s[i + 1]);
                i += 2;
                continue;
            }
            if (ch == '"') in_str = false;
            i += 1;
        } else if (ch == '"') {
            in_str = true;
            try out.append(a, ch);
            i += 1;
        } else if (std.mem.startsWith(u8, s[i..], "//")) {
            while (i < s.len and s[i] != '\n') i += 1;
        } else if (std.mem.startsWith(u8, s[i..], "/*")) {
            i = if (std.mem.indexOfPos(u8, s, i + 2, "*/")) |e| e + 2 else s.len;
        } else if (ch == ',') {
            var j = i + 1;
            while (j < s.len and std.ascii.isWhitespace(s[j])) j += 1;
            if (j < s.len and (s[j] == ']' or s[j] == '}')) {
                i += 1;
                continue;
            }
            try out.append(a, ch);
            i += 1;
        } else {
            try out.append(a, ch);
            i += 1;
        }
    }
    return out.items;
}

/// MyCode's command ids and VS Code's names for them.
pub fn commandFor(n: []const u8) ?Cmd {
    if (commands.byId(n)) |c| return c;
    const vs = [_]struct { []const u8, Cmd }{
        .{ "workbench.action.toggleSidebarVisibility", .toggle_sidebar },
        .{ "workbench.action.quickOpen", .quick_open },
        .{ "workbench.action.showCommands", .command_palette },
        .{ "workbench.action.files.save", .save },
        .{ "workbench.action.files.saveAs", .save_as },
        .{ "workbench.action.files.saveAll", .save_all },
        .{ "workbench.action.files.newUntitledFile", .new_file },
        .{ "workbench.action.closeActiveEditor", .close_tab },
        .{ "workbench.action.reopenClosedEditor", .reopen_tab },
        .{ "workbench.action.terminal.toggleTerminal", .toggle_terminal },
        .{ "workbench.action.terminal.new", .new_terminal },
        .{ "workbench.action.nextEditor", .next_tab },
        .{ "workbench.action.previousEditor", .prev_tab },
        .{ "workbench.action.splitEditor", .split_right },
        .{ "workbench.action.findInFiles", .find_in_files },
        .{ "workbench.action.replaceInFiles", .replace_in_files },
        .{ "workbench.view.explorer", .show_explorer },
        .{ "workbench.view.scm", .show_scm },
        .{ "workbench.view.search", .find_in_files },
        .{ "workbench.action.gotoLine", .go_to_line },
        .{ "workbench.action.gotoSymbol", .go_to_symbol },
        .{ "workbench.action.openRecent", .open_recent },
        .{ "workbench.action.files.openFolder", .open_folder },
        .{ "workbench.action.openSettings", .open_settings },
        .{ "workbench.action.openGlobalKeybindings", .open_keybindings },
        .{ "workbench.action.zoomIn", .zoom_in },
        .{ "workbench.action.zoomOut", .zoom_out },
        .{ "workbench.action.zoomReset", .zoom_reset },
        .{ "editor.action.toggleWordWrap", .toggle_wrap },
        .{ "editor.action.toggleMinimap", .toggle_minimap },
        .{ "editor.action.moveLinesUpAction", .move_line_up },
        .{ "editor.action.moveLinesDownAction", .move_line_down },
        .{ "editor.action.copyLinesUpAction", .copy_line_up },
        .{ "editor.action.copyLinesDownAction", .copy_line_down },
        .{ "editor.action.deleteLines", .delete_line },
        .{ "editor.action.insertLineAfter", .insert_line_below },
        .{ "editor.action.insertLineBefore", .insert_line_above },
        .{ "editor.action.sortLinesAscending", .sort_lines_asc },
        .{ "editor.action.sortLinesDescending", .sort_lines_desc },
        .{ "editor.action.transformToUppercase", .upper_case },
        .{ "editor.action.transformToLowercase", .lower_case },
        .{ "editor.action.transformToCamelcase", .camel_case },
        .{ "editor.action.transformToSnakecase", .snake_case },
        .{ "editor.action.trimTrailingWhitespace", .trim_whitespace },
        .{ "editor.action.indentUsingTabs", .indent_tabs },
        .{ "editor.action.indentUsingSpaces", .indent_spaces_4 },
        .{ "actions.find", .find },
        .{ "editor.action.startFindReplaceAction", .replace },
        .{ "markdown.showPreview", .toggle_preview },
        .{ "workbench.action.editor.nextChange", .next_change },
        .{ "workbench.action.editor.previousChange", .prev_change },
        .{ "git.commit", .git_commit },
        .{ "git.push", .git_push },
        .{ "git.pull", .git_pull },
        .{ "git.fetch", .git_fetch },
        .{ "git.sync", .git_sync },
        .{ "git.checkout", .git_switch_branch },
        .{ "git.branch", .git_create_branch },
        .{ "git.stash", .git_stash },
        .{ "git.stashPop", .git_stash_pop },
        .{ "git.openChange", .open_changes },
        .{ "git.refresh", .git_refresh },
        .{ "merge-conflict.accept.current", .accept_current },
        .{ "merge-conflict.accept.incoming", .accept_incoming },
        .{ "merge-conflict.accept.both", .accept_both },
        .{ "merge-conflict.accept.all-current", .accept_all_current },
        .{ "merge-conflict.accept.all-incoming", .accept_all_incoming },
        .{ "merge-conflict.next", .next_conflict },
        .{ "merge-conflict.previous", .prev_conflict },
        .{ "copyFilePath", .copy_path },
        .{ "copyRelativeFilePath", .copy_relative_path },
        .{ "revealFileInOS", .reveal_in_os },
        .{ "workbench.files.action.collapseExplorerFolders", .collapse_folders },
        .{ "workbench.files.action.refreshFilesExplorer", .refresh_explorer },
        .{ "workbench.action.nextPanelView", .next_terminal },
        .{ "workbench.action.terminal.focusNext", .next_terminal },
        .{ "workbench.action.terminal.focusPrevious", .prev_terminal },
        .{ "workbench.action.closeFolder", .close_project },
        .{ "workbench.action.quit", .quit },
    };
    for (vs) |e| if (std.mem.eql(u8, e[0], n)) return e[1];
    return null;
}

test parseKey {
    const k = parseKey("ctrl+shift+p").?;
    try std.testing.expect(k.shift);
    try std.testing.expectEqual(@as(u21, 'p'), k.key);
    try std.testing.expect(parseKey("ctrl+nothing") == null);
}

test holds {
    try std.testing.expect(holds("editorTextFocus && !inputFocus", .{ .editor_focus = true }));
    try std.testing.expect(!holds("terminalFocus || (sideBarVisible && editorFocus)", .{ .sidebar_visible = true }));
}

test stripJsonc {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const o = try stripJsonc(arena.allocator(), "[ // c\n {\"key\": \"a//b\", /* x */ \"c\": 1,},\n]");
    try std.testing.expectEqualStrings("[ \n {\"key\": \"a//b\",  \"c\": 1}\n]", o);
}
