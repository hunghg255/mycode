//! settings.json, the user's preferences, in the Go app's format and folder
//! (%AppData%\MyCode, or MAYOI_DATA_DIR), read again when it changes.
//! Writes keep the keys this port doesn't know.
const std = @import("std");
const myzig = @import("myzig");
const fs = @import("fs.zig");

pub const Profile = struct {
    name: []const u8,
    path: []const u8,
    args: []const []const u8 = &.{},
};

pub const Settings = struct {
    fontFamily: []const u8 = "monospace",
    fontSize: f32 = 13,
    fontWeight: f32 = 400,
    lineHeight: f32 = 1.55,
    /// OpenType features, by commas ("calt=0,ss01"); a list in the file.
    fontFeatures: []const u8 = "",
    terminalFontFamily: []const u8 = "",
    terminalFontSize: f32 = 0,
    terminalCopyOnSelect: bool = true,
    terminalProfile: []const u8 = "",
    terminalProfiles: []const Profile = &.{},
    theme: []const u8 = "",
    appearance: []const u8 = "",
    /// "" (the Material Icon Theme) or "lucide".
    iconTheme: []const u8 = "",
    filesExclude: []const []const u8 = &.{},
    sidebarRight: bool = false,
    projectTabs: bool = true,
    projectIcons: bool = false,
    autoSave: bool = true,
    /// `true` or VS Code's "on" wrap at the edge; "wordWrapColumn" and
    /// "bounded" at `wordWrapColumn`, or the edge where that is nearer.
    wordWrap: bool = false,
    wordWrapColumn: f32 = 80,
    /// Made of `wordWrap`: lines wrap at `wordWrapColumn`.
    wrapAtColumn: bool = false,
    blame: bool = true,
    minimap: bool = true,
    minimapWidth: f32 = 90,
    diffLayout: []const u8 = "",
    scmTree: bool = false,
    scmAllBranches: bool = false,
};

