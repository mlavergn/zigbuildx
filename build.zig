const std = @import("std");
const mod = @import("src/module.zig");
const builtin = @import("builtin");

// zigbuildx targets one Zig release: std.Build moves between releases, and
// several extensions work around defects in this one. A clear error here beats
// an API mismatch reported from deep inside an extension.
comptime {
    const zig = builtin.zig_version;
    if (zig.major != 0 or zig.minor != 17) @compileError(std.fmt.comptimePrint("zigbuildx is for Zig 0.17.0; this is Zig {d}.{d}.{d}", .{ zig.major, zig.minor, zig.patch }));
}

/// Clones sibling checkouts and keeps worktree dependencies pinned; see `src/deps.zig`.
pub const Deps = mod.Deps;
/// Runs `git` for the build; see `src/git.zig`.
pub const Git = mod.Git;
/// Locates an Apple platform's SDK and pins the macOS deployment floor; see `src/xcode.zig`.
pub const Xcode = mod.Xcode;
/// Builds Swift dylibs and links modules against them; see `src/swift.zig`.
pub const Swift = mod.Swift;
/// Builds Android native libraries; see `src/android.zig`.
pub const Android = mod.Android;
/// An Android ABI and its Zig target; see `src/android.zig`.
pub const AndroidAbi = mod.AndroidAbi;
/// Extends Zig's generated documentation; see `src/docs.zig`.
pub const Docs = mod.Docs;

/// Declares zigbuildx's host tool and its own test step; a consumer never calls it.
///
/// - `b`: The build graph.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Run unit tests that match filter");
    // An option, not an environment variable: Zig 0.17 reuses a cached configure, whose Run steps keep the environment they were configured with.
    const vendor_check = b.option(bool, "vendor-check", "Also run the slow end-to-end test of zig build vendor (make vendor)") orelse false;

    // Installed, because an installed artifact is what `Dependency.artifact` finds
    // when an extension asks for the host tool (`src/tool_artifact.zig`).
    b.installArtifact(b.addExecutable(.{ .name = mod.ToolArtifact.name, .root_module = b.createModule(.{
        .root_source_file = b.path("src/tool.zig"),
        .target = b.graph.host,
        .optimize = .safe,
    }) }));

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
    // `Stage`'s tests hash packages with this `zig`; they skip without it, as under `make cross`.
    run_tests.setEnvironmentVariable("ZIGBUILDX_ZIG", b.graph.zig_exe);
    // Set either way, so a value in the configuring shell never decides it.
    run_tests.setEnvironmentVariable("ZIGBUILDX_VENDOR_CHECK", if (vendor_check) "1" else "0");
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
