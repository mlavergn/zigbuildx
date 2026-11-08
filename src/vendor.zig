const std = @import("std");
const log = std.log.scoped(.zigbuildx_vendor);
const mod = @import("module.zig");
const builtin = @import("builtin");

/// One entry of the tree `Vendor` writes into a tarball.
const TreeEntry = struct {
    const Self = @This();
    /// The path below the export, with the host's separator.
    path: []const u8,
    /// The path as the tarball names it, with `/`.
    name: []const u8,
    /// A directory, a link, or a file.
    kind: std.Io.File.Kind,

    /// Orders entries by their tarball names, so two runs write them alike.
    ///
    /// - `context`: Unused.
    /// - `a`: An entry.
    /// - `b`: Another.
    /// - Returns: `true` when `a` sorts first.
    fn lessThan(context: void, a: Self, b: Self) bool {
        _ = context;
        return std.mem.lessThan(u8, a.name, b.name);
    }
};

/// Writes a self-contained source tarball of a consumer at the commits it was last built from, which builds with no network.
///
/// The root's HEAD is exported; its own inside `.path` dependencies, each
/// sibling's HEAD (siblings of siblings included) and every `.url`
/// dependency go into the export's `zig-pkg/`, named by hash in its
/// manifests; a marker makes zigbuildx inert there; the export is built
/// with a global cache that holds no packages, to prove it needs nothing
/// else; and it is written as `<name>-<version>-<commit>.tar.gz`. A tracked
/// change, or a sibling off its declared ref, is refused. No git remote is
/// read; Zig fetches a `.url` dependency only when its global cache lacks it.
pub const Vendor = struct {
    const Self = @This();
    /// The marker at the root of a vendored tree: what it was made from, and the sign that zigbuildx does nothing there.
    pub const marker_name = ".zigbuildx-vendor";
    /// How many hex digits of the root's commit the tarball's name carries.
    pub const commit_digits = 12;
    /// The most of a failed build's output a message quotes.
    const quoted_output_bytes = 4096;
    /// The mode a directory or an executable gets in the tarball.
    const executable_mode = 0o755;
    /// The mode any other file gets in the tarball.
    const file_mode = 0o644;
    /// The mode a symbolic link gets in the tarball.
    const link_mode = 0o777;
    /// The owner-execute bit, which makes a file an executable.
    const owner_execute = 0o100;
    /// Allocates everything the run holds; an arena, freed all at once.
    allocator: std.mem.Allocator,
    /// IO for the filesystem and the children.
    io: std.Io,
    /// The consumer's absolute root.
    root: []const u8,
    /// The `zig` executable that hashes, fetches and builds.
    zig: []const u8,
    /// Where the tarball goes; emptied first.
    out_dir: []const u8,
    /// The environment the `zig` children run in.
    environ_map: *const std.process.Environ.Map,
    /// Exports and staging: `<root>/.zig-cache/zigbuildx-vendor`.
    work: []const u8,
    /// The global cache the proof builds with, its packages emptied first: `<work>/global-cache`.
    proof_cache: []const u8,
    /// The root's name for this zigbuildx, whose hash the marker records; null when the root does not list it.
    zigbuildx: ?[]const u8 = null,
    /// Whether the export is built with a global cache that holds no packages before it is written; tests that check something else turn it off.
    prove: bool = true,
    /// The tarball written, once `run` returns.
    tarball: []const u8 = "",
    /// What went wrong, when a function returns `error.DepsFailed`.
    problem: []const u8 = "",

    /// Creates a run for the consumer at `root`.
    ///
    /// - `allocator`: An arena for everything the run allocates.
    /// - `io`: IO for the filesystem and the children.
    /// - `root`: The consumer's absolute root.
    /// - `zig`: The `zig` executable.
    /// - `out_dir`: Where the tarball goes.
    /// - `environ_map`: The environment the `zig` children run in.
    /// - Returns: The run; allocation errors.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, root: []const u8, zig: []const u8, out_dir: []const u8, environ_map: *const std.process.Environ.Map) !Self {
        const work = try std.Io.Dir.path.join(allocator, &.{ root, ".zig-cache", "zigbuildx-vendor" });
        const proof_cache = try std.Io.Dir.path.join(allocator, &.{ work, "global-cache" });
        return .{ .allocator = allocator, .io = io, .root = root, .zig = zig, .out_dir = out_dir, .environ_map = environ_map, .work = work, .proof_cache = proof_cache };
    }

    /// `zigbuildx vendor <root> <zig> <out-dir> <zigbuildx-name>`: writes the consumer's vendored tarball into `out-dir`.
    /// Runs as the `vendor` step; `-` names no zigbuildx dependency.
    ///
    /// - `process_init`: The process's allocator, IO and environment.
    /// - `args`: The command line after the program's path; `args[0]` is the command.
    /// - Returns: `error.InvalidArguments` on a bad command line, `error.DepsFailed` when the consumer cannot be vendored, or IO, git and spawn errors.
    pub fn command(process_init: std.process.Init, args: []const [:0]const u8) !void {
        if (args.len != 5) {
            log.err("usage: zigbuildx vendor <root> <zig> <out-dir> <zigbuildx-name>", .{});
            return error.InvalidArguments;
        }
        const allocator = process_init.arena.allocator();
        const io = process_init.io;
        const root = try std.Io.Dir.cwd().realPathFileAlloc(io, args[1], allocator);
        var self = try Self.init(allocator, io, root, args[2], args[3], process_init.environ_map);
        if (!std.mem.eql(u8, args[4], "-")) self.zigbuildx = args[4];
        self.run() catch |err| {
            self.logFailure(err);
            return if (err == error.DepsFailed) err else error.DepsFailed;
        };
        log.info("wrote {s}; the vendor step installs it in vendor/ under the install prefix (zig-out by default)", .{std.Io.Dir.path.basename(self.tarball)});
    }

    /// Reports whether `root` is a vendored tree, where zigbuildx clones, updates and fetches nothing.
    ///
    /// - `allocator`: Allocator for the path.
    /// - `io`: IO for the filesystem.
    /// - `root`: The package's absolute root.
    /// - Returns: `true` when the marker is there; IO errors.
    pub fn isVendored(allocator: std.mem.Allocator, io: std.Io, root: []const u8) !bool {
        const marker = try std.Io.Dir.path.join(allocator, &.{ root, Self.marker_name });
        defer allocator.free(marker);
        return mod.File.exists(io, marker);
    }

    /// Writes the consumer's vendored tarball into `out_dir`, or refuses with every problem found.
    ///
    /// - `self`: The run.
    /// - Returns: `error.DepsFailed` with `problem` set, or IO, git and spawn errors.
    pub fn run(self: *Self) !void {
        // Two runs in one root would share the export, the staging area and the proof's cache.
        try std.Io.Dir.cwd().createDirPath(self.io, self.work);
        const lock = try std.Io.Dir.cwd().createFile(self.io, try std.Io.Dir.path.join(self.allocator, &.{ self.work, "vendor.lock" }), .{ .lock = .exclusive });
        defer lock.close(self.io);
        if (try Self.isVendored(self.allocator, self.io, self.root)) return self.fail("{s} is a vendored tree already", .{self.root});
        if (try mod.File.exists(self.io, try self.rootPath(mod.Stage.backup_name))) {
            return self.fail("build.zig.zon is rewritten for a distribution build ({s} holds the original); run zig build dev first", .{mod.Stage.backup_name});
        }
        if (!try mod.File.exists(self.io, try self.rootPath(".git"))) return self.fail("{s} is not a git checkout, so it has no commit to vendor", .{self.root});
        const source = try mod.File.readOptionalZ(self.allocator, self.io, try self.rootPath("build.zig.zon"), .limited(mod.Manifest.max_bytes)) orelse return self.fail("no build.zig.zon in {s}", .{self.root});
        const manifest = mod.Manifest.parse(self.allocator, source) catch return self.fail("cannot parse the build.zig.zon of {s}", .{self.root});
        const commit = try mod.Git.revParse(self.allocator, self.io, self.root, "HEAD") orelse return self.fail("{s} has no commits", .{self.root});
        const version = if (manifest.version.len > 0) manifest.version else "0.0.0";
        // They name a directory that is deleted and recreated: a `/` or `..` would point it elsewhere.
        if (!Self.isPlainName(manifest.name) or !Self.isPlainName(version)) return self.fail("cannot name a tarball from .name \"{s}\" and .version \"{s}\"", .{ manifest.name, version });
        const top = try self.allocator.print("{s}-{s}-{s}", .{ manifest.name, version, commit[0..Self.commit_digits] });
        const export_dir = try std.Io.Dir.path.join(self.allocator, &.{ self.work, top });

        var stage = try mod.Stage.init(self.allocator, self.io, self.root, self.zig);
        stage.target = export_dir;
        stage.local = true;
        stage.backup = false;
        stage.work = try std.Io.Dir.path.join(self.allocator, &.{ self.work, "stage" });
        stage.environ_map = self.environ_map;
        try std.Io.Dir.cwd().deleteTree(self.io, export_dir);
        try stage.exportCommit(self.root, commit, export_dir);
        stage.run() catch |err| {
            if (err == error.DepsFailed) return self.fail("{s}", .{stage.problem});
            return err;
        };

        try self.fetchAll(export_dir);
        try self.mark(export_dir, manifest, commit, &stage);
        if (self.prove) try self.proveBuild(export_dir);
        try self.writeTarball(export_dir, top, try mod.Git.commitTime(self.allocator, self.io, self.root));
        try std.Io.Dir.cwd().deleteTree(self.io, export_dir);
    }

    /// Logs why the run failed: the `problem` `fail` recorded, or else the error itself.
    ///
    /// - `self`: The run.
    /// - `err`: The error the run returned.
    fn logFailure(self: *const Self, err: anyerror) void {
        if (err == error.DepsFailed) {
            log.err("{s}", .{self.problem});
        } else {
            log.err("cannot vendor {s} [{any}]", .{ self.root, err });
        }
    }

    /// Fetches every `.url` dependency of the export, lazy ones included, into its `zig-pkg/`.
    ///
    /// - `self`: The run.
    /// - `export_dir`: The export.
    /// - Returns: `error.DepsFailed` when the fetch fails, or spawn errors.
    fn fetchAll(self: *Self, export_dir: []const u8) !void {
        // Fetches without running build(); a staged sibling's hash is found in `zig-pkg/` and never fetched.
        const output = try self.runZig(export_dir, &.{ "build", "--fetch=all" }, self.environ_map) orelse return;
        return self.fail("zig build --fetch=all failed in the export:\n{s}", .{output});
    }

    /// Writes the marker: the Zig release, this zigbuildx, the root's commit, and where each sibling came from.
    ///
    /// - `self`: The run.
    /// - `export_dir`: The export.
    /// - `manifest`: The root's manifest.
    /// - `commit`: The root's commit.
    /// - `stage`: The finished stage, whose siblings the marker lists.
    /// - Returns: IO errors.
    fn mark(self: *const Self, export_dir: []const u8, manifest: mod.Manifest, commit: []const u8, stage: *const mod.Stage) !void {
        var text: std.Io.Writer.Allocating = .init(self.allocator);
        const writer = &text.writer;
        try writer.print(".{{\n    .zig = \"{f}\",\n", .{std.zig.fmtString(builtin.zig_version_string)});
        if (self.zigbuildx) |name| for (manifest.entries) |entry| {
            if (!std.mem.eql(u8, entry.name, name)) continue;
            if (entry.hash) |hash| try writer.print("    .zigbuildx = \"{f}\",\n", .{std.zig.fmtString(hash)});
        };
        try writer.print("    .commit = \"{s}\",\n    .siblings = .{{\n", .{commit});
        for (stage.nodes.items) |node| try writer.print("        .{{ .path = \"{f}\", .url = \"{f}\" }},\n", .{ std.zig.fmtString(node.rel), std.zig.fmtString(node.url) });
        try writer.writeAll("    },\n}\n");
        const marker = try std.Io.Dir.path.join(self.allocator, &.{ export_dir, Self.marker_name });
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = marker, .data = text.written() });
    }

    /// Builds the export's default step with a global cache that holds no packages, so the tarball is known to need nothing outside it.
    ///
    /// - `self`: The run.
    /// - `export_dir`: The export, marked.
    /// - Returns: `error.DepsFailed` when the build fails or fetches a package, or IO and spawn errors.
    fn proveBuild(self: *Self, export_dir: []const u8) !void {
        const cwd = std.Io.Dir.cwd();
        // Kept between runs, since a new global cache costs Zig about 30 s to set up; its package store,
        // `p/`, is emptied, so a package missing from `zig-pkg/` would have to be fetched.
        const packages = try std.Io.Dir.path.join(self.allocator, &.{ self.proof_cache, "p" });
        try cwd.deleteTree(self.io, packages);
        try cwd.createDirPath(self.io, packages);
        var environ_map = try self.environ_map.clone(self.allocator);
        try environ_map.put("ZIG_GLOBAL_CACHE_DIR", self.proof_cache);
        log.info("building the export with no packages but its own", .{});
        if (try self.runZig(export_dir, &.{"build"}, &environ_map)) |output| {
            return self.fail("the export does not build on its own, so no tarball was written:\n{s}", .{output});
        }
        // A package that came from anywhere but `zig-pkg/` (a label cannot be fetched, but a real URL can).
        var store = try cwd.openDir(self.io, packages, .{ .iterate = true });
        defer store.close(self.io);
        var it = store.iterate();
        if (try it.next(self.io)) |entry| return self.fail("the export fetched {s} while it built, so no tarball was written; it is missing from zig-pkg/", .{entry.name});
        // The build's own outputs are not sources.
        inline for (.{ ".zig-cache", "zig-out" }) |name| {
            try cwd.deleteTree(self.io, try std.Io.Dir.path.join(self.allocator, &.{ export_dir, name }));
        }
    }

    /// Runs `zig args…` in `dir`.
    ///
    /// - `self`: The run.
    /// - `dir`: The working directory.
    /// - `args`: The arguments after `zig`.
    /// - `environ_map`: The child's environment.
    /// - Returns: Null on success, else the tail of its output; spawn errors.
    fn runZig(self: *const Self, dir: []const u8, args: []const []const u8, environ_map: *const std.process.Environ.Map) !?[]const u8 {
        const argv = try std.mem.concat(self.allocator, []const u8, &.{ &.{self.zig}, args });
        const result = try std.process.run(self.allocator, self.io, .{ .argv = argv, .cwd = .{ .path = dir }, .environ_map = environ_map });
        switch (result.term) {
            .exited => |code| if (code == 0) return null,
            else => {},
        }
        const output = std.mem.trim(u8, result.stderr, " \t\r\n");
        return output[output.len -| Self.quoted_output_bytes..];
    }

    /// Writes the export as `<out_dir>/<top>.tar.gz`: one top-level folder, entries sorted, every time `mtime`, owner 0.
    ///
    /// - `self`: The run.
    /// - `export_dir`: The export.
    /// - `top`: The top-level folder, and the file's name.
    /// - `mtime`: The time every entry carries: the root's commit time, so two runs write the same bytes.
    /// - Returns: IO errors.
    fn writeTarball(self: *Self, export_dir: []const u8, top: []const u8, mtime: u64) !void {
        const cwd = std.Io.Dir.cwd();
        var dir = try cwd.openDir(self.io, export_dir, .{ .iterate = true });
        defer dir.close(self.io);
        const entries = try self.listTree(dir);

        try cwd.deleteTree(self.io, self.out_dir);
        try cwd.createDirPath(self.io, self.out_dir);
        self.tarball = try std.Io.Dir.path.join(self.allocator, &.{ self.out_dir, try self.allocator.print("{s}.tar.gz", .{top}) });
        const partial = try self.allocator.print("{s}.partial", .{self.tarball});
        {
            var file = try cwd.createFile(self.io, partial, .{});
            defer file.close(self.io);
            var file_buffer: [64 * 1024]u8 = undefined;
            var file_writer = file.writer(self.io, &file_buffer);
            const window = try self.allocator.alloc(u8, std.compress.flate.max_window_len);
            // Large: its match tables do not belong on the stack.
            const compress = try self.allocator.create(std.compress.flate.Compress);
            compress.* = try .init(&file_writer.interface, window, .gzip, .default);
            var tar: std.tar.Writer = .{ .underlying_writer = &compress.writer };
            try tar.writeDir(top, .{ .mode = Self.executable_mode, .mtime = mtime });
            tar.prefix = top;
            var read_buffer: [64 * 1024]u8 = undefined;
            var link_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            for (entries) |entry| switch (entry.kind) {
                .directory => try tar.writeDir(entry.name, .{ .mode = Self.executable_mode, .mtime = mtime }),
                .sym_link => {
                    const len = try dir.readLink(self.io, entry.path, &link_buffer);
                    try tar.writeLink(entry.name, link_buffer[0..len], .{ .mode = Self.link_mode, .mtime = mtime });
                },
                // `listTree` lets nothing else through.
                else => {
                    var member = try dir.openFile(self.io, entry.path, .{});
                    defer member.close(self.io);
                    const stat = try member.stat(self.io);
                    var reader = member.reader(self.io, &read_buffer);
                    try tar.writeFileStream(entry.name, stat.size, &reader.interface, .{ .mode = if (Self.isExecutable(stat)) Self.executable_mode else Self.file_mode, .mtime = mtime });
                },
            };
            try compress.finish();
            try file_writer.interface.flush();
        }
        try cwd.rename(partial, cwd, self.tarball, self.io);
    }

    /// Lists every entry below `dir`, sorted, without `.git`.
    ///
    /// - `self`: The run.
    /// - `dir`: The directory, opened for iteration.
    /// - Returns: The entries; `error.DepsFailed` for an entry that is not a file, a directory or a link, or IO errors.
    fn listTree(self: *Self, dir: std.Io.Dir) ![]const TreeEntry {
        var entries: std.ArrayList(TreeEntry) = .empty;
        var walker = try dir.walkSelectively(self.allocator);
        defer walker.deinit();
        while (try walker.next(self.io)) |entry| {
            if (std.mem.eql(u8, entry.basename, ".git")) continue;
            switch (entry.kind) {
                .file, .directory, .sym_link => {},
                // A FIFO would block the read forever; a device or socket has no contents to ship.
                else => return self.fail("{s} in the export is a {t}; a tarball holds only files, directories and links", .{ entry.path, entry.kind }),
            }
            const path = try self.allocator.dupe(u8, entry.path);
            // A tar names entries with `/`, whatever the host's separator.
            const name = try std.mem.replaceOwned(u8, self.allocator, path, "\\", "/");
            try entries.append(self.allocator, .{ .path = path, .name = name, .kind = entry.kind });
            if (entry.kind == .directory) try walker.enter(self.io, entry);
        }
        std.mem.sort(TreeEntry, entries.items, {}, TreeEntry.lessThan);
        return entries.items;
    }

    /// Reports whether `text` can name a path component: letters, digits, `.`, `_`, `+` and `-`, not starting with `.`.
    ///
    /// - `text`: A manifest's `.name` or `.version`.
    /// - Returns: `true` when it is safe in a file name.
    fn isPlainName(text: []const u8) bool {
        if (text.len == 0 or text[0] == '.') return false;
        for (text) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.findScalar(u8, "._+-", c) == null) return false;
        return true;
    }

    /// Reports whether a file's owner may execute it; never on a host without executable bits.
    ///
    /// - `stat`: The file's metadata.
    /// - Returns: `true` for an executable.
    fn isExecutable(stat: std.Io.File.Stat) bool {
        if (comptime !std.Io.File.Permissions.has_executable_bit) return false;
        return stat.permissions.toMode() & Self.owner_execute != 0;
    }

    /// Joins `name` onto the root.
    ///
    /// - `self`: The run.
    /// - `name`: A path inside the root.
    /// - Returns: The absolute path; allocation errors.
    fn rootPath(self: *const Self, name: []const u8) ![]const u8 {
        return std.Io.Dir.path.join(self.allocator, &.{ self.root, name });
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

/// Makes `tree`'s consumer a committed Zig package and git checkout declaring `dependencies`, with siblings cloned beside it.
///
/// - `tree`: The fixture.
/// - `dependencies`: The body of its `.dependencies`.
/// - `build_zig`: Its `build.zig`.
/// - `siblings`: The upstreams to clone at `<tmp>/<name>`.
/// - Returns: IO and spawn errors.
fn testConsumer(tree: *mod.TestTree, dependencies: []const u8, build_zig: []const u8, siblings: []const []const u8) !void {
    for (siblings) |name| try tree.run(&.{ "git", "clone", "--quiet", try tree.path(try tree.allocator().print("origin/{s}", .{name})), try tree.path(name) });
    const dir = try tree.path("consumer");
    try tree.run(&.{ "git", "init", "--quiet", "--initial-branch=main", dir });
    // A whole manifest, as `zig build` needs: the fingerprint's checksum is the name's.
    const fingerprint = (@as(u64, std.hash.Crc32.hash("consumer")) << 32) | 1;
    try tree.write("consumer/build.zig.zon", try tree.allocator().print(".{{ .name = .consumer, .version = \"1.2.3\", .fingerprint = 0x{x}, .dependencies = .{{ {s} }}, .paths = .{{\"\"}} }}\n", .{ fingerprint, dependencies }));
    try tree.write("consumer/build.zig", build_zig);
    try tree.write("consumer/.gitignore", "deps/\n.zig-cache/\n");
    try tree.commit(dir, "one");
}

/// Creates a vendor run of `tree`'s consumer into `<tmp>/out`, its `zig` children on scratch caches, or skips without the `zig` executable.
///
/// - `tree`: The fixture.
/// - Returns: The run, not started, its proof off; `error.SkipZigTest` when the build did not pass `ZIGBUILDX_ZIG`.
fn testVendor(tree: *mod.TestTree) !Vendor {
    var run = try Vendor.init(tree.allocator(), tree.io, try tree.path("consumer"), try tree.zig(), try tree.path("out"), try tree.zigEnviron());
    // The same one: tests run one at a time, and the proof only empties its packages, which the next fetch puts back.
    run.proof_cache = try tree.globalCache();
    run.prove = false;
    return run;
}

/// Runs a vendor run that must fail, and returns its problem.
///
/// - `run`: The run.
/// - Returns: The message; `error.TestUnexpectedResult` when it succeeds.
fn vendorFails(run: *Vendor) ![]const u8 {
    run.run() catch |err| {
        try std.testing.expectEqual(error.DepsFailed, err);
        return run.problem;
    };
    return error.TestUnexpectedResult;
}

/// Unpacks the tarball at `tarball` into `<tmp>/<sub>`.
///
/// - `tree`: The fixture.
/// - `tarball`: The `.tar.gz`.
/// - `sub`: The directory, relative to the scratch root.
/// - Returns: IO, gzip and tar errors.
fn extract(tree: *mod.TestTree, tarball: []const u8, sub: []const u8) !void {
    try tree.tmp.dir.createDirPath(tree.io, sub);
    var out = try tree.tmp.dir.openDir(tree.io, sub, .{});
    defer out.close(tree.io);
    var file = try std.Io.Dir.cwd().openFile(tree.io, tarball, .{});
    defer file.close(tree.io);
    var file_buffer: [16 * 1024]u8 = undefined;
    var reader = file.reader(tree.io, &file_buffer);
    const window = try tree.allocator().alloc(u8, std.compress.flate.max_window_len);
    var decompress: std.compress.flate.Decompress = .init(&reader.interface, .gzip, window);
    try std.tar.extract(tree.io, out, &decompress.reader, .{});
}

test "vendor writes the root, its inside checkouts and its siblings at their HEADs, the same bytes every run" {
    var tree = try mod.TestTree.init();
    defer tree.deinit();
    try tree.upstream("leaf", "");
    try tree.upstream("mid", ".leaf = .{ .path = \"../leaf\" },");
    try tree.upstream("inner", "");
    try testConsumer(&tree, try std.mem.concat(tree.allocator(), u8, &.{ try tree.siblingWith("mid", ".branch = \"main\","), ".inner = .{ .path = \"deps/inner\" }," }), "pub fn build(_: *@import(\"std\").Build) void {}\n", &.{ "mid", "leaf" });
    try tree.run(&.{ "git", "clone", "--quiet", try tree.path("origin/inner"), try tree.path("consumer/deps/inner") });
    // A commit of `leaf`'s own, on no remote: what was built is what ships.
    try tree.commit(try tree.path("leaf"), "two");
    // Untracked files are no change, and no commit holds them.
    try tree.write("consumer/untracked", "x");
    try tree.write("mid/untracked", "x");

    var run = try testVendor(&tree);
    try run.run();
    const head = try tree.rev("consumer", "HEAD");
    const top = try tree.allocator().print("consumer-1.2.3-{s}", .{head[0..Vendor.commit_digits]});
    try std.testing.expectEqualStrings(try tree.allocator().print("{s}.tar.gz", .{top}), std.Io.Dir.path.basename(run.tarball));
    const bytes = try std.Io.Dir.cwd().readFileAlloc(tree.io, run.tarball, tree.allocator(), .unlimited);

    try extract(&tree, run.tarball, "unpacked");
    const unpacked = try tree.allocator().print("unpacked/{s}", .{top});
    try std.testing.expect(try Vendor.isVendored(tree.allocator(), tree.io, try tree.path(unpacked)));
    const marker = try tree.read(try tree.allocator().print("{s}/{s}", .{ unpacked, Vendor.marker_name }));
    try std.testing.expect(std.mem.find(u8, marker, head) != null);
    try std.testing.expect(std.mem.find(u8, marker, try tree.rev("leaf", "HEAD")) != null);
    // The root names its siblings by hash; its inside checkout is there at its path, without `.git`.
    const manifest = try tree.read(try tree.allocator().print("{s}/build.zig.zon", .{unpacked}));
    try std.testing.expect(std.mem.find(u8, manifest, "../mid") == null);
    try std.testing.expect(std.mem.find(u8, manifest, "deps/inner") != null);
    _ = try tree.read(try tree.allocator().print("{s}/deps/inner/build.zig.zon", .{unpacked}));
    try std.testing.expectError(error.FileNotFound, tree.tmp.dir.access(tree.io, try tree.allocator().print("{s}/deps/inner/.git", .{unpacked}), .{}));
    try std.testing.expectError(error.FileNotFound, tree.tmp.dir.access(tree.io, try tree.allocator().print("{s}/untracked", .{unpacked}), .{}));
    // `leaf`'s unpushed commit is in its package; `mid`'s untracked file is not in its own.
    var leaf_found = false;
    var packages = try tree.tmp.dir.openDir(tree.io, try tree.allocator().print("{s}/zig-pkg", .{unpacked}), .{ .iterate = true });
    defer packages.close(tree.io);
    var it = packages.iterate();
    while (try it.next(tree.io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, "leaf-")) {
            leaf_found = true;
            try packages.access(tree.io, try tree.allocator().print("{s}/two", .{entry.name}), .{});
        }
        if (std.mem.startsWith(u8, entry.name, "mid-")) try std.testing.expectError(error.FileNotFound, packages.access(tree.io, try tree.allocator().print("{s}/untracked", .{entry.name}), .{}));
    }
    try std.testing.expect(leaf_found);

    // A second run writes the same bytes; a vendored tree is refused.
    var again = try testVendor(&tree);
    try again.run();
    try std.testing.expectEqualSlices(u8, bytes, try std.Io.Dir.cwd().readFileAlloc(tree.io, again.tarball, tree.allocator(), .unlimited));
    var nested = try testVendor(&tree);
    nested.root = try tree.path(unpacked);
    try std.testing.expect(std.mem.find(u8, try vendorFails(&nested), "vendored tree already") != null);
}

