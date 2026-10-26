const std = @import("std");
const log = std.log.scoped(.zigbuildx_deps);
const mod = @import("module.zig");

/// What a worktree dependency is pinned to.
const PinKind = enum {
    /// A commit; the worktree is detached there.
    sha,
    /// A tag; the worktree is detached at its commit.
    tag,
    /// A branch; the worktree is on `<consumer>/<branch>`.
    branch,
};

/// A worktree dependency's pin.
const Pin = struct {
    const Self = @This();
    kind: PinKind,
    /// The SHA, tag or branch.
    value: []const u8,

    /// Reports whether a stamp recorded for `self` still satisfies `wanted`.
    ///
    /// Parameters:
    /// - `self`: the pin a stamp recorded.
    /// - `wanted`: the pin the manifest asks for now.
    ///
    /// Return: `true` when the kinds and values match.
    fn satisfies(self: *const Self, wanted: Pin) bool {
        return self.kind == wanted.kind and std.mem.eql(u8, self.value, wanted.value);
    }

    /// Reports whether the worktree sits on a branch rather than a detached HEAD.
    ///
    /// Parameters:
    /// - `self`: the pin.
    ///
    /// Return: `true` for `.branch`.
    fn follows(self: *const Self) bool {
        return self.kind == .branch;
    }
};

/// What `Deps` records about a worktree it made, in `<deps>/.zigbuildx/<name>.rev`.
///
/// The steady state compares this file with the manifest and runs no `git`.
const Stamp = struct {
    const Self = @This();
    /// The pin the worktree was made for.
    pin: Pin,
    /// HEAD when the worktree was created, moved or updated.
    sha: []const u8,
    /// The branch the worktree is on; empty when detached.
    branch: []const u8,
    /// The shared checkout that owns the worktree.
    checkout: []const u8,

    /// Parses a stamp file: kind, value, SHA, branch and checkout, one per line.
    ///
    /// Parameters:
    /// - `text`: the file contents; the result borrows from it.
    ///
    /// Return: the stamp; `null` when the file is not a stamp.
    fn parse(text: []const u8) ?Self {
        var lines = std.mem.splitScalar(u8, text, '\n');
        const kind = std.meta.stringToEnum(PinKind, lines.next() orelse return null) orelse return null;
        const value = lines.next() orelse return null;
        const sha = lines.next() orelse return null;
        const branch = lines.next() orelse return null;
        const checkout = lines.next() orelse return null;
        if (sha.len == 0 or checkout.len == 0) return null;
        return .{ .pin = .{ .kind = kind, .value = value }, .sha = sha, .branch = branch, .checkout = checkout };
    }

    /// Formats the stamp for its file.
    ///
    /// Parameters:
    /// - `self`: the stamp.
    /// - `allocator`: allocator for the text.
    ///
    /// Return: the text, owned by the caller.
    fn serialize(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        return allocator.print("{t}\n{s}\n{s}\n{s}\n{s}\n", .{ self.pin.kind, self.pin.value, self.sha, self.branch, self.checkout });
    }
};

/// One dependency of a `build.zig.zon`, reduced to the fields `Deps` reads.
const Entry = struct {
    const Self = @This();
    name: []const u8,
    path: ?[]const u8 = null,
    clone: ?[]const u8 = null,
    archive: ?[]const u8 = null,
    checkout: ?[]const u8 = null,
    sha: ?[]const u8 = null,
    tag: ?[]const u8 = null,
    branch: ?[]const u8 = null,
};

/// Where an absent `.path` dependency comes from.
const Source = union(enum) {
    /// A git repository to clone (`.clone`).
    clone: []const u8,
    /// A zip to download and unpack (`.archive`).
    archive: []const u8,
};

/// The parts of a `build.zig.zon` `Deps` reads at run time.
///
/// The root's manifest is also available at comptime, but a transitive
/// dependency's is not: it may not exist until `Deps` creates its worktree.
/// Reading every manifest from disk keeps one code path for both.
const Manifest = struct {
    const Self = @This();
    /// The package's `.name`.
    name: []const u8,
    /// The package's `.dependencies`, in manifest order.
    entries: []const Entry,

    /// Parses a manifest's `.name` and `.dependencies`, ignoring every other field.
    ///
    /// Parameters:
    /// - `allocator`: allocator for the result; use an arena, as nothing is freed individually.
    /// - `source`: the manifest text.
    ///
    /// Return: the manifest; `error.InvalidManifest` when it is not ZON of the expected shape.
    fn parse(allocator: std.mem.Allocator, source: [:0]const u8) !Self {
        var ast = try std.zig.Ast.parse(allocator, source, .{ .mode = .zon });
        defer ast.deinit(allocator);
        if (ast.errors.len > 0) return error.InvalidManifest;
        const zoir = try std.zig.ZonGen.generate(allocator, ast, .{});
        defer zoir.deinit(allocator);
        if (zoir.hasCompileErrors()) return error.InvalidManifest;
        const top = switch (std.zig.Zoir.Node.Index.root.get(&zoir)) {
            .struct_literal => |fields| fields,
            else => return error.InvalidManifest,
        };
        var self = Self{ .name = "", .entries = &.{} };
        for (top.names, 0..) |key, i| {
            const value = top.vals.at(@intCast(i)).get(&zoir);
            if (std.mem.eql(u8, key.get(&zoir), "name")) {
                self.name = try allocator.dupe(u8, switch (value) {
                    .enum_literal => |name| name.get(&zoir),
                    .string_literal => |name| name,
                    else => return error.InvalidManifest,
                });
            } else if (std.mem.eql(u8, key.get(&zoir), "dependencies")) {
                self.entries = try Self.parseEntries(allocator, &zoir, value);
            }
        }
        return self;
    }

    /// Parses the `.dependencies` struct literal.
    ///
    /// Parameters:
    /// - `allocator`: allocator for the result.
    /// - `zoir`: the manifest's ZON IR.
    /// - `node`: the `.dependencies` value.
    ///
    /// Return: the entries; `error.InvalidManifest` when a dependency is not a struct literal.
    fn parseEntries(allocator: std.mem.Allocator, zoir: *const std.zig.Zoir, node: std.zig.Zoir.Node) ![]const Entry {
        const deps = switch (node) {
            .struct_literal => |fields| fields,
            .empty_literal => return &.{},
            else => return error.InvalidManifest,
        };
        const entries = try allocator.alloc(Entry, deps.names.len);
        for (deps.names, entries, 0..) |name, *entry, i| {
            entry.* = .{ .name = try allocator.dupe(u8, name.get(zoir)) };
            const fields = switch (deps.vals.at(@intCast(i)).get(zoir)) {
                .struct_literal => |fields| fields,
                .empty_literal => continue,
                else => return error.InvalidManifest,
            };
            for (fields.names, 0..) |key, j| {
                const text = switch (fields.vals.at(@intCast(j)).get(zoir)) {
                    .string_literal => |text| text,
                    else => continue,
                };
                inline for (.{ "path", "clone", "archive", "checkout", "sha", "tag", "branch" }) |field| {
                    if (std.mem.eql(u8, key.get(zoir), field)) @field(entry, field) = try allocator.dupe(u8, text);
                }
            }
        }
        return entries;
    }
};

/// A worktree dependency, as the manifests declare it.
const Worktree = struct {
    const Self = @This();
    /// The dependency's name in the manifest that first declared it.
    name: []const u8,
    /// The worktree's absolute path: `<deps>/<base>`.
    dir: []const u8,
    /// The worktree's path relative to the consumer, for messages.
    rel: []const u8,
    /// What the worktree is pinned to.
    pin: Pin,
    /// The shared checkout's absolute path.
    checkout: []const u8,
    /// Where to clone the checkout from when it is absent.
    clone: ?[]const u8,
    /// The package whose manifest declared it.
    declared_by: []const u8,
    /// The branch prefix: `<consumer>`, or `<consumer>/<owner>` for a nested worktree.
    branch_prefix: []const u8,
    /// The stamp once the worktree is in place.
    stamp: ?Stamp = null,
};

/// Where a pin resolves to in a checkout.
const Target = struct {
    const Self = @This();
    /// The commit.
    sha: []const u8,
    /// The pin it resolves.
    pin: Pin,
    /// The worktree's branch; empty when it is detached.
    branch: []const u8,
};

/// What `Sync.update` did to the worktrees that follow a branch.
const Updated = struct {
    /// Worktrees fast-forwarded.
    moved: usize = 0,
    /// Worktrees skipped (uncommitted changes, commits of their own, branch
    /// gone) or whose checkout could not be fetched.
    failed: usize = 0,
};

