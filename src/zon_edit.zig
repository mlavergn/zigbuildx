const std = @import("std");

/// Edits a `build.zig.zon` in place, as text.
///
/// Each edit replaces one dependency's value and leaves every other byte as
/// it was: formatting, comments and the other entries survive, which
/// re-serializing the parsed manifest would lose.
pub const ZonEdit = struct {
    const Self = @This();

    /// Replaces the value of dependency `name` in `source` with `value`.
    ///
    /// - `allocator`: Allocator for the parse and the result.
    /// - `source`: A `build.zig.zon`.
    /// - `name`: The dependency's field name in `.dependencies`.
    /// - `value`: ZON text for its new value, such as `.{ .url = "…", .hash = "…" }`.
    /// - Returns: The edited text, owned by the caller, or `null` when `source` has no such dependency; `error.InvalidManifest` when it does not parse.
    pub fn replaceDependency(allocator: std.mem.Allocator, source: [:0]const u8, name: []const u8, value: []const u8) !?[:0]u8 {
        var tree = try std.zig.Ast.parse(allocator, source, .{ .mode = .zon });
        defer tree.deinit(allocator);
        if (tree.errors.len > 0) return error.InvalidManifest;
        const dependencies = Self.field(&tree, tree.rootDecls()[0], "dependencies") orelse return null;
        const node = Self.field(&tree, dependencies, name) orelse return null;
        const start = tree.tokenStart(tree.firstToken(node));
        const last = tree.lastToken(node);
        const end = tree.tokenStart(last) + tree.tokenSlice(last).len;
        return try std.mem.concatWithSentinel(allocator, u8, &.{ source[0..start], value, source[end..] }, 0);
    }

    /// Finds the value of field `name` in the struct literal `node`.
    ///
    /// - `tree`: The parsed manifest.
    /// - `node`: A struct literal, such as the manifest itself.
    /// - `name`: The field.
    /// - Returns: The field's value node, or `null` when `node` is no struct literal or has no such field.
    fn field(tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index, name: []const u8) ?std.zig.Ast.Node.Index {
        var buffer: [2]std.zig.Ast.Node.Index = undefined;
        const init = tree.fullStructInit(&buffer, node) orelse return null;
        for (init.ast.fields) |value| {
            // `.name = value`: the name is the token two before the value's first.
            const token = tree.tokenSlice(tree.firstToken(value) - 2);
            // A name that is no identifier is quoted: `.@"my-dep"`.
            const bare = if (std.mem.startsWith(u8, token, "@\"")) token[2 .. token.len - 1] else token;
            if (std.mem.eql(u8, bare, name)) return value;
        }
        return null;
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test "replaceDependency swaps one entry's value and keeps every other byte" {
    const allocator = std.testing.allocator;
    const source =
        \\.{
        \\    .name = .app,
        \\    // the siblings
        \\    .dependencies = .{
        \\        .liba = .{ .path = "../liba", .clone = "git@host:org/liba.git" },
        \\        .@"lib-b" = .{
        \\            .path = "../lib-b",
        \\            .tag = "v1.0.0", // a release
        \\        },
        \\        .fetched = .{ .url = "https://example.com/x.tar.gz", .hash = "x" },
        \\    },
        \\}
        \\
    ;
    const first = (try ZonEdit.replaceDependency(allocator, source, "liba", ".{ .url = \"git+ssh://a#1\", .hash = \"a-1\" }")).?;
    defer allocator.free(first);
    const second = (try ZonEdit.replaceDependency(allocator, first, "lib-b", ".{ .url = \"git+ssh://b#2\", .hash = \"b-2\" }")).?;
    defer allocator.free(second);
    try std.testing.expectEqualStrings(
        \\.{
        \\    .name = .app,
        \\    // the siblings
        \\    .dependencies = .{
        \\        .liba = .{ .url = "git+ssh://a#1", .hash = "a-1" },
        \\        .@"lib-b" = .{ .url = "git+ssh://b#2", .hash = "b-2" },
        \\        .fetched = .{ .url = "https://example.com/x.tar.gz", .hash = "x" },
        \\    },
        \\}
        \\
    , second);
}

test "replaceDependency reports a missing entry and a manifest that does not parse" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(null, try ZonEdit.replaceDependency(allocator, ".{ .dependencies = .{ .a = .{} } }", "b", ".{}"));
    try std.testing.expectEqual(null, try ZonEdit.replaceDependency(allocator, ".{ .name = .x }", "a", ".{}"));
    try std.testing.expectError(error.InvalidManifest, ZonEdit.replaceDependency(allocator, ".{ .dependencies = ", "a", ".{}"));
}
