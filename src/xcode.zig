const std = @import("std");
const log = std.log.scoped(.zigbuildx_xcode);
const builtin = @import("builtin");

/// What `Xcode.addXcframework` assembles.
pub const Xcframework = struct {
    const Self = @This();
    /// The framework's name: `Hello` builds `Hello.xcframework`.
    name: []const u8,
    /// One library per platform and architecture, each built for an Apple target.
    libraries: []const *std.Build.Step.Compile,
    /// A directory of headers given with every library, or null for none.
    headers: ?std.Build.LazyPath = null,
};

/// Locates an Apple platform's SDK so a module can link against system frameworks.
///
/// macOS, iOS, tvOS, visionOS and watchOS, devices and simulators: `xcrun`
/// names the SDK for each, and one handle serves one platform. A target other
/// than macOS also needs `configure`, which describes the SDK's C library to
/// Zig.
pub const Xcode = struct {
    const Self = @This();
    /// Allocates the SDK paths; `init`'s is the build's arena.
    allocator: std.mem.Allocator,
    /// IO `xcrun` runs through.
    io: std.Io,
    /// The build graph `resolve` records the SDK on.
    // SAFETY: set by init(b); a handle from initWith (unit tests) never calls resolve.
    b: *std.Build = undefined,
    /// Whether an SDK was resolved, so its fields may be read.
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
    /// The SDK's `usr/lib`, where the system libraries a framework depends on
    /// are found (`libobjc.A` for CoreFoundation); valid only after `resolve`.
    // SAFETY: populated by resolve() before first read, guarded by `loaded`.
    libraries: []const u8 = undefined,
    /// Whether the handle links for an Apple platform; false only from
    /// `initFor` with a non-Apple target, and `linkFramework` then does nothing.
    apple: bool = true,

    /// Creates an unresolved handle for build graph `b`.
    ///
    /// Parameters:
    /// - `b`: the build graph; must outlive the handle.
    ///
    /// Return: the handle.
    pub fn init(b: *std.Build) !Self {
        var self = Self.initWith(b.allocator, b.graph.io);
        self.b = b;
        return self;
    }

    /// Creates a handle for `target`, resolved for an Apple target on a Mac.
    ///
    /// Parameters:
    /// - `b`: the build graph; must outlive the handle.
    /// - `target`: the target the modules are built for.
    ///
    /// Return: the handle; `error.FailedToResolveSDK` when a Mac has no SDK for the platform.
    pub fn initFor(b: *std.Build, target: std.Build.ResolvedTarget) !Self {
        var self = try Self.init(b);
        self.apple = target.result.os.tag.isDarwin();
        if (Self.resolvesFor(target.result.os.tag, b.graph.host.result.os.tag)) try self.resolveFor(target.result);
        return self;
    }

    /// Creates an unresolved handle with no build graph, for the unit tests.
    ///
    /// Parameters:
    /// - `allocator`: allocator for the SDK paths; must outlive the handle.
    /// - `io`: IO for `xcrun`.
    ///
    /// Return: the handle, usable with `resolveSdk` only.
    fn initWith(allocator: std.mem.Allocator, io: std.Io) Self {
        return Self{ .allocator = allocator, .io = io };
    }

    /// Frees the SDK paths when they were resolved; a handle from `init` need not call it.
    ///
    /// Parameters:
    /// - `self`: the handle.
    pub fn deinit(self: *Self) void {
        if (!self.loaded) return;
        self.allocator.free(self.libraries);
        self.allocator.free(self.frameworks);
        self.allocator.free(self.sdk);
        self.loaded = false;
    }

    /// Resolves the Apple Silicon macOS SDK into the handle; does nothing once resolved.
    ///
    /// Parameters:
    /// - `self`: the handle.
    ///
    /// Return: nothing; `error.FailedToResolveSDK` when there is no SDK.
    pub fn resolve(self: *Self) !void {
        if (self.loaded) return;
        try self.resolveFor(try std.zig.system.resolveTargetQuery(self.io, .{ .cpu_arch = .aarch64, .os_tag = .macos }));
    }

    /// Resolves the SDK of `target`'s platform into the handle; does nothing once resolved.
    ///
    /// Parameters:
    /// - `self`: the handle.
    /// - `target`: an Apple target; its OS and ABI pick the SDK.
    ///
    /// Return: nothing; `error.FailedToResolveSDK` when there is no SDK.
    pub fn resolveFor(self: *Self, target: std.Target) !void {
        if (self.loaded) return;
        try self.resolveSdk(target);
        // The configure cache cannot see xcrun's answer. The SDK's path carries its version,
        // so an Xcode update removes this file and the next build configures again.
        self.b.dependOnFileMetadata(self.b.graph.cwdRelativePath(self.b.pathJoin(&.{ self.sdk, "SDKSettings.json" })));
    }

    /// Declares `-Dtarget` like `b.standardTargetOptions`, plus `-Dmacos-min`, the macOS deployment floor.
    ///
    /// Parameters:
    /// - `b`: the build graph.
    /// - `default_min`: the floor without `-Dmacos-min`, as `major[.minor[.patch]]`.
    ///
    /// Return: the target; `error.InvalidVersion` when the floor does not parse.
    pub fn standardTargetOptions(b: *std.Build, default_min: []const u8) !std.Build.ResolvedTarget {
        const text = b.option([]const u8, "macos-min", "Minimum macOS version for macOS artifacts (major[.minor[.patch]])") orelse default_min;
        const min = Self.parseVersion(text) catch |err| {
            log.err("-Dmacos-min={s} is not major[.minor[.patch]]", .{text});
            return err;
        };
        // The floor applies on a macOS host only; `-Dtarget` overrides it with its own.
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

    /// Adds the SDK's frameworks directory and `usr/lib` to `module`'s search paths.
    ///
    /// Parameters:
    /// - `self`: a resolved handle.
    /// - `module`: the module that links system frameworks.
    pub fn addSdkPaths(self: *const Self, module: *std.Build.Module) void {
        self.addFrameworkPath(module);
        // A framework's stub names its dependencies by `/usr/lib` install name (CoreFoundation's
        // `libobjc.A`), and a non-native target searches no SDK directory without these paths.
        module.addLibraryPath(module.owner.graph.cwdRelativePath(self.libraries));
    }

    /// Links `module` against SDK framework `name`; use it in place of `module.linkFramework`.
    ///
    /// Parameters:
    /// - `self`: the handle; does nothing when made for a non-Apple target.
    /// - `module`: the module that links the framework.
    /// - `name`: the framework, as `"CoreFoundation"`.
    pub fn linkFramework(self: *const Self, module: *std.Build.Module, name: []const u8) void {
        if (!self.apple) return;
        if (self.loaded) self.addSdkPaths(module);
        module.linkFramework(name, .{});
    }

    /// Makes `lib` build against the resolved SDK; required for iOS, tvOS, visionOS and watchOS.
    ///
    /// Parameters:
    /// - `self`: the handle `initFor` made for `lib`'s target; does nothing when unresolved or non-Apple.
    /// - `lib`: a library or executable built for that target.
    ///
    /// Return: nothing; `error.TargetMismatch` when `lib` targets another platform.
    pub fn configure(self: *const Self, lib: *std.Build.Step.Compile) !void {
        if (!self.apple or !self.loaded) return;
        const target = lib.root_module.resolved_target orelse {
            log.err("{s} has no target; give it the one its Xcode handle was made for", .{lib.name});
            return error.TargetMismatch;
        };
        if (target.result.os.tag != self.target.os.tag or target.result.abi != self.target.abi) {
            log.err("{s} targets {t}-{t}, but this Xcode handle resolved {s}; make a handle with initFor for its target", .{ lib.name, target.result.os.tag, target.result.abi, std.Io.Dir.path.basename(self.sdk) });
            return error.TargetMismatch;
        }
        self.addSdkPaths(lib.root_module);
        if (self.target.os.tag == .macos) return;
        // Zig 0.17 finds no C library for Apple's other platforms, even with `--sysroot`.
        lib.setLibCFile(self.b.addWriteFiles().add(self.b.fmt("libc-{s}.txt", .{std.Io.Dir.path.basename(self.sdk)}), try self.libCText()));
        // The C sanitizers' runtime is Zig code, which Zig 0.17 cannot compile for these
        // platforms (`std.process.can_replace`), so a Debug link fails on it. Trapping
        // keeps every check and needs no runtime. A mode the build chose is left alone.
        const mode = lib.root_module.optimize orelse .debug;
        if (lib.root_module.sanitize_c == null and (mode == .debug or mode == .safe)) lib.root_module.sanitize_c = .trap;
    }

    /// Assembles an `.xcframework` from libraries built for Apple targets, joining each platform's architectures.
    /// Configure each library with an `initFor` handle for its own target first.
    ///
    /// Parameters:
    /// - `b`: the build graph.
    /// - `options`: the name, libraries and headers.
    ///
    /// Return: the `<name>.xcframework` directory, or null off macOS; `error.InvalidXcframework` for a library that is not for an Apple platform, or two for one platform and architecture.
    pub fn addXcframework(b: *std.Build, options: Xcframework) !?std.Build.LazyPath {
        if (b.graph.host.result.os.tag != .macos) return null;
        if (options.libraries.len == 0) {
            log.err("{s}.xcframework has no libraries", .{options.name});
            return error.InvalidXcframework;
        }
        // xcodebuild takes one library per platform, so a platform's architectures are joined first.
        var platforms: std.array_hash_map.String(std.ArrayList(*std.Build.Step.Compile)) = .empty;
        for (options.libraries) |lib| {
            const target = if (lib.root_module.resolved_target) |resolved| resolved.result else {
                log.err("{s} has no target", .{lib.name});
                return error.InvalidXcframework;
            };
            if (lib.kind != .lib or !target.os.tag.isDarwin()) {
                log.err("{s} is not a library for an Apple platform", .{lib.name});
                return error.InvalidXcframework;
            }
            const platform = try platforms.getOrPut(b.allocator, try Self.platformName(b.allocator, target));
            if (!platform.found_existing) platform.value_ptr.* = .empty;
            for (platform.value_ptr.items) |other| {
                if (other.root_module.resolved_target.?.result.cpu.arch != target.cpu.arch) continue;
                log.err("{s} and {s} both build {s} for {t}", .{ other.name, lib.name, platform.key_ptr.*, target.cpu.arch });
                return error.InvalidXcframework;
            }
            try platform.value_ptr.append(b.allocator, lib);
        }
        // Copied first: a Run step hashes a directory argument's path, and a copy's path changes with its contents.
        const headers = if (options.headers) |dir| b.addWriteFiles().addCopyDirectory(dir, "", .{}) else null;
        const xcodebuild = b.addSystemCommand(&.{ "xcodebuild", "-create-xcframework" });
        xcodebuild.setName(b.fmt("xcframework {s}", .{options.name}));
        for (platforms.keys(), platforms.values()) |platform, libs| {
            xcodebuild.addArg("-library");
            xcodebuild.addFileArg2(Self.joinArchitectures(b, platform, libs.items), .{});
            if (headers) |dir| {
                xcodebuild.addArg("-headers");
                xcodebuild.addDirectoryArg2(dir, .{});
            }
        }
        // xcodebuild refuses an existing output, so it creates the framework inside the step's own directory.
        const bundle = b.fmt("{s}.xcframework", .{options.name});
        xcodebuild.addArg("-output");
        const out = xcodebuild.addOutputDirectoryArg2("xcframework", .{ .suffix = b.fmt("/{s}", .{bundle}) });
        return out.path(b, bundle);
    }

    /// Asks `xcrun` for `target`'s SDK and fills in the handle; does nothing once resolved.
    ///
    /// Parameters:
    /// - `self`: the handle.
    /// - `target`: an Apple target; its OS and ABI pick the SDK.
    ///
    /// Return: nothing; `error.FailedToResolveSDK` when there is no SDK.
    fn resolveSdk(self: *Self, target: std.Target) !void {
        if (self.loaded) return;
        self.target = target;
        const sdk = std.zig.system.darwin.getSdk(self.allocator, self.io, &self.target) orelse {
            log.err("xcrun found no {t}{s} SDK; install Xcode and its {t} platform", .{ target.os.tag, if (target.abi == .simulator) " simulator" else "", target.os.tag });
            return error.FailedToResolveSDK;
        };
        errdefer self.allocator.free(sdk);
        // getSdk returns the SDK root; frameworks live in a subdirectory of it,
        // and a framework search path pointed at the root finds nothing.
        self.frameworks = try std.Io.Dir.path.join(self.allocator, &.{ sdk, "System", "Library", "Frameworks" });
        errdefer self.allocator.free(self.frameworks);
        self.libraries = try std.Io.Dir.path.join(self.allocator, &.{ sdk, "usr", "lib" });
        self.sdk = sdk;
        self.loaded = true;
    }

    /// Reports whether `initFor` resolves an SDK for a `target` build on `host`.
    ///
    /// Parameters:
    /// - `target`: the build target's OS.
    /// - `host`: the build host's OS.
    ///
    /// Return: `true` for an Apple target on a macOS host.
    fn resolvesFor(target: std.Target.Os.Tag, host: std.Target.Os.Tag) bool {
        return target.isDarwin() and host == .macos;
    }

    /// Names the platform an `.xcframework` files a target's library under.
    ///
    /// Parameters:
    /// - `allocator`: allocator for the name.
    /// - `target`: an Apple target.
    ///
    /// Return: the OS, with `-simulator` for the simulator ABI (`ios-simulator`), owned by the caller.
    fn platformName(allocator: std.mem.Allocator, target: std.Target) ![]u8 {
        return allocator.print("{t}{s}", .{ target.os.tag, if (target.abi == .simulator) "-simulator" else "" });
    }

    /// Returns one library for a platform: the only one, or every architecture's joined by `lipo`.
    ///
    /// Parameters:
    /// - `b`: the build graph.
    /// - `platform`: the platform's name, for the step's.
    /// - `libs`: the platform's libraries, one per architecture.
    ///
    /// Return: the library.
    fn joinArchitectures(b: *std.Build, platform: []const u8, libs: []const *std.Build.Step.Compile) std.Build.LazyPath {
        if (libs.len == 1) return libs[0].getEmittedBin();
        const lipo = b.addSystemCommand(&.{ "lipo", "-create" });
        lipo.setName(b.fmt("lipo {s} {s}", .{ libs[0].name, platform }));
        for (libs) |lib| lipo.addFileArg2(lib.getEmittedBin(), .{});
        lipo.addArg("-output");
        return lipo.addOutputFileArg2(b.fmt("lib{s}.{s}", .{ libs[0].name, if (libs[0].linkage == .dynamic) "dylib" else "a" }), .{});
    }

    /// Returns the libc file describing the resolved SDK's C library.
    ///
    /// Parameters:
    /// - `self`: a handle with `sdk` and `libraries` set.
    ///
    /// Return: the file's text, owned by `self.allocator`.
    fn libCText(self: *const Self) ![]u8 {
        const include = try std.Io.Dir.path.join(self.allocator, &.{ self.sdk, "usr", "include" });
        defer self.allocator.free(include);
        // Zig 0.17 requires every field, `darwin_sdk_dir` included for an Apple target.
        return self.allocator.print(
            \\include_dir={s}
            \\sys_include_dir={s}
            \\crt_dir={s}
            \\msvc_lib_dir=
            \\kernel32_lib_dir=
            \\cc_dir=
            \\darwin_sdk_dir={s}
            \\
        , .{ include, include, self.libraries, self.sdk });
    }

    /// Parses a `major[.minor[.patch]]` version, absent components being 0.
    ///
    /// Parameters:
    /// - `text`: the version.
    ///
    /// Return: the version; `error.InvalidVersion` when a component is not a number.
    fn parseVersion(text: []const u8) !std.SemanticVersion {
        // `std.SemanticVersion.parse` requires all three components; a floor is written `26.0`.
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
    var xcode = Xcode.initWith(allocator, std.testing.io);
    defer xcode.deinit();
    // The Apple Silicon macOS target, as `resolve` uses; resolveSdk picks the SDK from it.
    const macos = try std.zig.system.resolveTargetQuery(std.testing.io, .{ .cpu_arch = .aarch64, .os_tag = .macos });
    try xcode.resolveSdk(macos);
    // Twice on purpose: a resolved handle returns at once, without running xcrun or allocating again.
    try xcode.resolveSdk(macos);
    try std.testing.expect(std.mem.startsWith(u8, xcode.frameworks, xcode.sdk));
    try std.testing.expect(std.mem.endsWith(u8, xcode.frameworks, "System/Library/Frameworks"));
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, xcode.frameworks, .{});
    defer dir.close(std.testing.io);
    try dir.access(std.testing.io, "Foundation.framework", .{});

    // What CoreFoundation's stub depends on, by its `/usr/lib` install name.
    try std.testing.expect(std.mem.endsWith(u8, xcode.libraries, "usr/lib"));
    var libraries = try std.Io.Dir.cwd().openDir(std.testing.io, xcode.libraries, .{});
    defer libraries.close(std.testing.io);
    try libraries.access(std.testing.io, "libobjc.A.tbd", .{});
}

test "parseVersion accepts one to three components" {
    try std.testing.expectEqual(std.SemanticVersion{ .major = 26, .minor = 0, .patch = 0 }, try Xcode.parseVersion("26"));
    try std.testing.expectEqual(std.SemanticVersion{ .major = 26, .minor = 1, .patch = 0 }, try Xcode.parseVersion("26.1"));
    try std.testing.expectEqual(std.SemanticVersion{ .major = 14, .minor = 2, .patch = 3 }, try Xcode.parseVersion("14.2.3"));
    try std.testing.expectError(error.InvalidVersion, Xcode.parseVersion("26.x"));
    try std.testing.expectError(error.InvalidVersion, Xcode.parseVersion("1.2.3.4"));
    try std.testing.expectError(error.InvalidVersion, Xcode.parseVersion(""));
}

test "resolvesFor resolves every Apple platform, only on a Mac" {
    try std.testing.expect(Xcode.resolvesFor(.macos, .macos));
    try std.testing.expect(Xcode.resolvesFor(.ios, .macos));
    try std.testing.expect(Xcode.resolvesFor(.visionos, .macos));
    try std.testing.expect(!Xcode.resolvesFor(.linux, .macos));
    try std.testing.expect(!Xcode.resolvesFor(.macos, .linux));
}

test "resolveSdk finds the iOS device and simulator SDKs for their targets" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cases = [_]struct { query: std.Target.Query, prefix: []const u8 }{
        .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .ios }, .prefix = "iPhoneOS" },
        .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .ios, .abi = .simulator }, .prefix = "iPhoneSimulator" },
    };
    for (cases) |case| {
        const target = try std.zig.system.resolveTargetQuery(io, case.query);
        // An Xcode without the iOS platform has no SDK to find; resolveSdk would log an error.
        const probe = std.zig.system.darwin.getSdk(allocator, io, &target) orelse return error.SkipZigTest;
        allocator.free(probe);
        var xcode = Xcode.initWith(allocator, io);
        defer xcode.deinit();
        try xcode.resolveSdk(target);
        try std.testing.expect(std.mem.startsWith(u8, std.Io.Dir.path.basename(xcode.sdk), case.prefix));
        try std.testing.expectEqual(std.Target.Os.Tag.ios, xcode.target.os.tag);
    }
}

