//! The app's UI tests (`zig build uitest`): each case makes its folders and
//! settings, then runs mycode headless (`--myzig-snapshot`) with a script of
//! clicks, keys and typing. A step that finds no text fails the run, so
//! `move:TEXT` checks that a text is shown; a crash fails it too. Some cases
//! then check what the app wrote: a saved file, a commit, its state.
//!
//! The folders are made in the system's temporary folder, outside any
//! repository, as `mycode-uitest/caseN`.
//!
//!     uitest <mycode.exe> [name filter]
const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;

const File = struct { path: []const u8, data: []const u8 };

/// One start of the app: the folders it opens (the case's, by name) and
/// its script.
const Run = struct { open: []const []const u8, script: []const u8 };

const Case = struct {
    name: []const u8,
    /// Files of the case's folders, as "folder/path".
    files: []const File = &.{},
    /// Folders made Git repositories, their files committed.
    repos: []const []const u8 = &.{},
    /// Files changed after the commit.
    changes: []const File = &.{},
    /// More to set up, after the files, repositories and changes.
    setup: ?*const fn (t: *T) anyerror!void = null,
    settings: []const u8 = "{}",
    runs: []const Run,
    /// What the app left behind, checked after its runs.
    check: ?*const fn (t: *T) anyerror!void = null,
};

const files_ab: []const File = &.{
    .{ .path = "alpha/a.txt", .data = "first\n" },
    .{ .path = "alpha/b.txt", .data = "second\n" },
    .{ .path = "alpha/src/needle.zig", .data = "const haystack = 1;\n// findme here\n" },
    .{ .path = "beta/only_beta.txt", .data = "beta\n" },
};

