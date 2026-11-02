const std = @import("std");
const log = std.log.scoped(.zigbuildx_stage);
const mod = @import("module.zig");

/// How far `Stage.stage` has got with a sibling.
const State = enum {
    /// Prepared, not staged yet.
    queued,
    /// Its own siblings are being staged: meeting it again is a cycle.
    visiting,
    /// In the package store, with its hash known.
    staged,
};

/// A dependency of a staged package on another staged sibling.
const Edge = struct {
    const Self = @This();
    /// The field name the declaring manifest gives it.
    name: []const u8,
    /// The sibling, an index into `Stage.nodes`.
    node: usize,
    /// Whether the declaring manifest marks it `.lazy`, which its rewritten entry keeps.
    lazy: bool,
};

/// A sibling `Stage` stages: a `.path` that leaves the package declaring it.
const Node = struct {
    const Self = @This();
    /// The declared path, resolved: the sibling's identity, as in `Sync`.
    dir: []const u8,
    /// `dir` relative to the root, for messages.
    rel: []const u8,
    /// Where it comes from.
    source: mod.Source,
    /// The branch or tag a clone is staged at; null for the remote's default branch.
    ref: ?mod.Pin,
    /// The package whose manifest declared it first.
    declared_by: []const u8,
    /// The staged copy: the export of its commit, or the unpacked archive.
    export_dir: []const u8 = "",
    /// The commit staged; empty for an archive.
    commit: []const u8 = "",
    /// Its own siblings.
    edges: []const Edge = &.{},
    /// How far staging has got.
    state: State = .queued,
    /// The `.url` written for it: a label, never fetched while its hash is in the store.
    url: []const u8 = "",
    /// Its package hash.
    hash: []const u8 = "",
};

