//! Barrel for `src/`: each folder as a namespace (`mod.deps.Deps`, `mod.core.Git`); what the tests compile.

const std = @import("std");
const builtin = @import("builtin");

/// Whether this code is compiled in Debug mode.
pub const is_debug = builtin.mode == .debug;

/// Generic helpers the extensions share, knowing nothing of manifests: `File`, `Git`.
pub const core = @import("core/module.zig");
/// Sibling and worktree dependencies, distribution builds and vendoring: `Deps`, `Sync`, `Stage`, `Vendor`, ….
pub const deps = @import("deps/module.zig");
/// Target platforms' SDKs and toolchains, and the app laid out as each runs it: `Xcode`, `Swift`, `App`, `Android`.
pub const platform = @import("platform/module.zig");
/// Zig's generated documentation, extended and served: `Docs`, `DocsServer`.
pub const docs = @import("docs/module.zig");
/// Fixtures for the tests: `TestTree`, `ZipBuilder`.
pub const testing = @import("testing/module.zig");
/// The host tool's command dispatch.
pub const Tool = @import("tool.zig").Tool;

test {
    std.testing.refAllDecls(@This());
}
