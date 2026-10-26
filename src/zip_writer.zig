const std = @import("std");

/// Writes a zip of stored (uncompressed) entries in memory, for the tests' fixture archives.
///
/// What is left of `ApkZip` now that packaging APKs is zigpkg's: the
/// `ZipArchive` and `Deps` tests build the archives they unpack with it, since
/// std can read a zip but not write one. Entries carry no real timestamp, so
/// the same entries give the same bytes.
pub const ZipWriter = struct {
    const Self = @This();
    const local_signature: u32 = 0x04034b50;
    const central_signature: u32 = 0x02014b50;
    const end_signature: u32 = 0x06054b50;
    const central_header_len: usize = 46;
    /// 1980-01-01, the earliest date a zip can state.
    const dos_date: u16 = (0 << 9) | (1 << 5) | 1;

    allocator: std.mem.Allocator,
    /// Local headers and data, in archive order.
    body: std.Io.Writer.Allocating,
    /// Central directory records, in the same order.
    central: std.Io.Writer.Allocating,
    count: usize = 0,

    /// Creates an empty archive.
    ///
    /// Parameters:
    /// - `allocator`: backs the archive being built.
    ///
    /// Return: the archive.
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{ .allocator = allocator, .body = .init(allocator), .central = .init(allocator) };
    }

    /// Frees the archive.
    ///
    /// Parameters:
    /// - `self`: the archive.
    pub fn deinit(self: *Self) void {
        self.central.deinit();
        self.body.deinit();
    }

    /// Appends `data` as entry `name`, stored uncompressed.
    ///
    /// Parameters:
    /// - `self`: the archive.
    /// - `name`: the entry's path, with `/` separators.
    /// - `data`: the file's contents.
    ///
    /// Return: nothing; `error.EntryTooLarge` past 4 GiB, `error.ArchiveTooLarge`, or allocation errors.
    pub fn addStored(self: *Self, name: []const u8, data: []const u8) !void {
        if (data.len >= 0xFFFFFFFF) return error.EntryTooLarge;
        const offset = self.body.written().len;
        if (offset >= 0xFFFFFFFF) return error.ArchiveTooLarge;
        const size: u32 = @intCast(data.len);
        var record = try self.allocator.alloc(u8, central_header_len + name.len);
        defer self.allocator.free(record);
        @memset(record, 0);
        std.mem.writeInt(u32, record[0..4], central_signature, .little);
        std.mem.writeInt(u16, record[4..6], 20, .little); // version made by
        std.mem.writeInt(u16, record[6..8], 20, .little); // version needed
        std.mem.writeInt(u16, record[14..16], dos_date, .little);
        std.mem.writeInt(u32, record[16..20], std.hash.Crc32.hash(data), .little);
        std.mem.writeInt(u32, record[20..24], size, .little);
        std.mem.writeInt(u32, record[24..28], size, .little);
        std.mem.writeInt(u16, record[28..30], @intCast(name.len), .little);
        std.mem.writeInt(u32, record[42..46], @intCast(offset), .little);
        @memcpy(record[central_header_len..], name);

        const writer = &self.body.writer;
        try writer.writeInt(u32, local_signature, .little);
        // Version needed through uncompressed size share their layout with the
        // central record's bytes 6..28.
        try writer.writeAll(record[6..28]);
        try writer.writeInt(u16, @intCast(name.len), .little);
        try writer.writeInt(u16, 0, .little); // extra length
        try writer.writeAll(name);
        try writer.writeAll(data);
        try self.central.writer.writeAll(record);
        self.count += 1;
    }

    /// Writes the central directory and its end record, completing the archive.
    ///
    /// Parameters:
    /// - `self`: the archive; nothing may be added afterwards.
    ///
    /// Return: the zip's bytes, owned by the archive; `error.TooManyEntries`,
    /// `error.ArchiveTooLarge`, or allocation errors.
    pub fn finish(self: *Self) ![]const u8 {
        if (self.count > 0xFFFF) return error.TooManyEntries;
        const central_offset = self.body.written().len;
        const central_len = self.central.written().len;
        if (central_offset + central_len >= 0xFFFFFFFF) return error.ArchiveTooLarge;
        const writer = &self.body.writer;
        try writer.writeAll(self.central.written());
        try writer.writeInt(u32, end_signature, .little);
        try writer.writeInt(u16, 0, .little); // this disk
        try writer.writeInt(u16, 0, .little); // central directory's disk
        try writer.writeInt(u16, @intCast(self.count), .little);
        try writer.writeInt(u16, @intCast(self.count), .little);
        try writer.writeInt(u32, @intCast(central_len), .little);
        try writer.writeInt(u32, @intCast(central_offset), .little);
        try writer.writeInt(u16, 0, .little); // comment length
        return self.body.written();
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test "addStored and finish produce a zip std.zip can read back" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var zip = ZipWriter.init(allocator);
    defer zip.deinit();
    try zip.addStored("AndroidManifest.xml", "<manifest/>");
    try zip.addStored("lib/arm64-v8a/libmain.so", "\x7fELF");
    const bytes = try zip.finish();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "out.zip", .data = bytes });
    var file = try tmp.dir.openFile(io, "out.zip", .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    try tmp.dir.createDir(io, "x", .default_dir);
    var out = try tmp.dir.openDir(io, "x", .{});
    defer out.close(io);
    try std.zip.extract(out, &reader, .{});

    const manifest = try out.readFileAlloc(io, "AndroidManifest.xml", allocator, .unlimited);
    defer allocator.free(manifest);
    try std.testing.expectEqualStrings("<manifest/>", manifest);
    const lib = try out.readFileAlloc(io, "lib/arm64-v8a/libmain.so", allocator, .unlimited);
    defer allocator.free(lib);
    try std.testing.expectEqualStrings("\x7fELF", lib);
}
