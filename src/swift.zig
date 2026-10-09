const std = @import("std");
const log = std.log.scoped(.zigbuildx_swift);

/// What `Swift.addDylib` compiles.
pub const SwiftDylib = struct {
    const Self = @This();
    /// The library's name: `afm` builds `libafm.dylib`, linked as `-lafm`.
    name: []const u8,
    /// The Swift sources, in `swiftc` argument order.
    sources: []const std.Build.LazyPath,
    /// A C header the Swift code imports, so it shares the C side's types rather
    /// than mirroring them and a layout change is a compile error, not a silent
    /// ABI mismatch.
    bridging_header: ?std.Build.LazyPath = null,
    /// The target: its architecture and macOS floor become `swiftc`'s `-target`.
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    swift_version: []const u8 = "6",
};

/// Builds a Swift dynamic library with `swiftc` and links Zig modules against it.
///
/// For a Zig package that reaches an Apple framework with no C API through a
/// small Swift shim exporting `@_cdecl` functions.
pub const Swift = struct {
    const Self = @This();

    /// Compiles `options.sources` into `lib<name>.dylib` and registers it as `lib<name>`.
    ///
    /// The install name is `@rpath/lib<name>.dylib`: without one, linked binaries
    /// record the dylib's cache path, which does not survive a cache clean. Every
    /// source and the bridging header are file arguments, so editing any of them
    /// — the header included — rebuilds the dylib, and `swiftc` finds them from
    /// whatever directory the root build runs in.
    ///
    /// Registering the dylib as a named lazy path is what lets a package that
    /// depends on this one find it through `Swift.fromDependency`.
    ///
    /// Parameters:
    /// - `b`: the build graph.
    /// - `options`: what to compile.
    ///
    /// Return: the dylib, or null when the target is not macOS or the host
    /// cannot run `swiftc`.
    pub fn addDylib(b: *std.Build, options: SwiftDylib) ?std.Build.LazyPath {
        const target = options.target.result;
        if (target.os.tag != .macos or b.graph.host.result.os.tag != .macos) return null;
        const file_name = b.fmt("lib{s}.dylib", .{options.name});
        const swiftc = b.addSystemCommand(&.{
            "swiftc",
            "-emit-library",
            "-parse-as-library",
            "-target",
            Self.triple(b.allocator, target) catch @panic("OOM"),
            "-swift-version",
            options.swift_version,
            switch (options.optimize) {
                .Debug => "-Onone",
                .ReleaseSmall => "-Osize",
                .ReleaseSafe, .ReleaseFast => "-O",
            },
            "-Xlinker",
            "-install_name",
            "-Xlinker",
            b.fmt("@rpath/{s}", .{file_name}),
        });
        swiftc.setName(b.fmt("swiftc {s}", .{file_name}));
        if (options.bridging_header) |header| {
            swiftc.addArg("-import-objc-header");
            swiftc.addFileArg(header);
        }
        swiftc.addArg("-o");
        const dylib = swiftc.addOutputFileArg(file_name);
        for (options.sources) |source| swiftc.addFileArg(source);
        b.addNamedLazyPath(b.fmt("lib{s}", .{options.name}), dylib);
        return dylib;
    }

    /// Links `module` against a dylib from `addDylib`, from the build cache and once installed.
    ///
    /// Two rpaths, because the binary runs from two places: the build cache under
    /// `zig build test`, and the install prefix, where `addInstall` puts the dylib
    /// beside `bin/`. The second is special, not a path: a path is normalized,
    /// which collapses `@executable_path/..` into a bare `lib` relative to
    /// wherever the binary is launched from.
    ///
    /// Parameters:
    /// - `module`: the module to link; mutated in place.
    /// - `name`: the library's name, as given to `addDylib`.
    /// - `dylib`: the dylib, or null to do nothing — `addDylib`'s answer off macOS.
    pub fn link(module: *std.Build.Module, name: []const u8, dylib: ?std.Build.LazyPath) void {
        const path = dylib orelse return;
        module.addLibraryPath(path.dirname());
        module.linkSystemLibrary(name, .{});
        module.addRPath(path.dirname());
        module.addRPathSpecial("@executable_path/../lib");
    }

    /// Creates a step installing the dylib under `lib/`, where `link`'s installed rpath looks.
    ///
    /// Parameters:
    /// - `b`: the build graph.
    /// - `name`: the library's name, as given to `addDylib`.
    /// - `dylib`: the dylib.
    ///
    /// Return: the install step, not yet attached to any step.
    pub fn addInstall(b: *std.Build, name: []const u8, dylib: std.Build.LazyPath) *std.Build.Step {
        return &b.addInstallLibFile(dylib, b.fmt("lib{s}.dylib", .{name})).step;
    }

    /// Returns the dylib a dependency built with `addDylib`.
    ///
    /// For a consumer that installs its own executables, which must install the
    /// dependency's dylib beside them.
    ///
    /// Parameters:
    /// - `dep`: the dependency.
    /// - `name`: the library's name, as the dependency gave it to `addDylib`.
    ///
    /// Return: the dylib, or null when the dependency built none — off macOS.
    pub fn fromDependency(dep: *std.Build.Dependency, name: []const u8) ?std.Build.LazyPath {
        // Not `dep.namedLazyPath`, which panics on a name it cannot find, and off
        // macOS nothing is ever registered.
        const lib_name = dep.builder.fmt("lib{s}", .{name});
        const dylib = dep.builder.named_lazy_paths.get(lib_name);
        if (dylib == null) log.debug("{s} registered no {s}", .{ dep.builder.dep_prefix, lib_name });
        return dylib;
    }

    /// Returns `swiftc`'s `-target` for `target`: `<arch>-apple-macos<major>.<minor>`.
    ///
    /// The version is the target's own macOS floor — `Xcode.standardTargetOptions`
    /// sets it — so the Swift side and the Zig side state the same minimum.
    ///
    /// Parameters:
    /// - `allocator`: owns the returned string.
    /// - `target`: a macOS target.
    ///
    /// Return: the triple; allocation errors.
    fn triple(allocator: std.mem.Allocator, target: std.Target) ![]u8 {
        const arch = switch (target.cpu.arch) {
            .aarch64 => "arm64",
            else => @tagName(target.cpu.arch),
        };
        const min = target.os.version_range.semver.min;
        return std.fmt.allocPrint(allocator, "{s}-apple-macos{d}.{d}", .{ arch, min.major, min.minor });
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test "triple carries the target's arch and macOS floor" {
    const io = std.testing.io;
    const arm = try std.zig.system.resolveTargetQuery(io, .{ .cpu_arch = .aarch64, .os_tag = .macos, .os_version_min = .{ .semver = .{ .major = 26, .minor = 0, .patch = 0 } } });
    const intel = try std.zig.system.resolveTargetQuery(io, .{ .cpu_arch = .x86_64, .os_tag = .macos, .os_version_min = .{ .semver = .{ .major = 14, .minor = 2, .patch = 0 } } });
    const allocator = std.testing.allocator;
    const arm_triple = try Swift.triple(allocator, arm);
    defer allocator.free(arm_triple);
    const intel_triple = try Swift.triple(allocator, intel);
    defer allocator.free(intel_triple);
    try std.testing.expectEqualStrings("arm64-apple-macos26.0", arm_triple);
    try std.testing.expectEqualStrings("x86_64-apple-macos14.2", intel_triple);
}
