const std = @import("std");
const log = std.log.scoped(.zigbuildx_git);

/// Where a new worktree's HEAD goes; see `Git.worktreeAdd`.
pub const WorktreeHead = union(enum) {
    /// Detached at this commit.
    detached: []const u8,
    /// On this branch, created at `start` unless `start` is null.
    branch: struct { name: []const u8, start: ?[]const u8 },
};

/// Runs `git` for the build.
///
/// One function per git command. Each knows nothing about manifests, pins or
/// stamps; `Deps` owns that policy. `repo` is the directory git runs in (`-C`),
/// a checkout or a worktree.
pub const Git = struct {
    const Self = @This();

    /// Clones the repository at `url` into `dest`, at `ref` or the remote's default branch.
    ///
    /// Parameters:
    /// - `io`: IO the `git` child is spawned on.
    /// - `url`: the repository to clone.
    /// - `dest`: the directory to clone into.
    /// - `ref`: the branch, or the tag (HEAD then detached), to check out; null for the remote's HEAD.
    ///
    /// Return: nothing; `error.GitCloneFailed` when `git` fails, or spawn errors.
    pub fn clone(io: std.Io, url: []const u8, dest: []const u8, ref: ?[]const u8) !void {
        // `--` ends the options, so a URL from a manifest cannot pass as one (`--upload-pack=...`).
        // A tag detaches HEAD, and `--quiet` does not silence git's advice about that.
        const default_argv = [_][]const u8{ "git", "clone", "--quiet", "--", url, dest };
        const ref_argv = [_][]const u8{ "git", "-c", "advice.detachedHead=false", "clone", "--quiet", "--branch", ref orelse "", "--", url, dest };
        const argv: []const []const u8 = if (ref != null) &ref_argv else &default_argv;
        var child = std.process.spawn(io, .{ .argv = argv }) catch |err| {
            log.err("cannot run git [{any}]", .{err});
            return err;
        };
        const term = try child.wait(io);
        switch (term) {
            .exited => |code| if (code == 0) {
                log.info("cloned {s} into {s}", .{ url, dest });
                return;
            },
            else => {},
        }
        log.err("git clone {s} {s} failed [{any}]", .{ url, dest, term });
        return error.GitCloneFailed;
    }

    /// Fetches branches and tags from the default remote, accepting tags moved upstream.
    ///
    /// Parameters:
    /// - `allocator`: allocator for the child's output, freed before return.
    /// - `io`: IO the `git` child is spawned on.
    /// - `repo`: the checkout to fetch into.
    ///
    /// Return: nothing; `error.GitFailed` when `git` fails, or spawn errors.
    pub fn fetch(allocator: std.mem.Allocator, io: std.Io, repo: []const u8) !void {
        // `--force`: without it a tag moved upstream makes `--tags` exit 1 ("would clobber existing tag").
        // The checkout's tag then follows upstream; a worktree pinned to it keeps its stamped commit.
        try Self.runVoid(allocator, io, repo, &.{ "fetch", "--tags", "--force", "--quiet" });
    }

    /// Starts the fetch `fetch` runs without waiting for it, so several can overlap.
    ///
    /// Parameters:
    /// - `io`: IO the `git` child is spawned on.
    /// - `repo`: the checkout to fetch into.
    ///
    /// Return: the running child, for `finishFetch`; spawn errors.
    pub fn startFetch(io: std.Io, repo: []const u8) !std.process.Child {
        // The arguments `fetch` passes; git's own errors reach stderr, as `clone`'s do.
        return std.process.spawn(io, .{ .argv = &.{ "git", "-C", repo, "fetch", "--tags", "--force", "--quiet" }, .stdin = .ignore, .stdout = .ignore });
    }

    /// Waits for a child that `startFetch` began.
    ///
    /// Parameters:
    /// - `io`: IO the child was spawned on.
    /// - `child`: the running child.
    ///
    /// Return: `true` when the fetch succeeded.
    pub fn finishFetch(io: std.Io, child: *std.process.Child) bool {
        const term = child.wait(io) catch return false;
        return switch (term) {
            .exited => |code| code == 0,
            else => false,
        };
    }

    /// Names the branch the `origin` remote's HEAD points at, asking the remote.
    ///
    /// Parameters:
    /// - `allocator`: allocator for the returned name.
    /// - `io`: IO the `git` child is spawned on.
    /// - `repo`: a checkout with an `origin` remote.
    ///
    /// Return: the branch without `refs/heads/`, owned by the caller; `null` when the remote has no commits; `error.GitFailed` or spawn errors.
    pub fn remoteHead(allocator: std.mem.Allocator, io: std.Io, repo: []const u8) !?[]u8 {
        // An empty remote lists nothing and exits 0; otherwise the first line is `ref: refs/heads/<b>\tHEAD`.
        const out = try Self.run(allocator, io, repo, &.{ "ls-remote", "--symref", "origin", "HEAD" });
        defer allocator.free(out);
        const prefix = "ref: refs/heads/";
        if (!std.mem.startsWith(u8, out, prefix)) return null;
        const rest = out[prefix.len..];
        const end = std.mem.findScalar(u8, rest, '\t') orelse return null;
        return try allocator.dupe(u8, rest[0..end]);
    }

    /// Resolves `rev` to the full SHA of the commit it names.
    ///
    /// Parameters:
    /// - `allocator`: allocator for the returned SHA.
    /// - `io`: IO the `git` child is spawned on.
    /// - `repo`: the checkout or worktree to resolve in.
    /// - `rev`: any revision git accepts: a SHA, `refs/tags/<tag>`, `refs/remotes/origin/<branch>`, `HEAD`.
    ///
    /// Return: the SHA, owned by the caller; `null` when `rev` names no commit; `error.GitFailed` or spawn errors.
    pub fn revParse(allocator: std.mem.Allocator, io: std.Io, repo: []const u8, rev: []const u8) !?[]u8 {
        const commit = try allocator.print("{s}^{{commit}}", .{rev});
        defer allocator.free(commit);
        return Self.runOptional(allocator, io, repo, &.{ "rev-parse", "--verify", "--quiet", commit });
    }

    /// Names the branch HEAD is on.
    ///
    /// Parameters:
    /// - `allocator`: allocator for the returned name.
    /// - `io`: IO the `git` child is spawned on.
    /// - `repo`: the checkout or worktree to inspect.
    ///
    /// Return: the branch without `refs/heads/`, owned by the caller; `null` when detached; `error.GitFailed` or spawn errors.
    pub fn currentBranch(allocator: std.mem.Allocator, io: std.Io, repo: []const u8) !?[]u8 {
        return Self.runOptional(allocator, io, repo, &.{ "symbolic-ref", "--quiet", "--short", "HEAD" });
    }

    /// Resolves the upstream of the branch HEAD is on (`@{u}`).
    ///
    /// Parameters:
    /// - `allocator`: allocator for the returned SHA.
    /// - `io`: IO the `git` child is spawned on.
    /// - `repo`: the checkout to inspect.
    ///
    /// Return: the upstream's last-fetched SHA, owned by the caller; `null` with no upstream or when detached; `error.GitFailed` or spawn errors.
    pub fn upstream(allocator: std.mem.Allocator, io: std.Io, repo: []const u8) !?[]u8 {
        return Self.revParse(allocator, io, repo, "@{u}");
    }

    /// Adds a worktree at `path`, detached at `commit` or on `branch`.
    ///
    /// Parameters:
    /// - `allocator`: allocator for the child's output, freed before return.
    /// - `io`: IO the `git` child is spawned on.
    /// - `repo`: the checkout that owns the worktree.
    /// - `path`: where the worktree goes; must not exist.
    /// - `on`: `.detached` at a commit, or `.branch`: a start creates it there, a null start checks out an existing one.
    ///
    /// Return: nothing; `error.GitFailed` when `git` fails, or spawn errors.
    pub fn worktreeAdd(allocator: std.mem.Allocator, io: std.Io, repo: []const u8, path: []const u8, on: WorktreeHead) !void {
        switch (on) {
            .detached => |commit| try Self.runVoid(allocator, io, repo, &.{ "worktree", "add", "--quiet", "--detach", path, commit }),
            .branch => |branch| if (branch.start) |start| {
                try Self.runVoid(allocator, io, repo, &.{ "worktree", "add", "--quiet", "-b", branch.name, path, start });
            } else {
                try Self.runVoid(allocator, io, repo, &.{ "worktree", "add", "--quiet", path, branch.name });
            },
        }
    }

    /// Clears the records of worktrees whose directories are gone.
    ///
    /// Parameters:
    /// - `allocator`: allocator for the child's output, freed before return.
    /// - `io`: IO the `git` child is spawned on.
    /// - `repo`: the checkout that owns the worktrees.
    ///
    /// Return: nothing; `error.GitFailed` when `git` fails, or spawn errors.
    pub fn worktreePrune(allocator: std.mem.Allocator, io: std.Io, repo: []const u8) !void {
        try Self.runVoid(allocator, io, repo, &.{ "worktree", "prune" });
    }

    /// Removes the worktree at `path`; git refuses when it has uncommitted changes.
    ///
    /// Parameters:
    /// - `allocator`: allocator for the child's output, freed before return.
    /// - `io`: IO the `git` child is spawned on.
    /// - `repo`: the checkout that owns the worktree.
    /// - `path`: the worktree to remove.
    ///
    /// Return: nothing; `error.GitFailed` when `git` fails, or spawn errors.
    pub fn worktreeRemove(allocator: std.mem.Allocator, io: std.Io, repo: []const u8, path: []const u8) !void {
        try Self.runVoid(allocator, io, repo, &.{ "worktree", "remove", path });
    }

    /// Detaches HEAD at `commit`.
    ///
    /// Parameters:
    /// - `allocator`: allocator for the child's output, freed before return.
    /// - `io`: IO the `git` child is spawned on.
    /// - `repo`: the worktree to move.
    /// - `commit`: the commit to check out.
    ///
    /// Return: nothing; `error.GitFailed` when `git` fails, or spawn errors.
    pub fn checkoutDetached(allocator: std.mem.Allocator, io: std.Io, repo: []const u8, commit: []const u8) !void {
        try Self.runVoid(allocator, io, repo, &.{ "checkout", "--quiet", "--detach", commit });
    }

    /// Checks out branch `name`, creating it at `start` when `start` is not null.
    ///
    /// Parameters:
    /// - `allocator`: allocator for the child's output, freed before return.
    /// - `io`: IO the `git` child is spawned on.
    /// - `repo`: the worktree to move.
    /// - `name`: the branch.
    /// - `start`: the commit a new branch starts at; null to check out an existing one.
    ///
    /// Return: nothing; `error.GitFailed` when `git` fails, or spawn errors.
    pub fn checkoutBranch(allocator: std.mem.Allocator, io: std.Io, repo: []const u8, name: []const u8, start: ?[]const u8) !void {
        if (start) |commit| {
            try Self.runVoid(allocator, io, repo, &.{ "checkout", "--quiet", "-b", name, commit });
        } else {
            try Self.runVoid(allocator, io, repo, &.{ "checkout", "--quiet", name });
        }
    }

    /// Creates branch `name` at `origin/<name>`, tracking it, and checks it out.
    ///
    /// Parameters:
    /// - `allocator`: allocator for the child's output, freed before return.
    /// - `io`: IO the `git` child is spawned on.
    /// - `repo`: the checkout; `origin/<name>` must have been fetched.
    /// - `name`: the branch.
    ///
    /// Return: nothing; `error.GitFailed` when `git` fails, or spawn errors.
    pub fn checkoutTracking(allocator: std.mem.Allocator, io: std.Io, repo: []const u8, name: []const u8) !void {
        const start = try allocator.print("refs/remotes/origin/{s}", .{name});
        defer allocator.free(start);
        try Self.runVoid(allocator, io, repo, &.{ "checkout", "--quiet", "--track", "-b", name, start });
    }

    /// Fast-forwards the checked-out branch to `commit`; git refuses anything but a fast-forward.
    ///
    /// Parameters:
    /// - `allocator`: allocator for the child's output, freed before return.
    /// - `io`: IO the `git` child is spawned on.
    /// - `repo`: the worktree to move.
    /// - `commit`: the commit to move to.
    ///
    /// Return: nothing; `error.GitFailed` when `git` fails, or spawn errors.
    pub fn fastForward(allocator: std.mem.Allocator, io: std.Io, repo: []const u8, commit: []const u8) !void {
        try Self.runVoid(allocator, io, repo, &.{ "merge", "--quiet", "--ff-only", commit });
    }

    /// Reports whether the worktree has no uncommitted changes, untracked files included.
    ///
    /// Parameters:
    /// - `allocator`: allocator for the child's output, freed before return.
    /// - `io`: IO the `git` child is spawned on.
    /// - `repo`: the worktree to inspect.
    ///
    /// Return: `true` when clean; `error.GitFailed` when `git` fails, or spawn errors.
    pub fn isClean(allocator: std.mem.Allocator, io: std.Io, repo: []const u8) !bool {
        const out = try Self.run(allocator, io, repo, &.{ "status", "--porcelain" });
        defer allocator.free(out);
        return out.len == 0;
    }

    /// Reports whether HEAD has commits that `base` does not.
    ///
    /// Parameters:
    /// - `allocator`: allocator for the child's output, freed before return.
    /// - `io`: IO the `git` child is spawned on.
    /// - `repo`: the worktree to inspect.
    /// - `base`: the commit HEAD is compared with.
    ///
    /// Return: `true` when HEAD is ahead of `base`; `error.GitFailed` when `git` fails, or spawn errors.
    pub fn isAhead(allocator: std.mem.Allocator, io: std.Io, repo: []const u8, base: []const u8) !bool {
        const range = try allocator.print("{s}..HEAD", .{base});
        defer allocator.free(range);
        const out = try Self.run(allocator, io, repo, &.{ "rev-list", "--count", range });
        defer allocator.free(out);
        return !std.mem.eql(u8, out, "0");
    }

    /// Reports whether `ancestor` is reachable from `descendant`, so moving `ancestor`'s branch there loses nothing.
    ///
    /// Parameters:
    /// - `allocator`: allocator for the child's output, freed before return.
    /// - `io`: IO the `git` child is spawned on.
    /// - `repo`: the checkout to inspect.
    /// - `ancestor`: a revision, e.g. `refs/heads/<branch>`.
    /// - `descendant`: a revision, e.g. a fetched commit.
    ///
    /// Return: `true` when it is an ancestor or the same commit; `error.GitFailed` when `git` fails, or spawn errors.
    pub fn isAncestor(allocator: std.mem.Allocator, io: std.Io, repo: []const u8, ancestor: []const u8, descendant: []const u8) !bool {
        const out = try Self.runOptional(allocator, io, repo, &.{ "merge-base", "--is-ancestor", ancestor, descendant }) orelse return false;
        allocator.free(out);
        return true;
    }

    /// Reports whether local branch `name` exists.
    ///
    /// Parameters:
    /// - `allocator`: allocator for the child's output, freed before return.
    /// - `io`: IO the `git` child is spawned on.
    /// - `repo`: the checkout or worktree to inspect.
    /// - `name`: the branch, without `refs/heads/`.
    ///
    /// Return: `true` when it exists; `error.GitFailed` when `git` fails, or spawn errors.
    pub fn branchExists(allocator: std.mem.Allocator, io: std.Io, repo: []const u8, name: []const u8) !bool {
        const ref = try allocator.print("refs/heads/{s}", .{name});
        defer allocator.free(ref);
        const out = try Self.runOptional(allocator, io, repo, &.{ "show-ref", "--verify", "--quiet", ref }) orelse return false;
        allocator.free(out);
        return true;
    }

    /// Deletes local branch `name`; git refuses when it has unmerged commits.
    ///
    /// Parameters:
    /// - `allocator`: allocator for the child's output, freed before return.
    /// - `io`: IO the `git` child is spawned on.
    /// - `repo`: the checkout that owns the branch.
    /// - `name`: the branch.
    ///
    /// Return: nothing; `error.GitFailed` when `git` fails, or spawn errors.
    pub fn branchDelete(allocator: std.mem.Allocator, io: std.Io, repo: []const u8, name: []const u8) !void {
        try Self.runVoid(allocator, io, repo, &.{ "branch", "--quiet", "-d", name });
    }

    /// Lists the tags of the remote repository at `url`, without fetching it.
    ///
    /// Parameters:
    /// - `allocator`: allocator for the returned listing.
    /// - `io`: IO the `git` child is spawned on.
    /// - `repo`: any directory git may run in; nothing in it is read.
    /// - `url`: the remote repository.
    ///
    /// Return: `<sha>\trefs/tags/<tag>` lines, plus `<commit>\trefs/tags/<tag>^{}` for an annotated tag, owned by the caller; `error.GitFailed` or spawn errors.
    pub fn remoteTags(allocator: std.mem.Allocator, io: std.Io, repo: []const u8, url: []const u8) ![]u8 {
        // `--` ends the options, so a URL from a manifest cannot pass as one. No `--refs`:
        // an annotated tag's own line names the tag object, and only its `^{}` line the commit.
        return Self.run(allocator, io, repo, &.{ "ls-remote", "--tags", "--", url });
    }

    /// Reports whether git ignores `path`, so it can never be committed by accident.
    ///
    /// Parameters:
    /// - `allocator`: allocator for the child's output, freed before return.
    /// - `io`: IO the `git` child is spawned on.
    /// - `repo`: a directory inside the repository.
    /// - `path`: the file, relative to `repo`.
    ///
    /// Return: `true` when ignored; `error.GitFailed` when `repo` is outside a repository, or spawn errors.
    pub fn isIgnored(allocator: std.mem.Allocator, io: std.Io, repo: []const u8, path: []const u8) !bool {
        const out = try Self.runOptional(allocator, io, repo, &.{ "check-ignore", "--quiet", path }) orelse return false;
        allocator.free(out);
        return true;
    }

    /// Runs `git -C repo args…` and discards its output.
    ///
    /// Parameters:
    /// - `allocator`: allocator for the child's output, freed before return.
    /// - `io`: IO the `git` child is spawned on.
    /// - `repo`: the directory git runs in.
    /// - `args`: the arguments after `git -C repo`.
    ///
    /// Return: nothing; `error.GitFailed` when `git` fails, or spawn errors.
    fn runVoid(allocator: std.mem.Allocator, io: std.Io, repo: []const u8, args: []const []const u8) !void {
        allocator.free(try Self.run(allocator, io, repo, args));
    }

    /// Runs `git -C repo args…` and returns its trimmed stdout; any non-zero exit is a failure.
    ///
    /// Parameters:
    /// - `allocator`: allocator for the returned output.
    /// - `io`: IO the `git` child is spawned on.
    /// - `repo`: the directory git runs in.
    /// - `args`: the arguments after `git -C repo`.
    ///
    /// Return: trimmed stdout, owned by the caller; `error.GitFailed` when `git` fails, or spawn errors.
    fn run(allocator: std.mem.Allocator, io: std.Io, repo: []const u8, args: []const []const u8) ![]u8 {
        return try Self.runExpecting(allocator, io, repo, args, false) orelse unreachable;
    }

    /// Runs `git -C repo args…`, treating exit 1 as "not found".
    ///
    /// Parameters:
    /// - `allocator`: allocator for the returned output.
    /// - `io`: IO the `git` child is spawned on.
    /// - `repo`: the directory git runs in.
    /// - `args`: the arguments after `git -C repo`.
    ///
    /// Return: trimmed stdout, owned by the caller; `null` on exit 1; `error.GitFailed` or spawn errors.
    fn runOptional(allocator: std.mem.Allocator, io: std.Io, repo: []const u8, args: []const []const u8) !?[]u8 {
        return Self.runExpecting(allocator, io, repo, args, true);
    }

    /// Runs `git -C repo args…` and collects its output.
    ///
    /// Parameters:
    /// - `allocator`: allocator for the returned output.
    /// - `io`: IO the `git` child is spawned on.
    /// - `repo`: the directory git runs in.
    /// - `args`: the arguments after `git -C repo`.
    /// - `missing_ok`: whether exit 1 means "not found" rather than failure.
    ///
    /// Return: trimmed stdout, owned by the caller; `null` on exit 1 when `missing_ok`; `error.GitFailed` or spawn errors.
    fn runExpecting(allocator: std.mem.Allocator, io: std.Io, repo: []const u8, args: []const []const u8, missing_ok: bool) !?[]u8 {
        const argv = try allocator.alloc([]const u8, args.len + 3);
        defer allocator.free(argv);
        argv[0] = "git";
        argv[1] = "-C";
        argv[2] = repo;
        @memcpy(argv[3..], args);
        const result = std.process.run(allocator, io, .{ .argv = argv }) catch |err| {
            log.err("cannot run git [{any}]", .{err});
            return err;
        };
        defer allocator.free(result.stderr);
        const code: ?u8 = switch (result.term) {
            .exited => |code| code,
            else => null,
        };
        if (code == 0) {
            defer allocator.free(result.stdout);
            return try allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \t\r\n"));
        }
        allocator.free(result.stdout);
        if (missing_ok and code == 1) return null;
        log.err("git -C {s} {s} failed [{any}]: {s}", .{ repo, args[0], result.term, std.mem.trim(u8, result.stderr, " \t\r\n") });
        return error.GitFailed;
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

/// A scratch origin repository with one commit on `main`, tagged `v1`.
const TestRepo = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    io: std.Io,
    tmp: std.testing.TmpDir,
    root: [:0]const u8,

    /// Creates the scratch directory and the origin repository in it.
    ///
    /// Parameters:
    /// - `allocator`: allocator for paths; freed by `deinit`.
    /// - `io`: IO for the filesystem and `git`.
    ///
    /// Return: the fixture; spawn and filesystem errors.
    fn init(allocator: std.mem.Allocator, io: std.Io) !Self {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
        errdefer allocator.free(root);
        var self = Self{ .allocator = allocator, .io = io, .tmp = tmp, .root = root };
        const origin = try self.path("origin");
        defer allocator.free(origin);
        try self.git(&.{ "git", "init", "--quiet", "--initial-branch=main", origin });
        try self.commit("origin", "one");
        try self.git(&.{ "git", "-C", origin, "tag", "v1" });
        return self;
    }

    /// Removes the scratch directory.
    ///
    /// Parameters:
    /// - `self`: the fixture.
    fn deinit(self: *Self) void {
        self.allocator.free(self.root);
        self.tmp.cleanup();
    }

    /// Joins `sub` onto the scratch directory.
    ///
    /// Parameters:
    /// - `self`: the fixture.
    /// - `sub`: a path inside it.
    ///
    /// Return: the absolute path, owned by the caller; allocation errors.
    fn path(self: *const Self, sub: []const u8) ![]u8 {
        return std.Io.Dir.path.join(self.allocator, &.{ self.root, sub });
    }

    /// Writes file `name` in repository `repo` and commits it.
    ///
    /// Parameters:
    /// - `self`: the fixture.
    /// - `repo`: the repository, relative to the scratch directory.
    /// - `name`: the file to write and the commit message.
    ///
    /// Return: nothing; spawn and filesystem errors.
    fn commit(self: *const Self, repo: []const u8, name: []const u8) !void {
        const dir = try self.path(repo);
        defer self.allocator.free(dir);
        const file = try std.Io.Dir.path.join(self.allocator, &.{ repo, name });
        defer self.allocator.free(file);
        try self.tmp.dir.writeFile(self.io, .{ .sub_path = file, .data = name });
        try self.git(&.{ "git", "-C", dir, "add", name });
        try self.git(&.{ "git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "--quiet", "-m", name });
    }

    /// Runs a command and expects it to succeed.
    ///
    /// Parameters:
    /// - `self`: the fixture.
    /// - `argv`: the command.
    ///
    /// Return: nothing; `error.TestUnexpectedResult` on failure, or spawn errors.
    fn git(self: *const Self, argv: []const []const u8) !void {
        const result = try std.process.run(self.allocator, self.io, .{ .argv = argv });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    }
};

test "clone copies a repository" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var repo = try TestRepo.init(allocator, io);
    defer repo.deinit();
    const origin = try repo.path("origin");
    defer allocator.free(origin);
    const dest = try repo.path("clone");
    defer allocator.free(dest);
    try Git.clone(io, origin, dest, null);
    try repo.tmp.dir.access(io, "clone/.git", .{});
}

test "clone checks out the branch or tag asked for" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var repo = try TestRepo.init(allocator, io);
    defer repo.deinit();
    const origin = try repo.path("origin");
    defer allocator.free(origin);
    try repo.git(&.{ "git", "-C", origin, "branch", "dev" });
    const dest = try repo.path("clone");
    defer allocator.free(dest);
    try Git.clone(io, origin, dest, "dev");
    const branch = (try Git.currentBranch(allocator, io, dest)).?;
    defer allocator.free(branch);
    try std.testing.expectEqualStrings("dev", branch);

    // A tag leaves HEAD detached there.
    const tagged = try repo.path("tagged");
    defer allocator.free(tagged);
    try Git.clone(io, origin, tagged, "v1");
    try std.testing.expectEqual(null, try Git.currentBranch(allocator, io, tagged));
}

test "remoteHead names the remote's default branch, and null for an empty remote" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var repo = try TestRepo.init(allocator, io);
    defer repo.deinit();
    const origin = try repo.path("origin");
    defer allocator.free(origin);
    const dest = try repo.path("clone");
    defer allocator.free(dest);
    try Git.clone(io, origin, dest, null);
    const head = (try Git.remoteHead(allocator, io, dest)).?;
    defer allocator.free(head);
    try std.testing.expectEqualStrings("main", head);

    const empty = try repo.path("empty");
    defer allocator.free(empty);
    try repo.git(&.{ "git", "init", "--quiet", "--bare", empty });
    const local = try repo.path("local");
    defer allocator.free(local);
    try repo.git(&.{ "git", "init", "--quiet", local });
    try repo.git(&.{ "git", "-C", local, "remote", "add", "origin", empty });
    try std.testing.expectEqual(null, try Git.remoteHead(allocator, io, local));
}