test "vendor refuses tracked changes and siblings off their refs, listing them all, and writes nothing" {
    var tree = try mod.TestTree.init();
    defer tree.deinit();
    try tree.upstream("onbranch", "");
    try tree.upstream("ontag", "");
    try testConsumer(&tree, try std.mem.concat(tree.allocator(), u8, &.{ try tree.siblingWith("onbranch", ".branch = \"main\","), try tree.siblingWith("ontag", ".tag = \"v1\",") }), "", &.{ "onbranch", "ontag" });
    try tree.write("consumer/build.zig", "// changed\n");
    try tree.run(&.{ "git", "-C", try tree.path("onbranch"), "checkout", "--quiet", "-b", "other" });
    try tree.commit(try tree.path("ontag"), "two");
    try tree.write("ontag/one", "changed");

    var run = try testVendor(&tree);
    const problem = try vendorFails(&run);
    try std.testing.expect(std.mem.find(u8, problem, "consumer has uncommitted changes") != null);
    try std.testing.expect(std.mem.find(u8, problem, "onbranch is on other, but consumer declares .branch = \"main\"") != null);
    try std.testing.expect(std.mem.find(u8, problem, "ontag has uncommitted changes") != null);
    try std.testing.expect(std.mem.find(u8, problem, "ontag is not at tag v1") != null);
    try std.testing.expectError(error.FileNotFound, tree.tmp.dir.access(tree.io, "out", .{}));

    // Detached at the branch's tip is still off the branch.
    try tree.run(&.{ "git", "-C", try tree.path("consumer"), "checkout", "--quiet", "--", "build.zig" });
    try tree.run(&.{ "git", "-C", try tree.path("onbranch"), "checkout", "--quiet", "--detach", "main" });
    try tree.run(&.{ "git", "-C", try tree.path("ontag"), "checkout", "--quiet", "--", "one" });
    try tree.run(&.{ "git", "-C", try tree.path("ontag"), "checkout", "--quiet", "--detach", "v1" });
    var detached = try testVendor(&tree);
    const only = try vendorFails(&detached);
    try std.testing.expect(std.mem.find(u8, only, "onbranch is detached") != null);
    try std.testing.expect(std.mem.find(u8, only, "ontag") == null);

    // A manifest a distribution build rewrote is refused before anything else.
    try tree.write(try tree.allocator().print("consumer/{s}", .{mod.Stage.backup_name}), "");
    var rewritten = try testVendor(&tree);
    try std.testing.expect(std.mem.find(u8, try vendorFails(&rewritten), "zig build dev") != null);
}

