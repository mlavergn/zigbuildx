const std = @import("std");
const log = std.log.scoped(.zigbuildx_zip_archive);
const mod = @import("module.zig");

/// Unpacks a zip archive, fetched from a URL, as a `.path` dependency.
///
/// A source release that is not a git repository (SQLite's amalgamation, say)
/// can still be a `.path` dependency: its `.archive` names the zip, and `Deps`
/// unpacks it there when it is absent or was unpacked from another URL. A
/// single top-level folder is stripped, as `zig fetch` does.
///
/// An `https://` or `http://` archive is downloaded by `curl`, which ships
/// with macOS, Windows 10 and later, and nearly every Linux, and honours
/// `https_proxy`: the build runner's configure phase is compiled with
/// `std.options.http_disable_tls`, so `std.http` cannot fetch over TLS there.
/// The zip is unpacked in process with `std.zip`, as `unzip` is not on every host.
pub const ZipArchive = struct {
    const Self = @This();

    /// The file `unpack` leaves in the directory, holding the URL it came from.
    ///
    /// It marks the directory as zigbuildx's own, to replace when the URL changes.
    pub const stamp_name = ".zigbuildx-archive";

    /// The `build.zig` written into an archive that has none.
    ///
    /// `Deps` learns whether a `.path` dependency is present from the build
    /// runner's package table, which records a package by its `build.zig`;
    /// without one an unpacked archive would look absent forever.
    const stub_build_zig =
        \\//! Written by zigbuildx when it unpacked this archive, so Zig sees a package here.
        \\
        \\pub fn build(_: *@import("std").Build) void {}
        \\
    ;

    /// The largest stamp `source` reads; it holds one URL.
    const max_stamp_bytes = 1 << 16;

    /// The largest local (`file://`) archive `unpack` reads.
    const max_file_bytes = 1 << 30;

    /// How long `curl` waits to connect before the download fails, as its
    /// `--connect-timeout` takes it, so a server that never answers cannot
    /// hang the configure phase. A slow transfer once connected is not cut off.
    const connect_timeout_seconds = "30";

    /// The scheme of a local archive, as a mirror or a test uses.
    const file_scheme = "file://";

    /// Reads the URL the directory at `dir` was unpacked from.
    ///
    /// Parameters:
    /// - `allocator`: an arena for the result.
    /// - `io`: IO for the filesystem.
    /// - `dir`: the dependency's absolute path.
    ///
    /// Return: the URL, or `null` when `dir` has no stamp; IO errors.
    pub fn source(allocator: std.mem.Allocator, io: std.Io, dir: []const u8) !?[]const u8 {
        const path = try std.Io.Dir.path.join(allocator, &.{ dir, stamp_name });
        const text = try mod.File.readOptional(allocator, io, path, .limited(Self.max_stamp_bytes)) orelse return null;
        return std.mem.trimEnd(u8, text, "\r\n");
    }

    /// Downloads the zip at `url` and unpacks it at `dest`, replacing an earlier unpack; `dest` is untouched on failure.
    ///
    /// Parameters:
    /// - `allocator`: an arena for everything it allocates.
    /// - `io`: IO for the filesystem and `curl`.
    /// - `url`: an `https://`, `http://` or `file://` URL of a zip.
    /// - `dest`: the dependency's absolute path; the caller decides it may be replaced.
    ///
    /// Return: nothing; `error.ArchiveDownloadFailed`, `error.ArchiveEmpty`, or IO and zip errors, none of them logged.
    pub fn unpack(allocator: std.mem.Allocator, io: std.Io, url: []const u8, dest: []const u8) !void {
        const cwd = std.Io.Dir.cwd();
        // Downloaded and unpacked beside `dest`, then renamed into place, so a failed download leaves `dest`.
        const staging = try allocator.print("{s}.zigbuildx-unpack", .{dest});
        // A staging directory left by an interrupted unpack is stale.
        try cwd.deleteTree(io, staging);
        defer cwd.deleteTree(io, staging) catch |err| log.warn("cannot delete {s} [{any}]", .{ staging, err });
        const files = try std.Io.Dir.path.join(allocator, &.{ staging, "files" });
        try cwd.createDirPath(io, files);
        const zip_path = try std.Io.Dir.path.join(allocator, &.{ staging, "archive.zip" });
        try Self.download(allocator, io, url, zip_path);
        const top = try Self.extract(allocator, io, zip_path, files);
        const build_zig = try std.Io.Dir.path.join(allocator, &.{ top, "build.zig" });
        if (!try mod.File.exists(io, build_zig)) try cwd.writeFile(io, .{ .sub_path = build_zig, .data = Self.stub_build_zig });
        const stamp = try std.Io.Dir.path.join(allocator, &.{ top, stamp_name });
        try cwd.writeFile(io, .{ .sub_path = stamp, .data = try allocator.print("{s}\n", .{url}) });
        try mod.File.createParentDir(io, dest);
        // The old directory moves into staging, deleted with it, and comes back if the new one cannot take its place.
        const previous = try std.Io.Dir.path.join(allocator, &.{ staging, "previous" });
        var replaced = true;
        cwd.rename(dest, cwd, previous, io) catch |err| switch (err) {
            error.FileNotFound => replaced = false,
            else => return err,
        };
        cwd.rename(top, cwd, dest, io) catch |err| {
            if (replaced) cwd.rename(previous, cwd, dest, io) catch |restore_err| log.warn("cannot restore {s} [{any}]", .{ dest, restore_err });
            return err;
        };
        log.info("unpacked {s} into {s}", .{ url, dest });
    }

    /// Downloads `url` to the file at `path`.
    ///
    /// Parameters:
    /// - `allocator`: an arena for a local archive's contents.
    /// - `io`: IO for the filesystem and `curl`.
    /// - `url`: an `https://`, `http://` or `file://` URL.
    /// - `path`: the file to write.
    ///
    /// Return: nothing; `error.ArchiveDownloadFailed` when `curl` fails, or IO errors.
    fn download(allocator: std.mem.Allocator, io: std.Io, url: []const u8, path: []const u8) !void {
        const cwd = std.Io.Dir.cwd();
        if (std.mem.startsWith(u8, url, Self.file_scheme)) {
            const data = try cwd.readFileAlloc(io, url[Self.file_scheme.len..], allocator, .limited(Self.max_file_bytes));
            return cwd.writeFile(io, .{ .sub_path = path, .data = data });
        }
        // --fail turns an HTTP error into a non-zero exit; --show-error still prints it.
        // --url takes the URL as a value, so one from a manifest cannot pass as an option.
        var child = try std.process.spawn(io, .{ .argv = &.{ "curl", "--fail", "--location", "--silent", "--show-error", "--connect-timeout", Self.connect_timeout_seconds, "--output", path, "--url", url } });
        const term = try child.wait(io);
        switch (term) {
            .exited => |code| if (code == 0) return,
            else => {},
        }
        // Returned, not logged as an error: the caller names the archive in its message.
        log.warn("curl {s} failed [{any}]", .{ url, term });
        return error.ArchiveDownloadFailed;
    }

    /// Unpacks the zip at `zip_path` into `dir`.
    ///
    /// Parameters:
    /// - `allocator`: an arena for the result.
    /// - `io`: IO for the filesystem.
    /// - `zip_path`: the zip.
    /// - `dir`: an empty directory to unpack into.
    ///
    /// Return: the zip's single top-level folder inside `dir`, else `dir`; `error.ArchiveEmpty`, or IO and zip errors.
    fn extract(allocator: std.mem.Allocator, io: std.Io, zip_path: []const u8, dir: []const u8) ![]const u8 {
        const cwd = std.Io.Dir.cwd();
        var file = try cwd.openFile(io, zip_path, .{});
        defer file.close(io);
        var buffer: [16 * 1024]u8 = undefined;
        var reader = file.reader(io, &buffer);
        var out = try cwd.openDir(io, dir, .{});
        defer out.close(io);
        var diagnostics: std.zip.Diagnostics = .{ .allocator = allocator };
        try std.zip.extract(out, &reader, .{ .allow_backslashes = true, .diagnostics = &diagnostics });
        if (!diagnostics.saw_first_file) return error.ArchiveEmpty;
        if (diagnostics.root_dir.len == 0) return dir;
        return std.Io.Dir.path.join(allocator, &.{ dir, diagnostics.root_dir });
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

/// Writes a zip of `entries` into `tmp` as `name`.
///
/// Parameters:
/// - `allocator`: an arena for the result.
/// - `tmp`: the scratch directory.
/// - `name`: the zip's file name.
/// - `entries`: (name, contents) pairs, with `/`-separated names.
///
/// Return: the zip's `file://` URL; IO and zip errors.
fn writeTestZip(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, name: []const u8, entries: []const [2][]const u8) ![]const u8 {
    var zip = mod.ZipBuilder.init(allocator);
    defer zip.deinit();
    for (entries) |entry| try zip.addStored(entry[0], entry[1]);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = try zip.finish() });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    return allocator.print("{s}{s}/{s}", .{ ZipArchive.file_scheme, root, name });
}

