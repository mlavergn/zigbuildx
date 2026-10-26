# zigbuildx

> Zig build system extensions for `build.zig` and `build.zig.zon`.

## Overview

zigbuildx holds build logic that `std.Build` does not provide, so it lives in
one place instead of being copied from one project's `build.zig` to the next,
where the copies drift. It is imported, not run: nothing acts unless a
`build.zig` calls it, and it has no opinion about a project's layout or steps.

| Extension | What it does |
|---|---|
| `Deps` | Clones missing sibling checkouts and keeps them up to date, unpacks source archives, and gives pinned dependencies their own git worktree |
| `Git` | Runs `git` commands for the build |
| `Xcode` | Finds the macOS SDK, sets a macOS deployment floor, links frameworks |
| `Swift` | Builds a Swift dylib that a Zig package links against |
| `Android` | Builds Android native libraries against the NDK |
| `Docs` | Includes private declarations in Zig's generated documentation |

Packaging is not here: [zigpkg](https://github.com/mlavergn/zigpkg) (`zpkg`)
turns what a build made into a `.pkg`, `.deb`, `.msi` or `.apk`. zigbuildx
4.0.0 removed `Pkg` and `Apk`; see *Migrating from 3.x*.

Several extensions work around defects in Zig 0.17.0 or the macOS 27 SDK;
each is written to be deleted on its own once the cause goes away.

## Requirements

- **Zig 0.17.** `build.zig` refuses any other minor release; the workarounds
  were checked against 0.17.0. zigbuildx 1.x is the Zig 0.16 release; 3.0.0
  changed `Xcode.init` and `Android.init` to take `b`; 4.0.0 removed `Pkg`
  and `Apk`.
- **Hosts:** macOS (Apple Silicon), Linux (arm64, x86_64) and Windows (x86_64,
  arm64). Apple-only extensions fall back to plain behaviour elsewhere.
- **Per extension:**
  - `Deps`: `git`; `curl` for an `https://` `.archive`.
  - `Xcode`, `Swift`: Xcode or the Command Line Tools.
  - `Android`: the Android SDK's NDK.

## Setup

Add zigbuildx to a project:

```sh
zig fetch --save git+https://github.com/mlavergn/zigbuildx
```

It must stay a `.url` + `.hash` dependency, never a `.path`: a missing `.path`
dependency fails to compile before `Deps` could clone it. Then, in `build.zig`:

```zig
const zon = @import("build.zig.zon");
const zigbuildx = @import("zigbuildx");
```

To work on zigbuildx itself:

```sh
git clone git@github.com:mlavergn/zigbuildx.git
cd zigbuildx
make validate  # clean, format, lint, build, test, cross
```

## Configuration

- **`build.zig.zon` fields**, which Zig ignores and zigbuildx reads:
  - `.clone`: where `Deps` clones a missing `.path` dependency from; a
    sibling's own `.path` dependencies are cloned from its manifest's `.clone`.
  - `.archive`: instead of `.clone`, the URL of a zip `Deps` unpacks at the
    `.path` (a source release that is not a git repository); see *Usage*.
  - `.sha`, `.tag`, `.branch`: pin a dependency to its own worktree under
    `deps/`; `.checkout` names the shared checkout (default `../<name>`).
- **Environment:** `ANDROID_HOME` or `ANDROID_SDK_ROOT`, and
  `ANDROID_NDK_HOME` or `ANDROID_NDK_ROOT`. Each falls back to Android
  Studio's defaults.
- **Build options:** `-Dmacos-min` (from `Xcode.standardTargetOptions`) and
  `-Dupdate` (from `Deps`: fetch and fast-forward dependencies).
- **Ignore `deps/`** in a project that pins dependencies, and keep it out of
  `zig fmt` and linting.

## Usage

Call `Deps` first in `build()`; `sync` also handles everything `cloneMissing`
does:

```zig
pub fn build(b: *std.Build) !void {
    zigbuildx.Deps.sync(b, zon);
    // ...
}
```

Pin a dependency to its own worktree, and list or update the worktrees:

```zig
.zigstorage = .{ .path = "deps/zigstorage", .clone = "git@github.com:org/zigstorage.git", .tag = "1.6.7" },
```

```sh
zig build deps            # each worktree: pin, commit, clean or dirty
zig build deps -Dupdate   # fetch, and fast-forward branch pins
```

A dependency `Deps` clones or a worktree it creates or moves ends the build
with `error: configure command exited with code 1`, after
`dependencies changed; re-run zig build`: run `zig build` again.

Unpack a source release that is not a git repository, such as SQLite's
amalgamation, at a `.path`:

```zig
.sqlite = .{ .path = "sqlite", .archive = "https://www.sqlite.org/2026/sqlite-amalgamation-3540100.zip" },
```

```zig
const sqlite3_c = b.dependency("sqlite", .{}).path("sqlite3.c");
```

`cloneMissing` or `sync` downloads the zip (with `curl`; `file://` is read
directly), strips its single top-level folder as `zig fetch` does, and adds a
stub `build.zig` when it has none, so Zig sees a package there. A
`.zigbuildx-archive` file in the directory records the URL: changing the URL
replaces the directory on the next build, and a directory without that file
is never touched. Unlike a clone, an unpack needs no re-run: the same build
goes on with the files in place. Git-ignore the path. The URL is the pin, so an `.archive`
takes no `.sha`, `.tag` or `.branch`, and `-Dupdate` leaves it alone. Zig
verifies no hash for it, so point it at a source you trust over `https://`.

Bring sibling checkouts (`../x`) up to date, with `cloneMissing` or `sync`:

```sh
zig build -Dupdate   # fetch each sibling, fast-forward those behind their upstream
```

A sibling is moved only when it is clean, on a branch with an upstream, and
has no commits of its own; otherwise it is skipped with a warning and the
build goes on. Under `sync`, `-Dupdate` also fast-forwards branch worktrees,
and one it must skip fails the build. Anything moved ends the build as above,
with `dependencies updated; re-run zig build`.

To update automatically after a compile error, call `guard` last in
`build()`:

```zig
pub fn build(b: *std.Build) !void {
    zigbuildx.Deps.cloneMissing(b, zon);
    // ... every artifact and step ...
    zigbuildx.Deps.guard(b);
}
```

When a compile reached from `zig build`'s default step fails, `guard` leaves
`.zig-cache/zigbuildx/update`; the next `zig build` updates as `-Dupdate`
would, then deletes it. A step that does not depend on the default one
(usually `test`), and a failure after the compiles, leave none.

Target macOS with a floor and link frameworks:

```zig
const target = try zigbuildx.Xcode.standardTargetOptions(b, "26.0");
if (b.graph.host.result.os.tag == .macos) {
    var xcode = try zigbuildx.Xcode.init(b);
    try xcode.resolve();
    xcode.linkFramework(lib.root_module, "CoreFoundation");
}
```

Build and link a Swift dylib:

```zig
const shim = zigbuildx.Swift.addDylib(b, .{ .name = "afm", .sources = &.{b.path("swift/AFM.swift")}, .bridging_header = b.path("swift/afm.h"), .target = target, .optimize = optimize });
zigbuildx.Swift.link(exe.root_module, "afm", shim);
```

Build an Android library (`zpkg --package --format apk` packages it):

```zig
var android = try zigbuildx.Android.init(b);
try android.resolve();
const lib = b.addLibrary(.{ .name = "main", .linkage = .dynamic, .root_module = b.createModule(.{
    .root_source_file = b.path("src/main.zig"),
    .target = zigbuildx.Android.resolveTarget(b, .arm64V8a, 30),
}) });
try android.configure(lib);
```

Document private declarations:

```zig
const docs = zigbuildx.Docs.includePrivate(b, lib.getEmittedDocs());
```

### Migrating from 3.x

`Pkg` and `Apk` moved to zigpkg, which packages what a build already made:
build first, then run `zpkg --package`, which reads the project's
`package.zon` (beside `build.zig`, committed). Its top level takes the bundle
id apart: `.bundle = "com.example.tool"` becomes `.domain = "com"`,
`.org = "example"`, `.name = "tool"` (and its own `.version`), and still
installs to `/usr/local/example/tool`; each format is a section.

```zig
.{
    .org = "example",
    .name = "tool",
    .version = "1.0.0",
    .pkg = .{ .root = "zig-out/pkg/root" },
}
```

- **`zig build pkg`:** delete `zigbuildx.Pkg.add(...)`, then
  `zig build --release=fast --prefix zig-out/pkg/root` and `zpkg --package`,
  which writes `zig-out/pkg/tool-1.0.0.pkg`. A `.pkg` section with no
  `.account` builds it unsigned, as `Pkg` did without signing credentials,
  and needs no `signing.zon`; with one, zigpkg signs it with that account's
  identities, without the keychain.
- **`zig build pkg-notarize`:** the section's `.notarize = true`.
- **`.deb`, `.msi`:** `--format deb` (with `--arch`) or `--format msi`.
  `Pkg`'s per-user `.msi`, with arm64 programs in an x86 installer, is
  `.scope = "user"` and `.platform = "x86"`.
- **`PkgOptions.libraries`:** put them in the payload's `lib/` beside `bin/`
  (in `bin/` for Windows), and list them in `.sign` to have them signed.
- **`Apk.add`:** build the libraries, then `zpkg --package --format apk`,
  whose `.apk` section names the manifest, `res/` and keystore. The keystore password
  is kept in zigpkg's vault, no longer on the command line.
- **`signing.zon`:** only to sign, publish or use a release keystore: zigpkg
  reads it from where `zpkg` runs and needs its `.store`. Its `.apple_*`
  fields are only imported, once, into an account.

## Architecture

```
build.zig        the public surface: re-exports each extension, declares the host tool
src/module.zig   the barrel the tests compile
src/tool.zig     the host tool: one program, a command per job a step hands it
src/             the extensions: deps, git, xcode, swift, android, docs, zip_archive
```

Each extension is one struct per file, re-exported from `build.zig`, whose
`pub` declarations are the package's whole surface. Work that would otherwise
need a platform-specific shell tool (`sed -i`), and work a step must do while
the build runs (a Zig 0.17 step cannot run code of its own), is done by
zigbuildx's host tool, built from `src/tool.zig` for the build host.
