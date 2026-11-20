const std = @import("std");

/// File-system primitives the extensions share.
///
/// One function per operation, each knowing nothing about manifests, stamps
/// or archives, as `Git` is for git: the caller keeps the policy. Paths are
/// absolute, or relative to the working directory.
pub const File = struct {
    const Self = @This();

    /// Reports whether `path` exists.
    ///
    /// - `io`: IO for the filesystem.
    /// - `path`: The file or directory.
    /// - Returns: `true` when it exists; IO errors other than "not found".
    pub fn exists(io: std.Io, path: []const u8) !bool {
        std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }

    /// Reads the file at `path`, or reports that there is none.
    ///
    /// - `allocator`: Allocator for the contents.
    /// - `io`: IO for the filesystem.
    /// - `path`: The file.
    /// - `limit`: The most it may hold.
    /// - Returns: The contents, owned by the caller, or `null` when missing; `error.StreamTooLong` past `limit`.
    pub fn readOptional(allocator: std.mem.Allocator, io: std.Io, path: []const u8, limit: std.Io.Limit) !?[]u8 {
        return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, limit) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
    }

    /// Reads the file at `path` with a terminating 0, or reports that there is none.
    ///
    /// - `allocator`: Allocator for the contents.
    /// - `io`: IO for the filesystem.
    /// - `path`: The file.
    /// - `limit`: The most it may hold.
    /// - Returns: The 0-terminated contents, owned by the caller, or `null` when missing; `error.StreamTooLong` past `limit`.
    pub fn readOptionalZ(allocator: std.mem.Allocator, io: std.Io, path: []const u8, limit: std.Io.Limit) !?[:0]u8 {
        return std.Io.Dir.cwd().readFileAllocOptions(io, path, allocator, limit, .of(u8), 0) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
    }

    /// Creates the directory `path` goes in, and any missing above it.
    ///
    /// - `io`: IO for the filesystem.
    /// - `path`: A file or directory; a bare name has no parent to create.
    /// - Returns: IO errors.
    pub fn createParentDir(io: std.Io, path: []const u8) !void {
        try std.Io.Dir.cwd().createDirPath(io, std.Io.Dir.path.dirname(path) orelse return);
    }

    /// Copies the tree at `src` to `dest`, files with their permissions and links as links, leaving out every entry named in `skip`.
    ///
    /// - `allocator`: Allocator for the walk, freed before return.
    /// - `io`: IO for the filesystem.
    /// - `src`: The directory to copy.
    /// - `dest`: Where the copy goes; created, and merged into when it exists.
    /// - `skip`: Names left out at any depth, with everything below them, such as `.git`.
    /// - Returns: IO errors.
    pub fn copyTree(allocator: std.mem.Allocator, io: std.Io, src: []const u8, dest: []const u8, skip: []const []const u8) !void {
        const cwd = std.Io.Dir.cwd();
        var from = try cwd.openDir(io, src, .{ .iterate = true });
        defer from.close(io);
        try cwd.createDirPath(io, dest);
        var to = try cwd.openDir(io, dest, .{});
        defer to.close(io);
        var walker = try from.walkSelectively(allocator);
        defer walker.deinit();
        var link: [std.Io.Dir.max_path_bytes]u8 = undefined;
        while (try walker.next(io)) |entry| {
            if (Self.isSkipped(entry.basename, skip)) continue;
            switch (entry.kind) {
                .directory => {
                    try to.createDirPath(io, entry.path);
                    try walker.enter(io, entry);
                },
                .sym_link => {
                    const len = try entry.dir.readLink(io, entry.basename, &link);
                    to.deleteFile(io, entry.path) catch |err| switch (err) {
                        error.FileNotFound => {},
                        else => return err,
                    };
                    try to.symLink(io, link[0..len], entry.path, .{});
                },
                else => try entry.dir.copyFile(entry.basename, to, entry.path, io, .{}),
            }
        }
    }

    /// Reports whether `name` is one of `skip`.
    ///
    /// - `name`: An entry's name.
    /// - `skip`: The names to leave out.
    /// - Returns: `true` when listed.
    fn isSkipped(name: []const u8, skip: []const []const u8) bool {
        for (skip) |item| if (std.mem.eql(u8, name, item)) return true;
        return false;
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test "exists and readOptional treat a missing file as an answer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    const path = try std.Io.Dir.path.join(allocator, &.{ root, "a.txt" });

    try std.testing.expect(!try File.exists(io, path));
    try std.testing.expectEqual(null, try File.readOptional(allocator, io, path, .limited(64)));
    try std.testing.expectEqual(null, try File.readOptionalZ(allocator, io, path, .limited(64)));

    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hello" });
    try std.testing.expect(try File.exists(io, path));
    try std.testing.expectEqualStrings("hello", (try File.readOptional(allocator, io, path, .limited(64))).?);
    const terminated = (try File.readOptionalZ(allocator, io, path, .limited(64))).?;
    try std.testing.expectEqualStrings("hello", terminated);
    try std.testing.expectEqual(0, terminated[terminated.len]);
    try std.testing.expectError(error.StreamTooLong, File.readOptional(allocator, io, path, .limited(2)));
}

test "createParentDir creates every missing directory above a path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    const path = try std.Io.Dir.path.join(allocator, &.{ root, "x", "y", "z.txt" });

    try File.createParentDir(io, path);
    try File.createParentDir(io, path);
    try tmp.dir.access(io, "x/y", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "x/y/z.txt", .{}));
}

test "copyTree copies files and links, leaving out skipped names at any depth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    try tmp.dir.createDirPath(io, "src/a/.git");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/top.txt", .data = "top" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/a/b.txt", .data = "b" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/a/.git/HEAD", .data = "ref" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/.git", .data = "gitdir: elsewhere" });
    const links = std.Io.Dir.path.sep != '\\';
    if (links) try tmp.dir.symLink(io, "b.txt", "src/a/link", .{});

    const dest = try std.Io.Dir.path.join(allocator, &.{ root, "dest" });
    try File.copyTree(allocator, io, try std.Io.Dir.path.join(allocator, &.{ root, "src" }), dest, &.{".git"});
    try std.testing.expectEqualStrings("b", try tmp.dir.readFileAlloc(io, "dest/a/b.txt", allocator, .limited(8)));
    try std.testing.expectEqualStrings("top", try tmp.dir.readFileAlloc(io, "dest/top.txt", allocator, .limited(8)));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "dest/.git", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "dest/a/.git", .{}));
    if (links) {
        var buffer: [64]u8 = undefined;
        try std.testing.expectEqualStrings("b.txt", buffer[0..try tmp.dir.readLink(io, "dest/a/link", &buffer)]);
    }
    // A second copy merges into the first.
    try File.copyTree(allocator, io, try std.Io.Dir.path.join(allocator, &.{ root, "src" }), dest, &.{".git"});
}