test "vendor proves the export builds with no packages but its own, and writes nothing when it does not" {
    var tree = try mod.TestTree.init();
    defer tree.deinit();
    try tree.upstream("lib", "");
    // Zig resolves every eager dependency before build() runs, so `lib` must be in `zig-pkg/` whether or not build() asks for it.
    try testConsumer(&tree, try tree.sibling("lib"), "pub fn build(_: *@import(\"std\").Build) void {}\n", &.{"lib"});
    try tree.write("consumer/build.zig", "pub fn build(b: *@import(\"std\").Build) void { _ = b.dependency(\"missing\", .{}); }\n");
    try tree.commit(try tree.path("consumer"), "broken");
    var broken = try testVendor(&tree);
    broken.prove = true;
    try std.testing.expect(std.mem.find(u8, try vendorFails(&broken), "does not build on its own") != null);
    try std.testing.expectError(error.FileNotFound, tree.tmp.dir.access(tree.io, "out", .{}));

    try tree.write("consumer/build.zig", "pub fn build(_: *@import(\"std\").Build) void {}\n");
    try tree.commit(try tree.path("consumer"), "fixed");
    var run = try testVendor(&tree);
    run.prove = true;
    try run.run();
    try std.Io.Dir.cwd().access(tree.io, run.tarball, .{});
}

