//! MyCode, drawn by myzig: `mycode [folder-or-file]`.
const std = @import("std");
const myzig = @import("myzig");
const fs = @import("fs.zig");
const git = @import("git.zig");
const commands = @import("commands.zig");
const Workbench = @import("workbench.zig").Workbench;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const app = try myzig.App.create(init, .{ .name = "MyCode" });
    defer app.destroy();
    try git.init(init.arena.allocator(), init.environ_map);

    // The folder: the first argument that isn't a flag, else the working directory.
    var target: []const u8 = ".";
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args[1..]) |a| if (!std.mem.startsWith(u8, a, "--")) {
        target = a;
        break;
    };
    const abs = fs.absolute(gpa, io, target) catch try fs.absolute(gpa, io, ".");
    defer gpa.free(abs);
    const is_dir = fs.isDirectory(io, abs);
    const root = if (is_dir) abs else std.fs.path.dirname(abs) orelse abs;

    const wb = try Workbench.create(gpa, io, app, root);
    defer wb.destroy();
    if (!is_dir) wb.openFile(abs, false);

    const bar = commands.menuBar(Workbench, wb);
    try app.setMenu(&bar);
    const win = try app.newWindow(.{
        .title = "MyCode",
        .width = 1280,
        .height = 820,
        .min_width = 640,
        .min_height = 400,
        .state = myzig.windowState("main"),
        .on_event = .of(wb, Workbench.onWindowEvent),
        .on_drop = .of(wb, Workbench.onDrop),
        .content = .{ .view = .init(wb, Workbench.view) },
    });
    wb.attach(win);
    try app.run();
}

test {
    _ = fs;
    _ = git;
    _ = @import("quickopen.zig");
}
