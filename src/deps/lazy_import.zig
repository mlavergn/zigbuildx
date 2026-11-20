// zlint-disable case-convention
// `lazyImport` stands in for std's `Build.lazyImport` and keeps its name and
// its `?type` result, an imported `build.zig`, not a type it makes.

const std = @import("std");
const log = std.log.scoped(.zigbuildx_lazy_import);
const mod = @import("module.zig");

/// `Deps.lazyImport`: std's `lazyImport`, minus its compile error for a
/// `.path` dependency missing from disk.
pub const LazyImport = struct {
    const Self = @This();

    /// Imports dependency `name`'s `build.zig` as `std.Build.lazyImport` does, but answers null for a `.path` dependency missing from disk.
    /// Call it after `cloneMissing` or `sync`, which fetch the dependency; the re-run imports it.
    ///
    /// - `b`: The build graph.
    /// - `asking_build_zig`: The `build.zig` asking, normally `@This()`.
    /// - `name`: The dependency's field name in that package's `build.zig.zon`.
    /// - Returns: Its `build.zig`; null while it is missing or not fetched yet.
    pub inline fn lazyImport(b: *std.Build, comptime asking_build_zig: type, comptime name: []const u8) ?type {
        // The runner marks a `.path` package available whatever is on disk, so std's `lazyImport` reaches its
        // `@compileError` before `build()` runs. Everything else (a lazy `.url` not fetched yet, an unknown name) is std's.
        return if (comptime Self.isMissingPath(@import("root"), asking_build_zig, name))
            Self.missingImport(b, asking_build_zig, name)
        else
            b.lazyImport(asking_build_zig, name);
    }

    /// Reports whether `asking_build_zig`'s dependency `name` is a `.path` package missing from disk, or without a `build.zig`.
    ///
    /// - `root`: The root module (`@import("root")`); a root that is not a build runner answers false.
    /// - `asking_build_zig`: The `build.zig` asking; the root's when no package has it.
    /// - `name`: The dependency's field name in that package's `build.zig.zon`.
    /// - Returns: `true` only for a `.path` package missing, or without a `build.zig`.
    fn isMissingPath(comptime root: type, comptime asking_build_zig: type, comptime name: []const u8) bool {
        if (!@hasDecl(root, "dependencies")) return false;
        const table = root.dependencies;
        // As `Deps.missingSibling`: comparing every package's whole key runs past the default quota.
        @setEvalBranchQuota(1000 + @typeInfo(table.packages).@"struct".decl_names.len * mod.PackageTable.branches_per_package);
        const asking_key = comptime Self.askingKey(table, asking_build_zig);
        const deps = if (asking_key.len == 0) table.root_deps else @field(table.packages, asking_key).deps;
        const found = comptime mod.PackageTable.findDependency(deps, name);
        const key = found orelse return false;
        const package = @field(table.packages, key);
        // The table cannot tell a missing directory from one without a `build.zig`; `Deps.missingSibling` treats them alike.
        // Present, or a lazy `.url` not fetched yet: std's to import or to fetch. Comptime, so `build_root` below is read only when declared.
        if (comptime @hasDecl(package, "build_zig") or mod.PackageTable.isUnfetched(package)) return false;
        // A fetched package without a `build.zig` never will have one: std's compile error says so.
        return !mod.PackageTable.isFetched(package.build_root, key);
    }

    /// Finds the table key of the package whose `build.zig` is `asking_build_zig`, as std's `lazyImport` does.
    ///
    /// - `table`: The runner's `dependencies`.
    /// - `asking_build_zig`: The `build.zig` asking.
    /// - Returns: The key; empty for the root, which no package has.
    fn askingKey(comptime table: type, comptime asking_build_zig: type) []const u8 {
        inline for (@typeInfo(table.packages).@"struct".decl_names) |key| {
            const package = @field(table.packages, key);
            if (@hasDecl(package, "build_zig") and package.build_zig == asking_build_zig) return key;
        }
        return "";
    }

    /// Warns that dependency `name` is missing, or has no `build.zig`; panics, as std does, when `asking_build_zig` is not `b`'s.
    ///
    /// - `b`: The build graph.
    /// - `asking_build_zig`: The `build.zig` asking.
    /// - `name`: The dependency's field name.
    /// - Returns: null.
    inline fn missingImport(b: *std.Build, comptime asking_build_zig: type, comptime name: []const u8) ?type {
        // Inline, as `lazyImport` is: a `?type` result makes an ordinary call comptime, where logging cannot run.
        const asking_key = comptime Self.askingKey(@import("root").dependencies, asking_build_zig);
        // std's own check: another package's `build.zig` would resolve `name` in another manifest.
        if (!std.mem.eql(u8, asking_key, b.pkg_hash)) {
            const build_zig_path = b.root.join(b.graph.arena, "build.zig") catch @panic("OOM");
            std.debug.panic("{} is not the struct that corresponds to {f}", .{ asking_build_zig, build_zig_path });
        }
        log.warn("dependency '{s}' is missing, or has no build.zig; it is fetched only when Deps.cloneMissing or Deps.sync runs before this import, then re-run zig build", .{name});
        return null;
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
}

/// A build runner's package table for the `lazyImport` tests: the shapes the
/// runner generates, one of each kind of entry.
const LazyImportFixture = struct {
    const Self = @This();

    /// The `build.zig` of the package the tests ask from.
    const AskingBuild = struct {
        const Self = @This();
    };

    /// A `build.zig` on disk.
    const PresentBuild = struct {
        const Self = @This();
    };

    /// The root module of a build runner.
    const Root = struct {
        const Self = @This();

        /// The runner's table.
        pub const dependencies = struct {
            const Self = @This();

            /// Every package, keyed by path or hash.
            pub const packages = struct {
                const Self = @This();

                /// A `.path` dependency on disk.
                pub const @"../present" = struct {
                    const Self = @This();
                    /// Where it is.
                    pub const build_root = "../present";
                    /// Its `build.zig`.
                    pub const build_zig = PresentBuild;
                    /// Its dependencies, name then key.
                    pub const deps: []const struct { []const u8, []const u8 } = &.{};
                };
                /// A lazy `.path` dependency whose directory is missing.
                pub const @"../missing" = struct {
                    const Self = @This();
                    /// The runner marks a `.path` package available whatever is on disk.
                    pub const available = true;
                    /// Where it would be.
                    pub const build_root = "../missing";
                    /// No manifest, so no dependencies.
                    pub const deps: []const struct { []const u8, []const u8 } = &.{};
                };
                /// A fetched `.url` dependency without a `build.zig`.
                pub const @"csrc-1.0.0-hash" = struct {
                    const Self = @This();
                    /// Where it was fetched to.
                    pub const build_root = "zig-pkg/csrc-1.0.0-hash";
                    /// Its dependencies, name then key.
                    pub const deps: []const struct { []const u8, []const u8 } = &.{};
                };
                /// A lazy `.url` dependency not fetched yet.
                pub const @"lazy-1.0.0-hash" = struct {
                    const Self = @This();
                    /// The runner knows the package but has not fetched it.
                    pub const available = false;
                };
                /// A package that asks for its own dependencies.
                pub const @"../asking" = struct {
                    const Self = @This();
                    /// Where it is.
                    pub const build_root = "../asking";
                    /// Its `build.zig`.
                    pub const build_zig = AskingBuild;
                    /// Its dependencies, name then key: its own name for the missing package.
                    pub const deps: []const struct { []const u8, []const u8 } = &.{.{ "mine", "../missing" }};
                };
            };
            /// The root's dependencies.
            pub const root_deps: []const struct { []const u8, []const u8 } = &.{
                .{ "present", "../present" },
                .{ "missing", "../missing" },
                .{ "lazy", "lazy-1.0.0-hash" },
                .{ "csrc", "csrc-1.0.0-hash" },
                .{ "asking", "../asking" },
            };
        };
    };

    /// The root's own `build.zig`: no package has it.
    const RootBuild = struct {
        const Self = @This();
    };
};

test "lazyImport answers null only for a missing .path dependency" {
    const Fixture = LazyImportFixture;
    try std.testing.expect(LazyImport.isMissingPath(Fixture.Root, Fixture.RootBuild, "missing"));
    try std.testing.expect(!LazyImport.isMissingPath(Fixture.Root, Fixture.RootBuild, "present"));
    // A lazy `.url` not fetched yet is std's: null, and fetched before the re-run.
    try std.testing.expect(!LazyImport.isMissingPath(Fixture.Root, Fixture.RootBuild, "lazy"));
    // A fetched package without a `build.zig` is std's, whose compile error says so.
    try std.testing.expect(!LazyImport.isMissingPath(Fixture.Root, Fixture.RootBuild, "csrc"));
    // A name the manifest lacks is std's, which names the manifest.
    try std.testing.expect(!LazyImport.isMissingPath(Fixture.Root, Fixture.RootBuild, "unknown"));
}

test "lazyImport resolves a name in the asking package's own manifest" {
    const Fixture = LazyImportFixture;
    // `mine` is the asking package's name for the missing `.path`; the root has no such name.
    try std.testing.expect(LazyImport.isMissingPath(Fixture.Root, Fixture.AskingBuild, "mine"));
    try std.testing.expect(!LazyImport.isMissingPath(Fixture.Root, Fixture.RootBuild, "mine"));
}

test "lazyImport leaves everything to std outside a build runner" {
    const NotARunner = struct {
        const Self = @This();
    };
    try std.testing.expect(!LazyImport.isMissingPath(NotARunner, LazyImportFixture.RootBuild, "missing"));
}

test "askingKey finds the asking package, and an empty key for the root" {
    const table = LazyImportFixture.Root.dependencies;
    try std.testing.expectEqualStrings("../asking", comptime LazyImport.askingKey(table, LazyImportFixture.AskingBuild));
    try std.testing.expectEqualStrings("", comptime LazyImport.askingKey(table, LazyImportFixture.RootBuild));
}