test "unpack strips a single top-level folder and stamps the URL" {
    std.testing.log_level = .err;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const url = try writeTestZip(allocator, &tmp, "one.zip", &.{ .{ "release-1/a.c", "one" }, .{ "release-1/inc/a.h", "h" } });
    const dest = try std.Io.Dir.path.join(allocator, &.{ try tmp.dir.realPathFileAlloc(io, ".", allocator), "dep" });

    try std.testing.expectEqual(null, try ZipArchive.source(allocator, io, dest));
    try ZipArchive.unpack(allocator, io, url, dest);
    const a = try tmp.dir.readFileAlloc(io, "dep/a.c", allocator, .limited(64));
    try std.testing.expectEqualStrings("one", a);
    try tmp.dir.access(io, "dep/inc/a.h", .{});
    try tmp.dir.access(io, "dep/build.zig", .{});
    try std.testing.expectEqualStrings(url, (try ZipArchive.source(allocator, io, dest)).?);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "dep.zigbuildx-unpack", .{}));
}

test "unpack replaces an earlier unpack, keeps an archive's own build.zig, and leaves dest alone on failure" {
    std.testing.log_level = .err;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const dest = try std.Io.Dir.path.join(allocator, &.{ try tmp.dir.realPathFileAlloc(io, ".", allocator), "dep" });
    try ZipArchive.unpack(allocator, io, try writeTestZip(allocator, &tmp, "one.zip", &.{.{ "release-1/old.c", "one" }}), dest);

    // Two top-level entries: nothing is stripped.
    const two = try writeTestZip(allocator, &tmp, "two.zip", &.{ .{ "new.c", "two" }, .{ "build.zig", "// own" } });
    try ZipArchive.unpack(allocator, io, two, dest);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "dep/old.c", .{}));
    try std.testing.expectEqualStrings("// own", try tmp.dir.readFileAlloc(io, "dep/build.zig", allocator, .limited(64)));
    try std.testing.expectEqualStrings(two, (try ZipArchive.source(allocator, io, dest)).?);

    const missing = try allocator.print("{s}{s}", .{ ZipArchive.file_scheme, try std.Io.Dir.path.join(allocator, &.{ dest, "..", "missing.zip" }) });
    try std.testing.expectError(error.FileNotFound, ZipArchive.unpack(allocator, io, missing, dest));
    try tmp.dir.access(io, "dep/new.c", .{});
}
