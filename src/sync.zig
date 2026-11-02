const std = @import("std");
const log = std.log.scoped(.zigbuildx_sync);
const mod = @import("module.zig");

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
    pin: mod.Pin,
    /// The shared checkout's absolute path.
    checkout: []const u8,
    /// Where to clone the checkout from when it is absent.
    clone: ?[]const u8,
    /// The package whose manifest declared it.
    declared_by: []const u8,
    /// The branch prefix: `<consumer>`, or `<consumer>/<owner>` for a nested worktree.
    branch_prefix: []const u8,
    /// The stamp once the worktree is in place.
    stamp: ?mod.Stamp = null,
};

/// A sibling checkout outside `deps/`, as the manifests declare it.
const Sibling = struct {
    const Self = @This();
    /// The checkout's absolute path.
    dir: []const u8,
    /// The branch it follows (`.branch`) or the tag it is held at (`.tag`); null for none.
    ref: ?mod.Pin,
    /// The package whose manifest declared it first.
    declared_by: []const u8,
};

/// Where a distribution build puts a sibling checkout.
const SiblingTarget = struct {
    const Self = @This();
    /// The sibling.
    sibling: Sibling,
    /// The ref it is brought to: its own, or the remote's default branch.
    ref: mod.Pin,
    /// The revision checked out once fetched: `refs/tags/<tag>` or `refs/remotes/origin/<branch>`.
    rev: []const u8,
    /// Whether the checkout is fetched first.
    fetch: bool,
};

/// Where a pin resolves to in a checkout.
const Target = struct {
    const Self = @This();
    /// The commit.
    sha: []const u8,
    /// The pin it resolves.
    pin: mod.Pin,
    /// The worktree's branch; empty when it is detached.
    branch: []const u8,
};

