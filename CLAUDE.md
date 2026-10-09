# CLAUDE.md

Guidance for Claude Code in this repository.

## Project

zigbuildx is a library of Zig build system extensions: logic that `std.Build`
lacks, imported from other projects' `build.zig` instead of being copied into
each one. `README.md` covers setup and usage; how each extension works, and
the workarounds behind them, are below.

- **Zig 0.17.0 only.** `build.zig` has a `comptime` guard that refuses any
  Zig outside 0.17 (it does not check the patch). Several extensions work
  around Zig 0.17.0 defects; see *Workarounds*. Version 1.x was the Zig 0.16
  release; 2.0.0 dropped 0.16; 3.0.0 made `Xcode` and `Android` take the
  build graph at `init`; 3.2.0 made `Deps` clone a sibling's own siblings.
- **The public surface is `build.zig`.** Consumers import this package's
  `build.zig` by dependency name, so only what it re-exports (`Deps`, `Git`,
  `Xcode`, `Swift`, `Android`, `AndroidAbi`, `Apk`, `Docs`, `Pkg`) is
  reachable. It also declares the host tool, so it has a `build()`.
  `src/module.zig` is the barrel for tests.
- **It runs on every host.** The code executes inside other projects' build
  runners on macOS, Linux and Windows. Host-specific behaviour is a runtime
  branch on `b.graph.host`, so a Windows-only mistake compiles fine on macOS.
  `make cross` catches it.
- **No dependencies.** `build.zig.zon` `.dependencies` stays empty.

## Commands

- **`ZIG`:** the Makefile runs `$(ZIG)`, default `zig`, which is 0.17 on
  this machine.
- `make`: format and test.
- One test: `zig build test -Dtest-filter=<substring>`.
- `make validate`: **the gate**. It runs clean, format, lint, test and cross,
  and must pass before a change is done. `zlint` and `zlintpre` exit 0 even
  when they find something, so read the whole output rather than trusting the
  exit code.
- `make cross`: compiles the test suite and the host tool for x86_64 and
  aarch64 Windows and Linux, without running them.
- `make lint`: needs the `styleguide` submodule; run `make subpull` after a
  fresh clone.
- `make format` and `make lint` cover every `.zig` file under `src/`
  (`find src -name '*.zig'`), plus `build.zig`.

## Style

@styleguide/ZIGSTYLE.md

`styleguide/ZIGMIGRATE.md` maps deprecated APIs. Two deliberate departures
from ZIGSTYLE D.3.a:

- **No `@src()` entry tracing.** A consumer's build runner is compiled in
  Debug, where `log.debug` prints, so tracing would print on every build.
- **A scoped logger only in files that log.** `zlint` flags an unused one.

Beyond ZIGSTYLE:

- **Doc comments** on every function: a one-line summary, an optional
  rationale paragraph, then `Parameters:` bullets and a `Return:` line.
- **`// SAFETY:` comment** above every `undefined` field, saying what
  populates it before its first read.
- **One-line parameter lists.** `zlintpre` rejects a multi-line list.
- **Build and package are separate.** Code that compiles lives at the top of
  `src/` (`android.zig`); code that assembles an installable package lives
  under `src/pkg/` (`pkg/android/apk.zig`, `macos/`, `linux/`, `windows/`).
- **Sub-packages:** `src/pkg/` has its own `module.zig` barrel, reached as
  `mod.pkg`; its files import that barrel, and it passes through the parent
  types they need (`Git`, `HostTool`, `Android`). A folder with several
  `.zig` files gets its own barrel too (`pkg/android/`, reached as
  `mod.pkg.android`); a folder with one does not.
- **The host tool** (`src/tool.zig`): one program, `zigbuildx <command>`,
  that does every job a step must do while the build runs. A Zig 0.17 step
  cannot run code of its own (`Step` has a closed set of tags and no
  `makeFn`), and a program also avoids shell tools that differ between
  platforms (`sed -i`, `zip`). Each command is a `command(process_init, args)`
  method on the struct it serves (`ApkZip`, `Deb`, `Deps`, `Docs`, `Pkg`),
  with `args[0]` the command's name; `Tool.dispatch` maps names to them. Name
  the `std.process.Init` parameter `process_init`, since `init` shadows the
  struct's `init`.
- **Reaching the host tool:** `build.zig` installs it as the artifact
  `zigbuildx`, and `HostTool.add(b)` finds this zigbuildx among the build
  runner's packages by type identity (its `build.zig`'s `Deps` is this
  `Deps`), then calls `dependencyFromBuildZig(...).artifact("zigbuildx")`.
  So the consumer may name the dependency anything, and two zigbuildx
  versions in one build each use their own tool.

