const std = @import("std");

/// Reads the build runner's generated package table (`@import("root").dependencies`) at comptime.
pub const PackageTable = struct {
    const Self = @This();
    /// The comptime branches allowed per entry of the table, enough to compare paths of any length.
    pub const branches_per_package = 4096;

    /// Finds the table key of dependency `name` in one package's list.
    ///
    /// - `deps`: The package's dependencies (`root_deps`, or a package's `deps`), name then key.
    /// - `name`: The dependency's field name in that package's `build.zig.zon`.
    /// - Returns: The key; null when the list has no such name.
    pub fn findDependency(comptime deps: []const struct { []const u8, []const u8 }, comptime name: []const u8) ?[]const u8 {
        for (deps) |dep| {
            if (std.mem.eql(u8, dep[0], name)) return dep[1];
        }
        return null;
    }

    /// Reports whether an entry of the table is a lazy dependency not fetched yet.
    ///
    /// - `package`: The entry; the runner gives it a `build_root` only once the package is on disk.
    /// - Returns: `true` when it has none.
    pub fn isUnfetched(comptime package: type) bool {
        return !@hasDecl(package, "build_root");
    }

    /// Reports whether an entry of the table is a fetched package, not a `.path` one.
    ///
    /// - `build_root`: The entry's `build_root`: relative to the build's working directory, or absolute.
    /// - `key`: The entry's key: a hash for a fetched package, a path for a `.path` one.
    /// - Returns: `true` when the package sits at `zig-pkg/<key>` or a cache's `p/<key>`.
    pub fn isFetched(build_root: []const u8, key: []const u8) bool {
        // Not an equality test: a `.path` package's root is `<dir of the build>/<key>`, which is the
        // key itself only when `zig build` runs in the root package's own directory.
        if (!std.mem.endsWith(u8, build_root, key) or build_root.len == key.len) return false;
        const parent = build_root[0 .. build_root.len - key.len];
        if (!std.Io.Dir.path.isSep(parent[parent.len - 1])) return false;
        const store = std.Io.Dir.path.basename(parent[0 .. parent.len - 1]);
        return std.mem.eql(u8, store, "zig-pkg") or std.mem.eql(u8, store, "p");
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test "findDependency names a dependency's key, and null for an unknown name" {
    const deps: []const struct { []const u8, []const u8 } = &.{ .{ "liba", "../liba" }, .{ "fetched", "fetched-0.0.0" } };
    try std.testing.expectEqualStrings("../liba", PackageTable.findDependency(deps, "liba").?);
    try std.testing.expectEqualStrings("fetched-0.0.0", PackageTable.findDependency(deps, "fetched").?);
    try std.testing.expect(PackageTable.findDependency(deps, "unknown") == null);
}

test "isFetched tells a fetched package from a .path one, wherever zig build runs" {
    const hash = "zigbuildx-6.0.0-9koPhJjSBAAdyvyqYS1GYMx";
    try std.testing.expect(PackageTable.isFetched("zig-pkg/" ++ hash, hash));
    try std.testing.expect(PackageTable.isFetched("/abs/app/zig-pkg/" ++ hash, hash));
    try std.testing.expect(PackageTable.isFetched("/home/u/.cache/zig/p/" ++ hash, hash));
    try std.testing.expect(!PackageTable.isFetched("../liba", "../liba"));
    try std.testing.expect(!PackageTable.isFetched("/abs/app/../liba", "../liba"));
    try std.testing.expect(!PackageTable.isFetched("vendor", "vendor"));
    try std.testing.expect(!PackageTable.isFetched("/abs/app/vendor", "vendor"));
}

test "isUnfetched tells a lazy dependency not fetched yet from one on disk" {
    // Shaped as the build runner's package table writes them.
    const Unfetched = struct {
        const Self = @This();
        /// The runner knows the package but has not fetched it.
        pub const available = false;
    };
    const Fetched = struct {
        const Self = @This();
        /// The package is on disk.
        pub const available = true;
        /// Where it is.
        pub const build_root = "zig-pkg/lazy-0.0.0";
    };
    try std.testing.expect(PackageTable.isUnfetched(Unfetched));
    try std.testing.expect(!PackageTable.isUnfetched(Fetched));
}