test "checkoutTracking puts a repository with no commits on a fetched branch" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var repo = try TestRepo.init(allocator, io);
    defer repo.deinit();
    const origin = try repo.path("origin");
    defer allocator.free(origin);
    const local = try repo.path("local");
    defer allocator.free(local);
    try repo.git(&.{ "git", "init", "--quiet", "--initial-branch=main", local });
    try repo.git(&.{ "git", "-C", local, "remote", "add", "origin", origin });
    var child = try Git.startFetch(io, local);
    try std.testing.expect(Git.finishFetch(io, &child));
    try Git.checkoutTracking(allocator, io, local, "main");
    try repo.tmp.dir.access(io, "local/one", .{});
    const tip = (try Git.upstream(allocator, io, local)).?;
    defer allocator.free(tip);
    const want = (try Git.revParse(allocator, io, origin, "main")).?;
    defer allocator.free(want);
    try std.testing.expectEqualStrings(want, tip);
}

test "revParse resolves tags and branches and reports a missing revision" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var repo = try TestRepo.init(allocator, io);
    defer repo.deinit();
    const origin = try repo.path("origin");
    defer allocator.free(origin);
    const head = (try Git.revParse(allocator, io, origin, "HEAD")).?;
    defer allocator.free(head);
    try std.testing.expectEqual(40, head.len);
    const tag = (try Git.revParse(allocator, io, origin, "refs/tags/v1")).?;
    defer allocator.free(tag);
    try std.testing.expectEqualStrings(head, tag);
    try std.testing.expectEqual(null, try Git.revParse(allocator, io, origin, "refs/tags/nope"));
}