/// One run of `Deps.sync`: reads the manifests and brings the worktrees in line with them.
///
/// All allocation goes through `allocator`, which should be an arena (the
/// build's, in a build); nothing is freed individually.
const Sync = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    io: std.Io,
    /// The consumer's absolute root.
    root: []const u8,
    /// The root package's `.name`.
    consumer: []const u8 = "",
    /// Every worktree dependency, the root's first.
    worktrees: std.ArrayList(Worktree) = .empty,
    /// Unpinned paths under a `deps` directory: used as is, and never orphans.
    unpinned: std.ArrayList([]const u8) = .empty,
    /// Unpinned sibling checkouts outside `deps/`, absolute, in the order found.
    siblings: std.ArrayList([]const u8) = .empty,
    /// How many of `siblings` have had their manifests read.
    walked: usize = 0,
    /// Paths unpacked from an `.archive`, absolute: no git checkouts, so never updated.
    archives: std.ArrayList([]const u8) = .empty,
    /// Orphans left in place, relative to the consumer.
    orphans: std.ArrayList([]const u8) = .empty,
    /// Whether anything was cloned, created or moved, so the build must re-run.
    changed: bool = false,
    /// Whether an archive was unpacked. That needs no re-run: nothing compiles
    /// an archive's Zig code, and its files are read only once the build runs.
    unpacked: bool = false,
    /// What went wrong, when a function returns `error.DepsFailed`.
    problem: []const u8 = "",

    /// Creates a run for the package at `root`.
    ///
    /// Parameters:
    /// - `allocator`: an arena for everything the run allocates.
    /// - `io`: IO for the filesystem and `git`.
    /// - `root`: the consumer's absolute root.
    ///
    /// Return: the run.
    fn init(allocator: std.mem.Allocator, io: std.Io, root: []const u8) !Self {
        return .{ .allocator = allocator, .io = io, .root = root };
    }

    /// Reads every manifest, then clones, creates, moves and removes until disk matches them.
    ///
    /// Parameters:
    /// - `self`: the run.
    ///
    /// Return: nothing; `error.DepsFailed` with `problem` set, or IO and spawn errors.
    fn run(self: *Self) !void {
        const manifest = try self.readManifest(self.root) orelse return self.fail("no build.zig.zon in {s}", .{self.root});
        self.consumer = manifest.name;
        try self.collect(manifest, self.root, self.root);
        try self.followSiblings();
        const deps = try std.Io.Dir.path.join(self.allocator, &.{ self.root, "deps" });
        if (self.worktrees.items.len == 0 and !try self.exists(deps)) return;
        const state = try std.Io.Dir.path.join(self.allocator, &.{ deps, ".zigbuildx" });
        try std.Io.Dir.cwd().createDirPath(self.io, state);
        const lock_path = try std.Io.Dir.path.join(self.allocator, &.{ state, "lock" });
        // Serialises concurrent builds of this consumer; released when the file closes.
        const lock = try std.Io.Dir.cwd().createFile(self.io, lock_path, .{ .lock = .exclusive });
        defer lock.close(self.io);
        // Transitive manifests are read as their worktrees appear, so the list grows while it is walked.
        var i: usize = 0;
        while (i < self.worktrees.items.len) : (i += 1) {
            try self.ensure(i);
            const worktree = self.worktrees.items[i];
            const declared = try self.readManifest(worktree.dir) orelse continue;
            try self.collect(declared, worktree.dir, worktree.checkout);
        }
        try self.followSiblings();
        try self.removeOrphans();
    }

    /// Records `manifest`'s worktree dependencies and, for the root, clones missing sibling checkouts.
    ///
    /// A dependency is **pinned** when it sets `.sha`, `.tag` or `.branch`; it
    /// becomes a worktree, and its `.path`, resolved from the declaring
    /// package, must be a direct child of a `deps` directory inside the
    /// consumer. An **unpinned** dependency's `.path` is used as is, wherever
    /// it points. The first declaration of a path wins, pinned or not; a later
    /// one that pins it differently is ignored with a warning. An `.archive`
    /// dependency is pinned by its URL alone, so it may not set a pin field.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `manifest`: the declaring package's manifest.
    /// - `dir`: where the declaring package is on disk.
    /// - `home`: where the declaring package's own checkout is; its
    ///   `.checkout` paths are relative to this, not to a worktree of it.
    ///
    /// Return: nothing; `error.DepsFailed` on a malformed root entry, or clone errors.
    fn collect(self: *Self, manifest: Manifest, dir: []const u8, home: []const u8) !void {
        const is_root = std.mem.eql(u8, dir, self.root);
        for (manifest.entries) |entry| {
            const pin = try self.pinOf(manifest.name, entry);
            const source = try self.sourceOf(manifest.name, entry);
            const archive = if (source) |from| from == .archive else false;
            if (pin != null and archive) return self.fail("{s} pins {s}, but an .archive dependency is pinned by its URL alone", .{ manifest.name, entry.name });
            const path = entry.path orelse {
                if (pin != null and is_root) return self.fail("{s} pins {s}, which is not a worktree dependency (its .path must be under deps/)", .{ manifest.name, entry.name });
                if (archive and is_root) return self.fail("{s} names an .archive for {s}, which has no .path to unpack it at", .{ manifest.name, entry.name });
                continue;
            };
            const resolved = try std.Io.Dir.path.resolveAlloc(self.allocator, &.{ dir, path });
            const pinnable = self.isWorktreePath(resolved);
            if (pin != null and !pinnable) {
                if (is_root) return self.fail("{s} pins {s}, but a pinned dependency's .path must be under deps/", .{ manifest.name, entry.name });
                continue;
            }
            const rel = try std.Io.Dir.path.relativeAlloc(self.allocator, self.root, null, self.root, resolved);
            // The first declaration of a path wins, pinned or not.
            if (self.find(resolved)) |existing| {
                if (pin) |wanted| if (!existing.pin.satisfies(wanted)) log.warn("{s} pins {s} to {t} {s}; using {s}'s {t} {s}", .{ manifest.name, existing.rel, wanted.kind, wanted.value, existing.declared_by, existing.pin.kind, existing.pin.value });
                continue;
            }
            if (self.isUnpinned(resolved)) {
                if (pin) |wanted| log.warn("{s} pins {s} to {t} {s}; using the path as is, as an earlier declaration does", .{ manifest.name, rel, wanted.kind, wanted.value });
                continue;
            }
            // Unpinned: the path is used as is. Under deps/ the root clones or
            // unpacks it when absent, as cloneMissing does; a sibling outside
            // deps/ is fetched whoever declares it, and its own dependencies
            // are followed.
            const wanted = pin orelse {
                if (!pinnable) {
                    try self.addSibling(resolved, source);
                    continue;
                }
                try self.unpinned.append(self.allocator, resolved);
                if (is_root) if (source) |from| try self.materialize(resolved, from);
                continue;
            };
            try self.worktrees.append(self.allocator, .{
                .name = entry.name,
                .dir = resolved,
                .rel = rel,
                .pin = wanted,
                .checkout = try std.Io.Dir.path.resolveAlloc(self.allocator, &.{ home, entry.checkout orelse try self.allocator.print("../{s}", .{entry.name}) }),
                .clone = entry.clone,
                .declared_by = manifest.name,
                .branch_prefix = try self.branchPrefix(rel),
            });
        }
    }

    /// Reads an entry's pin fields.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `package`: the declaring package, for the message.
    /// - `entry`: the dependency.
    ///
    /// Return: the pin, or `null` when it sets none; `error.DepsFailed` when it sets more than one.
    fn pinOf(self: *Self, package: []const u8, entry: Entry) !?Pin {
        var pin: ?Pin = null;
        var count: usize = 0;
        inline for (.{ "sha", "tag", "branch" }) |field| {
            if (@field(entry, field)) |value| {
                pin = .{ .kind = @field(PinKind, field), .value = value };
                count += 1;
            }
        }
        if (count > 1) return self.fail("{s}: {s} sets more than one of .sha, .tag and .branch", .{ package, entry.name });
        return pin;
    }

    /// Reads where an entry is fetched from when it is absent.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `package`: the declaring package, for the message.
    /// - `entry`: the dependency.
    ///
    /// Return: the source, or `null` when it names none; `error.DepsFailed`
    /// when it sets both `.clone` and `.archive`.
    fn sourceOf(self: *Self, package: []const u8, entry: Entry) !?Source {
        if (entry.clone != null and entry.archive != null) return self.fail("{s}: {s} sets both .clone and .archive", .{ package, entry.name });
        if (entry.clone) |url| return .{ .clone = url };
        if (entry.archive) |url| return .{ .archive = url };
        return null;
    }

    /// Reports whether `path` is a direct child of a `deps` directory inside the consumer.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `path`: an absolute, resolved path.
    ///
    /// Return: `true` for a worktree dependency's path.
    fn isWorktreePath(self: *const Self, path: []const u8) bool {
        const parent = std.Io.Dir.path.dirname(path) orelse return false;
        if (!std.mem.eql(u8, std.Io.Dir.path.basename(parent), "deps")) return false;
        return std.mem.startsWith(u8, parent, self.root) and parent.len > self.root.len and std.Io.Dir.path.isSep(parent[self.root.len]);
    }

    /// Builds the branch prefix for a worktree at `rel`.
    ///
    /// `deps/x` gets `<consumer>`; a nested `deps/mid/deps/x` gets
    /// `<consumer>/mid`, so two worktrees of one checkout never want the same branch.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `rel`: the worktree's path relative to the consumer.
    ///
    /// Return: the prefix.
    fn branchPrefix(self: *const Self, rel: []const u8) ![]const u8 {
        var prefix: std.ArrayList(u8) = .empty;
        try prefix.appendSlice(self.allocator, self.consumer);
        var parts = std.mem.tokenizeAny(u8, std.Io.Dir.path.dirname(rel) orelse "", "/\\");
        while (parts.next()) |part| {
            if (std.mem.eql(u8, part, "deps")) continue;
            try prefix.append(self.allocator, '/');
            try prefix.appendSlice(self.allocator, part);
        }
        return prefix.items;
    }

    /// Finds the worktree recorded at `dir`.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `dir`: an absolute worktree path.
    ///
    /// Return: the worktree, or `null`.
    fn find(self: *const Self, dir: []const u8) ?*const Worktree {
        for (self.worktrees.items) |*worktree| {
            if (std.mem.eql(u8, worktree.dir, dir)) return worktree;
        }
        return null;
    }

    /// Reports whether `dir` was declared unpinned.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `dir`: an absolute path.
    ///
    /// Return: `true` when an earlier declaration names it with no pin.
    fn isUnpinned(self: *const Self, dir: []const u8) bool {
        for (self.unpinned.items) |path| {
            if (std.mem.eql(u8, path, dir)) return true;
        }
        return false;
    }

    /// Clones or unpacks an unpinned dependency from `source`, as `cloneMissing` does.
    ///
    /// A clone happens only when the path is absent. An archive is also
    /// unpacked again when its URL changed; see `ensureArchive`.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `path`: the dependency's absolute path.
    /// - `source`: where it comes from.
    ///
    /// Return: nothing; `error.DepsFailed` for an archive, or clone errors, which `Git.clone` logs.
    fn materialize(self: *Self, path: []const u8, source: Source) !void {
        switch (source) {
            .clone => |url| {
                if (try self.exists(path)) return;
                try mod.Git.clone(self.io, url, path);
                self.changed = true;
            },
            .archive => |url| try self.ensureArchive(path, url),
        }
    }

    /// Unpacks an `.archive` dependency when it is absent or was unpacked from another URL.
    ///
    /// The directory's stamp records its URL, so an unchanged one costs a
    /// file read and no download. A directory without a stamp is not
    /// zigbuildx's to replace.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `path`: the dependency's absolute path.
    /// - `url`: the zip's URL.
    ///
    /// Return: nothing; `error.DepsFailed` when the path holds something else
    /// or the archive cannot be fetched, or IO errors.
    fn ensureArchive(self: *Self, path: []const u8, url: []const u8) !void {
        if (!self.isArchive(path)) try self.archives.append(self.allocator, path);
        const rel = try std.Io.Dir.path.relativeAlloc(self.allocator, self.root, null, self.root, path);
        if (try self.exists(path)) {
            const unpacked = try mod.ZipArchive.source(self.allocator, self.io, path) orelse {
                return self.fail("{s} exists but zigbuildx did not unpack it (it has no {s}); move it aside and re-run", .{ rel, mod.ZipArchive.stamp_name });
            };
            if (std.mem.eql(u8, unpacked, url)) return;
            log.info("{s} was unpacked from {s}; replacing it", .{ rel, unpacked });
        }
        mod.ZipArchive.unpack(self.allocator, self.io, url, path) catch |err| {
            return self.fail("cannot unpack {s} into {s} [{any}]", .{ url, rel, err });
        };
        self.unpacked = true;
    }

    /// Reports whether `dir` was unpacked from an `.archive`.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `dir`: an absolute path.
    ///
    /// Return: `true` when an `.archive` dependency names it.
    fn isArchive(self: *const Self, dir: []const u8) bool {
        for (self.archives.items) |path| {
            if (std.mem.eql(u8, path, dir)) return true;
        }
        return false;
    }

    /// Queues the sibling at `path`, cloning or unpacking it from `source` as `materialize` does.
    ///
    /// Each path is queued once, so a cycle of siblings ends. One that is absent
    /// with no `source` is left for Zig to report.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `path`: the dependency's absolute path.
    /// - `source`: where it comes from, if anywhere.
    ///
    /// Return: nothing; `error.DepsFailed` for an archive, or clone errors, which `Git.clone` logs.
    fn addSibling(self: *Self, path: []const u8, source: ?Source) !void {
        for (self.siblings.items) |seen| {
            if (std.mem.eql(u8, seen, path)) return;
        }
        try self.siblings.append(self.allocator, path);
        try self.materialize(path, source orelse return);
    }

    /// Reads each queued sibling's manifest and queues its unpinned `.path` dependencies outside `deps/`.
    ///
    /// Zig opens every `.path` package in the tree before `build()` can run, so
    /// a sibling's own sibling must be on disk too, though only the root runs
    /// `Deps`. A pinned dependency of a sibling belongs to that sibling's
    /// `deps/`, not the consumer's, and is left alone. Siblings queued while
    /// this runs are walked in the same pass.
    ///
    /// Parameters:
    /// - `self`: the run.
    ///
    /// Return: nothing; `error.DepsFailed` when a manifest does not parse, or IO and clone errors.
    fn followSiblings(self: *Self) !void {
        while (self.walked < self.siblings.items.len) : (self.walked += 1) {
            const dir = self.siblings.items[self.walked];
            const manifest = try self.readManifest(dir) orelse continue;
            for (manifest.entries) |entry| {
                const path = entry.path orelse continue;
                if (entry.sha != null or entry.tag != null or entry.branch != null) continue;
                const resolved = try std.Io.Dir.path.resolveAlloc(self.allocator, &.{ dir, path });
                if (self.isWorktreePath(resolved)) continue;
                try self.addSibling(resolved, try self.sourceOf(manifest.name, entry));
            }
        }
    }

    /// Clones or unpacks every absent `.path` dependency of the root, then of its siblings, as `cloneMissing` does.
    ///
    /// The root's entries are cloned whatever they pin, as `cloneMissing`
    /// always has; no worktree is made.
    ///
    /// Parameters:
    /// - `self`: the run.
    ///
    /// Return: nothing; `error.DepsFailed` with `problem` set, or IO and clone errors.
    fn cloneSiblings(self: *Self) !void {
        const manifest = try self.readManifest(self.root) orelse return self.fail("no build.zig.zon in {s}", .{self.root});
        for (manifest.entries) |entry| {
            const path = entry.path orelse continue;
            try self.addSibling(try std.Io.Dir.path.resolveAlloc(self.allocator, &.{ self.root, path }), try self.sourceOf(manifest.name, entry));
        }
        try self.followSiblings();
    }

    /// Fetches every sibling checkout and fast-forwards each one that is behind its upstream.
    ///
    /// Siblings are the developer's own checkouts, so one is left alone, with
    /// a warning, when it has uncommitted changes or commits its upstream
    /// lacks; and quietly when it is not a repository of its own, is on a
    /// detached HEAD, or its branch has no upstream. A fetch that fails (say,
    /// offline) skips that sibling too. None of these fail the build.
    ///
    /// Parameters:
    /// - `self`: the run, after `run` or `cloneSiblings` has queued the siblings.
    ///
    /// Return: whether any sibling moved; IO errors.
    fn updateSiblings(self: *Self) !bool {
        var moved = false;
        for (self.siblings.items) |dir| {
            // An archive's URL is its pin: `ensureArchive` has already brought it in line.
            if (self.isArchive(dir)) continue;
            const rel = try std.Io.Dir.path.relativeAlloc(self.allocator, self.root, null, self.root, dir);
            // A directory inside some other repository is not its own checkout: leave that repository alone.
            if (!try self.exists(try std.Io.Dir.path.join(self.allocator, &.{ dir, ".git" }))) {
                log.info("not updating {s}: it is not a git checkout", .{rel});
                continue;
            }
            const branch = (mod.Git.currentBranch(self.allocator, self.io, dir) catch continue) orelse {
                log.info("not updating {s}: HEAD is detached", .{rel});
                continue;
            };
            if ((mod.Git.upstream(self.allocator, self.io, dir) catch continue) == null) {
                log.info("not updating {s}: {s} has no upstream branch", .{ rel, branch });
                continue;
            }
            mod.Git.fetch(self.allocator, self.io, dir) catch {
                log.warn("not updating {s}: git fetch failed", .{rel});
                continue;
            };
            const tip = (mod.Git.upstream(self.allocator, self.io, dir) catch null) orelse continue;
            const head = (mod.Git.revParse(self.allocator, self.io, dir, "HEAD") catch null) orelse continue;
            if (std.mem.eql(u8, tip, head)) continue;
            const clean = mod.Git.isClean(self.allocator, self.io, dir) catch false;
            const ahead = mod.Git.isAhead(self.allocator, self.io, dir, tip) catch true;
            if (!clean or ahead) {
                log.warn("not updating {s}: {s} has {s}", .{ rel, branch, if (!clean) "uncommitted changes" else "commits its upstream lacks" });
                continue;
            }
            mod.Git.fastForward(self.allocator, self.io, dir, tip) catch continue;
            log.info("updated {s} ({s}) from {s} to {s}", .{ rel, branch, Self.short(head), Self.short(tip) });
            moved = true;
        }
        return moved;
    }

    /// Brings worktree `index` in line with its pin: creates it, moves it, or leaves it.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `index`: the worktree's index in `worktrees`.
    ///
    /// Return: nothing; `error.DepsFailed` when it cannot be brought in line, or IO and git errors.
    fn ensure(self: *Self, index: usize) !void {
        const worktree = &self.worktrees.items[index];
        const stamp = try self.readStamp(worktree.dir);
        if (!try self.exists(worktree.dir)) {
            // A stamp without its directory is from a worktree deleted by hand; it is replaced.
            try self.create(worktree);
        } else if (stamp) |found| {
            if (found.pin.satisfies(worktree.pin)) {
                worktree.stamp = found;
            } else {
                try self.move(worktree, found);
            }
        } else {
            return self.fail("{s} exists but zigbuildx did not create it (it has no stamp); move it aside and re-run", .{worktree.rel});
        }
        const build_zig = try std.Io.Dir.path.join(self.allocator, &.{ worktree.dir, "build.zig" });
        if (!try self.exists(build_zig)) return self.fail("{s} has no build.zig; a worktree dependency must be a Zig package", .{worktree.rel});
    }

    /// Creates a worktree, cloning its checkout first when that is absent.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `worktree`: the worktree to create; its `stamp` is set.
    ///
    /// Return: nothing; `error.DepsFailed`, or IO and git errors.
    fn create(self: *Self, worktree: *Worktree) !void {
        if (!try self.exists(worktree.checkout)) {
            const url = worktree.clone orelse return self.fail("{s} needs the checkout {s}, which is missing, and {s} has no .clone", .{ worktree.rel, worktree.checkout, worktree.name });
            try mod.Git.clone(self.io, url, worktree.checkout);
        }
        const target = try self.resolve(worktree);
        try mod.Git.worktreePrune(self.allocator, self.io, worktree.checkout);
        try std.Io.Dir.cwd().createDirPath(self.io, std.Io.Dir.path.dirname(worktree.dir).?);
        if (target.branch.len == 0) {
            try mod.Git.worktreeAdd(self.allocator, self.io, worktree.checkout, worktree.dir, .{ .detached = target.sha });
        } else {
            // An existing branch is left by a worktree deleted by hand: reuse it as is, keeping its commits.
            const reuse = try mod.Git.branchExists(self.allocator, self.io, worktree.checkout, target.branch);
            try mod.Git.worktreeAdd(self.allocator, self.io, worktree.checkout, worktree.dir, .{ .branch = .{ .name = target.branch, .start = if (reuse) null else target.sha } });
        }
        try self.writeStamp(worktree, target);
        log.info("created {s} at {t} {s}", .{ worktree.rel, target.pin.kind, target.pin.value });
        self.changed = true;
    }

    /// Moves an existing worktree to a new pin, unless it has work of its own.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `worktree`: the worktree; its `stamp` is set.
    /// - `old`: the stamp it was created or last moved with.
    ///
    /// Return: nothing; `error.DepsFailed` when it is dirty or ahead, or IO and git errors.
    fn move(self: *Self, worktree: *Worktree, old: Stamp) !void {
        if (!try mod.Git.isClean(self.allocator, self.io, worktree.dir)) {
            return self.fail("{s} is now pinned to {t} {s}, but it has uncommitted changes on {t} {s}; commit or discard them, then re-run", .{ worktree.rel, worktree.pin.kind, worktree.pin.value, old.pin.kind, old.pin.value });
        }
        if (try mod.Git.isAhead(self.allocator, self.io, worktree.dir, old.sha)) {
            return self.fail("{s} is now pinned to {t} {s}, but it has commits beyond {s} ({t} {s}); push or drop them, then re-run", .{ worktree.rel, worktree.pin.kind, worktree.pin.value, Self.short(old.sha), old.pin.kind, old.pin.value });
        }
        const target = try self.resolve(worktree);
        if (target.branch.len == 0) {
            try mod.Git.checkoutDetached(self.allocator, self.io, worktree.dir, target.sha);
        } else {
            const reuse = try mod.Git.branchExists(self.allocator, self.io, worktree.dir, target.branch);
            try mod.Git.checkoutBranch(self.allocator, self.io, worktree.dir, target.branch, if (reuse) null else target.sha);
        }
        try self.writeStamp(worktree, target);
        log.info("moved {s} from {t} {s} to {t} {s}", .{ worktree.rel, old.pin.kind, old.pin.value, target.pin.kind, target.pin.value });
        self.changed = true;
    }

    /// Resolves a worktree's pin in its checkout, fetching once when the revision is not there.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `worktree`: the worktree.
    ///
    /// Return: the target; `error.DepsFailed` when the revision is not found, or git errors.
    fn resolve(self: *Self, worktree: *const Worktree) !Target {
        const pin = worktree.pin;
        const sha = try self.lookup(worktree.checkout, pin) orelse blk: {
            try mod.Git.fetch(self.allocator, self.io, worktree.checkout);
            break :blk try self.lookup(worktree.checkout, pin);
        } orelse return self.fail("{s}: {t} {s} is not in {s}, even after git fetch", .{ worktree.rel, pin.kind, pin.value, worktree.checkout });
        const branch = if (pin.follows()) try self.allocator.print("{s}/{s}", .{ worktree.branch_prefix, pin.value }) else "";
        return .{ .sha = sha, .pin = pin, .branch = branch };
    }

    /// Looks a resolved pin up in a checkout without fetching.
    ///
    /// A branch is looked up on `origin` first, then locally, so a checkout with no remote still works.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `checkout`: the checkout.
    /// - `pin`: the pin.
    ///
    /// Return: the commit, or `null` when it is not there; git errors.
    fn lookup(self: *const Self, checkout: []const u8, pin: Pin) !?[]const u8 {
        return switch (pin.kind) {
            .sha => mod.Git.revParse(self.allocator, self.io, checkout, pin.value),
            .tag => mod.Git.revParse(self.allocator, self.io, checkout, try self.allocator.print("refs/tags/{s}", .{pin.value})),
            .branch => try mod.Git.revParse(self.allocator, self.io, checkout, try self.allocator.print("refs/remotes/origin/{s}", .{pin.value})) orelse
                try mod.Git.revParse(self.allocator, self.io, checkout, try self.allocator.print("refs/heads/{s}", .{pin.value})),
        };
    }

    /// Removes worktrees whose stamps no dependency claims any more, when they hold no work.
    ///
    /// Parameters:
    /// - `self`: the run.
    ///
    /// Return: nothing; IO errors. Git failures are logged and leave the orphan in place.
    fn removeOrphans(self: *Self) !void {
        var dirs: std.ArrayList([]const u8) = .empty;
        try dirs.append(self.allocator, try std.Io.Dir.path.join(self.allocator, &.{ self.root, "deps" }));
        for (self.worktrees.items) |worktree| {
            const parent = std.Io.Dir.path.dirname(worktree.dir).?;
            for (dirs.items) |dir| {
                if (std.mem.eql(u8, dir, parent)) break;
            } else try dirs.append(self.allocator, parent);
        }
        for (dirs.items) |deps| {
            const state = try std.Io.Dir.path.join(self.allocator, &.{ deps, ".zigbuildx" });
            var dir = std.Io.Dir.cwd().openDir(self.io, state, .{ .iterate = true }) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            defer dir.close(self.io);
            var names: std.ArrayList([]const u8) = .empty;
            var it = dir.iterate();
            while (try it.next(self.io)) |item| {
                if (item.kind == .file and std.mem.endsWith(u8, item.name, ".rev")) try names.append(self.allocator, try self.allocator.dupe(u8, item.name));
            }
            for (names.items) |name| {
                const path = try std.Io.Dir.path.join(self.allocator, &.{ deps, name[0 .. name.len - ".rev".len] });
                // A path still declared unpinned keeps what is there; its old stamp is left alone.
                if (self.find(path) == null and !self.isUnpinned(path)) try self.removeOrphan(path);
            }
        }
    }

    /// Removes one orphaned worktree, its branch and its stamp, or leaves it with a warning.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `path`: the orphan's absolute path.
    ///
    /// Return: nothing; IO errors.
    fn removeOrphan(self: *Self, path: []const u8) !void {
        const rel = try std.Io.Dir.path.relativeAlloc(self.allocator, self.root, null, self.root, path);
        const stamp = try self.readStamp(path) orelse {
            log.warn("{s} is no longer a dependency, but its stamp is unreadable; left in place", .{rel});
            try self.orphans.append(self.allocator, rel);
            return;
        };
        if (try self.exists(path)) {
            const clean = mod.Git.isClean(self.allocator, self.io, path) catch false;
            const ahead = mod.Git.isAhead(self.allocator, self.io, path, stamp.sha) catch true;
            if (!clean or ahead) {
                log.warn("{s} is no longer a dependency, but it has {s}; left in place", .{ rel, if (!clean) "uncommitted changes" else "commits of its own" });
                try self.orphans.append(self.allocator, rel);
                return;
            }
            mod.Git.worktreeRemove(self.allocator, self.io, stamp.checkout, path) catch {
                try self.orphans.append(self.allocator, rel);
                return;
            };
        } else {
            mod.Git.worktreePrune(self.allocator, self.io, stamp.checkout) catch log.warn("cannot prune worktrees in {s}", .{stamp.checkout});
        }
        if (stamp.branch.len > 0) {
            mod.Git.branchDelete(self.allocator, self.io, stamp.checkout, stamp.branch) catch log.warn("kept branch {s} in {s}: git refused to delete it", .{ stamp.branch, stamp.checkout });
        }
        try std.Io.Dir.cwd().deleteFile(self.io, try self.stampPath(path));
        log.info("removed orphaned {s}", .{rel});
    }

    /// Fetches and fast-forwards every worktree that follows a branch.
    ///
    /// Checkouts behind a tag pin are fetched too, so `status` can report a
    /// tag moved upstream; those worktrees do not move. A worktree with
    /// uncommitted changes or commits of its own is skipped with a warning,
    /// and counted.
    ///
    /// Parameters:
    /// - `self`: the run, after `run`.
    ///
    /// Return: how many worktrees moved, and how many were skipped or failed; IO errors.
    fn update(self: *const Self) !Updated {
        var updated: Updated = .{};
        var fetched: std.ArrayList([]const u8) = .empty;
        for (self.worktrees.items) |*worktree| {
            const stamp = worktree.stamp orelse continue;
            if (stamp.pin.kind == .sha) continue;
            for (fetched.items) |checkout| {
                if (std.mem.eql(u8, checkout, stamp.checkout)) break;
            } else {
                mod.Git.fetch(self.allocator, self.io, stamp.checkout) catch {
                    updated.failed += 1;
                    continue;
                };
                try fetched.append(self.allocator, stamp.checkout);
            }
            if (!stamp.pin.follows()) continue;
            const tip = (self.lookup(stamp.checkout, stamp.pin) catch null) orelse {
                log.warn("skipped {s}: branch {s} is gone from {s}", .{ worktree.rel, stamp.pin.value, stamp.checkout });
                updated.failed += 1;
                continue;
            };
            if (std.mem.eql(u8, tip, stamp.sha)) continue;
            const clean = mod.Git.isClean(self.allocator, self.io, worktree.dir) catch false;
            const ahead = mod.Git.isAhead(self.allocator, self.io, worktree.dir, stamp.sha) catch true;
            if (!clean or ahead) {
                log.warn("skipped {s}: it has {s}", .{ worktree.rel, if (!clean) "uncommitted changes" else "commits of its own" });
                updated.failed += 1;
                continue;
            }
            mod.Git.fastForward(self.allocator, self.io, worktree.dir, tip) catch {
                updated.failed += 1;
                continue;
            };
            try self.writeStamp(worktree, .{ .sha = tip, .pin = stamp.pin, .branch = stamp.branch });
            log.info("updated {s} to {s}", .{ worktree.rel, Self.short(tip) });
            updated.moved += 1;
        }
        return updated;
    }

    /// Writes one line per worktree: path, pin, SHA, and clean, dirty or ahead; then the orphans left in place.
    ///
    /// Parameters:
    /// - `self`: the run, after `run`.
    /// - `writer`: where the lines go.
    ///
    /// Return: nothing; write errors.
    fn status(self: *const Self, writer: *std.Io.Writer) !void {
        for (self.worktrees.items) |worktree| {
            const stamp = worktree.stamp orelse continue;
            const clean: ?bool = mod.Git.isClean(self.allocator, self.io, worktree.dir) catch null;
            const ahead = mod.Git.isAhead(self.allocator, self.io, worktree.dir, stamp.sha) catch false;
            const state = if (clean) |is_clean| (if (is_clean) "clean" else "dirty") else "unknown";
            try writer.print("{s}  {t} {s}  {s}  {s}{s}", .{ worktree.rel, stamp.pin.kind, stamp.pin.value, Self.short(stamp.sha), state, if (ahead) ", ahead" else "" });
            if (stamp.pin.kind == .tag) {
                const now = self.lookup(stamp.checkout, stamp.pin) catch null;
                if (now) |sha| if (!std.mem.eql(u8, sha, stamp.sha)) try writer.print("  (tag moved upstream to {s}; not followed)", .{Self.short(sha)});
            }
            try writer.writeByte('\n');
        }
        for (self.orphans.items) |rel| try writer.print("{s}  orphaned\n", .{rel});
    }

    /// Reads the manifest in `dir`.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `dir`: a package directory.
    ///
    /// Return: the manifest, or `null` when there is none; `error.DepsFailed`
    /// when it does not parse, or IO errors.
    fn readManifest(self: *Self, dir: []const u8) !?Manifest {
        const path = try std.Io.Dir.path.join(self.allocator, &.{ dir, "build.zig.zon" });
        const source = std.Io.Dir.cwd().readFileAllocOptions(self.io, path, self.allocator, .limited(1 << 20), .of(u8), 0) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        return Manifest.parse(self.allocator, source) catch |err| switch (err) {
            error.InvalidManifest => return self.fail("cannot parse {s}", .{path}),
            else => return err,
        };
    }

    /// Returns the stamp path for the worktree at `dir`: `<deps>/.zigbuildx/<name>.rev`.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `dir`: the worktree's absolute path.
    ///
    /// Return: the stamp's absolute path.
    fn stampPath(self: *const Self, dir: []const u8) ![]const u8 {
        const name = try self.allocator.print("{s}.rev", .{std.Io.Dir.path.basename(dir)});
        return std.Io.Dir.path.join(self.allocator, &.{ std.Io.Dir.path.dirname(dir).?, ".zigbuildx", name });
    }

    /// Reads the stamp for the worktree at `dir`.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `dir`: the worktree's absolute path.
    ///
    /// Return: the stamp, or `null` when there is none or it does not parse; IO errors.
    fn readStamp(self: *const Self, dir: []const u8) !?Stamp {
        const text = std.Io.Dir.cwd().readFileAlloc(self.io, try self.stampPath(dir), self.allocator, .limited(1 << 16)) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        return Stamp.parse(text);
    }

    /// Records the worktree's HEAD and pin in its stamp, and on the worktree.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `worktree`: the worktree; its `stamp` is set.
    /// - `target`: where it now is.
    ///
    /// Return: nothing; IO and git errors.
    fn writeStamp(self: *const Self, worktree: *Worktree, target: Target) !void {
        const head = try mod.Git.revParse(self.allocator, self.io, worktree.dir, "HEAD") orelse target.sha;
        const stamp = Stamp{ .pin = target.pin, .sha = head, .branch = target.branch, .checkout = worktree.checkout };
        const path = try self.stampPath(worktree.dir);
        try std.Io.Dir.cwd().createDirPath(self.io, std.Io.Dir.path.dirname(path).?);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = try stamp.serialize(self.allocator) });
        worktree.stamp = stamp;
    }

    /// Reports whether `path` exists.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `path`: an absolute path.
    ///
    /// Return: `true` when it exists; IO errors other than "not found".
    fn exists(self: *const Self, path: []const u8) !bool {
        std.Io.Dir.cwd().access(self.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }

    /// Shortens a SHA for messages.
    ///
    /// Parameters:
    /// - `sha`: a full or short SHA.
    ///
    /// Return: its first 12 characters.
    fn short(sha: []const u8) []const u8 {
        return sha[0..@min(sha.len, 12)];
    }

    /// Records why the run failed, for the caller to log.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `fmt`: the message format.
    /// - `args`: its arguments.
    ///
    /// Return: always `error.DepsFailed`, or `error.OutOfMemory`.
    fn fail(self: *Self, comptime fmt: []const u8, args: anytype) error{ DepsFailed, OutOfMemory } {
        self.problem = try self.allocator.print(fmt, args);
        return error.DepsFailed;
    }
};

