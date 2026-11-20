//! Barrel for `src/testing/`: fixtures for the tests.

const std = @import("std");

/// Builds in-memory zips for the tests.
pub const ZipBuilder = @import("zip_builder.zig").ZipBuilder;
/// A scratch tree of git repositories and a consumer, for the tests.
pub const TestTree = @import("test_tree.zig").TestTree;

// Other folders, for this folder's files.

/// Generic helpers: `File`, `Git`.
pub const core = @import("../module.zig").core;
/// Dependencies, distribution builds and vendoring: `Deps`, `Sync`, `Mode`, `ToolArtifact`, ….
pub const deps = @import("../module.zig").deps;

test {
    std.testing.refAllDecls(@This());
}
