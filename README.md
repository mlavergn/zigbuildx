# zigbuildx

> Zig build system extensions.

## Overview

zigbuildx provides build tools that `std.Build` does not provide by default.
Nothing acts unless a `build.zig` calls it.

| Extension | What it does |
|---|---|
| `Deps` | Clones missing sibling checkouts and keeps them up to date, builds them at their declared branch or tag in CI, unpacks source archives, gives pinned dependencies their own git worktree, and repins zigbuildx |
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
  - On a sibling (`../x`), `.branch` or `.tag` says what it is cloned at,
    and what a CI build uses (see *CI builds*): a `.branch` is followed, a
    `.tag` is left where it is. `.sha` is refused there.

```zig
.{
    // .name, .version, .fingerprint and .paths, as `zig init` writes them
    .dependencies = .{
        // zigbuildx itself, written by `zig fetch --save` or `zig build zigbuildx-pin`
        .zigbuildx = .{
            .url = "git+https://github.com/mlavergn/zigbuildx?ref=v5.1.0#<commit>",
            .hash = "zigbuildx-5.1.0-<hash>",
        },
        // A sibling checkout, cloned when ../mylib is missing
        .mylib = .{ .path = "../mylib", .clone = "git@github.com:org/mylib.git" },
        // A sibling that follows a branch other than the remote's default
        .mytool = .{ .path = "../mytool", .clone = "git@github.com:org/mytool.git", .branch = "dev" },
        // A sibling held at a release tag
        .myfmt = .{ .path = "../myfmt", .clone = "git@github.com:org/myfmt.git", .tag = "v2.1.0" },
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
- **Build options:** `-Dci` (from `Deps`; default on when `CI` is set),
  `-Dmacos-min` (from `Xcode.standardTargetOptions`).
- **Ignore `deps/`** in a project that pins dependencies, and keep it out of
  `zig fmt` and linting. Git-ignore an `.archive`'s path too.

## Usage

Call `Deps` first in `build()`, either `cloneMissing` or `sync`, not both
(`sync` does everything `cloneMissing` does, plus worktrees):

```zig
pub fn build(b: *std.Build) !void {
    zigbuildx.Deps.sync(b, zon);
    // ... every artifact and step ...
}
```

Whenever `build()` runs, `Deps` fetches and fast-forwards every sibling and
`.branch` worktree that has no uncommitted changes and no commits of its own;
one with work of its own is skipped, with a warning, without touching the
network. A sibling whose `.branch` is not the branch it is on is skipped the
same way. A sibling with a `.tag` is never fetched or moved; one that is not
at its tag gets a warning. `.sha` and `.tag` worktrees and `.archive`s are
never fetched. An empty checkout, as an interrupted clone leaves, is filled
in from its `.clone`.

When `Deps` clones, fills in, moves or fast-forwards anything, the build
stops with `dependencies changed; re-run zig build` (or `dependencies
updated`): run it again.

```sh
zig build deps            # list the worktrees: pin, commit, clean or dirty
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

## CI builds

On a developer's machine, siblings are the developer's own checkouts. A CI
build instead needs the same tree every time. Build with `-Dci` (on by
default when the `CI` environment variable is set, as most CI services do)
and every sibling, siblings of siblings included, is cloned at or moved to
the ref its manifest declares:

| Declared | CI builds |
|---|---|
| `.tag = "v2.1.0"` | that tag |
| `.branch = "dev"` | the tip of `origin/dev` |
| neither | the tip of the remote's default branch |

A sibling with uncommitted changes, commits that are not pushed, or a
branch with no upstream fails the build rather than being moved; build with
`-Dci=false` to keep it. A failed fetch, or a ref the remote does not have,
fails it too, as does a `.branch` worktree under `deps/` that cannot be
brought to its branch's tip. If two manifests name different refs for one sibling, the
first found (the root's first) wins, with a warning.

Siblings are cloned beside the project (`../x`), so check the project out
into a folder of its own inside the CI workspace, and give git the
credentials for the private repositories:

```sh
# workspace/app is the project; its siblings are cloned to workspace/<name>
cd app
zig build -Dci || zig build -Dci   # the first run exits 1 after cloning
zig build -Dci test
```

- **Credentials:** a deploy key or `GIT_SSH_COMMAND` for `git@` URLs, or
  `git config --global url."https://x-access-token:$TOKEN@github.com/".insteadOf "git@github.com:"`
  to fetch them over HTTPS with a token.
- **Exit code:** Zig reports every configure failure as exit 1, so a run that
  cloned or moved a sibling cannot be told apart from a failure by its code;
  run it again, as above. A second failure is a real one.
- **Every configure checks the remotes** in CI mode; nothing is cached.
- **`CI` and the configure cache:** Zig does not track the environment. On a
  machine that also builds without `CI`, pass `-Dci` explicitly.

## Migrating from 5.0

Nothing to change. 5.1 adds `-Dci` and accepts `.tag` on a sibling.

## Migrating from 4.x

- **`-Dupdate` is gone:** every build that runs `build()` updates, as
  `-Dupdate` did, but skips any checkout with work of its own before
  fetching it. A skip or a failed fetch (offline) warns and never fails the
  build. Drop `-Dupdate` from scripts.
- **`Deps.guard` and the `deps-mark` command are gone:** delete the
  `zigbuildx.Deps.guard(b);` line. A failed compile no longer triggers
  anything, since every build already updates.
- **`zig build deps` only lists:** its `--update` is gone with `-Dupdate`.
- **Tag checkouts are not fetched:** `zig build deps` reports a tag moved
  upstream only after something else fetched its checkout.
- **A sibling may take `.branch`.** `.sha` on a `../x` is still refused
  (5.1 accepts `.tag`).
