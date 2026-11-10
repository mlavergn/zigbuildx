const std = @import("std");
const log = std.log.scoped(.zigbuildx_deps);
const mod = @import("module.zig");

/// Walks a package's `build.zig.zon` dependencies and fetches the ones missing from disk.
///
/// A dependency that names a sibling checkout by `.path` can also name the
/// repository to fetch it from by `.clone`, or a zip to unpack there by
/// `.archive` — fields plain Zig ignores. `cloneMissing` reads them, and
/// fetches every such dependency that is absent before the build graph is
/// declared.
///
/// `sync` does that too, and also gives each dependency whose `.path` is under
/// `deps/` its own git worktree of the shared checkout, pinned by `.sha`,
/// `.tag` or `.branch`.
///
/// With `-Ddist`, `cloneMissing` builds from nothing outside the consumer: `Stage`
/// clones each sibling with git, stages it into Zig's package store, and
/// rewrites `build.zig.zon` to name it by hash; `zig build dev` puts the
/// original back. Under `sync`, `-Ddist` brings the siblings at `../x` to their
/// refs instead.
pub const Deps = struct {
    const Self = @This();
    /// The `-D` option that turns a distribution build on.
    const dist_option = "dist";
    /// The step `sync` declares to list worktrees.
    const deps_step = "deps";
    /// The step that repins zigbuildx.
    const pin_step = "zigbuildx-pin";
    /// The step `cloneMissing` declares to put back a manifest a distribution build rewrote.
    const dev_step = "dev";
    /// The step `cloneMissing` declares to write a vendored source tarball.
    const vendor_step = "vendor";
    /// The comptime branches allowed per entry of the build runner's package table, enough to compare paths of any length.
    const branches_per_package = 4096;

    /// Clones every missing cloneable dependency, transitive ones included, and exits 1; returns when none are missing.
    ///
    /// - `b`: The build graph.
    /// - `zon`: The caller's `@import("build.zig.zon")`.
    /// - Returns: `void` when every dependency is present; otherwise `noreturn`.
    pub fn cloneMissing(b: *std.Build, comptime zon: anytype) if (Self.allPresent(zon) and Self.siblingsPresent(zon)) void else noreturn {
        const present = comptime Self.allPresent(zon) and Self.siblingsPresent(zon);
        // In a dependency's build() the root's has already run.
        if (present and !b.isRoot()) return;
        if (Self.ranBefore(b)) {
            // A second `cloneMissing` has nothing left to do; one after `sync` is a mix-up.
            if (present and !b.top_level_steps.contains(Self.deps_step)) return;
            Self.failMixed();
        }
        const root = Self.rootPath(b) catch |err| {
            log.err("cannot resolve the build root [{any}]", .{err});
            std.process.exit(1);
        };
        // A vendored tree holds every package already: nothing is cloned, updated or fetched.
        const vendored = mod.Vendor.isVendored(b.allocator, b.graph.io, root) catch |err| {
            log.err("cannot look for {s} [{any}]", .{ mod.Vendor.marker_name, err });
            std.process.exit(1);
        };
        if (vendored) {
            if (present) {
                Self.declareVendored(b);
                return;
            } else {
                log.err("this vendored tree lacks {s}; unpack the tarball again", .{comptime Self.missingSibling(zon) orelse "a .path dependency"});
                std.process.exit(1);
            }
        }
        if (present) {
            Self.addPinStep(b);
            Self.addDevStep(b);
            Self.addVendorStep(b);
        }
        const mode = Self.modeOf(b);
        // A distribution build uses staged packages: Zig never fetches a sibling, and nothing at `../` is read.
        // On the re-run no sibling is left, and what follows handles `.path`s inside the consumer.
        if (mode == .dist) Self.stageSiblings(b, root);
        var run = mod.Sync.init(b.allocator, b.graph.io, root) catch |err| {
            log.err("cannot clone dependencies [{any}]", .{err});
            std.process.exit(1);
        };
        run.mode = mode;
        // With everything present this queues the siblings, for the update, fills in
        // an empty checkout, and unpacks any archive whose URL changed.
        run.cloneSiblings() catch |err| {
            run.logFailure(err, "clone");
            std.process.exit(1);
        };
        // The runner was compiled without a fresh clone: its build() would never run, so only a re-run picks it up.
        if (present) {
            if (run.changed) {
                log.info("dependencies changed; re-run zig build", .{});
                std.process.exit(1);
            }
            Self.applyUpdate(&run, false);
            return;
        }
        if (run.changed or run.unpacked) {
            log.info("fetched missing dependencies; re-run zig build", .{});
        } else if (Self.appearedOnDisk(b, root, comptime Self.missingSibling(zon))) {
            // A concurrent build fetched it while this one waited for the lock.
            log.info("another build fetched the missing dependencies; re-run zig build", .{});
        } else {
            log.err("{s} is missing: give it a .clone or an .archive, or put a Zig package there", .{comptime Self.missingSibling(zon) orelse "a .path dependency"});
        }
        std.process.exit(1);
    }

    /// Clones missing sibling checkouts and brings every worktree dependency in line with its pin.
    /// Call it first in `build()`.
    ///
    /// - `b`: The build graph.
    /// - `zon`: The caller's `@import("build.zig.zon")`.
    /// - Returns: `void` when everything is in place; otherwise `noreturn`.
    pub fn sync(b: *std.Build, comptime zon: anytype) if (Self.allPresent(zon) and Self.worktreesPresent(zon) and Self.siblingsPresent(zon)) void else noreturn {
        const present = comptime Self.allPresent(zon) and Self.worktreesPresent(zon) and Self.siblingsPresent(zon);
        // In a dependency's build() the root's sync has already run.
        if (!b.isRoot()) {
            if (present) return;
            log.err("a worktree dependency is missing; the root package's build() must call Deps.sync first", .{});
            std.process.exit(1);
        }
        if (Self.ranBefore(b)) {
            // A second `sync` has nothing left to do; one after `cloneMissing`, which cloned `deps/` paths as plain checkouts, cannot make worktrees of them.
            if (present and b.top_level_steps.contains(Self.deps_step)) return;
            Self.failMixed();
        }
        const io = b.graph.io;
        const root = Self.rootPath(b) catch |err| {
            log.err("cannot resolve the build root [{any}]", .{err});
            std.process.exit(1);
        };
        var run = mod.Sync.init(b.allocator, io, root) catch |err| {
            log.err("cannot sync dependencies [{any}]", .{err});
            std.process.exit(1);
        };
        run.mode = Self.modeOf(b);
        run.run() catch |err| {
            run.logFailure(err, "sync");
            std.process.exit(1);
        };
        // Anything cloned, created or moved needs a re-run, as in cloneMissing.
        if (run.changed) {
            log.info("dependencies changed; re-run zig build", .{});
            std.process.exit(1);
        }
        // noreturn while one is missing, so nothing after the call compiles: a transitive
        // top-level @import of the missing package would otherwise fail before sync could create it.
        if (comptime !present) {
            log.err("{s} is still missing; an unpinned .path is used as is, so put it there or give it a .clone or an .archive", .{comptime Self.missingWorktree(zon) orelse (Self.missingSibling(zon) orelse "a .path dependency")});
            std.process.exit(1);
        }
        // Zig 0.17 skips build() when nothing it tracks changed, and a worktree deleted by hand or a
        // stamp left behind is nothing it tracks: poison the configure cache while worktrees exist.
        if (run.worktrees.items.len > 0 or run.orphans.items.len > 0) b.graph.poisonCache();
        Self.applyUpdate(&run, true);
        const list = b.addRunArtifact(mod.ToolArtifact.add(b));
        list.setName(Self.deps_step);
        list.addArg("deps");
        list.addDirectoryArg2(b.path("."), .{});
        // It reads and moves worktrees: never cached.
        list.has_side_effects = true;
        const top = b.step(Self.deps_step, "List worktree dependencies: pin, commit, clean or dirty");
        top.dependOn(&list.step);
        Self.addPinStep(b);
    }

    /// `zigbuildx pin <root> <name> <zig>`: pins dependency `name`, this zigbuildx, to its repository's newest release tag.
    /// Runs as the `zigbuildx-pin` step.
    ///
    /// - `process_init`: The process's allocator and IO.
    /// - `args`: The command line after the program's path; `args[0]` is the command.
    /// - Returns: `error.InvalidArguments` on a bad command line, `error.DepsFailed` when no release can be pinned or `zig fetch` fails, or IO and git errors.
    pub fn pin(process_init: std.process.Init, args: []const [:0]const u8) !void {
        if (args.len != 4) {
            log.err("usage: zigbuildx pin <root> <dependency-name> <zig>", .{});
            return error.InvalidArguments;
        }
        const allocator = process_init.arena.allocator();
        const io = process_init.io;
        const root = try std.Io.Dir.cwd().realPathFileAlloc(io, args[1], allocator);
        const name = args[2];
        // A pin written into the manifest a distribution build rewrote would be lost when `zig build dev` restores the original.
        if (try mod.File.exists(io, try std.Io.Dir.path.join(allocator, &.{ root, mod.Stage.backup_name }))) {
            log.err("build.zig.zon is rewritten for a distribution build ({s} holds the original); run zig build dev first", .{mod.Stage.backup_name});
            return error.DepsFailed;
        }
        const manifest_path = try std.Io.Dir.path.join(allocator, &.{ root, "build.zig.zon" });
        const source = try mod.File.readOptionalZ(allocator, io, manifest_path, .limited(mod.Manifest.max_bytes)) orelse {
            log.err("no build.zig.zon in {s}", .{root});
            return error.DepsFailed;
        };
        const manifest = mod.Manifest.parse(allocator, source) catch |err| {
            log.err("cannot parse {s} [{any}]", .{ manifest_path, err });
            return error.DepsFailed;
        };
        const entry = for (manifest.entries) |entry| {
            if (std.mem.eql(u8, entry.name, name)) break entry;
        } else {
            log.err("{s} has no dependency named {s}", .{ manifest_path, name });
            return error.DepsFailed;
        };
        const url = entry.url orelse {
            log.err("{s} has no .url: zigbuildx must be a .url + .hash dependency", .{name});
            return error.DepsFailed;
        };
        const repository = mod.ReleasePin.repository(url) orelse {
            log.err("{s}'s .url is not a git+ URL, so it has no tags to pin to: {s}", .{ name, url });
            return error.DepsFailed;
        };
        const current = mod.ReleasePin.ref(url);
        // The URL keeps its form: `?ref=<ref>#<commit>` from `zig fetch --save`, or `#<ref>` from `--save-exact`.
        const save = try allocator.print("{s}={s}", .{ if (std.mem.find(u8, url, "?ref=") == null) "--save-exact" else "--save", name });
        // Every tag, so one that is no release (`v5.2.0-rc1`, `nightly`) is told from a branch.
        const listing = mod.Git.remoteTags(allocator, io, root, repository) catch {
            log.err("cannot list the tags of {s}", .{repository});
            return error.DepsFailed;
        };
        if (mod.ReleasePin.isBranch(current, listing)) {
            // A branch is followed, never swapped for a tag: refresh its commit and hash.
            const target = if (current.len == 0) try allocator.print("git+{s}", .{repository}) else try allocator.print("git+{s}#{s}", .{ repository, current });
            try Self.zigFetch(io, args[3], root, save, target);
            log.info("refreshed {s} on {s}; the next zig build uses it", .{ name, if (current.len == 0) "its default branch" else current });
            return;
        }
        const release = mod.ReleasePin.newestRelease(listing) orelse {
            log.err("{s} has no release tag (vX.Y.Z)", .{repository});
            return error.DepsFailed;
        };
        const pinned_commit = mod.ReleasePin.commit(url);
        if (std.mem.eql(u8, current, release.tag)) {
            if (std.mem.eql(u8, pinned_commit, release.commit)) {
                log.info("{s} is already pinned to {s}, the newest release", .{ name, release.tag });
                return;
            }
            // The tag now names another commit (history rewritten), or the URL names none.
            if (pinned_commit.len > 0) log.info("{s} moved from {s} to {s}; re-pinning", .{ release.tag, mod.Sync.short(pinned_commit), mod.Sync.short(release.commit) });
        } else if (mod.ReleasePin.tagVersion(current)) |pinned| if (pinned.order(release.version) == .gt) {
            // A pin ahead of every release (a pre-release, or a release not tagged yet) is never moved back.
            log.warn("{s} is pinned to {s}, newer than {s}, the newest release tag; left as it is", .{ name, current, release.tag });
            return;
        };
        try Self.zigFetch(io, args[3], root, save, try allocator.print("git+{s}#{s}", .{ repository, release.tag }));
        if (std.mem.eql(u8, current, release.tag)) {
            log.info("pinned {s} to {s} at {s}; the next zig build uses it", .{ name, release.tag, mod.Sync.short(release.commit) });
        } else {
            log.info("pinned {s} to {s} (was {s}); the next zig build uses it", .{ name, release.tag, if (current.len == 0) "unpinned" else current });
        }
    }

    /// `zigbuildx deps <root>`: lists the worktree dependencies.
    /// Runs as the `deps` step.
    ///
    /// - `process_init`: The process's allocator and IO.
    /// - `args`: The command line after the program's path; `args[0]` is the command.
    /// - Returns: `error.InvalidArguments` on a bad command line, `error.DepsFailed` when a worktree is out of line, or IO errors.
    pub fn command(process_init: std.process.Init, args: []const [:0]const u8) !void {
        const io = process_init.io;
        if (args.len != 2) {
            log.err("usage: zigbuildx deps <root>", .{});
            return error.InvalidArguments;
        }
        const allocator = process_init.arena.allocator();
        const root = try std.Io.Dir.cwd().realPathFileAlloc(io, args[1], allocator);
        var run = try mod.Sync.init(allocator, io, root);
        // In the steady state this reads stamps and runs no `git`.
        run.run() catch |err| {
            if (err == error.DepsFailed) log.err("{s}", .{run.problem});
            return err;
        };
        if (run.changed) log.info("dependencies changed; re-run zig build", .{});
        var buffer: [1024]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(io, &buffer);
        try run.status(&stdout.interface);
        try stdout.interface.flush();
    }

    /// `zigbuildx restore <root>`: puts back the `build.zig.zon` a distribution build rewrote, so the next build uses the siblings at `../` again.
    /// Runs as the `dev` step.
    ///
    /// - `process_init`: The process's allocator and IO.
    /// - `args`: The command line after the program's path; `args[0]` is the command.
    /// - Returns: `error.InvalidArguments` on a bad command line, or IO errors.
    pub fn restore(process_init: std.process.Init, args: []const [:0]const u8) !void {
        if (args.len != 2) {
            log.err("usage: zigbuildx restore <root>", .{});
            return error.InvalidArguments;
        }
        const allocator = process_init.arena.allocator();
        const io = process_init.io;
        const root = try std.Io.Dir.cwd().realPathFileAlloc(io, args[1], allocator);
        if (try Self.restoreManifest(allocator, io, root)) {
            log.info("restored build.zig.zon; run zig build to build against ../", .{});
        } else {
            log.info("nothing to restore: there is no {s}", .{mod.Stage.backup_name});
        }
    }

    /// Reports whether every cloneable dependency is present.
    ///
    /// - `zon`: The caller's `@import("build.zig.zon")`.
    /// - Returns: `true` when none is missing.
    pub fn allPresent(comptime zon: anytype) bool {
        inline for (@typeInfo(@TypeOf(zon.dependencies)).@"struct".field_names) |field_name| {
            if (Self.isCloneable(zon, field_name) and !Self.isPresent(field_name)) return false;
        }
        return true;
    }

    /// Reports whether dependency `name` was present when the build runner was compiled.
    /// Use it to guard a top-level `@import` of a dependency's `build.zig`.
    ///
    /// - `name`: The dependency's field name in `build.zig.zon`.
    /// - Returns: `true` when present, when this package is not the root, or when the root is not a build runner.
    pub fn isPresent(comptime name: []const u8) bool {
        // The runner's generated table answers for the root package only.
        const root = @import("root");
        if (!@hasDecl(root, "dependencies")) return true;
        for (root.dependencies.root_deps) |dep| {
            if (std.mem.eql(u8, dep[0], name)) return @hasDecl(@field(root.dependencies.packages, dep[1]), "build_zig");
        }
        return true;
    }

    /// Reports whether dependency `name` declares both a `.path` and a `.clone`.
    ///
    /// - `zon`: The caller's `@import("build.zig.zon")`.
    /// - `name`: The dependency's field name in `build.zig.zon`.
    /// - Returns: `true` when both fields are present.
    pub fn isCloneable(comptime zon: anytype, comptime name: []const u8) bool {
        // An `.archive` is not cloneable: it is unpacked in the same build, so never makes cloneMissing noreturn.
        const Dep = @TypeOf(@field(zon.dependencies, name));
        return @hasField(Dep, "path") and @hasField(Dep, "clone");
    }

    /// Runs `zig fetch` in `root` to rewrite a dependency's `.url` and `.hash`.
    ///
    /// - `io`: IO the child is spawned on.
    /// - `zig`: The `zig` executable.
    /// - `root`: The package whose `build.zig.zon` is rewritten.
    /// - `save`: `--save=<name>` or `--save-exact=<name>`.
    /// - `target`: The `git+` URL to fetch.
    /// - Returns: `error.DepsFailed` when `zig fetch` fails, or spawn errors.
    fn zigFetch(io: std.Io, zig: []const u8, root: []const u8, save: []const u8, target: []const u8) !void {
        var child = try std.process.spawn(io, .{ .argv = &.{ zig, "fetch", save, target }, .cwd = .{ .path = root } });
        const term = try child.wait(io);
        switch (term) {
            .exited => |code| if (code == 0) return,
            else => {},
        }
        log.err("zig fetch {s} failed [{any}]", .{ target, term });
        return error.DepsFailed;
    }

    /// Declares the `zigbuildx-pin` step, which pins this zigbuildx in the root's `build.zig.zon` to its newest release.
    ///
    /// - `b`: The root package's build graph.
    fn addPinStep(b: *std.Build) void {
        const top = b.step(Self.pin_step, "Pin zigbuildx in build.zig.zon to its newest release tag");
        // Found by identity, whatever the root named it; none when zigbuildx comes only through another dependency.
        const name = mod.ToolArtifact.dependencyName() orelse {
            top.dependOn(&b.addFail("zigbuildx-pin: build.zig.zon does not list zigbuildx itself, so there is nothing to pin").step);
            return;
        };
        const run = b.addRunArtifact(mod.ToolArtifact.add(b));
        run.setName(Self.pin_step);
        run.addArg("pin");
        run.addDirectoryArg2(b.path("."), .{});
        run.addArg(name);
        run.addArg(b.graph.zig_exe);
        // It asks the network and rewrites build.zig.zon: never cached.
        run.has_side_effects = true;
        top.dependOn(&run.step);
    }

    /// Declares the `dev` step, which puts back the `build.zig.zon` a distribution build rewrote.
    ///
    /// - `b`: The root package's build graph.
    fn addDevStep(b: *std.Build) void {
        const run = b.addRunArtifact(mod.ToolArtifact.add(b));
        run.setName(Self.dev_step);
        run.addArg("restore");
        run.addDirectoryArg2(b.path("."), .{});
        // It rewrites build.zig.zon: never cached.
        run.has_side_effects = true;
        b.step(Self.dev_step, "Put back the build.zig.zon a distribution build rewrote, to build against ../ again").dependOn(&run.step);
    }

    /// Declares the `vendor` step, which writes a self-contained source tarball of the root and every package it reads.
    ///
    /// - `b`: The root package's build graph.
    fn addVendorStep(b: *std.Build) void {
        const run = b.addRunArtifact(mod.ToolArtifact.add(b));
        run.setName(Self.vendor_step);
        run.addArg("vendor");
        run.addDirectoryArg2(b.path("."), .{});
        run.addArg(b.graph.zig_exe);
        const out = run.addOutputDirectoryArg2("vendor", .{});
        run.addArg(mod.ToolArtifact.dependencyName() orelse "-");
        // It reads the checkouts' commits, which nothing tracks: never cached.
        run.has_side_effects = true;
        const install = b.addInstallDirectory(.{ .source_dir = out, .install_dir = .prefix, .install_subdir = "vendor" });
        b.step(Self.vendor_step, "Write a source tarball of this package and every package it reads, which builds with no network").dependOn(&install.step);
    }

    /// Declares in a vendored tree the option and steps `cloneMissing` declares, each refusing; `-Ddist` stops the build.
    ///
    /// - `b`: The root package's build graph.
    fn declareVendored(b: *std.Build) void {
        // Declared, so `ranBefore` holds and a `-Ddist` is refused rather than reported as unknown.
        const dist = b.option(bool, Self.dist_option, "Refused in a vendored tree, which builds what it holds") orelse false;
        if (dist) {
            log.err("this is a vendored tree ({s}): it builds what it holds, so -Ddist does not apply", .{mod.Vendor.marker_name});
            std.process.exit(1);
        }
        inline for (.{ Self.pin_step, Self.dev_step, Self.vendor_step }) |name| {
            const message = std.fmt.comptimePrint("{s}: this is a vendored tree ({s}), which builds what it holds; run it in the original checkout", .{ name, mod.Vendor.marker_name });
            b.step(name, "Refused in a vendored tree").dependOn(&b.addFail(message).step);
        }
    }

    /// Stages the root's siblings for a distribution build; exits 1 for a re-run when the manifest was rewritten.
    ///
    /// - `b`: The root package's build graph.
    /// - `root`: Its absolute root.
    fn stageSiblings(b: *std.Build, root: []const u8) void {
        var stage = mod.Stage.init(b.allocator, b.graph.io, root, b.graph.zig_exe) catch |err| {
            log.err("cannot stage dependencies [{any}]", .{err});
            std.process.exit(1);
        };
        stage.run() catch |err| {
            stage.logFailure(err);
            std.process.exit(1);
        };
        // The runner was compiled from the manifest as it was: only a re-run reads the rewritten one.
        if (stage.rewrote) {
            log.info("dependencies staged; re-run zig build", .{});
            std.process.exit(1);
        }
    }

    /// Puts `build.zig.zon.orig` back over `build.zig.zon` in `root`.
    ///
    /// - `allocator`: An arena for the paths.
    /// - `io`: IO for the filesystem.
    /// - `root`: The consumer's absolute root.
    /// - Returns: `true` when there was a backup to put back; IO errors.
    fn restoreManifest(allocator: std.mem.Allocator, io: std.Io, root: []const u8) !bool {
        const backup = try std.Io.Dir.path.join(allocator, &.{ root, mod.Stage.backup_name });
        const manifest = try std.Io.Dir.path.join(allocator, &.{ root, "build.zig.zon" });
        // A rename replaces the rewritten manifest in one step.
        std.Io.Dir.cwd().rename(backup, std.Io.Dir.cwd(), manifest, io) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }

    /// Updates the siblings, or in a distribution build brings them to their refs, and for `sync` the branch worktrees; exits when anything moved.
    ///
    /// - `run`: The run, after `run` or `cloneSiblings`.
    /// - `worktrees`: Whether to update worktrees too (`sync`).
    fn applyUpdate(run: *mod.Sync, worktrees: bool) void {
        // `Sync.run` released the lock on return: hold it again, so two builds never move one checkout at once.
        const lock = run.acquireLock() catch |err| {
            log.err("cannot lock dependencies [{any}]", .{err});
            std.process.exit(1);
        };
        defer lock.close(run.io);
        const moved = switch (run.mode) {
            .develop => run.updateSiblings() catch |err| {
                log.err("cannot update dependencies [{any}]", .{err});
                std.process.exit(1);
            },
            // Unlike an update, a sibling a distribution build cannot bring to its ref fails the build.
            .dist => run.enforceSiblings() catch |err| {
                run.logFailure(err, "update");
                std.process.exit(1);
            },
        };
        const updated: mod.Updated = if (worktrees) run.update() catch |err| {
            log.err("cannot update dependencies [{any}]", .{err});
            std.process.exit(1);
        } else .{};
        if (updated.failed > 0) switch (run.mode) {
            // Every build updates, so a skip or an offline fetch only warns: it must not stop the build.
            .develop => log.warn("{d} worktree dependencies were not updated; see the warnings above", .{updated.failed}),
            // A distribution build builds what the manifests declare or nothing, as for siblings.
            .dist => {
                log.err("{d} worktree dependencies could not be brought to their branch tips; see the warnings above, or build without -Ddist", .{updated.failed});
                std.process.exit(1);
            },
        };
        if (moved or updated.moved > 0) {
            log.info("dependencies updated; re-run zig build", .{});
            std.process.exit(1);
        }
    }

    /// Reads `-Ddist`, which turns a distribution build on.
    /// A distribution build poisons the configure cache, so every configure checks the remotes.
    ///
    /// - `b`: The root package's build graph.
    /// - Returns: `.dist` or `.develop`.
    fn modeOf(b: *std.Build) mod.Mode {
        const dist = b.option(bool, Self.dist_option, "Build each sibling at the ref its manifest declares: cloneMissing stages them into Zig's package store, sync moves them at ../") orelse false;
        if (!dist) return .develop;
        // Zig does not track the remotes, so a cached configure would skip the check.
        b.graph.poisonCache();
        return .dist;
    }

    /// Reports whether an earlier `cloneMissing` or `sync` ran in this build().
    ///
    /// - `b`: The root package's build graph.
    /// - Returns: `true` once `-Ddist` is declared, as both do.
    fn ranBefore(b: *std.Build) bool {
        return b.available_options_map.contains(Self.dist_option);
    }

    /// Stops a build() that calls both `cloneMissing` and `sync`, which would panic on their second declarations.
    fn failMixed() noreturn {
        log.err("call Deps.cloneMissing or Deps.sync, not both: sync does everything cloneMissing does", .{});
        std.process.exit(1);
    }

    /// Returns the absolute, resolved path of `b`'s package.
    ///
    /// - `b`: The build graph.
    /// - Returns: The path, owned by `b`'s arena; IO errors.
    fn rootPath(b: *std.Build) ![]const u8 {
        return b.root.root_dir.handle.realPathFileAlloc(b.graph.io, b.root.subPathOrDot(), b.allocator);
    }

    /// Reports whether a package the build runner was compiled without is now a Zig package on disk.
    ///
    /// - `b`: The root package's build graph.
    /// - `root`: Its absolute root.
    /// - `missing`: The runner's key for the missing package (its path from the root), or null when none is known.
    /// - Returns: `true` when its `build.zig` exists now.
    fn appearedOnDisk(b: *std.Build, root: []const u8, missing: ?[]const u8) bool {
        const path = missing orelse return false;
        const build_zig = std.Io.Dir.path.join(b.allocator, &.{ root, path, "build.zig" }) catch return false;
        return mod.File.exists(b.graph.io, build_zig) catch false;
    }

    /// Reports whether `path` is the `.path` of one of the root's `.archive` dependencies.
    ///
    /// - `zon`: The caller's `@import("build.zig.zon")`.
    /// - `path`: A key of the runner's package table.
    /// - Returns: `true` for a root archive's path.
    fn isRootArchive(comptime zon: anytype, comptime path: []const u8) bool {
        inline for (@typeInfo(@TypeOf(zon.dependencies)).@"struct".field_names) |field_name| {
            const dep = @field(zon.dependencies, field_name);
            const Dep = @TypeOf(dep);
            // The runner keys a `.path` package by its `.path` as the manifest writes it: compare as written.
            if (@hasField(Dep, "archive") and @hasField(Dep, "path") and std.mem.eql(u8, dep.path, path)) return true;
        }
        return false;
    }

    /// Reports whether every worktree dependency, transitive ones included, was present when the build runner was compiled.
    ///
    /// - `zon`: The caller's `@import("build.zig.zon")`; its `.archive` paths are skipped.
    /// - Returns: `true` when none is missing, or when the root is not a build runner.
    fn worktreesPresent(comptime zon: anytype) bool {
        return Self.missingWorktree(zon) == null;
    }

    /// Names the first package under `deps/` that was missing when the build runner was compiled.
    ///
    /// - `zon`: The caller's `@import("build.zig.zon")`; its `.archive` paths are skipped.
    /// - Returns: Its path from the root, or `null` when none is missing or the root is not a build runner.
    fn missingWorktree(comptime zon: anytype) ?[]const u8 {
        const root = @import("root");
        if (!@hasDecl(root, "dependencies")) return null;
        const decl_names = @typeInfo(root.dependencies.packages).@"struct".decl_names;
        // The default quota of 1000 runs out at a few dozen packages.
        @setEvalBranchQuota(1000 + decl_names.len * Self.branches_per_package);
        // A `.path` package is keyed by its path from the root: a worktree is any key under `deps/`, transitive ones included.
        for (decl_names) |decl_name| {
            if (Self.isUnderDeps(decl_name) and !@hasDecl(@field(root.dependencies.packages, decl_name), "build_zig") and !Self.isRootArchive(zon, decl_name)) return decl_name;
        }
        return null;
    }

    /// Reports whether every `.path` package outside `deps/`, transitive ones included, was present when the build runner was compiled.
    ///
    /// - `zon`: The caller's `@import("build.zig.zon")`; its `.archive` paths are skipped.
    /// - Returns: `true` when none is missing, or when the root is not a build runner.
    fn siblingsPresent(comptime zon: anytype) bool {
        return Self.missingSibling(zon) == null;
    }

    /// Names the first `.path` package outside `deps/` that was missing when the build runner was compiled.
    ///
    /// - `zon`: The caller's `@import("build.zig.zon")`; its `.archive` paths are skipped.
    /// - Returns: Its path from the root, or `null` when none is missing or the root is not a build runner.
    fn missingSibling(comptime zon: anytype) ?[]const u8 {
        const root = @import("root");
        if (!@hasDecl(root, "dependencies")) return null;
        const decl_names = @typeInfo(root.dependencies.packages).@"struct".decl_names;
        // The default quota of 1000 runs out at a dozen hashed packages, each compared along its whole key.
        @setEvalBranchQuota(1000 + decl_names.len * Self.branches_per_package);
        for (decl_names) |decl_name| {
            const package = @field(root.dependencies.packages, decl_name);
            // A present package, the usual case, is settled without comparing any paths.
            if (@hasDecl(package, "build_zig") or Self.isUnderDeps(decl_name)) continue;
            // A lazy dependency not fetched yet has no `build_root` at all: it is fetched when a build asks
            // for it, not missing. Checked before `build_root` is read, which would not compile.
            if (Self.isUnfetched(package)) continue;
            // A fetched package is keyed by its hash and lives in `zig-pkg/` or a cache, so it is not
            // mistaken for a missing sibling.
            if (Self.isFetched(package.build_root, decl_name)) continue;
            // The root's own archives are unpacked in the same build; a sibling's is unknown at comptime and costs a re-run.
            if (!Self.isRootArchive(zon, decl_name)) return decl_name;
        }
        return null;
    }

    /// Reports whether an entry of the build runner's package table is a lazy dependency not fetched yet.
    ///
    /// - `package`: The entry; the runner gives it a `build_root` only once the package is on disk.
    /// - Returns: `true` when it has none.
    fn isUnfetched(comptime package: type) bool {
        return !@hasDecl(package, "build_root");
    }

    /// Reports whether an entry of the build runner's package table is a fetched package, not a `.path` one.
    ///
    /// - `build_root`: The entry's `build_root`: relative to the build's working directory, or absolute.
    /// - `key`: The entry's key: a hash for a fetched package, a path for a `.path` one.
    /// - Returns: `true` when the package sits at `zig-pkg/<key>` or a cache's `p/<key>`.
    fn isFetched(build_root: []const u8, key: []const u8) bool {
        // Not an equality test: a `.path` package's root is `<dir of the build>/<key>`, which is the
        // key itself only when `zig build` runs in the root package's own directory.
        if (!std.mem.endsWith(u8, build_root, key) or build_root.len == key.len) return false;
        const parent = build_root[0 .. build_root.len - key.len];
        if (!std.Io.Dir.path.isSep(parent[parent.len - 1])) return false;
        const store = std.Io.Dir.path.basename(parent[0 .. parent.len - 1]);
        return std.mem.eql(u8, store, "zig-pkg") or std.mem.eql(u8, store, "p");
    }

    /// Reports whether a key of the build runner's package table is a path under the root's `deps/`.
    ///
    /// - `key`: A package's key; a `.path` package's is its path from the root, with the host's separator.
    /// - Returns: `true` for `deps/<x>` or `deps\<x>`.
    fn isUnderDeps(comptime key: []const u8) bool {
        return std.mem.startsWith(u8, key, "deps/") or std.mem.startsWith(u8, key, "deps\\");
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

const test_zon = .{
    .dependencies = .{
        .sibling = .{ .path = "../sibling", .clone = "git@example.com:sibling.git" },
        .local = .{ .path = "../local" },
        .fetched = .{ .url = "https://example.com/fetched.tar.gz", .hash = "fetched-0.0.0" },
        .unpacked = .{ .path = "../unpacked", .archive = "https://example.com/unpacked.zip" },
    },
};

test "isCloneable requires a path and a clone; an archive is not cloned" {
    try std.testing.expect(Deps.isCloneable(test_zon, "sibling"));
    try std.testing.expect(!Deps.isCloneable(test_zon, "unpacked"));
    try std.testing.expect(!Deps.isCloneable(test_zon, "local"));
    try std.testing.expect(!Deps.isCloneable(test_zon, "fetched"));
}

test "outside a build runner every dependency counts as present" {
    try std.testing.expect(Deps.isPresent("sibling"));
    try std.testing.expect(Deps.allPresent(test_zon));
    try std.testing.expect(Deps.allPresent(.{ .dependencies = .{} }));
    try std.testing.expect(Deps.worktreesPresent(test_zon));
}

test "isFetched tells a fetched package from a .path one, wherever zig build runs" {
    const hash = "zigbuildx-6.0.0-9koPhJjSBAAdyvyqYS1GYMx";
    try std.testing.expect(Deps.isFetched("zig-pkg/" ++ hash, hash));
    try std.testing.expect(Deps.isFetched("/abs/app/zig-pkg/" ++ hash, hash));
    try std.testing.expect(Deps.isFetched("/home/u/.cache/zig/p/" ++ hash, hash));
    try std.testing.expect(!Deps.isFetched("../liba", "../liba"));
    try std.testing.expect(!Deps.isFetched("/abs/app/../liba", "../liba"));
    try std.testing.expect(!Deps.isFetched("vendor", "vendor"));
    try std.testing.expect(!Deps.isFetched("/abs/app/vendor", "vendor"));
}

test "isUnfetched tells a lazy dependency not fetched yet from one on disk" {
    // Shaped as the build runner's package table writes them.
    const Unfetched = struct {
        /// The runner knows the package but has not fetched it.
        pub const available = false;
    };
    const Fetched = struct {
        /// The package is on disk.
        pub const available = true;
        /// Where it is.
        pub const build_root = "zig-pkg/lazy-0.0.0";
    };
    try std.testing.expect(Deps.isUnfetched(Unfetched));
    try std.testing.expect(!Deps.isUnfetched(Fetched));
}

test "restoreManifest puts the backup back once, and reports when there is none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = "rewritten" });
    try std.testing.expect(!try Deps.restoreManifest(allocator, io, root));
    try tmp.dir.writeFile(io, .{ .sub_path = mod.Stage.backup_name, .data = "original" });
    try std.testing.expect(try Deps.restoreManifest(allocator, io, root));
    try std.testing.expectEqualStrings("original", try tmp.dir.readFileAlloc(io, "build.zig.zon", allocator, .limited(64)));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, mod.Stage.backup_name, .{}));
    try std.testing.expect(!try Deps.restoreManifest(allocator, io, root));
}