/// The file a failed compile leaves behind, so the next build updates its dependencies.
///
/// It lives at `<root>/.zig-cache/zigbuildx/update`, a fixed path: the
/// configure phase cannot learn where the local cache really is, and the
/// marks are written by the host tool, which is given the root. A
/// `--cache-dir` elsewhere leaves it there all the same.
const Breadcrumb = struct {
    const Self = @This();

    /// Its directory relative to the package root, as `b.path` takes it.
    ///
    /// The configure phase tracks this directory's contents rather than the
    /// file: Zig 0.17 fails configuration (`FileSystemFailure`) on a tracked
    /// file that is missing, despite `dependOnFileMetadata`'s doc comment.
    /// The directory holds nothing else, so it is empty after every build
    /// that compiled, and the configure cache holds.
    const dir_sub_path = ".zig-cache/zigbuildx";

    /// What the file says, for whoever finds it.
    const contents = "A zig build failed to compile; the next zig build fetches and fast-forwards its dependencies, then deletes this file.\n";

    /// Returns the breadcrumb's absolute path for the package at `root`.
    ///
    /// Parameters:
    /// - `allocator`: allocator for the path.
    /// - `root`: the package's absolute root.
    ///
    /// Return: the path, owned by the caller.
    fn path(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
        return std.Io.Dir.path.join(allocator, &.{ root, ".zig-cache", "zigbuildx", "update" });
    }

    /// Creates the breadcrumb's directory, so the configure phase can track it.
    ///
    /// Parameters:
    /// - `io`: IO for the filesystem.
    /// - `file`: the breadcrumb's absolute path.
    ///
    /// Return: nothing; IO errors.
    fn prepare(io: std.Io, file: []const u8) !void {
        try std.Io.Dir.cwd().createDirPath(io, std.Io.Dir.path.dirname(file).?);
    }

    /// Leaves the breadcrumb.
    ///
    /// Parameters:
    /// - `io`: IO for the filesystem.
    /// - `file`: its absolute path.
    ///
    /// Return: nothing; IO errors.
    fn set(io: std.Io, file: []const u8) !void {
        try Self.prepare(io, file);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = Self.contents });
    }

    /// Removes the breadcrumb, if it is there.
    ///
    /// Parameters:
    /// - `io`: IO for the filesystem.
    /// - `file`: its absolute path.
    ///
    /// Return: nothing; IO errors other than "not found".
    fn clear(io: std.Io, file: []const u8) !void {
        std.Io.Dir.cwd().deleteFile(io, file) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    /// Reports whether the breadcrumb is there.
    ///
    /// Parameters:
    /// - `io`: IO for the filesystem.
    /// - `file`: its absolute path.
    ///
    /// Return: `true` when it exists; IO errors other than "not found".
    fn isSet(io: std.Io, file: []const u8) !bool {
        std.Io.Dir.cwd().access(io, file, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }
};

/// Why a build updates its dependencies before declaring its graph.
const UpdateRequest = struct {
    const Self = @This();
    /// `-Dupdate` was given.
    flag: bool,
    /// A failed compile left the breadcrumb; its absolute path, to delete once consumed.
    breadcrumb: ?[]const u8,

    /// Reports whether anything asks for an update.
    ///
    /// Parameters:
    /// - `self`: the request.
    ///
    /// Return: `true` for `-Dupdate` or a breadcrumb.
    fn any(self: *const Self) bool {
        return self.flag or self.breadcrumb != null;
    }
};

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
pub const Deps = struct {
    const Self = @This();

    /// Clones every missing cloneable dependency, transitive ones included, and exits 1; returns when none are missing.
    ///
    /// The exit is not optional. The build runner was compiled before the clone
    /// existed, so a dependency cloned mid-`build()` resolves but its own `build()`
    /// never runs; only a fresh `zig build` picks it up. When nothing is missing the
    /// return type is `void`.
    ///
    /// A `.path` dependency of a sibling (`../tui` declaring `../vaxis`) is
    /// cloned from the `.clone` in the sibling's manifest: Zig opens it before
    /// the sibling's own `build()` could, and `Deps` runs for the root only.
    ///
    /// A `.path` dependency with an `.archive` instead of a `.clone` is
    /// downloaded and unpacked there (see `ZipArchive`), and the build goes
    /// on: no Zig code imports an archive, so no re-run is needed. Its stamp
    /// is checked whenever `build()` runs, so a new `.archive` URL in the
    /// root's manifest replaces it the same way.
    ///
    /// Also declares `-Dupdate`, which fetches every sibling checkout and
    /// fast-forwards those behind their upstream, then exits 1 for a re-run
    /// when any moved. A breadcrumb left by `guard` asks for the same once.
    ///
    /// Parameters:
    /// - `b`: the build graph.
    /// - `zon`: the caller's `@import("build.zig.zon")`.
    ///
    /// Return: nothing when all are present; otherwise never.
    pub fn cloneMissing(b: *std.Build, comptime zon: anytype) if (Self.allPresent(zon) and Self.siblingsPresent(zon)) void else noreturn {
        const present = comptime Self.allPresent(zon) and Self.siblingsPresent(zon);
        // In a dependency's build() the root's has already run.
        if (present and !b.isRoot()) return;
        const root = Self.rootPath(b) catch |err| {
            log.err("cannot resolve the build root [{any}]", .{err});
            std.process.exit(1);
        };
        const request: UpdateRequest = if (present) Self.updateRequest(b, root) else .{ .flag = false, .breadcrumb = null };
        // An archive's URL can change without it going missing: its stamp is read each time.
        if (present and !request.any() and comptime !Self.hasArchive(zon)) return;
        var run = Sync.init(b.allocator, b.graph.io, root) catch |err| {
            log.err("cannot clone dependencies [{any}]", .{err});
            std.process.exit(1);
        };
        // With everything present this queues the siblings, for the update, and
        // unpacks any archive whose URL changed.
        run.cloneSiblings() catch |err| {
            if (err == error.DepsFailed) {
                log.err("{s}", .{run.problem});
            } else {
                // Git.clone logs its own failure.
                log.err("cannot clone dependencies [{any}]", .{err});
            }
            std.process.exit(1);
        };
        if (present) {
            if (run.changed) {
                log.info("dependencies changed; re-run zig build", .{});
                std.process.exit(1);
            }
            if (request.any()) Self.applyUpdate(&run, request, false);
            return;
        }
        if (run.changed or run.unpacked) {
            log.info("fetched missing dependencies; re-run zig build", .{});
        } else {
            log.err("{s} is missing: give it a .clone or an .archive, or put a Zig package there", .{comptime Self.missingSibling(zon) orelse "a .path dependency"});
        }
        std.process.exit(1);
    }

    /// Clones missing sibling checkouts and brings every worktree dependency in line with its pin.
    ///
    /// Call it first in `build()`. A pinned dependency (`.sha`, `.tag` or
    /// `.branch`, with a `.path` under `deps/`) gets its own git worktree of the shared checkout
    /// (`.checkout`, default `../<name>`), detached at `.sha` or `.tag`, or on
    /// the branch `<consumer>/<branch>` for `.branch`. An unpinned dependency's
    /// `.path` is used as is, and cloned from `.clone` when absent, exactly as
    /// `cloneMissing` does. Transitive dependencies are followed through each
    /// worktree's manifest, and through each unpinned sibling's outside `deps/`.
    ///
    /// Anything cloned, created or moved exits 1 for a re-run, as
    /// `cloneMissing` does. While a worktree dependency is missing the return
    /// type is `noreturn`, so nothing after the call is compiled: a transitive
    /// package's top-level `@import` of a missing dependency would otherwise
    /// fail to compile before `sync` could create it. An unchanged build reads
    /// stamp files and runs no `git`.
    ///
    /// Zig 0.17 skips `build()` when nothing it tracks has changed, and a
    /// worktree deleted by hand or a stamp left behind is nothing it tracks; so
    /// while there are worktrees this poisons the configure cache, and
    /// `build()` runs on every build, as it did before 0.17.
    ///
    /// Also declares the `deps` step, which lists the worktrees, and
    /// `-Dupdate`, which fetches every sibling checkout and worktree checkout
    /// and fast-forwards the siblings and branch worktrees that are behind,
    /// then exits 1 for a re-run when any moved. A branch worktree it must
    /// skip (uncommitted changes, commits of its own) fails the build; a
    /// sibling it skips only warns. A breadcrumb left by `guard` asks for the
    /// same once.
    ///
    /// Parameters:
    /// - `b`: the build graph.
    /// - `zon`: the caller's `@import("build.zig.zon")`.
    ///
    /// Return: nothing when everything is in place; otherwise never.
    pub fn sync(b: *std.Build, comptime zon: anytype) if (Self.allPresent(zon) and Self.worktreesPresent(zon) and Self.siblingsPresent(zon)) void else noreturn {
        const present = comptime Self.allPresent(zon) and Self.worktreesPresent(zon) and Self.siblingsPresent(zon);
        // In a dependency's build() the root's sync has already run.
        if (b.pkg_hash.len != 0) {
            if (present) return;
            log.err("a worktree dependency is missing; the root package's build() must call Deps.sync first", .{});
            std.process.exit(1);
        }
        const io = b.graph.io;
        const root = Self.rootPath(b) catch |err| {
            log.err("cannot resolve the build root [{any}]", .{err});
            std.process.exit(1);
        };
        var run = Sync.init(b.allocator, io, root) catch |err| {
            log.err("cannot sync dependencies [{any}]", .{err});
            std.process.exit(1);
        };
        run.run() catch |err| {
            if (err == error.DepsFailed) {
                log.err("{s}", .{run.problem});
            } else {
                log.err("cannot sync dependencies [{any}]", .{err});
            }
            std.process.exit(1);
        };
        if (run.changed) {
            log.info("dependencies changed; re-run zig build", .{});
            std.process.exit(1);
        }
        if (comptime !present) {
            log.err("{s} is still missing; an unpinned .path is used as is, so put it there or give it a .clone or an .archive", .{comptime Self.missingWorktree(zon) orelse (Self.missingSibling(zon) orelse "a .path dependency")});
            std.process.exit(1);
        }
        if (run.worktrees.items.len > 0 or run.orphans.items.len > 0) b.graph.poisonCache();
        const request = Self.updateRequest(b, root);
        if (request.any()) Self.applyUpdate(&run, request, true);
        const list = b.addRunArtifact(mod.HostTool.add(b));
        list.setName("deps");
        list.addArg("deps");
        list.addDirectoryArg2(b.path("."), .{});
        if (request.flag) list.addArg("--update");
        // It reads and moves worktrees: never cached.
        list.has_side_effects = true;
        const top = b.step("deps", "List worktree dependencies; -Dupdate fast-forwards those that follow a branch");
        top.dependOn(&list.step);
    }

    /// `zigbuildx deps <root> [--update]`: lists the worktree dependencies and, with `--update`, fast-forwards those that follow a branch.
    ///
    /// Runs as the `deps` step. It reads the manifests again, which in the
    /// steady state runs no `git`, then reports each worktree's state.
    ///
    /// Parameters:
    /// - `process_init`: the process's allocator and IO.
    /// - `args`: the command line after the program's path; `args[0]` is the command.
    ///
    /// Return: nothing; `error.InvalidArguments` on a bad command line,
    /// `error.DepsFailed` when the worktrees are not in line or `--update`
    /// skipped or failed one, or IO errors.
    pub fn command(process_init: std.process.Init, args: []const [:0]const u8) !void {
        const io = process_init.io;
        const update = args.len == 3 and std.mem.eql(u8, args[2], "--update");
        if (args.len != 2 and !update) {
            log.err("usage: zigbuildx deps <root> [--update]", .{});
            return error.InvalidArguments;
        }
        const allocator = process_init.arena.allocator();
        const root = try std.Io.Dir.cwd().realPathFileAlloc(io, args[1], allocator);
        var run = try Sync.init(allocator, io, root);
        run.run() catch |err| {
            if (err == error.DepsFailed) log.err("{s}", .{run.problem});
            return err;
        };
        if (run.changed) log.info("dependencies changed; re-run zig build", .{});
        const updated: Updated = if (update) try run.update() else .{};
        var buffer: [1024]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(io, &buffer);
        try run.status(&stdout.interface);
        try stdout.interface.flush();
        if (updated.failed > 0) {
            log.err("{d} worktree dependencies were not updated; see the warnings above", .{updated.failed});
            return error.DepsFailed;
        }
    }

    /// Leaves a breadcrumb while `zig build` compiles, so that a compile error makes the next build update dependencies.
    ///
    /// Call it last in the root's `build()`, after `cloneMissing` or `sync`
    /// and once every artifact is declared. It wraps the default step only:
    /// one step leaves the breadcrumb, another removes it once every `Compile`
    /// the default step reaches has succeeded, and the default step waits for
    /// that. A compile error stops the removal, so the breadcrumb stays, and
    /// the next build's `cloneMissing` or `sync` updates as `-Dupdate` would,
    /// then deletes it. A failure after the compiles (an install, a run step)
    /// leaves none. The build runner keeps running independent steps after a
    /// failure, so the breadcrumb is left even when a compile fails first.
    ///
    /// zigbuildx's own host tool is not watched, since the marks run on it.
    ///
    /// Parameters:
    /// - `b`: the root package's build graph.
    ///
    /// Return: nothing.
    pub fn guard(b: *std.Build) void {
        if (!b.isRoot()) return;
        const tool = mod.HostTool.add(b);
        const install = b.getInstallStep();
        var compiles: std.ArrayList(*std.Build.Step) = .empty;
        var seen: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty;
        var pending: std.ArrayList(*std.Build.Step) = .empty;
        pending.append(b.allocator, install) catch @panic("OOM");
        while (pending.pop()) |step| {
            if (step == &tool.step) continue;
            const visit = seen.getOrPut(b.allocator, step) catch @panic("OOM");
            if (visit.found_existing) continue;
            if (step.cast(std.Build.Step.Compile) != null) compiles.append(b.allocator, step) catch @panic("OOM");
            pending.appendSlice(b.allocator, step.dependencies.items) catch @panic("OOM");
        }
        if (compiles.items.len == 0) return;
        const arm = Self.addMark(b, tool, "set");
        const disarm = Self.addMark(b, tool, "clear");
        disarm.step.dependOn(&arm.step);
        for (compiles.items) |compile| disarm.step.dependOn(compile);
        install.dependOn(&disarm.step);
    }

    /// `zigbuildx deps-mark set|clear <root>`: leaves or removes the breadcrumb that makes the next build update dependencies.
    ///
    /// Runs as the two steps `guard` adds.
    ///
    /// Parameters:
    /// - `process_init`: the process's allocator and IO.
    /// - `args`: the command line after the program's path; `args[0]` is the command.
    ///
    /// Return: nothing; `error.InvalidArguments` on a bad command line, or IO errors.
    pub fn mark(process_init: std.process.Init, args: []const [:0]const u8) !void {
        const set = args.len == 3 and std.mem.eql(u8, args[1], "set");
        const clear = args.len == 3 and std.mem.eql(u8, args[1], "clear");
        if (!set and !clear) {
            log.err("usage: zigbuildx deps-mark set|clear <root>", .{});
            return error.InvalidArguments;
        }
        const file = try Breadcrumb.path(process_init.arena.allocator(), args[2]);
        if (set) try Breadcrumb.set(process_init.io, file) else try Breadcrumb.clear(process_init.io, file);
    }

    /// Declares `-Dupdate` and makes the breadcrumb a configure input, then reports what asks for an update.
    ///
    /// Parameters:
    /// - `b`: the root package's build graph.
    /// - `root`: its absolute root.
    ///
    /// Return: the request.
    fn updateRequest(b: *std.Build, root: []const u8) UpdateRequest {
        const flag = b.option(bool, "update", "Fetch and fast-forward sibling checkouts, and worktree dependencies that follow a branch") orelse false;
        // Upstream is nothing the configure cache tracks: without this a repeated -Dupdate would not fetch.
        if (flag) b.graph.poisonCache();
        const file = Breadcrumb.path(b.allocator, root) catch @panic("OOM");
        // The breadcrumb appearing re-runs build(); while it is absent the configure cache holds.
        Breadcrumb.prepare(b.graph.io, file) catch |err| {
            log.err("cannot create {s} [{any}]", .{ std.Io.Dir.path.dirname(file).?, err });
            std.process.exit(1);
        };
        b.dependOnDirectoryContents(b.path(Breadcrumb.dir_sub_path));
        const left = Breadcrumb.isSet(b.graph.io, file) catch false;
        return .{ .flag = flag, .breadcrumb = if (left) file else null };
    }

    /// Updates the siblings and, for `sync`, the branch worktrees; exits when anything moved or a worktree was skipped.
    ///
    /// A consumed breadcrumb is deleted either way, so the build after this
    /// one is an ordinary one.
    ///
    /// Parameters:
    /// - `run`: the run, after `run` or `cloneSiblings`.
    /// - `request`: what asked for the update.
    /// - `worktrees`: whether to update worktrees too (`sync`).
    ///
    /// Return: nothing when nothing moved and no worktree was skipped; otherwise it exits 1.
    fn applyUpdate(run: *Sync, request: UpdateRequest, worktrees: bool) void {
        if (request.breadcrumb != null) log.info("the last build failed to compile; updating dependencies", .{});
        const moved = run.updateSiblings() catch |err| {
            log.err("cannot update dependencies [{any}]", .{err});
            std.process.exit(1);
        };
        const updated: Updated = if (worktrees) run.update() catch |err| {
            log.err("cannot update dependencies [{any}]", .{err});
            std.process.exit(1);
        } else .{};
        if (request.breadcrumb) |file| Breadcrumb.clear(run.io, file) catch |err| log.warn("cannot delete {s} [{any}]", .{ file, err });
        if (updated.failed > 0) log.err("{d} worktree dependencies were not updated; see the warnings above", .{updated.failed});
        if (moved or updated.moved > 0) {
            log.info("dependencies updated; re-run zig build", .{});
            std.process.exit(1);
        }
        if (updated.failed > 0) std.process.exit(1);
    }

    /// Adds a step that runs `zigbuildx deps-mark <action> <root>`.
    ///
    /// Parameters:
    /// - `b`: the root package's build graph.
    /// - `tool`: zigbuildx's host tool.
    /// - `action`: `set` or `clear`.
    ///
    /// Return: the step.
    fn addMark(b: *std.Build, tool: *std.Build.Step.Compile, action: []const u8) *std.Build.Step.Run {
        const run = b.addRunArtifact(tool);
        run.setName(b.allocator.print("deps-mark {s}", .{action}) catch @panic("OOM"));
        run.addArg("deps-mark");
        run.addArg(action);
        run.addDirectoryArg2(b.path("."), .{});
        // It touches a file outside the cache: never cached.
        run.has_side_effects = true;
        return run;
    }

    /// Returns the absolute, resolved path of `b`'s package.
    ///
    /// Parameters:
    /// - `b`: the build graph.
    ///
    /// Return: the path, owned by `b`'s arena; IO errors.
    fn rootPath(b: *std.Build) ![]const u8 {
        return b.root.root_dir.handle.realPathFileAlloc(b.graph.io, b.root.subPathOrDot(), b.allocator);
    }

    /// Reports whether every cloneable dependency is present.
    ///
    /// Parameters:
    /// - `zon`: the caller's `@import("build.zig.zon")`.
    ///
    /// Return: `true` when none is missing.
    pub fn allPresent(comptime zon: anytype) bool {
        inline for (@typeInfo(@TypeOf(zon.dependencies)).@"struct".field_names) |field_name| {
            if (Self.isCloneable(zon, field_name) and !Self.isPresent(field_name)) return false;
        }
        return true;
    }

    /// Reports whether dependency `name` was present when the build runner was compiled.
    ///
    /// Reads the runner's generated dependency table, so it answers for the root
    /// package only. Use it to guard a top-level `@import` of a dependency's
    /// `build.zig`, which is a compile error while the dependency is absent.
    ///
    /// Parameters:
    /// - `name`: the dependency's field name in `build.zig.zon`.
    ///
    /// Return: `true` when present, when this package is not the root, or when
    /// the root is not a build runner.
    pub fn isPresent(comptime name: []const u8) bool {
        const root = @import("root");
        if (!@hasDecl(root, "dependencies")) return true;
        const deps = root.dependencies;
        for (deps.root_deps) |dep| {
            if (std.mem.eql(u8, dep[0], name)) return @hasDecl(@field(deps.packages, dep[1]), "build_zig");
        }
        return true;
    }

    /// Reports whether dependency `name` declares both a `.path` and a `.clone`.
    ///
    /// An `.archive` dependency is not cloneable: no Zig code imports it, so it
    /// is unpacked in the same build and never makes `cloneMissing` `noreturn`.
    ///
    /// Parameters:
    /// - `zon`: the caller's `@import("build.zig.zon")`.
    /// - `name`: the dependency's field name in `build.zig.zon`.
    ///
    /// Return: `true` when both fields are present.
    pub fn isCloneable(comptime zon: anytype, comptime name: []const u8) bool {
        const Dep = @TypeOf(@field(zon.dependencies, name));
        return @hasField(Dep, "path") and @hasField(Dep, "clone");
    }

    /// Reports whether any root dependency is unpacked from an `.archive`.
    ///
    /// Parameters:
    /// - `zon`: the caller's `@import("build.zig.zon")`.
    ///
    /// Return: `true` when one declares an `.archive`.
    fn hasArchive(comptime zon: anytype) bool {
        inline for (@typeInfo(@TypeOf(zon.dependencies)).@"struct".field_names) |field_name| {
            if (@hasField(@TypeOf(@field(zon.dependencies, field_name)), "archive")) return true;
        }
        return false;
    }

    /// Reports whether `path` is the `.path` of one of the root's `.archive` dependencies.
    ///
    /// The runner keys a `.path` package by its `.path` as the manifest
    /// writes it, so the two compare as written.
    ///
    /// Parameters:
    /// - `zon`: the caller's `@import("build.zig.zon")`.
    /// - `path`: a key of the runner's package table.
    ///
    /// Return: `true` for a root archive's path.
    fn isRootArchive(comptime zon: anytype, comptime path: []const u8) bool {
        inline for (@typeInfo(@TypeOf(zon.dependencies)).@"struct".field_names) |field_name| {
            const dep = @field(zon.dependencies, field_name);
            const Dep = @TypeOf(dep);
            if (@hasField(Dep, "archive") and @hasField(Dep, "path") and std.mem.eql(u8, dep.path, path)) return true;
        }
        return false;
    }

    /// Reports whether every worktree dependency, transitive ones included, was present when the build runner was compiled.
    ///
    /// The runner keys a `.path` package by its path from the root, so a
    /// worktree dependency is any key under `deps/`. Unlike `isPresent`, this
    /// checks the whole package table, not just the root's dependencies.
    ///
    /// Parameters:
    /// - `zon`: the caller's `@import("build.zig.zon")`; its `.archive` paths are skipped.
    ///
    /// Return: `true` when none is missing, or when the root is not a build runner.
    fn worktreesPresent(comptime zon: anytype) bool {
        return Self.missingWorktree(zon) == null;
    }

    /// Names the first package under `deps/` that was missing when the build runner was compiled.
    ///
    /// Parameters:
    /// - `zon`: the caller's `@import("build.zig.zon")`; its `.archive` paths are skipped.
    ///
    /// Return: its path from the root, or `null` when none is missing or the
    /// root is not a build runner.
    fn missingWorktree(comptime zon: anytype) ?[]const u8 {
        const root = @import("root");
        if (!@hasDecl(root, "dependencies")) return null;
        const packages = root.dependencies.packages;
        for (@typeInfo(packages).@"struct".decl_names) |decl_name| {
            const under_deps = std.mem.startsWith(u8, decl_name, "deps/") or std.mem.startsWith(u8, decl_name, "deps\\");
            if (under_deps and !@hasDecl(@field(packages, decl_name), "build_zig") and !Self.isRootArchive(zon, decl_name)) return decl_name;
        }
        return null;
    }

    /// Reports whether every `.path` package outside `deps/`, transitive ones included, was present when the build runner was compiled.
    ///
    /// Parameters:
    /// - `zon`: the caller's `@import("build.zig.zon")`; its `.archive` paths are skipped.
    ///
    /// Return: `true` when none is missing, or when the root is not a build runner.
    fn siblingsPresent(comptime zon: anytype) bool {
        return Self.missingSibling(zon) == null;
    }

    /// Names the first `.path` package outside `deps/` that was missing when the build runner was compiled.
    ///
    /// The runner keys a `.path` package by its path from the root, which is
    /// also its `build_root`; a fetched package is keyed by its hash and lives
    /// in a cache, so an unfetched lazy dependency is not mistaken for one.
    /// The root's own `.archive` paths are skipped: `cloneMissing` unpacks
    /// them in the same build. A sibling's archive is not known at comptime,
    /// so a missing one still costs a re-run.
    ///
    /// Parameters:
    /// - `zon`: the caller's `@import("build.zig.zon")`.
    ///
    /// Return: its path from the root, or `null` when none is missing or the
    /// root is not a build runner.
    fn missingSibling(comptime zon: anytype) ?[]const u8 {
        const root = @import("root");
        if (!@hasDecl(root, "dependencies")) return null;
        const packages = root.dependencies.packages;
        for (@typeInfo(packages).@"struct".decl_names) |decl_name| {
            const package = @field(packages, decl_name);
            const is_path = std.mem.eql(u8, package.build_root, decl_name);
            const under_deps = std.mem.startsWith(u8, decl_name, "deps/") or std.mem.startsWith(u8, decl_name, "deps\\");
            if (is_path and !under_deps and !@hasDecl(package, "build_zig") and !Self.isRootArchive(zon, decl_name)) return decl_name;
        }
        return null;
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
    try std.testing.expect(Deps.hasArchive(test_zon));
    try std.testing.expect(!Deps.hasArchive(.{ .dependencies = .{ .local = .{ .path = "../local" } } }));
}

test "outside a build runner every dependency counts as present" {
    try std.testing.expect(Deps.isPresent("sibling"));
    try std.testing.expect(Deps.allPresent(test_zon));
    try std.testing.expect(Deps.allPresent(.{ .dependencies = .{} }));
    try std.testing.expect(Deps.worktreesPresent(test_zon));
}

test "Manifest reads the name and dependencies and ignores other fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try Manifest.parse(arena.allocator(),
        \\.{
        \\    .name = .consumer,
        \\    .version = "0.0.0",
        \\    .fingerprint = 0x1234,
        \\    .dependencies = .{
        \\        .leaf = .{ .path = "deps/leaf", .tag = "v1", .lazy = true },
        \\        .fetched = .{ .url = "https://example.com/x.tar.gz", .hash = "x" },
        \\    },
        \\    .paths = .{""},
        \\}
    );
    try std.testing.expectEqualStrings("consumer", manifest.name);
    try std.testing.expectEqual(2, manifest.entries.len);
    try std.testing.expectEqualStrings("leaf", manifest.entries[0].name);
    try std.testing.expectEqualStrings("deps/leaf", manifest.entries[0].path.?);
    try std.testing.expectEqualStrings("v1", manifest.entries[0].tag.?);
    try std.testing.expectEqual(null, manifest.entries[1].path);
    try std.testing.expectError(error.InvalidManifest, Manifest.parse(arena.allocator(), ".{ .name = "));
}

