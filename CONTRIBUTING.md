# Contributing

## Development

MyCode needs Zig 0.17 and a checkout of [myzig](https://github.com/hunghg255/myzig) beside this folder (`../myzig`).

```sh
zig build run -- <folder-or-file>                           # run MyCode
../myzig/cli/zig-out/bin/myzig dev                          # run it, rebuilt and restarted as its files change
zig build test                                              # unit tests
zig build uitest                                            # UI tests: the app run headless with scripts
zig build uitest -- "quick open"                            # the UI tests whose names hold "quick open"
```

Set `MAYOI_DATA_DIR` to a folder of its own to run a development build beside the everyday MyCode, with its own
settings and windows' state.

A UI test (`uitest/main.zig`) makes its folders, settings and Git repositories in `%TEMP%\mycode-uitest`, then runs
the app with `--myzig-snapshot` and a script of clicks, keys and typing (myzig's `ui.Tester.runScript`). A step that
finds no text fails the run, as a crash does, so `move:TEXT` checks that a text is shown; a case may then check what
the app left behind: a saved file, a commit, its state. To see what a script does, run the app with the same flags
and look at the snapshot:

```sh
MAYOI_DATA_DIR=/tmp/data zig-out/bin/mycode.exe <folder> --myzig-dark --myzig-snapshot=shot.png \
    --myzig-script="frames:3;shortcut:ctrl+p;type:main;key:enter"
```

The screenshots in `docs/screenshots` are taken the same way, with `--myzig-snapshot`.

Add a line under `## Unreleased` in `CHANGELOG.md` for every change people will see, and describe features in
`docs/FEATURES.md` and settings in `docs/SETTINGS.md`. `docs/ARCHITECTURE.md` is a tour of the source.

## Releasing

Write the release notes under `## Unreleased` in `CHANGELOG.md` and commit them on `main`, then:

```sh
scripts/bump.sh patch    # or minor, major, or a version such as 0.2.0
```

It sets the version in `build.zig.zon`, renames `## Unreleased` to `## <version>` in `CHANGELOG.md`, commits and tags
`v<version>`, and after asking pushes `main` and the tag, builds the installer and the portable zip with the myzig
CLI (`../myzig/cli`, with [NSIS](https://nsis.sourceforge.io) on the `PATH`) and publishes them as the GitHub release
with `gh`. Installed apps check the latest release once a day, and from **Help → Check for Updates…**; the update
window shows the changelog section.

Windows builds are not signed, and updates are not checked against a signing key yet (see the README's
**Not yet**).
