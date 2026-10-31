const std = @import("std");
const mod = @import("module.zig");

/// What `Deps` records about a worktree it made, in `<deps>/.zigbuildx/<name>.rev`.
///
/// The steady state compares this file with the manifest and runs no `git`.
pub const Stamp = struct {
    const Self = @This();
    /// The largest stamp read; one is five short lines.
    pub const max_bytes = 1 << 16;
    /// The pin the worktree was made for.
    pin: mod.Pin,
    /// HEAD when the worktree was created, moved or updated.
    sha: []const u8,
    /// The branch the worktree is on; empty when detached.
    branch: []const u8,
    /// The shared checkout that owns the worktree.
    checkout: []const u8,

    /// Parses a stamp file: kind, value, SHA, branch and checkout, one per line.
    ///
    /// - `text`: The file contents; the result borrows from it.
    /// - Returns: The stamp; `null` when the file is not a stamp.
    pub fn parse(text: []const u8) ?Self {
        var lines = std.mem.splitScalar(u8, text, '\n');
        const kind = std.meta.stringToEnum(mod.PinKind, lines.next() orelse return null) orelse return null;
        const value = lines.next() orelse return null;
        const sha = lines.next() orelse return null;
        const branch = lines.next() orelse return null;
        const checkout = lines.next() orelse return null;
        if (sha.len == 0 or checkout.len == 0) return null;
        return .{ .pin = .{ .kind = kind, .value = value }, .sha = sha, .branch = branch, .checkout = checkout };
    }

    /// Formats the stamp for its file.
    ///
    /// - `self`: The stamp.
    /// - `allocator`: Allocator for the text.
    /// - Returns: The text, owned by the caller.
    pub fn serialize(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        return allocator.print("{t}\n{s}\n{s}\n{s}\n{s}\n", .{ self.pin.kind, self.pin.value, self.sha, self.branch, self.checkout });
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test "Stamp round-trips" {
    const stamp = Stamp{ .pin = .{ .kind = .branch, .value = "main" }, .sha = "abc", .branch = "c/main", .checkout = "/x/leaf" };
    const text = try stamp.serialize(std.testing.allocator);
    defer std.testing.allocator.free(text);
    const parsed = Stamp.parse(text).?;
    try std.testing.expectEqual(mod.PinKind.branch, parsed.pin.kind);
    try std.testing.expectEqualStrings("main", parsed.pin.value);
    try std.testing.expectEqualStrings("c/main", parsed.branch);
    try std.testing.expectEqualStrings("/x/leaf", parsed.checkout);
    try std.testing.expectEqual(null, Stamp.parse("bogus\n"));
    try std.testing.expect(parsed.pin.satisfies(.{ .kind = .branch, .value = "main" }));
    try std.testing.expect(!parsed.pin.satisfies(.{ .kind = .tag, .value = "main" }));
}
