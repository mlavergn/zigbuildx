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
    /// The largest stamp read; one is five short lines.
    const max_bytes = 1 << 16;
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
    /// Where a fetched dependency comes from; only `Deps.pin` reads it.
    url: ?[]const u8 = null,
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
    /// The largest `build.zig.zon` read; a manifest is a few kilobytes.
    const max_bytes = 1 << 20;
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
                inline for (.{ "url", "path", "clone", "archive", "checkout", "sha", "tag", "branch" }) |field| {
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

/// A sibling checkout outside `deps/`, as the manifests declare it.
const Sibling = struct {
    const Self = @This();
    /// The checkout's absolute path.
    dir: []const u8,
    /// The branch it follows (`.branch`); null for whatever branch it is on.
    branch: ?[]const u8,
    /// The package whose manifest declared it first.
    declared_by: []const u8,
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
    const Self = @This();
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
    /// Sibling checkouts outside `deps/`, in the order found; each path once.
    siblings: std.ArrayList(Sibling) = .empty,
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
        const lock = try self.acquireLock();
        defer lock.close(self.io);
        const manifest = try self.readManifest(self.root) orelse return self.fail("no build.zig.zon in {s}", .{self.root});
        self.consumer = manifest.name;
        try self.collect(manifest, self.root, self.root);
        try self.followSiblings();
        const deps = try std.Io.Dir.path.join(self.allocator, &.{ self.root, "deps" });
        if (self.worktrees.items.len == 0 and !try mod.File.exists(self.io, deps)) return;
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
    /// Parameters:
    /// - `self`: the run.
    /// - `manifest`: the declaring package's manifest.
    /// - `dir`: where the declaring package is on disk.
    /// - `home`: the declaring package's own checkout, which its `.checkout` paths resolve against.
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
            if (pin) |outside| if (!pinnable) {
                // A sibling may follow a branch; only a worktree can be frozen at a SHA or tag.
                if (outside.follows()) {
                    try self.addSibling(resolved, source, outside.value, manifest.name);
                    continue;
                }
                if (is_root) return self.fail("{s} pins {s} to a {t}, but a .sha or .tag dependency's .path must be under deps/", .{ manifest.name, entry.name, outside.kind });
                continue;
            };
            const rel = try self.relativeToRoot(resolved);
            // The first declaration of a path wins, pinned or not.
            if (self.find(resolved)) |existing| {
                if (pin) |wanted| if (!existing.pin.satisfies(wanted)) log.warn("{s} pins {s} to {t} {s}; using {s}'s {t} {s}", .{ manifest.name, existing.rel, wanted.kind, wanted.value, existing.declared_by, existing.pin.kind, existing.pin.value });
                continue;
            }
            if (Self.containsPath(self.unpinned.items, resolved)) {
                if (pin) |wanted| log.warn("{s} pins {s} to {t} {s}; using the path as is, as an earlier declaration does", .{ manifest.name, rel, wanted.kind, wanted.value });
                continue;
            }
            // Unpinned: the path is used as is. Under deps/ the root clones or
            // unpacks it when absent, as cloneMissing does; a sibling outside
            // deps/ is fetched whoever declares it, and its own dependencies
            // are followed.
            const wanted = pin orelse {
                if (!pinnable) {
                    try self.addSibling(resolved, source, null, manifest.name);
                    continue;
                }
                try self.unpinned.append(self.allocator, resolved);
                if (is_root) if (source) |from| try self.materialize(resolved, from, null);
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
    /// Return: the source, or `null` when it names none; `error.DepsFailed` when it sets both `.clone` and `.archive`.
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
    /// Parameters:
    /// - `self`: the run.
    /// - `rel`: the worktree's path relative to the consumer.
    ///
    /// Return: the prefix.
    fn branchPrefix(self: *const Self, rel: []const u8) ![]const u8 {
        var prefix: std.ArrayList(u8) = .empty;
        try prefix.appendSlice(self.allocator, self.consumer);
        // `deps/mid/deps/x` gets `<consumer>/mid`, so two worktrees of one checkout never want the same branch.
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

    /// Reports whether `paths` holds `path`.
    ///
    /// Parameters:
    /// - `paths`: absolute paths, as the run records them.
    /// - `path`: an absolute path.
    ///
    /// Return: `true` when one of `paths` equals `path`.
    fn containsPath(paths: []const []const u8, path: []const u8) bool {
        // Few paths: a scan is cheaper than a map.
        for (paths) |candidate| {
            if (std.mem.eql(u8, candidate, path)) return true;
        }
        return false;
    }

    /// Clones or unpacks an unpinned dependency from `source`, as `cloneMissing` does.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `path`: the dependency's absolute path.
    /// - `source`: where it comes from.
    /// - `branch`: the branch a clone checks out; null for the remote's default.
    ///
    /// Return: nothing; `error.DepsFailed` for an archive or a directory that is no package, or clone errors, which `Git.clone` logs.
    fn materialize(self: *Self, path: []const u8, source: Source, branch: ?[]const u8) !void {
        switch (source) {
            .clone => |url| {
                if (!try mod.File.exists(self.io, path)) {
                    try mod.Git.clone(self.io, url, path, branch);
                    self.changed = true;
                    return;
                }
                // The steady state: a stat or two, no git.
                if (try self.isPackage(path)) return;
                try self.repair(path, url, branch);
            },
            // Also unpacked again when its URL changed.
            .archive => |url| try self.ensureArchive(path, url),
        }
    }

    /// Reports whether `dir` holds a Zig package: a `build.zig.zon` or a `build.zig`.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `dir`: an absolute path that exists.
    ///
    /// Return: `true` when either file is there; IO errors.
    fn isPackage(self: *const Self, dir: []const u8) !bool {
        for ([_][]const u8{ "build.zig.zon", "build.zig" }) |name| {
            if (try mod.File.exists(self.io, try std.Io.Dir.path.join(self.allocator, &.{ dir, name }))) return true;
        }
        return false;
    }

    /// Fills in a checkout that a clone left with no commits and no files, or refuses anything else that is no package.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `path`: the dependency's absolute path; it exists and holds no package.
    /// - `url`: its `.clone`, for messages.
    /// - `branch`: the branch to check out; null for the remote's default.
    ///
    /// Return: nothing; `error.DepsFailed` when it holds anything of its own or the remote has nothing to check out, or IO and git errors.
    fn repair(self: *Self, path: []const u8, url: []const u8, branch: ?[]const u8) !void {
        const rel = try self.relativeToRoot(path);
        // Only an empty repository is filled in: anything else may be someone's work.
        if (!try self.holdsOnlyGit(path) or try mod.Git.revParse(self.allocator, self.io, path, "HEAD") != null) {
            return self.fail("{s} exists but is not a Zig package (no build.zig.zon); move it aside and re-run", .{rel});
        }
        const wanted = branch orelse try mod.Git.remoteHead(self.allocator, self.io, path) orelse {
            return self.fail("{s} is an empty checkout and {s} has no commits yet; push, then re-run", .{ rel, url });
        };
        try mod.Git.fetch(self.allocator, self.io, path);
        if (try mod.Git.revParse(self.allocator, self.io, path, try self.allocator.print("refs/remotes/origin/{s}", .{wanted})) == null) {
            return self.fail("{s} is an empty checkout and {s} has no branch {s}", .{ rel, url, wanted });
        }
        try mod.Git.checkoutTracking(self.allocator, self.io, path, wanted);
        log.info("filled in the empty checkout {s} from {s} ({s})", .{ rel, url, wanted });
        self.changed = true;
    }

    /// Reports whether `dir` holds nothing but a `.git` directory.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `dir`: an absolute directory path.
    ///
    /// Return: `true` when `.git` is its only entry; IO errors.
    fn holdsOnlyGit(self: *const Self, dir: []const u8) !bool {
        var handle = try std.Io.Dir.cwd().openDir(self.io, dir, .{ .iterate = true });
        defer handle.close(self.io);
        var found_git = false;
        var it = handle.iterate();
        while (try it.next(self.io)) |item| {
            if (!std.mem.eql(u8, item.name, ".git") or item.kind != .directory) return false;
            found_git = true;
        }
        return found_git;
    }

    /// Unpacks an `.archive` dependency when it is absent or was unpacked from another URL.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `path`: the dependency's absolute path.
    /// - `url`: the zip's URL.
    ///
    /// Return: nothing; `error.DepsFailed` when the path holds something else or cannot be unpacked, or IO errors.
    fn ensureArchive(self: *Self, path: []const u8, url: []const u8) !void {
        if (!Self.containsPath(self.archives.items, path)) try self.archives.append(self.allocator, path);
        const rel = try self.relativeToRoot(path);
        if (try mod.File.exists(self.io, path)) {
            const unpacked = try mod.ZipArchive.source(self.allocator, self.io, path) orelse {
                return self.fail("{s} exists but zigbuildx did not unpack it (it has no {s}); move it aside and re-run", .{ rel, mod.ZipArchive.stamp_name });
            };
            // The stamp records the URL: an unchanged one costs a read and no download.
            if (std.mem.eql(u8, unpacked, url)) return;
            log.info("{s} was unpacked from {s}; replacing it", .{ rel, unpacked });
        }
        mod.ZipArchive.unpack(self.allocator, self.io, url, path) catch |err| {
            return self.fail("cannot unpack {s} into {s} [{any}]", .{ url, rel, err });
        };
        self.unpacked = true;
    }

    /// Queues the sibling at `path`, cloning or unpacking it from `source` as `materialize` does.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `path`: the dependency's absolute path.
    /// - `source`: where it comes from, if anywhere.
    /// - `branch`: the branch it follows (`.branch`), or null.
    /// - `declared_by`: the package whose manifest names it.
    ///
    /// Return: nothing; `error.DepsFailed` for an archive, or clone errors, which `Git.clone` logs.
    fn addSibling(self: *Self, path: []const u8, source: ?Source, branch: ?[]const u8, declared_by: []const u8) !void {
        // Each path is queued once, so a cycle of siblings ends; the first declaration wins.
        if (self.findSibling(path)) |first| {
            // A later declaration that names no branch has nothing to disagree with.
            if (branch) |want| {
                const agrees = if (first.branch) |had| std.mem.eql(u8, had, want) else false;
                if (!agrees) log.warn("{s} wants {s} on branch {s}; using {s}'s {s}", .{ declared_by, try self.relativeToRoot(path), want, first.declared_by, first.branch orelse "current branch" });
            }
            return;
        }
        try self.siblings.append(self.allocator, .{ .dir = path, .branch = branch, .declared_by = declared_by });
        // An absent one with no `source` is left for Zig to report.
        try self.materialize(path, source orelse return, branch);
    }

    /// Finds the sibling queued at `dir`.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `dir`: an absolute path.
    ///
    /// Return: the sibling, or `null`.
    fn findSibling(self: *const Self, dir: []const u8) ?*const Sibling {
        for (self.siblings.items) |*sibling| {
            if (std.mem.eql(u8, sibling.dir, dir)) return sibling;
        }
        return null;
    }

    /// Reads each queued sibling's manifest and queues its unpinned `.path` dependencies outside `deps/`.
    ///
    /// Parameters:
    /// - `self`: the run.
    ///
    /// Return: nothing; `error.DepsFailed` when a manifest does not parse, or IO and clone errors.
    fn followSiblings(self: *Self) !void {
        // Zig opens every `.path` package before `build()` runs, and only the root runs `Deps`, so a
        // sibling's own sibling must be on disk too. Siblings queued here are walked in the same pass.
        while (self.walked < self.siblings.items.len) : (self.walked += 1) {
            const dir = self.siblings.items[self.walked].dir;
            const manifest = try self.readManifest(dir) orelse continue;
            for (manifest.entries) |entry| {
                const path = entry.path orelse continue;
                // Only a worktree is frozen at a SHA or tag, and that one is the sibling's own.
                if (entry.sha != null or entry.tag != null) continue;
                const resolved = try std.Io.Dir.path.resolveAlloc(self.allocator, &.{ dir, path });
                if (self.isWorktreePath(resolved)) continue;
                // A branch pin under the sibling's own `deps/` is its worktree, not a sibling.
                if (entry.branch != null and std.mem.eql(u8, std.Io.Dir.path.basename(std.Io.Dir.path.dirname(resolved) orelse ""), "deps")) continue;
                try self.addSibling(resolved, try self.sourceOf(manifest.name, entry), entry.branch, manifest.name);
            }
        }
    }

    /// Clones or unpacks every absent `.path` dependency of the root, then of its siblings, as `cloneMissing` does.
    ///
    /// Parameters:
    /// - `self`: the run.
    ///
    /// Return: nothing; `error.DepsFailed` with `problem` set, or IO and clone errors.
    fn cloneSiblings(self: *Self) !void {
        const lock = try self.acquireLock();
        defer lock.close(self.io);
        const manifest = try self.readManifest(self.root) orelse return self.fail("no build.zig.zon in {s}", .{self.root});
        // Every `.path` is cloned whatever it pins; no worktree is made.
        for (manifest.entries) |entry| {
            const path = entry.path orelse continue;
            try self.addSibling(try std.Io.Dir.path.resolveAlloc(self.allocator, &.{ self.root, path }), try self.sourceOf(manifest.name, entry), entry.branch, manifest.name);
        }
        try self.followSiblings();
    }

    /// Fetches every sibling checkout with no work of its own and fast-forwards each one that is behind.
    ///
    /// Parameters:
    /// - `self`: the run, after `run` or `cloneSiblings` has queued the siblings.
    ///
    /// Return: whether any sibling moved; IO errors.
    fn updateSiblings(self: *Self) !bool {
        // Siblings are the developer's own checkouts: a skip only logs, never fails the build.
        // Everything that can rule a sibling out is local, so a skipped one never reaches the network.
        var dirs: std.ArrayList([]const u8) = .empty;
        var tips: std.ArrayList([]const u8) = .empty;
        for (self.siblings.items) |sibling| {
            const tip = try self.siblingTip(sibling) orelse continue;
            try dirs.append(self.allocator, sibling.dir);
            try tips.append(self.allocator, tip);
        }
        const fetched = try self.fetchAll(dirs.items);
        var moved = false;
        for (dirs.items, tips.items, fetched) |dir, tip_ref, ok| {
            const rel = try self.relativeToRoot(dir);
            if (!ok) {
                log.warn("not updating {s}: git fetch failed", .{rel});
                continue;
            }
            const tip = (mod.Git.revParse(self.allocator, self.io, dir, tip_ref) catch null) orelse continue;
            const head = (mod.Git.revParse(self.allocator, self.io, dir, "HEAD") catch null) orelse continue;
            if (std.mem.eql(u8, tip, head)) continue;
            mod.Git.fastForward(self.allocator, self.io, dir, tip) catch continue;
            log.info("updated {s} from {s} to {s}", .{ rel, Self.short(head), Self.short(tip) });
            moved = true;
        }
        return moved;
    }

    /// Decides, without the network, whether a sibling is updated, and names what it is fast-forwarded to.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `sibling`: the sibling.
    ///
    /// Return: the revision to fast-forward to (`@{u}` or `refs/remotes/origin/<branch>`), or `null` when it is left alone; IO errors.
    fn siblingTip(self: *Self, sibling: Sibling) !?[]const u8 {
        const dir = sibling.dir;
        // An archive's URL is its pin: `ensureArchive` has already brought it in line.
        if (Self.containsPath(self.archives.items, dir)) return null;
        const rel = try self.relativeToRoot(dir);
        // A directory inside some other repository is not its own checkout: leave that repository alone.
        if (!try mod.File.exists(self.io, try std.Io.Dir.path.join(self.allocator, &.{ dir, ".git" }))) {
            log.info("not updating {s}: it is not a git checkout", .{rel});
            return null;
        }
        const current = (mod.Git.currentBranch(self.allocator, self.io, dir) catch return null) orelse {
            log.info("not updating {s}: HEAD is detached", .{rel});
            return null;
        };
        const tip_ref = if (sibling.branch) |wanted| blk: {
            if (!std.mem.eql(u8, current, wanted)) {
                log.warn("not updating {s}: it is on {s}, and {s} wants {s}", .{ rel, current, sibling.declared_by, wanted });
                return null;
            }
            break :blk try self.allocator.print("refs/remotes/origin/{s}", .{wanted});
        } else "@{u}";
        // Compared with the tip as last fetched: commits of its own are local, whatever upstream did since.
        const base = (mod.Git.revParse(self.allocator, self.io, dir, tip_ref) catch null) orelse {
            log.info("not updating {s}: {s} has no upstream branch", .{ rel, current });
            return null;
        };
        if (self.describeLocalWork(dir, base)) |work| {
            log.warn("not updating {s}: {s} has {s}", .{ rel, current, work });
            return null;
        }
        return tip_ref;
    }

    /// Fetches every repository in `dirs` at once.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `dirs`: absolute checkout paths, each once.
    ///
    /// Return: whether each fetch succeeded, in `dirs` order; allocation errors.
    fn fetchAll(self: *const Self, dirs: []const []const u8) ![]bool {
        const fetched = try self.allocator.alloc(bool, dirs.len);
        const children = try self.allocator.alloc(?std.process.Child, dirs.len);
        // All started before any is waited for: each is a round trip, so they overlap, and
        // processes need no threads (a build runner is compiled single-threaded).
        for (dirs, children) |dir, *child| child.* = mod.Git.startFetch(self.io, dir) catch null;
        for (children, fetched) |*child, *ok| ok.* = if (child.*) |*running| mod.Git.finishFetch(self.io, running) else false;
        return fetched;
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
        if (!try mod.File.exists(self.io, worktree.dir)) {
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
        if (!try mod.File.exists(self.io, build_zig)) return self.fail("{s} has no build.zig; a worktree dependency must be a Zig package", .{worktree.rel});
    }

    /// Creates a worktree, cloning its checkout first when that is absent.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `worktree`: the worktree to create; its `stamp` is set.
    ///
    /// Return: nothing; `error.DepsFailed`, or IO and git errors.
    fn create(self: *Self, worktree: *Worktree) !void {
        if (!try mod.File.exists(self.io, worktree.checkout)) {
            const url = worktree.clone orelse return self.fail("{s} needs the checkout {s}, which is missing, and {s} has no .clone", .{ worktree.rel, worktree.checkout, worktree.name });
            try mod.Git.clone(self.io, url, worktree.checkout, null);
        }
        const target = try self.resolve(worktree);
        try mod.Git.worktreePrune(self.allocator, self.io, worktree.checkout);
        try mod.File.createParentDir(self.io, worktree.dir);
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
            // `origin` first, then local, so a checkout with no remote still works.
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
            if (!Self.containsPath(dirs.items, parent)) try dirs.append(self.allocator, parent);
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
                if (self.find(path) == null and !Self.containsPath(self.unpinned.items, path)) try self.removeOrphan(path);
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
        const rel = try self.relativeToRoot(path);
        const stamp = try self.readStamp(path) orelse {
            log.warn("{s} is no longer a dependency, but its stamp is unreadable; left in place", .{rel});
            try self.orphans.append(self.allocator, rel);
            return;
        };
        if (try mod.File.exists(self.io, path)) {
            if (self.describeLocalWork(path, stamp.sha)) |work| {
                log.warn("{s} is no longer a dependency, but it has {s}; left in place", .{ rel, work });
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

    /// Fetches and fast-forwards every worktree that follows a branch and has no work of its own.
    ///
    /// Parameters:
    /// - `self`: the run, after `run`.
    ///
    /// Return: how many worktrees moved, and how many were skipped or failed; IO errors.
    fn update(self: *const Self) !Updated {
        var updated: Updated = .{};
        // A SHA or tag is frozen, so its checkout is never fetched; a branch worktree with work of
        // its own is skipped before its checkout is, so a skip never reaches the network.
        var candidates: std.ArrayList(*Worktree) = .empty;
        var checkouts: std.ArrayList([]const u8) = .empty;
        for (self.worktrees.items) |*worktree| {
            const stamp = worktree.stamp orelse continue;
            if (!stamp.pin.follows()) continue;
            if (self.describeLocalWork(worktree.dir, stamp.sha)) |work| {
                log.warn("skipped {s}: it has {s}", .{ worktree.rel, work });
                updated.failed += 1;
                continue;
            }
            try candidates.append(self.allocator, worktree);
            // Each checkout is fetched once, however many worktrees share it.
            if (!Self.containsPath(checkouts.items, stamp.checkout)) try checkouts.append(self.allocator, stamp.checkout);
        }
        const fetched = try self.fetchAll(checkouts.items);
        for (candidates.items) |worktree| {
            const stamp = worktree.stamp.?;
            const ok = for (checkouts.items, fetched) |checkout, done| {
                if (std.mem.eql(u8, checkout, stamp.checkout)) break done;
            } else false;
            if (!ok) {
                log.warn("skipped {s}: git fetch failed in {s}", .{ worktree.rel, stamp.checkout });
                updated.failed += 1;
                continue;
            }
            const tip = (self.lookup(stamp.checkout, stamp.pin) catch null) orelse {
                log.warn("skipped {s}: branch {s} is gone from {s}", .{ worktree.rel, stamp.pin.value, stamp.checkout });
                updated.failed += 1;
                continue;
            };
            if (std.mem.eql(u8, tip, stamp.sha)) continue;
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
    /// Return: the manifest, or `null` when there is none; `error.DepsFailed` when it does not parse, or IO errors.
    fn readManifest(self: *Self, dir: []const u8) !?Manifest {
        const path = try std.Io.Dir.path.join(self.allocator, &.{ dir, "build.zig.zon" });
        const source = try mod.File.readOptionalZ(self.allocator, self.io, path, .limited(Manifest.max_bytes)) orelse return null;
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
        const text = try mod.File.readOptional(self.allocator, self.io, try self.stampPath(dir), .limited(Stamp.max_bytes)) orelse return null;
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
        try mod.File.createParentDir(self.io, path);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = try stamp.serialize(self.allocator) });
        worktree.stamp = stamp;
    }

    /// Returns `path` relative to the consumer's root, for messages.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `path`: an absolute path.
    ///
    /// Return: the relative path; allocation errors.
    fn relativeToRoot(self: *const Self, path: []const u8) ![]const u8 {
        return std.Io.Dir.path.relativeAlloc(self.allocator, self.root, null, self.root, path);
    }

    /// Describes the work of its own a checkout or worktree holds, which moving it would put at risk.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `dir`: the checkout or worktree.
    /// - `base`: the commit that HEAD is compared with; commits beyond it are its own.
    ///
    /// Return: "uncommitted changes" or "commits of its own", or `null` when it has neither.
    fn describeLocalWork(self: *const Self, dir: []const u8, base: []const u8) ?[]const u8 {
        // A `git` failure counts as work, so a checkout that cannot be inspected is left alone.
        const clean = mod.Git.isClean(self.allocator, self.io, dir) catch false;
        if (!clean) return "uncommitted changes";
        const ahead = mod.Git.isAhead(self.allocator, self.io, dir, base) catch true;
        if (ahead) return "commits of its own";
        return null;
    }

    /// Takes the lock that serialises concurrent builds of this consumer.
    ///
    /// Parameters:
    /// - `self`: the run.
    ///
    /// Return: the locked file, released when it is closed; IO errors.
    fn acquireLock(self: *const Self) !std.Io.File {
        const dir = try std.Io.Dir.path.join(self.allocator, &.{ self.root, ".zig-cache" });
        try std.Io.Dir.cwd().createDirPath(self.io, dir);
        const path = try std.Io.Dir.path.join(self.allocator, &.{ dir, "zigbuildx.lock" });
        return std.Io.Dir.cwd().createFile(self.io, path, .{ .lock = .exclusive });
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

    /// Logs why the run failed: the `problem` `fail` recorded, or else the error itself.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `err`: the error the run returned.
    /// - `action`: what the run was doing, for the message (`"clone"`, `"sync"`).
    fn logFailure(self: *const Self, err: anyerror, action: []const u8) void {
        if (err == error.DepsFailed) {
            log.err("{s}", .{self.problem});
        } else {
            // `Git.clone` has already logged git's reason; this names what the run was doing.
            log.err("cannot {s} dependencies [{any}]", .{ action, err });
        }
    }
};

/// Reads the `git+` URLs `zig fetch` writes and `git ls-remote` listings, for `Deps.pin`.
/// A release tag and the commit it names.
const Release = struct {
    const Self = @This();
    /// The tag, `v` and a semantic version.
    tag: []const u8,
    /// The commit it names; for an annotated tag, the commit, not the tag object.
    commit: []const u8,
    /// The tag's version.
    version: std.SemanticVersion,
};

const ReleasePin = struct {
    const Self = @This();

    /// Returns the repository a `git+` dependency URL names, without its scheme prefix, ref or commit.
    ///
    /// Parameters:
    /// - `url`: a `.url`, such as `git+https://host/x?ref=v1.0.0#<sha>` or `git+https://host/x#main`.
    ///
    /// Return: `https://host/x`, or null when `url` is not a `git+` URL.
    fn repository(url: []const u8) ?[]const u8 {
        const prefix = "git+";
        if (!std.mem.startsWith(u8, url, prefix)) return null;
        const rest = url[prefix.len..];
        return rest[0 .. std.mem.findAny(u8, rest, "?#") orelse rest.len];
    }

    /// Returns what a `git+` dependency URL is pinned to: its `?ref=`, else what follows `#`.
    ///
    /// Parameters:
    /// - `url`: a `.url`.
    ///
    /// Return: the tag or branch (`v1.0.0`, `main`), a commit, or "" when it names none.
    fn ref(url: []const u8) []const u8 {
        const query = "?ref=";
        if (std.mem.find(u8, url, query)) |start| {
            const rest = url[start + query.len ..];
            return rest[0 .. std.mem.findScalar(u8, rest, '#') orelse rest.len];
        }
        const hash = std.mem.findScalar(u8, url, '#') orelse return "";
        return url[hash + 1 ..];
    }

    /// Returns the commit a `?ref=<ref>#<commit>` URL pins, as `zig fetch --save` writes it.
    ///
    /// Parameters:
    /// - `url`: a `.url`.
    ///
    /// Return: the commit, or "" when `url` names none (`#<ref>` alone, as `zig fetch --save-exact` keeps it).
    fn commit(url: []const u8) []const u8 {
        if (std.mem.find(u8, url, "?ref=") == null) return "";
        const hash = std.mem.findScalar(u8, url, '#') orelse return "";
        return url[hash + 1 ..];
    }

    /// Reports whether a ref is a full commit hash rather than a tag or branch.
    ///
    /// Parameters:
    /// - `pinned`: a ref from a `.url`.
    ///
    /// Return: `true` for 40 or 64 hex digits.
    fn isCommit(pinned: []const u8) bool {
        if (pinned.len != 40 and pinned.len != 64) return false;
        for (pinned) |c| if (!std.ascii.isHex(c)) return false;
        return true;
    }

    /// Reports whether a ref is a branch to follow: neither a release tag nor a commit.
    ///
    /// Parameters:
    /// - `pinned`: a ref from a `.url`; "" is the default branch.
    ///
    /// Return: `true` for a branch.
    fn isBranch(pinned: []const u8) bool {
        return Self.releaseVersion(pinned) == null and !Self.isCommit(pinned);
    }

    /// Reads the version of a release tag: `v` and a semantic version, with no pre-release or build part.
    ///
    /// Parameters:
    /// - `tag`: a tag or ref, such as `v3.6.0`, `v5.0.0-rc1` or `main`.
    ///
    /// Return: the version, or null when `tag` is not a release tag.
    fn releaseVersion(tag: []const u8) ?std.SemanticVersion {
        if (!std.mem.startsWith(u8, tag, "v")) return null;
        const version = std.SemanticVersion.parse(tag[1..]) catch return null;
        if (version.pre != null or version.build != null) return null;
        return version;
    }

    /// Returns the newest release tag in a `git ls-remote --tags` listing, with the commit it names.
    ///
    /// Parameters:
    /// - `listing`: `<sha>\trefs/tags/<tag>` lines, and `<commit>\trefs/tags/<tag>^{}` for annotated tags.
    ///
    /// Return: the release, borrowed from `listing`, or null when there is no release tag.
    fn newestRelease(listing: []const u8) ?Release {
        var newest: ?Release = null;
        var lines = std.mem.tokenizeScalar(u8, listing, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            const marker = "\trefs/tags/";
            const start = std.mem.find(u8, line, marker) orelse continue;
            const sha = line[0..start];
            const name = line[start + marker.len ..];
            const peeled = std.mem.endsWith(u8, name, "^{}");
            const tag = if (peeled) name[0 .. name.len - "^{}".len] else name;
            const version = Self.releaseVersion(tag) orelse continue;
            if (newest) |best| {
                // The peeled line follows its tag's own: it replaces the tag object with the commit.
                if (std.mem.eql(u8, best.tag, tag)) {
                    if (peeled) newest.?.commit = sha;
                    continue;
                }
                if (version.order(best.version) != .gt) continue;
            }
            newest = .{ .tag = tag, .commit = sha, .version = version };
        }
        return newest;
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
    /// Parameters:
    /// - `b`: the build graph.
    /// - `zon`: the caller's `@import("build.zig.zon")`.
    ///
    /// Return: `void` when every dependency is present; otherwise `noreturn`.
    pub fn cloneMissing(b: *std.Build, comptime zon: anytype) if (Self.allPresent(zon) and Self.siblingsPresent(zon)) void else noreturn {
        const present = comptime Self.allPresent(zon) and Self.siblingsPresent(zon);
        // In a dependency's build() the root's has already run.
        if (present and !b.isRoot()) return;
        const root = Self.rootPath(b) catch |err| {
            log.err("cannot resolve the build root [{any}]", .{err});
            std.process.exit(1);
        };
        if (present) Self.addPinStep(b);
        var run = Sync.init(b.allocator, b.graph.io, root) catch |err| {
            log.err("cannot clone dependencies [{any}]", .{err});
            std.process.exit(1);
        };
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
    /// Parameters:
    /// - `b`: the build graph.
    /// - `zon`: the caller's `@import("build.zig.zon")`.
    ///
    /// Return: `void` when everything is in place; otherwise `noreturn`.
    pub fn sync(b: *std.Build, comptime zon: anytype) if (Self.allPresent(zon) and Self.worktreesPresent(zon) and Self.siblingsPresent(zon)) void else noreturn {
        const present = comptime Self.allPresent(zon) and Self.worktreesPresent(zon) and Self.siblingsPresent(zon);
        // In a dependency's build() the root's sync has already run.
        if (!b.isRoot()) {
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
        list.setName("deps");
        list.addArg("deps");
        list.addDirectoryArg2(b.path("."), .{});
        // It reads and moves worktrees: never cached.
        list.has_side_effects = true;
        const top = b.step("deps", "List worktree dependencies: pin, commit, clean or dirty");
        top.dependOn(&list.step);
        Self.addPinStep(b);
    }

    /// `zigbuildx pin <root> <name> <zig>`: pins dependency `name`, this zigbuildx, to its repository's newest release tag.
    /// Runs as the `zigbuildx-pin` step.
    ///
    /// Parameters:
    /// - `process_init`: the process's allocator and IO.
    /// - `args`: the command line after the program's path; `args[0]` is the command.
    ///
    /// Return: nothing; `error.InvalidArguments` on a bad command line, `error.DepsFailed` when no release can be pinned or `zig fetch` fails, or IO and git errors.
    pub fn pin(process_init: std.process.Init, args: []const [:0]const u8) !void {
        if (args.len != 4) {
            log.err("usage: zigbuildx pin <root> <dependency-name> <zig>", .{});
            return error.InvalidArguments;
        }
        const allocator = process_init.arena.allocator();
        const io = process_init.io;
        const root = try std.Io.Dir.cwd().realPathFileAlloc(io, args[1], allocator);
        const name = args[2];
        const manifest_path = try std.Io.Dir.path.join(allocator, &.{ root, "build.zig.zon" });
        const source = try mod.File.readOptionalZ(allocator, io, manifest_path, .limited(Manifest.max_bytes)) orelse {
            log.err("no build.zig.zon in {s}", .{root});
            return error.DepsFailed;
        };
        const manifest = Manifest.parse(allocator, source) catch |err| {
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
        const repository = ReleasePin.repository(url) orelse {
            log.err("{s}'s .url is not a git+ URL, so it has no tags to pin to: {s}", .{ name, url });
            return error.DepsFailed;
        };
        const current = ReleasePin.ref(url);
        // The URL keeps its form: `?ref=<ref>#<commit>` from `zig fetch --save`, or `#<ref>` from `--save-exact`.
        const save = try allocator.print("{s}={s}", .{ if (std.mem.find(u8, url, "?ref=") == null) "--save-exact" else "--save", name });
        if (ReleasePin.isBranch(current)) {
            // A branch is followed, never swapped for a tag: refresh its commit and hash.
            const target = if (current.len == 0) try allocator.print("git+{s}", .{repository}) else try allocator.print("git+{s}#{s}", .{ repository, current });
            try Self.zigFetch(io, args[3], root, save, target);
            log.info("refreshed {s} on {s}; the next zig build uses it", .{ name, if (current.len == 0) "its default branch" else current });
            return;
        }
        const listing = mod.Git.remoteTags(allocator, io, root, repository) catch {
            log.err("cannot list the tags of {s}", .{repository});
            return error.DepsFailed;
        };
        const release = ReleasePin.newestRelease(listing) orelse {
            log.err("{s} has no release tag (vX.Y.Z)", .{repository});
            return error.DepsFailed;
        };
        const pinned_commit = ReleasePin.commit(url);
        if (std.mem.eql(u8, current, release.tag)) {
            if (std.mem.eql(u8, pinned_commit, release.commit)) {
                log.info("{s} is already pinned to {s}, the newest release", .{ name, release.tag });
                return;
            }
            // The tag now names another commit (history rewritten), or the URL names none.
            if (pinned_commit.len > 0) log.info("{s} moved from {s} to {s}; re-pinning", .{ release.tag, Sync.short(pinned_commit), Sync.short(release.commit) });
        } else if (ReleasePin.releaseVersion(current)) |pinned| if (pinned.order(release.version) == .gt) {
            // A pin ahead of every tag (a release not tagged yet) is never moved back.
            log.warn("{s} is pinned to {s}, newer than {s}, the newest release tag; left as it is", .{ name, current, release.tag });
            return;
        };
        try Self.zigFetch(io, args[3], root, save, try allocator.print("git+{s}#{s}", .{ repository, release.tag }));
        if (std.mem.eql(u8, current, release.tag)) {
            log.info("pinned {s} to {s} at {s}; the next zig build uses it", .{ name, release.tag, Sync.short(release.commit) });
        } else {
            log.info("pinned {s} to {s} (was {s}); the next zig build uses it", .{ name, release.tag, if (current.len == 0) "unpinned" else current });
        }
    }

    /// `zigbuildx deps <root>`: lists the worktree dependencies.
    /// Runs as the `deps` step.
    ///
    /// Parameters:
    /// - `process_init`: the process's allocator and IO.
    /// - `args`: the command line after the program's path; `args[0]` is the command.
    ///
    /// Return: nothing; `error.InvalidArguments` on a bad command line, `error.DepsFailed` when a worktree is out of line, or IO errors.
    pub fn command(process_init: std.process.Init, args: []const [:0]const u8) !void {
        const io = process_init.io;
        if (args.len != 2) {
            log.err("usage: zigbuildx deps <root>", .{});
            return error.InvalidArguments;
        }
        const allocator = process_init.arena.allocator();
        const root = try std.Io.Dir.cwd().realPathFileAlloc(io, args[1], allocator);
        var run = try Sync.init(allocator, io, root);
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
    /// Use it to guard a top-level `@import` of a dependency's `build.zig`.
    ///
    /// Parameters:
    /// - `name`: the dependency's field name in `build.zig.zon`.
    ///
    /// Return: `true` when present, when this package is not the root, or when the root is not a build runner.
    pub fn isPresent(comptime name: []const u8) bool {
        // The runner's generated table answers for the root package only.
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
    /// Parameters:
    /// - `zon`: the caller's `@import("build.zig.zon")`.
    /// - `name`: the dependency's field name in `build.zig.zon`.
    ///
    /// Return: `true` when both fields are present.
    pub fn isCloneable(comptime zon: anytype, comptime name: []const u8) bool {
        // An `.archive` is not cloneable: it is unpacked in the same build, so never makes cloneMissing noreturn.
        const Dep = @TypeOf(@field(zon.dependencies, name));
        return @hasField(Dep, "path") and @hasField(Dep, "clone");
    }

    /// Runs `zig fetch` in `root` to rewrite a dependency's `.url` and `.hash`.
    ///
    /// Parameters:
    /// - `io`: IO the child is spawned on.
    /// - `zig`: the `zig` executable.
    /// - `root`: the package whose `build.zig.zon` is rewritten.
    /// - `save`: `--save=<name>` or `--save-exact=<name>`.
    /// - `target`: the `git+` URL to fetch.
    ///
    /// Return: nothing; `error.DepsFailed` when `zig fetch` fails, or spawn errors.
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
    /// Parameters:
    /// - `b`: the root package's build graph.
    fn addPinStep(b: *std.Build) void {
        const top = b.step("zigbuildx-pin", "Pin zigbuildx in build.zig.zon to its newest release tag");
        // Found by identity, whatever the root named it; none when zigbuildx comes only through another dependency.
        const name = mod.ToolArtifact.dependencyName() orelse {
            top.dependOn(&b.addFail("zigbuildx-pin: build.zig.zon does not list zigbuildx itself, so there is nothing to pin").step);
            return;
        };
        const run = b.addRunArtifact(mod.ToolArtifact.add(b));
        run.setName("zigbuildx-pin");
        run.addArg("pin");
        run.addDirectoryArg2(b.path("."), .{});
        run.addArg(name);
        run.addArg(b.graph.zig_exe);
        // It asks the network and rewrites build.zig.zon: never cached.
        run.has_side_effects = true;
        top.dependOn(&run.step);
    }

    /// Updates the siblings and, for `sync`, the branch worktrees; exits when anything moved.
    ///
    /// Parameters:
    /// - `run`: the run, after `run` or `cloneSiblings`.
    /// - `worktrees`: whether to update worktrees too (`sync`).
    fn applyUpdate(run: *Sync, worktrees: bool) void {
        const moved = run.updateSiblings() catch |err| {
            log.err("cannot update dependencies [{any}]", .{err});
            std.process.exit(1);
        };
        const updated: Updated = if (worktrees) run.update() catch |err| {
            log.err("cannot update dependencies [{any}]", .{err});
            std.process.exit(1);
        } else .{};
        // Every build updates, so a skip or an offline fetch only warns: it must not stop the build.
        if (updated.failed > 0) log.warn("{d} worktree dependencies were not updated; see the warnings above", .{updated.failed});
        if (moved or updated.moved > 0) {
            log.info("dependencies updated; re-run zig build", .{});
            std.process.exit(1);
        }
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

    /// Reports whether a package the build runner was compiled without is now a Zig package on disk.
    ///
    /// Parameters:
    /// - `b`: the root package's build graph.
    /// - `root`: its absolute root.
    /// - `missing`: the runner's key for the missing package (its path from the root), or null when none is known.
    ///
    /// Return: `true` when its `build.zig` exists now.
    fn appearedOnDisk(b: *std.Build, root: []const u8, missing: ?[]const u8) bool {
        const path = missing orelse return false;
        const build_zig = std.Io.Dir.path.join(b.allocator, &.{ root, path, "build.zig" }) catch return false;
        return mod.File.exists(b.graph.io, build_zig) catch false;
    }

    /// Reports whether `path` is the `.path` of one of the root's `.archive` dependencies.
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
            // The runner keys a `.path` package by its `.path` as the manifest writes it: compare as written.
            if (@hasField(Dep, "archive") and @hasField(Dep, "path") and std.mem.eql(u8, dep.path, path)) return true;
        }
        return false;
    }

    /// Reports whether every worktree dependency, transitive ones included, was present when the build runner was compiled.
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
    /// Return: its path from the root, or `null` when none is missing or the root is not a build runner.
    fn missingWorktree(comptime zon: anytype) ?[]const u8 {
        const root = @import("root");
        if (!@hasDecl(root, "dependencies")) return null;
        const packages = root.dependencies.packages;
        // A `.path` package is keyed by its path from the root: a worktree is any key under `deps/`, transitive ones included.
        for (@typeInfo(packages).@"struct".decl_names) |decl_name| {
            if (Self.isUnderDeps(decl_name) and !@hasDecl(@field(packages, decl_name), "build_zig") and !Self.isRootArchive(zon, decl_name)) return decl_name;
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
    /// Parameters:
    /// - `zon`: the caller's `@import("build.zig.zon")`; its `.archive` paths are skipped.
    ///
    /// Return: its path from the root, or `null` when none is missing or the root is not a build runner.
    fn missingSibling(comptime zon: anytype) ?[]const u8 {
        const root = @import("root");
        if (!@hasDecl(root, "dependencies")) return null;
        const packages = root.dependencies.packages;
        for (@typeInfo(packages).@"struct".decl_names) |decl_name| {
            const package = @field(packages, decl_name);
            // A `.path` package's key is its `build_root`; a fetched one is keyed by hash and lives in a
            // cache, so an unfetched lazy dependency is not mistaken for one.
            const is_path = std.mem.eql(u8, package.build_root, decl_name);
            // The root's own archives are unpacked in the same build; a sibling's is unknown at comptime and costs a re-run.
            if (is_path and !Self.isUnderDeps(decl_name) and !@hasDecl(package, "build_zig") and !Self.isRootArchive(zon, decl_name)) return decl_name;
        }
        return null;
    }

    /// Reports whether a key of the build runner's package table is a path under the root's `deps/`.
    ///
    /// Parameters:
    /// - `key`: a package's key; a `.path` package's is its path from the root, with the host's separator.
    ///
    /// Return: `true` for `deps/<x>` or `deps\<x>`.
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

test "ReleasePin reads a git+ URL's repository and ref" {
    try std.testing.expectEqualStrings("https://github.com/x/zigbuildx", ReleasePin.repository("git+https://github.com/x/zigbuildx?ref=v3.6.0#fba04ba852fc06317207bdc7119b58dc13638ac0").?);
    try std.testing.expectEqualStrings("https://github.com/x/zigbuildx", ReleasePin.repository("git+https://github.com/x/zigbuildx#main").?);
    try std.testing.expectEqual(null, ReleasePin.repository("https://example.com/zigbuildx.tar.gz"));
    try std.testing.expectEqualStrings("v3.6.0", ReleasePin.ref("git+https://github.com/x/zigbuildx?ref=v3.6.0#fba04ba852fc06317207bdc7119b58dc13638ac0"));
    try std.testing.expectEqualStrings("main", ReleasePin.ref("git+https://github.com/x/zigbuildx#main"));
    try std.testing.expectEqualStrings("", ReleasePin.ref("git+https://github.com/x/zigbuildx"));
}

test "ReleasePin takes an annotated tag's commit from its peeled line" {
    const listing =
        "1111111111111111111111111111111111111111\trefs/tags/v4.1.0\n" ++
        "2222222222222222222222222222222222222222\trefs/tags/v4.1.0^{}\n" ++
        "3333333333333333333333333333333333333333\trefs/tags/v4.0.0\n" ++
        "4444444444444444444444444444444444444444\trefs/tags/v4.0.0^{}\n";
    const newest = ReleasePin.newestRelease(listing).?;
    try std.testing.expectEqualStrings("v4.1.0", newest.tag);
    // The commit, not the tag object: a `?ref=v4.1.0#<commit>` URL names the commit.
    try std.testing.expectEqualStrings("2222222222222222222222222222222222222222", newest.commit);
}

test "ReleasePin reads the pinned commit and tells a branch from a tag or a commit" {
    try std.testing.expectEqualStrings("fba04ba852fc06317207bdc7119b58dc13638ac0", ReleasePin.commit("git+https://github.com/x/zigbuildx?ref=v3.6.0#fba04ba852fc06317207bdc7119b58dc13638ac0"));
    // `--save-exact` keeps `#<ref>`, which names no commit.
    try std.testing.expectEqualStrings("", ReleasePin.commit("git+https://github.com/x/zigbuildx#main"));
    try std.testing.expect(ReleasePin.isBranch("main"));
    try std.testing.expect(ReleasePin.isBranch(""));
    try std.testing.expect(!ReleasePin.isBranch("v4.1.0"));
    try std.testing.expect(!ReleasePin.isBranch("fba04ba852fc06317207bdc7119b58dc13638ac0"));
    try std.testing.expect(ReleasePin.isCommit("fba04ba852fc06317207bdc7119b58dc13638ac0"));
    try std.testing.expect(!ReleasePin.isCommit("fba04ba"));
}

test "ReleasePin picks the newest release tag by version, not by listing order" {
    const listing =
        "cc0f3e78820c1f628de09fd3cddb83d795a25542\trefs/tags/v1.0.0\n" ++
        "7075087e013cd2313cfa7ce1b603a8d2388632d5\trefs/tags/v3.10.0\n" ++
        "fba04ba852fc06317207bdc7119b58dc13638ac0\trefs/tags/v3.6.0\r\n" ++
        "4618f3da19ff5b7b259ad67b0c4ee22d5a1892ab\trefs/tags/v9.0.0-rc1\n" ++
        "6b20787689b19cad79ef2f1b2520b28dadf34299\trefs/tags/nightly\n";
    const newest = ReleasePin.newestRelease(listing).?;
    try std.testing.expectEqualStrings("v3.10.0", newest.tag);
    try std.testing.expectEqualStrings("7075087e013cd2313cfa7ce1b603a8d2388632d5", newest.commit);
    try std.testing.expectEqual(null, ReleasePin.newestRelease("6b20787689b19cad79ef2f1b2520b28dadf34299\trefs/tags/nightly\n"));
    try std.testing.expectEqual(null, ReleasePin.newestRelease(""));
    try std.testing.expectEqual(std.SemanticVersion{ .major = 4, .minor = 1, .patch = 0 }, ReleasePin.releaseVersion("v4.1.0").?);
    try std.testing.expectEqual(null, ReleasePin.releaseVersion("main"));
    try std.testing.expectEqual(null, ReleasePin.releaseVersion("4.1.0"));
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

    /// Resolves `rev_` in the repository at `sub`.
    ///
    /// Parameters:
    /// - `self`: the fixture.
    /// - `sub`: the repository, relative to the scratch root.
    /// - `rev_`: the revision.
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
        var archive = mod.ZipBuilder.init(self.allocator());
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

test "update never fetches the checkout of a tag or a SHA" {
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
    // Neither the worktree nor its checkout's copy of the tag moved: nothing was fetched.
    try std.testing.expectEqualStrings(pinned, try tree.rev("consumer/deps/leaf", "HEAD"));
    try std.testing.expectEqualStrings(pinned, try tree.rev("leaf", "refs/tags/v1"));
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
    // A sibling with work of its own is never fetched: its view of upstream is still v1.
    for ([_][]const u8{ "dirty", "ahead" }) |name| {
        try std.testing.expectEqualStrings(try tree.rev(try tree.allocator().print("origin/{s}", .{name}), "v1"), try tree.rev(name, "refs/remotes/origin/main"));
    }
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

test "a sibling with a .branch is cloned on it, followed, and left alone on another branch" {
    var tree = try TestTree.init();
    defer tree.deinit();
    try tree.upstream("mid", "");
    const origin = try tree.path("origin/mid");
    try tree.run(&.{ "git", "-C", origin, "checkout", "--quiet", "-b", "dev" });
    try tree.commit(origin, "two");
    try tree.run(&.{ "git", "-C", origin, "checkout", "--quiet", "main" });
    try tree.consumer(try tree.allocator().print(".mid = .{{ .path = \"../mid\", .clone = \"{s}\", .branch = \"dev\" }},", .{origin}));
    const first = try tree.sync();
    try std.testing.expect(first.changed);
    try std.testing.expectEqualStrings("dev", (try mod.Git.currentBranch(tree.allocator(), tree.io, try tree.path("mid"))).?);

    // Followed: dev moved upstream, so the sibling does.
    try tree.run(&.{ "git", "-C", origin, "checkout", "--quiet", "dev" });
    try tree.commit(origin, "three");
    var run_ = try tree.sync();
    try std.testing.expect(try run_.updateSiblings());
    try std.testing.expectEqualStrings(try tree.rev("origin/mid", "dev"), try tree.rev("mid", "HEAD"));

    // On another branch: the developer's choice, so it is neither fetched nor moved.
    try tree.run(&.{ "git", "-C", try tree.path("mid"), "checkout", "--quiet", "main" });
    try tree.commit(origin, "four");
    var again = try tree.sync();
    try std.testing.expect(!try again.updateSiblings());
    try std.testing.expectEqualStrings(try tree.rev("origin/mid", "main"), try tree.rev("mid", "HEAD"));
    try std.testing.expectEqualStrings(try tree.rev("origin/mid", "dev~1"), try tree.rev("mid", "refs/remotes/origin/dev"));
}

test "two manifests naming different branches for one sibling: the first found wins" {
    var tree = try TestTree.init();
    defer tree.deinit();
    try tree.upstream("leaf", "");
    const leaf_origin = try tree.path("origin/leaf");
    try tree.run(&.{ "git", "-C", leaf_origin, "branch", "dev" });
    try tree.upstream("mid", try tree.allocator().print(".leaf = .{{ .path = \"../leaf\", .clone = \"{s}\", .branch = \"dev\" }},", .{leaf_origin}));
    try tree.consumer(try tree.allocator().print("{s} .leaf = .{{ .path = \"../leaf\", .clone = \"{s}\", .branch = \"main\" }},", .{ try tree.sibling("mid"), leaf_origin }));
    const run_ = try tree.sync();
    const leaf = run_.findSibling(try tree.path("leaf")).?;
    try std.testing.expectEqualStrings("main", leaf.branch.?);
    try std.testing.expectEqualStrings("consumer", leaf.declared_by);
    try std.testing.expectEqualStrings("main", (try mod.Git.currentBranch(tree.allocator(), tree.io, try tree.path("leaf"))).?);
}

test "cloneSiblings fills in a checkout a clone left empty" {
    var tree = try TestTree.init();
    defer tree.deinit();
    try tree.upstream("mid", "");
    const empty = try tree.path("mid");
    try tree.run(&.{ "git", "init", "--quiet", "--initial-branch=main", empty });
    try tree.run(&.{ "git", "-C", empty, "remote", "add", "origin", try tree.path("origin/mid") });
    try tree.consumer(try tree.sibling("mid"));
    var run_ = try Sync.init(tree.allocator(), tree.io, try tree.path("consumer"));
    try run_.cloneSiblings();
    try std.testing.expect(run_.changed);
    try tree.tmp.dir.access(tree.io, "mid/build.zig.zon", .{});
    try std.testing.expectEqualStrings(try tree.rev("origin/mid", "HEAD"), try tree.rev("mid", "HEAD"));
    // On the branch, tracking it, so the next update follows it.
    try std.testing.expectEqualStrings(try tree.rev("origin/mid", "HEAD"), try tree.rev("mid", "@{u}"));
    var again = try Sync.init(tree.allocator(), tree.io, try tree.path("consumer"));
    try again.cloneSiblings();
    try std.testing.expect(!again.changed);
}

test "cloneSiblings refuses an empty checkout of an empty remote, and a directory that is no package" {
    var tree = try TestTree.init();
    defer tree.deinit();
    const bare = try tree.path("origin/mid");
    try tree.run(&.{ "git", "init", "--quiet", "--bare", bare });
    const empty = try tree.path("mid");
    try tree.run(&.{ "git", "init", "--quiet", empty });
    try tree.run(&.{ "git", "-C", empty, "remote", "add", "origin", bare });
    try tree.consumer(try tree.sibling("mid"));
    var run_ = try Sync.init(tree.allocator(), tree.io, try tree.path("consumer"));
    try std.testing.expectError(error.DepsFailed, run_.cloneSiblings());
    try std.testing.expect(std.mem.find(u8, run_.problem, "has no commits yet") != null);

    // Files of its own: never touched.
    try tree.write("junk/notes", "x");
    try tree.consumer(try tree.sibling("junk"));
    var junk = try Sync.init(tree.allocator(), tree.io, try tree.path("consumer"));
    try std.testing.expectError(error.DepsFailed, junk.cloneSiblings());
    try std.testing.expect(std.mem.find(u8, junk.problem, "is not a Zig package") != null);
    try tree.tmp.dir.access(tree.io, "junk/notes", .{});
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
    // The update leaves an archive alone: it is no git checkout, and its URL is its pin.
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
