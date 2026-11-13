# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

zigbuildx is a library of Zig build system extensions: logic `std.Build` lacks,
imported from other projects' `build.zig` instead of copied into each one.
`README.md` covers setup and usage.

- **Zig 0.17, 0.17.1 or later.** A `comptime` guard in `build.zig` refuses any
  other minor release, and 0.17.0. Several extensions work around 0.17.0 defects (see
  *Workarounds*).
- **It runs on every host.** The code executes inside other projects' build
  runners on macOS, Linux and Windows. Host-specific behaviour is a runtime
  branch on `b.graph.host`, so a Windows-only mistake compiles on macOS;
  `make cross` catches it.
- **No dependencies.** `build.zig.zon` `.dependencies` stays empty.
- **No packaging.** Building a `.pkg`, `.deb`, `.msi` or `.apk` is out of
  scope; 4.0.0 removed `Pkg` and `Apk`. `App` only lays out an install (a
  `.app`, a desktop entry); signing, `.dmg`s and notarization are a packager's.
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
  they need that sibling checkout. `make lint` runs `zlint -c ../styleguide
  --deny-warnings` over `build.zig` and `ZIG_DIRS`
  (default `src cli web`; only `src/` exists). Add new source roots to
  `ZIG_DIRS`.
- `make tag`: tags `v<.version>` and pushes it; `zigbuildx-pin` finds
  releases by that tag.