const cases = [_]Case{
    .{
        .name = "explorer lists the folder and opens a subfolder",
        .files = files_ab,
        .runs = &.{.{ .open = &.{"alpha"}, .script = "frames:3;move:a.txt;move:b.txt;click:src;move:needle.zig" }},
    },
    .{
        .name = "welcome page shows with no file open",
        .files = files_ab,
        .runs = &.{.{ .open = &.{"alpha"}, .script = "frames:3;move:START;move:Quick Open…" }},
    },
    .{
        .name = "a file opened by quick open is edited and saved",
        .files = files_ab,
        .runs = &.{.{ .open = &.{"alpha"}, .script = "frames:3;shortcut:ctrl+p;type:a.txt;key:enter;frames:3;type:typed-;shortcut:ctrl+s;frames:3" }},
        .check = struct {
            fn f(t: *T) !void {
                try t.expectFile("alpha/a.txt", "typed-first\n");
            }
        }.f,
    },
    .{
        .name = "quick open opens a file by name",
        .files = files_ab,
        .runs = &.{.{ .open = &.{"alpha"}, .script = "frames:3;shortcut:ctrl+p;type:needle;key:enter;frames:3;move:needle.zig" }},
    },
    .{
        .name = "erasing the palette's prefix keeps the app",
        .files = files_ab,
        .runs = &.{.{ .open = &.{"alpha"}, .script = "frames:3;shortcut:ctrl+shift+p;key:backspace;key:backspace;type:a;key:backspace;type:@;key:backspace;frames:3" }},
    },
    .{
        .name = "new files get numbered tabs",
        .files = files_ab,
        .runs = &.{.{ .open = &.{"alpha"}, .script = "frames:3;shortcut:ctrl+n;frames:3;shortcut:ctrl+n;frames:3;move:Untitled-1;move:Untitled-2" }},
    },
    .{
        .name = "closing every project leaves No Folder Open",
        .files = files_ab,
        .runs = &.{.{ .open = &.{ "alpha", "beta" }, .script = "frames:3;" ++ close_project ++ close_project ++ close_project ++ "move:No Folder Open;move:alpha;move:beta" }},
        .check = struct {
            fn f(t: *T) !void {
                try t.expectState("\"projects\": []");
            }
        }.f,
    },
    .{
        .name = "project tabs turned off and on again",
        .files = files_ab,
        .runs = &.{.{ .open = &.{ "alpha", "beta" }, .script = "frames:3;" ++ palette ++ "Project Tabs;key:enter;frames:6;" ++ palette ++ "Project Tabs;key:enter;frames:6" }},
    },
    .{
        .name = "without project tabs a recent folder takes the window",
        .files = files_ab,
        .settings = "{\"projectTabs\": false}",
        .runs = &.{
            .{ .open = &.{"beta"}, .script = "frames:3" },
            .{ .open = &.{"alpha"}, .script = "frames:3;click:beta;frames:6;move:only_beta.txt" },
        },
    },
    .{
        .name = "search finds text in the files",
        .files = files_ab,
        .runs = &.{.{ .open = &.{"alpha"}, .script = "frames:3;shortcut:ctrl+shift+f;type:findme;live:1;move:needle.zig" }},
    },
    .{
        .name = "source control lists changes and commits them",
        .files = files_ab,
        .repos = &.{"alpha"},
        .changes = &.{ .{ .path = "alpha/a.txt", .data = "changed\n" }, .{ .path = "alpha/new.txt", .data = "new\n" } },
        .runs = &.{.{ .open = &.{"alpha"}, .script = "frames:3;shortcut:ctrl+shift+g;live:1;move:new.txt;move:a.txt;drag:180,123>180,123;type:the commit;shortcut:ctrl+enter;move:Commit all changes?;drag:733,452>733,452;live:1" }},
        .check = struct {
            fn f(t: *T) !void {
                try t.expectGit("alpha", &.{ "log", "-1", "--format=%s" }, "the commit");
                try t.expectGit("alpha", &.{ "status", "--porcelain" }, "");
            }
        }.f,
    },
    .{
        // Every row shares the Explorer's menu: the one right-clicked is renamed.
        .name = "the Explorer's context menu acts on the row right-clicked",
        .files = files_ab,
        .runs = &.{.{ .open = &.{"alpha"}, .script = "frames:3;rclick:a.txt;click:Rename…;type:renamed;key:enter;frames:3;move:renamed.txt" }},
        .check = struct {
            fn f(t: *T) !void {
                try t.expectFile("alpha/renamed.txt", "first\n");
                try t.expectFile("alpha/b.txt", "second\n");
            }
        }.f,
    },
    .{
        .name = "a commit's context menu shows once and acts on that commit",
        .files = files_ab,
        .repos = &.{"alpha"},
        .setup = struct {
            fn f(t: *T) !void {
                try t.write(.{ .path = "alpha/b.txt", .data = "changed\n" });
                t.gpa.free(try t.git("alpha", &.{ "commit", "-q", "-am", "second" }));
            }
        }.f,
        .runs = &.{.{ .open = &.{"alpha"}, .script = "frames:3;shortcut:ctrl+shift+g;live:1;rclick:first;click:Create Branch Here…;type:at-first;key:enter;live:2" }},
        .check = struct {
            fn f(t: *T) !void {
                try t.expectGit("alpha", &.{ "rev-parse", "--abbrev-ref", "HEAD" }, "at-first");
                try t.expectGit("alpha", &.{ "log", "-1", "--format=%s" }, "first");
            }
        }.f,
    },
    .{
        // Files are read in the background: the diff shows once they are.
        .name = "the Changes tab shows each changed file's diff",
        .files = files_ab,
        .repos = &.{"alpha"},
        .changes = &.{ .{ .path = "alpha/a.txt", .data = "first line changed\n" }, .{ .path = "alpha/b.txt", .data = "second line changed\n" } },
        .runs = &.{.{ .open = &.{"alpha"}, .script = "frames:3;live:1;" ++ palette ++ "Open All Changes;key:enter;live:2;move:first line changed;move:second line changed" }},
    },
    .{
        // The tab menu's Split Right, Move to Next Column and Move to Panel
        // empty the terminal's column: once, they freed it as the tab strip
        // still drew it. (The terminal's tab is the only one, at 402,56.)
        .name = "a terminal tab splits right and moves from its tab menu",
        .files = files_ab,
        .runs = &.{
            .{ .open = &.{"alpha"}, .script = "frames:3;" ++ palette ++ "New Terminal in Editor Area;key:enter;live:2;rclick:402,56;click:Split Right;live:1" },
            .{ .open = &.{"alpha"}, .script = "frames:3;" ++ palette ++ "New Terminal in Editor Area;key:enter;live:2;rclick:402,56;click:Move to Next Column;live:1" },
            .{ .open = &.{"alpha"}, .script = "frames:3;" ++ palette ++ "New Terminal in Editor Area;key:enter;live:2;rclick:402,56;click:Move to Panel;live:1;move:TERMINAL" },
        },
    },
    .{
        // Scrolled into a block, its line sticks above the editor: that once
        // changed the editor's id, which lost its scroll, which took the
        // line away, every other frame.
        .name = "scrolled into a block, its sticky line stays",
        .files = &.{.{ .path = "alpha/big.ts", .data = "export interface Big {\n    field_1: number;\n    field_2: number;\n    field_3: number;\n    field_4: number;\n    field_5: number;\n    field_6: number;\n    field_7: number;\n    field_8: number;\n    field_9: number;\n    field_10: number;\n    field_11: number;\n    field_12: number;\n    field_13: number;\n    field_14: number;\n    field_15: number;\n    field_16: number;\n    field_17: number;\n    field_18: number;\n    field_19: number;\n    field_20: number;\n    field_21: number;\n    field_22: number;\n    field_23: number;\n    field_24: number;\n    field_25: number;\n    field_26: number;\n    field_27: number;\n    field_28: number;\n    field_29: number;\n    field_30: number;\n    field_31: number;\n    field_32: number;\n    field_33: number;\n    field_34: number;\n    field_35: number;\n    field_36: number;\n    field_37: number;\n    field_38: number;\n    field_39: number;\n    field_40: number;\n    field_41: number;\n    field_42: number;\n    field_43: number;\n    field_44: number;\n    field_45: number;\n    field_46: number;\n    field_47: number;\n    field_48: number;\n    field_49: number;\n    field_50: number;\n    field_51: number;\n    field_52: number;\n    field_53: number;\n    field_54: number;\n    field_55: number;\n    field_56: number;\n    field_57: number;\n    field_58: number;\n    field_59: number;\n    field_60: number;\n    field_61: number;\n    field_62: number;\n    field_63: number;\n    field_64: number;\n    field_65: number;\n    field_66: number;\n    field_67: number;\n    field_68: number;\n    field_69: number;\n    field_70: number;\n    field_71: number;\n    field_72: number;\n    field_73: number;\n    field_74: number;\n    field_75: number;\n    field_76: number;\n    field_77: number;\n    field_78: number;\n    field_79: number;\n    field_80: number;\n    field_81: number;\n    field_82: number;\n    field_83: number;\n    field_84: number;\n    field_85: number;\n    field_86: number;\n    field_87: number;\n    field_88: number;\n    field_89: number;\n    field_90: number;\n    field_91: number;\n    field_92: number;\n    field_93: number;\n    field_94: number;\n    field_95: number;\n    field_96: number;\n    field_97: number;\n    field_98: number;\n    field_99: number;\n    field_100: number;\n    field_101: number;\n    field_102: number;\n    field_103: number;\n    field_104: number;\n    field_105: number;\n    field_106: number;\n    field_107: number;\n    field_108: number;\n    field_109: number;\n    field_110: number;\n    field_111: number;\n    field_112: number;\n    field_113: number;\n    field_114: number;\n    field_115: number;\n    field_116: number;\n    field_117: number;\n    field_118: number;\n    field_119: number;\n    field_120: number;\n}\n" }},
        .runs = &.{.{ .open = &.{"alpha"}, .script = "frames:3;shortcut:ctrl+p;type:big.ts;key:enter;frames:3;drag:900,400>900,400;wheel:-1500;frames:1;move:export interface Big {;frames:1;move:export interface Big {;frames:1;move:export interface Big {" }},
    },
    .{
        .name = "a merge conflict is resolved with Accept Incoming and Accept Current",
        .files = &.{
            .{ .path = "alpha/a.txt", .data = "top\nbase one\nm1\nm2\nm3\nm4\nbase two\nend\n" },
        },
        .repos = &.{"alpha"},
        .setup = struct {
            // Both branches change both lines: two conflicts.
            fn f(t: *T) !void {
                t.gpa.free(try t.git("alpha", &.{ "checkout", "-q", "-b", "other" }));
                try t.write(.{ .path = "alpha/a.txt", .data = "top\ntheirs one\nm1\nm2\nm3\nm4\ntheirs two\nend\n" });
                t.gpa.free(try t.git("alpha", &.{ "commit", "-q", "-am", "theirs" }));
                t.gpa.free(try t.git("alpha", &.{ "checkout", "-q", "main" }));
                try t.write(.{ .path = "alpha/a.txt", .data = "top\nours one\nm1\nm2\nm3\nm4\nours two\nend\n" });
                t.gpa.free(try t.git("alpha", &.{ "commit", "-q", "-am", "ours" }));
                try t.gitMayFail("alpha", &.{ "merge", "-q", "other" });
            }
        }.f,
        .runs = &.{.{ .open = &.{"alpha"}, .script = "frames:3;live:1;shortcut:ctrl+p;type:a.txt;key:enter;live:1;move:Accept Current;click:Accept Incoming;frames:3;click:Accept Current;frames:3;shortcut:ctrl+s;frames:3" }},
        .check = struct {
            fn f(t: *T) !void {
                try t.expectFile("alpha/a.txt", "top\ntheirs one\nm1\nm2\nm3\nm4\nours two\nend\n");
            }
        }.f,
    },
};

