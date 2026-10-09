const std = @import("std");
const log = std.log.scoped(.zigbuildx_deb);

/// One file or directory under a staged directory.
const Entry = struct {
    const Self = @This();
    /// The path relative to the directory, with `/` separators.
    path: []const u8,
    kind: enum { file, directory },
    size: u64,
    mode: u32,
};

/// Writes a Debian binary package from a staged tree, with no `dpkg-deb`.
///
/// A `.deb` is an `ar` archive of three members: `debian-binary`, holding
/// `2.0`; `control.tar.gz`, the `control` file and maintainer scripts; and
/// `data.tar.gz`, the files to install, relative to `/`. `dpkg-deb` is not on
/// macOS or Windows, so this writes one with `std.tar` and `std.compress.flate`.
///
/// Built for the host and run by `Pkg`, so it is a program as well as a type:
/// `deb <staging> <out.deb>` packs `<staging>/control` and `<staging>/data`.
/// Entries are sorted, owned by root and dated 0, so an unchanged input
/// yields an identical package.
pub const Deb = struct {
    const Self = @This();
    /// Maintainer scripts dpkg runs; they must be executable.
    const scripts = [_][]const u8{ "preinst", "postinst", "prerm", "postrm", "config" };

    allocator: std.mem.Allocator,
    io: std.Io,

    /// Creates a packer.
    ///
    /// Parameters:
    /// - `allocator`: backs the package being built.
    /// - `io`: IO for reading the staged tree.
    ///
    /// Return: the packer.
    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Self {
        return .{ .allocator = allocator, .io = io };
    }

    /// Maps a CPU architecture to Debian's name for it.
    ///
    /// Parameters:
    /// - `cpu`: the target's architecture.
    ///
    /// Return: `arm64` or `amd64`, or `null` for any other.
    pub fn arch(cpu: std.Target.Cpu.Arch) ?[]const u8 {
        return switch (cpu) {
            .aarch64 => "arm64",
            .x86_64 => "amd64",
            else => null,
        };
    }

    /// Reports whether `name` is a valid Debian package name.
    ///
    /// Parameters:
    /// - `name`: the package name.
    ///
    /// Return: `true` for lowercase letters, digits, `+`, `-` and `.`, at least two long, starting alphanumeric.
    pub fn isName(name: []const u8) bool {
        if (name.len < 2 or !std.ascii.isAlphanumeric(name[0])) return false;
        for (name) |c| {
            if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '+' or c == '-' or c == '.')) return false;
        }
        return true;
    }

    /// Packs `staging`'s `control` and `data` directories into a `.deb`.
    ///
    /// `control/control` gains an `Installed-Size` field, computed from `data`.
    ///
    /// Parameters:
    /// - `self`: the packer.
    /// - `staging`: the staged tree.
    ///
    /// Return: the package, owned by the caller; `error.MissingControl` when
    /// `control/control` is absent, or IO errors.
    pub fn pack(self: *const Self, staging: std.Io.Dir) ![]u8 {
        var data_dir = try staging.openDir(self.io, "data", .{ .iterate = true });
        defer data_dir.close(self.io);
        const data_entries = try self.collect(data_dir);
        defer self.freeEntries(data_entries);
        var installed: u64 = 0;
        for (data_entries) |entry| installed += entry.size;

        var control_dir = try staging.openDir(self.io, "control", .{ .iterate = true });
        defer control_dir.close(self.io);
        const control_text = control_dir.readFileAlloc(self.io, "control", self.allocator, .limited(1 << 16)) catch |err| switch (err) {
            error.FileNotFound => return error.MissingControl,
            else => return err,
        };
        defer self.allocator.free(control_text);
        const control = try Self.withInstalledSize(self.allocator, control_text, (installed + 1023) / 1024);
        defer self.allocator.free(control);
        const control_entries = try self.collect(control_dir);
        defer self.freeEntries(control_entries);

        const control_tar = try self.tarGz(control_dir, control_entries, control);
        defer self.allocator.free(control_tar);
        const data_tar = try self.tarGz(data_dir, data_entries, null);
        defer self.allocator.free(data_tar);

        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        try out.writer.writeAll("!<arch>\n");
        try Self.arMember(&out.writer, "debian-binary", "2.0\n");
        try Self.arMember(&out.writer, "control.tar.gz", control_tar);
        try Self.arMember(&out.writer, "data.tar.gz", data_tar);
        return out.toOwnedSlice();
    }

    /// Lists every file and directory under `dir`, sorted by path.
    ///
    /// Parameters:
    /// - `self`: the packer.
    /// - `dir`: the directory to walk.
    ///
    /// Return: the entries, freed with `freeEntries`; IO errors.
    fn collect(self: *const Self, dir: std.Io.Dir) ![]Entry {
        var entries: std.ArrayList(Entry) = .empty;
        errdefer {
            for (entries.items) |entry| self.allocator.free(entry.path);
            entries.deinit(self.allocator);
        }
        var walker = try dir.walk(self.allocator);
        defer walker.deinit();
        while (try walker.next(self.io)) |item| {
            const path = try self.allocator.dupe(u8, item.path);
            errdefer self.allocator.free(path);
            std.mem.replaceScalar(u8, path, '\\', '/');
            switch (item.kind) {
                .directory => try entries.append(self.allocator, .{ .path = path, .kind = .directory, .size = 0, .mode = 0o755 }),
                .file => {
                    const stat = try item.dir.statFile(self.io, item.basename, .{});
                    try entries.append(self.allocator, .{ .path = path, .kind = .file, .size = stat.size, .mode = Self.fileMode(path, stat.permissions) });
                },
                else => self.allocator.free(path),
            }
        }
        // Sorted, so the package does not depend on the order the host lists a directory in.
        std.mem.sort(Entry, entries.items, {}, struct {
            /// Orders entries by path.
            ///
            /// Parameters:
            /// - `a`: one entry.
            /// - `b`: another.
            ///
            /// Return: `true` when `a` sorts before `b`.
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                return std.mem.lessThan(u8, a.path, b.path);
            }
        }.lessThan);
        return entries.toOwnedSlice(self.allocator);
    }

    /// Frees what `collect` returned.
    ///
    /// Parameters:
    /// - `self`: the packer.
    /// - `entries`: the entries.
    fn freeEntries(self: *const Self, entries: []Entry) void {
        for (entries) |entry| self.allocator.free(entry.path);
        self.allocator.free(entries);
    }

    /// Chooses a staged file's mode: 0755 for programs and maintainer scripts, 0644 otherwise.
    ///
    /// A Windows host has no executable bit to read, so anything in a `bin`
    /// directory, and any maintainer script, is executable whatever the host says.
    ///
    /// Parameters:
    /// - `path`: the path relative to its staged directory.
    /// - `permissions`: what the host reports.
    ///
    /// Return: the mode.
    fn fileMode(path: []const u8, permissions: std.Io.File.Permissions) u32 {
        if (std.mem.startsWith(u8, path, "bin/") or std.mem.find(u8, path, "/bin/") != null) return 0o755;
        for (Self.scripts) |script| {
            if (std.mem.eql(u8, path, script)) return 0o755;
        }
        if (std.Io.File.Permissions.has_executable_bit and permissions.toMode() & 0o111 != 0) return 0o755;
        return 0o644;
    }

    /// Inserts `Installed-Size` into a control file, before `Description` or at the end.
    ///
    /// Parameters:
    /// - `allocator`: allocator for the result.
    /// - `control`: the control file.
    /// - `kib`: the installed size in KiB.
    ///
    /// Return: the control file with the field, owned by the caller.
    fn withInstalledSize(allocator: std.mem.Allocator, control: []const u8, kib: u64) ![]u8 {
        const trimmed = std.mem.trimEnd(u8, control, "\n");
        const field = try allocator.print("Installed-Size: {d}\n", .{kib});
        defer allocator.free(field);
        const at = if (std.mem.find(u8, trimmed, "\nDescription:")) |i| i + 1 else trimmed.len + 1;
        if (at > trimmed.len) return std.mem.concat(allocator, u8, &.{ trimmed, "\n", field });
        return std.mem.concat(allocator, u8, &.{ trimmed[0..at], field, trimmed[at..], "\n" });
    }

    /// Writes a gzipped tarball of `entries` from `dir`, rooted at `./`.
    ///
    /// Parameters:
    /// - `self`: the packer.
    /// - `dir`: the staged directory.
    /// - `entries`: its entries, from `collect`.
    /// - `control`: replaces the file named `control`, when not null.
    ///
    /// Return: the `.tar.gz`, owned by the caller; IO errors.
    fn tarGz(self: *const Self, dir: std.Io.Dir, entries: []const Entry, control: ?[]const u8) ![]u8 {
        var out = try std.Io.Writer.Allocating.initCapacity(self.allocator, 1 << 16);
        errdefer out.deinit();
        const window = try self.allocator.alloc(u8, std.compress.flate.max_window_len);
        defer self.allocator.free(window);
        var gzip = try std.compress.flate.Compress.init(&out.writer, window, .gzip, .default);
        var tar: std.tar.Writer = .{ .underlying_writer = &gzip.writer };
        try tar.writeDir("./", .{ .mode = 0o755 });
        var buffer: [1 << 16]u8 = undefined;
        for (entries) |entry| {
            const name = try self.allocator.print("./{s}", .{entry.path});
            defer self.allocator.free(name);
            switch (entry.kind) {
                .directory => try tar.writeDir(name, .{ .mode = entry.mode }),
                .file => if (control != null and std.mem.eql(u8, entry.path, "control")) {
                    try tar.writeFileBytes(name, control.?, .{ .mode = 0o644 });
                } else {
                    var file = try dir.openFile(self.io, entry.path, .{});
                    defer file.close(self.io);
                    var reader = file.reader(self.io, &buffer);
                    try tar.writeFileStream(name, entry.size, &reader.interface, .{ .mode = entry.mode });
                },
            }
        }
        try tar.finishPedantically();
        try gzip.finish();
        try out.writer.flush();
        return out.toOwnedSlice();
    }

    /// Writes one `ar` member: a 60-byte header, the data, and a pad byte to an even length.
    ///
    /// Parameters:
    /// - `writer`: the archive.
    /// - `name`: the member name, at most 16 bytes.
    /// - `data`: the member's contents.
    ///
    /// Return: nothing; write errors.
    fn arMember(writer: *std.Io.Writer, name: []const u8, data: []const u8) !void {
        std.debug.assert(name.len <= 16);
        try writer.print("{s: <16}{s: <12}{s: <6}{s: <6}{s: <8}{d: <10}`\n", .{ name, "0", "0", "0", "100644", data.len });
        try writer.writeAll(data);
        if (data.len % 2 == 1) try writer.writeByte('\n');
    }

    /// `zigbuildx deb <staging> <out.deb>`: packs a staged tree into a `.deb`.
    ///
    /// Parameters:
    /// - `process_init`: the process's allocator and IO.
    /// - `args`: the command line after the program's path; `args[0]` is the command.
    ///
    /// Return: nothing; `error.InvalidArguments` on a bad command line, or IO errors.
    pub fn command(process_init: std.process.Init, args: []const [:0]const u8) !void {
        const allocator = process_init.gpa;
        const io = process_init.io;
        if (args.len != 3) {
            log.err("usage: zigbuildx deb <staging> <out.deb>", .{});
            return error.InvalidArguments;
        }
        const cwd = std.Io.Dir.cwd();
        var staging = try cwd.openDir(io, args[1], .{});
        defer staging.close(io);
        const packer = try Self.init(allocator, io);
        const deb = try packer.pack(staging);
        defer allocator.free(deb);
        try cwd.writeFile(io, .{ .sub_path = args[2], .data = deb });
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

/// Splits an `ar` archive into its members' names and data, for the tests.
///
/// Parameters:
/// - `bytes`: the archive.
/// - `names`: receives the member names.
/// - `datas`: receives the member contents.
///
/// Return: the member count; `error.TestUnexpectedResult` when it is not an `ar` archive.
fn arMembers(bytes: []const u8, names: [][]const u8, datas: [][]const u8) !usize {
    if (!std.mem.startsWith(u8, bytes, "!<arch>\n")) return error.TestUnexpectedResult;
    var at: usize = 8;
    var count: usize = 0;
    while (at < bytes.len) : (count += 1) {
        const header = bytes[at..][0..60];
        const size = try std.fmt.parseInt(usize, std.mem.trim(u8, header[48..58], " "), 10);
        names[count] = std.mem.trim(u8, header[0..16], " ");
        datas[count] = bytes[at + 60 ..][0..size];
        at += 60 + size + size % 2;
    }
    return count;
}

/// Gunzips `bytes` and lists the tar entries' names and modes, as `name mode` lines.
///
/// Parameters:
/// - `allocator`: allocator for the result.
/// - `bytes`: a `.tar.gz`.
///
/// Return: the listing, owned by the caller; decompression and tar errors.
fn tarListing(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var input: std.Io.Reader = .fixed(bytes);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var gunzip: std.compress.flate.Decompress = .init(&input, .gzip, &window);
    var file_name: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var link_name: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(&gunzip.reader, .{ .file_name_buffer = &file_name, .link_name_buffer = &link_name });
    var listing: std.Io.Writer.Allocating = .init(allocator);
    errdefer listing.deinit();
    while (try it.next()) |entry| {
        try listing.writer.print("{s} {o}\n", .{ entry.name, entry.mode });
        if (entry.kind == .file) try it.streamRemaining(entry, &listing.writer);
    }
    return listing.toOwnedSlice();
}

test "arch and isName follow Debian's rules" {
    try std.testing.expectEqualStrings("arm64", Deb.arch(.aarch64).?);
    try std.testing.expectEqual(null, Deb.arch(.riscv64));
    try std.testing.expect(Deb.isName("zlintpre"));
    try std.testing.expect(!Deb.isName("ZLint"));
    try std.testing.expect(!Deb.isName("z"));
}

test "withInstalledSize puts the field before Description" {
    const allocator = std.testing.allocator;
    const out = try Deb.withInstalledSize(allocator, "Package: x\nDescription: y\n", 3);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("Package: x\nInstalled-Size: 3\nDescription: y\n", out);
    const end = try Deb.withInstalledSize(allocator, "Package: x\n", 1);
    defer allocator.free(end);
    try std.testing.expectEqualStrings("Package: x\nInstalled-Size: 1\n", end);
}

test "pack writes an ar archive of debian-binary, control.tar.gz and data.tar.gz" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "control");
    try tmp.dir.createDirPath(io, "data/usr/local/acme/tool/bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "control/control", .data = "Package: tool\nVersion: 1.0.0\nArchitecture: arm64\nDescription: a tool\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "control/preinst", .data = "#!/bin/sh\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "data/usr/local/acme/tool/bin/tool", .data = "ELF" });

    const deb = try (try Deb.init(allocator, io)).pack(tmp.dir);
    defer allocator.free(deb);
    var names: [3][]const u8 = undefined;
    var datas: [3][]const u8 = undefined;
    try std.testing.expectEqual(3, try arMembers(deb, &names, &datas));
    try std.testing.expectEqualStrings("debian-binary", names[0]);
    try std.testing.expectEqualStrings("2.0\n", datas[0]);
    try std.testing.expectEqualStrings("control.tar.gz", names[1]);
    try std.testing.expectEqualStrings("data.tar.gz", names[2]);

    const control = try tarListing(allocator, datas[1]);
    defer allocator.free(control);
    try std.testing.expectEqualStrings(
        \\./ 755
        \\./control 644
        \\Package: tool
        \\Version: 1.0.0
        \\Architecture: arm64
        \\Installed-Size: 1
        \\Description: a tool
        \\./preinst 755
        \\#!/bin/sh
        \\
    , control);
    const data = try tarListing(allocator, datas[2]);
    defer allocator.free(data);
    try std.testing.expectEqualStrings(
        \\./ 755
        \\./usr 755
        \\./usr/local 755
        \\./usr/local/acme 755
        \\./usr/local/acme/tool 755
        \\./usr/local/acme/tool/bin 755
        \\./usr/local/acme/tool/bin/tool 755
        \\ELF
    , data);

    // The same input packs to the same bytes.
    const again = try (try Deb.init(allocator, io)).pack(tmp.dir);
    defer allocator.free(again);
    try std.testing.expectEqualSlices(u8, deb, again);
}
