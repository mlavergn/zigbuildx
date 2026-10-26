# zigbuildx

> Zig build system extensions.

## Overview

zigbuildx provides build tools that `std.Build` does not provide by default.
Nothing acts unless a `build.zig` calls it.

| Extension | What it does |
|---|---|
| `Deps` | Clones missing sibling checkouts and keeps them up to date, unpacks source archives, gives pinned dependencies their own git worktree, and repins zigbuildx |
| `Git` | Runs `git` commands for the build |
| `Xcode` | Finds an Apple platform's SDK (macOS, iOS, tvOS, visionOS, watchOS), sets a macOS deployment floor, links frameworks, assembles `.xcframework`s |
| `Swift` | Builds a Swift dylib that a Zig package links against |
| `Android` | Builds Android native libraries against the NDK |
| `Docs` | Includes private declarations in Zig's generated documentation |

## Requirements

- **Zig 0.17.** `build.zig` refuses any other minor release.
- **Hosts:** macOS (Apple Silicon), Linux (arm64, x86_64) and Windows (x86_64,
  arm64). Apple-only extensions do nothing elsewhere.
- **Per extension:**
  - `Deps`: `git`; `curl` for an `https://` `.archive`.
  - `Xcode`, `Swift`: Xcode or the Command Line Tools; Xcode with the
    platform for iOS, tvOS, visionOS or watchOS.
  - `Android`: the Android SDK's NDK.

## Setup

Add zigbuildx to a project, as a `.url` dependency (never a `.path`):

```sh
zig fetch --save git+https://github.com/mlavergn/zigbuildx
```

```zig
const zon = @import("build.zig.zon");
const zigbuildx = @import("zigbuildx");
```

To work on zigbuildx itself:

```sh
git clone git@github.com:mlavergn/zigbuildx.git
cd zigbuildx
make validate
```

## Configuration

- **`build.zig.zon` fields**, which Zig ignores and zigbuildx reads:
  - `.clone`: where `Deps` clones a missing `.path` dependency from.
  - `.archive`: instead of `.clone`, a zip `Deps` unpacks at the `.path`.
  - `.sha`, `.tag`, `.branch`: pin a dependency to its own worktree under
    `deps/` (`sync` only); `.checkout` names the shared checkout (default
    `../<name>`).

```zig
.{
    // .name, .version, .fingerprint and .paths, as `zig init` writes them
    .dependencies = .{
        // zigbuildx itself, written by `zig fetch --save` or `zig build zigbuildx-pin`
        .zigbuildx = .{
            .url = "git+https://github.com/mlavergn/zigbuildx?ref=v4.1.0#<commit>",
            .hash = "zigbuildx-4.1.0-<hash>",
        },
        // A sibling checkout, cloned when ../mylib is missing
        .mylib = .{ .path = "../mylib", .clone = "git@github.com:org/mylib.git" },
        // A source release that is not a git repository, unpacked from a zip
        .sqlite = .{ .path = "sqlite", .archive = "https://www.sqlite.org/2026/sqlite-amalgamation-3540100.zip" },
        // Worktrees of a shared checkout, pinned to a tag, a branch or a commit
        .json = .{ .path = "deps/json", .clone = "git@github.com:org/json.git", .tag = "v1.2.0" },
        .log = .{ .path = "deps/log", .clone = "git@github.com:org/log.git", .branch = "main" },
        .csv = .{ .path = "deps/csv", .checkout = "../csv-checkout", .sha = "<commit>" },
    },
}
```

An `.archive` is not hash-checked, so point it at a source you trust over
`https://`.

- **Environment:** `ANDROID_HOME` or `ANDROID_SDK_ROOT`, and
  `ANDROID_NDK_HOME` or `ANDROID_NDK_ROOT`, each falling back to Android
  Studio's defaults.
- **Build options:** `-Dmacos-min` (from `Xcode.standardTargetOptions`) and
  `-Dupdate` (from `Deps`).
- **Ignore `deps/`** in a project that pins dependencies, and keep it out of
  `zig fmt` and linting. Git-ignore an `.archive`'s path too.

## Usage

Call `Deps` first in `build()` (`sync` does everything `cloneMissing` does,
plus worktrees), and `guard` last:

```zig
pub fn build(b: *std.Build) !void {
    zigbuildx.Deps.sync(b, zon);
    // ... every artifact and step ...
    zigbuildx.Deps.guard(b); // after a compile error, the next build updates dependencies
}
```

When `Deps` clones or moves anything, the build stops with
`dependencies changed; re-run zig build`: run it again.

```sh
zig build deps            # list the worktrees: pin, commit, clean or dirty
zig build -Dupdate        # fetch, and fast-forward siblings and branch pins
zig build zigbuildx-pin   # pin zigbuildx to its newest release (`make buildxpin`); a branch pin stays on its branch
```

Target Apple platforms and link frameworks:

```zig
const target = try zigbuildx.Xcode.standardTargetOptions(b, "26.0"); // macOS floor
var xcode = try zigbuildx.Xcode.initFor(b, target); // does nothing for non-Apple targets
try xcode.configure(lib); // needed for iOS, tvOS, visionOS and watchOS
xcode.linkFramework(lib.root_module, "CoreFoundation");
```

Assemble an `.xcframework` from one library per platform and architecture,
each built and configured for its own target as above:

```zig
const xcf = try zigbuildx.Xcode.addXcframework(b, .{ .name = "Hello", .libraries = &.{ ios, sim_arm64, sim_x86_64, macos }, .headers = b.path("include") });
if (xcf) |dir| b.getInstallStep().dependOn(&b.addInstallDirectory(.{ .source_dir = dir, .install_dir = .prefix, .install_subdir = "Hello.xcframework" }).step);
```

Swift, Android and docs:

```zig
const shim = zigbuildx.Swift.addDylib(b, .{ .name = "shim", .sources = &.{b.path("swift/Shim.swift")}, .target = target, .optimize = optimize });
zigbuildx.Swift.link(exe.root_module, "shim", shim);

var android = try zigbuildx.Android.init(b);
try android.resolve();
try android.configure(lib); // lib's target from zigbuildx.Android.resolveTarget(b, .arm64V8a, 30)

const docs = zigbuildx.Docs.includePrivate(b, lib.getEmittedDocs());
```
