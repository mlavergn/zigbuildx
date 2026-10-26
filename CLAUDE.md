# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

zigbuildx is a library of Zig build system extensions: logic `std.Build` lacks,
imported from other projects' `build.zig` instead of copied into each one.
`README.md` covers setup and usage.

- **Zig 0.17.0 only.** A `comptime` guard in `build.zig` refuses any other
  minor release. Several extensions work around 0.17.0 defects (see
  *Workarounds*).
- **It runs on every host.** The code executes inside other projects' build
  runners on macOS, Linux and Windows. Host-specific behaviour is a runtime
  branch on `b.graph.host`, so a Windows-only mistake compiles on macOS;
  `make cross` catches it.
- **No dependencies.** `build.zig.zon` `.dependencies` stays empty.
- **No packaging.** Building a `.pkg`, `.deb`, `.msi` or `.apk` is out of
  scope; 4.0.0 removed `Pkg` and `Apk`.
- **It is a base module.** Never name a project that depends on zigbuildx,
  in code, docs or examples: zigbuildx knows nothing about its consumers.
  Use generic names (`../mylib`, `../a`) in examples.

## Build / Test

- `make`: format and test. `ZIG` (default `zig`, 0.17 here) is the compiler.
- `zig build test -Dtest-filter=<substring>`: one test.
- `make validate`: **the gate**, which must pass before a change is done:
  clean, format, lint, build, test, then `cross`. Any lint finding or
  warning fails it.
- `make cross`: compiles the suite and the host tool for x86_64 and aarch64
  Windows and Linux, without running them.
- `format`, `lint` and `validate` come from `../styleguide/Makefile.in`, so
  they need that sibling checkout. `make lint` runs `zlintpre`, then `zlint
  -c ../styleguide --deny-warnings`, over `build.zig` and `ZIG_DIRS`
  (default `src cli web`; only `src/` exists). Add new source roots to
  `ZIG_DIRS`.
- `make tag`: tags `v<.version>` and pushes it; `zigbuildx-pin` finds
  releases by that tag.

Unit tests cannot cover how the build graph is wired, and `refAllDecls` does
not analyze nested functions, so a typo in an unreferenced method compiles.
Check graph changes in a scratch consumer outside this repo, re-fetching
after every change (the hash pins the contents):

```sh
zig fetch --save=zigbuildx ../zigbuildx   # from the scratch package
```

- **Android:** no SDK is installed, and none should be. Point `ANDROID_HOME`
  at a fake tree holding `ndk/<v>/toolchains/llvm/prebuilt/<host>/sysroot`;
  linking libc needs the real NDK, so check `configure` from the failing
  link command (`--libc`, `-z max-page-size=16384`).
- **Linux:** podman with Debian (`xz-utils curl git`) and Zig 0.17.0's
  aarch64-linux tarball in `/opt`. The `xcrun` tests skip there.
- **Windows:** compile only, through `make cross`.
- **Configure caching:** run `zig build` twice; the second skips `build()`
  (a `std.debug.print` in the scratch `build.zig` shows whether it ran).

## Module layout

```
build.zig              the public surface: re-exports Deps, Git, Xcode, Swift,
                       Android, AndroidAbi and Docs; installs the host tool
src/module.zig         the barrel the tests compile
src/deps.zig           Deps (clone, sync, update, guard, pin) and its private Sync
src/git.zig            Git: one thin wrapper per git command
src/xcode.zig          Xcode: Apple SDKs, the macOS floor, frameworks, xcframeworks
src/swift.zig          Swift: swiftc dylibs
src/android.zig        Android, AndroidAbi: the NDK
src/docs.zig           Docs: autodoc with private declarations
src/zip_archive.zig    ZipArchive: `.archive` download and unpack
src/file.zig           File: file-system primitives the others share
src/tool.zig           Tool: the host tool's main and command dispatch
src/tool_artifact.zig  ToolArtifact: finds the host tool for a consumer's build
src/zip_builder.zig    ZipBuilder: in-memory zips for the tests
```

Consumers import this package's `build.zig` by dependency name, so only what
it re-exports is reachable; `File`, `ZipArchive`, `ToolArtifact`, `Tool` and
`ZipBuilder` are internal. A new sub-folder with several `.zig` files gets
its own `module.zig` barrel.

## Architecture conventions

@../styleguide/ZIGSTYLE.md

