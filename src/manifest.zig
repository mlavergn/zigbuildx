const std = @import("std");
const mod = @import("module.zig");

/// The parts of a `build.zig.zon` `Deps` reads at run time.
///
/// The root's manifest is also available at comptime, but a transitive
/// dependency's is not: it may not exist until `Deps` creates its worktree.
/// Reading every manifest from disk keeps one code path for both.
pub const Manifest = struct {
    const Self = @This();
    /// The largest `build.zig.zon` read; a manifest is a few kilobytes.
    pub const max_bytes = 1 << 20;
    /// The package's `.name`.
    name: []const u8,
    /// The package's `.version`; empty when it has none.
    version: []const u8 = "",
    /// The package's `.dependencies`, in manifest order.
    entries: []const mod.Entry,

    /// Parses a manifest's `.name`, `.version` and `.dependencies`, ignoring every other field.
    ///
    /// - `allocator`: Allocator for the result; use an arena, as nothing is freed individually.
    /// - `source`: The manifest text.
    /// - Returns: The manifest; `error.InvalidManifest` when it is not ZON of the expected shape.
    pub fn parse(allocator: std.mem.Allocator, source: [:0]const u8) !Self {
        var ast = try std.zig.Ast.parse(allocator, source, .{ .mode = .zon });
        defer ast.deinit(allocator);
        if (ast.errors.len > 0) return error.InvalidManifest;
        const zoir = try std.zig.ZonGen.generate(allocator, ast, .{});
        defer zoir.deinit(allocator);
        if (zoir.hasCompileErrors()) return error.InvalidManifest;
        const top = switch (std.zig.Zoir.Node.Index.root.get(&zoir)) {
            .struct_literal => |fields| fields,
            else => return error.InvalidManifest,
        };
        var self = Self{ .name = "", .entries = &.{} };
        for (top.names, 0..) |key, i| {
            const value = top.vals.at(@intCast(i)).get(&zoir);
            if (std.mem.eql(u8, key.get(&zoir), "name")) {
                self.name = try allocator.dupe(u8, switch (value) {
                    .enum_literal => |name| name.get(&zoir),
                    .string_literal => |name| name,
                    else => return error.InvalidManifest,
                });
            } else if (std.mem.eql(u8, key.get(&zoir), "version")) {
                self.version = try allocator.dupe(u8, switch (value) {
                    .string_literal => |version| version,
                    else => return error.InvalidManifest,
                });
            } else if (std.mem.eql(u8, key.get(&zoir), "dependencies")) {
                self.entries = try Self.parseEntries(allocator, &zoir, value);
            }
        }
        return self;
    }

    /// Parses the `.dependencies` struct literal.
    ///
    /// - `allocator`: Allocator for the result.
    /// - `zoir`: The manifest's ZON IR.
    /// - `node`: The `.dependencies` value.
    /// - Returns: The entries; `error.InvalidManifest` when a dependency is not a struct literal.
    fn parseEntries(allocator: std.mem.Allocator, zoir: *const std.zig.Zoir, node: std.zig.Zoir.Node) ![]const mod.Entry {
        const deps = switch (node) {
            .struct_literal => |fields| fields,
            .empty_literal => return &.{},
            else => return error.InvalidManifest,
        };
        const entries = try allocator.alloc(mod.Entry, deps.names.len);
        for (deps.names, entries, 0..) |name, *entry, i| {
            entry.* = .{ .name = try allocator.dupe(u8, name.get(zoir)) };
            const fields = switch (deps.vals.at(@intCast(i)).get(zoir)) {
                .struct_literal => |fields| fields,
                .empty_literal => continue,
                else => return error.InvalidManifest,
            };
            for (fields.names, 0..) |key, j| {
                const text = switch (fields.vals.at(@intCast(j)).get(zoir)) {
                    .string_literal => |text| text,
                    .true => {
                        if (std.mem.eql(u8, key.get(zoir), "lazy")) entry.lazy = true;
                        continue;
                    },
                    else => continue,
                };
                inline for (.{ "url", "hash", "path", "clone", "archive", "checkout", "sha", "tag", "branch" }) |field| {
                    if (std.mem.eql(u8, key.get(zoir), field)) @field(entry, field) = try allocator.dupe(u8, text);
                }
            }
        }
        return entries;
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test "Manifest reads the name, version and dependencies and ignores other fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try Manifest.parse(arena.allocator(),
        \\.{
        \\    .name = .consumer,
        \\    .version = "0.0.0",
        \\    .fingerprint = 0x1234,
        \\    .dependencies = .{
        \\        .leaf = .{ .path = "deps/leaf", .tag = "v1", .lazy = true },
        \\        .fetched = .{ .url = "https://example.com/x.tar.gz", .hash = "x" },
        \\    },
        \\    .paths = .{""},
        \\}
    );
    try std.testing.expectEqualStrings("consumer", manifest.name);
    try std.testing.expectEqualStrings("0.0.0", manifest.version);
    try std.testing.expectEqualStrings("x", manifest.entries[1].hash.?);
    try std.testing.expectEqual(2, manifest.entries.len);
    try std.testing.expectEqualStrings("leaf", manifest.entries[0].name);
    try std.testing.expectEqualStrings("deps/leaf", manifest.entries[0].path.?);
    try std.testing.expectEqualStrings("v1", manifest.entries[0].tag.?);
    try std.testing.expectEqual(null, manifest.entries[1].path);
    try std.testing.expectError(error.InvalidManifest, Manifest.parse(arena.allocator(), ".{ .name = "));
}