const palette = "shortcut:ctrl+shift+p;type:";
const close_project = palette ++ "Close Project;key:enter;frames:6;";

/// A case's run: its folder, its data folder, what it ran.
const T = struct {
    gpa: std.mem.Allocator,
    io: Io,
    dir: []const u8,
    env: *const std.process.Environ.Map,

    fn path(t: *T, rel: []const u8) ![]u8 {
        return std.fs.path.join(t.gpa, &.{ t.dir, rel });
    }

    fn expectFile(t: *T, rel: []const u8, want: []const u8) !void {
        const p = try t.path(rel);
        defer t.gpa.free(p);
        const got = try Dir.cwd().readFileAlloc(t.io, p, t.gpa, .limited(1 << 20));
        defer t.gpa.free(got);
        if (!std.mem.eql(u8, got, want)) {
            std.debug.print("    {s}: got {f}, want {f}\n", .{ rel, std.zig.fmtString(got), std.zig.fmtString(want) });
            return error.WrongFile;
        }
    }

    fn expectState(t: *T, want: []const u8) !void {
        const p = try t.path("data/state-zig.json");
        defer t.gpa.free(p);
        const got = try Dir.cwd().readFileAlloc(t.io, p, t.gpa, .limited(1 << 20));
        defer t.gpa.free(got);
        if (std.mem.indexOf(u8, got, want) == null) {
            std.debug.print("    state has no {s}:\n{s}\n", .{ want, got });
            return error.WrongState;
        }
    }

    fn expectGit(t: *T, rel: []const u8, args: []const []const u8, want: []const u8) !void {
        const out = try t.git(rel, args);
        defer t.gpa.free(out);
        const got = std.mem.trim(u8, out, " \r\n");
        if (!std.mem.eql(u8, got, want)) {
            std.debug.print("    git {s}: got {f}, want {f}\n", .{ args[0], std.zig.fmtString(got), std.zig.fmtString(want) });
            return error.WrongGit;
        }
    }

    fn git(t: *T, rel: []const u8, args: []const []const u8) ![]u8 {
        return t.gitRun(rel, args, false);
    }

    /// Git, whose failing is expected (a merge that conflicts).
    fn gitMayFail(t: *T, rel: []const u8, args: []const []const u8) !void {
        if (t.gitRun(rel, args, true)) |out| t.gpa.free(out) else |err| if (err != error.GitFailed) return err;
    }

    fn gitRun(t: *T, rel: []const u8, args: []const []const u8, quiet: bool) ![]u8 {
        const cwd = try t.path(rel);
        defer t.gpa.free(cwd);
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(t.gpa);
        try argv.appendSlice(t.gpa, &.{ "git", "-c", "user.name=uitest", "-c", "user.email=uitest@example.com", "-c", "commit.gpgsign=false", "-c", "core.autocrlf=false" });
        try argv.appendSlice(t.gpa, args);
        const r = try std.process.run(t.gpa, t.io, .{ .argv = argv.items, .cwd = .{ .path = cwd } });
        defer t.gpa.free(r.stderr);
        if (!r.term.success()) {
            if (!quiet) std.debug.print("    git {s}: {s}\n", .{ args[0], r.stderr });
            t.gpa.free(r.stdout);
            return error.GitFailed;
        }
        return r.stdout;
    }

    fn write(t: *T, f: File) !void {
        const p = try t.path(f.path);
        defer t.gpa.free(p);
        if (std.fs.path.dirname(p)) |d| try Dir.cwd().createDirPath(t.io, d);
        try Dir.cwd().writeFile(t.io, .{ .sub_path = p, .data = f.data });
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: uitest <mycode.exe> [name filter]\n", .{});
        return error.Usage;
    }
    const exe = try Dir.cwd().realPathFileAlloc(io, args[1], init.arena.allocator());
    const filter = if (args.len > 2) args[2] else "";
    const tmp = init.environ_map.get("TEMP") orelse init.environ_map.get("TMPDIR") orelse "/tmp";
    const work = try std.fs.path.join(init.arena.allocator(), &.{ tmp, "mycode-uitest" });

    var failed: usize = 0;
    var ran: usize = 0;
    for (cases, 0..) |case, i| {
        if (std.mem.indexOf(u8, case.name, filter) == null) continue;
        ran += 1;
        var name_buf: [16]u8 = undefined;
        const dir = try std.fs.path.join(gpa, &.{ work, try std.fmt.bufPrint(&name_buf, "case{d}", .{i}) });
        defer gpa.free(dir);
        Dir.cwd().deleteTree(io, dir) catch {};
        var t: T = .{ .gpa = gpa, .io = io, .dir = dir, .env = init.environ_map };
        if (runCase(&t, case, exe)) {
            std.debug.print("ok   {s}\n", .{case.name});
        } else |err| {
            failed += 1;
            std.debug.print("FAIL {s}: {t}\n", .{ case.name, err });
        }
    }
    std.debug.print("{d} of {d} passed\n", .{ ran - failed, ran });
    if (failed > 0) std.process.exit(1);
}