## Gotchas

- **`.paths`:** it must list `build.zig` and `build.zig.zon`. Without them a
  fetched copy has no `build.zig`, and consumers fail with "no module named
  'zigbuildx'".
- **Tests and error logs:** the test runner fails any test that logs at error
  level, so test a failure path through a function that returns the error and
  let its caller log it (see `Android.resolveFrom` and `Android.resolve`).
- **Configure is cached (Zig 0.17).** `build()` runs in a separate
  configurer process, and Zig skips it when nothing it tracks changed: the
  `-D` options, the build scripts and manifests, and files named with
  `b.dependOn*`. Anything else `build()` observes (environment, `xcrun`,
  directory listings, git state) must be declared: `b.dependOnFileMetadata`
  and friends where a path captures it, else `b.graph.poisonCache()`, which
  makes every build configure again. `Xcode.resolve` depends on the SDK's
  `SDKSettings.json`; `Android.resolve`, `Deps.sync` (while worktrees exist)
  and `Pkg` for Windows (`b.findProgram`) poison.
- **No concrete paths at configure time.** `b.cache_root`,
  `b.getInstallPath`, `b.pathFromRoot` and `LazyPath.getPath*` are gone; the
  package root is `b.root` (a `Cache.Path`), and cache and install paths
  exist only when a step runs. Work that needs them belongs in the host tool.
- **`Deps` and the re-run.** `Deps` runs for the root package only (see
  `isPresent`), and its exit-and-re-run is required: a dependency cloned
  mid-`build()` resolves, but its own `build()` never runs.
- **Run steps hash a directory argument's path, not its contents.** A
  directory whose path never changes needs `has_side_effects` (the `pkg`
  run) or each file added with `addFileInput` (`Apk`'s `res/`, whose walk
  also registers each directory with `dependOnDirectoryContents`).
- **Deprecated in 0.17, and not to be used:** `Run.add*Arg` without `2`
  (`addOutputFileArg2`, `addDirectoryArg2`, ...), `Compile.out_filename`
  (`std.zig.binNameAlloc`, or the artifact's name), `LazyPath.cwd_relative`
  (`b.graph.cwdRelativePath`), `std.fs.path` (`std.Io.Dir.path`, with
  `resolveAlloc` and `relativeAlloc`), `std.fmt.allocPrint`
  (`allocator.print`), `std.mem.indexOf*` (`std.mem.find*`), `std.builtin`
  (`std.lang`). See `styleguide/ZIGMIGRATE.md`.
- **A `.path` dependency is a compile error while missing.** So zigbuildx
  itself must be a `.url` + `.hash` dependency, and a top-level `@import` of
  a missing dependency's `build.zig` must be guarded with `Deps.isPresent`.

## Extension internals

- **`Deps.cloneMissing`:** clones every root `.path` dependency that has a
  `.clone` and is absent, then exits 1 for a re-run; it compiles away when
  nothing is missing.
  - **Siblings of siblings:** an unpinned `.path` outside `deps/` declared by
    a sibling (`../tui` naming `../vaxis`) is cloned from the `.clone` in that
    sibling's manifest, and its manifest is followed in turn (each path once,
    so a cycle ends). Zig opens every `.path` package before the sibling's
    own `build()` could clone it, and `Deps` runs for the root only. A
    sibling's pinned dependencies belong to its own `deps/` and are skipped.
  - **Detection:** `missingSibling` scans the runner's whole package table for
    a `.path` package (keyed by its path, which equals its `build_root`; a
    fetched one is keyed by hash) outside `deps/` with no `build_zig`, so the
    call still compiles away in the steady state.
