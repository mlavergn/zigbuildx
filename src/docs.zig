const std = @import("std");
const log = std.log.scoped(.zigbuildx_docs);
const mod = @import("module.zig");

/// Extends Zig's generated documentation.
///
/// Zig's autodoc already collects private declarations; the shipped front end
/// asks the wasm side for public members only, at two call sites. Flipping
/// their `include_private` argument documents everything, as Swift's
/// `--symbol-graph-minimum-access-level internal` does. Only the emitted copy
/// is changed, never the toolchain.
///
/// The patching is done by the host tool's `docs-patch` command, which copies
/// an autodoc site, patching its `main.js`.
pub const Docs = struct {
    const Self = @This();

    /// The two call sites in Zig 0.17.0's `lib/docs/main.js`, and what each becomes.
    pub const replacements = [_][2][]const u8{
        .{ "type_fn_members(decl_index, false)", "type_fn_members(decl_index, true)" },
        .{ "namespaceMembers(decl_index, false)", "namespaceMembers(decl_index, true)" },
    };

    /// Returns autodoc site `docs` with private declarations listed alongside public ones.
    /// Fails the build when Zig's front end no longer has the code it patches.
    ///
    /// Parameters:
    /// - `b`: the build graph.
    /// - `docs`: an emitted site, from `getEmittedDocs()`.
    ///
    /// Return: the patched site's directory, for `b.addInstallDirectory`.
    pub fn includePrivate(b: *std.Build, docs: std.Build.LazyPath) std.Build.LazyPath {
        // Zig's autodoc renders public declarations only; the host tool copies the site, patching `main.js`.
        const run = b.addRunArtifact(mod.ToolArtifact.add(b));
        run.setName("docs include private");
        run.addArg("docs-patch");
        run.addDirectoryArg2(docs, .{});
        return run.addOutputDirectoryArg2("docs", .{});
    }

    /// Returns `js` with each replacement applied; each pattern must occur exactly once.
    ///
    /// Parameters:
    /// - `allocator`: owns the result.
    /// - `js`: the contents of `main.js`.
    ///
    /// Return: the patched script; `error.AutodocChanged` when a pattern is missing or repeated.
    pub fn patch(allocator: std.mem.Allocator, js: []const u8) ![]u8 {
        var current = try allocator.dupe(u8, js);
        errdefer allocator.free(current);
        for (Self.replacements) |replacement| {
            // Any count but one means the front end changed, and patching blindly could leave
            // private members hidden, or break the site, with nothing reported.
            const count = std.mem.count(u8, current, replacement[0]);
            if (count != 1) {
                log.err("main.js has {d} occurrences of '{s}', expected 1: Zig's autodoc changed", .{ count, replacement[0] });
                return error.AutodocChanged;
            }
            const next = try std.mem.replaceOwned(u8, allocator, current, replacement[0], replacement[1]);
            allocator.free(current);
            current = next;
        }
        return current;
    }

    /// `zigbuildx docs-patch <in-dir> <out-dir>`: copies the autodoc site at `in-dir`, patching `main.js`.
    ///
    /// Parameters:
    /// - `process_init`: the process's allocator and IO.
    /// - `args`: the command line after the program's path; `args[0]` is the command.
    ///
    /// Return: nothing; `error.InvalidArguments`, `error.AutodocChanged` when `main.js` is unpatchable, or IO errors.
    pub fn command(process_init: std.process.Init, args: []const [:0]const u8) !void {
        const allocator = process_init.gpa;
        const io = process_init.io;
        if (args.len != 3) {
            log.err("usage: zigbuildx docs-patch <in-dir> <out-dir>", .{});
            return error.InvalidArguments;
        }
        const cwd = std.Io.Dir.cwd();
        var in = try cwd.openDir(io, args[1], .{ .iterate = true });
        defer in.close(io);
        try cwd.createDirPath(io, args[2]);
        var out = try cwd.openDir(io, args[2], .{});
        defer out.close(io);

        var patched = false;
        var walker = try in.walk(allocator);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            switch (entry.kind) {
                .directory => try out.createDirPath(io, entry.path),
                .file => {
                    const data = try in.readFileAlloc(io, entry.path, allocator, .unlimited);
                    defer allocator.free(data);
                    if (!std.mem.eql(u8, entry.path, "main.js")) {
                        try out.writeFile(io, .{ .sub_path = entry.path, .data = data });
                        continue;
                    }
                    const js = try Self.patch(allocator, data);
                    defer allocator.free(js);
                    try out.writeFile(io, .{ .sub_path = entry.path, .data = js });
                    patched = true;
                },
                else => {},
            }
        }
        if (!patched) {
            log.err("{s} has no main.js: not an autodoc site", .{args[1]});
            return error.AutodocChanged;
        }
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test "patch flips both call sites" {
    const allocator = std.testing.allocator;
    const js =
        \\const members = unwrapSlice32(wasm_exports.type_fn_members(decl_index, false)).slice();
        \\const members = namespaceMembers(decl_index, false).slice();
        \\function namespaceMembers(decl_index, include_private) {}
    ;
    const out = try Docs.patch(allocator, js);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "type_fn_members(decl_index, true)") != null);
    try std.testing.expect(std.mem.find(u8, out, "namespaceMembers(decl_index, true)") != null);
    try std.testing.expect(std.mem.find(u8, out, "decl_index, false") == null);
    try std.testing.expect(std.mem.find(u8, out, "function namespaceMembers(decl_index, include_private)") != null);
}
