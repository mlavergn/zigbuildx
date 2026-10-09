const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.zigbuildx_archive);

/// Re-lays a static library so Apple's linker accepts it.
///
/// Zig 0.16 writes archive members that are not 8-byte aligned, and Apple's `ld`
/// skips such a member with only a warning ("64-bit mach-o not 8-byte aligned"),
/// so the link then fails on its missing symbols. Whether it trips depends on the
/// size of the members ahead of it, so it appears and disappears as a library
/// grows. A Zig consumer never sees it: only `ld64` and `libtool` care, which is
/// to say Swift packages and Xcode projects linking the installed `.a`.
pub const Archive = struct {
    const Self = @This();

    /// Extracts `$1`'s members and re-archives them, aligned, into `$2`.
    ///
    /// Extraction is not optional: `libtool -static` given the archive itself
    /// drops the misaligned member with a warning and writes an archive without
    /// it. `ar x` writes members with mode 000, hence the `chmod`, and silently
    /// keeps only the last of two members with one name, hence the check.
    pub const script =
        \\set -eu
        \\abs() { (cd "$(dirname "$1")" && printf '%s/%s' "$(pwd)" "$(basename "$1")"); }
        \\in=$(abs "$1"); out=$(abs "$2")
        \\dups=$(ar -t "$in" | grep -v '^__\.SYMDEF' | sort | uniq -d)
        \\if [ -n "$dups" ]; then echo "cannot repack $in: duplicate members: $dups" >&2; exit 1; fi
        \\tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
        \\cd "$tmp"
        \\ar x "$in"
        \\rm -f __.SYMDEF*
        \\chmod 644 ./*
        \\libtool -static -o "$out" ./*
    ;

    /// Returns `lib`'s archive in a form Apple's linker accepts.
    ///
    /// The repack runs only where it can and where it matters: a static library
    /// for an Apple target, built on a macOS host, which has `libtool`. Anywhere
    /// else the archive is returned untouched.
    ///
    /// Parameters:
    /// - `b`: the build graph the repack step is registered on.
    /// - `lib`: the static library.
    ///
    /// Return: the repacked archive, or `lib`'s own.
    pub fn repack(b: *std.Build, lib: *std.Build.Step.Compile) std.Build.LazyPath {
        if (!Self.isNeeded(b, lib)) return lib.getEmittedBin();
        const run = b.addSystemCommand(&.{ "/bin/sh", "-c", Self.script, "repack" });
        run.setName(b.fmt("repack {s}", .{lib.out_filename}));
        run.addFileArg(lib.getEmittedBin());
        return run.addOutputFileArg(lib.out_filename);
    }

    /// Creates a step installing `lib`'s repacked archive under `lib/`.
    ///
    /// The counterpart of `b.addInstallArtifact(lib, .{})`, and like it not yet
    /// attached to any step. Headers registered with `lib.installHeader` are
    /// installed too: only an artifact install carries them, so one runs with its
    /// binary disabled, beside the repacked archive.
    ///
    /// Parameters:
    /// - `b`: the build graph.
    /// - `lib`: the static library.
    ///
    /// Return: the install step.
    pub fn addInstall(b: *std.Build, lib: *std.Build.Step.Compile) *std.Build.Step {
        if (!Self.isNeeded(b, lib)) return &b.addInstallArtifact(lib, .{}).step;
        const headers = b.addInstallArtifact(lib, .{ .dest_dir = .disabled });
        const archive = b.addInstallLibFile(Self.repack(b, lib), lib.out_filename);
        archive.step.dependOn(&headers.step);
        return &archive.step;
    }

    /// Installs `lib`'s repacked archive as part of `zig build install`.
    ///
    /// The counterpart of `b.installArtifact(lib)`.
    ///
    /// Parameters:
    /// - `b`: the build graph.
    /// - `lib`: the static library.
    pub fn install(b: *std.Build, lib: *std.Build.Step.Compile) void {
        b.getInstallStep().dependOn(Self.addInstall(b, lib));
    }

    /// Reports whether `lib` is a static library Apple's linker will read, built where `libtool` exists.
    ///
    /// Parameters:
    /// - `b`: the build graph, whose host is checked.
    /// - `lib`: the artifact to check.
    ///
    /// Return: `true` when the repack should run.
    fn isNeeded(b: *std.Build, lib: *std.Build.Step.Compile) bool {
        if (lib.kind != .lib or lib.linkage != .static) {
            log.warn("{s} is not a static library; installing it unchanged", .{lib.name});
            return false;
        }
        const target = lib.root_module.resolved_target orelse return false;
        return b.graph.host.result.os.tag == .macos and target.result.os.tag.isDarwin();
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

/// Returns the data offset of the first member whose data is not 8-byte aligned, if any.
///
/// Parameters:
/// - `bytes`: an `ar` archive.
///
/// Return: the offset, or `null` when every member is aligned;
/// `error.NotAnArchive`, or a parse error from a malformed header.
fn firstMisaligned(bytes: []const u8) !?usize {
    if (!std.mem.startsWith(u8, bytes, "!<arch>\n")) return error.NotAnArchive;
    var offset: usize = 8;
    while (offset + 60 <= bytes.len) {
        const header = bytes[offset .. offset + 60];
        const name = std.mem.trimEnd(u8, header[0..16], " ");
        var size = try std.fmt.parseInt(usize, std.mem.trimEnd(u8, header[48..58], " "), 10);
        var start = offset + 60;
        var member = name;
        if (std.mem.startsWith(u8, name, "#1/")) {
            const name_len = try std.fmt.parseInt(usize, name[3..], 10);
            member = bytes[start .. start + name_len];
            start += name_len;
            size -= name_len;
        }
        if (!std.mem.startsWith(u8, member, "__.SYMDEF") and start % 8 != 0) return start;
        offset = start + size;
        offset += offset & 1;
    }
    return null;
}

/// Runs `argv`, failing the test unless it exits 0.
///
/// Parameters:
/// - `io`: IO the child is spawned on.
/// - `argv`: the command.
///
/// Return: nothing; `error.TestExpectedEqual` on a non-zero exit, or spawn errors.
fn expectRun(io: std.Io, argv: []const []const u8) !void {
    var child = try std.process.spawn(io, .{ .argv = argv });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try child.wait(io));
}

test "script realigns a member Apple's linker would skip" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    try tmp.dir.writeFile(io, .{ .sub_path = "probe.c", .data = "int zigbuildx_probe(void) { return 42; }\n" });
    const source = try std.fs.path.join(allocator, &.{ root, "probe.c" });
    defer allocator.free(source);
    const object = try std.fs.path.join(allocator, &.{ root, "probe.o" });
    defer allocator.free(object);
    try expectRun(io, &.{ "clang", "-c", source, "-o", object });

    // A BSD archive by hand, with a 6-byte name so the object's data lands at
    // 8 + 60 + 6 = 74 — the same misalignment Zig's archiver produces.
    const object_bytes = try tmp.dir.readFileAlloc(io, "probe.o", allocator, .unlimited);
    defer allocator.free(object_bytes);
    var archive: std.Io.Writer.Allocating = .init(allocator);
    defer archive.deinit();
    try archive.writer.writeAll("!<arch>\n");
    try archive.writer.print("{s: <16}{s: <12}{s: <6}{s: <6}{s: <8}{d: <10}`\n", .{ "#1/6", "0", "0", "0", "644", object_bytes.len + 6 });
    try archive.writer.writeAll("pr.o\x00\x00");
    try archive.writer.writeAll(object_bytes);
    try tmp.dir.writeFile(io, .{ .sub_path = "in.a", .data = archive.written() });
    try std.testing.expectEqual(@as(?usize, 74), try firstMisaligned(archive.written()));

    const in = try std.fs.path.join(allocator, &.{ root, "in.a" });
    defer allocator.free(in);
    const out = try std.fs.path.join(allocator, &.{ root, "out.a" });
    defer allocator.free(out);
    try expectRun(io, &.{ "/bin/sh", "-c", Archive.script, "repack", in, out });

    const repacked = try tmp.dir.readFileAlloc(io, "out.a", allocator, .unlimited);
    defer allocator.free(repacked);
    try std.testing.expectEqual(@as(?usize, null), try firstMisaligned(repacked));
    try std.testing.expect(std.mem.indexOf(u8, repacked, "_zigbuildx_probe") != null);
}