`../styleguide/ZIGMIGRATE.md` maps deprecated APIs. Departures from and
additions to ZIGSTYLE:

- **No `@src()` entry tracing** (D.3.a): a consumer's build runner is Debug,
  where `log.debug` prints on every build.
- **A scoped logger only in files that log**: `zlint` flags an unused one.
- **Fixed limits are named constants** (A.1.b): there is no `Config` inside
  another project's `build()`, so read caps (`Manifest.max_bytes`) and
  `curl`'s `ZipArchive.connect_timeout_seconds` are constants on their
  struct, never bare numbers. A value a consumer must choose is a `-D`
  option.
- **Doc comments** on every function say what it does, never how: a
  one-line summary (plus at most one line a caller must know, such as "Call
  it first in `build()`"), a one-line `Parameters:` bullet per parameter in
  signature order, and a one-line `Return:` (omitted for plain `void`). Why a
  line does something non-obvious, such as a Zig 0.17 workaround, is a `//`
  comment on that line.
- **`// SAFETY:`** above every `undefined` field, saying what populates it.
- **One-line parameter lists**: `zlintpre` rejects multi-line ones.
- **Use `Run`'s `…Arg2` forms throughout.** Every path-argument method
  without `2` is deprecated in 0.17 except `addFileArg`, a plain wrapper of
  `addFileArg2`; `addFileArg2` is used too, so there is one form.
- **Never use, deprecated in 0.17:**
  `Compile.out_filename` (`std.zig.binNameAlloc`), `LazyPath.cwd_relative`
  (`b.graph.cwdRelativePath`), `std.fs.path` (`std.Io.Dir.path`),
  `std.fmt.allocPrint` (`allocator.print`), `std.mem.indexOf*`
  (`std.mem.find*`), `std.builtin` (`std.lang`). Optimize modes are
  `.debug`, `.safe`, `.fast`, `.small`.
- **Declare what `build()` observes.** Zig 0.17 skips `build()` when nothing
  it tracks changed (`-D` options, build scripts, manifests, `b.dependOn*`
  paths). Declare anything else: `b.dependOnFileMetadata` and friends where
  a path captures it, else `b.graph.poisonCache()`. `Xcode.resolveFor`
  tracks `SDKSettings.json`; `Deps` tracks `.zig-cache/zigbuildx/`;
  `Android.resolve`, `Deps.sync` with worktrees, and `-Dupdate` poison.
- **Work at build time goes in the host tool.** A Zig 0.17 step cannot run
  code of its own, and cache and install paths exist only when steps run.
  `src/tool.zig` is one program, `zigbuildx <command>`; each command is a
  `command(process_init, args)` method on the struct it serves (`args[0]` is
  its name), listed in `Tool.commands`. Name the parameter `process_init`.
  `ToolArtifact.add(b)` finds this zigbuildx among the runner's packages by
  type identity (its `build.zig`'s `Deps` is this `Deps`), so a consumer may
  name the dependency anything.
- **Generic helpers stay generic.** `Git` and `File` know nothing about
  manifests, stamps or archives; `Deps` and `ZipArchive` own the policy.

### How the extensions work

- **`Deps.cloneMissing`:** clones each absent root `.path` dependency with a
  `.clone`, then exits 1 for a re-run: a dependency cloned mid-`build()`
  resolves, but its own `build()` never runs. It also follows siblings of
  siblings (`../a` naming `../b`, from the sibling's manifest, each path
  once), since Zig opens every `.path` package before a sibling's `build()`
  could clone it. It runs for the root only. `missingSibling` scans the
  runner's package table (a `.path` package's key is its path) for one
  outside `deps/` with no `build_zig`, so the clone path compiles away in
  the steady state. A lock, `<root>/.zig-cache/zigbuildx.lock`, is held from
  before the first clone.
- **`.archive` (`ZipArchive`):** a zip unpacked at a `.path` wherever a
  `.clone` would be cloned. It is downloaded (`curl`; `file://` in process)
  into `<path>.zigbuildx-unpack/`, extracted, stripped of a single top-level
  folder, and renamed into place; the old directory waits in staging until
  the new one is in. It needs no re-run, since no Zig code imports it, so
  `missingSibling` and `missingWorktree` skip the root's archive paths. A stub
  `build.zig` marks it present in the runner's table. `.zigbuildx-archive`
  stamps the URL: a new URL replaces the directory, and a directory without
  the stamp is refused. It cannot be pinned, is never updated, and is not
  hash-checked.
- **`Deps.sync`:** must come first in `build()`. `.sha` or `.tag` gives a
  detached worktree under `deps/`; `.branch` gives the branch
  `<consumer>/<branch>`. A worktree is created from its checkout (`.checkout`,
  default `../<name>`), cloned or fetched as needed; a changed pin moves a
  clean worktree, and one with work of its own stops the build. Anything
  cloned, created or moved exits 1. The steady state compares manifests with
  `deps/.zigbuildx/*.rev` stamps and runs no `git`. Each worktree's manifest
  is read in the same pass; a `../x` from `deps/mid` resolves to the root's
  `deps/x`, and the first declaration of a path wins. An unclaimed worktree
  is removed when clean, else kept and listed. The return type is `noreturn`
  while a `deps/` package is missing, so a transitive top-level `@import` can
  wait; a worktree dependency must have a `build.zig`.
- **`-Dupdate`:** fetches and fast-forwards siblings (skipping, with a
  warning, any that is dirty or ahead; never failing the build) and, under
  `sync`, branch worktrees (one it must skip fails the build). Anything moved
  exits 1.
- **`Deps.guard`:** called last. It makes the default step wait for
  `deps-mark clear`, which runs after every `Compile` the default step
  reaches, while `deps-mark set` runs unordered. A compile error therefore
  leaves `<root>/.zig-cache/zigbuildx/update`, a configure input, and the
  next build updates as `-Dupdate` would and deletes it. Steps outside the
  default step, and compile errors in `build.zig`, are not covered.
- **`zigbuildx-pin` (`Deps.pin`, `make buildxpin` in `Makefile.in`):**
  declared by `cloneMissing` and `sync`. It reads this zigbuildx's `.url`
  (named by `ToolArtifact.dependencyName`) and runs `zig fetch` in the root,
  keeping the URL's form (`?ref=<ref>#<commit>` with `--save`, `#<ref>` with
  `--save-exact`). A branch pin (`#main`) is refreshed on its branch, never
  swapped for a tag. Otherwise it takes the newest `vX.Y.Z` from `git
  ls-remote --tags` (an annotated tag's commit from its `^{}` line, so no
  `--refs`) and re-pins when the tag or its commit differs, as after a
  history rewrite. A pin newer than every tag is left alone.