- **`Deps.sync`:** the successor, and it must come first in `build()`.
  - **Pins:** `.sha` and `.tag` give a detached worktree; `.branch` gives the
    branch `<consumer>/<branch>`, created at `origin/<branch>`. `<consumer>`
    is the root's `.name`. More than one pin, or a pin on a `.path` outside
    `deps/`, is an error. An unpinned `.path` is used as is, wherever it
    points, cloned from `.clone` when absent: under `deps/` by the root only,
    outside it by any sibling, as `cloneMissing` does.
  - **Create and move:** a missing worktree is created from its checkout,
    which is cloned if absent and fetched (`--tags --force`) if it lacks the
    revision. A changed pin moves a clean worktree; one with uncommitted
    changes or commits beyond its stamp stops the build. Anything cloned,
    created or moved exits 1 for a re-run.
  - **Steady state:** compares the manifests with `deps/.zigbuildx/*.rev`
    stamps and runs no `git`.
  - **Transitive:** each worktree's own manifest is read in the same pass. A
    sibling path (`../x` from `deps/mid`) resolves to the consumer's
    `deps/x`, so Zig sees one copy; the first declaration of a path wins,
    the root's first. A dependency that itself uses `deps/` gets nested
    worktrees on branches prefixed `<consumer>/<dep>/`.
  - **Orphans:** a worktree no manifest claims is removed with its branch
    when clean and not ahead; otherwise kept and listed. A worktree deleted
    by hand is recreated, reusing any branch it left.
  - **`zig build deps`** lists the worktrees; `-Dupdate` fetches checkouts
    behind branch and tag pins, fast-forwards branch pins (skipping any with
    work of their own, and failing at the end), and lets `status` report a
    tag moved upstream.
  - **Return type:** `noreturn` while a `deps/` package is missing from the
    runner's table, so code after the call is not compiled; that lets a
    transitive top-level `@import` wait. A worktree dependency must have a
    `build.zig`, since Zig cannot tell one without from a missing one.
  - **0.17:** the configurer still runs with a `.path` dependency missing,
    and its `@import("root").dependencies` table still reports it. Its
    `exit(1)` shows as `error: configure command exited with code 1`. `sync`
    poisons the configure cache while worktrees or orphans exist; a root with
    only unpinned dependencies keeps the cache. The `deps` step runs the host
    tool's `deps` command, which reads the manifests again (no `git` in the
    steady state) before `status` and `update`.
- **`Git`:** one thin wrapper per command, given the directory git runs in;
  no manifest knowledge. `Deps` owns the policy.
- **`Xcode`:**
  - `standardTargetOptions` adds `-Dmacos-min` on a macOS host; `-Dtarget`
    overrides it, carrying its own floor (`aarch64-macos.26.0`).
  - `init(b)` keeps the build graph and takes its allocator and io from it;
    the unit tests, which have no graph, use the private `initWith`.
  - `resolve()` asks `xcrun` for the Apple Silicon SDK and is idempotent.
    `xcrun` names a versioned path (`MacOSX27.0.sdk`), so it makes the SDK's
    `SDKSettings.json` a configure input; an Xcode update removes the path.
  - `linkFramework` adds the SDK's `System/Library/Frameworks`, which a
    floored (non-native) target otherwise never searches.
- **`Swift.addDylib`:** an `@rpath` install name; every source and the
  bridging header as file arguments, so edits rebuild it; two rpaths, the
  build cache (for tests) and `@executable_path/../lib` (added as a special
  rpath, since normalising collapses it); `-target` from the Zig target. It
  returns null off macOS. `fromDependency` finds a dependency's dylib.
- **`Android`:** `init(b)` keeps the build graph, as `Xcode` does, so
  `resolve()` and `configure(lib)` take no `b`. `resolve` takes the SDK from `ANDROID_HOME`,
  `ANDROID_SDK_ROOT` or Android Studio's default; the NDK from
  `ANDROID_NDK_HOME`, `ANDROID_NDK_ROOT` or the newest under the SDK; the
  newest build-tools and platform; and the host's NDK prebuilt. `resolve`
  poisons the configure cache (it reads the environment). `configure` adds a
  libc file and 16 KB pages. Zig 0.17's libc file needs every field, including
  `darwin_sdk_dir`, and takes a Linux target's `crtbegin`/`crtend` from
  `cc_dir`, which is the NDK's per-API library directory, like `crt_dir`; a
  test parses the file with `std.zig.LibCInstallation.parse`. Windows tools are `aapt2.exe`,
  `zipalign.exe`, `apksigner.bat`; `keytool` comes from `JAVA_HOME` or `PATH`.
- **`Apk.add`:** `aapt2 compile` and `link`, then the host tool's `apk-zip` adds each library
  under `lib/<abi>/` stored (Android maps them from the APK), `zipalign -P 16`
  and `apksigner`. Without a keystore it signs with Android Studio's debug
  keystore, else one generated into the cache.
- **`Docs.includePrivate`:** the host tool's `docs-patch` copies the autodoc
  site and flips the two `include_private` call sites in `main.js`; each
  pattern must occur once, so a changed front end fails the build.
