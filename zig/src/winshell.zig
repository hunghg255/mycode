//! The `mycode` command and File Explorer's "Open with MyCode", set up for
//! the user alone as VS Code's installer does: `mycode.cmd` and `mycode`
//! (for Git Bash) in %LOCALAPPDATA%\MyCode\bin, on the user's PATH, and the
//! menus of folders, their insides, drives and files. Uninstalling takes
//! them away and they stay away.
const std = @import("std");
const builtin = @import("builtin");
const fs = @import("fs.zig");

pub const supported = builtin.os.tag == .windows;

const keys = [_][2][]const u8{
    .{ "HKCU\\Software\\Classes\\Directory\\shell\\MyCode", "%V" },
    .{ "HKCU\\Software\\Classes\\Directory\\Background\\shell\\MyCode", "%V" },
    .{ "HKCU\\Software\\Classes\\Drive\\shell\\MyCode", "%V" },
    .{ "HKCU\\Software\\Classes\\*\\shell\\MyCode", "%1" },
};

fn run(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) bool {
    const r = std.process.run(gpa, io, .{ .argv = argv }) catch return false;
    gpa.free(r.stdout);
    gpa.free(r.stderr);
    return r.term.success();
}

fn binDir(gpa: std.mem.Allocator, env: *const std.process.Environ.Map) ?[]u8 {
    const local = env.get("LOCALAPPDATA") orelse return null;
    return std.fs.path.join(gpa, &.{ local, "MyCode", "bin" }) catch null;
}

fn marker(gpa: std.mem.Allocator, data_dir: []const u8) []u8 {
    return std.fs.path.join(gpa, &.{ data_dir, "no-shell-integration" }) catch &.{};
}

/// Whether the user took the command away (it then stays away).
pub fn optedOut(gpa: std.mem.Allocator, io: std.Io, data_dir: []const u8) bool {
    const m = marker(gpa, data_dir);
    defer gpa.free(m);
    return fs.exists(io, m);
}

/// Sets up the command and the menus, unless they're there or were taken away.
/// Runs at start, off the main thread (it starts PowerShell and reg.exe).
pub fn ensure(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, data_dir: []const u8, exe: []const u8, force: bool) bool {
    if (!supported) return false;
    if (!force and optedOut(gpa, io, data_dir)) return false;
    if (force) {
        const m = marker(gpa, data_dir);
        defer gpa.free(m);
        std.Io.Dir.cwd().deleteFile(io, m) catch {};
    }
    const bin = binDir(gpa, env) orelse return false;
    defer gpa.free(bin);
    std.Io.Dir.cwd().createDirPath(io, bin) catch return false;
    // The scripts start MyCode and return at once.
    const cmd_path = std.fs.path.join(gpa, &.{ bin, "mycode.cmd" }) catch return false;
    defer gpa.free(cmd_path);
    const cmd = std.fmt.allocPrint(gpa, "@echo off\r\nstart \"\" \"{s}\" %*\r\n", .{exe}) catch return false;
    defer gpa.free(cmd);
    const sh_path = std.fs.path.join(gpa, &.{ bin, "mycode" }) catch return false;
    defer gpa.free(sh_path);
    const posix_exe = gpa.dupe(u8, exe) catch return false;
    defer gpa.free(posix_exe);
    std.mem.replaceScalar(u8, posix_exe, '\\', '/');
    const sh = std.fmt.allocPrint(gpa, "#!/bin/sh\n\"{s}\" \"$@\" >/dev/null 2>&1 &\n", .{posix_exe}) catch return false;
    defer gpa.free(sh);
    const old = fs.read(gpa, io, cmd_path) catch null;
    defer if (old) |o| gpa.free(o);
    const fresh = old == null or !std.mem.eql(u8, old.?, cmd);
    if (fresh or force) {
        fs.write(io, cmd_path, cmd) catch return false;
        fs.write(io, sh_path, sh) catch {};
        // The user's PATH, through .NET, which tells running programs.
        const ps = std.fmt.allocPrint(gpa,
            \\$b='{s}'; $p=[Environment]::GetEnvironmentVariable('Path','User'); if (-not $p) {{ $p='' }}; if (($p -split ';') -notcontains $b) {{ [Environment]::SetEnvironmentVariable('Path', ($p.TrimEnd(';') + ';' + $b).TrimStart(';'), 'User') }}
        , .{bin}) catch return false;
        defer gpa.free(ps);
        _ = run(gpa, io, &.{ "powershell.exe", "-NoProfile", "-NonInteractive", "-Command", ps });
        for (keys) |k| {
            const icon = std.fmt.allocPrint(gpa, "\"{s}\"", .{exe}) catch continue;
            defer gpa.free(icon);
            const command_key = std.fmt.allocPrint(gpa, "{s}\\command", .{k[0]}) catch continue;
            defer gpa.free(command_key);
            const command = std.fmt.allocPrint(gpa, "\"{s}\" \"{s}\"", .{ exe, k[1] }) catch continue;
            defer gpa.free(command);
            _ = run(gpa, io, &.{ "reg.exe", "add", k[0], "/ve", "/d", "Open with MyCode", "/f" });
            _ = run(gpa, io, &.{ "reg.exe", "add", k[0], "/v", "Icon", "/d", icon, "/f" });
            _ = run(gpa, io, &.{ "reg.exe", "add", command_key, "/ve", "/d", command, "/f" });
        }
    }
    return true;
}

/// Takes the command and the menus away, for good.
pub fn uninstall(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, data_dir: []const u8) void {
    if (!supported) return;
    const m = marker(gpa, data_dir);
    defer gpa.free(m);
    fs.write(io, m, "") catch {};
    remove(gpa, io, env);
}

/// Takes the command and the menus away, as the uninstaller asks
/// (`--uninstall-shell`): those the Go app set up too, which have the same
/// names. Installed again, MyCode sets them up again.
pub fn remove(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) void {
    if (!supported) return;
    const bin = binDir(gpa, env) orelse return;
    defer gpa.free(bin);
    std.Io.Dir.cwd().deleteTree(io, bin) catch {};
    const ps = std.fmt.allocPrint(gpa,
        \\$b='{s}'; $p=[Environment]::GetEnvironmentVariable('Path','User'); if ($p) {{ [Environment]::SetEnvironmentVariable('Path', (($p -split ';') | Where-Object {{ $_ -and $_ -ne $b }}) -join ';', 'User') }}
    , .{bin}) catch return;
    defer gpa.free(ps);
    _ = run(gpa, io, &.{ "powershell.exe", "-NoProfile", "-NonInteractive", "-Command", ps });
    for (keys) |k| _ = run(gpa, io, &.{ "reg.exe", "delete", k[0], "/f" });
}
