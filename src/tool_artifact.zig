const std = @import("std");
const mod = @import("module.zig");

/// Finds the build artifact of zigbuildx's own program, `Tool`, for a consumer's build graph.
///
/// `Tool` is the program, run by `Run` steps while the build runs; this is
/// what a consumer's `build()` asks for it with, while the graph is declared.
/// Since Zig 0.17 a step cannot run code of its own, so work that must happen
/// while the build runs (listing worktrees, pinning zigbuildx, patching docs) is
/// done by the program, which also behaves the same on every host and needs
/// no shell tools. It is built for the build host, never the target:
/// zigbuildx's `build.zig` declares it, and a consumer's build compiles and
/// caches it like any other artifact.
pub const ToolArtifact = struct {
    const Self = @This();

    /// The executable's name, and the artifact name `build.zig` installs it under.
    pub const name = "zigbuildx";

    /// Returns the host tool of the zigbuildx package this code belongs to, whatever the consumer named it.
    ///
    /// Parameters:
    /// - `b`: the build graph of a package that depends on zigbuildx.
    ///
    /// Return: the executable; panics when `b`'s package does not depend on this zigbuildx.
    pub fn add(b: *std.Build) *std.Build.Step.Compile {
        const root = @import("root");
        if (comptime !@hasDecl(root, "dependencies")) @panic("ToolArtifact.add runs only in a build runner");
        const packages = root.dependencies.packages;
        // By identity, not name: two packages in one build may each depend on a different zigbuildx.
        inline for (@typeInfo(packages).@"struct".decl_names) |decl_name| {
            const package = @field(packages, decl_name);
            if (comptime Self.isSelf(package)) return b.dependencyFromBuildZig(package.build_zig, .{}).artifact(Self.name);
        }
        @panic("zigbuildx is not among the build's packages");
    }

    /// Names this zigbuildx among the root package's own dependencies.
    ///
    /// Return: the field `build.zig.zon` gives it, or null when the root does not list it itself.
    pub fn dependencyName() ?[]const u8 {
        const root = @import("root");
        if (comptime !@hasDecl(root, "dependencies")) return null;
        inline for (root.dependencies.root_deps) |dep| {
            if (comptime Self.isSelf(@field(root.dependencies.packages, dep[1]))) return dep[0];
        }
        return null;
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
