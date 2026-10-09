# CLAUDE.md

Guidance for Claude Code in this repository.

## Project

zigbuildx is a library of Zig build system extensions: logic that `std.Build`
lacks, imported from other projects' `build.zig` instead of being copied into
each one. `README.md` covers setup and usage; how each extension works, and
the workarounds behind them, are below.

- **Zig 0.16.0 only.** `build.zig` has a `comptime` guard that refuses any
  Zig outside 0.16 (it does not check the patch). Several extensions work
  around Zig 0.16.0 defects; see *Workarounds*.
- **The public surface is `build.zig`.** Consumers import this package's
  `build.zig` by dependency name, so only what it re-exports (`Deps`, `Git`,
  `Xcode`, `Archive`, `Swift`, `Android`, `AndroidAbi`, `Apk`, `Docs`, `Pkg`)
  is reachable.
  `src/module.zig` is the barrel for tests.
- **It runs on every host.** The code executes inside other projects' build
  runners on macOS, Linux and Windows. Host-specific behaviour is a runtime
  branch on `b.graph.host`, so a Windows-only mistake compiles fine on macOS.
  `make cross` catches it.
- **No dependencies.** `build.zig.zon` `.dependencies` stays empty.

## Commands

- `make`: format and test.
- One test: `zig build test -Dtest-filter=<substring>`.
- `make validate`: **the gate**. It runs clean, format, lint, test and cross,
  and must pass before a change is done. `zlint` and `zlintpre` exit 0 even
  when they find something, so read the whole output rather than trusting the
  exit code.
- `make cross`: compiles the test suite and the host tools for x86_64 and
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
- **Host tools** (`docs.zig`, `pkg/android/apk_zip.zig`, `pkg/linux/deb.zig`):
  single-file programs that import only `std`. They are embedded with `@embedFile` and compiled for the
  host through `HostTool.add`, and they are the way to avoid shell tools that
  differ between platforms (`sed -i`, `zip`). Each also exposes a type that
  the tests exercise. `docs.zig` is also the `Docs` extension: Zig loads every
  `@import` eagerly, so it cannot import `module.zig` and compiles itself
  for the host instead of calling `HostTool.add`.

## Gotchas

- **`.paths`:** it must list `build.zig` and `build.zig.zon`. Without them a
  fetched copy has no `build.zig`, and consumers fail with "no module named
  'zigbuildx'".
- **Tests and error logs:** the test runner fails any test that logs at error
  level, so test a failure path through a function that returns the error and
  let its caller log it (see `Android.resolveFrom` and `Android.resolve`).
- **Paths needed at configure time.** `Xcode.linkLibCpp` writes its overlay
  into `b.cache_root` while the graph is declared, because the libc file must
  hold the overlay's absolute path. A `WriteFiles` output path is not known
  until it runs.
- **`Deps` and the re-run.** `Deps` runs for the root package only (see
  `isPresent`), and its exit-and-re-run is required: a dependency cloned
  mid-`build()` resolves, but its own `build()` never runs.
