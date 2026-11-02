const std = @import("std");
const mod = @import("module.zig");

/// A worktree dependency's pin.
pub const Pin = struct {
    const Self = @This();
    /// Whether `value` is a SHA, a tag or a branch.
    kind: mod.PinKind,
    /// The SHA, tag or branch.
    value: []const u8,

    /// Reports whether a stamp recorded for `self` still satisfies `wanted`.
    ///
    /// - `self`: The pin a stamp recorded.
    /// - `wanted`: The pin the manifest asks for now.
    /// - Returns: `true` when the kinds and values match.
    pub fn satisfies(self: *const Self, wanted: Pin) bool {
        return self.kind == wanted.kind and std.mem.eql(u8, self.value, wanted.value);
    }

    /// Reports whether the worktree sits on a branch rather than a detached HEAD.
    ///
    /// - `self`: The pin.
    /// - Returns: `true` for `.branch`.
    pub fn follows(self: *const Self) bool {
        return self.kind == .branch;
    }

    /// Reports whether `value` may name a SHA, tag or branch.
    ///
    /// - `value`: A `.sha`, `.tag` or `.branch` from a manifest.
    /// - Returns: `false` for an empty value or one git could read as an option.
    pub fn isValidValue(value: []const u8) bool {
        // A value git could read as an option (`-f`, `--orphan`) is no ref name git accepts either.
        return value.len > 0 and value[0] != '-';
    }
};