test "Stamp round-trips" {
    const stamp = Stamp{ .pin = .{ .kind = .branch, .value = "main" }, .sha = "abc", .branch = "c/main", .checkout = "/x/leaf" };
    const text = try stamp.serialize(std.testing.allocator);
    defer std.testing.allocator.free(text);
    const parsed = Stamp.parse(text).?;
    try std.testing.expectEqual(PinKind.branch, parsed.pin.kind);
    try std.testing.expectEqualStrings("main", parsed.pin.value);
    try std.testing.expectEqualStrings("c/main", parsed.branch);
    try std.testing.expectEqualStrings("/x/leaf", parsed.checkout);
    try std.testing.expectEqual(null, Stamp.parse("bogus\n"));
    try std.testing.expect(parsed.pin.satisfies(.{ .kind = .branch, .value = "main" }));
    try std.testing.expect(!parsed.pin.satisfies(.{ .kind = .tag, .value = "main" }));
}

/// A scratch tree for `Sync`: a consumer, origin repositories, and shared checkouts.
///
/// `<tmp>/origin/<name>` are the upstreams, each a Zig package tagged `v1`;
/// `<tmp>/<name>` are the shared checkouts, cloned on demand through `.clone`;
/// `<tmp>/consumer` is the root package.
const TestTree = struct {
    const Self = @This();
    arena: std.heap.ArenaAllocator,
    io: std.Io,
    tmp: std.testing.TmpDir,
    root: []const u8,

    /// Creates the scratch tree.
    ///
    /// Return: the fixture; IO errors.
    fn init() !Self {
        // These tests exercise expected warnings; any output on stderr makes
        // `zig build test` report the run as a failed command.
        std.testing.log_level = .err;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer arena.deinit();
        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena.allocator());
        return .{ .arena = arena, .io = std.testing.io, .tmp = tmp, .root = root };
    }

    /// Removes the scratch tree.
    ///
    /// Parameters:
    /// - `self`: the fixture.
    fn deinit(self: *Self) void {
        self.arena.deinit();
        self.tmp.cleanup();
    }

    /// Returns the fixture's allocator.
    ///
    /// Parameters:
    /// - `self`: the fixture.
    ///
    /// Return: the arena's allocator.
    fn allocator(self: *Self) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Joins `sub` onto the scratch root.
    ///
    /// Parameters:
    /// - `self`: the fixture.
    /// - `sub`: a path inside it.
    ///
    /// Return: the absolute path.
    fn path(self: *Self, sub: []const u8) ![]const u8 {
        return std.Io.Dir.path.join(self.allocator(), &.{ self.root, sub });
    }

    /// Creates upstream package `name` with the given dependencies, committed on `main` and tagged `v1`.
    ///
    /// Parameters:
    /// - `self`: the fixture.
    /// - `name`: the package.
    /// - `dependencies`: the body of its `.dependencies`.
    ///
    /// Return: nothing; IO and spawn errors.
    fn upstream(self: *Self, name: []const u8, dependencies: []const u8) !void {
        const dir = try self.path(try self.allocator().print("origin/{s}", .{name}));
        try self.run(&.{ "git", "init", "--quiet", "--initial-branch=main", dir });
        try self.write(try self.allocator().print("origin/{s}/build.zig.zon", .{name}), try self.allocator().print(".{{ .name = .{s}, .dependencies = .{{ {s} }} }}\n", .{ name, dependencies }));
        try self.write(try self.allocator().print("origin/{s}/build.zig", .{name}), "");
        try self.commit(dir, "one");
        try self.run(&.{ "git", "-C", dir, "tag", "v1" });
    }

    /// Writes the consumer's manifest.
    ///
    /// Parameters:
    /// - `self`: the fixture.
    /// - `dependencies`: the body of its `.dependencies`.
    ///
    /// Return: nothing; IO errors.
    fn consumer(self: *Self, dependencies: []const u8) !void {
        try self.write("consumer/build.zig.zon", try self.allocator().print(".{{ .name = .consumer, .dependencies = .{{ {s} }} }}\n", .{dependencies}));
    }

    /// Writes the dependency text for `name` at `deps/<name>`, cloned from its upstream, plus `extra`.
    ///
    /// Parameters:
    /// - `self`: the fixture.
    /// - `name`: the dependency.
    /// - `extra`: more fields, e.g. `.tag = "v1",`.
    ///
    /// Return: the text.
    fn dep(self: *Self, name: []const u8, extra: []const u8) ![]const u8 {
        return self.allocator().print(".{s} = .{{ .path = \"deps/{s}\", .clone = \"{s}/origin/{s}\", {s} }},", .{ name, name, self.root, name, extra });
    }

    /// Writes the dependency text for sibling `name` at `../<name>`, cloned from its upstream.
    ///
    /// Parameters:
    /// - `self`: the fixture.
    /// - `name`: the dependency.
    ///
    /// Return: the text.
    fn sibling(self: *Self, name: []const u8) ![]const u8 {
        return self.allocator().print(".{s} = .{{ .path = \"../{s}\", .clone = \"{s}/origin/{s}\" }},", .{ name, name, self.root, name });
    }

    /// Runs a sync of the consumer.
    ///
    /// Parameters:
    /// - `self`: the fixture.
    ///
    /// Return: the finished run; its errors.
    fn sync(self: *Self) !Sync {
        var run_ = try Sync.init(self.allocator(), self.io, try self.path("consumer"));
        try run_.run();
        return run_;
    }

    /// Runs a sync of the consumer that must fail, and returns its problem.
    ///
    /// Parameters:
    /// - `self`: the fixture.
    ///
    /// Return: the message; `error.TestUnexpectedResult` when the sync succeeds.
    fn syncFails(self: *Self) ![]const u8 {
        var run_ = try Sync.init(self.allocator(), self.io, try self.path("consumer"));
        run_.run() catch |err| {
            try std.testing.expectEqual(error.DepsFailed, err);
            return run_.problem;
        };
        return error.TestUnexpectedResult;
    }

    /// Resolves `rev` in the repository at `sub`.
    ///
    /// Parameters:
    /// - `self`: the fixture.
    /// - `sub`: the repository, relative to the scratch root.
    /// - `rev`: the revision.
    ///
    /// Return: the SHA; `error.TestUnexpectedResult` when it is not there.
    fn rev(self: *Self, sub: []const u8, rev_: []const u8) ![]const u8 {
        return try mod.Git.revParse(self.allocator(), self.io, try self.path(sub), rev_) orelse error.TestUnexpectedResult;
    }

    /// Writes a zip of `entries` (name, contents) at `sub`.
    ///
    /// Parameters:
    /// - `self`: the fixture.
    /// - `sub`: the zip, relative to the scratch root, inside a directory.
    /// - `entries`: the entries, `/`-separated names.
    ///
    /// Return: its `file://` URL; IO and zip errors.
    fn zip(self: *Self, sub: []const u8, entries: []const [2][]const u8) ![]const u8 {
        var archive = mod.ZipWriter.init(self.allocator());
        defer archive.deinit();
        for (entries) |entry| try archive.addStored(entry[0], entry[1]);
        try self.write(sub, try archive.finish());
        return self.allocator().print("file://{s}", .{try self.path(sub)});
    }

    /// Writes a file, creating its directory.
    ///
    /// Parameters:
    /// - `self`: the fixture.
    /// - `sub`: the file, relative to the scratch root.
    /// - `data`: its contents.
    ///
    /// Return: nothing; IO errors.
    fn write(self: *Self, sub: []const u8, data: []const u8) !void {
        try self.tmp.dir.createDirPath(self.io, std.Io.Dir.path.dirname(sub).?);
        try self.tmp.dir.writeFile(self.io, .{ .sub_path = sub, .data = data });
    }

    /// Writes file `name` in repository `dir` and commits everything.
    ///
    /// Parameters:
    /// - `self`: the fixture.
    /// - `dir`: the repository's absolute path.
    /// - `name`: the file, and the commit message.
    ///
    /// Return: nothing; IO and spawn errors.
    fn commit(self: *Self, dir: []const u8, name: []const u8) !void {
        const file = try std.Io.Dir.path.join(self.allocator(), &.{ dir, name });
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = file, .data = name });
        try self.run(&.{ "git", "-C", dir, "add", "--all" });
        try self.run(&.{ "git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "--quiet", "-m", name });
    }

    /// Runs a command and expects it to succeed.
    ///
    /// Parameters:
    /// - `self`: the fixture.
    /// - `argv`: the command.
    ///
    /// Return: nothing; `error.TestUnexpectedResult` on failure, or spawn errors.
    fn run(self: *Self, argv: []const []const u8) !void {
        const result = try std.process.run(self.allocator(), self.io, .{ .argv = argv });
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    }
};

