//! Barrel for `src/docs/`: Zig's generated documentation, extended and served.

const std = @import("std");

/// Extends Zig's generated documentation.
pub const Docs = @import("docs.zig").Docs;
/// Serves an autodoc site on loopback for `Docs.addServe`.
pub const DocsServer = @import("docs_server.zig").DocsServer;

// Other folders, for this folder's files.

/// Dependencies, distribution builds and vendoring: `Deps`, `Sync`, `Mode`, `ToolArtifact`, ….
pub const deps = @import("../module.zig").deps;

test {
    std.testing.refAllDecls(@This());
}