- **`Pkg`:**
  - **Identity:** `.bundle` is the bundle id and the package id as written, and
    must be three labels, `<domain>.<org>.<name>`; paths and the package's file
    name use its second and last labels. The project's `.name` is not read, and
    each program keeps its executable's name. Three exactly, because
    `uninstall.sh` removes `/usr/local/<org>/<name>`: `com.example` alone would
    make that the whole organisation's directory.
  - **Scripts:** macOS `preinstall`, `postinstall`, `uninstall.sh` and Linux
    `preinst`, `postrm`, `profile.sh`, embedded and filled with `{pkg_name}`,
    `{pkg_id}`, `{pkg_org}`; `PkgOptions.scripts` overrides them by name.
    The macOS scripts come from `~/src/inferise/pkg/zlintpre`, with one fix
    (`postinstall` tested `-d` on a file). The preinstall that runs the old
    `uninstall.sh`, wiping `/etc/<org>/<name>` on upgrade, is intended.
  - **Steps:** `Pkg.add` declares; `PkgRun` (the host tool's `pkg`
    command) stages and builds the macOS and Linux packages beside the Run
    step's output, from `--key=value` options and the programs after `--`,
    and deletes the stage. A problem (`.bundle` missing, mixed targets) becomes
    a `Fail` step behind `zig build pkg`. `pkg-notarize` notarizes a copy of
    the package and installs it over the plain one.
  - **macOS:** `Pkgbuild` signs each executable with `Developer ID
    Application` (hardened runtime, timestamp) and the `.pkg` with
    `Developer ID Installer`; `pkg-notarize` runs `notarytool --wait`
    (password visible in `ps` while it runs) and `stapler`.
  - **Linux:** the `deb` host tool writes the archive; entries are root-owned
    and dated 0. Unsigned; signing belongs to the apt repository.
  - **Windows:** `Msi` renders WiX for `wixl` while the graph is declared:
    per-user under `%LOCALAPPDATA%`, the user `PATH`, GUIDs derived from the
    id. A `WriteFiles` step stages `bin/` and `product.wxs`, and `wixl` runs
    in it. `wixl` has no arm64 platform, so arm64 ships in an x86 installer.
    Without `wixl`, the stage is installed to
    `zig-out/pkg/<name>-<version>-wix/` and the step fails with the command to
    finish it.

## Workarounds

Four remain, because of Zig 0.17.0 or the macOS 27 SDK. Each can be deleted
on its own when the cause goes away; a release for a later Zig starts by
re-checking every one.

- **A floor loses the SDK's frameworks (`Xcode.linkFramework`).** Any
  `os_version_min` makes the target non-native, and Zig then searches no SDK
  framework directory ("searched paths: none"); `--sysroot` does not help.
  Remove when a floored target finds frameworks with plain `linkFramework`.
- **Artifacts stamped with the host's macOS (`Xcode.standardTargetOptions`).**
  A native build on macOS 27 is stamped 27.0, so older consumers' linkers warn
  "built for newer 'macOS' version" and Swift shims see 27-only deprecations.
  Never removed on its own: it is how a deployment target is stated.
- **No Android C library (`Android.configure`).** Zig 0.17.0 ships no bionic;
  a libc file points at the NDK sysroot. Remove when Zig ships it.
- **Autodoc hides private declarations (`Docs.includePrivate`).** The front
  end passes `include_private = false` at two call sites. Remove when `zig
  build docs` gains an option, or at once if the patch reports a change.

Removed in 2.0.0, both checked on 0.17.0 before removal: `Archive`, since Zig
now 8-byte-aligns archive members (a 0.16 archive of seven objects had three
misaligned, a 0.17 one none); and `Xcode.linkLibCpp`, since a C++20
`std::uniform_real_distribution` program links with plain `link_libcpp` on
SDK 27, native and floored at 26.0.

## Verifying

Unit tests cannot cover how the build graph is wired. Use a scratch consumer
package outside this repo:

```sh
zig17 fetch --save=zigbuildx ../zigbuildx   # from the scratch package; local url + hash
```

Re-run that fetch after every change to zigbuildx, because the hash pins the
contents.

- **Android without an SDK** (none is installed, and none should be): point
  `ANDROID_HOME` at a fake tree holding `build-tools/<v>/{aapt2,zipalign,apksigner}`
  stand-in scripts that log their argv, `platforms/android-N/android.jar`, and
  `ndk/<v>/toolchains/llvm/prebuilt/<host>/sysroot`. Point `JAVA_HOME` at a
  directory whose `bin/keytool` is a stand-in. Build the `.so` without libc;
  linking libc needs the real NDK, so check `configure` from the failing link
  command instead, which shows `--libc` and `-z max-page-size=16384`.