/// The most `zig build` runs the end-to-end test allows a consumer to settle in: one per clone and one to build.
const app_build_runs = 4;

/// What a child process did: whether it exited 0, and its output.
const Outcome = struct {
    const Self = @This();
    /// Whether it exited 0.
    ok: bool,
    /// Its stderr, then its stdout.
    output: []const u8,
};

/// Runs `argv` in `<tmp>/<sub>` with `environ_map`.
///
/// - `tree`: The fixture.
/// - `sub`: The working directory, relative to the scratch root.
/// - `argv`: The command.
/// - `environ_map`: The child's environment.
/// - Returns: What it did; spawn errors.
fn runIn(tree: *mod.TestTree, sub: []const u8, argv: []const []const u8, environ_map: *const std.process.Environ.Map) !Outcome {
    const result = try std.process.run(tree.allocator(), tree.io, .{ .argv = argv, .cwd = .{ .path = try tree.path(sub) }, .environ_map = environ_map });
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    return .{ .ok = ok, .output = try std.mem.concat(tree.allocator(), u8, &.{ result.stderr, result.stdout }) };
}

/// Writes Zig package `name` at `<tmp>/<sub>`, a git checkout on `main` with nothing committed yet.
///
/// - `tree`: The fixture.
/// - `sub`: Where it goes, relative to the scratch root.
/// - `name`: The package's name.
/// - `dependencies`: The body of its `.dependencies`.
/// - `build_zig`: Its `build.zig`.
/// - `source`: Its `<name>.zig`.
/// - Returns: IO and spawn errors.
fn endToEndPackage(tree: *mod.TestTree, sub: []const u8, name: []const u8, dependencies: []const u8, build_zig: []const u8, source: []const u8) !void {
    const allocator = tree.allocator();
    try tree.run(&.{ "git", "init", "--quiet", "--initial-branch=main", try tree.path(sub) });
    // The fingerprint's checksum is the name's, as `zig build` checks it.
    const fingerprint = (@as(u64, std.hash.Crc32.hash(name)) << 32) | 1;
    try tree.write(try allocator.print("{s}/build.zig.zon", .{sub}), try allocator.print(".{{ .name = .{s}, .version = \"0.1.0\", .fingerprint = 0x{x}, .minimum_zig_version = \"0.17.0\", .dependencies = .{{ {s} }}, .paths = .{{\"\"}} }}\n", .{ name, fingerprint, dependencies }));
    try tree.write(try allocator.print("{s}/build.zig", .{sub}), build_zig);
    try tree.write(try allocator.print("{s}/{s}.zig", .{ sub, name }), source);
    try tree.write(try allocator.print("{s}/.gitignore", .{sub}), ".zig-cache/\nzig-out/\nzig-pkg/\n");
}