test "sync creates worktrees for a SHA, a tag and a branch, then stays put" {
    var tree = try TestTree.init();
    defer tree.deinit();
    for ([_][]const u8{ "bysha", "bytag", "bybranch" }) |name| try tree.upstream(name, "");
    const sha = try tree.rev("origin/bysha", "HEAD");
    try tree.consumer(try std.mem.concat(tree.allocator(), u8, &.{
        try tree.dep("bysha", try tree.allocator().print(".sha = \"{s}\",", .{sha[0..10]})),
        try tree.dep("bytag", ".tag = \"v1\","),
        try tree.dep("bybranch", ".branch = \"main\","),
    }));

    const first = try tree.sync();
    try std.testing.expect(first.changed);
    try std.testing.expectEqual(3, first.worktrees.items.len);
    // Detached for a SHA or tag; on <consumer>/<branch> otherwise.
    try std.testing.expectEqualStrings(sha, try tree.rev("consumer/deps/bysha", "HEAD"));
    try std.testing.expectEqualStrings(try tree.rev("bytag", "refs/tags/v1"), try tree.rev("consumer/deps/bytag", "HEAD"));
    try std.testing.expectEqual(null, try mod.Git.revParse(tree.allocator(), tree.io, try tree.path("consumer/deps/bytag"), "refs/heads/consumer/main"));
    try std.testing.expect(try mod.Git.branchExists(tree.allocator(), tree.io, try tree.path("bybranch"), "consumer/main"));

    const second = try tree.sync();
    try std.testing.expect(!second.changed);
}