pub const Store = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: []u8,
    settings_path: []u8,
    keys_path: []u8,
    state_path: []u8,
    s: Settings = .{},
    arena: std.heap.ArenaAllocator,
    /// The settings read before, kept until the next read: one read in the
    /// middle of a frame (settings.json saved in the editor) leaves the
    /// strings the frame drew.
    old_arena: std.heap.ArenaAllocator,
    mtime: i96 = -1,
    /// Bumped whenever the settings change, so views apply them once.
    version: u64 = 1,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !Store {
        const dir = if (env.get("MAYOI_DATA_DIR")) |d| try gpa.dupe(u8, d) else try myzig.appPath(gpa, .config, "MyCode");
        std.Io.Dir.cwd().createDirPath(io, dir) catch {};
        var st: Store = .{
            .gpa = gpa,
            .io = io,
            .dir = dir,
            .settings_path = try std.fs.path.join(gpa, &.{ dir, "settings.json" }),
            .keys_path = try std.fs.path.join(gpa, &.{ dir, "keybindings.json" }),
            // The Go app's state.json has another shape: the port keeps its own.
            .state_path = try std.fs.path.join(gpa, &.{ dir, "state-zig.json" }),
            .arena = .init(gpa),
            .old_arena = .init(gpa),
        };
        migrate(gpa, io, dir, st.settings_path);
        _ = st.reload();
        if (!fs.exists(io, st.keys_path)) fs.write(io, st.keys_path, "// Keyboard shortcuts, in VS Code's format.\n[\n]\n") catch {};
        return st;
    }

    /// A first start under the name MyCode keeps what Mayoi had, as the Go
    /// app's `migrateData`: its settings and keyboard shortcuts are copied
    /// from the folder beside this one, while this one has no settings.
    fn migrate(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, settings_path: []const u8) void {
        if (fs.exists(io, settings_path)) return;
        const parent = std.fs.path.dirname(dir) orelse return;
        const old = std.fs.path.join(gpa, &.{ parent, "Mayoi" }) catch return;
        defer gpa.free(old);
        if (std.ascii.eqlIgnoreCase(old, dir) or !fs.isDirectory(io, old)) return;
        for ([_][]const u8{ "settings.json", "keybindings.json" }) |name| {
            const from = std.fs.path.join(gpa, &.{ old, name }) catch continue;
            defer gpa.free(from);
            const data = fs.read(gpa, io, from) catch continue;
            defer gpa.free(data);
            const to = std.fs.path.join(gpa, &.{ dir, name }) catch continue;
            defer gpa.free(to);
            fs.write(io, to, data) catch {};
        }
    }

    pub fn deinit(st: *Store) void {
        st.arena.deinit();
        st.old_arena.deinit();
        st.gpa.free(st.dir);
        st.gpa.free(st.settings_path);
        st.gpa.free(st.keys_path);
        st.gpa.free(st.state_path);
    }

    /// Reads settings.json again if it changed; true when it did.
    pub fn reload(st: *Store) bool {
        const m = fs.mtime(st.io, st.settings_path);
        if (m == st.mtime) return false;
        st.mtime = m;
        const data = fs.read(st.gpa, st.io, st.settings_path) catch return false;
        defer st.gpa.free(data);
        st.old_arena.deinit();
        st.old_arena = st.arena;
        st.arena = .init(st.gpa);
        const a = st.arena.allocator();
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, data, .{}) catch return false;
        st.s = parse(a, v);
        st.version += 1;
        return true;
    }

    /// Sets one key and writes the file, keeping its other keys.
    pub fn set(st: *Store, key: []const u8, value: std.json.Value) void {
        var arena: std.heap.ArenaAllocator = .init(st.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var obj: std.json.ObjectMap = .empty;
        if (fs.read(a, st.io, st.settings_path)) |data| {
            if (std.json.parseFromSliceLeaky(std.json.Value, a, data, .{})) |v| {
                if (v == .object) obj = v.object;
            } else |_| return; // a file that doesn't parse is the user's to fix
        } else |_| {}
        obj.put(a, key, value) catch return;
        const out = std.fmt.allocPrint(a, "{f}\n", .{std.json.fmt(std.json.Value{ .object = obj }, .{ .whitespace = .indent_2 })}) catch return;
        fs.write(st.io, st.settings_path, out) catch return;
        st.mtime = -1;
        _ = st.reload();
    }

    pub fn setBool(st: *Store, key: []const u8, v: bool) void {
        st.set(key, .{ .bool = v });
    }

    pub fn setString(st: *Store, key: []const u8, v: []const u8) void {
        st.set(key, .{ .string = v });
    }

    pub fn setNumber(st: *Store, key: []const u8, v: f32) void {
        st.set(key, .{ .float = v });
    }
};

fn num(v: std.json.Value) ?f32 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| @floatCast(f),
        else => null,
    };
}