- **Linux:** run it in podman with Debian, installing `xz-utils curl git` and
  extracting `https://ziglang.org/download/0.17.0/zig-aarch64-linux-0.17.0.tar.xz`
  into `/opt`. One test is skipped there by design: the `xcrun` SDK lookup.
  `zig build pkg` in a scratch consumer there gives a `.deb` that `dpkg -i`
  installs.
- **Windows:** compile only, via `make cross`. Nothing here runs Windows
  binaries.
- **Configure caching:** run `zig build` twice; the second skips `build()`.
  A `std.debug.print` in the scratch `build.zig` shows whether it ran.

## Adopters

Every Zig project under `~/src/inferise` and `~/src/mlavergn` that lists
zigbuildx (about 27) pins `git+https://github.com/mlavergn/zigbuildx#v3.0.0`
with its `.hash`. Their Zig 0.17 ports are uncommitted. Nearly all use
`Xcode` and `Deps.cloneMissing`; beyond that:

| Repo | Uses |
|---|---|
| zigclaude | `Deps.sync` (all dependencies unpinned) |
| zigstorage | `Xcode` floor 26.0 and `linkFramework`, `Docs` |
| zigwebrtc, dropbox | `Xcode` floor |
| zigafm | `Xcode` floor 26.0, `Swift` |
| zigagent | `Swift.fromDependency` (zigafm's dylib) |
| zlintpre | `Pkg` |

- **Version bumps:** bump `.version` on any change, push the tag, then in each
  adopter run `zig fetch --save-exact=zigbuildx
  git+https://github.com/mlavergn/zigbuildx#v<x.y.z>`, which keeps the tag in
  the URL. Before the tag is pushed, `zig fetch .` from this repo puts the
  same hash in the global cache, so adopters build against it locally.
- **From 2.0.0 to 3.0.0:** `Xcode.init(b.allocator, b.graph.io)` becomes
  `Xcode.init(b)` and `resolve(b)` becomes `resolve()`; `Android` likewise,
  with `configure(b, lib)` becoming `configure(lib)`.
- **From 1.x (Zig 0.16):** `Archive.install(b, lib)` becomes
  `b.installArtifact(lib)`, `Archive.addInstall(b, lib)` becomes
  `&b.addInstallArtifact(lib, .{}).step`, plus the project's own port
  (`ZIGMIGRATE.md`'s 0.16-to-0.17 section).

## Deferred

- **ADB over TCP install step:** about 1,000–1,300 lines with tests.
  - **Reuse:** zigunoq's `src/protocol.zig` and `src/adb.zig` (push and shell)
    port over, swapping its USB transport for `std.Io.net`.
  - **New:** RSA authentication.
    - **Key loading:** read the PKCS#8 `~/.android/adbkey`.
    - **Signing:** sign the 20-byte token with PKCS#1 v1.5 and a SHA-1
      DigestInfo, using `std.crypto.ff` (std can only verify RSA).
    - **Public key:** Android's custom format (`n0inv`, R² mod n) for the
      first-time prompt.
  - **Out of scope:** Android 11+ TLS pairing and USB. Key generation when no
    `adbkey` exists, which needs a decision.
  - **No test device here**, so real `adbd` compatibility goes unverified;
    test against a loopback fake device.
  - **Open:** is there a test device, how to handle a missing key, and
    whether it lives here or in its own package shared with zigunoq.
- **zigandroidtv** (`~/src/mlavergn/zigandroidtv`): convert its Makefile to a
  `build.zig` using `Android`, giving that extension a real user. Its Makefile
  currently references `src/main.zig`, but the file is at the root.
- **zigagent:** adopt `Xcode.standardTargetOptions(b, "26.0")`. Without a
  floor, the `libafm.dylib` it builds through zigafm is stamped macOS 27.0, and
  `swiftc` warns about an API deprecated in 27.
- **llama.cpp.zmake** (`~/src/mlavergn/llamazig`) could drop its Apple
  libc++ workaround once on Zig 0.17, where plain `link_libcpp` links on SDK
  27. The C++ runtime then changes from Apple's dylib to Zig's static libc++.
  The owner's call.
- **Other repos** could adopt `Docs.includePrivate`, a one-line change on each
  docs install step.
- **zigstorage's `make lint`** walks `zig-pkg/`. Give it an explicit file list,
  as zigclaude does.
