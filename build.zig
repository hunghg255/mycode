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
        // Windows keeps its debug information: it is in a .pdb beside the
        // build, the .exe only names it, and a crash then logs its stack
        // (crash-zig.log) where that file is.
        .strip = if (target.result.os.tag == .windows) false else strip,
        .imports = &.{
            .{ .name = "myzig", .module = myzig },
            .{ .name = "terminal", .module = terminal },
            .{ .name = "watch", .module = watch },
            .{ .name = "mainthread", .module = mainthread },
        },
    });
    // The Material Icon Theme's icons (icons/update.py makes material.zig).
    root.addImport("material", b.createModule(.{ .root_source_file = b.path("icons/material.zig") }));
    // The version, from build.zig.zon, for updates.
    const options = b.addOptions();
    options.addOption([]const u8, "version", @import("build.zig.zon").version);
    root.addOptions("build_options", options);
    // The logo of the welcome page.
    root.addAnonymousImport("icon_png", .{ .root_source_file = b.path("resources/icon.png") });
    if (win32_res) |res| if (target.result.os.tag == .windows) root.addObjectFile(.{ .cwd_relative = res });

    const exe = b.addExecutable(.{ .name = "mycode", .root_module = root });
    if (b.option(bool, "windows-gui", "A Windows app without a console") orelse false) exe.subsystem = .windows;
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run the app").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = root });
    b.step("test", "Run the app's tests").dependOn(&b.addRunArtifact(tests).step);

    // The UI tests: the app run headless with scripts (uitest/main.zig);
    // `zig build uitest -- NAME` runs the cases whose names hold NAME.
    const uitest = b.addExecutable(.{ .name = "uitest", .root_module = b.createModule(.{
        .root_source_file = b.path("uitest/main.zig"),
        .target = b.graph.host,
    }) });
    const run_ui = b.addRunArtifact(uitest);
    run_ui.addArtifactArg(exe);
    run_ui.addPassthruArgs();
    run_ui.has_side_effects = true;
    b.step("uitest", "Run the app headless through its UI tests").dependOn(&run_ui.step);
}
