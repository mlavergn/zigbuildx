const std = @import("std");
const log = std.log.scoped(.zigbuildx_apk_zip);

/// Adds files to a zip without recompressing the entries already in it.
///
/// `aapt2 link` writes an APK with the manifest and resources but has no way to
/// add native libraries, and the tools that do (`zip`, the JDK's `jar`) are not
/// on every host. This copies the base archive's entries verbatim, appends each
/// added file stored uncompressed — Android maps a native library straight out
/// of the APK, which needs it stored — and writes a new central directory.
///
/// Built for the host and run by `Apk.add`, so it is a program as well as
/// a type: `apk-zip <base.apk> <out.apk> <dir>` adds every file under `<dir>` at
/// its path relative to `<dir>`.
pub const ApkZip = struct {
    const Self = @This();
    const local_signature: u32 = 0x04034b50;
    const central_signature: u32 = 0x02014b50;
    const end_signature: u32 = 0x06054b50;
    const local_header_len: usize = 30;
    const central_header_len: usize = 46;
    const end_record_len: usize = 22;
    /// General-purpose flag bit 3: sizes and CRC follow the data, in a descriptor.
    const data_descriptor_flag: u16 = 0x0008;
    /// 1980-01-01, the earliest date a zip can state: added entries carry no
    /// real timestamp, so an unchanged input yields an identical archive.
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
    pub fn init(allocator: std.mem.Allocator) !Self {
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

    /// Copies every entry of zip `bytes` whose name is not in `skip`, compressed data verbatim.
    ///
    /// Each entry gets a fresh local header without the data-descriptor flag, so
    /// its sizes and CRC are stated up front where `zipalign` reads them.
    ///
    /// Parameters:
    /// - `self`: the archive.
    /// - `bytes`: the source zip.
    /// - `skip`: names to leave out, because they are about to be added.
    ///
    /// Return: nothing; `error.InvalidZip` for a malformed source, `error.Zip64Unsupported` for a zip64 one.
    pub fn copyEntries(self: *Self, bytes: []const u8, skip: []const []const u8) !void {
        const end = try Self.findEnd(bytes);
        const entries = std.mem.readInt(u16, bytes[end + 10 ..][0..2], .little);
        var offset: usize = std.mem.readInt(u32, bytes[end + 16 ..][0..4], .little);
        for (0..entries) |_| {
            if (offset + central_header_len > bytes.len) return error.InvalidZip;
            const header = bytes[offset..][0..central_header_len];
            if (std.mem.readInt(u32, header[0..4], .little) != central_signature) return error.InvalidZip;
            const name_len = std.mem.readInt(u16, header[28..30], .little);
            const extra_len = std.mem.readInt(u16, header[30..32], .little);
            const comment_len = std.mem.readInt(u16, header[32..34], .little);
            const record_len = central_header_len + name_len + extra_len + comment_len;
            if (offset + record_len > bytes.len) return error.InvalidZip;
            const name = bytes[offset + central_header_len ..][0..name_len];
            defer offset += record_len;
            if (Self.contains(skip, name)) continue;

            const compressed = std.mem.readInt(u32, header[20..24], .little);
            const local = std.mem.readInt(u32, header[42..46], .little);
            if (compressed == 0xFFFFFFFF or local == 0xFFFFFFFF) return error.Zip64Unsupported;
            if (local + local_header_len > bytes.len) return error.InvalidZip;
            const local_name_len = std.mem.readInt(u16, bytes[local + 26 ..][0..2], .little);
            const local_extra_len = std.mem.readInt(u16, bytes[local + 28 ..][0..2], .little);
            const data_start = local + local_header_len + local_name_len + local_extra_len;
            if (data_start + compressed > bytes.len) return error.InvalidZip;

            const flags = std.mem.readInt(u16, header[8..10], .little) & ~data_descriptor_flag;
            var record = try self.allocator.dupe(u8, bytes[offset..][0..record_len]);
            defer self.allocator.free(record);
            std.mem.writeInt(u16, record[8..10], flags, .little);
            try self.append(record, bytes[data_start..][0..compressed]);
        }
    }

    /// Adds `data` under `name`, stored uncompressed.
    ///
    /// Parameters:
    /// - `self`: the archive.
    /// - `name`: the entry's path inside the archive, `/`-separated.
    /// - `data`: the entry's contents.
    ///
    /// Return: nothing; `error.EntryTooLarge` past 4 GiB.
    pub fn addStored(self: *Self, name: []const u8, data: []const u8) !void {
        if (data.len >= 0xFFFFFFFF) return error.EntryTooLarge;
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
        @memcpy(record[central_header_len..], name);
        try self.append(record, data);
    }

    /// Returns the finished archive: the entries, then the central directory and its end record.
    ///
    /// Parameters:
    /// - `self`: the archive; nothing may be added afterwards.
    ///
    /// Return: the archive's bytes, owned by `self`; `error.TooManyEntries` past 65535.
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

    /// Writes one entry: a local header built from central `record`, then `data`, then the record itself.
    ///
    /// Parameters:
    /// - `self`: the archive.
    /// - `record`: the entry's central directory record; its local-offset field is set here.
    /// - `data`: the entry's data as it is stored.
    ///
    /// Return: nothing; `error.ArchiveTooLarge` past 4 GiB.
    fn append(self: *Self, record: []u8, data: []const u8) !void {
        const offset = self.body.written().len;
        if (offset >= 0xFFFFFFFF) return error.ArchiveTooLarge;
        std.mem.writeInt(u32, record[42..46], @intCast(offset), .little);
        const name_len = std.mem.readInt(u16, record[28..30], .little);
        const writer = &self.body.writer;
        try writer.writeInt(u32, local_signature, .little);
        // Version needed through uncompressed size share their layout with the
        // central record's bytes 6..28.
        try writer.writeAll(record[6..28]);
        try writer.writeInt(u16, name_len, .little);
        try writer.writeInt(u16, 0, .little); // extra length
        try writer.writeAll(record[central_header_len..][0..name_len]);
        try writer.writeAll(data);
        try self.central.writer.writeAll(record);
        self.count += 1;
    }

    /// Finds the end-of-central-directory record, scanning back past any archive comment.
    ///
    /// Parameters:
    /// - `bytes`: the zip.
    ///
    /// Return: the record's offset; `error.InvalidZip` when there is none.
    fn findEnd(bytes: []const u8) !usize {
        if (bytes.len < end_record_len) return error.InvalidZip;
        var offset = bytes.len - end_record_len;
        const floor = if (bytes.len > end_record_len + 0xFFFF) bytes.len - end_record_len - 0xFFFF else 0;
        while (true) : (offset -= 1) {
            if (std.mem.readInt(u32, bytes[offset..][0..4], .little) == end_signature) return offset;
            if (offset == floor) return error.InvalidZip;
        }
    }

    /// Reports whether `names` holds `name`.
    ///
    /// Parameters:
    /// - `names`: the list to search.
    /// - `name`: the name to find.
    ///
    /// Return: `true` when present.
    fn contains(names: []const []const u8, name: []const u8) bool {
        for (names) |candidate| {
            if (std.mem.eql(u8, candidate, name)) return true;
        }
        return false;
    }

    /// `zigbuildx apk-zip <base.apk> <out.apk> <dir>`: writes `base.apk` plus every file under `dir`.
    ///
    /// Parameters:
    /// - `process_init`: the process's allocator and IO.
    /// - `args`: the command line after the program's path; `args[0]` is the command.
    ///
    /// Return: nothing; `error.InvalidArguments` on a bad command line, or IO and zip errors.
    pub fn command(process_init: std.process.Init, args: []const [:0]const u8) !void {
        const allocator = process_init.gpa;
        const io = process_init.io;
        if (args.len != 4) {
            log.err("usage: zigbuildx apk-zip <base.apk> <out.apk> <dir>", .{});
            return error.InvalidArguments;
        }
        const cwd = std.Io.Dir.cwd();

        var dir = try cwd.openDir(io, args[3], .{ .iterate = true });
        defer dir.close(io);
        var names: std.ArrayList([]const u8) = .empty;
        defer {
            for (names.items) |name| allocator.free(name);
            names.deinit(allocator);
        }
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            const name = try allocator.dupe(u8, entry.path);
            std.mem.replaceScalar(u8, name, '\\', '/');
            try names.append(allocator, name);
        }
        // Sorted, so the archive does not depend on the order the host lists a directory in.
        std.mem.sort([]const u8, names.items, {}, struct {
            /// Orders names bytewise.
            ///
            /// Parameters:
            /// - `a`: one name.
            /// - `b`: another.
            ///
            /// Return: `true` when `a` sorts before `b`.
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);

        const base = try cwd.readFileAlloc(io, args[1], allocator, .unlimited);
        defer allocator.free(base);
        var zip = try Self.init(allocator);
        defer zip.deinit();
        try zip.copyEntries(base, names.items);
        for (names.items) |name| {
            const data = try dir.readFileAlloc(io, name, allocator, .unlimited);
            defer allocator.free(data);
            try zip.addStored(name, data);
        }
        try cwd.writeFile(io, .{ .sub_path = args[2], .data = try zip.finish() });
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test "copyEntries and addStored produce a zip std.zip can read back" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var base = try ApkZip.init(allocator);
    defer base.deinit();
    try base.addStored("AndroidManifest.xml", "<manifest/>");
    try base.addStored("lib/arm64-v8a/libmain.so", "stale");
    const base_bytes = try allocator.dupe(u8, try base.finish());
    defer allocator.free(base_bytes);

    var apk = try ApkZip.init(allocator);
    defer apk.deinit();
    const added = [_][]const u8{"lib/arm64-v8a/libmain.so"};
    try apk.copyEntries(base_bytes, &added);
    try apk.addStored(added[0], "\x7fELF fresh");
    const bytes = try apk.finish();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "out.apk", .data = bytes });
    var file = try tmp.dir.openFile(io, "out.apk", .{});
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
    try std.testing.expectEqualStrings("\x7fELF fresh", lib);
}

test "findEnd rejects bytes that are not a zip" {
    try std.testing.expectError(error.InvalidZip, ApkZip.findEnd("not a zip at all, just text"));
    try std.testing.expectError(error.InvalidZip, ApkZip.findEnd("short"));
}
