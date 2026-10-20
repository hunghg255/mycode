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
    /// One key, or a chord of up to four.
    keys: []const Key,
    /// The command of a binding that runs one, or is taken away ("-command").
    cmd: ?Cmd,
    remove: bool = false,
    when: []const u8 = "",
    /// What it does: one step, or runCommands' list.
    steps: []const Step = &.{},
};

pub const Step = struct {
    action: Action = .run,
    cmd: ?Cmd = null,
    /// `type` and `sendSequence`'s text, `vscode.open`'s path.
    text: []const u8 = "",
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

pub const max_chord = 4;

pub const Keymap = struct {
    arena: std.heap.ArenaAllocator,
    bindings: []Binding = &.{},
    /// The keys of a chord typed so far, waiting for the next.
    chord: [max_chord]Key = undefined,
    chord_len: usize = 0,
    /// Keys and commands the file had that weren't understood.
    errors: []const []const u8 = &.{},
    /// Bumped by each load, so the window says once what failed.
    loads: u32 = 0,

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
        k.errors = &.{};
        k.chord_len = 0;
        k.loads +%= 1;
        var errs: std.ArrayList([]const u8) = .empty;
        defer k.errors = errs.items;
        const clean = stripJsonc(a, data) catch return;
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, clean, .{}) catch {
            errs.append(a, "it isn't a JSON list") catch {};
            return;
        };
        if (v != .array) return;
        var list: std.ArrayList(Binding) = .empty;
        for (v.array.items) |e| {
            if (e != .object) continue;
            const key = e.object.get("key") orelse continue;
            const command = e.object.get("command") orelse continue;
            if (key != .string or command != .string) continue;
            var keys: std.ArrayList(Key) = .empty;
            var it = std.mem.tokenizeScalar(u8, key.string, ' ');
            var ok = true;
            while (it.next()) |part| {
                if (keys.items.len == max_chord) break;
                const one = parseKey(part) orelse {
                    ok = false;
                    break;
                };
                keys.append(a, one) catch {};
            }
            if (!ok or keys.items.len == 0) {
                errs.append(a, std.fmt.allocPrint(a, "the key \"{s}\"", .{key.string}) catch "") catch {};
                continue;
            }
            var b: Binding = .{ .keys = keys.items, .cmd = null };
            var cmd_name = command.string;
            if (std.mem.startsWith(u8, cmd_name, "-")) {
                b.remove = true;
                cmd_name = cmd_name[1..];
            }
            const args = e.object.get("args");
            if (std.mem.eql(u8, cmd_name, "runCommands")) {
                var steps: std.ArrayList(Step) = .empty;
                if (args) |ar| if (ar == .object) if (ar.object.get("commands")) |cs| if (cs == .array) for (cs.array.items) |one| {
                    const cmd_of = switch (one) {
                        .string => |n| n,
                        .object => |o| if (o.get("command")) |n| (if (n == .string) n.string else continue) else continue,
                        else => continue,
                    };
                    const step_args = if (one == .object) one.object.get("args") else null;
                    const step = stepOf(cmd_of, step_args) orelse {
                        errs.append(a, std.fmt.allocPrint(a, "the command \"{s}\"", .{cmd_of}) catch "") catch {};
                        continue;
                    };
                    steps.append(a, step) catch {};
                };
                b.steps = steps.items;
            } else if (stepOf(cmd_name, args)) |step| {
                b.cmd = step.cmd;
                b.steps = a.dupe(Step, &.{step}) catch &.{};
            } else {
                errs.append(a, std.fmt.allocPrint(a, "the command \"{s}\"", .{cmd_name}) catch "") catch {};
                continue;
            }
            if (e.object.get("when")) |w| if (w == .string) {
                b.when = w.string;
            };
            list.append(a, b) catch {};
        }
        k.bindings = list.items;
    }

    /// The binding this event's key completes, if any; chords wait for
    /// their next key. Takes the key.
    pub fn match(k: *Keymap, c: *ui.Context, cx: Context) ?*const Binding {
        if (k.bindings.len == 0) return null;
        const sc = c.input.shortcut orelse return null;
        const pressed: Key = .{ .key = sc.key, .cmd = sc.cmd, .ctrl = sc.ctrl, .alt = sc.alt, .shift = sc.shift };
        var typed: [max_chord]Key = undefined;
        @memcpy(typed[0..k.chord_len], k.chord[0..k.chord_len]);
        typed[k.chord_len] = pressed;
        const n = k.chord_len + 1;
        const in_chord = k.chord_len > 0;
        k.chord_len = 0;
        // Later bindings win, as in VS Code.
        var longer = false;
        var i = k.bindings.len;
        while (i > 0) {
            i -= 1;
            const b = &k.bindings[i];
            if (b.keys.len < n or !holds(b.when, cx)) continue;
            if (!startsWith(b.keys, typed[0..n])) continue;
            if (b.keys.len > n) {
                longer = true;
                continue;
            }
            _ = c.shortcut(sc);
            return if (b.remove) null else b;
        }
        if (longer and n < max_chord) {
            @memcpy(k.chord[0..n], typed[0..n]);
            k.chord_len = n;
            _ = c.shortcut(sc);
            return null;
        }
        // A chord's unbound key ends it.
        if (in_chord) _ = c.shortcut(sc);
        return null;
    }

    /// The keys of the chord typed so far, as the status bar shows them.
    pub fn chordText(k: *const Keymap, c: *ui.Context) []const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (k.chord[0..k.chord_len]) |key| {
            if (out.items.len > 0) out.append(c.alloc(), ' ') catch {};
            out.appendSlice(c.alloc(), ui.shortcutLabel(c, key.shortcut())) catch {};
        }
        return out.items;
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
            if (b.cmd == cmd and !b.remove and b.keys.len == 1) return b.keys[0];
        }
        return null;
    }
};

