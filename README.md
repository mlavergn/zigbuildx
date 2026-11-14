# zigbuildx

> Zig build system extensions.

## Overview

zigbuildx provides build tools that `std.Build` does not provide by default.
Nothing acts unless a `build.zig` calls it.

| Extension | What it does |
|---|---|
| `Deps` | Clones missing sibling checkouts and keeps them up to date, stages them as Zig packages for distribution builds that read nothing outside the project, writes vendored source tarballs that build with no network, unpacks source archives, gives pinned dependencies their own git worktree, and repins zigbuildx |
| `Git` | Runs `git` commands for the build |
| `Xcode` | Finds an Apple platform's SDK (macOS, iOS, tvOS, visionOS, watchOS), sets a macOS deployment floor, links frameworks, assembles `.xcframework`s |
| `Swift` | Builds a Swift dylib that a Zig package links against |
| `App` | Installs a GUI executable as its platform expects: a macOS `.app` bundle, or a Linux desktop entry and icon |
| `Android` | Builds Android native libraries against the NDK |
| `Docs` | Includes private declarations in Zig's generated documentation, and serves a site locally with no `python3` |

## Requirements

- **Zig 0.17.1 or a later 0.17.** `build.zig` refuses 0.17.0 and any other
  minor release.
- **Hosts:** macOS (Apple Silicon), Linux (arm64, x86_64) and Windows (x86_64,
  arm64). Apple-only extensions do nothing elsewhere.