/// The settings of a parsed file, values out of range corrected, as the Go app does.
pub fn parse(a: std.mem.Allocator, v: std.json.Value) Settings {
    var s: Settings = .{};
    if (v != .object) return s;
    const o = v.object;
    const info = @typeInfo(Settings).@"struct";
    inline for (info.field_names, info.field_types) |fname, ftype| if (o.get(fname)) |x| {
        switch (ftype) {
            bool => if (x == .bool) {
                @field(s, fname) = x.bool;
            },
            f32 => if (num(x)) |n| {
                @field(s, fname) = n;
            },
            []const u8 => if (x == .string) {
                @field(s, fname) = x.string;
            },
            else => {},
        }
    };
    s.fontSize = std.math.clamp(s.fontSize, 9, 28);
    s.lineHeight = std.math.clamp(s.lineHeight, 1, 3);
    if (s.terminalFontSize != 0) s.terminalFontSize = std.math.clamp(s.terminalFontSize, 9, 28);
    s.minimapWidth = std.math.clamp(s.minimapWidth, 40, 400);
    // Word wrap as VS Code writes it too: a string, and its `editor.` keys.
    for ([_][]const u8{ "wordWrap", "editor.wordWrap" }) |k| if (o.get(k)) |x| switch (x) {
        .bool => |b| {
            s.wordWrap = b;
            s.wrapAtColumn = false;
        },
        .string => |str| {
            s.wordWrap = !std.mem.eql(u8, str, "off");
            s.wrapAtColumn = std.mem.eql(u8, str, "wordWrapColumn") or std.mem.eql(u8, str, "bounded");
        },
        else => {},
    };
    if (o.get("editor.wordWrapColumn")) |x| if (num(x)) |n| {
        s.wordWrapColumn = n;
    };
    s.wordWrapColumn = std.math.clamp(s.wordWrapColumn, 10, 1000);
    s.wrapAtColumn = s.wrapAtColumn and s.wordWrap;
    if (std.mem.trim(u8, s.fontFamily, " ").len == 0) s.fontFamily = "monospace";
    // Themes used to be appearances.
    if (std.mem.eql(u8, s.appearance, "matrix") or std.mem.eql(u8, s.appearance, "claude")) {
        s.theme = s.appearance;
        s.appearance = "";
    }
    s.fontWeight = std.math.clamp(s.fontWeight, 100, 900);
    if (o.get("fontFeatures")) |ff| if (ff == .array) {
        var list: std.ArrayList(u8) = .empty;
        for (ff.array.items) |x| if (x == .string and x.string.len > 0) {
            if (list.items.len > 0) list.append(a, ',') catch {};
            list.appendSlice(a, x.string) catch {};
        };
        s.fontFeatures = list.items;
    };
    if (o.get("filesExclude")) |fe| if (fe == .object) {
        var list: std.ArrayList([]const u8) = .empty;
        var it = fe.object.iterator();
        while (it.next()) |e| if (e.value_ptr.* == .bool and e.value_ptr.bool) list.append(a, e.key_ptr.*) catch {};
        s.filesExclude = list.items;
    };
    if (o.get("terminalProfiles")) |tp| if (tp == .array) {
        var list: std.ArrayList(Profile) = .empty;
        for (tp.array.items) |p| {
            if (p != .object) continue;
            const name = p.object.get("name") orelse continue;
            const path = p.object.get("path") orelse continue;
            if (name != .string or path != .string) continue;
            var args: std.ArrayList([]const u8) = .empty;
            if (p.object.get("args")) |ar| if (ar == .array) for (ar.array.items) |x| if (x == .string) args.append(a, x.string) catch {};
            list.append(a, .{ .name = name.string, .path = path.string, .args = args.items }) catch {};
        }
        s.terminalProfiles = list.items;
    };
    return s;
}

test parse {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"fontSize": 40, "autoSave": false, "appearance": "matrix", "filesExclude": {"**/dist": true, "x": false},
        \\ "terminalProfiles": [{"name": "Bash", "path": "bash", "args": ["-l"]}]}
    , .{});
    const s = parse(a, v);
    try std.testing.expectEqual(@as(f32, 28), s.fontSize);
    try std.testing.expect(!s.autoSave);
    try std.testing.expectEqualStrings("matrix", s.theme);
    try std.testing.expectEqual(@as(usize, 1), s.filesExclude.len);
    try std.testing.expectEqualStrings("-l", s.terminalProfiles[0].args[0]);
    try std.testing.expect(!s.wordWrap);
    // Word wrap in VS Code's words.
    const w = parse(a, try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"editor.wordWrap": "bounded", "editor.wordWrapColumn": 100}
    , .{}));
    try std.testing.expect(w.wordWrap and w.wrapAtColumn);
    try std.testing.expectEqual(@as(f32, 100), w.wordWrapColumn);
    const on = parse(a, try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"wordWrap": "on"}
    , .{}));
    try std.testing.expect(on.wordWrap and !on.wrapAtColumn);
    const off = parse(a, try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"wordWrap": "off", "wordWrapColumn": 60}
    , .{}));
    try std.testing.expect(!off.wordWrap and !off.wrapAtColumn);
    try std.testing.expectEqual(@as(f32, 60), off.wordWrapColumn);
}