/// Stages a consumer's siblings into Zig's package store for a distribution build, and rewrites its `build.zig.zon` to name them by hash.
///
/// Each sibling (a `.path` outside the package that declares it) is cloned
/// with git, through the machine's own credentials, or unpacked from its
/// `.archive`; its commit is exported; its own siblings are staged first and
/// written into its manifest; and `zig fetch` hashes the local copy, which then
/// goes into the consumer's `zig-pkg/`. Zig never fetches a sibling itself, so
/// a private repository needs no credentials Zig lacks, and nothing outside the
/// consumer is read by the build.
pub const Stage = struct {
    const Self = @This();
    /// The backup of the manifest a rewrite replaces, beside it.
    pub const backup_name = "build.zig.zon.orig";
    /// Allocates everything the run holds; an arena, freed all at once.
    allocator: std.mem.Allocator,
    /// IO for the filesystem and the children.
    io: std.Io,
    /// The consumer's absolute root.
    root: []const u8,
    /// The `zig` executable that hashes each staged copy.
    zig: []const u8,
    /// Clones and exports: `<root>/.zig-cache/zigbuildx-dist`.
    work: []const u8,
    /// The environment `zig fetch` runs in; null to inherit the build's. Tests point `ZIG_GLOBAL_CACHE_DIR` at a scratch cache.
    environ_map: ?*const std.process.Environ.Map = null,
    /// Every sibling found, in the order found: the root's first.
    nodes: std.ArrayList(Node) = .empty,
    /// Whether the root's manifest was rewritten, so the build must re-run.
    rewrote: bool = false,
    /// What went wrong, when a function returns `error.DepsFailed`.
    problem: []const u8 = "",

    /// Creates a run for the consumer at `root`.
    ///
    /// - `allocator`: An arena for everything the run allocates.
    /// - `io`: IO for the filesystem and the children.
    /// - `root`: The consumer's absolute root.
    /// - `zig`: The `zig` executable, `b.graph.zig_exe` in a build.
    /// - Returns: The run.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, root: []const u8, zig: []const u8) !Self {
        const work = try std.Io.Dir.path.join(allocator, &.{ root, ".zig-cache", "zigbuildx-dist" });
        return .{ .allocator = allocator, .io = io, .root = root, .zig = zig, .work = work };
    }

    /// Stages every sibling of the root, its siblings' siblings included, and rewrites the root's manifest to name them by hash.
    /// Does nothing when the root names no sibling, as on the re-run after a rewrite.
    ///
    /// - `self`: The run.
    /// - Returns: `error.DepsFailed` with `problem` set, or IO and spawn errors.
    pub fn run(self: *Self) !void {
        const lock = try mod.Sync.lockRoot(self.allocator, self.io, self.root);
        defer lock.close(self.io);
        const manifest_path = try std.Io.Dir.path.join(self.allocator, &.{ self.root, "build.zig.zon" });
        const source = try mod.File.readOptionalZ(self.allocator, self.io, manifest_path, .limited(mod.Manifest.max_bytes)) orelse return self.fail("no build.zig.zon in {s}", .{self.root});
        const manifest = mod.Manifest.parse(self.allocator, source) catch return self.fail("cannot parse {s}", .{manifest_path});
        const edges = try self.collect(manifest, self.root);
        if (edges.len == 0) return;
        // Breadth first, so the root's declarations, then the nearer ones, win; the list grows while it is walked.
        var i: usize = 0;
        while (i < self.nodes.items.len) : (i += 1) try self.prepare(i);
        // Depth first: a package's hash covers its manifest, so its siblings are staged and written into it first.
        for (edges) |edge| try self.stage(edge.node);
        const rewritten = try self.rewrite(source, edges);
        // Written last, so a failure above leaves the manifest as it was; the backup goes first.
        const backup = try std.Io.Dir.path.join(self.allocator, &.{ self.root, Self.backup_name });
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = backup, .data = source });
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = manifest_path, .data = rewritten });
        self.rewrote = true;
        log.info("rewrote build.zig.zon to build {d} staged siblings; the original is {s}, and zig build dev puts it back", .{ self.nodes.items.len, Self.backup_name });
    }

    /// Logs why the run failed: the `problem` `fail` recorded, or else the error itself.
    ///
    /// - `self`: The run.
    /// - `err`: The error the run returned.
    pub fn logFailure(self: *const Self, err: anyerror) void {
        if (err == error.DepsFailed) {
            log.err("{s}", .{self.problem});
        } else {
            log.err("cannot stage dependencies [{any}]", .{err});
        }
    }

    /// Names the `.url` written for a sibling cloned from `clone` at `commit`: a `git+` URL Zig accepts as one.
    ///
    /// - `allocator`: Allocator for the result.
    /// - `clone`: The sibling's `.clone`: a URL, an scp-style `user@host:path`, or a local path.
    /// - `commit`: The commit staged.
    /// - Returns: `git+<scheme>://…#<commit>`; allocation errors.
    pub fn labelOf(allocator: std.mem.Allocator, clone: []const u8, commit: []const u8) ![]const u8 {
        const bare = if (std.mem.startsWith(u8, clone, "git+")) clone["git+".len..] else clone;
        if (std.mem.find(u8, bare, "://") != null) return allocator.print("git+{s}#{s}", .{ bare, commit });
        const colon = std.mem.findScalar(u8, bare, ':');
        const slash = std.mem.findScalar(u8, bare, '/');
        // `git@host:org/x.git`, as git reads it: a colon before any slash, and not a Windows drive (`C:`).
        if (colon) |at| if (at > 1 and (slash == null or at < slash.?)) {
            return allocator.print("git+ssh://{s}/{s}#{s}", .{ bare[0..at], std.mem.trimStart(u8, bare[at + 1 ..], "/"), commit });
        };
        // A local path: Zig rejects scp syntax and backslashes alike as a URI.
        const path = try std.mem.replaceOwned(u8, allocator, bare, "\\", "/");
        defer allocator.free(path);
        return allocator.print("git+file://{s}{s}#{s}", .{ if (std.mem.startsWith(u8, path, "/")) "" else "/", path, commit });
    }

    /// Lists the siblings `manifest` declares, queueing any not found before.
    ///
    /// - `self`: The run.
    /// - `manifest`: The declaring package's manifest.
    /// - `dir`: Where the declaring package is declared: the root, or a sibling's `dir`.
    /// - Returns: An edge per sibling; `error.DepsFailed` for one dist mode cannot stage, or allocation errors.
    fn collect(self: *Self, manifest: mod.Manifest, dir: []const u8) ![]const Edge {
        var edges: std.ArrayList(Edge) = .empty;
        const is_root = std.mem.eql(u8, dir, self.root);
        for (manifest.entries) |entry| {
            const path = entry.path orelse continue;
            const resolved = try std.Io.Dir.path.resolveAlloc(self.allocator, &.{ dir, path });
            if (Self.isInside(dir, resolved)) {
                // Inside the package it ships with it, except a `sync` worktree, which no export holds.
                if (!is_root and Self.isPinned(entry) and Self.isUnderDeps(dir, resolved)) {
                    return self.fail("{s} has a worktree dependency {s} (a pinned .path under deps/); dist mode stages siblings only", .{ manifest.name, entry.name });
                }
                continue;
            }
            if (std.mem.eql(u8, resolved, self.root)) return self.fail("{s} depends on the root package; dist mode cannot stage a cycle", .{manifest.name});
            const node = try self.add(resolved, entry, manifest.name);
            try edges.append(self.allocator, .{ .name = entry.name, .node = node, .lazy = entry.lazy });
        }
        return edges.items;
    }

    /// Queues the sibling at `dir`, or finds it queued already; the first declaration wins.
    ///
    /// - `self`: The run.
    /// - `dir`: The sibling's resolved path.
    /// - `entry`: The declaring dependency.
    /// - `declared_by`: The declaring package's name.
    /// - Returns: The sibling's index in `nodes`; `error.DepsFailed` for a sibling with no source or with a `.sha`.
    fn add(self: *Self, dir: []const u8, entry: mod.Entry, declared_by: []const u8) !usize {
        const ref = try self.refOf(declared_by, entry);
        for (self.nodes.items, 0..) |node, i| {
            if (!std.mem.eql(u8, node.dir, dir)) continue;
            if (ref) |want| {
                const agrees = if (node.ref) |had| had.satisfies(want) else false;
                if (!agrees) log.warn("{s} wants {s} at {t} {s}; {s}'s declaration wins", .{ declared_by, node.rel, want.kind, want.value, node.declared_by });
            }
            return i;
        }
        const rel = try std.Io.Dir.path.relativeAlloc(self.allocator, self.root, null, self.root, dir);
        if (entry.clone != null and entry.archive != null) return self.fail("{s}: {s} sets both .clone and .archive", .{ declared_by, entry.name });
        const source: mod.Source = if (entry.clone) |url| .{ .clone = url } else if (entry.archive) |url| .{ .archive = url } else {
            return self.fail("{s}: {s} ({s}) has neither a .clone nor an .archive, so dist mode cannot stage it", .{ declared_by, entry.name, rel });
        };
        if (source == .archive and ref != null) return self.fail("{s} pins {s}, but an .archive dependency is pinned by its URL alone", .{ declared_by, entry.name });
        try self.nodes.append(self.allocator, .{ .dir = dir, .rel = rel, .source = source, .ref = ref, .declared_by = declared_by });
        return self.nodes.items.len - 1;
    }

    /// Reads the ref a sibling is staged at: its `.branch` or `.tag`.
    ///
    /// - `self`: The run.
    /// - `package`: The declaring package, for the message.
    /// - `entry`: The dependency.
    /// - Returns: The ref, or `null` for the remote's default branch; `error.DepsFailed` for a `.sha`, more than one pin, or an invalid value.
    fn refOf(self: *Self, package: []const u8, entry: mod.Entry) !?mod.Pin {
        if (entry.sha != null) return self.fail("{s}: {s} sets a .sha, but only a worktree is frozen at one", .{ package, entry.name });
        if (entry.branch != null and entry.tag != null) return self.fail("{s}: {s} sets both .branch and .tag", .{ package, entry.name });
        const pin: mod.Pin = if (entry.branch) |value| .{ .kind = .branch, .value = value } else if (entry.tag) |value| .{ .kind = .tag, .value = value } else return null;
        if (!mod.Pin.isValidValue(pin.value)) return self.fail("{s}: {s} has an invalid .{t}: \"{s}\"", .{ package, entry.name, pin.kind, pin.value });
        return pin;
    }

    /// Fetches sibling `index` into a local copy and queues the siblings its manifest declares.
    ///
    /// - `self`: The run.
    /// - `index`: The sibling, in `nodes`.
    /// - Returns: `error.DepsFailed` when it cannot be fetched or lacks its ref, or IO and git errors.
    fn prepare(self: *Self, index: usize) !void {
        const node = self.nodes.items[index];
        const base = std.Io.Dir.path.basename(node.dir);
        // One export per sibling, keyed by its path: two siblings may clone one repository at two refs.
        const export_key = try self.allocator.print("{s}-{x:0>16}", .{ base, std.hash.Wyhash.hash(0, node.dir) });
        const export_dir = try std.Io.Dir.path.join(self.allocator, &.{ self.work, "export", export_key });
        try std.Io.Dir.cwd().deleteTree(self.io, export_dir);
        var commit: []const u8 = "";
        switch (node.source) {
            .clone => |clone| {
                // One clone per repository, kept between runs so it is fetched, not cloned again; it is
                // only read (`rev-parse`, `archive`), never checked out, so siblings can share it.
                const clone_key = try self.allocator.print("{s}-{x:0>16}", .{ base, std.hash.Wyhash.hash(0, clone) });
                const checkout = try std.Io.Dir.path.join(self.allocator, &.{ self.work, "clones", clone_key });
                if (try mod.File.exists(self.io, checkout)) {
                    mod.Git.fetch(self.allocator, self.io, checkout, "origin") catch return self.fail("cannot fetch {s} for {s}", .{ clone, node.rel });
                } else {
                    try mod.File.createParentDir(self.io, checkout);
                    mod.Git.clone(self.io, clone, checkout, null) catch return self.fail("cannot clone {s} for {s}", .{ clone, node.rel });
                }
                const rev = if (node.ref) |ref| switch (ref.kind) {
                    .tag => try self.allocator.print("refs/tags/{s}", .{ref.value}),
                    else => try self.allocator.print("refs/remotes/origin/{s}", .{ref.value}),
                } else "refs/remotes/origin/HEAD";
                commit = try mod.Git.revParse(self.allocator, self.io, checkout, rev) orelse {
                    return self.fail("{s} has no {s} for {s}", .{ clone, if (node.ref) |ref| try self.allocator.print("{t} {s}", .{ ref.kind, ref.value }) else "default branch", node.rel });
                };
                try self.exportCommit(checkout, commit, export_dir);
            },
            .archive => |archive| mod.ZipArchive.unpack(self.allocator, self.io, archive, export_dir) catch |err| {
                return self.fail("cannot unpack {s} for {s} [{any}]", .{ archive, node.rel, err });
            },
        }
        self.nodes.items[index].export_dir = export_dir;
        self.nodes.items[index].commit = commit;
        const manifest_path = try std.Io.Dir.path.join(self.allocator, &.{ export_dir, "build.zig.zon" });
        // A package without a manifest (an archive, often) has no siblings.
        const source = try mod.File.readOptionalZ(self.allocator, self.io, manifest_path, .limited(mod.Manifest.max_bytes)) orelse return;
        const manifest = mod.Manifest.parse(self.allocator, source) catch return self.fail("cannot parse the build.zig.zon of {s}", .{node.rel});
        // `collect` grows `nodes`, so the edges are stored by index afterwards.
        const edges = try self.collect(manifest, node.dir);
        self.nodes.items[index].edges = edges;
    }

    /// Writes the tracked files of `commit` in `checkout` into `dest`.
    ///
    /// - `self`: The run.
    /// - `checkout`: The clone.
    /// - `commit`: The commit staged.
    /// - `dest`: The export directory; absent.
    /// - Returns: IO, git and tar errors.
    fn exportCommit(self: *Self, checkout: []const u8, commit: []const u8, dest: []const u8) !void {
        const cwd = std.Io.Dir.cwd();
        const tar_path = try self.allocator.print("{s}.tar", .{dest});
        defer cwd.deleteFile(self.io, tar_path) catch |err| log.warn("cannot delete {s} [{any}]", .{ tar_path, err });
        // Also creates the tar's directory, beside `dest`.
        try cwd.createDirPath(self.io, dest);
        // Exactly the commit: an untracked file in the clone never reaches the package.
        try mod.Git.archive(self.allocator, self.io, checkout, commit, tar_path);
        var out = try cwd.openDir(self.io, dest, .{});
        defer out.close(self.io);
        var file = try cwd.openFile(self.io, tar_path, .{});
        defer file.close(self.io);
        var buffer: [16 * 1024]u8 = undefined;
        var reader = file.reader(self.io, &buffer);
        // In process, so no host needs `tar` on its PATH.
        try std.tar.extract(self.io, out, &reader.interface, .{});
    }

    /// Puts sibling `index` into the consumer's `zig-pkg/`, after its own siblings, under the hash Zig gives it.
    ///
    /// - `self`: The run.
    /// - `index`: The sibling, in `nodes`.
    /// - Returns: `error.DepsFailed` for a cycle or a failed `zig fetch`, or IO errors.
    fn stage(self: *Self, index: usize) !void {
        switch (self.nodes.items[index].state) {
            .staged => return,
            .visiting => return self.fail("{s} depends on itself through its siblings; dist mode cannot stage a cycle", .{self.nodes.items[index].rel}),
            .queued => {},
        }
        self.nodes.items[index].state = .visiting;
        const edges = self.nodes.items[index].edges;
        for (edges) |edge| try self.stage(edge.node);
        const node = self.nodes.items[index];
        if (edges.len > 0) {
            const manifest_path = try std.Io.Dir.path.join(self.allocator, &.{ node.export_dir, "build.zig.zon" });
            const source = (try mod.File.readOptionalZ(self.allocator, self.io, manifest_path, .limited(mod.Manifest.max_bytes))).?;
            try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = manifest_path, .data = try self.rewrite(source, edges) });
        }
        const hash = try self.hashOf(node.export_dir, node.rel);
        // Zig resolves a hash from the consumer's `zig-pkg/` before any cache or URL, so a staged
        // sibling needs neither the network nor the global cache `zig fetch` wrote to.
        const package = try std.Io.Dir.path.join(self.allocator, &.{ self.root, "zig-pkg", hash });
        if (try mod.File.exists(self.io, package)) {
            try std.Io.Dir.cwd().deleteTree(self.io, node.export_dir);
        } else {
            try mod.File.createParentDir(self.io, package);
            try std.Io.Dir.cwd().rename(node.export_dir, std.Io.Dir.cwd(), package, self.io);
        }
        const url = switch (node.source) {
            .clone => |clone| try Self.labelOf(self.allocator, clone, node.commit),
            .archive => |archive| archive,
        };
        self.nodes.items[index].url = url;
        self.nodes.items[index].hash = hash;
        self.nodes.items[index].state = .staged;
        if (node.commit.len > 0) {
            log.info("staged {s} at {s} as {s}", .{ node.rel, mod.Sync.short(node.commit), hash });
        } else {
            log.info("staged {s} as {s}", .{ node.rel, hash });
        }
    }

    /// Returns the package hash Zig gives the directory at `dir`.
    ///
    /// - `self`: The run.
    /// - `dir`: The staged copy.
    /// - `rel`: The sibling, for the message.
    /// - Returns: The package hash; `error.DepsFailed` when `zig fetch` fails, or spawn errors.
    fn hashOf(self: *Self, dir: []const u8, rel: []const u8) ![]const u8 {
        // A local directory: `zig fetch` reads it and nothing else, so Zig never reaches the network.
        const result = try std.process.run(self.allocator, self.io, .{ .argv = &.{ self.zig, "fetch", dir }, .environ_map = self.environ_map });
        const ok = switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (!ok) return self.fail("zig fetch of {s} failed: {s}", .{ rel, std.mem.trim(u8, result.stderr, " \t\r\n") });
        return std.mem.trim(u8, result.stdout, " \t\r\n");
    }

    /// Rewrites each sibling `edges` names, in a manifest's text, to its staged `.url` and `.hash`.
    ///
    /// - `self`: The run.
    /// - `source`: The manifest.
    /// - `edges`: Its siblings, every one staged.
    /// - Returns: The rewritten text; `error.DepsFailed` when a dependency cannot be found in it.
    fn rewrite(self: *Self, source: [:0]const u8, edges: []const Edge) ![:0]const u8 {
        var text: [:0]const u8 = source;
        for (edges) |edge| {
            const node = self.nodes.items[edge.node];
            const value = try self.allocator.print(".{{ .url = \"{f}\", .hash = \"{f}\"{s} }}", .{ std.zig.fmtString(node.url), std.zig.fmtString(node.hash), if (edge.lazy) ", .lazy = true" else "" });
            const edited = mod.ZonEdit.replaceDependency(self.allocator, text, edge.name, value) catch |err| {
                return self.fail("cannot rewrite {s} in a build.zig.zon [{any}]", .{ edge.name, err });
            };
            text = edited orelse return self.fail("cannot find dependency {s} to rewrite", .{edge.name});
        }
        return text;
    }

    /// Reports whether `path` is `dir` or below it.
    ///
    /// - `dir`: An absolute, resolved directory.
    /// - `path`: An absolute, resolved path.
    /// - Returns: `true` when `path` does not leave `dir`.
    fn isInside(dir: []const u8, path: []const u8) bool {
        if (!std.mem.startsWith(u8, path, dir)) return false;
        return path.len == dir.len or std.Io.Dir.path.isSep(path[dir.len]);
    }

    /// Reports whether `path` is a direct child of `dir`'s `deps` directory.
    ///
    /// - `dir`: The package's resolved directory.
    /// - `path`: A resolved path inside it.
    /// - Returns: `true` for `<dir>/deps/<x>`.
    fn isUnderDeps(dir: []const u8, path: []const u8) bool {
        const parent = std.Io.Dir.path.dirname(path) orelse return false;
        return std.mem.eql(u8, std.Io.Dir.path.basename(parent), "deps") and std.mem.eql(u8, std.Io.Dir.path.dirname(parent) orelse "", dir);
    }

    /// Reports whether `entry` sets a `.sha`, `.tag` or `.branch`.
    ///
    /// - `entry`: The dependency.
    /// - Returns: `true` when it is pinned.
    fn isPinned(entry: mod.Entry) bool {
        return entry.sha != null or entry.tag != null or entry.branch != null;
    }

    /// Records why the run failed, for the caller to log.
    ///
    /// - `self`: The run.
    /// - `fmt`: The message's format.
    /// - `args`: Its arguments.
    /// - Returns: `error.DepsFailed` always, or allocation errors.
    fn fail(self: *Self, comptime fmt: []const u8, args: anytype) error{ DepsFailed, OutOfMemory } {
        self.problem = try self.allocator.print(fmt, args);
        return error.DepsFailed;
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test "labelOf turns every .clone form into a git+ URL Zig accepts" {
    const allocator = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "https://host/org/x.git", "git+https://host/org/x.git#c0" },
        .{ "git+https://host/org/x.git", "git+https://host/org/x.git#c0" },
        .{ "ssh://git@host/org/x.git", "git+ssh://git@host/org/x.git#c0" },
        .{ "git@host:org/x.git", "git+ssh://git@host/org/x.git#c0" },
        .{ "git@host:/srv/x.git", "git+ssh://git@host/srv/x.git#c0" },
        .{ "/srv/git/x.git", "git+file:///srv/git/x.git#c0" },
        .{ "C:\\git\\x.git", "git+file:///C:/git/x.git#c0" },
    };
    for (cases) |case| {
        const label = try Stage.labelOf(allocator, case[0], "c0");
        defer allocator.free(label);
        try std.testing.expectEqualStrings(case[1], label);
    }
}

