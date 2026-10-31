const std = @import("std");
const builtin = @import("builtin");

/// Whether this code is compiled in Debug mode.
pub const is_debug = builtin.mode == .debug;

/// File-system primitives the extensions share.
pub const File = @import("file.zig").File;
/// Downloads and unpacks a `.archive` dependency.
pub const ZipArchive = @import("zip_archive.zig").ZipArchive;
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
/// Runs `git` for the build.
pub const Git = @import("git.zig").Git;
/// Where a new worktree's HEAD goes.
pub const WorktreeHead = @import("git.zig").WorktreeHead;
/// Locates an Apple platform's SDK and pins the macOS deployment floor.
pub const Xcode = @import("xcode.zig").Xcode;
/// What `Xcode.addXcframework` assembles.
pub const Xcframework = @import("xcode.zig").Xcframework;
/// Builds Swift dylibs and links modules against them.
pub const Swift = @import("swift.zig").Swift;
/// What `Swift.addDylib` compiles.
pub const SwiftDylib = @import("swift.zig").SwiftDylib;
/// Builds Android native libraries.
pub const Android = @import("android.zig").Android;
/// An Android ABI and its Zig target.
pub const AndroidAbi = @import("android_abi.zig").AndroidAbi;
/// Extends Zig's generated documentation.
pub const Docs = @import("docs.zig").Docs;
/// Finds the host tool's artifact for a consumer's build graph.
pub const ToolArtifact = @import("tool_artifact.zig").ToolArtifact;
/// The host tool's command dispatch.
pub const Tool = @import("tool.zig").Tool;
/// Builds in-memory zips for the tests.
pub const ZipBuilder = @import("zip_builder.zig").ZipBuilder;

test {
    std.testing.refAllDecls(@This());
}
