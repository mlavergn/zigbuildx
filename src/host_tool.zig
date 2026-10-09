const std = @import("std");
const mod = @import("module.zig");

/// Returns zigbuildx's own program, built for the build host.
///
/// Some extensions do their work in a program rather than a shell command, so
/// it behaves the same on every host and needs nothing installed; and since
/// Zig 0.17 a step can no longer run code of its own, so work that must happen
/// while the build runs (packaging, listing worktrees) is done by it too. It
/// is one program, `src/tool.zig`, with a command per job; zigbuildx's
/// `build.zig` declares it, and a consumer's build compiles and caches it like
/// any other artifact.
pub const HostTool = struct {
    const Self = @This();

    /// The executable's name, and the artifact name `build.zig` installs it under.
    pub const name = "zigbuildx";

    /// Returns the host tool, from the zigbuildx package this code belongs to.
    ///
    /// The package is found by identity, not by name: the consumer may call
    /// its zigbuildx dependency anything, and two packages in one build may
    /// each depend on a different zigbuildx. The one whose `build.zig`
    /// re-exports this very `Deps` is this one.
    ///
    /// Parameters:
    /// - `b`: the build graph of a package that depends on zigbuildx.
    ///
    /// Return: the executable; panics when `b`'s package does not depend on
    /// this zigbuildx, or outside a build runner.
    pub fn add(b: *std.Build) *std.Build.Step.Compile {
        const root = @import("root");
        if (comptime !@hasDecl(root, "dependencies")) @panic("HostTool.add runs only in a build runner");
        const packages = root.dependencies.packages;
        inline for (@typeInfo(packages).@"struct".decl_names) |decl_name| {
            const package = @field(packages, decl_name);
            if (comptime Self.isSelf(package)) return b.dependencyFromBuildZig(package.build_zig, .{}).artifact(Self.name);
        }
        @panic("zigbuildx is not among the build's packages");
    }

    /// Reports whether `package`, an entry of the build runner's package table, is this zigbuildx.
    ///
    /// Parameters:
    /// - `package`: the entry.
    ///
    /// Return: `true` when its `build.zig` re-exports this module's `Deps`.
    fn isSelf(comptime package: type) bool {
        if (!@hasDecl(package, "build_zig")) return false;
        const build_zig = package.build_zig;
        return @hasDecl(build_zig, "Deps") and @TypeOf(build_zig.Deps) == type and build_zig.Deps == mod.Deps;
    }
};