/// One run of `Deps.sync`: reads the manifests and brings the worktrees in line with them.
///
/// All allocation goes through `allocator`, which should be an arena (the
/// build's, in a build); nothing is freed individually.
pub const Sync = struct {
    const Self = @This();
    /// How many characters of a SHA messages show.
    const short_sha_len = 12;
    /// The revision a sibling with no `.branch` is fast-forwarded to: its branch's upstream.
    const upstream_rev = "@{u}";
    /// Allocates everything the run holds; an arena, freed all at once.
    allocator: std.mem.Allocator,
    /// IO for the filesystem and the `git` children.
    io: std.Io,
    /// The consumer's absolute root.
    root: []const u8,
    /// The root package's `.name`.
    consumer: []const u8 = "",
    /// How siblings are updated: fast-forwarded (`develop`) or brought to their refs (`dist`).
    mode: mod.Mode = .develop,
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
    /// - `allocator`: An arena for everything the run allocates.
    /// - `io`: IO for the filesystem and `git`.
    /// - `root`: The consumer's absolute root.
    /// - Returns: The run.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, root: []const u8) !Self {
        return .{ .allocator = allocator, .io = io, .root = root };
    }

    /// Reads every manifest, then clones, creates, moves and removes until disk matches them.
    ///
    /// - `self`: The run.
    /// - Returns: `error.DepsFailed` with `problem` set, or IO and spawn errors.
    pub fn run(self: *Self) !void {
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

    /// Clones or unpacks every absent `.path` dependency of the root, then of its siblings, as `cloneMissing` does.
    ///
    /// - `self`: The run.
    /// - Returns: `error.DepsFailed` with `problem` set, or IO and clone errors.
    pub fn cloneSiblings(self: *Self) !void {
        const lock = try self.acquireLock();
        defer lock.close(self.io);
        const manifest = try self.readManifest(self.root) orelse return self.fail("no build.zig.zon in {s}", .{self.root});
        // Every `.path` is cloned whatever it pins; no worktree is made.
        for (manifest.entries) |entry| {
            const path = entry.path orelse continue;
            try self.addSibling(try std.Io.Dir.path.resolveAlloc(self.allocator, &.{ self.root, path }), try self.sourceOf(manifest.name, entry), try self.siblingRef(manifest.name, entry), manifest.name);
        }
        try self.followSiblings();
    }

    /// Fetches every sibling checkout with no work of its own and fast-forwards each one that is behind.
    ///
    /// - `self`: The run, after `run` or `cloneSiblings` has queued the siblings.
    /// - Returns: Whether any sibling moved; IO errors.
    pub fn updateSiblings(self: *Self) !bool {
        // Siblings are the developer's own checkouts: a skip only logs, never fails the build.
        // Everything that can rule a sibling out is local, so a skipped one never reaches the network.
        var dirs: std.ArrayList([]const u8) = .empty;
        var tips: std.ArrayList([]const u8) = .empty;
        var remotes: std.ArrayList(?[]const u8) = .empty;
        for (self.siblings.items) |sibling| {
            const tip = try self.siblingTip(sibling) orelse continue;
            try dirs.append(self.allocator, sibling.dir);
            try tips.append(self.allocator, tip);
            // The remote the tip is read from: a `.branch` is `origin`'s, `@{u}` its branch's own upstream's.
            try remotes.append(self.allocator, if (std.mem.eql(u8, tip, Self.upstream_rev)) null else "origin");
        }
        const fetched = try self.fetchAll(dirs.items, remotes.items);
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

    /// Brings every sibling checkout to the ref its manifest declares, for a distribution build.
    ///
    /// - `self`: The run, after `run` or `cloneSiblings` has queued the siblings.
    /// - Returns: Whether any sibling moved; `error.DepsFailed` when one has work of its own, cannot be fetched, or lacks its ref, or IO and git errors.
    pub fn enforceSiblings(self: *Self) !bool {
        // As in `updateSiblings`, everything that fails a sibling is checked before the network.
        var targets: std.ArrayList(SiblingTarget) = .empty;
        var dirs: std.ArrayList([]const u8) = .empty;
        for (self.siblings.items) |sibling| {
            const target = try self.siblingTarget(sibling) orelse continue;
            try targets.append(self.allocator, target);
            if (target.fetch) try dirs.append(self.allocator, sibling.dir);
        }
        const fetched = try self.fetchAll(dirs.items, try self.originFor(dirs.items.len));
        // A distribution build builds what the manifests declare or nothing: unlike an update, a failed fetch fails the build.
        for (dirs.items, fetched) |dir, ok| {
            if (!ok) return self.fail("cannot fetch {s}; a distribution build needs its remote", .{try self.relativeToRoot(dir)});
        }
        var moved = false;
        for (targets.items) |target| {
            if (try self.moveSibling(target)) moved = true;
        }
        return moved;
    }

    /// Fetches and fast-forwards every worktree that follows a branch and has no work of its own.
    ///
    /// - `self`: The run, after `run`.
    /// - Returns: How many worktrees moved, and how many were skipped or failed; IO errors.
    pub fn update(self: *const Self) !mod.Updated {
        var updated: mod.Updated = .{};
        // A SHA or tag is frozen, so its checkout is never fetched; a branch worktree with work of
        // its own is skipped before its checkout is, so a skip never reaches the network.
        var candidates: std.ArrayList(*Worktree) = .empty;
        var checkouts: std.ArrayList([]const u8) = .empty;
        for (self.worktrees.items) |*worktree| {
            const stamp = worktree.stamp orelse continue;
            if (!stamp.pin.follows()) continue;
            if (self.describeLocalWork(worktree.dir, try self.workBase(worktree.dir, stamp))) |work| {
                log.warn("skipped {s}: it has {s}", .{ worktree.rel, work });
                updated.failed += 1;
                continue;
            }
            try candidates.append(self.allocator, worktree);
            // Each checkout is fetched once, however many worktrees share it.
            if (!Self.containsPath(checkouts.items, stamp.checkout)) try checkouts.append(self.allocator, stamp.checkout);
        }
        const fetched = try self.fetchAll(checkouts.items, try self.originFor(checkouts.items.len));
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
    /// - `self`: The run, after `run`.
    /// - `writer`: Where the lines go.
    /// - Returns: Write errors.
    pub fn status(self: *const Self, writer: *std.Io.Writer) !void {
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

    /// Takes the lock that serialises concurrent builds of this consumer.
    ///
    /// - `self`: The run.
    /// - Returns: The locked file, released when it is closed; IO errors.
    pub fn acquireLock(self: *const Self) !std.Io.File {
        return Self.lockRoot(self.allocator, self.io, self.root);
    }

    /// Takes the lock that serialises concurrent builds of the consumer at `root`, as `Stage` does too.
    ///
    /// - `allocator`: An arena for the lock's path.
    /// - `io`: IO for the filesystem.
    /// - `root`: The consumer's absolute root.
    /// - Returns: The locked file, released when it is closed; IO errors.
    pub fn lockRoot(allocator: std.mem.Allocator, io: std.Io, root: []const u8) !std.Io.File {
        const dir = try std.Io.Dir.path.join(allocator, &.{ root, ".zig-cache" });
        try std.Io.Dir.cwd().createDirPath(io, dir);
        const path = try std.Io.Dir.path.join(allocator, &.{ dir, "zigbuildx.lock" });
        return std.Io.Dir.cwd().createFile(io, path, .{ .lock = .exclusive });
    }

    /// Shortens a SHA for messages.
    ///
    /// - `sha`: A full or short SHA.
    /// - Returns: Its first `short_sha_len` characters.
    pub fn short(sha: []const u8) []const u8 {
        return sha[0..@min(sha.len, Self.short_sha_len)];
    }

    /// Logs why the run failed: the `problem` `fail` recorded, or else the error itself.
    ///
    /// - `self`: The run.
    /// - `err`: The error the run returned.
    /// - `action`: What the run was doing, for the message (`"clone"`, `"sync"`).
    pub fn logFailure(self: *const Self, err: anyerror, action: []const u8) void {
        if (err == error.DepsFailed) {
            log.err("{s}", .{self.problem});
        } else {
            // `Git.clone` has already logged git's reason; this names what the run was doing.
            log.err("cannot {s} dependencies [{any}]", .{ action, err });
        }
    }

    /// Records `manifest`'s worktree dependencies and, for the root, clones missing sibling checkouts.
    ///
    /// - `self`: The run.
    /// - `manifest`: The declaring package's manifest.
    /// - `dir`: Where the declaring package is on disk.
    /// - `home`: The declaring package's own checkout, which its `.checkout` paths resolve against.
    /// - Returns: `error.DepsFailed` on a malformed root entry, or clone errors.
    fn collect(self: *Self, manifest: mod.Manifest, dir: []const u8, home: []const u8) !void {
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
                // A sibling may follow a branch or sit at a tag; only a worktree can be frozen at a SHA.
                if (outside.kind != .sha) {
                    try self.addSibling(resolved, source, outside, manifest.name);
                    continue;
                }
                if (is_root) return self.fail("{s} pins {s} to a {t}, but a .sha dependency's .path must be under deps/", .{ manifest.name, entry.name, outside.kind });
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
    /// - `self`: The run.
    /// - `package`: The declaring package, for the message.
    /// - `entry`: The dependency.
    /// - Returns: The pin, or `null` when it sets none; `error.DepsFailed` when it sets more than one.
    fn pinOf(self: *Self, package: []const u8, entry: mod.Entry) !?mod.Pin {
        var pin: ?mod.Pin = null;
        var count: usize = 0;
        inline for (.{ "sha", "tag", "branch" }) |field| {
            if (@field(entry, field)) |value| {
                if (!mod.Pin.isValidValue(value)) return self.fail("{s}: {s} has an invalid .{s}: \"{s}\"", .{ package, entry.name, field, value });
                pin = .{ .kind = @field(mod.PinKind, field), .value = value };
                count += 1;
            }
        }
        if (count > 1) return self.fail("{s}: {s} sets more than one of .sha, .tag and .branch", .{ package, entry.name });
        return pin;
    }

    /// Reads the ref a sibling is cloned at: its `.branch` or `.tag`.
    ///
    /// - `self`: The run.
    /// - `package`: The declaring package, for the message.
    /// - `entry`: The dependency.
    /// - Returns: The ref, or `null` for none or a `.sha`; `error.DepsFailed` when it sets more than one pin.
    fn siblingRef(self: *Self, package: []const u8, entry: mod.Entry) !?mod.Pin {
        const pin = try self.pinOf(package, entry) orelse return null;
        // Only a worktree is frozen at a SHA.
        return if (pin.kind == .sha) null else pin;
    }

    /// Names a sibling's ref for messages.
    ///
    /// - `self`: The run.
    /// - `ref`: The ref, or null for none.
    /// - Returns: `branch <b>`, `tag <t>`, or what no ref means in this mode; allocation errors.
    fn describeRef(self: *const Self, ref: ?mod.Pin) ![]const u8 {
        const pin = ref orelse return switch (self.mode) {
            .develop => "its current branch",
            .dist => "the remote's default branch",
        };
        return self.allocator.print("{t} {s}", .{ pin.kind, pin.value });
    }

    /// Names a tag's ref.
    ///
    /// - `self`: The run.
    /// - `tag`: The tag.
    /// - Returns: `refs/tags/<tag>`; allocation errors.
    fn tagRef(self: *const Self, tag: []const u8) ![]const u8 {
        return self.allocator.print("refs/tags/{s}", .{tag});
    }

    /// Names a branch's ref on the `origin` remote, as last fetched.
    ///
    /// - `self`: The run.
    /// - `branch`: The branch.
    /// - Returns: `refs/remotes/origin/<branch>`; allocation errors.
    fn originRef(self: *const Self, branch: []const u8) ![]const u8 {
        return self.allocator.print("refs/remotes/origin/{s}", .{branch});
    }

    /// Reports whether a sibling is a git checkout of its own, which an update or a distribution build may move.
    ///
    /// - `self`: The run.
    /// - `dir`: The sibling's absolute path.
    /// - `action`: What is skipped, for the message (`"updating"`, `"checking"`).
    /// - Returns: `false` for an archive or a directory with no `.git`; IO errors.
    fn isOwnCheckout(self: *const Self, dir: []const u8, action: []const u8) !bool {
        // An archive's URL is its pin: `ensureArchive` has already brought it in line.
        if (Self.containsPath(self.archives.items, dir)) return false;
        // A directory inside some other repository is not its own checkout: leave that repository alone.
        if (!try mod.File.exists(self.io, try std.Io.Dir.path.join(self.allocator, &.{ dir, ".git" }))) {
            log.info("not {s} {s}: it is not a git checkout", .{ action, try self.relativeToRoot(dir) });
            return false;
        }
        return true;
    }

    /// Reads where an entry is fetched from when it is absent.
    ///
    /// - `self`: The run.
    /// - `package`: The declaring package, for the message.
    /// - `entry`: The dependency.
    /// - Returns: The source, or `null` when it names none; `error.DepsFailed` when it sets both `.clone` and `.archive`.
    fn sourceOf(self: *Self, package: []const u8, entry: mod.Entry) !?mod.Source {
        if (entry.clone != null and entry.archive != null) return self.fail("{s}: {s} sets both .clone and .archive", .{ package, entry.name });
        if (entry.clone) |url| return .{ .clone = url };
        if (entry.archive) |url| return .{ .archive = url };
        return null;
    }

    /// Reports whether `path` is a direct child of a `deps` directory inside the consumer.
    ///
    /// - `self`: The run.
    /// - `path`: An absolute, resolved path.
    /// - Returns: `true` for a worktree dependency's path.
    fn isWorktreePath(self: *const Self, path: []const u8) bool {
        const parent = std.Io.Dir.path.dirname(path) orelse return false;
        if (!std.mem.eql(u8, std.Io.Dir.path.basename(parent), "deps")) return false;
        return std.mem.startsWith(u8, parent, self.root) and parent.len > self.root.len and std.Io.Dir.path.isSep(parent[self.root.len]);
    }

    /// Builds the branch prefix for a worktree at `rel`.
    ///
    /// - `self`: The run.
    /// - `rel`: The worktree's path relative to the consumer.
    /// - Returns: The prefix.
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
    /// - `self`: The run.
    /// - `dir`: An absolute worktree path.
    /// - Returns: The worktree, or `null`.
    fn find(self: *const Self, dir: []const u8) ?*const Worktree {
        for (self.worktrees.items) |*worktree| {
            if (std.mem.eql(u8, worktree.dir, dir)) return worktree;
        }
        return null;
    }

    /// Reports whether `paths` holds `path`.
    ///
    /// - `paths`: Absolute paths, as the run records them.
    /// - `path`: An absolute path.
    /// - Returns: `true` when one of `paths` equals `path`.
    fn containsPath(paths: []const []const u8, path: []const u8) bool {
        // Few paths: a scan is cheaper than a map.
        for (paths) |candidate| {
            if (std.mem.eql(u8, candidate, path)) return true;
        }
        return false;
    }

    /// Clones or unpacks an unpinned dependency from `source`, as `cloneMissing` does.
    ///
    /// - `self`: The run.
    /// - `path`: The dependency's absolute path.
    /// - `source`: Where it comes from.
    /// - `ref`: The branch or tag a clone checks out; null for the remote's default branch.
    /// - Returns: `error.DepsFailed` for an archive or a directory that is no package, or clone errors, which `Git.clone` logs.
    fn materialize(self: *Self, path: []const u8, source: mod.Source, ref: ?mod.Pin) !void {
        switch (source) {
            .clone => |url| {
                if (!try mod.File.exists(self.io, path)) {
                    try mod.Git.clone(self.io, url, path, if (ref) |pin| pin.value else null);
                    self.changed = true;
                    return;
                }
                // The steady state: a stat or two, no git.
                if (try self.isPackage(path)) return;
                try self.repair(path, url, ref);
            },
            // Also unpacked again when its URL changed.
            .archive => |url| try self.ensureArchive(path, url),
        }
    }

    /// Reports whether `dir` holds a Zig package: a `build.zig.zon` or a `build.zig`.
    ///
    /// - `self`: The run.
    /// - `dir`: An absolute path that exists.
    /// - Returns: `true` when either file is there; IO errors.
    fn isPackage(self: *const Self, dir: []const u8) !bool {
        for ([_][]const u8{ "build.zig.zon", "build.zig" }) |name| {
            if (try mod.File.exists(self.io, try std.Io.Dir.path.join(self.allocator, &.{ dir, name }))) return true;
        }
        return false;
    }

    /// Fills in a checkout that a clone left with no commits and no files, or refuses anything else that is no package.
    ///
    /// - `self`: The run.
    /// - `path`: The dependency's absolute path; it exists and holds no package.
    /// - `url`: Its `.clone`, for messages.
    /// - `ref`: The branch or tag to check out; null for the remote's default branch.
    /// - Returns: `error.DepsFailed` when it holds anything of its own or the remote has nothing to check out, or IO and git errors.
    fn repair(self: *Self, path: []const u8, url: []const u8, ref: ?mod.Pin) !void {
        const rel = try self.relativeToRoot(path);
        // Only an empty repository is filled in: anything else may be someone's work.
        if (!try self.holdsOnlyGit(path) or try mod.Git.revParse(self.allocator, self.io, path, "HEAD") != null) {
            return self.fail("{s} exists but is not a Zig package (no build.zig.zon); move it aside and re-run", .{rel});
        }
        if (ref) |pin| if (pin.kind == .tag) {
            try mod.Git.fetch(self.allocator, self.io, path, "origin");
            const sha = try mod.Git.revParse(self.allocator, self.io, path, try self.tagRef(pin.value)) orelse {
                return self.fail("{s} is an empty checkout and {s} has no tag {s}", .{ rel, url, pin.value });
            };
            try mod.Git.checkoutDetached(self.allocator, self.io, path, sha);
            log.info("filled in the empty checkout {s} from {s} (tag {s})", .{ rel, url, pin.value });
            self.changed = true;
            return;
        };
        const wanted = (if (ref) |pin| pin.value else null) orelse try mod.Git.remoteHead(self.allocator, self.io, path) orelse {
            return self.fail("{s} is an empty checkout and {s} has no commits yet; push, then re-run", .{ rel, url });
        };
        try mod.Git.fetch(self.allocator, self.io, path, "origin");
        if (try mod.Git.revParse(self.allocator, self.io, path, try self.originRef(wanted)) == null) {
            return self.fail("{s} is an empty checkout and {s} has no branch {s}", .{ rel, url, wanted });
        }
        try mod.Git.checkoutTracking(self.allocator, self.io, path, wanted);
        log.info("filled in the empty checkout {s} from {s} ({s})", .{ rel, url, wanted });
        self.changed = true;
    }

    /// Reports whether `dir` holds nothing but a `.git` directory.
    ///
    /// - `self`: The run.
    /// - `dir`: An absolute directory path.
    /// - Returns: `true` when `.git` is its only entry; IO errors.
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
    /// - `self`: The run.
    /// - `path`: The dependency's absolute path.
    /// - `url`: The zip's URL.
    /// - Returns: `error.DepsFailed` when the path holds something else or cannot be unpacked, or IO errors.
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
    /// - `self`: The run.
    /// - `path`: The dependency's absolute path.
    /// - `source`: Where it comes from, if anywhere.
    /// - `ref`: The branch it follows (`.branch`) or the tag it sits at (`.tag`), or null.
    /// - `declared_by`: The package whose manifest names it.
    /// - Returns: `error.DepsFailed` for an archive, or clone errors, which `Git.clone` logs.
    fn addSibling(self: *Self, path: []const u8, source: ?mod.Source, ref: ?mod.Pin, declared_by: []const u8) !void {
        // Each path is queued once, so a cycle of siblings ends; the first declaration wins.
        if (self.findSibling(path)) |first| {
            // A later declaration that names no ref has nothing to disagree with.
            if (ref) |want| {
                const agrees = if (first.ref) |had| had.satisfies(want) else false;
                if (!agrees) log.warn("{s} wants {s} at {t} {s}; {s}'s declaration wins ({s})", .{ declared_by, try self.relativeToRoot(path), want.kind, want.value, first.declared_by, try self.describeRef(first.ref) });
            }
            return;
        }
        try self.siblings.append(self.allocator, .{ .dir = path, .ref = ref, .declared_by = declared_by });
        // An absent one with no `source` is left for Zig to report.
        try self.materialize(path, source orelse return, ref);
    }

    /// Finds the sibling queued at `dir`.
    ///
    /// - `self`: The run.
    /// - `dir`: An absolute path.
    /// - Returns: The sibling, or `null`.
    fn findSibling(self: *const Self, dir: []const u8) ?*const Sibling {
        for (self.siblings.items) |*sibling| {
            if (std.mem.eql(u8, sibling.dir, dir)) return sibling;
        }
        return null;
    }

    /// Reads each queued sibling's manifest and queues its unpinned `.path` dependencies outside `deps/`.
    ///
    /// - `self`: The run.
    /// - Returns: `error.DepsFailed` when a manifest does not parse, or IO and clone errors.
    fn followSiblings(self: *Self) !void {
        // Zig opens every `.path` package before `build()` runs, and only the root runs `Deps`, so a
        // sibling's own sibling must be on disk too. Siblings queued here are walked in the same pass.
        while (self.walked < self.siblings.items.len) : (self.walked += 1) {
            const dir = self.siblings.items[self.walked].dir;
            const manifest = try self.readManifest(dir) orelse continue;
            for (manifest.entries) |entry| {
                const path = entry.path orelse continue;
                const resolved = try std.Io.Dir.path.resolveAlloc(self.allocator, &.{ dir, path });
                if (self.isWorktreePath(resolved)) continue;
                const pin = try self.pinOf(manifest.name, entry);
                // Only a worktree is frozen at a SHA, and a pin under the sibling's own `deps/` is its worktree, not a sibling.
                if (pin) |pinned| if (pinned.kind == .sha or std.mem.eql(u8, std.Io.Dir.path.basename(std.Io.Dir.path.dirname(resolved) orelse ""), "deps")) continue;
                try self.addSibling(resolved, try self.sourceOf(manifest.name, entry), pin, manifest.name);
            }
        }
    }

    /// Decides, without the network, whether a sibling is updated, and names what it is fast-forwarded to.
    ///
    /// - `self`: The run.
    /// - `sibling`: The sibling.
    /// - Returns: The revision to fast-forward to (`@{u}` or `refs/remotes/origin/<branch>`), or `null` when it is left alone; IO errors.
    fn siblingTip(self: *Self, sibling: Sibling) !?[]const u8 {
        const dir = sibling.dir;
        if (!try self.isOwnCheckout(dir, "updating")) return null;
        const rel = try self.relativeToRoot(dir);
        if (sibling.ref) |ref| if (ref.kind == .tag) {
            // A tag is never fetched or moved; a sibling that left it is the developer's choice, but worth a word.
            const tag = mod.Git.revParse(self.allocator, self.io, dir, try self.tagRef(ref.value)) catch null;
            const head = mod.Git.revParse(self.allocator, self.io, dir, "HEAD") catch null;
            const at_tag = tag != null and head != null and std.mem.eql(u8, tag.?, head.?);
            if (!at_tag) log.warn("{s} is not at tag {s}, which {s} wants; left as it is", .{ rel, ref.value, sibling.declared_by });
            return null;
        };
        const current = (mod.Git.currentBranch(self.allocator, self.io, dir) catch return null) orelse {
            log.info("not updating {s}: HEAD is detached", .{rel});
            return null;
        };
        const tip_ref = if (sibling.ref) |wanted| blk: {
            if (!std.mem.eql(u8, current, wanted.value)) {
                log.warn("not updating {s}: it is on {s}, and {s} wants {s}", .{ rel, current, sibling.declared_by, wanted.value });
                return null;
            }
            break :blk try self.originRef(wanted.value);
        } else Self.upstream_rev;
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

    /// Decides where a distribution build puts a sibling, refusing one with work of its own.
    ///
    /// - `self`: The run.
    /// - `sibling`: The sibling.
    /// - Returns: The target, or `null` for an archive or a directory that is no git checkout; `error.DepsFailed` when it has work of its own or its remote has no commits, or IO and git errors.
    fn siblingTarget(self: *Self, sibling: Sibling) !?SiblingTarget {
        const dir = sibling.dir;
        if (!try self.isOwnCheckout(dir, "checking")) return null;
        const rel = try self.relativeToRoot(dir);
        // Work of its own is never moved, and a build of something else is no distribution build: fail.
        if (!try mod.Git.isClean(self.allocator, self.io, dir)) {
            return self.fail("{s} has uncommitted changes, so a distribution build cannot move it to {s}; discard them, or build without -Ddist", .{ rel, try self.describeRef(sibling.ref) });
        }
        // Detached, it holds nothing a move loses; on a branch, commits its upstream lacks are its own.
        if (try mod.Git.currentBranch(self.allocator, self.io, dir)) |branch| {
            const base = try mod.Git.upstream(self.allocator, self.io, dir) orelse {
                return self.fail("{s} is on {s}, which has no upstream, so it may hold unpushed work; push it, or build without -Ddist", .{ rel, branch });
            };
            if (try mod.Git.isAhead(self.allocator, self.io, dir, base)) {
                return self.fail("{s} has commits of its own on {s}; push or drop them, or build without -Ddist", .{ rel, branch });
            }
        }
        const ref: mod.Pin = sibling.ref orelse .{
            .kind = .branch,
            .value = try mod.Git.remoteHead(self.allocator, self.io, dir) orelse return self.fail("{s}: its remote has no commits", .{rel}),
        };
        return switch (ref.kind) {
            .tag => blk: {
                const rev = try self.tagRef(ref.value);
                // A tag the checkout already has is not fetched again: a tag is not expected to move.
                const known = try mod.Git.revParse(self.allocator, self.io, dir, rev) != null;
                break :blk .{ .sibling = sibling, .ref = ref, .rev = rev, .fetch = !known };
            },
            .branch => .{ .sibling = sibling, .ref = ref, .rev = try self.originRef(ref.value), .fetch = true },
            // `siblingRef` and `collect` never give a sibling a SHA.
            .sha => unreachable,
        };
    }

    /// Moves a sibling to its distribution target: detached at a tag, or on its branch at `origin/<branch>`.
    ///
    /// - `self`: The run.
    /// - `target`: Where the sibling goes; its checkout has been fetched when it needed it.
    /// - Returns: Whether it moved; `error.DepsFailed` when the ref is not on its remote or the branch has commits of its own, or IO and git errors.
    fn moveSibling(self: *Self, target: SiblingTarget) !bool {
        const dir = target.sibling.dir;
        const rel = try self.relativeToRoot(dir);
        const sha = try mod.Git.revParse(self.allocator, self.io, dir, target.rev) orelse {
            return self.fail("{s}: {t} {s}, which {s} wants, is not on its remote", .{ rel, target.ref.kind, target.ref.value, target.sibling.declared_by });
        };
        const head = try mod.Git.revParse(self.allocator, self.io, dir, "HEAD") orelse "";
        // The build reads files, not refs: a checkout already at the commit is left on its branch or detached.
        if (std.mem.eql(u8, head, sha)) return false;
        switch (target.ref.kind) {
            .tag => try mod.Git.checkoutDetached(self.allocator, self.io, dir, sha),
            .branch => {
                const branch = target.ref.value;
                const exists = try mod.Git.branchExists(self.allocator, self.io, dir, branch);
                // Checked before anything moves: a local branch with commits `origin/<branch>` lacks is work of its own.
                if (exists and !try mod.Git.isAncestor(self.allocator, self.io, dir, try self.allocator.print("refs/heads/{s}", .{branch}), sha)) {
                    return self.fail("{s} has commits of its own on {s}; push or drop them, or build without -Ddist", .{ rel, branch });
                }
                const current = try mod.Git.currentBranch(self.allocator, self.io, dir);
                const on_branch = if (current) |name| std.mem.eql(u8, name, branch) else false;
                if (!on_branch) {
                    if (exists) {
                        try mod.Git.checkoutBranch(self.allocator, self.io, dir, branch, null);
                    } else {
                        try mod.Git.checkoutTracking(self.allocator, self.io, dir, branch);
                    }
                }
                try mod.Git.fastForward(self.allocator, self.io, dir, sha);
            },
            // `siblingTarget` never targets a SHA.
            .sha => unreachable,
        }
        log.info("moved {s} to {t} {s} ({s})", .{ rel, target.ref.kind, target.ref.value, Self.short(sha) });
        return true;
    }

    /// Names `origin` as the remote of each of `count` fetches.
    ///
    /// - `self`: The run.
    /// - `count`: How many.
    /// - Returns: The remotes, for `fetchAll`; allocation errors.
    fn originFor(self: *const Self, count: usize) ![]const ?[]const u8 {
        const remotes = try self.allocator.alloc(?[]const u8, count);
        @memset(remotes, "origin");
        return remotes;
    }

    /// Fetches every repository in `dirs` at once, each from its remote in `remotes`.
    ///
    /// - `self`: The run.
    /// - `dirs`: Absolute checkout paths, each once.
    /// - `remotes`: The remote to fetch for each of `dirs`, or null for its current branch's upstream remote.
    /// - Returns: Whether each fetch succeeded, in `dirs` order; allocation errors.
    fn fetchAll(self: *const Self, dirs: []const []const u8, remotes: []const ?[]const u8) ![]bool {
        const fetched = try self.allocator.alloc(bool, dirs.len);
        const children = try self.allocator.alloc(?std.process.Child, dirs.len);
        // All started before any is waited for: each is a round trip, so they overlap, and
        // processes need no threads (a build runner is compiled single-threaded).
        for (dirs, remotes, children) |dir, remote, *child| child.* = mod.Git.startFetch(self.io, dir, remote) catch null;
        for (children, fetched) |*child, *ok| ok.* = if (child.*) |*running| mod.Git.finishFetch(self.io, running) else false;
        return fetched;
    }

    /// Brings worktree `index` in line with its pin: creates it, moves it, or leaves it.
    ///
    /// - `self`: The run.
    /// - `index`: The worktree's index in `worktrees`.
    /// - Returns: `error.DepsFailed` when it cannot be brought in line, or IO and git errors.
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
    /// - `self`: The run.
    /// - `worktree`: The worktree to create; its `stamp` is set.
    /// - Returns: `error.DepsFailed`, or IO and git errors.
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
    /// - `self`: The run.
    /// - `worktree`: The worktree; its `stamp` is set.
    /// - `old`: The stamp it was created or last moved with.
    /// - Returns: `error.DepsFailed` when it is dirty or ahead, or IO and git errors.
    fn move(self: *Self, worktree: *Worktree, old: mod.Stamp) !void {
        if (!try mod.Git.isClean(self.allocator, self.io, worktree.dir)) {
            return self.fail("{s} is now pinned to {t} {s}, but it has uncommitted changes on {t} {s}; commit or discard them, then re-run", .{ worktree.rel, worktree.pin.kind, worktree.pin.value, old.pin.kind, old.pin.value });
        }
        if (try mod.Git.isAhead(self.allocator, self.io, worktree.dir, try self.workBase(worktree.dir, old))) {
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
    /// - `self`: The run.
    /// - `worktree`: The worktree.
    /// - Returns: The target; `error.DepsFailed` when the revision is not found, or git errors.
    fn resolve(self: *Self, worktree: *const Worktree) !Target {
        const pin = worktree.pin;
        const sha = try self.lookup(worktree.checkout, pin) orelse blk: {
            try mod.Git.fetch(self.allocator, self.io, worktree.checkout, "origin");
            break :blk try self.lookup(worktree.checkout, pin);
        } orelse return self.fail("{s}: {t} {s} is not in {s}, even after git fetch", .{ worktree.rel, pin.kind, pin.value, worktree.checkout });
        const branch = if (pin.follows()) try self.allocator.print("{s}/{s}", .{ worktree.branch_prefix, pin.value }) else "";
        return .{ .sha = sha, .pin = pin, .branch = branch };
    }

    /// Looks a resolved pin up in a checkout without fetching.
    ///
    /// - `self`: The run.
    /// - `checkout`: The checkout.
    /// - `pin`: The pin.
    /// - Returns: The commit, or `null` when it is not there; git errors.
    fn lookup(self: *const Self, checkout: []const u8, pin: mod.Pin) !?[]const u8 {
        return switch (pin.kind) {
            .sha => mod.Git.revParse(self.allocator, self.io, checkout, pin.value),
            .tag => mod.Git.revParse(self.allocator, self.io, checkout, try self.tagRef(pin.value)),
            // `origin` first, then local, so a checkout with no remote still works.
            .branch => try mod.Git.revParse(self.allocator, self.io, checkout, try self.originRef(pin.value)) orelse
                try mod.Git.revParse(self.allocator, self.io, checkout, try self.allocator.print("refs/heads/{s}", .{pin.value})),
        };
    }

    /// Removes worktrees whose stamps no dependency claims any more, when they hold no work.
    ///
    /// - `self`: The run.
    /// - Returns: IO errors. Git failures are logged and leave the orphan in place.
    fn removeOrphans(self: *Self) !void {
        var dirs: std.ArrayList([]const u8) = .empty;
        try dirs.append(self.allocator, try std.Io.Dir.path.join(self.allocator, &.{ self.root, "deps" }));
        for (self.worktrees.items) |worktree| {
            const parent = std.Io.Dir.path.dirname(worktree.dir).?;
            if (!Self.containsPath(dirs.items, parent)) try dirs.append(self.allocator, parent);
            // Its own `deps/` too: a worktree it no longer declares is an orphan there.
            const own = try std.Io.Dir.path.join(self.allocator, &.{ worktree.dir, "deps" });
            if (!Self.containsPath(dirs.items, own)) try dirs.append(self.allocator, own);
        }
        for (dirs.items) |deps| {
            for (try self.stampedIn(deps)) |path| {
                // A path still declared unpinned keeps what is there; its old stamp is left alone.
                if (self.find(path) == null and !Self.containsPath(self.unpinned.items, path)) try self.removeOrphan(path);
            }
        }
    }

    /// Lists the worktrees stamped in the `deps` directory `deps`.
    ///
    /// - `self`: The run.
    /// - `deps`: A `deps` directory's absolute path.
    /// - Returns: Each stamped worktree's absolute path; none when `deps` has no stamps; IO errors.
    fn stampedIn(self: *const Self, deps: []const u8) ![]const []const u8 {
        const state = try std.Io.Dir.path.join(self.allocator, &.{ deps, ".zigbuildx" });
        var dir = std.Io.Dir.cwd().openDir(self.io, state, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return &.{},
            else => return err,
        };
        defer dir.close(self.io);
        var paths: std.ArrayList([]const u8) = .empty;
        var it = dir.iterate();
        while (try it.next(self.io)) |item| {
            if (item.kind != .file or !std.mem.endsWith(u8, item.name, ".rev")) continue;
            try paths.append(self.allocator, try std.Io.Dir.path.join(self.allocator, &.{ deps, item.name[0 .. item.name.len - ".rev".len] }));
        }
        return paths.items;
    }

    /// Removes one orphaned worktree, its branch and its stamp, or leaves it with a warning.
    ///
    /// - `self`: The run.
    /// - `path`: The orphan's absolute path.
    /// - Returns: IO errors.
    fn removeOrphan(self: *Self, path: []const u8) !void {
        const rel = try self.relativeToRoot(path);
        const stamp = try self.readStamp(path) orelse {
            log.warn("{s} is no longer a dependency, but its stamp is unreadable; left in place", .{rel});
            try self.orphans.append(self.allocator, rel);
            return;
        };
        if (try mod.File.exists(self.io, path)) {
            // Its own worktrees go first: `git worktree remove` would delete them with it, and
            // `deps/` is git-ignored, so its own status cannot see their work.
            const nested = try std.Io.Dir.path.join(self.allocator, &.{ path, "deps" });
            for (try self.stampedIn(nested)) |inner| if (self.find(inner) == null) try self.removeOrphan(inner);
            if ((try self.stampedIn(nested)).len > 0) {
                log.warn("{s} is no longer a dependency, but it holds a worktree that stays; left in place", .{rel});
                try self.orphans.append(self.allocator, rel);
                return;
            }
            if (self.describeLocalWork(path, try self.workBase(path, stamp))) |work| {
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

    /// Reads the manifest in `dir`.
    ///
    /// - `self`: The run.
    /// - `dir`: A package directory.
    /// - Returns: The manifest, or `null` when there is none; `error.DepsFailed` when it does not parse, or IO errors.
    fn readManifest(self: *Self, dir: []const u8) !?mod.Manifest {
        const path = try std.Io.Dir.path.join(self.allocator, &.{ dir, "build.zig.zon" });
        const source = try mod.File.readOptionalZ(self.allocator, self.io, path, .limited(mod.Manifest.max_bytes)) orelse return null;
        return mod.Manifest.parse(self.allocator, source) catch |err| switch (err) {
            error.InvalidManifest => return self.fail("cannot parse {s}", .{path}),
            else => return err,
        };
    }

    /// Returns the stamp path for the worktree at `dir`: `<deps>/.zigbuildx/<name>.rev`.
    ///
    /// - `self`: The run.
    /// - `dir`: The worktree's absolute path.
    /// - Returns: The stamp's absolute path.
    fn stampPath(self: *const Self, dir: []const u8) ![]const u8 {
        const name = try self.allocator.print("{s}.rev", .{std.Io.Dir.path.basename(dir)});
        return std.Io.Dir.path.join(self.allocator, &.{ std.Io.Dir.path.dirname(dir).?, ".zigbuildx", name });
    }

    /// Reads the stamp for the worktree at `dir`.
    ///
    /// - `self`: The run.
    /// - `dir`: The worktree's absolute path.
    /// - Returns: The stamp, or `null` when there is none or it does not parse; IO errors.
    fn readStamp(self: *const Self, dir: []const u8) !?mod.Stamp {
        const text = try mod.File.readOptional(self.allocator, self.io, try self.stampPath(dir), .limited(mod.Stamp.max_bytes)) orelse return null;
        return mod.Stamp.parse(text);
    }

    /// Records the worktree's HEAD and pin in its stamp, and on the worktree.
    ///
    /// - `self`: The run.
    /// - `worktree`: The worktree; its `stamp` is set.
    /// - `target`: Where it now is.
    /// - Returns: IO and git errors.
    fn writeStamp(self: *const Self, worktree: *Worktree, target: Target) !void {
        const head = try mod.Git.revParse(self.allocator, self.io, worktree.dir, "HEAD") orelse target.sha;
        const stamp = mod.Stamp{ .pin = target.pin, .sha = head, .branch = target.branch, .checkout = worktree.checkout };
        const path = try self.stampPath(worktree.dir);
        try mod.File.createParentDir(self.io, path);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = try stamp.serialize(self.allocator) });
        worktree.stamp = stamp;
    }

    /// Returns `path` relative to the consumer's root, for messages.
    ///
    /// - `self`: The run.
    /// - `path`: An absolute path.
    /// - Returns: The relative path; allocation errors.
    fn relativeToRoot(self: *const Self, path: []const u8) ![]const u8 {
        return std.Io.Dir.path.relativeAlloc(self.allocator, self.root, null, self.root, path);
    }

    /// Names the commit a worktree's own work is counted from: its branch's tip as last fetched, once that holds the stamped commit, else the stamped commit.
    ///
    /// - `self`: The run.
    /// - `dir`: The worktree.
    /// - `stamp`: Its stamp.
    /// - Returns: The commit; allocation errors.
    fn workBase(self: *const Self, dir: []const u8, stamp: mod.Stamp) ![]const u8 {
        if (!stamp.pin.follows()) return stamp.sha;
        const tip = (mod.Git.revParse(self.allocator, self.io, dir, try self.originRef(stamp.pin.value)) catch null) orelse return stamp.sha;
        // Commits pushed from the worktree are upstream's now, not its own.
        const pushed = mod.Git.isAncestor(self.allocator, self.io, dir, stamp.sha, tip) catch false;
        return if (pushed) tip else stamp.sha;
    }

    /// Describes the work of its own a checkout or worktree holds, which moving it would put at risk.
    ///
    /// - `self`: The run.
    /// - `dir`: The checkout or worktree.
    /// - `base`: The commit that HEAD is compared with; commits beyond it are its own.
    /// - Returns: "uncommitted changes" or "commits of its own", or `null` when it has neither.
    fn describeLocalWork(self: *const Self, dir: []const u8, base: []const u8) ?[]const u8 {
        // A `git` failure counts as work, so a checkout that cannot be inspected is left alone.
        const clean = mod.Git.isClean(self.allocator, self.io, dir) catch false;
        if (!clean) return "uncommitted changes";
        const ahead = mod.Git.isAhead(self.allocator, self.io, dir, base) catch true;
        if (ahead) return "commits of its own";
        return null;
    }

    /// Records why the run failed, for the caller to log.
    ///
    /// - `self`: The run.
    /// - `fmt`: The message format.
    /// - `args`: Its arguments.
    /// - Returns: Always `error.DepsFailed`, or `error.OutOfMemory`.
    fn fail(self: *Self, comptime fmt: []const u8, args: anytype) error{ DepsFailed, OutOfMemory } {
        self.problem = try self.allocator.print(fmt, args);
        return error.DepsFailed;
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test "sync creates worktrees for a SHA, a tag and a branch, then stays put" {
    var tree = try mod.TestTree.init();
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
    var tree = try mod.TestTree.init();
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
    var tree = try mod.TestTree.init();
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
    var tree = try mod.TestTree.init();
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
    var tree = try mod.TestTree.init();
    defer tree.deinit();
    try tree.upstream("leaf", "");
    try tree.consumer(try tree.dep("leaf", ".tag = \"v1\","));
    _ = try tree.sync();
    const origin = try tree.path("origin/leaf");
    const pinned = try tree.rev("consumer/deps/leaf", "HEAD");
    try tree.commit(origin, "two");
    try tree.run(&.{ "git", "-C", origin, "tag", "--force", "v1" });

    var run_ = try tree.sync();
    try std.testing.expectEqual(mod.Updated{}, try run_.update());
    // Neither the worktree nor its checkout's copy of the tag moved: nothing was fetched.
    try std.testing.expectEqualStrings(pinned, try tree.rev("consumer/deps/leaf", "HEAD"));
    try std.testing.expectEqualStrings(pinned, try tree.rev("leaf", "refs/tags/v1"));
}

test "sync rejects two pin fields and a SHA on a path outside deps/" {
    var tree = try mod.TestTree.init();
    defer tree.deinit();
    try tree.consumer(".leaf = .{ .path = \"deps/leaf\", .tag = \"v1\", .branch = \"main\" },");
    try std.testing.expect(std.mem.find(u8, try tree.syncFails(), "more than one") != null);
    try tree.consumer(".leaf = .{ .path = \"../leaf\", .sha = \"0123456789\" },");
    try std.testing.expect(std.mem.find(u8, try tree.syncFails(), "must be under deps/") != null);
}

test "a worktree deleted by hand is recreated on its existing branch, commits kept" {
    var tree = try mod.TestTree.init();
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
    var tree = try mod.TestTree.init();
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
    var tree = try mod.TestTree.init();
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
    var tree = try mod.TestTree.init();
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
    var tree = try mod.TestTree.init();
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
    var tree = try mod.TestTree.init();
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
    var tree = try mod.TestTree.init();
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
    var tree = try mod.TestTree.init();
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
    var tree = try mod.TestTree.init();
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
    var tree = try mod.TestTree.init();
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
    var tree = try mod.TestTree.init();
    defer tree.deinit();
    try tree.upstream("leaf", "");
    const leaf_origin = try tree.path("origin/leaf");
    try tree.run(&.{ "git", "-C", leaf_origin, "branch", "dev" });
    try tree.upstream("mid", try tree.allocator().print(".leaf = .{{ .path = \"../leaf\", .clone = \"{s}\", .branch = \"dev\" }},", .{leaf_origin}));
    try tree.consumer(try tree.allocator().print("{s} .leaf = .{{ .path = \"../leaf\", .clone = \"{s}\", .branch = \"main\" }},", .{ try tree.sibling("mid"), leaf_origin }));
    const run_ = try tree.sync();
    const leaf = run_.findSibling(try tree.path("leaf")).?;
    try std.testing.expectEqualStrings("main", leaf.ref.?.value);
    try std.testing.expectEqualStrings("consumer", leaf.declared_by);
    try std.testing.expectEqualStrings("main", (try mod.Git.currentBranch(tree.allocator(), tree.io, try tree.path("leaf"))).?);
}

test "cloneSiblings fills in a checkout a clone left empty" {
    var tree = try mod.TestTree.init();
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
    var tree = try mod.TestTree.init();
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
    var tree = try mod.TestTree.init();
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
    var tree = try mod.TestTree.init();
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
    var tree = try mod.TestTree.init();
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
    var tree = try mod.TestTree.init();
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

test "a sibling with a .tag is cloned at it, then never fetched or moved" {
    var tree = try mod.TestTree.init();
    defer tree.deinit();
    try tree.upstream("mid", "");
    const origin = try tree.path("origin/mid");
    try tree.commit(origin, "two");
    try tree.consumer(try tree.siblingWith("mid", ".tag = \"v1\","));
    const first = try tree.sync();
    try std.testing.expect(first.changed);
    try std.testing.expectEqualStrings(try tree.rev("origin/mid", "v1"), try tree.rev("mid", "HEAD"));
    try std.testing.expectEqual(null, try mod.Git.currentBranch(tree.allocator(), tree.io, try tree.path("mid")));

    var run_ = try tree.sync();
    try std.testing.expect(!run_.changed);
    try std.testing.expect(!try run_.updateSiblings());
    try std.testing.expectEqualStrings(try tree.rev("origin/mid", "v1"), try tree.rev("mid", "HEAD"));

    // Moved off the tag by hand: warned about, and left there.
    try tree.run(&.{ "git", "-C", try tree.path("mid"), "checkout", "--quiet", "--detach", "origin/main" });
    var moved = try tree.sync();
    try std.testing.expect(!try moved.updateSiblings());
    try std.testing.expectEqualStrings(try tree.rev("origin/mid", "main"), try tree.rev("mid", "HEAD"));
}

test "a sibling's own tagged sibling is cloned at its tag, and the root's ref wins" {
    var tree = try mod.TestTree.init();
    defer tree.deinit();
    try tree.upstream("leaf", "");
    try tree.commit(try tree.path("origin/leaf"), "two");
    try tree.upstream("other", "");
    try tree.commit(try tree.path("origin/other"), "two");
    try tree.upstream("mid", try std.mem.concat(tree.allocator(), u8, &.{ try tree.siblingWith("leaf", ".tag = \"v1\","), try tree.siblingWith("other", ".tag = \"v1\",") }));
    try tree.consumer(try std.mem.concat(tree.allocator(), u8, &.{ try tree.sibling("mid"), try tree.siblingWith("other", ".branch = \"main\",") }));
    const run_ = try tree.sync();
    try std.testing.expectEqualStrings(try tree.rev("origin/leaf", "v1"), try tree.rev("leaf", "HEAD"));
    try std.testing.expectEqualStrings(try tree.rev("origin/other", "main"), try tree.rev("other", "HEAD"));
    try std.testing.expectEqual(mod.PinKind.branch, run_.findSibling(try tree.path("other")).?.ref.?.kind);
}

test "cloneSiblings fills in an empty checkout at its tag" {
    var tree = try mod.TestTree.init();
    defer tree.deinit();
    try tree.upstream("mid", "");
    try tree.commit(try tree.path("origin/mid"), "two");
    const empty = try tree.path("mid");
    try tree.run(&.{ "git", "init", "--quiet", "--initial-branch=main", empty });
    try tree.run(&.{ "git", "-C", empty, "remote", "add", "origin", try tree.path("origin/mid") });
    try tree.consumer(try tree.siblingWith("mid", ".tag = \"v1\","));
    var run_ = try Sync.init(tree.allocator(), tree.io, try tree.path("consumer"));
    try run_.cloneSiblings();
    try std.testing.expect(run_.changed);
    try std.testing.expectEqualStrings(try tree.rev("origin/mid", "v1"), try tree.rev("mid", "HEAD"));
}

test "a distribution build moves clean siblings to their refs, then stays put" {
    var tree = try mod.TestTree.init();
    defer tree.deinit();
    for ([_][]const u8{ "bytag", "bybranch", "noref" }) |name| try tree.upstream(name, "");
    // bytag is cloned on main, past v1; bybranch on main, not dev; noref on feature, not the default main.
    try tree.commit(try tree.path("origin/bytag"), "two");
    const bybranch = try tree.path("origin/bybranch");
    try tree.run(&.{ "git", "-C", bybranch, "checkout", "--quiet", "-b", "dev" });
    try tree.commit(bybranch, "two");
    try tree.run(&.{ "git", "-C", bybranch, "checkout", "--quiet", "main" });
    const noref = try tree.path("origin/noref");
    try tree.run(&.{ "git", "-C", noref, "branch", "feature" });
    try tree.commit(noref, "two");
    for ([_][]const u8{ "bytag", "bybranch" }) |name| try tree.run(&.{ "git", "clone", "--quiet", try tree.path(try tree.allocator().print("origin/{s}", .{name})), try tree.path(name) });
    try tree.run(&.{ "git", "clone", "--quiet", "--branch", "feature", noref, try tree.path("noref") });
    try tree.consumer(try std.mem.concat(tree.allocator(), u8, &.{ try tree.siblingWith("bytag", ".tag = \"v1\","), try tree.siblingWith("bybranch", ".branch = \"dev\","), try tree.sibling("noref") }));

    var run_ = try tree.syncIn(.dist);
    try std.testing.expect(!run_.changed);
    try std.testing.expect(try run_.enforceSiblings());
    try std.testing.expectEqualStrings(try tree.rev("origin/bytag", "v1"), try tree.rev("bytag", "HEAD"));
    try std.testing.expectEqualStrings(try tree.rev("origin/bybranch", "dev"), try tree.rev("bybranch", "HEAD"));
    try std.testing.expectEqualStrings("dev", (try mod.Git.currentBranch(tree.allocator(), tree.io, try tree.path("bybranch"))).?);
    try std.testing.expectEqualStrings(try tree.rev("origin/noref", "main"), try tree.rev("noref", "HEAD"));
    try std.testing.expectEqualStrings("main", (try mod.Git.currentBranch(tree.allocator(), tree.io, try tree.path("noref"))).?);

    var again = try tree.syncIn(.dist);
    try std.testing.expect(!try again.enforceSiblings());

    // A branch that moved upstream is followed.
    try tree.run(&.{ "git", "-C", bybranch, "checkout", "--quiet", "dev" });
    try tree.commit(bybranch, "three");
    var moved = try tree.syncIn(.dist);
    try std.testing.expect(try moved.enforceSiblings());
    try std.testing.expectEqualStrings(try tree.rev("origin/bybranch", "dev"), try tree.rev("bybranch", "HEAD"));
}

test "a distribution build refuses a dirty sibling, commits of its own, and a branch with no upstream" {
    var tree = try mod.TestTree.init();
    defer tree.deinit();
    try tree.upstream("mid", "");
    try tree.consumer(try tree.siblingWith("mid", ".branch = \"main\","));
    _ = try tree.sync();
    const mid = try tree.path("mid");

    try tree.write("mid/scratch", "x");
    var dirty = try tree.syncIn(.dist);
    try std.testing.expectError(error.DepsFailed, dirty.enforceSiblings());
    try std.testing.expect(std.mem.find(u8, dirty.problem, "uncommitted changes") != null);
    try tree.tmp.dir.deleteFile(tree.io, "mid/scratch");

    try tree.commit(mid, "mine");
    var ahead = try tree.syncIn(.dist);
    try std.testing.expectError(error.DepsFailed, ahead.enforceSiblings());
    try std.testing.expect(std.mem.find(u8, ahead.problem, "commits of its own") != null);
    try tree.run(&.{ "git", "-C", mid, "reset", "--quiet", "--hard", "HEAD~1" });

    try tree.run(&.{ "git", "-C", mid, "branch", "--unset-upstream" });
    var untracked = try tree.syncIn(.dist);
    try std.testing.expectError(error.DepsFailed, untracked.enforceSiblings());
    try std.testing.expect(std.mem.find(u8, untracked.problem, "no upstream") != null);
}

test "a ref value git could read as an option is refused" {
    var tree = try mod.TestTree.init();
    defer tree.deinit();
    try tree.consumer(".leaf = .{ .path = \"../leaf\", .branch = \"--orphan\" },");
    try std.testing.expect(std.mem.find(u8, try tree.syncFails(), "invalid .branch") != null);
    try tree.consumer(".leaf = .{ .path = \"deps/leaf\", .tag = \"\" },");
    try std.testing.expect(std.mem.find(u8, try tree.syncFails(), "invalid .tag") != null);
}

test "a distribution build refuses a local branch with commits of its own before switching to it" {
    var tree = try mod.TestTree.init();
    defer tree.deinit();
    try tree.upstream("mid", "");
    const origin = try tree.path("origin/mid");
    try tree.run(&.{ "git", "-C", origin, "branch", "dev" });
    try tree.consumer(try tree.siblingWith("mid", ".branch = \"dev\","));
    _ = try tree.sync();
    // A commit of its own on dev, then back on a pushed main.
    const mid = try tree.path("mid");
    try tree.commit(mid, "mine");
    try tree.run(&.{ "git", "-C", mid, "checkout", "--quiet", "-b", "main", "origin/main" });
    try tree.commit(origin, "two");
    try tree.run(&.{ "git", "-C", origin, "checkout", "--quiet", "dev" });
    try tree.commit(origin, "three");
    var run_ = try tree.syncIn(.dist);
    try std.testing.expectError(error.DepsFailed, run_.enforceSiblings());
    try std.testing.expect(std.mem.find(u8, run_.problem, "commits of its own on dev") != null);
    try std.testing.expectEqualStrings("main", (try mod.Git.currentBranch(tree.allocator(), tree.io, mid)).?);
}

test "a distribution build moves a clean detached sibling and fails on a tag its remote lacks" {
    var tree = try mod.TestTree.init();
    defer tree.deinit();
    try tree.upstream("mid", "");
    const origin = try tree.path("origin/mid");
    try tree.commit(origin, "two");
    try tree.run(&.{ "git", "-C", origin, "tag", "v2" });
    try tree.consumer(try tree.siblingWith("mid", ".tag = \"v1\","));
    _ = try tree.sync();
    try tree.consumer(try tree.siblingWith("mid", ".tag = \"v2\","));
    var run_ = try tree.syncIn(.dist);
    try std.testing.expect(try run_.enforceSiblings());
    try std.testing.expectEqualStrings(try tree.rev("origin/mid", "v2"), try tree.rev("mid", "HEAD"));

    try tree.consumer(try tree.siblingWith("mid", ".tag = \"v9\","));
    var missing = try tree.syncIn(.dist);
    try std.testing.expectError(error.DepsFailed, missing.enforceSiblings());
    try std.testing.expect(std.mem.find(u8, missing.problem, "is not on its remote") != null);
}

test "an orphan is kept while a worktree inside it has work of its own, and both go once it is clean" {
    var tree = try mod.TestTree.init();
    defer tree.deinit();
    try tree.upstream("nested", "");
    try tree.upstream("mid", try tree.allocator().print(".nested = .{{ .path = \"deps/nested\", .clone = \"{s}/origin/nested\", .branch = \"main\" }},", .{tree.root}));
    // mid ignores its deps/, as the README advises, so its own status cannot see nested's work.
    try tree.write("origin/mid/.gitignore", "deps/\n");
    try tree.commit(try tree.path("origin/mid"), "ignore");
    try tree.consumer(try tree.dep("mid", ".branch = \"main\","));
    _ = try tree.sync();
    try tree.tmp.dir.access(tree.io, "consumer/deps/mid/deps/nested/build.zig", .{});

    try tree.write("consumer/deps/mid/deps/nested/scratch", "x");
    try tree.consumer("");
    const kept = try tree.sync();
    try std.testing.expectEqual(2, kept.orphans.items.len);
    try tree.tmp.dir.access(tree.io, "consumer/deps/mid/deps/nested/scratch", .{});

    try tree.tmp.dir.deleteFile(tree.io, "consumer/deps/mid/deps/nested/scratch");
    const gone = try tree.sync();
    try std.testing.expectEqual(0, gone.orphans.items.len);
    try std.testing.expectError(error.FileNotFound, tree.tmp.dir.access(tree.io, "consumer/deps/mid", .{}));
}

test "a branch worktree's pushed commits are no longer its own" {
    var tree = try mod.TestTree.init();
    defer tree.deinit();
    try tree.upstream("leaf", "");
    const origin = try tree.path("origin/leaf");
    try tree.run(&.{ "git", "-C", origin, "config", "receive.denyCurrentBranch", "updateInstead" });
    try tree.consumer(try tree.dep("leaf", ".branch = \"main\","));
    _ = try tree.sync();
    const worktree = try tree.path("consumer/deps/leaf");
    try tree.commit(worktree, "mine");
    try tree.run(&.{ "git", "-C", worktree, "push", "--quiet", "origin", "HEAD:main" });

    var run_ = try tree.sync();
    const updated = try run_.update();
    try std.testing.expectEqual(0, updated.failed);
    // The stamp follows the pushed commit, so the next build is unchanged.
    const after = try tree.sync();
    try std.testing.expect(!after.changed);
    try std.testing.expectEqualStrings(try tree.rev("origin/leaf", "main"), after.worktrees.items[0].stamp.?.sha);
}
