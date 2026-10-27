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
    /// Parameters:
    /// - `io`: IO for the filesystem.
    /// - `path`: the file or directory.
    ///
    /// Return: `true` when it exists; IO errors other than "not found".
    pub fn exists(io: std.Io, path: []const u8) !bool {
        std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }

    /// Reads the file at `path`, or reports that there is none.
    ///
    /// Parameters:
    /// - `allocator`: allocator for the contents.
    /// - `io`: IO for the filesystem.
    /// - `path`: the file.
    /// - `limit`: the most it may hold.
    ///
    /// Return: the contents, owned by the caller, or `null` when missing; `error.StreamTooLong` past `limit`.
    pub fn readOptional(allocator: std.mem.Allocator, io: std.Io, path: []const u8, limit: std.Io.Limit) !?[]u8 {
        return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, limit) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
    }

    /// Reads the file at `path` with a terminating 0, or reports that there is none.
    ///
    /// Parameters:
    /// - `allocator`: allocator for the contents.
    /// - `io`: IO for the filesystem.
    /// - `path`: the file.
    /// - `limit`: the most it may hold.
    ///
    /// Return: the 0-terminated contents, owned by the caller, or `null` when missing; `error.StreamTooLong` past `limit`.
    pub fn readOptionalZ(allocator: std.mem.Allocator, io: std.Io, path: []const u8, limit: std.Io.Limit) !?[:0]u8 {
        return std.Io.Dir.cwd().readFileAllocOptions(io, path, allocator, limit, .of(u8), 0) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
    }

    /// Creates the directory `path` goes in, and any missing above it.
    ///
    /// Parameters:
    /// - `io`: IO for the filesystem.
    /// - `path`: a file or directory; a bare name has no parent to create.
    ///
    /// Return: nothing; IO errors.
    pub fn createParentDir(io: std.Io, path: []const u8) !void {
        try std.Io.Dir.cwd().createDirPath(io, std.Io.Dir.path.dirname(path) orelse return);
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
