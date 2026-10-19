const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug information");
    const win32_res = b.option([]const u8, "win32-res", "A compiled resource file (.res) to link on Windows");
    const myzig = b.dependency("myzig", .{ .target = target, .optimize = optimize }).module("myzig");
    const terminal = b.dependency("myzig_terminal", .{ .target = target, .optimize = optimize }).module("terminal");
    const watch = b.dependency("myzig_watch", .{ .target = target, .optimize = optimize }).module("watch");
    const mainthread = b.dependency("mainthread", .{ .target = target, .optimize = optimize }).module("mainthread");
    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "myzig", .module = myzig },
            .{ .name = "terminal", .module = terminal },
            .{ .name = "watch", .module = watch },
            .{ .name = "mainthread", .module = mainthread },
        },
    });
    if (win32_res) |res| if (target.result.os.tag == .windows) root.addObjectFile(.{ .cwd_relative = res });

    const exe = b.addExecutable(.{ .name = "mycode", .root_module = root });
    if (b.option(bool, "windows-gui", "A Windows app without a console") orelse false) exe.subsystem = .windows;
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run the app").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = root });
    b.step("test", "Run the app's tests").dependOn(&b.addRunArtifact(tests).step);
}