test "sync fetches a tag the checkout does not have yet" {
    var tree = try TestTree.init();
    defer tree.deinit();
    try tree.upstream("leaf", "");
    try tree.consumer(try tree.dep("leaf", ".tag = \"v1\","));
    _ = try tree.sync();
    const origin = try tree.path("origin/leaf");
    try tree.commit(origin, "two");
    try tree.run(&.{ "git", "-C", origin, "tag", "v2" });
    try tree.consumer(try tree.dep("leaf", ".tag = \"v2\","));
    const moved = try tree.sync();
    try std.testing.expect(moved.changed);
    try std.testing.expectEqualStrings(try tree.rev("origin/leaf", "v2"), try tree.rev("consumer/deps/leaf", "HEAD"));
}

test "sync moves a clean worktree to a new pin and refuses a dirty or ahead one" {
    var tree = try TestTree.init();
    defer tree.deinit();
    try tree.upstream("leaf", "");
    const origin = try tree.path("origin/leaf");
    try tree.commit(origin, "two");
    try tree.run(&.{ "git", "-C", origin, "tag", "v2" });
    try tree.consumer(try tree.dep("leaf", ".tag = \"v1\","));
    _ = try tree.sync();

    // Dirty: refused, and the worktree stays at v1.
    try tree.write("consumer/deps/leaf/scratch", "x");
    try tree.consumer(try tree.dep("leaf", ".tag = \"v2\","));
    try std.testing.expect(std.mem.find(u8, try tree.syncFails(), "uncommitted changes") != null);
    try tree.tmp.dir.deleteFile(tree.io, "consumer/deps/leaf/scratch");

    // Clean: moved to v2, then to the branch.
    _ = try tree.sync();
    try std.testing.expectEqualStrings(try tree.rev("origin/leaf", "v2"), try tree.rev("consumer/deps/leaf", "HEAD"));
    try tree.consumer(try tree.dep("leaf", ".branch = \"main\","));
    _ = try tree.sync();
    try std.testing.expect(try mod.Git.branchExists(tree.allocator(), tree.io, try tree.path("leaf"), "consumer/main"));

    // Ahead: a commit of its own blocks a move back to a tag.
    try tree.commit(try tree.path("consumer/deps/leaf"), "mine");
    try tree.consumer(try tree.dep("leaf", ".tag = \"v1\","));
    try std.testing.expect(std.mem.find(u8, try tree.syncFails(), "commits beyond") != null);
}

