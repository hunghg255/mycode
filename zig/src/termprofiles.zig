//! Terminal profiles, as VS Code's: the shells this machine has
//! (PowerShell 7, Windows PowerShell, Command Prompt, Git Bash and WSL on
//! Windows; /etc/shells elsewhere), and those of the settings.
const std = @import("std");
const builtin = @import("builtin");
const fs = @import("fs.zig");
const settings = @import("settings.zig");

pub const Profile = struct {
    name: []const u8,
    path: []const u8,
    args: []const []const u8 = &.{},
};

/// Finds the profiles; their strings are in `a`.
pub fn find(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, own: []const settings.Profile) []Profile {
    var out: std.ArrayList(Profile) = .empty;
    if (builtin.os.tag == .windows) {
        const pf = env.get("ProgramFiles") orelse "C:\\Program Files";
        const root = env.get("SystemRoot") orelse "C:\\Windows";
        const cands = [_]struct { []const u8, []const u8, []const []const u8 }{
            .{ "PowerShell", std.fmt.allocPrint(a, "{s}\\PowerShell\\7\\pwsh.exe", .{pf}) catch "", &.{"-NoLogo"} },
            .{ "Windows PowerShell", std.fmt.allocPrint(a, "{s}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", .{root}) catch "", &.{"-NoLogo"} },
            .{ "Command Prompt", std.fmt.allocPrint(a, "{s}\\System32\\cmd.exe", .{root}) catch "", &.{} },
            .{ "Git Bash", std.fmt.allocPrint(a, "{s}\\Git\\bin\\bash.exe", .{pf}) catch "", &.{ "--login", "-i" } },
            .{ "WSL", std.fmt.allocPrint(a, "{s}\\System32\\wsl.exe", .{root}) catch "", &.{} },
        };
        for (cands) |cd| if (cd[1].len > 0 and fs.exists(io, cd[1])) out.append(a, .{ .name = cd[0], .path = cd[1], .args = cd[2] }) catch {};
    } else {
        const data = fs.read(a, io, "/etc/shells") catch "";
        var it = std.mem.tokenizeScalar(u8, data, '\n');
        while (it.next()) |l| {
            const p = std.mem.trim(u8, l, " \t\r");
            if (p.len == 0 or p[0] == '#' or !fs.exists(io, p)) continue;
            const name = std.fs.path.basename(p);
            var dup = false;
            for (out.items) |o| if (std.mem.eql(u8, o.name, name)) {
                dup = true;
            };
            if (!dup) out.append(a, .{ .name = name, .path = p, .args = &.{"-l"} }) catch {};
        }
    }
    // The settings' own, over a found one of the same name.
    for (own) |p| {
        const path = expand(a, env, p.path);
        const found = if (std.fs.path.isAbsolute(path)) fs.exists(io, path) else which(a, io, env, path) != null;
        if (!found) continue;
        const prof: Profile = .{ .name = p.name, .path = path, .args = p.args };
        var replaced = false;
        for (out.items) |*o| if (std.mem.eql(u8, o.name, p.name)) {
            o.* = prof;
            replaced = true;
        };
        if (!replaced) out.append(a, prof) catch {};
    }
    return out.items;
}

/// `$NAME` and `${NAME}` replaced by the environment's values.
fn expand(a: std.mem.Allocator, env: *const std.process.Environ.Map, s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '$') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '$') {
            var j = i + 1;
            const braced = j < s.len and s[j] == '{';
            if (braced) j += 1;
            const start = j;
            while (j < s.len and (std.ascii.isAlphanumeric(s[j]) or s[j] == '_')) j += 1;
            const name = s[start..j];
            if (braced and j < s.len and s[j] == '}') j += 1;
            out.appendSlice(a, env.get(name) orelse "") catch {};
            i = j;
        } else {
            out.append(a, s[i]) catch {};
            i += 1;
        }
    }
    return out.items;
}

fn which(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    const path = env.get("PATH") orelse env.get("Path") orelse return null;
    const sep: u8 = if (builtin.os.tag == .windows) ';' else ':';
    const exts: []const []const u8 = if (builtin.os.tag == .windows) &.{ ".exe", ".cmd", ".bat", "" } else &.{""};
    var it = std.mem.tokenizeScalar(u8, path, sep);
    while (it.next()) |dir| for (exts) |ext| {
        const p = std.fmt.allocPrint(a, "{s}{c}{s}{s}", .{ dir, std.fs.path.sep, name, ext }) catch return null;
        if (fs.exists(io, p)) return p;
    };
    return null;
}
