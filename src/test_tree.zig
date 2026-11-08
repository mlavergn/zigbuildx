const std = @import("std");
const mod = @import("module.zig");

/// A scratch tree for the tests of `Sync`, `Stage` and `Vendor`: a consumer, origin repositories, and shared checkouts.
///
/// `<tmp>/origin/<name>` are the upstreams, each a Zig package tagged `v1`;
/// `<tmp>/<name>` are the shared checkouts, cloned on demand through `.clone`;
/// `<tmp>/consumer` is the root package.
pub const TestTree = struct {
    const Self = @This();
    /// The most `read` returns.
    const max_read_bytes = 1 << 20;
    /// Backs everything the fixture allocates; freed by `deinit`.
    arena: std.heap.ArenaAllocator,
    /// IO for the filesystem and the children.
    io: std.Io,
    /// The scratch directory, removed by `deinit`.
    tmp: std.testing.TmpDir,
    /// The scratch directory's absolute path.
    root: []const u8,

    /// Creates the scratch tree.
    ///
    /// - Returns: The fixture; IO errors.
    pub fn init() !Self {
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
    /// - `self`: The fixture.
    pub fn deinit(self: *Self) void {
        self.arena.deinit();
        self.tmp.cleanup();
    }

    /// Returns the fixture's allocator.
    ///
    /// - `self`: The fixture.
    /// - Returns: The arena's allocator.
    pub fn allocator(self: *Self) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Joins `sub` onto the scratch root.
    ///
    /// - `self`: The fixture.
    /// - `sub`: A path inside it.
    /// - Returns: The absolute path.
    pub fn path(self: *Self, sub: []const u8) ![]const u8 {
        return std.Io.Dir.path.join(self.allocator(), &.{ self.root, sub });
    }

    /// Creates upstream package `name` with the given dependencies, committed on `main` and tagged `v1`.
    ///
    /// - `self`: The fixture.
    /// - `name`: The package.
    /// - `dependencies`: The body of its `.dependencies`.
    /// - Returns: IO and spawn errors.
    pub fn upstream(self: *Self, name: []const u8, dependencies: []const u8) !void {
        const dir = try self.path(try self.allocator().print("origin/{s}", .{name}));
        try self.run(&.{ "git", "init", "--quiet", "--initial-branch=main", dir });
        // A whole manifest, which `zig fetch` validates when `Stage` stages it: the fingerprint's checksum is the name's.
        const fingerprint = (@as(u64, std.hash.Crc32.hash(name)) << 32) | 1;
        try self.write(try self.allocator().print("origin/{s}/build.zig.zon", .{name}), try self.allocator().print(".{{ .name = .{s}, .version = \"0.0.0\", .fingerprint = 0x{x}, .dependencies = .{{ {s} }}, .paths = .{{\"\"}} }}\n", .{ name, fingerprint, dependencies }));
        try self.write(try self.allocator().print("origin/{s}/build.zig", .{name}), "");
        try self.commit(dir, "one");
        try self.run(&.{ "git", "-C", dir, "tag", "v1" });
    }

    /// Writes the consumer's manifest.
    ///
    /// - `self`: The fixture.
    /// - `dependencies`: The body of its `.dependencies`.
    /// - Returns: IO errors.
    pub fn consumer(self: *Self, dependencies: []const u8) !void {
        try self.write("consumer/build.zig.zon", try self.allocator().print(".{{ .name = .consumer, .dependencies = .{{ {s} }} }}\n", .{dependencies}));
    }

    /// Writes the dependency text for `name` at `deps/<name>`, cloned from its upstream, plus `extra`.
    ///
    /// - `self`: The fixture.
    /// - `name`: The dependency.
    /// - `extra`: More fields, e.g. `.tag = "v1",`.
    /// - Returns: The text.
    pub fn dep(self: *Self, name: []const u8, extra: []const u8) ![]const u8 {
        return self.allocator().print(".{s} = .{{ .path = \"deps/{s}\", .clone = \"{s}/origin/{s}\", {s} }},", .{ name, name, self.root, name, extra });
    }

    /// Writes the dependency text for sibling `name` at `../<name>`, cloned from its upstream.
    ///
    /// - `self`: The fixture.
    /// - `name`: The dependency.
    /// - Returns: The text.
    pub fn sibling(self: *Self, name: []const u8) ![]const u8 {
        return self.allocator().print(".{s} = .{{ .path = \"../{s}\", .clone = \"{s}/origin/{s}\" }},", .{ name, name, self.root, name });
    }

    /// Runs a sync of the consumer.
    ///
    /// - `self`: The fixture.
    /// - Returns: The finished run; its errors.
    pub fn sync(self: *Self) !mod.Sync {
        return self.syncIn(.develop);
    }

    /// Runs a sync of the consumer in `mode`.
    ///
    /// - `self`: The fixture.
    /// - `mode`: How siblings are treated.
    /// - Returns: The finished run; its errors.
    pub fn syncIn(self: *Self, mode: mod.Mode) !mod.Sync {
        var run_ = try mod.Sync.init(self.allocator(), self.io, try self.path("consumer"));
        run_.mode = mode;
        try run_.run();
        return run_;
    }

    /// Writes the dependency text for sibling `name` at `../<name>`, cloned from its upstream, plus `extra`.
    ///
    /// - `self`: The fixture.
    /// - `name`: The dependency.
    /// - `extra`: More fields, e.g. `.tag = "v1",`.
    /// - Returns: The text.
    pub fn siblingWith(self: *Self, name: []const u8, extra: []const u8) ![]const u8 {
        return self.allocator().print(".{s} = .{{ .path = \"../{s}\", .clone = \"{s}/origin/{s}\", {s} }},", .{ name, name, self.root, name, extra });
    }

    /// Runs a sync of the consumer that must fail, and returns its problem.
    ///
    /// - `self`: The fixture.
    /// - Returns: The message; `error.TestUnexpectedResult` when the sync succeeds.
    pub fn syncFails(self: *Self) ![]const u8 {
        var run_ = try mod.Sync.init(self.allocator(), self.io, try self.path("consumer"));
        run_.run() catch |err| {
            try std.testing.expectEqual(error.DepsFailed, err);
            return run_.problem;
        };
        return error.TestUnexpectedResult;
    }

    /// Resolves `rev_` in the repository at `sub`.
    ///
    /// - `self`: The fixture.
    /// - `sub`: The repository, relative to the scratch root.
    /// - `rev_`: The revision.
    /// - Returns: The SHA; `error.TestUnexpectedResult` when it is not there.
    pub fn rev(self: *Self, sub: []const u8, rev_: []const u8) ![]const u8 {
        return try mod.Git.revParse(self.allocator(), self.io, try self.path(sub), rev_) orelse error.TestUnexpectedResult;
    }

    /// Writes a zip of `entries` (name, contents) at `sub`.
    ///
    /// - `self`: The fixture.
    /// - `sub`: The zip, relative to the scratch root, inside a directory.
    /// - `entries`: The entries, `/`-separated names.
    /// - Returns: Its `file://` URL; IO and zip errors.
    pub fn zip(self: *Self, sub: []const u8, entries: []const [2][]const u8) ![]const u8 {
        var archive = mod.ZipBuilder.init(self.allocator());
        defer archive.deinit();
        for (entries) |entry| try archive.addStored(entry[0], entry[1]);
        try self.write(sub, try archive.finish());
        return self.allocator().print("file://{s}", .{try self.path(sub)});
    }

    /// Writes a file, creating its directory.
    ///
    /// - `self`: The fixture.
    /// - `sub`: The file, relative to the scratch root.
    /// - `data`: Its contents.
    /// - Returns: IO errors.
    pub fn write(self: *Self, sub: []const u8, data: []const u8) !void {
        try self.tmp.dir.createDirPath(self.io, std.Io.Dir.path.dirname(sub).?);
        try self.tmp.dir.writeFile(self.io, .{ .sub_path = sub, .data = data });
    }

    /// Writes file `name` in repository `dir` and commits everything.
    ///
    /// - `self`: The fixture.
    /// - `dir`: The repository's absolute path.
    /// - `name`: The file, and the commit message.
    /// - Returns: IO and spawn errors.
    pub fn commit(self: *Self, dir: []const u8, name: []const u8) !void {
        const file = try std.Io.Dir.path.join(self.allocator(), &.{ dir, name });
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = file, .data = name });
        try self.run(&.{ "git", "-C", dir, "add", "--all" });
        try self.run(&.{ "git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "--quiet", "-m", name });
    }

    /// Returns the `zig` executable the build passed for tests that run it.
    ///
    /// - `self`: The fixture.
    /// - Returns: Its path; `error.SkipZigTest` when the build did not pass `ZIGBUILDX_ZIG`, as under `make cross`.
    pub fn zig(self: *Self) ![]const u8 {
        return std.testing.environ.getAlloc(self.allocator(), "ZIGBUILDX_ZIG") catch error.SkipZigTest;
    }

    /// Returns the scratch global cache the tests' `zig` children share, never the developer's own.
    /// It is kept beside `std.testing`'s scratch directories: a new one costs Zig half a minute to set up.
    ///
    /// - `self`: The fixture.
    /// - Returns: Its absolute path; IO errors.
    pub fn globalCache(self: *Self) ![]const u8 {
        const cache = try std.Io.Dir.cwd().realPathFileAlloc(self.io, ".zig-cache", self.allocator());
        return std.Io.Dir.path.join(self.allocator(), &.{ cache, "zigbuildx-test-global-cache" });
    }

    /// Returns the test process's environment with `ZIG_GLOBAL_CACHE_DIR` set to `globalCache`.
    ///
    /// - `self`: The fixture.
    /// - Returns: The environment, owned by the fixture; IO and allocation errors.
    pub fn zigEnviron(self: *Self) !*std.process.Environ.Map {
        const environ_map = try self.allocator().create(std.process.Environ.Map);
        environ_map.* = try std.testing.environ.createMap(self.allocator());
        try environ_map.put("ZIG_GLOBAL_CACHE_DIR", try self.globalCache());
        return environ_map;
    }

    /// Reads a file of the scratch tree.
    ///
    /// - `self`: The fixture.
    /// - `sub`: The file, relative to the scratch root.
    /// - Returns: Its contents, owned by the fixture; IO errors.
    pub fn read(self: *Self, sub: []const u8) ![]u8 {
        return self.tmp.dir.readFileAlloc(self.io, sub, self.allocator(), .limited(Self.max_read_bytes));
    }

    /// Runs a command and expects it to succeed.
    ///
    /// - `self`: The fixture.
    /// - `argv`: The command.
    /// - Returns: `error.TestUnexpectedResult` on failure, or spawn errors.
    pub fn run(self: *Self, argv: []const []const u8) !void {
        const result = try std.process.run(self.allocator(), self.io, .{ .argv = argv });
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    }
};
