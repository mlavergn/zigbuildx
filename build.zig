const std = @import("std");

const builtin = @import("builtin");

const mod = @import("src/module.zig");

// zigbuildx targets one Zig release: std.Build moves between releases, and
// several extensions work around defects in this one. A clear error here beats
// an API mismatch reported from deep inside an extension.
comptime {
    const zig = builtin.zig_version;
    if (zig.major != 0 or zig.minor != 16) @compileError(std.fmt.comptimePrint("zigbuildx is for Zig 0.16.0; this is Zig {d}.{d}.{d}", .{ zig.major, zig.minor, zig.patch }));
}

/// Clones sibling checkouts and keeps worktree dependencies pinned; see `src/deps.zig`.
pub const Deps = mod.Deps;
/// Runs `git` for the build; see `src/git.zig`.
pub const Git = mod.Git;
/// Locates the macOS SDK and pins the macOS deployment floor; see `src/xcode.zig`.
pub const Xcode = mod.Xcode;
/// Re-lays static libraries so Apple's linker accepts them; see `src/archive.zig`.
pub const Archive = mod.Archive;
/// Builds Swift dylibs and links modules against them; see `src/swift.zig`.
pub const Swift = mod.Swift;
/// Builds Android native libraries; see `src/android.zig`.
pub const Android = mod.Android;
/// An Android ABI and its Zig target; see `src/android.zig`.
pub const AndroidAbi = mod.AndroidAbi;
/// Packages Android native libraries into a signed APK; see `src/pkg/android/apk.zig`.
pub const Apk = mod.pkg.android.Apk;
/// Extends Zig's generated documentation; see `src/docs.zig`.
pub const Docs = mod.Docs;
/// Builds installable packages (`zig build pkg`); see `src/pkg/pkg.zig`.
pub const Pkg = mod.pkg.Pkg;

/// Declares the test step for zigbuildx's own suite.
///
/// A consumer never runs this: it imports the package's `build.zig` by
/// dependency name and calls its extensions directly. The step exists so the
/// extensions are tested where they are written.
///
/// Parameters:
/// - `b`: the build graph the step is registered on.
///
/// Return: nothing.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Run unit tests that match filter");

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/module.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = if (test_filter) |filter| &.{filter} else &.{},
    });
    const run_tests = b.addRunArtifact(tests);
    run_tests.has_side_effects = true;
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