test "fetch brings a new tag into a clone" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var repo = try TestRepo.init(allocator, io);
    defer repo.deinit();
    const origin = try repo.path("origin");
    defer allocator.free(origin);
    const checkout = try repo.path("checkout");
    defer allocator.free(checkout);
    try Git.clone(io, origin, checkout, null);
    try repo.commit("origin", "two");
    try repo.git(&.{ "git", "-C", origin, "tag", "v2" });
    try std.testing.expectEqual(null, try Git.revParse(allocator, io, checkout, "refs/tags/v2"));
    try Git.fetch(allocator, io, checkout);
    const v2 = (try Git.revParse(allocator, io, checkout, "refs/tags/v2")).?;
    allocator.free(v2);
}

test "fetch accepts a tag moved upstream" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var repo = try TestRepo.init(allocator, io);
    defer repo.deinit();
    const origin = try repo.path("origin");
    defer allocator.free(origin);
    const checkout = try repo.path("checkout");
    defer allocator.free(checkout);
    try Git.clone(io, origin, checkout, null);
    try repo.commit("origin", "two");
    try repo.git(&.{ "git", "-C", origin, "tag", "--force", "v1" });
    try Git.fetch(allocator, io, checkout);
    const moved = (try Git.revParse(allocator, io, checkout, "refs/tags/v1")).?;
    defer allocator.free(moved);
    const head = (try Git.revParse(allocator, io, origin, "HEAD")).?;
    defer allocator.free(head);
    try std.testing.expectEqualStrings(head, moved);
}

