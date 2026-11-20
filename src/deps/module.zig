//! Barrel for `src/deps/`: sibling and worktree dependencies, distribution builds and vendoring.

const std = @import("std");

/// Clones sibling checkouts and keeps worktree dependencies pinned.
pub const Deps = @import("deps.zig").Deps;
/// One run of `Deps.sync`: brings the worktrees in line with the manifests.
pub const Sync = @import("sync.zig").Sync;
/// How `Deps` treats sibling checkouts.
pub const Mode = @import("mode.zig").Mode;
/// What `Sync.update` did to the worktrees that follow a branch.
pub const Updated = @import("updated.zig").Updated;
/// The parts of a `build.zig.zon` `Deps` reads at run time.
pub const Manifest = @import("manifest.zig").Manifest;
/// One dependency of a `build.zig.zon`.
pub const Entry = @import("entry.zig").Entry;
/// A worktree dependency's pin.
pub const Pin = @import("pin.zig").Pin;
/// What a worktree dependency is pinned to.
pub const PinKind = @import("pin_kind.zig").PinKind;
/// What a worktree's stamp records.
pub const Stamp = @import("stamp.zig").Stamp;
/// Reads the `git+` URLs and tag listings `Deps.pin` works from.
pub const ReleasePin = @import("release_pin.zig").ReleasePin;
/// Stages siblings into Zig's package store for a distribution build.
pub const Stage = @import("stage.zig").Stage;
/// Writes a consumer's self-contained source tarball for `zig build vendor`.
pub const Vendor = @import("vendor.zig").Vendor;
/// Where an absent `.path` dependency comes from.
pub const Source = @import("source.zig").Source;
/// Edits a `build.zig.zon` in place, as text.
pub const ZonEdit = @import("zon_edit.zig").ZonEdit;
/// Downloads and unpacks a `.archive` dependency.
pub const ZipArchive = @import("zip_archive.zig").ZipArchive;
/// Reads the build runner's generated package table at comptime.
pub const PackageTable = @import("package_table.zig").PackageTable;
/// Imports a dependency's `build.zig`, null while a `.path` one is missing.
pub const LazyImport = @import("lazy_import.zig").LazyImport;
/// Finds the host tool's artifact for a consumer's build graph.
pub const ToolArtifact = @import("tool_artifact.zig").ToolArtifact;

// Other folders, for this folder's files.

/// Generic helpers: `File`, `Git`.
pub const core = @import("../module.zig").core;
/// Test fixtures: `TestTree`, `ZipBuilder`.
pub const testing = @import("../module.zig").testing;

test {
    std.testing.refAllDecls(@This());
}
