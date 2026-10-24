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
| `Apk` | Packages Android native libraries into a signed APK, with no Java or Kotlin |
| `Docs` | Includes private declarations in Zig's generated documentation |
| `Pkg` | Builds an installable package: `.pkg` (macOS), `.deb` (Linux), `.msi` (Windows) |

Several extensions work around defects in Zig 0.17.0 or the macOS 27 SDK;
each is written to be deleted on its own once the cause goes away.

## Requirements

- **Zig 0.17.** `build.zig` refuses any other minor release; the workarounds
  were checked against 0.17.0. zigbuildx 1.x is the Zig 0.16 release; 3.0.0
  changed `Xcode.init` and `Android.init` to take `b`.
- **Hosts:** macOS (Apple Silicon), Linux (arm64, x86_64) and Windows (x86_64,
  arm64). Apple-only extensions fall back to plain behaviour elsewhere.
- **Per extension:**
  - `Deps`: `git`; `curl` for an `https://` `.archive`.
  - `Xcode`, `Swift`: Xcode or the Command Line Tools.
  - `Android`, `Apk`: the Android SDK and NDK; a JDK's `keytool` for the debug
    keystore.
  - `Pkg`: `pkgbuild` and `codesign` for macOS; `wixl` (`apt install wixl`, or
    Homebrew's `msitools`) for Windows. Linux packages need no tools.

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
  - `.bundle`: the bundle id in reverse DNS, three labels
    (`com.example.tool`), required by `zig build pkg`. It is the package id,
    and its second and last labels name the install directory.
- **`signing.zon`**, in the project root, holds the Apple signing identity and
  notarization credentials as `.apple_id`, `.apple_password`, `.apple_name`
  and `.apple_team`. It must be listed in `.gitignore`; `Pkg` refuses it
  otherwise. Without it, macOS packages are built unsigned.
- **Environment:** `ANDROID_HOME` or `ANDROID_SDK_ROOT`, `ANDROID_NDK_HOME` or
  `ANDROID_NDK_ROOT`, and `JAVA_HOME`. Each falls back to Android Studio's
  defaults or `PATH`. A release APK's keystore password is best passed as
  `env:VAR`, keeping it off the command line.
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

Build an Android library and package it as an APK:

```zig
var android = try zigbuildx.Android.init(b);
try android.resolve();
const lib = b.addLibrary(.{ .name = "main", .linkage = .dynamic, .root_module = b.createModule(.{
    .root_source_file = b.path("src/main.zig"),
    .target = zigbuildx.Android.resolveTarget(b, .arm64V8a, 30),
}) });
try android.configure(lib);
const apk = try zigbuildx.Apk.add(&android, b, .{ .name = "app", .manifest = b.path("AndroidManifest.xml"), .resources = b.path("res"), .libraries = &.{lib} });
```

Document private declarations:

```zig
const docs = zigbuildx.Docs.includePrivate(b, lib.getEmittedDocs());
```

Build an installable package of a project's executables:

```zig
_ = zigbuildx.Pkg.add(b, zon, .{ .executables = &.{exe} });
```

```sh
zig build pkg -Doptimize=fast                         # zig-out/pkg/<name>-<version>.pkg
zig build pkg -Doptimize=fast -Dtarget=aarch64-linux  # <name>_<version>_arm64.deb, package <bundle>
zig build pkg -Doptimize=fast -Dtarget=x86_64-windows # <name>-<version>-x64.msi
zig build pkg-notarize -Doptimize=fast                # macOS: notarize and staple
```

Shared libraries the programs load go in `lib` beside `bin`, under the name
the programs expect (on Windows, in `bin`), and are signed with them:

```zig
_ = zigbuildx.Pkg.add(b, zon, .{ .executables = &.{exe}, .libraries = &.{.{ .name = "libfoo.dylib", .path = dylib }} });
```

Packages install to `/usr/local/<org>/<name>` (per user under
`%LOCALAPPDATA%\<org>\<name>` on Windows) and put its `bin` on `PATH`, where
`.bundle = "com.<org>.<name>"`; `com.example.tool` installs to
`/usr/local/example/tool`. Each program keeps its executable's name; the
project's `.name` plays no part.
Without `wixl`, a Windows package stops after writing its WiX source and
programs to `zig-out/pkg/<name>-<version>-wix/`, with the command to finish it.

## Architecture

```
build.zig        the public surface: re-exports each extension, declares the host tool
src/module.zig   the barrel the tests compile
src/tool.zig     the host tool: one program, a command per job a step hands it
src/             build-side extensions: deps, git, xcode, swift, android, docs
src/pkg/         packaging: pkg.zig (zig build pkg), one folder per platform
  macos/         pkgbuild.zig and the install scripts
  linux/         deb.zig and the maintainer scripts
  windows/       msi.zig (WiX source for wixl)
  android/       apk.zig and apk_zip.zig
```

Code that compiles lives at the top of `src/`; code that assembles an
installable package lives under `src/pkg/`. Each extension is one struct per
file, re-exported from `build.zig`, whose `pub` declarations are the package's
whole surface. Work that would otherwise need a platform-specific shell tool
(`zip`, `dpkg-deb`, `sed -i`), and work a step must do while the build runs
(a Zig 0.17 step cannot run code of its own), is done by zigbuildx's host
tool, built from `src/tool.zig` for the build host.