test "currentBranch and upstream follow a clone's branch and report a detached HEAD" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var repo = try TestRepo.init(allocator, io);
    defer repo.deinit();
    const origin = try repo.path("origin");
    defer allocator.free(origin);
    const checkout = try repo.path("checkout");
    defer allocator.free(checkout);
    try Git.clone(io, origin, checkout, null);

    // A clone's branch tracks origin's; origin's own branch tracks nothing.
    const branch = (try Git.currentBranch(allocator, io, checkout)).?;
    defer allocator.free(branch);
    try std.testing.expectEqualStrings("main", branch);
    const up = (try Git.upstream(allocator, io, checkout)).?;
    defer allocator.free(up);
    const head = (try Git.revParse(allocator, io, origin, "HEAD")).?;
    defer allocator.free(head);
    try std.testing.expectEqualStrings(head, up);
    try std.testing.expectEqual(null, try Git.upstream(allocator, io, origin));

    try repo.git(&.{ "git", "-C", checkout, "checkout", "--quiet", "--detach" });
    try std.testing.expectEqual(null, try Git.currentBranch(allocator, io, checkout));
    try std.testing.expectEqual(null, try Git.upstream(allocator, io, checkout));
}

test "worktrees: add, inspect, move, remove" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var repo = try TestRepo.init(allocator, io);
    defer repo.deinit();
    const origin = try repo.path("origin");
    defer allocator.free(origin);
    const one = (try Git.revParse(allocator, io, origin, "HEAD")).?;
    defer allocator.free(one);
    try repo.commit("origin", "two");
    const two = (try Git.revParse(allocator, io, origin, "HEAD")).?;
    defer allocator.free(two);

    // Detached at the first commit; clean, and not ahead of it.
    const detached = try repo.path("detached");
    defer allocator.free(detached);
    try Git.worktreeAdd(allocator, io, origin, detached, .{ .detached = one });
    try std.testing.expect(try Git.isClean(allocator, io, detached));
    try std.testing.expect(!try Git.isAhead(allocator, io, detached, one));
    try Git.checkoutDetached(allocator, io, detached, two);
    try std.testing.expect(try Git.isAhead(allocator, io, detached, one));

    // On a new branch at the first commit, then fast-forwarded.
    const branched = try repo.path("branched");
    defer allocator.free(branched);
    try std.testing.expect(!try Git.branchExists(allocator, io, origin, "me/main"));
    try Git.worktreeAdd(allocator, io, origin, branched, .{ .branch = .{ .name = "me/main", .start = one } });
    try std.testing.expect(try Git.branchExists(allocator, io, origin, "me/main"));
    try Git.fastForward(allocator, io, branched, two);
    const moved = (try Git.revParse(allocator, io, branched, "HEAD")).?;
    defer allocator.free(moved);
    try std.testing.expectEqualStrings(two, moved);

    // The first commit is an ancestor of the second, not the reverse.
    try std.testing.expect(try Git.isAncestor(allocator, io, origin, one, two));
    try std.testing.expect(!try Git.isAncestor(allocator, io, origin, two, one));

    // A dirty worktree is not clean.
    try repo.tmp.dir.writeFile(io, .{ .sub_path = "branched/scratch", .data = "x" });
    try std.testing.expect(!try Git.isClean(allocator, io, branched));
    try repo.tmp.dir.deleteFile(io, "branched/scratch");

    // Removed, then re-added on the existing branch after a hand deletion and a prune.
    try Git.worktreeRemove(allocator, io, origin, branched);
    try Git.worktreeAdd(allocator, io, origin, branched, .{ .branch = .{ .name = "me/main", .start = null } });
    try repo.tmp.dir.deleteTree(io, "branched");
    try Git.worktreePrune(allocator, io, origin);
    try Git.worktreeAdd(allocator, io, origin, branched, .{ .branch = .{ .name = "me/main", .start = null } });
    try Git.checkoutBranch(allocator, io, branched, "me/other", one);
    try Git.checkoutBranch(allocator, io, branched, "me/main", null);
    try Git.branchDelete(allocator, io, origin, "me/other");
    try std.testing.expect(!try Git.branchExists(allocator, io, origin, "me/other"));
}

test "isIgnored follows .gitignore" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var repo = try TestRepo.init(allocator, io);
    defer repo.deinit();
    const origin = try repo.path("origin");
    defer allocator.free(origin);
    try repo.tmp.dir.writeFile(io, .{ .sub_path = "origin/.gitignore", .data = "signing.env\n" });
    try std.testing.expect(try Git.isIgnored(allocator, io, origin, "signing.env"));
    try std.testing.expect(!try Git.isIgnored(allocator, io, origin, "build.zig"));
}