/// Creates a stage of `tree`'s consumer that hashes into a scratch global cache, or skips without the `zig` executable.
///
/// - `tree`: The fixture.
/// - Returns: The run, not started; `error.SkipZigTest` when the build did not pass `ZIGBUILDX_ZIG`.
fn testStage(tree: *mod.TestTree) !Stage {
    const zig = std.testing.environ.getAlloc(tree.allocator(), "ZIGBUILDX_ZIG") catch return error.SkipZigTest;
    var run = try Stage.init(tree.allocator(), tree.io, try tree.path("consumer"), zig);
    // Hashed into a scratch global cache, never the developer's own. It is shared and kept, beside
    // `std.testing`'s own scratch directories: a new one costs `zig fetch` half a minute to set up.
    const cache = try std.Io.Dir.cwd().realPathFileAlloc(tree.io, ".zig-cache", tree.allocator());
    const environ_map = try tree.allocator().create(std.process.Environ.Map);
    environ_map.* = try std.testing.environ.createMap(tree.allocator());
    try environ_map.put("ZIG_GLOBAL_CACHE_DIR", try std.Io.Dir.path.join(tree.allocator(), &.{ cache, "zigbuildx-test-global-cache" }));
    run.environ_map = environ_map;
    return run;
}

/// Runs a stage of `tree`'s consumer that must fail, and returns its problem.
///
/// - `tree`: The fixture.
/// - Returns: The message; `error.TestUnexpectedResult` when the stage succeeds.
fn stageFails(tree: *mod.TestTree) ![]const u8 {
    var run = try testStage(tree);
    run.run() catch |err| {
        try std.testing.expectEqual(error.DepsFailed, err);
        return run.problem;
    };
    return error.TestUnexpectedResult;
}