test "update fast-forwards a branch worktree and skips a dirty one" {
    var tree = try TestTree.init();
    defer tree.deinit();
    try tree.upstream("clean", "");
    try tree.upstream("dirty", "");
    try tree.consumer(try std.mem.concat(tree.allocator(), u8, &.{ try tree.dep("clean", ".branch = \"main\","), try tree.dep("dirty", ".branch = \"main\",") }));
    _ = try tree.sync();
    for ([_][]const u8{ "origin/clean", "origin/dirty" }) |sub| try tree.commit(try tree.path(sub), "two");
    try tree.write("consumer/deps/dirty/scratch", "x");

    var run_ = try tree.sync();
    const updated = try run_.update();
    try std.testing.expectEqual(1, updated.moved);
    try std.testing.expectEqual(1, updated.failed);
    try std.testing.expectEqualStrings(try tree.rev("origin/clean", "HEAD"), try tree.rev("consumer/deps/clean", "HEAD"));
    try std.testing.expectEqualStrings(try tree.rev("origin/dirty", "v1"), try tree.rev("consumer/deps/dirty", "HEAD"));

    // The stamp follows the update, so the next build is unchanged.
    const after = try tree.sync();
    try std.testing.expect(!after.changed);
    var out: std.Io.Writer.Allocating = .init(tree.allocator());
    var status_run = after;
    try status_run.status(&out.writer);
    try std.testing.expect(std.mem.find(u8, out.written(), "deps/dirty  branch main") != null);
}

test "update fetches a tag's checkout, so status reports the tag moved upstream" {
    var tree = try TestTree.init();
    defer tree.deinit();
    try tree.upstream("leaf", "");
    try tree.consumer(try tree.dep("leaf", ".tag = \"v1\","));
    _ = try tree.sync();
    const origin = try tree.path("origin/leaf");
    const pinned = try tree.rev("consumer/deps/leaf", "HEAD");
    try tree.commit(origin, "two");
    try tree.run(&.{ "git", "-C", origin, "tag", "--force", "v1" });

    var run_ = try tree.sync();
    try std.testing.expectEqual(Updated{}, try run_.update());
    // The worktree stays where its stamp put it.
    try std.testing.expectEqualStrings(pinned, try tree.rev("consumer/deps/leaf", "HEAD"));
    var out: std.Io.Writer.Allocating = .init(tree.allocator());
    try run_.status(&out.writer);
    try std.testing.expect(std.mem.find(u8, out.written(), "tag moved upstream") != null);
}

test "sync rejects two pin fields and a pin on a path outside deps/" {
    var tree = try TestTree.init();
    defer tree.deinit();
    try tree.consumer(".leaf = .{ .path = \"deps/leaf\", .tag = \"v1\", .branch = \"main\" },");
    try std.testing.expect(std.mem.find(u8, try tree.syncFails(), "more than one") != null);
    try tree.consumer(".leaf = .{ .path = \"../leaf\", .tag = \"v1\" },");
    try std.testing.expect(std.mem.find(u8, try tree.syncFails(), "must be under deps/") != null);
}

test "a worktree deleted by hand is recreated on its existing branch, commits kept" {
    var tree = try TestTree.init();
    defer tree.deinit();
    try tree.upstream("leaf", "");
    try tree.consumer(try tree.dep("leaf", ".branch = \"main\","));
    _ = try tree.sync();
    try tree.commit(try tree.path("consumer/deps/leaf"), "mine");
    const mine = try tree.rev("consumer/deps/leaf", "HEAD");
    try tree.tmp.dir.deleteTree(tree.io, "consumer/deps/leaf");
    const again = try tree.sync();
    try std.testing.expect(again.changed);
    try std.testing.expectEqualStrings(mine, try tree.rev("consumer/deps/leaf", "HEAD"));
}

test "an orphan is removed when clean and kept when dirty" {
    var tree = try TestTree.init();
    defer tree.deinit();
    try tree.upstream("kept", "");
    try tree.upstream("gone", "");
    try tree.consumer(try std.mem.concat(tree.allocator(), u8, &.{ try tree.dep("kept", ".tag = \"v1\","), try tree.dep("gone", ".branch = \"main\",") }));
    _ = try tree.sync();
    try tree.write("consumer/deps/kept/scratch", "x");
    try tree.consumer("");
    const run_ = try tree.sync();
    try std.testing.expect(!run_.changed);
    try std.testing.expectEqual(1, run_.orphans.items.len);
    try tree.tmp.dir.access(tree.io, "consumer/deps/kept/scratch", .{});
    try std.testing.expectError(error.FileNotFound, tree.tmp.dir.access(tree.io, "consumer/deps/gone", .{}));
    try std.testing.expectError(error.FileNotFound, tree.tmp.dir.access(tree.io, "consumer/deps/.zigbuildx/gone.rev", .{}));
    try std.testing.expect(!try mod.Git.branchExists(tree.allocator(), tree.io, try tree.path("gone"), "consumer/main"));
}

test "transitive dependencies resolve through worktrees, and the root's pin wins" {
    var tree = try TestTree.init();
    defer tree.deinit();
    try tree.upstream("leaf", "");
    const leaf_origin = try tree.path("origin/leaf");
    try tree.commit(leaf_origin, "two");
    // mid names leaf as a sibling and pins it to main; the root pins it to v1.
    try tree.upstream("mid", try tree.allocator().print(".leaf = .{{ .path = \"../leaf\", .clone = \"{s}\", .branch = \"main\" }}, .nested = .{{ .path = \"deps/nested\", .clone = \"{s}/origin/nested\", .branch = \"main\" }},", .{ leaf_origin, tree.root }));
    try tree.upstream("nested", "");
    try tree.consumer(try std.mem.concat(tree.allocator(), u8, &.{ try tree.dep("mid", ".tag = \"v1\","), try tree.dep("leaf", ".tag = \"v1\",") }));
    const run_ = try tree.sync();
    try std.testing.expectEqual(3, run_.worktrees.items.len);
    try std.testing.expectEqualStrings(try tree.rev("origin/leaf", "v1"), try tree.rev("consumer/deps/leaf", "HEAD"));
    // mid's own deps/ path nests, and its branch is prefixed with mid.
    try tree.tmp.dir.access(tree.io, "consumer/deps/mid/deps/nested/build.zig", .{});
    try std.testing.expect(try mod.Git.branchExists(tree.allocator(), tree.io, try tree.path("nested"), "consumer/mid/main"));
}

