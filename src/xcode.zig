const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.zigbuildx_xcode);

/// Locates the macOS SDK so a module can link against system frameworks.
pub const Xcode = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    io: std.Io,
    loaded: bool = false,
    /// The target the SDK was resolved for; valid only after `resolve`.
    // SAFETY: populated by resolve() before first read, guarded by `loaded`.
    target: std.Target = undefined,
    /// Absolute path of the SDK root, as `xcrun --show-sdk-path` reports it; valid only after `resolve`.
    // SAFETY: populated by resolve() before first read, guarded by `loaded`.
    sdk: []const u8 = undefined,
    /// The SDK's `System/Library/Frameworks`; valid only after `resolve`.
    // SAFETY: populated by resolve() before first read, guarded by `loaded`.
    frameworks: []const u8 = undefined,

    /// Creates an unresolved `Xcode` handle.
    ///
    /// Parameters:
    /// - `allocator`: allocator for the SDK paths; must outlive the handle.
    /// - `io`: IO for querying the host during `resolve`.
    ///
    /// Return: the handle; `target`, `sdk` and `frameworks` are unset until `resolve`.
    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Self {
        return Self{ .allocator = allocator, .io = io };
    }

    /// Frees the SDK paths when they were resolved.
    ///
    /// A handle made with `b.allocator` need not call this: the build's arena
    /// frees everything at once.
    ///
    /// Parameters:
    /// - `self`: the handle to release.
    pub fn deinit(self: *Self) void {
        if (!self.loaded) return;
        self.allocator.free(self.frameworks);
        self.allocator.free(self.sdk);
        self.loaded = false;
    }

    /// Resolves the Apple Silicon macOS target and SDK paths into the handle.
    ///
    /// Idempotent: a resolved handle returns at once, so one handle can serve
    /// every module in a build without spawning `xcrun` again.
    ///
    /// Zig 0.17 reuses a configured build graph until something it was told
    /// about changes, and `xcrun`'s answer is not something it can see. The
    /// SDK's path carries its version (`MacOSX27.0.sdk`), so the SDK's
    /// `SDKSettings.json` is made a configure input: an Xcode update removes
    /// the path, and the next build configures again.
    ///
    /// Parameters:
    /// - `self`: the handle to populate.
    /// - `b`: the build graph, which records the SDK as a configure input.
    ///
    /// Return: nothing on success; `error.FailedToResolveSDK` when no SDK is
    /// found, or target-resolution errors.
    pub fn resolve(self: *Self, b: *std.Build) !void {
        if (self.loaded) return;
        try self.resolveSdk();
        b.dependOnFileMetadata(b.graph.cwdRelativePath(b.pathJoin(&.{ self.sdk, "SDKSettings.json" })));
    }

    /// Asks `xcrun` for the SDK and fills in the handle; `resolve` without the build graph.
    ///
    /// Parameters:
    /// - `self`: the handle to populate.
    ///
    /// Return: nothing on success; `error.FailedToResolveSDK` when no SDK is
    /// found, or target-resolution errors.
    fn resolveSdk(self: *Self) !void {
        if (self.loaded) return;
        // Always aarch64-macos, whatever the build target: the SDK is looked up for
        // the primary platform, and `getSdk` needs a fully resolved target.
        const query = std.Target.Query{
            .cpu_arch = .aarch64,
            .os_tag = .macos,
        };
        self.target = try std.zig.system.resolveTargetQuery(self.io, query);
        const sdk = std.zig.system.darwin.getSdk(self.allocator, self.io, &self.target) orelse {
            log.err("xcrun found no macOS SDK; install Xcode or the Command Line Tools", .{});
            return error.FailedToResolveSDK;
        };
        errdefer self.allocator.free(sdk);
        // getSdk returns the SDK root; frameworks live in a subdirectory of it,
        // and a framework search path pointed at the root finds nothing.
        self.frameworks = try std.Io.Dir.path.join(self.allocator, &.{ sdk, "System", "Library", "Frameworks" });
        self.sdk = sdk;
        self.loaded = true;
    }

    /// Declares `-Dtarget` like `b.standardTargetOptions`, plus `-Dmacos-min`, the macOS deployment floor.
    ///
    /// Without a floor a native build is stamped with the build host's own macOS
    /// version, so the same source yields objects an older consumer's linker
    /// warns about ("built for newer 'macOS' version"). With one, every macOS
    /// artifact — and every Swift dylib `Swift.addDylib` derives from this target
    /// — states the same minimum. The floor is applied only on a macOS host;
    /// `-Dtarget` overrides it entirely, and carries its own floor as
    /// `aarch64-macos.26.0`.
    ///
    /// A floor makes the target no longer native, and Zig searches the SDK for
    /// frameworks only on a native target: link frameworks through `linkFramework`,
    /// or every `-framework` fails with "searched paths: none". `--sysroot` does
    /// not restore the search.
    ///
    /// Parameters:
    /// - `b`: the build graph the options are declared on.
    /// - `default_min`: the floor when `-Dmacos-min` is absent, as `major[.minor[.patch]]`.
    ///
    /// Return: the resolved target; `error.InvalidVersion` when a floor does not parse.
    pub fn standardTargetOptions(b: *std.Build, default_min: []const u8) !std.Build.ResolvedTarget {
        const text = b.option([]const u8, "macos-min", "Minimum macOS version for macOS artifacts (major[.minor[.patch]])") orelse default_min;
        const min = Self.parseVersion(text) catch |err| {
            log.err("-Dmacos-min={s} is not major[.minor[.patch]]", .{text});
            return err;
        };
        if (b.graph.host.result.os.tag != .macos) return b.standardTargetOptions(.{});
        return b.standardTargetOptions(.{ .default_target = .{ .os_version_min = .{ .semver = min } } });
    }

    /// Adds the SDK's frameworks directory to `module`'s framework search path.
    ///
    /// Parameters:
    /// - `self`: a resolved handle.
    /// - `module`: the module that links system frameworks.
    pub fn addFrameworkPath(self: *const Self, module: *std.Build.Module) void {
        std.debug.assert(self.loaded);
        module.addFrameworkPath(module.owner.graph.cwdRelativePath(self.frameworks));
    }

    /// Links `module` against SDK framework `name`, adding the frameworks directory it is found in.
    ///
    /// Use in place of `module.linkFramework` wherever the target may not be
    /// native — which is any target `standardTargetOptions` gave a floor. An
    /// unresolved handle links without the path: off a macOS host there is no
    /// `xcrun` to resolve with, and that is all a native target needs.
    ///
    /// Parameters:
    /// - `self`: the handle, resolved where the host allows it.
    /// - `module`: the module that links the framework.
    /// - `name`: the framework, as `linkFramework` takes it (`"CoreFoundation"`).
    pub fn linkFramework(self: *const Self, module: *std.Build.Module, name: []const u8) void {
        if (self.loaded) self.addFrameworkPath(module);
        module.linkFramework(name, .{});
    }

    /// Parses a `major[.minor[.patch]]` version, defaulting absent components to 0.
    ///
    /// `std.SemanticVersion.parse` requires all three, and a deployment floor is
    /// conventionally written `26.0`.
    ///
    /// Parameters:
    /// - `text`: the version to parse.
    ///
    /// Return: the version; `error.InvalidVersion` when a component is not a number.
    fn parseVersion(text: []const u8) !std.SemanticVersion {
        var parts = std.mem.splitScalar(u8, text, '.');
        var components: [3]usize = .{ 0, 0, 0 };
        for (&components) |*component| {
            const part = parts.next() orelse break;
            component.* = std.fmt.parseInt(usize, part, 10) catch return error.InvalidVersion;
        }
        if (parts.next() != null) return error.InvalidVersion;
        return .{ .major = components[0], .minor = components[1], .patch = components[2] };
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test "resolve finds the SDK and its frameworks" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var xcode = try Xcode.init(allocator, std.testing.io);
    defer xcode.deinit();
    try xcode.resolveSdk();
    try xcode.resolveSdk();
    try std.testing.expect(std.mem.startsWith(u8, xcode.frameworks, xcode.sdk));
    try std.testing.expect(std.mem.endsWith(u8, xcode.frameworks, "System/Library/Frameworks"));
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, xcode.frameworks, .{});
    defer dir.close(std.testing.io);
    try dir.access(std.testing.io, "Foundation.framework", .{});
}

test "parseVersion accepts one to three components" {
    try std.testing.expectEqual(std.SemanticVersion{ .major = 26, .minor = 0, .patch = 0 }, try Xcode.parseVersion("26"));
    try std.testing.expectEqual(std.SemanticVersion{ .major = 26, .minor = 1, .patch = 0 }, try Xcode.parseVersion("26.1"));
    try std.testing.expectEqual(std.SemanticVersion{ .major = 14, .minor = 2, .patch = 3 }, try Xcode.parseVersion("14.2.3"));
    try std.testing.expectError(error.InvalidVersion, Xcode.parseVersion("26.x"));
    try std.testing.expectError(error.InvalidVersion, Xcode.parseVersion("1.2.3.4"));
    try std.testing.expectError(error.InvalidVersion, Xcode.parseVersion(""));
}

test "deinit on an unresolved handle frees nothing" {
    var xcode = try Xcode.init(std.testing.allocator, std.testing.io);
    xcode.deinit();
    try std.testing.expect(!xcode.loaded);
}