- **Per extension:**
  - `Deps`: `git`; `curl` for an `https://` `.archive`.
  - `Xcode`, `Swift`: Xcode or the Command Line Tools; Xcode with the
    platform for iOS, tvOS, visionOS or watchOS.
  - `Android`: the Android SDK's NDK.
  - `App`: nothing; it runs no tool, so a macOS bundle builds on any host.

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
make validate   # the gate: format, lint, build, test, cross-compile
make vendor     # the end-to-end check of zig build vendor (about a minute), before a release
```

## Configuration

- **`build.zig.zon` fields**, which Zig ignores and zigbuildx reads:
  - `.clone`: where `Deps` clones a missing `.path` dependency from.
  - `.archive`: instead of `.clone`, a zip `Deps` unpacks at the `.path`.
  - `.sha`, `.tag`, `.branch`: pin a dependency to its own worktree under
    `deps/` (`sync` only); `.checkout` names the shared checkout (default
    `../<name>`).
  - On a sibling (`../x`), `.branch` or `.tag` says what it is cloned at,
    and what a distribution build uses (see *Distribution builds*): a
    `.branch` is followed, a `.tag` is left where it is. `.sha` is refused
    there. A distribution build needs a
    `.clone` or an `.archive` on every sibling.

```zig
.{
    // .name, .version, .fingerprint and .paths, as `zig init` writes them
    .dependencies = .{
        // zigbuildx itself, written by `zig fetch --save` or `zig build zigbuildx-pin`
        .zigbuildx = .{
            .url = "git+https://github.com/mlavergn/zigbuildx?ref=v6.1.0#<commit>",
            .hash = "zigbuildx-6.1.0-<hash>",
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
- **Build options:** `-Ddist` (from `Deps`; see *Distribution builds*),
  `-Dmacos-min` (from `Xcode.standardTargetOptions`).
- **Ignore `deps/`** in a project that pins dependencies, and keep it out of
  `zig fmt` and linting. Git-ignore an `.archive`'s path too, and `zig-pkg/`
  and `build.zig.zon.orig`, which a distribution build writes.

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
zig build dev             # after a distribution build (cloneMissing): put back build.zig.zon, to build against ../ again
zig build vendor          # write a source tarball that builds with no network (cloneMissing; see *Vendored source tarballs*)
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

Install a GUI executable: on macOS `Hello.app` at the top of the prefix
(unsigned; `LSMinimumSystemVersion` is the `-Dmacos-min` floor, else 13.0), on
Linux `bin/Hello` with `share/applications/Hello.desktop` and the icon,
elsewhere the executable alone, under its artifact name. `.opens` says what
a Linux launcher may hand the app (`.file` writes `Exec=Hello %f`; the default
`.nothing` writes no field code), and `.mime_types` the types a file manager
offers it for (`"text/plain;inode/directory;"` for text files and folders),
which needs `.opens`. A version's `-rc1` or `+build` suffix is
dropped from the plist. A bad name, identifier or version, `.mime_types`
without `.opens`, or a bundle file name or `linux_subdir` that leaves its
directory, fails the build:

```zig
const app: zigbuildx.AppBundle = .{ .name = "Hello", .identifier = "com.example.hello", .version = zon.version, .exe = exe, .icns = b.path("assets/Hello.icns"), .png = b.path("assets/Hello.png") };
const install = zigbuildx.App.addInstall(b, app, null); // or pass zigbuildx.App.addBundle(b, app), the .app as a LazyPath
b.step("app", "Install the app").dependOn(install);
b.getInstallStep().dependOn(install);
```

Swift, Android and docs:

```zig
const shim = zigbuildx.Swift.addDylib(b, .{ .name = "shim", .sources = &.{b.path("swift/Shim.swift")}, .target = target, .optimize = optimize });
zigbuildx.Swift.link(exe.root_module, "shim", shim);

var android = try zigbuildx.Android.init(b);
try android.resolve();
try android.configure(lib); // lib's target from zigbuildx.Android.resolveTarget(b, .arm64V8a, 30)

const docs = zigbuildx.Docs.includePrivate(b, lib.getEmittedDocs());
// Serve it on a free loopback port (or a fixed one), open the browser, block until Ctrl-C.
b.step("docs-serve", "Serve the docs").dependOn(zigbuildx.Docs.addServe(b, docs, 0));
```

`Docs.addServe` runs the host tool's `docs-serve`: GET and HEAD from the site's
directory on `127.0.0.1`, one response per connection, `application/wasm` for
`main.wasm`. Paths are never percent-decoded, and absolute paths, `..`,
backslashes and drive letters are refused, so no request reaches outside the
site.

## Distribution builds

On a developer's machine, siblings are the developer's own checkouts at
`../`. A distribution build instead needs the same tree every time. Build
with `-Ddist`, and every sibling, siblings of siblings included, is built at
the ref its manifest declares:

| Declared | A distribution build uses |
|---|---|
| `.tag = "v2.1.0"` | that tag |
| `.branch = "dev"` | the tip of `origin/dev` |
| neither | the tip of the remote's default branch |

If two manifests name different refs for one sibling, the first found (the
root's first) wins, with a warning.

### Under `cloneMissing`: staged packages

A distribution build reads nothing outside the project, and Zig never
fetches a sibling:

1. Each sibling is cloned with git into `.zig-cache/zigbuildx-dist/`, at its
   ref, or unpacked from its `.archive`.
2. Its commit is exported, its own siblings are written into its manifest by
   hash, and it goes into the project's `zig-pkg/` under the hash Zig
   computes for it.
3. `build.zig.zon` is rewritten so each sibling is a `.url` + `.hash`; the
   original is kept as `build.zig.zon.orig`. The run exits 1.
4. The re-run builds every sibling from `zig-pkg/`.

```sh
cd app                                 # the project alone; nothing beside it is needed
zig build -Ddist || zig build -Ddist   # the first run exits 1 after staging
zig build -Ddist test
```

- **Private repositories** need only git's credentials: Zig resolves each
  sibling by hash, and its `.url` is a label it never fetches. A private
  dependency must therefore be a sibling: Zig fetches a `.url` dependency
  itself, before `build()` runs. zigbuildx must be one Zig can fetch.
- **Every sibling needs a `.clone` or an `.archive`.** A `.sha`, a cycle of
  siblings, a ref the remote does not have, or a failed clone fails the build,
  and the manifest is left as it was.
- **Never commit the rewritten `build.zig.zon`.** `zig build dev` puts the
  original back; the next `zig build` builds against `../` again. Running
  `-Ddist` again on a rewritten manifest stages nothing and leaves
  `build.zig.zon.orig` alone, and `zig build dev` with nothing to restore
  says so and does nothing.
- **Caching:** keep `.zig-cache/zigbuildx-dist/` between runs to fetch the
  clones rather than clone them again.

### Under `sync`: siblings at `../`

Every sibling is cloned at or moved to its ref, beside the project (`../x`),
so build from a folder of its own, with room beside it for the siblings:

```sh
# work/app is the project; its siblings are cloned to work/<name>
cd app
zig build -Ddist || zig build -Ddist   # the first run exits 1 after cloning
zig build -Ddist test
```

A sibling with uncommitted changes, commits that are not pushed, or a
branch with no upstream fails the build rather than being moved; build
without `-Ddist` to keep it. A failed fetch, or a ref the remote does not
have, fails it too, as does a `.branch` worktree under `deps/` that cannot
be brought to its branch's tip.

### Either way

- **Credentials:** a deploy key or `GIT_SSH_COMMAND` for `git@` URLs, or
  `git config --global url."https://x-access-token:$TOKEN@github.com/".insteadOf "git@github.com:"`
  to fetch them over HTTPS with a token.
- **Exit code:** Zig reports every configure failure as exit 1, so a run that
  staged, cloned or moved a sibling cannot be told apart from a failure by its
  code; run it again, as above. A second failure is a real one.
- **Every configure checks the remotes** in a distribution build; nothing is
  cached.

## Vendored source tarballs

A distribution build resolves the manifests' refs every time it runs. A
vendored tarball is resolved once: the project and every package it reads,
at the commits you last built, in one `.tar.gz` that builds with Zig 0.17
and fetches nothing. It needs no git, no credentials and no network, and
none of its siblings' repositories have to exist any more.

| Route | Builds from | Network |
|---|---|---|
| develop (`zig build`) | your checkouts at `../x` | fetches and fast-forwards siblings |
| distribution (`-Ddist`) | the manifests' refs on the remotes | on every configure |
| vendored (`zig build vendor`) | your checkouts' `HEAD`s, frozen in one `.tar.gz` | none, to build the tarball or from it |

```sh
zig build vendor          # writes zig-out/vendor/<name>-<version>-<commit>.tar.gz
```

Run it in a project that calls `cloneMissing`, after a build in develop
mode, so every sibling is checked out:

1. The project's `HEAD` is exported. Its own `.path` dependencies inside
   it (a `deps/x` checkout, an unpacked `.archive`) are added as they are.
2. Each sibling, siblings of siblings included, is exported from its
   checkout at `../x` at its `HEAD`: what you built is what ships. An
   `.archive` sibling is copied as unpacked. A sibling needs no `.clone`.
3. Each goes into the export's `zig-pkg/` under its hash, and the
   manifests name them by hash, as a distribution build does. `zig build
   --fetch=all` adds every `.url` dependency, lazy ones and zigbuildx
   included, from Zig's global cache (Zig fetches one the cache lacks; no
   git remote is read).
4. A marker, `.zigbuildx-vendor`, records the Zig release, zigbuildx's
   hash, the project's commit and each sibling's repository and commit.
   A repository URL that carries credentials (`https://<token>@host/…`)
   is recorded without them.
5. The export is built with a global cache that holds no packages: a
   package missing from `zig-pkg/` would have to be fetched, so the build
   fails, and no tarball is written.
6. The tarball has one top-level folder, `<name>-<version>-<commit>`, the
   first 12 hex digits of the project's commit. Entries are sorted, with
   the commit's time and owner 0, so the same commits give the same bytes
   on the same kind of host.

```sh
tar xzf app-1.2.0-0123456789ab.tar.gz
cd app-1.2.0-0123456789ab
zig build                 # Zig 0.17; nothing is fetched, cloned or updated
```

- **Refused, all at once:** a project or sibling that is not a git
  checkout of its own; uncommitted changes to tracked files in the
  project, a sibling or a `deps/x` checkout (untracked files do not count,
  and are left out); a sibling with a `.branch` that is not on that branch,
  detached included; a sibling with a `.tag` that is not at it; a
  `build.zig.zon` rewritten by a distribution build (run `zig build dev`
  first). Also refused: a `.name` or `.version` that cannot name a file
  (letters, digits and `._+-`, not starting with `.`; no `.version` gives
  `0.0.0`), and anything in the tree that is not a file, a directory or a
  link.
- **Warned:** a `HEAD` (the project's or a sibling's) that no remote branch
  holds, as last fetched. The tarball builds, but nobody else can fetch
  that commit.
- **Inside a vendored tree** zigbuildx does nothing: `cloneMissing`
  returns at once, and `-Ddist`, `dev`, `zigbuildx-pin` and `vendor` each
  fail with a message.
- **Not included:** Zig itself, and anything outside the packages, such as
  an SDK or an NDK.
- **Time:** the proof builds the project. Its global cache,
  `.zig-cache/zigbuildx-vendor/global-cache`, is kept between runs
  (only its packages are emptied), so only the first run pays Zig's
  half-minute cache setup.
- **`sync`** does not declare `vendor` yet.

## Migrating from 6.0

- **`vendor` is a step of `cloneMissing`:** rename a `vendor` step of your
  own, as Zig refuses two steps of one name. Nothing else changes.

## Migrating from 5.x

- **A distribution build takes `-Ddist`,** and no environment variable turns
  it on.
- **Under `cloneMissing`, `-Ddist` stages the siblings** rather than cloning
  them to `../x`, so they no longer need a folder beside the project. Every
  sibling needs a `.clone` or an `.archive`; git-ignore `zig-pkg/` and
  `build.zig.zon.orig`.
- **`dev` is a step of `cloneMissing`:** rename a `dev` step of your own, as
  Zig refuses two steps of one name.
- **`sync` is otherwise unchanged:** under `-Ddist` it moves the siblings at
  `../x` to their refs, as before.
- **Fetches prune:** a branch deleted on the remote is dropped from a
  checkout's `origin/…` refs, so it is reported gone rather than built stale.
  Local branches and tags are never removed.
- **`zigbuildx-pin` moves a pre-release pin** (`v5.2.0-rc1`) to the newest
  release once one is newer, and refuses to run while a distribution build
  has `build.zig.zon` rewritten (run `zig build dev` first).

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