/// Reads a file of `tree`.
///
/// - `tree`: The fixture.
/// - `sub`: The file, relative to the scratch root.
/// - Returns: Its contents; IO errors.
fn readTree(tree: *mod.TestTree, sub: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(tree.io, try tree.path(sub), tree.allocator(), .limited(1 << 20));
}

test "stage stages siblings leaves first, each once, and rewrites the root to name them by hash" {
    var tree = try mod.TestTree.init();
    defer tree.deinit();
    try tree.upstream("leaf", "");
    try tree.upstream("mid", try tree.siblingWith("leaf", ".tag = \"v1\","));
    try tree.consumer(try std.mem.concat(tree.allocator(), u8, &.{ try tree.siblingWith("mid", ".branch = \"main\","), try tree.siblingWith("leaf", ".tag = \"v1\",") }));
    const original = try readTree(&tree, "consumer/build.zig.zon");

    var run = try testStage(&tree);
    try run.run();
    try std.testing.expect(run.rewrote);
    // `leaf` is declared twice, by the root and by `mid`, and staged once.
    try std.testing.expectEqual(2, run.nodes.items.len);
    const mid = run.nodes.items[0];
    const leaf = run.nodes.items[1];
    try std.testing.expectEqualStrings(try tree.rev("origin/mid", "main"), mid.commit);
    try std.testing.expectEqualStrings(try tree.rev("origin/leaf", "v1"), leaf.commit);
    try std.testing.expect(std.mem.startsWith(u8, mid.hash, "mid-0.0.0-"));

    // The root names both by hash; the original is kept beside it.
    const rewritten = try readTree(&tree, "consumer/build.zig.zon");
    try std.testing.expect(std.mem.find(u8, rewritten, ".path") == null);
    try std.testing.expect(std.mem.find(u8, rewritten, try tree.allocator().print(".hash = \"{s}\"", .{mid.hash})) != null);
    try std.testing.expect(std.mem.find(u8, rewritten, try tree.allocator().print("git+file://{s}#{s}", .{ try tree.path("origin/mid"), mid.commit })) != null);
    try std.testing.expectEqualStrings(original, try readTree(&tree, "consumer/build.zig.zon.orig"));

    // The staged `mid` names its own sibling by hash too, and is in the consumer's `zig-pkg/`.
    const staged_mid = try readTree(&tree, try tree.allocator().print("consumer/zig-pkg/{s}/build.zig.zon", .{mid.hash}));
    try std.testing.expect(std.mem.find(u8, staged_mid, leaf.hash) != null);
    try tree.tmp.dir.access(tree.io, try tree.allocator().print("consumer/zig-pkg/{s}/build.zig", .{leaf.hash}), .{});
    // Nothing is cloned beside the consumer: a dist build reads nothing outside it.
    try std.testing.expectError(error.FileNotFound, tree.tmp.dir.access(tree.io, "mid", .{}));
    try std.testing.expectError(error.FileNotFound, tree.tmp.dir.access(tree.io, "leaf", .{}));

    // The re-run finds no siblings left and changes nothing, the backup included.
    var again = try testStage(&tree);
    try again.run();
    try std.testing.expect(!again.rewrote);
    try std.testing.expectEqualStrings(rewritten, try readTree(&tree, "consumer/build.zig.zon"));
    try std.testing.expectEqualStrings(original, try readTree(&tree, "consumer/build.zig.zon.orig"));
}