test "libCText describes an Apple SDK in a file Zig's own parser accepts" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // No SDK is resolved: the text needs only its paths, so this runs on every host.
    var xcode = Xcode.initWith(allocator, io);
    defer xcode.deinit();
    xcode.sdk = "/sdk/iPhoneOS.sdk";
    xcode.libraries = "/sdk/iPhoneOS.sdk/usr/lib";
    const text = try xcode.libCText();
    defer allocator.free(text);
    try std.testing.expect(std.mem.find(u8, text, "darwin_sdk_dir=/sdk/iPhoneOS.sdk\n") != null);
    try std.testing.expect(std.mem.find(u8, text, "crt_dir=/sdk/iPhoneOS.sdk/usr/lib\n") != null);

    try tmp.dir.writeFile(io, .{ .sub_path = "libc.txt", .data = text });
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const path = try std.Io.Dir.path.join(allocator, &.{ root, "libc.txt" });
    defer allocator.free(path);
    const ios = try std.zig.system.resolveTargetQuery(io, .{ .cpu_arch = .aarch64, .os_tag = .ios });
    var libc = try std.zig.LibCInstallation.parse(allocator, io, path, &ios);
    libc.deinit(allocator);
}

test "platformName files a simulator apart from its device" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cases = [_]struct { query: std.Target.Query, name: []const u8 }{
        .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .ios }, .name = "ios" },
        .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .ios, .abi = .simulator }, .name = "ios-simulator" },
        .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .macos }, .name = "macos" },
    };
    for (cases) |case| {
        const name = try Xcode.platformName(allocator, try std.zig.system.resolveTargetQuery(io, case.query));
        defer allocator.free(name);
        try std.testing.expectEqualStrings(case.name, name);
    }
}

test "deinit on an unresolved handle frees nothing" {
    var xcode = Xcode.initWith(std.testing.allocator, std.testing.io);
    xcode.deinit();
    try std.testing.expect(!xcode.loaded);
}