fn runCase(t: *T, case: Case, exe: []const u8) !void {
    for (case.files) |f| try t.write(f);
    for (case.repos) |r| {
        const out = try t.git(r, &.{ "init", "-q", "-b", "main" });
        t.gpa.free(out);
        t.gpa.free(try t.git(r, &.{ "add", "-A" }));
        t.gpa.free(try t.git(r, &.{ "commit", "-q", "-m", "first" }));
    }
    for (case.changes) |f| try t.write(f);
    if (case.setup) |setup| try setup(t);
    try t.write(.{ .path = "data/settings.json", .data = case.settings });

    var env = try t.env.clone(t.gpa);
    defer env.deinit();
    const data = try t.path("data");
    defer t.gpa.free(data);
    try env.put("MAYOI_DATA_DIR", data);

    const shot = try t.path("shot.png");
    defer t.gpa.free(shot);
    for (case.runs) |run| {
        var argv: std.ArrayList([]const u8) = .empty;
        defer {
            for (argv.items[1..]) |a| t.gpa.free(a);
            argv.deinit(t.gpa);
        }
        try argv.append(t.gpa, exe);
        for (run.open) |o| try argv.append(t.gpa, try t.path(o));
        try argv.append(t.gpa, try std.fmt.allocPrint(t.gpa, "--myzig-snapshot={s}", .{shot}));
        try argv.append(t.gpa, try std.fmt.allocPrint(t.gpa, "--myzig-script={s}", .{run.script}));
        try argv.append(t.gpa, try t.gpa.dupe(u8, "--myzig-dark"));
        const r = try std.process.run(t.gpa, t.io, .{ .argv = argv.items, .environ_map = &env, .stdout_limit = .limited(16 << 20), .stderr_limit = .limited(16 << 20) });
        defer t.gpa.free(r.stdout);
        defer t.gpa.free(r.stderr);
        if (!r.term.success()) {
            // The error, or a panic's message, and where to look.
            var lines = std.mem.splitScalar(u8, r.stderr, '\n');
            while (lines.next()) |l| if (std.mem.startsWith(u8, l, "error:") or std.mem.indexOf(u8, l, "panic") != null) {
                std.debug.print("    {s}\n", .{std.mem.trimEnd(u8, l, "\r")});
                break;
            };
            std.debug.print("    script: {s}\n    folder: {s}\n", .{ run.script, t.dir });
            return error.AppFailed;
        }
    }
    if (case.check) |check| try check(t);
}