- **Run steps hash a directory argument's path, not its contents.** A
  directory whose path never changes needs `has_side_effects` (the `.deb`
  pack) or each file added with `addFileInput` (`Apk`'s `res/`).
- **A `.path` dependency is a compile error while missing.** So zigbuildx
  itself must be a `.url` + `.hash` dependency, and a top-level `@import` of
  a missing dependency's `build.zig` must be guarded with `Deps.isPresent`.

## Extension internals

- **`Deps.cloneMissing`:** clones every root `.path` dependency that has a
  `.clone` and is absent, then exits 1 for a re-run; it compiles away when
  nothing is missing.
- **`Deps.sync`:** the successor, and it must come first in `build()`.
  - **Pins:** `.sha` and `.tag` give a detached worktree; `.branch` gives the
    branch `<consumer>/<branch>`, created at `origin/<branch>`. `<consumer>`
    is the root's `.name`. More than one pin, or a pin on a `.path` outside
    `deps/`, is an error. An unpinned `.path` is used as is, wherever it
    points, cloned from `.clone` when absent (root only).
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
- **`Git`:** one thin wrapper per command, given the directory git runs in;
  no manifest knowledge. `Deps` owns the policy.
- **`Xcode`:**
  - `standardTargetOptions` adds `-Dmacos-min` on a macOS host; `-Dtarget`
    overrides it, carrying its own floor (`aarch64-macos.26.0`).
  - `resolve` asks `xcrun` for the Apple Silicon SDK and is idempotent.
  - `linkFramework` adds the SDK's `System/Library/Frameworks`, which a
    floored (non-native) target otherwise never searches.
  - `linkLibCpp` gives a macOS target a libc file whose include directory
    holds a guarded `<math.h>` overlay; a libc file is the only setting that
    reaches Zig's libc++ build. Elsewhere it is `link_libcpp` alone.
- **`Archive`:** `install`, `addInstall` and `repack` extract the members and
  re-archive them with `libtool`, and install headers as `installArtifact`
  does. Off Apple targets they install unchanged.
- **`Swift.addDylib`:** an `@rpath` install name; every source and the
  bridging header as file arguments, so edits rebuild it; two rpaths, the
  build cache (for tests) and `@executable_path/../lib` (added as a special
  rpath, since normalising collapses it); `-target` from the Zig target. It
  returns null off macOS. `fromDependency` finds a dependency's dylib.
- **`Android`:** `resolve` takes the SDK from `ANDROID_HOME`,
  `ANDROID_SDK_ROOT` or Android Studio's default; the NDK from
  `ANDROID_NDK_HOME`, `ANDROID_NDK_ROOT` or the newest under the SDK; the
  newest build-tools and platform; and the host's NDK prebuilt. `configure`
  adds a libc file and 16 KB pages. Windows tools are `aapt2.exe`,
  `zipalign.exe`, `apksigner.bat`; `keytool` comes from `JAVA_HOME` or `PATH`.
- **`Apk.add`:** `aapt2 compile` and `link`, then `apk-zip` adds each library
  under `lib/<abi>/` stored (Android maps them from the APK), `zipalign -P 16`
  and `apksigner`. Without a keystore it signs with Android Studio's debug
  keystore, else one generated into the cache.
- **`Docs.includePrivate`:** copies the autodoc site and flips the two
  `include_private` call sites in `main.js`; each pattern must occur once, so
  a changed front end fails the build.
- **`Pkg`:**
  - **Identity:** id `<org>.<name>`; paths use the last label of `.org`.
  - **Scripts:** macOS `preinstall`, `postinstall`, `uninstall.sh` and Linux
    `preinst`, `postrm`, `profile.sh`, embedded and filled with `{pkg_name}`,
    `{pkg_id}`, `{pkg_org}`; `PkgOptions.scripts` overrides them by name.
    The macOS scripts come from `~/src/inferise/pkg/zlintpre`, with one fix
    (`postinstall` tested `-d` on a file). The preinstall that runs the old
    `uninstall.sh`, wiping `/etc/<org>/<name>` on upgrade, is intended.
  - **macOS:** `Pkgbuild` signs each executable with `Developer ID
    Application` (hardened runtime, timestamp) and the `.pkg` with
    `Developer ID Installer`; `pkg-notarize` runs `notarytool --wait`
    (password visible in `ps` while it runs) and `stapler`.
  - **Linux:** the `deb` host tool writes the archive; entries are root-owned
    and dated 0. Unsigned; signing belongs to the apt repository.
  - **Windows:** `Msi` renders WiX for `wixl`: per-user under
    `%LOCALAPPDATA%`, the user `PATH`, GUIDs derived from the id. `wixl` has
    no arm64 platform, so arm64 ships in an x86 installer. Without `wixl`,
    the `.wxs` is written to `zig-out/pkg/` with the command to finish it.

## Workarounds

Six exist only because of Zig 0.16.0 or the macOS 27 SDK. Each can be deleted
on its own when the cause goes away; a release for a later Zig starts by
re-checking every one.

- **Misaligned archive members (`Archive`).** Zig 0.16.0 does not 8-byte-align
  members; Apple's `ld` skips a misaligned one ("64-bit mach-o not 8-byte
  aligned") and the link fails on missing symbols, coming and going as the
  library grows. `libtool -static -o out.a in.a` silently drops the member,
  hence the extraction. Remove when an installed archive's member offsets are
  aligned.
- **`INFINITY` undeclared in libc++ (`Xcode.linkLibCpp`).** On a macOS 27
  host every C++ link fails in Zig's libc++: Zig builds it as C++23, and SDK
  27's `<math.h>` leaves `INFINITY` and `NAN` to `<float.h>` from C++20 on,
  which Zig 0.16's clang does not supply. Remove when a C++20
  `std::uniform_real_distribution` program links with plain `link_libcpp`.
- **A floor loses the SDK's frameworks (`Xcode.linkFramework`).** Any
  `os_version_min` makes the target non-native, and Zig then searches no SDK
  framework directory ("searched paths: none"); `--sysroot` does not help.
  Remove when a floored target finds frameworks with plain `linkFramework`.
- **Artifacts stamped with the host's macOS (`Xcode.standardTargetOptions`).**
  A native build on macOS 27 is stamped 27.0, so older consumers' linkers warn
  "built for newer 'macOS' version" and Swift shims see 27-only deprecations.
  Never removed on its own: it is how a deployment target is stated.
- **No Android C library (`Android.configure`).** Zig 0.16.0 ships no bionic;
  a libc file points at the NDK sysroot. Remove when Zig ships it.
- **Autodoc hides private declarations (`Docs.includePrivate`).** The front
  end passes `include_private = false` at two call sites. Remove when `zig
  build docs` gains an option, or at once if the patch reports a change.

## Verifying

Unit tests cannot cover how the build graph is wired. Use a scratch consumer
package outside this repo:

```sh
zig fetch --save=zigbuildx ../zigbuildx   # from the scratch package; local url + hash
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
  extracting `https://ziglang.org/download/0.16.0/zig-aarch64-linux-0.16.0.tar.xz`
  into `/opt`. Two tests are skipped there by design: the `xcrun` SDK lookup
  and the `libtool` repack.
- **Windows:** compile only, via `make cross`. Nothing here runs Windows
  binaries.
- **The macOS 27 C++ failure:** a C++20 program using
  `std::uniform_real_distribution` reproduces it. It fails with plain
  `link_libcpp` and links with `xcode.linkLibCpp`.

## Adopters

All four reference zigbuildx with a local `.url = "../zigbuildx"` and
`.hash`. Nothing is committed in any of them.

| Repo | Uses |
|---|---|
| zigclaude | `Deps.sync` (all dependencies unpinned), `Xcode` |
| zigstorage | `Archive`, `Xcode` floor 26.0 and `linkFramework`, `Docs` |
| zigwebrtc | `Archive`, `Xcode` floor 26.0 |
| zigafm | `Deps`, `Xcode` floor 26.0, `Swift`, `Archive` |

- **Pins have diverged.** All four pin version `1.0.0`, but with different
  contents: zigclaude's includes `Deps.sync`, and zigstorage's is newer than
  the other two. Bump the version on a change, then re-fetch in each adopter
  that needs it.
- **After pushing**, change each adopter's `.url` to
  `git+https://github.com/mlavergn/zigbuildx#<commit>`. The hash is unchanged
  if the pushed files match.

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
- **llama.cpp.zmake** (`~/src/mlavergn/llamazig`) could replace its Apple
  libc++ workaround with `xcode.linkLibCpp`. Output is identical, but the C++
  runtime changes from Apple's dylib to Zig's static libc++. The owner's call.
- **Other repos** could adopt `Docs.includePrivate`, a one-line change on each
  docs install step.
- **zigstorage's `make lint`** walks `zig-pkg/`. Give it an explicit file list,
  as zigclaude does.