- **`Xcode`:** `initFor(b, target)` resolves the SDK of the target's own
  platform on a Mac (`darwin.getSdk` maps every Apple OS and the simulator
  ABI) and does nothing for a non-Apple target, so callers need no checks;
  one handle serves one platform. `linkFramework` adds the SDK's
  `System/Library/Frameworks` and `usr/lib`, which a non-native target never
  searches; `usr/lib` holds what framework stubs name by install name
  (CoreFoundation's `libobjc.A`). `configure(lib)` adds the libc file and
  trapping sanitizers for Apple's other platforms. `addXcframework` groups
  libraries by platform (`ios` vs `ios-simulator`), joins a platform's
  architectures with `lipo`, and runs `xcodebuild -create-xcframework` with
  `-output` inside the step's own directory (`suffix`), since `xcodebuild`
  refuses an existing output; headers are copied through a `WriteFile` first,
  so an edit changes their path and rebuilds. Static libraries work on stock
  0.17.0 for every slice; a dynamic simulator library does not link there.
  Bundling a dynamic framework (`Info.plist`, dSYMs) is out of scope.
  `standardTargetOptions`
  adds `-Dmacos-min` on a macOS host.
- **`Swift.addDylib`:** an `@rpath` install name; sources and bridging header
  as file arguments, so edits rebuild; rpaths for the build cache and
  `@executable_path/../lib` (a special rpath, since a path would be
  normalized); `-target` from the Zig target. Null off macOS.
- **`Android`:** the SDK from `ANDROID_HOME`, `ANDROID_SDK_ROOT` or Android
  Studio's default, the NDK from `ANDROID_NDK_HOME`, `ANDROID_NDK_ROOT` or
  the newest under the SDK. `configure` adds a libc file and 16 KB pages;
  Zig 0.17's libc file needs every field, and takes `crtbegin`/`crtend` from
  `cc_dir`, the NDK's per-API directory like `crt_dir`.
- **`Docs.includePrivate`:** the host tool's `docs-patch` copies the autodoc
  site and flips the two `include_private` call sites in `main.js`; each
  pattern must occur once, so a changed front end fails the build.

## Project-state heads-ups

- **`.paths` must list `build.zig` and `build.zig.zon`,** or a fetched copy
  has no `build.zig` and consumers fail with "no module named 'zigbuildx'".
- **A test that logs at error level fails.** Test a failure path through a
  function that returns the error (or a message, as `Android.describeFailure`
  does) and let its caller log.
- **A tracked path must exist.** `dependOnFileMetadata` on a missing file
  fails configuration with `FileSystemFailure`; track a directory that always
  exists (create it in `build()`).
- **No concrete paths at configure time.** `b.cache_root`,
  `b.getInstallPath`, `b.pathFromRoot` and `LazyPath.getPath*` are gone; the
  package root is `b.root`.
- **Run steps hash a directory argument's path, not its contents.** Give such
  a step `has_side_effects`, or add each file with `addFileInput`.
- **A `.path` dependency is a compile error while missing.** zigbuildx itself
  must be a `.url` + `.hash` dependency, and a top-level `@import` of a
  missing dependency's `build.zig` needs `Deps.isPresent`.
- **Name siblings `../x`, not `deps/x`.** A `.path` resolves as text, and its
  path is its identity: `../x` from any depth is one package, while `deps/x`
  under each declarer is a separate one, even through links to one checkout
  (`expected type 'root.T', found 'root.T'`).
- **Bump `.version` on any change.** Release: push `main`, then `make tag`;
  a consumer on 4.1.0 or later moves to it with `zig build zigbuildx-pin`.
  Before the push, `zig fetch .` here puts the same hash in the global cache
  for local builds. Consumers pin a tag with its commit (`?ref=v4.1.0#<commit>`),
  so a release that rewrites history breaks their URLs.
- **Compatibility:** 4.1.0 needs no consumer change, though an iOS, tvOS,
  visionOS or watchOS target must call `xcode.configure(lib)`. 4.0.0 removed
  `Pkg` and `Apk`.

### Workarounds

Seven remain, each deletable on its own when its cause goes away; a release
for a later Zig starts by re-checking every one.

- **A floor loses the SDK's frameworks (`Xcode.linkFramework`).** Any
  `os_version_min` makes the target non-native, and Zig then searches neither
  the SDK's frameworks nor its `usr/lib`; `--sysroot` does not help.
- **Artifacts stamped with the host's macOS (`Xcode.standardTargetOptions`).**
  A native build on macOS 27 is stamped 27.0, so older linkers warn. Never
  removed: it is how a deployment target is stated.
- **No C library for Apple's other platforms (`Xcode.configure`).** Zig 0.17.0
  finds an SDK only for macOS and ignores `--sysroot` there; a libc file names
  the SDK (`../zig17` fix 2).
- **No C sanitizer runtime for Apple's other platforms (`Xcode.configure`).**
  The UBSan runtime is Zig code that 0.17.0 cannot compile for them, so
  `sanitize_c = .trap` is set when the build chose no mode (`../zig17`
  fix 1).
- **No Android C library (`Android.configure`).** Zig ships no bionic; a libc
  file points at the NDK sysroot.
- **No TLS in `build()` (`ZipArchive.download`).** The configurer is compiled
  with `http_disable_tls`, so `std.http` cannot fetch `https://`; `curl` does.
- **Autodoc hides private declarations (`Docs.includePrivate`).** The front
  end passes `include_private = false` at two call sites.

Not worked around: a simulator executable fails in Zig's linker
(`SDKSettings.json`'s "Simulator - X.Y", `../zig17` fix 3), and Zig code that
reaches `std.debug.print` does not compile for Apple's other platforms.

## Not yet implemented

- **ADB over TCP install step** (about 1,000–1,300 lines): the ADB protocol
  (push and shell) on `std.Io.net`, plus RSA signing of the auth token with
  `~/.android/adbkey` (`std.crypto.ff`; std can only verify RSA). Open: a
  test device, a missing key, and whether it belongs in its own package.
- **Rejected:** sibling pins (`.sha`/`.tag`/`.branch` on a `../x`) as
  checks; and a `--fork` per sibling, since Zig reads `--fork` only from the
  command line and matches only hashed packages.