test "stage stages an archive sibling under its URL" {
    var tree = try mod.TestTree.init();
    defer tree.deinit();
    const url = try tree.zip("zips/vendored.zip", &.{.{ "vendored-1.0/src/a.c", "int a;\n" }});
    try tree.consumer(try tree.allocator().print(".vendored = .{{ .path = \"../vendored\", .archive = \"{s}\" }},", .{url}));
    var run = try testStage(&tree);
    try run.run();
    const node = run.nodes.items[0];
    try std.testing.expectEqualStrings(url, node.url);
    // No manifest: Zig names the package by its hash alone.
    try std.testing.expect(std.mem.startsWith(u8, node.hash, "N-V-"));
    try tree.tmp.dir.access(tree.io, try tree.allocator().print("consumer/zig-pkg/{s}/src/a.c", .{node.hash}), .{});
}

test "stage refuses what it cannot stage and leaves the manifest as it was" {
    var tree = try mod.TestTree.init();
    defer tree.deinit();
    try tree.upstream("a", try tree.sibling("b"));
    try tree.upstream("b", try tree.sibling("a"));
    try tree.consumer(try tree.sibling("a"));
    const original = try readTree(&tree, "consumer/build.zig.zon");
    try std.testing.expect(std.mem.find(u8, try stageFails(&tree), "cycle") != null);
    try std.testing.expectEqualStrings(original, try readTree(&tree, "consumer/build.zig.zon"));
    try std.testing.expectError(error.FileNotFound, tree.tmp.dir.access(tree.io, "consumer/build.zig.zon.orig", .{}));

    try tree.consumer(".bare = .{ .path = \"../bare\" },");
    try std.testing.expect(std.mem.find(u8, try stageFails(&tree), "neither a .clone nor an .archive") != null);
    try tree.consumer(try tree.siblingWith("a", ".sha = \"0123456\","));
    try std.testing.expect(std.mem.find(u8, try stageFails(&tree), ".sha") != null);
    try tree.consumer(try tree.siblingWith("a", ".tag = \"v9\","));
    try std.testing.expect(std.mem.find(u8, try stageFails(&tree), "has no tag v9") != null);
    try tree.consumer(try tree.siblingWith("a", ".branch = \"--orphan\","));
    try std.testing.expect(std.mem.find(u8, try stageFails(&tree), "invalid .branch") != null);
}