/// Runs `zig build <args>` in `<tmp>/app` until it stops asking for a re-run, as `cloneMissing` does after cloning.
///
/// - `tree`: The fixture.
/// - `zig`: The `zig` executable.
/// - `environ_map`: The child's environment.
/// - Returns: The last run's outcome; spawn errors.
fn buildApp(tree: *mod.TestTree, zig: []const u8, environ_map: *const std.process.Environ.Map) !Outcome {
    var outcome = try runIn(tree, "app", &.{ zig, "build" }, environ_map);
    var runs: usize = 1;
    while (!outcome.ok and runs < app_build_runs and std.mem.find(u8, outcome.output, "re-run zig build") != null) : (runs += 1) {
        outcome = try runIn(tree, "app", &.{ zig, "build" }, environ_map);
    }
    return outcome;
}

/// Expects `zig build vendor` in `<tmp>/app` to fail with a message containing `message`.
///
/// - `tree`: The fixture.
/// - `zig`: The `zig` executable.
/// - `environ_map`: The child's environment.
/// - `message`: Part of the refusal.
/// - Returns: `error.TestUnexpectedResult` when it succeeds or says something else; spawn errors.
fn expectVendorRefused(tree: *mod.TestTree, zig: []const u8, environ_map: *const std.process.Environ.Map, message: []const u8) !void {
    const outcome = try runIn(tree, "app", &.{ zig, "build", "vendor" }, environ_map);
    try std.testing.expect(!outcome.ok);
    if (std.mem.find(u8, outcome.output, message) == null) {
        std.debug.print("expected \"{s}\" in:\n{s}\n", .{ message, outcome.output });
        return error.TestUnexpectedResult;
    }
}