test "an unpinned path is used as is, even under deps/, and is never an orphan" {
    var tree = try TestTree.init();
    defer tree.deinit();
    try tree.upstream("leaf", "");
    try tree.consumer(try tree.dep("leaf", ".branch = \"main\","));
    _ = try tree.sync();
    // Unpinning keeps the directory: no worktree is managed, and nothing is removed.
    try tree.consumer(".leaf = .{ .path = \"deps/leaf\" },");
    const run_ = try tree.sync();
    try std.testing.expect(!run_.changed);
    try std.testing.expectEqual(0, run_.worktrees.items.len);
    try std.testing.expectEqual(0, run_.orphans.items.len);
    try tree.tmp.dir.access(tree.io, "consumer/deps/leaf/build.zig", .{});
    // A pinned dependency's sibling path to it is used as is too.
    try tree.upstream("mid", try tree.allocator().print(".leaf = .{{ .path = \"../leaf\", .clone = \"{s}/origin/leaf\", .tag = \"v1\" }},", .{tree.root}));
    try tree.consumer(try std.mem.concat(tree.allocator(), u8, &.{ try tree.dep("mid", ".tag = \"v1\","), ".leaf = .{ .path = \"deps/leaf\" }," }));
    const again = try tree.sync();
    try std.testing.expectEqual(1, again.worktrees.items.len);
}

test "sync clones a sibling's own sibling, then stays put" {
    var tree = try TestTree.init();
    defer tree.deinit();
    try tree.upstream("leaf", "");
    // mid names leaf as its sibling; only mid's manifest says where to clone it from.
    try tree.upstream("mid", try tree.allocator().print(".leaf = .{{ .path = \"../leaf\", .clone = \"{s}/origin/leaf\" }},", .{tree.root}));
    try tree.consumer(try tree.allocator().print(".mid = .{{ .path = \"../mid\", .clone = \"{s}/origin/mid\" }},", .{tree.root}));
    const first = try tree.sync();
    try std.testing.expect(first.changed);
    try std.testing.expectEqual(0, first.worktrees.items.len);
    try tree.tmp.dir.access(tree.io, "mid/build.zig", .{});
    try tree.tmp.dir.access(tree.io, "leaf/build.zig", .{});
    const again = try tree.sync();
    try std.testing.expect(!again.changed);
}

test "cloneSiblings follows siblings through a cycle and leaves their pins alone" {
    var tree = try TestTree.init();
    defer tree.deinit();
    // leaf points back at mid, and pins a worktree of its own that is not the consumer's.
    try tree.upstream("leaf", try tree.allocator().print(".mid = .{{ .path = \"../mid\", .clone = \"{s}/origin/mid\" }}, .own = .{{ .path = \"deps/own\", .clone = \"{s}/origin/own\", .tag = \"v1\" }},", .{ tree.root, tree.root }));
    try tree.upstream("mid", try tree.allocator().print(".leaf = .{{ .path = \"../leaf\", .clone = \"{s}/origin/leaf\" }},", .{tree.root}));
    try tree.consumer(try tree.allocator().print(".mid = .{{ .path = \"../mid\", .clone = \"{s}/origin/mid\" }}, .local = .{{ .path = \"../local\" }},", .{tree.root}));
    var run_ = try Sync.init(tree.allocator(), tree.io, try tree.path("consumer"));
    try run_.cloneSiblings();
    try std.testing.expect(run_.changed);
    try tree.tmp.dir.access(tree.io, "leaf/build.zig", .{});
    // Without a .clone, a missing sibling is left for Zig to report.
    try std.testing.expectError(error.FileNotFound, tree.tmp.dir.access(tree.io, "local", .{}));
    try std.testing.expectError(error.FileNotFound, tree.tmp.dir.access(tree.io, "leaf/deps/own", .{}));
    try std.testing.expectEqual(3, run_.siblings.items.len);
}

test "updateSiblings fast-forwards a sibling and its own sibling, then stays put" {
    var tree = try TestTree.init();
    defer tree.deinit();
    try tree.upstream("leaf", "");
    try tree.upstream("mid", try tree.sibling("leaf"));
    try tree.consumer(try tree.sibling("mid"));
    _ = try tree.sync();
    for ([_][]const u8{ "origin/mid", "origin/leaf" }) |sub| try tree.commit(try tree.path(sub), "two");

    var run_ = try tree.sync();
    try std.testing.expect(try run_.updateSiblings());
    try std.testing.expectEqualStrings(try tree.rev("origin/mid", "HEAD"), try tree.rev("mid", "HEAD"));
    try std.testing.expectEqualStrings(try tree.rev("origin/leaf", "HEAD"), try tree.rev("leaf", "HEAD"));

    var again = try tree.sync();
    try std.testing.expect(!try again.updateSiblings());
}

test "updateSiblings leaves a dirty, ahead, detached, untracked or non-git sibling alone" {
    var tree = try TestTree.init();
    defer tree.deinit();
    const names = [_][]const u8{ "dirty", "ahead", "detached", "untracked" };
    var dependencies: std.ArrayList(u8) = .empty;
    for (names) |name| {
        try tree.upstream(name, "");
        try dependencies.appendSlice(tree.allocator(), try tree.sibling(name));
    }
    try tree.write("plain/build.zig.zon", ".{ .name = .plain }\n");
    try dependencies.appendSlice(tree.allocator(), ".plain = .{ .path = \"../plain\" },");
    try tree.consumer(dependencies.items);
    _ = try tree.sync();
    for (names) |name| try tree.commit(try tree.path(try tree.allocator().print("origin/{s}", .{name})), "two");
    try tree.write("dirty/scratch", "x");
    try tree.commit(try tree.path("ahead"), "mine");
    const mine = try tree.rev("ahead", "HEAD");
    try tree.run(&.{ "git", "-C", try tree.path("detached"), "checkout", "--quiet", "--detach" });
    try tree.run(&.{ "git", "-C", try tree.path("untracked"), "branch", "--unset-upstream" });

    var run_ = try tree.sync();
    try std.testing.expect(!try run_.updateSiblings());
    try std.testing.expectEqualStrings(mine, try tree.rev("ahead", "HEAD"));
    for ([_][]const u8{ "dirty", "detached", "untracked" }) |name| {
        try std.testing.expectEqualStrings(try tree.rev(try tree.allocator().print("origin/{s}", .{name}), "v1"), try tree.rev(name, "HEAD"));
    }
}

test "updateSiblings follows a feature branch's upstream" {
    var tree = try TestTree.init();
    defer tree.deinit();
    try tree.upstream("mid", "");
    const origin = try tree.path("origin/mid");
    try tree.run(&.{ "git", "-C", origin, "checkout", "--quiet", "-b", "feature" });
    try tree.consumer(try tree.sibling("mid"));
    _ = try tree.sync();
    try std.testing.expectEqualStrings("feature", (try mod.Git.currentBranch(tree.allocator(), tree.io, try tree.path("mid"))).?);
    try tree.commit(origin, "two");

    var run_ = try tree.sync();
    try std.testing.expect(try run_.updateSiblings());
    try std.testing.expectEqualStrings(try tree.rev("origin/mid", "feature"), try tree.rev("mid", "HEAD"));
}

test "sync unpacks an archive sibling, stays put, and replaces it when its URL changes" {
    var tree = try TestTree.init();
    defer tree.deinit();
    const one = try tree.zip("zips/one.zip", &.{.{ "amalg-1/sqlite3.c", "one" }});
    try tree.consumer(try tree.allocator().print(".amalg = .{{ .path = \"../amalg\", .archive = \"{s}\" }},", .{one}));
    const first = try tree.sync();
    // Unpacked in the same build: no re-run.
    try std.testing.expect(first.unpacked and !first.changed);
    try std.testing.expectEqualStrings("one", try tree.tmp.dir.readFileAlloc(tree.io, "amalg/sqlite3.c", tree.allocator(), .limited(64)));
    // The stub build.zig is what makes the build runner see the package.
    try tree.tmp.dir.access(tree.io, "amalg/build.zig", .{});
    const second = try tree.sync();
    try std.testing.expect(!second.unpacked);

    const two = try tree.zip("zips/two.zip", &.{.{ "amalg-2/sqlite3.c", "two" }});
    try tree.consumer(try tree.allocator().print(".amalg = .{{ .path = \"../amalg\", .archive = \"{s}\" }},", .{two}));
    const third = try tree.sync();
    try std.testing.expect(third.unpacked);
    try std.testing.expectEqualStrings("two", try tree.tmp.dir.readFileAlloc(tree.io, "amalg/sqlite3.c", tree.allocator(), .limited(64)));
    // -Dupdate leaves an archive alone: it is no git checkout, and its URL is its pin.
    var run_ = try tree.sync();
    try std.testing.expect(!try run_.updateSiblings());
}

test "an archive under deps/ is unpacked by the root and is never an orphan" {
    var tree = try TestTree.init();
    defer tree.deinit();
    const one = try tree.zip("zips/one.zip", &.{.{ "amalg-1/sqlite3.c", "one" }});
    try tree.consumer(try tree.allocator().print(".amalg = .{{ .path = \"deps/amalg\", .archive = \"{s}\" }},", .{one}));
    const first = try tree.sync();
    try std.testing.expect(first.unpacked);
    try std.testing.expectEqual(0, first.orphans.items.len);
    try tree.tmp.dir.access(tree.io, "consumer/deps/amalg/sqlite3.c", .{});
    try std.testing.expect(!(try tree.sync()).unpacked);
}

test "cloneSiblings unpacks a sibling's own archive dependency" {
    var tree = try TestTree.init();
    defer tree.deinit();
    const one = try tree.zip("zips/one.zip", &.{.{ "amalg-1/sqlite3.c", "one" }});
    try tree.upstream("mid", try tree.allocator().print(".amalg = .{{ .path = \"../amalg\", .archive = \"{s}\" }},", .{one}));
    try tree.consumer(try tree.sibling("mid"));
    var run_ = try Sync.init(tree.allocator(), tree.io, try tree.path("consumer"));
    try run_.cloneSiblings();
    try std.testing.expect(run_.unpacked);
    try tree.tmp.dir.access(tree.io, "amalg/sqlite3.c", .{});
}

test "sync refuses to replace a directory it did not unpack, a pinned archive, and two sources" {
    var tree = try TestTree.init();
    defer tree.deinit();
    const one = try tree.zip("zips/one.zip", &.{.{ "amalg-1/sqlite3.c", "one" }});
    try tree.write("amalg/mine", "x");
    try tree.consumer(try tree.allocator().print(".amalg = .{{ .path = \"../amalg\", .archive = \"{s}\" }},", .{one}));
    try std.testing.expect(std.mem.find(u8, try tree.syncFails(), "did not unpack it") != null);
    try tree.tmp.dir.access(tree.io, "amalg/mine", .{});
    try tree.consumer(try tree.allocator().print(".amalg = .{{ .path = \"deps/amalg\", .archive = \"{s}\", .tag = \"v1\" }},", .{one}));
    try std.testing.expect(std.mem.find(u8, try tree.syncFails(), "pinned by its URL") != null);
    try tree.consumer(".amalg = .{ .path = \"../other\", .archive = \"file:///x.zip\", .clone = \"git@example.com:x.git\" },");
    try std.testing.expect(std.mem.find(u8, try tree.syncFails(), "both .clone and .archive") != null);
}

test "Breadcrumb is set, found and cleared, each idempotently" {
    var tree = try TestTree.init();
    defer tree.deinit();
    const file = try Breadcrumb.path(tree.allocator(), try tree.path("consumer"));
    try std.testing.expect(std.mem.endsWith(u8, file, try std.Io.Dir.path.join(tree.allocator(), &.{ ".zig-cache", "zigbuildx", "update" })));
    try std.testing.expect(!try Breadcrumb.isSet(tree.io, file));
    try Breadcrumb.set(tree.io, file);
    try Breadcrumb.set(tree.io, file);
    try std.testing.expect(try Breadcrumb.isSet(tree.io, file));
    try Breadcrumb.clear(tree.io, file);
    try Breadcrumb.clear(tree.io, file);
    try std.testing.expect(!try Breadcrumb.isSet(tree.io, file));
}