fn startsWith(keys: []const Key, typed: []const Key) bool {
    for (typed, 0..) |t, i| if (!eqlKey(keys[i], t)) return false;
    return true;
}

/// A command of the file with its arguments, or null for one MyCode
/// doesn't have.
fn stepOf(id: []const u8, args: ?std.json.Value) ?Step {
    if (std.mem.eql(u8, id, "type") or std.mem.eql(u8, id, "workbench.action.terminal.sendSequence")) {
        var st: Step = .{ .action = if (std.mem.eql(u8, id, "type")) .type_text else .send_sequence };
        if (args) |ar| if (ar == .object) if (ar.object.get("text")) |t| if (t == .string) {
            st.text = t.string;
        };
        return st;
    }
    if (std.mem.eql(u8, id, "vscode.open")) {
        var st: Step = .{ .action = .open };
        if (args) |ar| if (ar == .string) {
            st.text = ar.string;
        };
        return st;
    }
    return .{ .cmd = commandFor(id) orelse return null };
}

// Two keys are the same, Command being Control off macOS.
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
        .{ "git.stashPop", .git_stash_pop_pick },
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
        .{ "workbench.action.closeFolder", .close_folder },
        .{ "workbench.action.quit", .quit },
    };
    for (vs) |e| if (std.mem.eql(u8, e[0], n)) return e[1];
    // VS Code's names for the Go app's ids, as keymap.go has them.
    const go = [_][2][]const u8{
        .{ "workbench.action.toggleAutoSave", "file.autoSave" },
        .{ "workbench.action.openSettingsJson", "file.settings" },
        .{ "workbench.action.openGlobalKeybindingsFile", "file.keybindings" },
        .{ "workbench.action.closeWindow", "file.closeProject" },
        .{ "workbench.action.files.copyPathOfActiveFile", "file.copyPath" },
        .{ "workbench.action.files.copyRelativePathOfActiveFile", "file.copyRelativePath" },
        .{ "workbench.action.files.revealActiveFileInWindows", "file.reveal" },
        .{ "undo", "edit.undo" },
        .{ "redo", "edit.redo" },
        .{ "editor.action.nextMatchFindAction", "edit.findNext" },
        .{ "editor.action.previousMatchFindAction", "edit.findPrev" },
        .{ "editor.action.commentLine", "sel.comment" },
        .{ "editor.action.indentLines", "sel.indent" },
        .{ "editor.action.outdentLines", "sel.outdent" },
        .{ "expandLineSelection", "sel.line" },
        .{ "editor.action.jumpToBracket", "go.bracket" },
        .{ "workbench.action.togglePanel", "view.terminal" },
        .{ "workbench.action.createTerminalEditor", "view.terminalTab" },
        .{ "workbench.action.splitEditorRight", "view.splitRight" },
        .{ "workbench.action.focusNextGroup", "view.nextColumn" },
        .{ "workbench.action.focusPreviousGroup", "view.prevColumn" },
        .{ "workbench.action.moveEditorToNextGroup", "view.moveTabNext" },
        .{ "workbench.action.moveEditorToPreviousGroup", "view.moveTabPrev" },
        .{ "editor.action.fontZoomIn", "view.zoomIn" },
        .{ "editor.action.fontZoomOut", "view.zoomOut" },
        .{ "editor.action.fontZoomReset", "view.zoomReset" },
        .{ "git.commitStaged", "git.commit" },
        .{ "git.stage", "git.stageFile" },
        .{ "git.unstage", "git.unstageFile" },
        .{ "git.deleteRemoteBranch", "git.deleteBranch" },
        .{ "git.pushForce", "git.forcePush" },
        .{ "git.pushForceWithLease", "git.forcePush" },
        .{ "git.viewStash", "git.stashView" },
        .{ "gitlens.toggleFileBlame", "git.blame" },
        .{ "gitlens.toggleLineBlame", "git.blame" },
    };
    for (go) |e| if (std.mem.eql(u8, e[0], n)) return commands.byId(e[1]);
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

test "chords and runCommands" {
    var k: Keymap = .init(std.testing.allocator);
    defer k.deinit();
    k.load(
        \\[{"key": "ctrl+. g c", "command": "runCommands", "args": {"commands": ["git.stageAll", {"command": "git.commit"}]}},
        \\ {"key": "ctrl+k", "command": "nothing.here"}]
    );
    try std.testing.expectEqual(@as(usize, 1), k.bindings.len);
    try std.testing.expectEqual(@as(usize, 3), k.bindings[0].keys.len);
    try std.testing.expectEqual(@as(usize, 2), k.bindings[0].steps.len);
    try std.testing.expectEqual(Cmd.stage_all, k.bindings[0].steps[0].cmd.?);
    try std.testing.expectEqual(@as(usize, 1), k.errors.len);
}