// `make vendor` runs this one. It builds and vendors a whole consumer through
// real `zig build` runs, which takes a minute or more, so it skips unless
// `-Dvendor-check` sets ZIGBUILDX_VENDOR_CHECK to 1.
test "vendor end to end: a consumer's tarball builds with every remote gone and no packages but its own" {
    var tree = try mod.TestTree.init();
    defer tree.deinit();
    const allocator = tree.allocator();
    const enabled = std.testing.environ.getAlloc(allocator, "ZIGBUILDX_VENDOR_CHECK") catch return error.SkipZigTest;
    if (!std.mem.eql(u8, enabled, "1")) return error.SkipZigTest;
    const zig = try tree.zig();
    const global_cache = try tree.globalCache();
    const environ_map = try tree.zigEnviron();
    const exe = if (builtin.os.tag == .windows) "app.exe" else "app";

    // `../a` (`.branch = "main"`) depends on `../b`; everything comes from `origin/`, which goes away later.
    try endToEndPackage(&tree, "origin/b", "b", "", "pub fn build(b: *@import(\"std\").Build) void {\n    _ = b.addModule(\"b\", .{ .root_source_file = b.path(\"b.zig\") });\n}\n", "pub const value = 2;\n");
    try tree.commit(try tree.path("origin/b"), "one");
    try endToEndPackage(&tree, "origin/a", "a", try allocator.print(".b = .{{ .path = \"../b\", .clone = \"{s}\" }},", .{try tree.path("origin/b")}),
        \\pub fn build(b: *@import("std").Build) void {
        \\    const module = b.addModule("a", .{ .root_source_file = b.path("a.zig") });
        \\    module.addImport("b", b.dependency("b", .{}).module("b"));
        \\}
        \\
    , "pub const value = @import(\"b\").value + 1;\n");
    try tree.commit(try tree.path("origin/a"), "one");
    // A lazy `.url` dependency, fetched from a local directory.
    try endToEndPackage(&tree, "origin/lazy", "lazy", "", "pub fn build(b: *@import(\"std\").Build) void {\n    _ = b.addModule(\"lazy\", .{ .root_source_file = b.path(\"lazy.zig\") });\n}\n", "pub const value = 7;\n");
    // This zigbuildx, from a copy of its `.paths`, as the working tree has it.
    const zigbuildx = try tree.path("origin/zigbuildx");
    try std.Io.Dir.cwd().createDirPath(tree.io, zigbuildx);
    inline for (.{ "build.zig", "build.zig.zon" }) |name| try std.Io.Dir.cwd().copyFile(name, std.Io.Dir.cwd(), try std.Io.Dir.path.join(allocator, &.{ zigbuildx, name }), tree.io, .{});
    try mod.File.copyTree(allocator, tree.io, "src", try std.Io.Dir.path.join(allocator, &.{ zigbuildx, "src" }), &.{});

    try endToEndPackage(&tree, "origin/app", "app", try allocator.print(".a = .{{ .path = \"../a\", .clone = \"{s}\", .branch = \"main\" }},", .{try tree.path("origin/a")}),
        \\const std = @import("std");
        \\const zigbuildx = @import("zigbuildx");
        \\
        \\pub fn build(b: *std.Build) void {
        \\    zigbuildx.Deps.cloneMissing(b, @import("build.zig.zon"));
        \\    const exe = b.addExecutable(.{ .name = "app", .root_module = b.createModule(.{ .root_source_file = b.path("app.zig"), .target = b.graph.host }) });
        \\    exe.root_module.addImport("a", b.dependency("a", .{}).module("a"));
        \\    if (b.lazyDependency("lazy", .{})) |lazy| exe.root_module.addImport("lazy", lazy.module("lazy"));
        \\    b.installArtifact(exe);
        \\}
        \\
    ,
        \\pub fn main() void {
        \\    @import("std").debug.print("a={d} lazy={d}\n", .{ @import("a").value, @import("lazy").value });
        \\}
        \\
    );
    try std.testing.expect((try runIn(&tree, "origin/app", &.{ zig, "fetch", "--save=zigbuildx", zigbuildx }, environ_map)).ok);
    try std.testing.expect((try runIn(&tree, "origin/app", &.{ zig, "fetch", "--save=lazy", try tree.path("origin/lazy") }, environ_map)).ok);
    const manifest = try tree.read("origin/app/build.zig.zon");
    try tree.write("origin/app/build.zig.zon", try std.mem.replaceOwned(u8, allocator, manifest, ".lazy = .{", ".lazy = .{ .lazy = true,"));
    try tree.commit(try tree.path("origin/app"), "one");
    // A clone, so its HEAD is on `origin/main`.
    try tree.run(&.{ "git", "clone", "--quiet", try tree.path("origin/app"), try tree.path("app") });

    // Develop mode clones `../a` and `../b` beside `app`.
    const develop = try buildApp(&tree, zig, environ_map);
    if (!develop.ok) std.debug.print("{s}\n", .{develop.output});
    try std.testing.expect(develop.ok);
    try tree.tmp.dir.access(tree.io, "a/.git", .{});
    try tree.tmp.dir.access(tree.io, "b/.git", .{});
    const built = try runIn(&tree, "app", &.{try tree.path(try allocator.print("app/zig-out/bin/{s}", .{exe}))}, environ_map);
    try std.testing.expect(std.mem.find(u8, built.output, "a=3 lazy=7") != null);

    // A commit of `../b`'s own, on no remote: what was built is what ships.
    try tree.write("b/b.zig", "pub const value = 5;\n");
    try tree.run(&.{ "git", "-C", try tree.path("b"), "-c", "user.name=t", "-c", "user.email=t@t", "commit", "--quiet", "-am", "unpushed" });

    // Refusals, through the `vendor` step itself.
    const a_dir = try tree.path("a");
    try tree.write("a/a.zig", "// changed\n");
    try expectVendorRefused(&tree, zig, environ_map, "../a has uncommitted changes to tracked files");
    try tree.run(&.{ "git", "-C", a_dir, "checkout", "--quiet", "--", "a.zig" });
    try tree.run(&.{ "git", "-C", a_dir, "checkout", "--quiet", "-b", "other" });
    try expectVendorRefused(&tree, zig, environ_map, "../a is on other, but app declares .branch = \"main\"");
    try tree.run(&.{ "git", "-C", a_dir, "checkout", "--quiet", "--detach", "main" });
    try expectVendorRefused(&tree, zig, environ_map, "../a is detached");
    try tree.run(&.{ "git", "-C", a_dir, "checkout", "--quiet", "main" });
    try tree.write("a/untracked-file", "not committed");

    const vendored = try runIn(&tree, "app", &.{ zig, "build", "vendor" }, environ_map);
    if (!vendored.ok) std.debug.print("{s}\n", .{vendored.output});
    try std.testing.expect(vendored.ok);
    try std.testing.expect(std.mem.find(u8, vendored.output, "../b is at") != null);
    try std.testing.expect(std.mem.find(u8, vendored.output, "app is at") == null);
    const top = try allocator.print("app-0.1.0-{s}", .{(try tree.rev("app", "HEAD"))[0..Vendor.commit_digits]});
    const tarball = try tree.path(try allocator.print("app/zig-out/vendor/{s}.tar.gz", .{top}));

    // Every remote, the lazy package and this zigbuildx's copy go away.
    try std.Io.Dir.cwd().rename(try tree.path("origin"), std.Io.Dir.cwd(), try tree.path("gone"), tree.io);
    try extract(&tree, tarball, "unpacked");
    const unpacked = try allocator.print("unpacked/{s}", .{top});
    var dir = try tree.tmp.dir.openDir(tree.io, unpacked, .{ .iterate = true });
    defer dir.close(tree.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(tree.io)) |entry| {
        try std.testing.expect(!std.mem.eql(u8, entry.basename, ".git"));
        try std.testing.expect(!std.mem.eql(u8, entry.basename, "untracked-file"));
    }

    // Built with no packages but its own: `p/` is emptied first and must stay empty.
    const packages = try std.Io.Dir.path.join(allocator, &.{ global_cache, "p" });
    try std.Io.Dir.cwd().deleteTree(tree.io, packages);
    const offline = try runIn(&tree, unpacked, &.{ zig, "build" }, environ_map);
    if (!offline.ok) std.debug.print("{s}\n", .{offline.output});
    try std.testing.expect(offline.ok);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(tree.io, packages, .{}));
    const shipped = try runIn(&tree, unpacked, &.{try tree.path(try allocator.print("{s}/zig-out/bin/{s}", .{ unpacked, exe }))}, environ_map);
    try std.testing.expect(std.mem.find(u8, shipped.output, "a=6 lazy=7") != null);

    // zigbuildx does nothing in a vendored tree.
    for ([_][]const u8{ "-Ddist", "zigbuildx-pin", "vendor" }) |refused| {
        const outcome = try runIn(&tree, unpacked, &.{ zig, "build", refused }, environ_map);
        try std.testing.expect(!outcome.ok);
        try std.testing.expect(std.mem.find(u8, outcome.output, "vendored tree") != null);
    }
}