- `make vendor`: the test "vendor end to end" in `src/vendor.zig`, which
  skips unless `-Dvendor-check` is passed (an option, since a cached
  configure keeps a Run step's environment). Through real `zig build`
  runs it builds a scratch consumer (`../a` → `../b`, a lazy `.url`
  dependency, zigbuildx from a copy of its `.paths`), checks the refusals,
  vendors it, removes every origin and builds the unpacked tarball with no
  packages. About a minute; not part of `validate`. Run it after changing
  `Vendor` or `Stage`.

Unit tests cannot cover how the build graph is wired, and `refAllDecls` does
not analyze nested functions, so a typo in an unreferenced method compiles.
Check graph changes in a scratch consumer outside this repo, re-fetching
after every change (the hash pins the contents):

```sh
zig fetch --save=zigbuildx ../zigbuildx   # from the scratch package
```

- **`App`:** a scratch consumer with an `.icns`, a PNG and a resource (any
  bytes do): on macOS `zig build`, then `plutil -lint` the plist, check the
  executable bit, `codesign --force --sign -` and `codesign --verify --deep
  --strict` (a fake dylib in `frameworks` cannot be signed; leave it out), and
  `open -n`; `-Dmacos-min` reaches `LSMinimumSystemVersion`; a bad identifier
  fails with its message; `-Dtarget=x86_64-linux-gnu` (with and without
  `linux_subdir`) and `-Dtarget=x86_64-windows` show the other layouts.
- **Android:** no SDK is installed, and none should be. Point `ANDROID_HOME`
  at a fake tree holding `ndk/<v>/toolchains/llvm/prebuilt/<host>/sysroot`;
  linking libc needs the real NDK, so check `configure` from the failing
  link command (`--libc`, `-z max-page-size=16384`).
- **Linux:** podman with Debian (`xz-utils curl git`) and Zig 0.17.1's
  aarch64-linux tarball in `/opt`. The `xcrun` tests skip there.
- **Windows:** compile only, through `make cross`.
- **Configure caching:** run `zig build` twice; the second skips `build()`
  (a `std.debug.print` in the scratch `build.zig` shows whether it ran).
- **`Stage` tests** run `zig fetch` with the `zig` that `build.zig` passes as
  `ZIGBUILDX_ZIG` (they skip without it, as `make cross` builds them), into a
  scratch global cache kept at `.zig-cache/zigbuildx-test-global-cache`. Zig
  0.17 spends about 30 s setting up a new global cache, so the first test run
  after `make clean` is that much slower.
- **A distribution build end to end:** a scratch consumer calling
  `cloneMissing`, its siblings as bare repos (git clones them; Zig cannot
  fetch a local path), and a lone clone of it built with `-Ddist` and an
  empty `ZIG_GLOBAL_CACHE_DIR`
  (seeded with `zig fetch ../zigbuildx`, which stands in for the public URL).

## Module layout

```
build.zig              the public surface: re-exports Deps, Git, Xcode, Swift,
                       App, AppBundle, AppFile, Android, AndroidAbi and Docs;
                       installs the host tool
src/module.zig         the barrel the tests compile
src/deps.zig           Deps: the entry points (clone, sync, update, pin, restore)
src/sync.zig           Sync: one run over the manifests, siblings and worktrees
src/stage.zig          Stage: a distribution build under cloneMissing, siblings staged into zig-pkg/
src/source.zig         Source: a `.clone` or an `.archive`
src/zon_edit.zig       ZonEdit: in-place `build.zig.zon` edits
src/manifest.zig       Manifest: the parts of a `build.zig.zon` Deps reads
src/entry.zig          Entry: one manifest dependency
src/pin.zig            Pin: a worktree's SHA, tag or branch
src/pin_kind.zig       PinKind: which of the three a pin is
src/stamp.zig          Stamp: a worktree's `deps/.zigbuildx/*.rev` record
src/mode.zig           Mode: develop or dist
src/updated.zig        Updated: what an update moved or skipped
src/release_pin.zig    ReleasePin: `git+` URLs and release tags for `zigbuildx-pin`
src/git.zig            Git: one thin wrapper per git command
src/xcode.zig          Xcode: Apple SDKs, the macOS floor, frameworks, xcframeworks
src/swift.zig          Swift: swiftc dylibs
src/app.zig            App: a GUI executable's macOS `.app` or Linux desktop entry
src/android.zig        Android: the NDK
src/android_abi.zig    AndroidAbi: an ABI and its Zig target
src/docs.zig           Docs: autodoc with private declarations
src/vendor.zig         Vendor: `zig build vendor`, a self-contained source tarball
src/zip_archive.zig    ZipArchive: `.archive` download and unpack
src/file.zig           File: file-system primitives the others share
src/tool.zig           Tool: the host tool's main and command dispatch
src/tool_artifact.zig  ToolArtifact: finds the host tool for a consumer's build
src/zip_builder.zig    ZipBuilder: in-memory zips for the tests
src/test_tree.zig      TestTree: git repositories and a consumer, for the tests
```

Consumers import this package's `build.zig` by dependency name, so only what
it re-exports is reachable; everything else in `module.zig` is internal.
One struct per file (B.2.a): a type stays beside the primary struct only
when that struct is its sole user (`Release`, `Command`, `Xcframework`,
`AppBundle`), and anything two structs share gets a file of its own. A new sub-folder
with several `.zig` files gets its own `module.zig` barrel.

## Architecture conventions

@../styleguide/ZIGSTYLE.md

`../styleguide/ZIGMIGRATE.md` maps deprecated APIs. Departures from and
additions to ZIGSTYLE:

- **No `@src()` entry tracing** (D.3.a): a consumer's build runner is Debug,
  where `log.debug` prints on every build.
- **A scoped logger only in files that log, and `std` only in files that
  use it**: `zlint` flags an unused import.
- **Fixed limits are named constants** (A.1.b): there is no `Config` inside
  another project's `build()`, so read caps (`Manifest.max_bytes`) and
  `curl`'s `ZipArchive.connect_timeout_seconds` are constants on their
  struct, never bare numbers. A value a consumer must choose is a `-D`
  option.
- **Doc comments** (E.1) on every function say what it does, never how: a
  one-line summary (plus at most one line a caller must know, such as "Call
  it first in `build()`"), a blank `///`, then a one-line `` - `name`: ``
  bullet per parameter in signature order and a one-line `- Returns:`,
  both capitalized, with no blank line between them. `- Returns:` is
  omitted only for plain `void` and `noreturn`; an error union states its
  errors there (`- Returns: IO errors.`). Why a line does something
  non-obvious, such as a Zig 0.17 workaround, is a `//` comment on that line.
- **`// SAFETY:`** above every `undefined` field, saying what populates it.
- **No `deinit` on a struct that owns nothing** (D.2.a): `Sync` and `Stage`
  allocate from their caller's arena (the build's), so a `deinit` would be
  `_ = self;` and a `defer` at every call site.
- **One-line parameter lists**, even past the usual width.
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
  tracks `SDKSettings.json`; `Android.resolve`, `Deps.sync` with
  worktrees, and a distribution build poison. Upstream is not tracked: in
  develop mode `Deps` updates only when `build()` runs for some other
  reason.
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
  the steady state. A fetched package is told apart by where it lives
  (`isFetched`: `zig-pkg/<key>` or a cache's `p/<key>`), not by its
  `build_root` equalling its key, which holds only when `zig build` runs in
  the root's own directory. `missingSibling` tests `build_zig` first and
  raises the comptime branch quota per package: comparing a dozen hashed
  packages' paths, as a distribution build makes them, exceeds the default
  1000. A lock, `<root>/.zig-cache/zigbuildx.lock`, is held from
  before the first clone, and again by `applyUpdate` while siblings and
  worktrees are updated or moved, so two builds never move one checkout.
- **`.archive` (`ZipArchive`):** a zip unpacked at a `.path` wherever a
  `.clone` would be cloned. It is downloaded (`curl`; `file://` in process)
  into `<path>.zigbuildx-unpack/`, extracted, stripped of a single top-level
  folder, and renamed into place; the old directory waits in staging until
  the new one is in. It needs no re-run, since no Zig code imports it, so
  `missingSibling` and `missingWorktree` skip the root's archive paths. A stub
  `build.zig` marks it present in the runner's table. `.zigbuildx-archive`
  stamps the URL: a new URL replaces the directory, and a directory without
  the stamp is refused. It cannot be pinned, is never updated, and is not
  hash-checked. An entry name with a `:` is refused before anything is
  written: `std.zip` stops `..` and a leading `/`, but not a Windows drive
  (`C:\…`) or an NTFS stream, which Windows writes wherever they point.
- **One entry point per `build()`:** `cloneMissing` and `sync` each declare
  `-Ddist` and `zigbuildx-pin`, which Zig panics on declaring twice;
  `cloneMissing` also declares `dev` and `vendor`. A second
  call of the same one returns at once (`Deps.ranBefore`); mixing them
  fails with a message (`failMixed`), since `cloneMissing` clones `deps/`
  paths as plain checkouts, which `sync` then refuses for lacking a stamp.
- **`Deps.sync`:** must come first in `build()`. `.sha` or `.tag` gives a
  detached worktree under `deps/`; `.branch` gives the branch
  `<consumer>/<branch>`. A worktree is created from its checkout (`.checkout`,
  default `../<name>`), cloned or fetched as needed; a changed pin moves a
  clean worktree, and one with work of its own stops the build. Anything
  cloned, created or moved exits 1. The steady state compares manifests with
  `deps/.zigbuildx/*.rev` stamps and runs no `git`. Each worktree's manifest
  is read in the same pass; a `../x` from `deps/mid` resolves to the root's
  `deps/x`, and the first declaration of a path wins. An unclaimed worktree
  is removed when clean, else kept and listed; its own worktrees
  (`<orphan>/deps/<x>`) go first, and it stays while any of them does,
  since `git worktree remove` would delete them and its git-ignored `deps/`
  hides their work from its own status. Every claimed worktree's `deps/` is
  scanned too, so one it stops declaring is an orphan. "Commits of its own"
  are counted from the branch's tip as last fetched once that holds the
  stamped commit (`workBase`), so commits pushed from a worktree are not. The return type is `noreturn`
  while a `deps/` package is missing, so a transitive top-level `@import` can
  wait; a worktree dependency must have a `build.zig`.
- **The update (develop mode):** whenever `build()` runs, `Deps`
  fast-forwards siblings and, under `sync`, `.branch` worktrees. Everything
  that rules one out is checked first and locally (not a checkout, at a
  `.tag`, detached, on another branch than its `.branch`, no upstream,
  dirty, or ahead of the tip as last fetched), so a skipped checkout never
  reaches the network. The rest are fetched at once (`Sync.fetchAll`: every
  `git fetch` child is started before any is waited for; a build runner is
  single-threaded, so a `std.Io.Group` would run them one by one). Each
  fetch names the remote whose refs are read next: `origin` for a `.branch`,
  a distribution build, worktrees and `Stage`, the branch's own upstream
  remote for `@{u}`.
  `Git.fetch_args` adds `--prune`, so a branch deleted upstream is gone
  rather than stale (tags fetched by `--tags` are never pruned). `.sha`
  and `.tag` worktrees and archives are never fetched. A skip or a failed
  fetch warns and never fails the build; anything moved exits 1.
- **Sibling refs (`Sibling.ref`):** a `../x` may set `.branch` or `.tag`,
  in the root's manifest or a sibling's; `.sha` there is refused (only a
  worktree is frozen at a SHA). `pinOf` refuses an empty value or one
  starting with `-`, which git could read as an option (`git checkout
  <branch>` takes it bare). Either is cloned at it (`git clone
  --branch`; a tag leaves HEAD detached). In develop mode a `.branch` is
  fast-forwarded to `origin/<branch>` and a `.tag` is never fetched or
  moved: a sibling off its tag (checked against the local tag) is left, with
  a warning. Two manifests naming different refs for one sibling: the first
  found (root first) wins, with a warning, in either mode.
- **A distribution build (`-Ddist`):** a complement to develop mode for
  reproducible builds from the manifests' refs, with no commit tracking.
  `Deps.modeOf`, called by both `cloneMissing` and `sync`, declares `-Ddist`
  (off unless passed; nothing in the environment turns it on), and poisons
  the configure cache so every configure checks the remotes. `Mode` is
  `develop` or `dist`; the entry point decides what `dist` does:
  `cloneMissing` stages (next bullet), `sync` enforces (the one after).
- **A distribution build under `cloneMissing` (`Stage`, `Deps.stageSiblings`):** the build
  reads nothing outside the consumer, and Zig never fetches a sibling, so
  private repositories need only git's credentials. `Stage` runs before
  anything else, under the lock. Every `.path` that leaves the package
  declaring it is a sibling to stage; the root's own inside paths are left to
  what follows (`cloneSiblings` and `enforceSiblings`, as under `sync`).
  Breadth first (`prepare`, so the root's declaration, then the nearer, wins,
  with a warning): a `.clone` is cloned into
  `.zig-cache/zigbuildx-dist/clones/<base>-<wyhash of URL>` (fetched on a
  later run), its ref resolved (`refs/tags/<t>`, `refs/remotes/origin/<b>`,
  or `origin/HEAD`), the commit exported (`Git.archive`, extracted with
  `std.tar` in process); an `.archive` is unpacked by `ZipArchive`. Depth
  first (`stage`; `State.visiting` refuses a cycle): each export's manifest
  has its own siblings rewritten (`ZonEdit`), `zig fetch <dir>` hashes it,
  and the export is renamed into `<root>/zig-pkg/<hash>/`. Zig resolves a
  hash from `zig-pkg/` before any cache or URL; that is the only store
  zigbuildx can be sure the build reads, since the configurer is not told
  `--global-cache-dir`, `zig fetch` has no such flag, and its `--pkg-dir`
  does not place a plain fetch. The `.url` written is a label
  (`Stage.labelOf`: `git+<url>#<commit>`, an scp `.clone` as `git+ssh://`,
  which Zig requires, a local path as `git+file://`): never fetched while the
  hash is staged, and never fetchable for a package whose manifest was
  rewritten, so staging runs on every fresh checkout. The root's manifest is
  rewritten last, after `build.zig.zon.orig` (written only when something is
  rewritten, so the re-run never overwrites it), and the run exits 1; the
  re-run finds no sibling and `Stage` does nothing. Refused: a sibling with no
  `.clone` or `.archive`, a `.sha`, both `.branch` and `.tag`, an invalid ref
  (`Pin.isValidValue`), a sibling's pinned `.path` under its own `deps/` (a
  `sync` worktree, which no export holds), the root as a dependency, and a
  cycle. `zig build dev` runs `zigbuildx restore <root>` (`Deps.restore`),
  which renames `.orig` back; with none it says so and succeeds. Going back
  takes a second `zig build`: the run that restores was configured from the
  staged packages. Only `cloneMissing` declares `dev`: `sync` never rewrites
  the manifest.
- **Why staging works this way (Zig 0.17, checked in scratch packages):**
  Zig fetches every eager `.url` dependency before `build()` runs, so
  zigbuildx can only get in front of `.path` siblings; a lazy `.url` staged
  during `build()` is found by Zig's lazy fetch after it returns. A `.path`
  that leaves a hashed package is an error (`dependency path outside
  project`), so each staged sibling's own siblings must be rewritten to
  `.url` + `.hash` before it is hashed, leaves first. `zig fetch --save`
  keeps an existing `.path` entry, hence `ZonEdit`. A folder's hash covers
  only what its `.paths` lists, so the export matters only for `.paths =
  ""`; it is kept so a package is exactly its commit. Zig fetches
  `git+http(s)` only: `git://`, `git+file` and `git+ssh` are refused, which
  is harmless for a label whose hash is staged.
- **`zig build vendor` (`Vendor`, `Stage` with `local`):** a third route
  beside develop and dist: one `.tar.gz` of the root and every package it
  reads, at the commits last built, that builds with Zig 0.17 and fetches
  nothing. Declared by `cloneMissing` only, as `zigbuildx vendor <root> <zig>
  <out-dir> <zigbuildx-name>` into an output directory the step installs at
  `<prefix>/vendor/`. It reads no git remote (only Zig fetches, a `.url`
  dependency its global cache lacks) and touches no working tree, under
  `.zig-cache/zigbuildx-vendor/vendor.lock`: the root's HEAD is exported to
  `.zig-cache/zigbuildx-vendor/<top>/` (`.name` and `.version` must be plain
  file-name text, since `<top>` is deleted and recreated), and
  `Stage` runs with `local` (export each `../x` checkout's HEAD, or copy an
  `.archive` unpack; no `.clone` needed), `target` (the export: its manifest
  is rewritten and its `zig-pkg/` filled, while paths still resolve from
  `root`), `backup = false`, and `exportInside` (the root's inside `.path`s:
  a checkout's HEAD, else copied whole when the root's commit lacks it).
  Every check runs before staging and all problems are reported together
  (`Stage.problems`, `failAll`; the root's first, `checkRoot`): a root or
  sibling that is not its own checkout (git would answer for an enclosing
  repository), tracked changes (`Git.hasTrackedChanges`;
  untracked files do not count and no export holds them), a `.branch`
  sibling not on that branch (detached included), a `.tag` sibling not at
  it, and a root with `build.zig.zon.orig`. A HEAD on no remote branch as
  last fetched (`Git.isOnRemote`) warns. Then `zig build --fetch=all` in the
  export (it fetches without running `build()`, lazy dependencies included,
  into the export's `zig-pkg/`), the marker `.zigbuildx-vendor` (ZON: Zig
  version, the root's zigbuildx `.hash`, the commit, each sibling's label;
  a label names `origin` with its credentials removed,
  `Stage.withoutCredentials`, since a token in a remote URL would ship),
  and the proof: `zig build` in the export with a global cache whose `p/`
  is emptied first and must still be empty after (packages live only in
  `p/`; the rest of the cache is kept at `.zig-cache/zigbuildx-vendor/
  global-cache` to skip Zig's 30 s setup). The tarball is
  `<name>-<version>-<commit12>.tar.gz` with one top-level folder of that
  name, entries sorted, mtime the commit time (`Git.commitTime`), owner 0,
  modes 0o755/0o644 (`std.tar.Writer` over `std.compress.flate` gzip, whose
  header has no time), so the same commits give the same bytes on one kind
  of host (Windows has no executable bit). An entry that is not a file,
  directory or link (a FIFO would block the read) is refused. In a tree
  with the marker (`Vendor.isVendored`), `cloneMissing` declares `-Ddist`
  and the steps `dev`, `zigbuildx-pin` and `vendor` as refusals
  (`declareVendored`) and returns.
- **Why vendoring works this way:** it ships what was built: local HEADs,
  not the manifests' refs (a distribution build builds those), and commits,
  not working trees, so uncommitted tracked work is refused rather than
  shipped or silently dropped. An unpushed HEAD only warns, since the
  tarball needs no remote. A `.branch` sibling must be on that branch;
  detached at its tip is refused, as being on the branch is what `.branch`
  declares. `vendor.lock` is a file apart from `zigbuildx.lock` because
  `Stage.run` takes the root lock itself. The marker records the root's
  zigbuildx `.hash` (which carries the version), since `src/` cannot read
  zigbuildx's own `build.zig.zon`. Tar and gzip run in process, so no host
  needs `tar` or `gzip`. A manifest without `.version` names the tarball
  `0.0.0`. Checked in scratch packages: `--fetch=all` runs no `build()`,
  and a `zig build` the host tool starts honours its own
  `ZIG_GLOBAL_CACHE_DIR`, so the proof's cache is not the developer's.
- **A distribution build under `sync` (`Sync.enforceSiblings`):** `applyUpdate` runs
  `enforceSiblings` in place of `updateSiblings`: every sibling (siblings of
  siblings included) goes to its ref, `.branch` at `origin/<branch>` (on the
  branch), `.tag` detached, no ref the remote's default branch
  (`ls-remote --symref`). Work of its own fails the build, checked before
  the network: dirty, or on a branch that has no upstream or is ahead of
  it; a clean detached sibling is always moved. Switching to an existing
  local `<branch>` is refused first when it is not an ancestor of
  `origin/<branch>` (`Git.isAncestor`), so a failed move leaves the
  sibling where it was. A sibling already at the target commit is left on
  its branch or detached (`moveSibling`): the build reads files, not refs,
  and a switch would cost a re-run. Fetches run at once, a
  branch always, a tag only when the checkout lacks it; a failed fetch or a
  ref not on the remote fails the build. Anything moved exits 1, as a clone
  does. `deps/` `.branch` worktrees are updated as in develop mode, but one
  that cannot be (work of its own, a failed fetch, its branch gone) fails
  the build; archives behave as in develop mode. A
  distinct exit code for "re-run" is impossible: 0.17's `zig build` turns
  any configure failure into a fatal exit 1
  (`lib/compiler/Maker.zig:1515`), and its own re-run loop covers only
  hashed lazy packages, so a distribution build runs
  `zig build -Ddist || zig build -Ddist`.
  Clones land at `../x`, beside the project: `.path` is text, so a `deps/`
  layout would need `deps/x` manifests (the `sync` worktree route), which
  gives up live editing of `../x`.
- **Empty checkouts (`Sync.repair`):** a sibling path that exists with
  neither `build.zig.zon` nor `build.zig` is filled in only when it holds
  nothing but `.git` and has no commits (an interrupted clone): `.branch`
  or the remote's HEAD (`ls-remote --symref`) is fetched and checked out,
  tracking, or a `.tag` is fetched and checked out detached. Anything else
  without a manifest is refused, never touched.
- **`zigbuildx-pin` (`Deps.pin`, `make buildxpin` in `Makefile.in`):**
  declared by `cloneMissing` and `sync`. It reads this zigbuildx's `.url`
  (named by `ToolArtifact.dependencyName`) and runs `zig fetch` in the root,
  keeping the URL's form (`?ref=<ref>#<commit>` with `--save`, `#<ref>` with
  `--save-exact`). A branch pin (`#main`) is refreshed on its branch, never
  swapped for a tag; a branch is a ref that is neither a commit nor a tag
  the listing names, so a tag that is no release (`v5.2.0-rc1`, `nightly`)
  moves to the newest release. Otherwise it takes the newest `vX.Y.Z` from
  `git ls-remote --tags` (an annotated tag's commit from its `^{}` line, so
  no `--refs`) and re-pins when the tag or its commit differs, as after a
  history rewrite. A pin newer than every release, a pre-release included
  (`ReleasePin.tagVersion`), is left alone. It refuses while
  `build.zig.zon.orig` exists: a pin written into the manifest a
  distribution build rewrote would be lost to `zig build dev`.
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
- **`App`:** `addBundle` assembles `<name>.app/Contents/{MacOS/<name>,
  Info.plist, Resources/<name>.icns, Resources/*, Frameworks/*}` in a
  `WriteFile` for a macOS target, from any host (null otherwise; frameworks
  add the `@executable_path/../Frameworks` rpath). `addInstall` installs it at
  `<prefix>/<name>.app`, where a packager looks for it; a Linux target gets
  `bin/<name>`, `share/applications/<name>.desktop` and a 256×256
  `share/icons/hicolor` PNG, under `linux_subdir` when set; anything else gets
  the artifact alone. Unsigned: signing is the packager's. Both version keys are
  `version` without a `-`/`+` suffix; `LSMinimumSystemVersion` is the target
  query's `os_version_min` (`-Dmacos-min`), else 13.0, never the resolved
  version, which is the host's on a native build. A bad name (empty, `.`,
  `..`, or holding `/ \ " ` $ %` or a line break), identifier, version, a line
  break in a desktop value, or a bundle file name or `linux_subdir` that leaves
  its directory (`WriteFile` and installs join `..` as given) is one
  `b.addFail` step that every step it would write through depends on (on
  Linux the desktop entry's and icon's installs too), so the build fails only
  when the app is built, and installs nothing. Zig 0.17.1's
  `WriteFile` and `InstallDir` copies keep the executable bit. `AppBundle` is
  re-exported because a consumer passes one value to both calls, `AppFile`
  for a `frameworks` list built outside the literal. The frameworks rpath is
  added once, even when the consumer added it too. The desktop entry's `Exec=`
  is the bare executable (no `%f`/`%U`), quoted when the name holds a space or
  another reserved character (the name check refuses what quotes would
  escape); `Comment`'s `\` is escaped. Off macOS and Linux the executable
  keeps its artifact name, not `name`.
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
- **Compatibility:** 6.4.0 adds `App`, `AppBundle` and `AppFile`; nothing else
  changes. 6.2.1 requires Zig 0.17.1. 6.0.0 adds `-Ddist`, which nothing in the
  environment turns on. Under `cloneMissing` a distribution build
  stages the siblings into `zig-pkg/` and rewrites `build.zig.zon` (kept as
  `build.zig.zon.orig`), where 5.x cloned them to `../x`; every sibling then
  needs a `.clone` or an `.archive`. `cloneMissing` declares a `dev` step, so
  a consumer's own `dev` step must be renamed. `sync` is otherwise unchanged.
  6.1.0 adds `zig build vendor`: `cloneMissing` declares a `vendor` step, so
  a consumer's own `vendor` step must be renamed; nothing else changes. 5.1.1
  needs no consumer change: it splits `deps.zig`
  one struct per file, so `Sync`'s messages now log as `zigbuildx_sync`
  rather than `zigbuildx_deps`. 5.1.0 needs no consumer change: it adds
  `.tag` on a sibling (refused before). Under `cloneMissing`, a root
  `deps/x` with a `.tag` is now cloned at the tag and warned about when off
  it, as a sibling's is; it used to be cloned on the default branch and
  followed. 5.0.0 removed `-Dupdate`, `Deps.guard`, `Deps.mark`
  and `deps-mark`; the update runs on every configure. 4.1.0 needs no
  consumer change, though an iOS, tvOS, visionOS or watchOS target must call
  `xcode.configure(lib)`. 4.0.0 removed `Pkg` and `Apk`.

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

- **Staging under `sync`:** a distribution build under `sync` still moves
  the siblings at `../x`; staging its `deps/` worktrees by their pins is the
  next step if wanted.
- **`vendor` under `sync`:** `sync` does not declare it; vendoring its
  `deps/` worktrees means exporting each at its pin, as `exportInside` does
  for a `cloneMissing` checkout.
- **Private lazy `.url` dependencies:** staging one during `build()` works
  (see *Why staging works this way*); eager ones cannot be reached.
- **ADB over TCP install step** (about 1,000–1,300 lines): the ADB protocol
  (push and shell) on `std.Io.net`, plus RSA signing of the auth token with
  `~/.android/adbkey` (`std.crypto.ff`; std can only verify RSA). Open: a
  test device, a missing key, and whether it belongs in its own package.
- **Rejected for `App`:** signing (ad hoc included), `.dmg`s and
  notarization (a packager's, under *No packaging*); a universal `lipo`
  bundle; `Exec=` arguments; a `linux_subdir` for other targets.
- **Rejected for `vendor`:** shipping a working tree's uncommitted changes
  (a tarball is commits, so it can be rebuilt from them), formats other than
  `.tar.gz`, and bundling the Zig toolchain (the marker names its version).
- **Rejected:** a lock file of sibling commits (a distribution build builds
  the declared refs instead); `.sha` on a `../x`; and a `--fork` per sibling, since
  Zig reads `--fork` only from the command line and matches only hashed
  packages. For a distribution build under `cloneMissing`: a loopback git server for Zig
  to fetch the private siblings from (staging needs none, and it would have
  to outlive the configure that started it), and staging private `.url`
  dependencies (Zig fetches an eager one before `build()` runs).