test "stage keeps one repository at two refs apart, and a lazy sibling lazy" {
    var tree = try mod.TestTree.init();
    defer tree.deinit();
    try tree.upstream("lib", "");
    const origin = try tree.path("origin/lib");
    try tree.commit(origin, "two");
    try tree.run(&.{ "git", "-C", origin, "tag", "v2" });
    // Same repository, same folder name, two paths: each needs its own export.
    try tree.consumer(try tree.allocator().print(
        \\.old = .{{ .path = "../lib", .clone = "{s}", .tag = "v1" }},
        \\.new = .{{ .path = "../other/lib", .clone = "{s}", .tag = "v2", .lazy = true }},
    , .{ origin, origin }));
    var run = try testStage(&tree);
    try run.run();
    const old = run.nodes.items[0];
    const new = run.nodes.items[1];
    try std.testing.expectEqualStrings(try tree.rev("origin/lib", "v1"), old.commit);
    try std.testing.expectEqualStrings(try tree.rev("origin/lib", "v2"), new.commit);
    try std.testing.expect(!std.mem.eql(u8, old.hash, new.hash));
    try tree.tmp.dir.access(tree.io, try tree.allocator().print("consumer/zig-pkg/{s}/one", .{old.hash}), .{});
    try tree.tmp.dir.access(tree.io, try tree.allocator().print("consumer/zig-pkg/{s}/two", .{new.hash}), .{});
    try std.testing.expectError(error.FileNotFound, tree.tmp.dir.access(tree.io, try tree.allocator().print("consumer/zig-pkg/{s}/two", .{old.hash}), .{}));
    const rewritten = try readTree(&tree, "consumer/build.zig.zon");
    try std.testing.expect(std.mem.find(u8, rewritten, try tree.allocator().print(".hash = \"{s}\", .lazy = true }}", .{new.hash})) != null);
    try std.testing.expect(std.mem.find(u8, rewritten, try tree.allocator().print(".hash = \"{s}\" }}", .{old.hash})) != null);
}
