//! Barrel for `src/core/`: generic helpers the extensions share, knowing nothing of manifests.

const std = @import("std");

/// File-system primitives the extensions share.
pub const File = @import("file.zig").File;
/// Runs `git` for the build.
pub const Git = @import("git.zig").Git;
/// Where a new worktree's HEAD goes.
pub const WorktreeHead = @import("git.zig").WorktreeHead;

test {
    std.testing.refAllDecls(@This());
}
