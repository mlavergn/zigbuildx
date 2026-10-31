const std = @import("std");
const log = std.log.scoped(.zigbuildx_android);
const mod = @import("module.zig");

/// Builds Android native libraries, with no Java or Kotlin.
///
/// Zig ships no Android C library, so a library for Android links against the
/// NDK's sysroot through a libc file. Packaging the libraries into an APK is
/// out of scope. Works on macOS, Linux and Windows hosts: the NDK's prebuilt
/// directory follows the host.
pub const Android = struct {
    const Self = @This();
    /// Android 15 requires 64-bit libraries to load on 16 KB pages.
    const page_size: u64 = 16 * 1024;

    /// Backs every resolved path and libc file; freed by `deinit`.
    arena: std.heap.ArenaAllocator,
    /// IO for inspecting the SDK.
    io: std.Io,
    /// The build graph `resolve` reads and `configure` adds steps to.
    // SAFETY: set by init(b); a handle from initWith (unit tests) never calls resolve or configure.
    b: *std.Build = undefined,
    /// Whether `resolve` found the SDK, the NDK and the sysroot.
    loaded: bool = false,
    /// What `resolve` looked for and did not find, for its error message.
    missing: []const u8 = "",
    /// The build host's OS, which picks the NDK's prebuilt directory.
    // SAFETY: populated by resolve() before first read, guarded by `loaded`.
    host: std.Target.Os.Tag = undefined,
    /// The Android SDK's root.
    // SAFETY: populated by resolve() before first read, guarded by `loaded`.
    sdk: []const u8 = undefined,
    /// The NDK's root.
    // SAFETY: populated by resolve() before first read, guarded by `loaded`.
    ndk: []const u8 = undefined,
    /// The NDK's `toolchains/llvm/prebuilt/<host>/sysroot`.
    // SAFETY: populated by resolve() before first read, guarded by `loaded`.
    sysroot: []const u8 = undefined,

    /// Creates an unresolved handle for build graph `b`.
    ///
    /// - `b`: The build graph; must outlive the handle.
    /// - Returns: The handle.
    pub fn init(b: *std.Build) !Self {
        var self = Self.initWith(b.allocator, b.graph.io);
        self.b = b;
        return self;
    }

    /// Creates an unresolved handle with no build graph, for the unit tests.
    ///
    /// - `allocator`: Backs the resolved paths; must outlive the handle.
    /// - `io`: IO for inspecting the SDK.
    /// - Returns: The handle, usable with `resolveFrom` but not `resolve` or `configure`.
    fn initWith(allocator: std.mem.Allocator, io: std.Io) Self {
        return Self{ .arena = std.heap.ArenaAllocator.init(allocator), .io = io };
    }

    /// Frees the resolved paths.
    ///
    /// - `self`: The handle.
    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    /// Locates the SDK, the NDK and the NDK sysroot for this host.
    /// Poisons the configure cache: every build that resolves Android configures again.
    ///
    /// - `self`: The handle to populate; its build graph's environment and host are read.
    /// - Returns: `error.AndroidSdkNotFound` naming what is missing.
    pub fn resolve(self: *Self) !void {
        // Zig 0.17 reuses a configured graph until a tracked input changes, and neither the
        // environment nor a newer NDK appearing is tracked.
        self.b.graph.poisonCache();
        self.resolveFrom(&self.b.graph.environ_map, self.b.graph.host.result.os.tag) catch |err| {
            const message = self.describeFailure(err) catch "cannot locate the Android SDK";
            log.err("{s}", .{message});
            return err;
        };
    }

    /// Returns the target for `abi` at Android API level `api`.
    ///
    /// - `b`: The build graph.
    /// - `abi`: The ABI.
    /// - `api`: The minimum API level, which the NDK's libraries are chosen by.
    /// - Returns: The resolved target.
    pub fn resolveTarget(b: *std.Build, abi: mod.AndroidAbi, api: u32) std.Build.ResolvedTarget {
        return b.resolveTargetQuery(abi.query(api));
    }

    /// Makes `lib` link against the NDK: libc, the libc file, and 16 KB pages.
    ///
    /// - `self`: A resolved handle.
    /// - `lib`: A library whose target came from `resolveTarget`.
    /// - Returns: `error.NotAndroid` when `lib`'s target is not Android.
    pub fn configure(self: *Self, lib: *std.Build.Step.Compile) !void {
        std.debug.assert(self.loaded);
        const resolved = lib.root_module.resolved_target orelse {
            log.err("{s} has no target; give it one from resolveTarget", .{lib.name});
            return error.NotAndroid;
        };
        const target = resolved.result;
        const abi = mod.AndroidAbi.fromTarget(target) orelse {
            log.err("{s} does not target Android", .{lib.name});
            return error.NotAndroid;
        };
        const api = target.os.version_range.linux.android;
        lib.root_module.link_libc = true;
        lib.setLibCFile(self.b.addWriteFiles().add(self.b.fmt("libc-{s}-{d}.txt", .{ abi.dirName(), api }), try self.libCText(abi, api)));
        lib.link_z_max_page_size = page_size;
    }

    /// Populates the handle from `environ` for a `host` build.
    ///
    /// - `self`: The handle.
    /// - `environ`: The build's environment.
    /// - `host`: The build host's OS, which picks the NDK prebuilt.
    /// - Returns: `error.AndroidSdkNotFound`, `error.AndroidNdkNotFound` or `error.UnsupportedHost`, naming the path in `missing`.
    fn resolveFrom(self: *Self, environ: *const std.process.Environ.Map, host: std.Target.Os.Tag) !void {
        const allocator = self.arena.allocator();
        const cwd = std.Io.Dir.cwd();
        self.host = host;

        const sdk = environ.get("ANDROID_HOME") orelse environ.get("ANDROID_SDK_ROOT") orelse try Self.defaultSdk(allocator, environ, host);
        self.missing = sdk;
        cwd.access(self.io, sdk, .{}) catch return error.AndroidSdkNotFound;
        self.sdk = try allocator.dupe(u8, sdk);

        const ndk = environ.get("ANDROID_NDK_HOME") orelse environ.get("ANDROID_NDK_ROOT") orelse ndk: {
            const ndks = try std.Io.Dir.path.join(allocator, &.{ sdk, "ndk" });
            self.missing = ndks;
            break :ndk try std.Io.Dir.path.join(allocator, &.{ ndks, try self.newest(ndks) orelse return error.AndroidNdkNotFound });
        };
        self.ndk = try allocator.dupe(u8, ndk);
        const prebuilt = Self.hostTag(host) orelse {
            self.missing = @tagName(host);
            return error.UnsupportedHost;
        };
        self.sysroot = try std.Io.Dir.path.join(allocator, &.{ ndk, "toolchains", "llvm", "prebuilt", prebuilt, "sysroot" });
        self.missing = self.sysroot;
        cwd.access(self.io, self.sysroot, .{}) catch return error.AndroidNdkNotFound;

        self.missing = "";
        self.loaded = true;
    }

    /// Explains a `resolveFrom` failure, naming what was looked for and how to point at it.
    ///
    /// - `self`: The handle `resolveFrom` failed on; its `missing` names the path.
    /// - `err`: The error `resolveFrom` returned.
    /// - Returns: The message, owned by the handle; allocation errors.
    fn describeFailure(self: *Self, err: anyerror) ![]const u8 {
        const allocator = self.arena.allocator();
        return switch (err) {
            // No `missing` path: there was no home directory to find the default SDK in.
            error.AndroidSdkNotFound => if (self.missing.len == 0)
                "Android SDK not found: no home directory to look in; set ANDROID_HOME or ANDROID_SDK_ROOT"
            else
                allocator.print("Android SDK not found at {s}; set ANDROID_HOME or ANDROID_SDK_ROOT", .{self.missing}),
            error.AndroidNdkNotFound => allocator.print("Android NDK not found at {s}; set ANDROID_NDK_HOME or ANDROID_NDK_ROOT", .{self.missing}),
            error.UnsupportedHost => allocator.print("the Android NDK has no prebuilt toolchain for a {s} host", .{self.missing}),
            else => allocator.print("cannot locate the Android SDK [{any}]", .{err}),
        };
    }

    /// Returns the libc file that points Zig at the NDK sysroot for `abi` at `api`.
    ///
    /// - `self`: A resolved handle.
    /// - `abi`: The ABI.
    /// - `api`: The API level, which selects the sysroot's `usr/lib/<triple>/<api>`.
    /// - Returns: The file's text, owned by the handle; allocation errors.
    fn libCText(self: *Self, abi: mod.AndroidAbi, api: u32) ![]const u8 {
        const allocator = self.arena.allocator();
        const include = try std.Io.Dir.path.join(allocator, &.{ self.sysroot, "usr", "include" });
        const sys_include = try std.Io.Dir.path.join(allocator, &.{ include, abi.triple() });
        const crt = try std.Io.Dir.path.join(allocator, &.{ self.sysroot, "usr", "lib", abi.triple(), try allocator.print("{d}", .{api}) });
        // Zig 0.17 takes a Linux target's `crtbegin`/`crtend` from `cc_dir`; the NDK keeps
        // `crtbegin_so.o` and `crtend_so.o` beside the other startup objects, so `cc_dir` is `crt_dir`.
        return allocator.print(
            \\include_dir={s}
            \\sys_include_dir={s}
            \\crt_dir={s}
            \\msvc_lib_dir=
            \\kernel32_lib_dir=
            \\cc_dir={s}
            \\darwin_sdk_dir=
            \\
        , .{ include, sys_include, crt, crt });
    }

    /// Returns the newest entry of directory `path`, comparing the numbers in each name.
    /// Names with no number (preview platforms) are skipped.
    ///
    /// - `self`: The handle.
    /// - `path`: The directory.
    /// - Returns: The entry's name, or null when the directory is absent or holds none; IO errors.
    fn newest(self: *Self, path: []const u8) !?[]const u8 {
        var dir = std.Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true }) catch return null;
        defer dir.close(self.io);
        var best: ?[]const u8 = null;
        var best_version: [4]u32 = .{ 0, 0, 0, 0 };
        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.kind != .directory) continue;
            const version = Self.versionOf(entry.name) orelse continue;
            if (best != null and std.mem.order(u32, &version, &best_version) != .gt) continue;
            best = try self.arena.allocator().dupe(u8, entry.name);
            best_version = version;
        }
        return best;
    }

    /// Returns the first four numbers in `name`, zero-filled.
    ///
    /// - `name`: A versioned name, e.g. `35.0.1` or `android-35`.
    /// - Returns: The numbers, or null when `name` holds none.
    fn versionOf(name: []const u8) ?[4]u32 {
        var version: [4]u32 = .{ 0, 0, 0, 0 };
        var count: usize = 0;
        var it = std.mem.tokenizeAny(u8, name, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-._");
        while (it.next()) |digits| {
            if (count == version.len) break;
            version[count] = std.fmt.parseInt(u32, digits, 10) catch return null;
            count += 1;
        }
        return if (count == 0) null else version;
    }

    /// Returns the NDK prebuilt directory name for a host.
    ///
    /// - `host`: The host OS.
    /// - Returns: The name, or null for a host the NDK does not support.
    fn hostTag(host: std.Target.Os.Tag) ?[]const u8 {
        return switch (host) {
            // Google ships `darwin-x86_64` as a universal binary, so Apple Silicon uses it too.
            .macos => "darwin-x86_64",
            .linux => "linux-x86_64",
            .windows => "windows-x86_64",
            else => null,
        };
    }

    /// Returns Android Studio's default SDK location for `host`.
    ///
    /// - `allocator`: Owns the path.
    /// - `environ`: The build's environment.
    /// - `host`: The host OS.
    /// - Returns: The path; `error.AndroidSdkNotFound` when the home directory is unknown.
    fn defaultSdk(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map, host: std.Target.Os.Tag) ![]const u8 {
        if (host == .windows) {
            const local = environ.get("LOCALAPPDATA") orelse return error.AndroidSdkNotFound;
            return std.Io.Dir.path.join(allocator, &.{ local, "Android", "Sdk" });
        }
        const user_home = environ.get("HOME") orelse return error.AndroidSdkNotFound;
        if (host == .macos) return std.Io.Dir.path.join(allocator, &.{ user_home, "Library", "Android", "sdk" });
        return std.Io.Dir.path.join(allocator, &.{ user_home, "Android", "Sdk" });
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test "versionOf reads the numbers in a name" {
    try std.testing.expectEqual([4]u32{ 35, 0, 1, 0 }, Android.versionOf("35.0.1").?);
    try std.testing.expectEqual([4]u32{ 35, 0, 0, 0 }, Android.versionOf("android-35").?);
    try std.testing.expectEqual([4]u32{ 27, 2, 12479018, 0 }, Android.versionOf("27.2.12479018").?);
    try std.testing.expectEqual(@as(?[4]u32, null), Android.versionOf("android-Baklava"));
}

/// Builds a fake SDK under `root`: two NDKs, the newer with a sysroot for every host.
///
/// - `io`: IO for the filesystem.
/// - `root`: The directory to build it in.
/// - Returns: IO errors.
fn makeFakeSdk(io: std.Io, root: std.Io.Dir) !void {
    const dirs = [_][]const u8{
        "sdk/ndk/26.3.11579264/toolchains/llvm/prebuilt/darwin-x86_64/sysroot",
        "sdk/ndk/27.2.12479018/toolchains/llvm/prebuilt/darwin-x86_64/sysroot",
        "sdk/ndk/27.2.12479018/toolchains/llvm/prebuilt/linux-x86_64/sysroot",
        "sdk/ndk/27.2.12479018/toolchains/llvm/prebuilt/windows-x86_64/sysroot",
    };
    for (dirs) |dir| try root.createDirPath(io, dir);
}

test "resolve picks the newest NDK, and the sysroot for every host" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFakeSdk(io, tmp.dir);
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const sdk = try std.Io.Dir.path.join(allocator, &.{ root, "sdk" });
    defer allocator.free(sdk);
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("ANDROID_HOME", sdk);

    for ([_]std.Target.Os.Tag{ .macos, .linux, .windows }) |host| {
        var android = Android.initWith(allocator, io);
        defer android.deinit();
        try android.resolveFrom(&environ, host);
        try std.testing.expect(std.mem.find(u8, android.ndk, "27.2.12479018") != null);
        try std.testing.expect(std.mem.find(u8, android.sysroot, Android.hostTag(host).?) != null);

        const text = try android.libCText(.arm64V8a, 30);
        try std.testing.expect(std.mem.find(u8, text, "sys_include_dir=") != null);
        // Zig's own parser: it rejects a file missing any field its release expects.
        try tmp.dir.writeFile(io, .{ .sub_path = "libc.txt", .data = text });
        const libc_path = try std.Io.Dir.path.join(allocator, &.{ root, "libc.txt" });
        defer allocator.free(libc_path);
        const target = try std.zig.system.resolveTargetQuery(io, mod.AndroidAbi.arm64V8a.query(30));
        var libc = try std.zig.LibCInstallation.parse(allocator, io, libc_path, &target);
        libc.deinit(allocator);
        try std.testing.expect(std.mem.find(u8, text, "aarch64-linux-android") != null);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "crt_dir=")) try std.testing.expect(std.mem.endsWith(u8, line, "30"));
        }
    }
}

test "an explicit NDK wins over the SDK's newest" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFakeSdk(io, tmp.dir);
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const sdk = try std.Io.Dir.path.join(allocator, &.{ root, "sdk" });
    defer allocator.free(sdk);
    const ndk = try std.Io.Dir.path.join(allocator, &.{ sdk, "ndk", "26.3.11579264" });
    defer allocator.free(ndk);
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("ANDROID_HOME", sdk);
    try environ.put("ANDROID_NDK_HOME", ndk);

    var android = Android.initWith(allocator, io);
    defer android.deinit();
    try android.resolveFrom(&environ, .macos);
    try std.testing.expect(std.mem.find(u8, android.sysroot, "26.3.11579264") != null);
    // Only the darwin sysroot exists in the older NDK.
    var linux = Android.initWith(allocator, io);
    defer linux.deinit();
    try std.testing.expectError(error.AndroidNdkNotFound, linux.resolveFrom(&environ, .linux));
}

test "a missing SDK is reported, with the path looked for" {
    const allocator = std.testing.allocator;
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("ANDROID_HOME", "/nonexistent/zigbuildx/sdk");
    var android = Android.initWith(allocator, std.testing.io);
    defer android.deinit();
    try std.testing.expectError(error.AndroidSdkNotFound, android.resolveFrom(&environ, .linux));
    try std.testing.expectEqualStrings("/nonexistent/zigbuildx/sdk", android.missing);
    try std.testing.expectEqualStrings("Android SDK not found at /nonexistent/zigbuildx/sdk; set ANDROID_HOME or ANDROID_SDK_ROOT", try android.describeFailure(error.AndroidSdkNotFound));
}

test "every resolve failure has its own message" {
    var android = Android.initWith(std.testing.allocator, std.testing.io);
    defer android.deinit();
    // With no home directory there is no path to name.
    try std.testing.expectEqualStrings("Android SDK not found: no home directory to look in; set ANDROID_HOME or ANDROID_SDK_ROOT", try android.describeFailure(error.AndroidSdkNotFound));
    android.missing = "/sdk/ndk";
    try std.testing.expectEqualStrings("Android NDK not found at /sdk/ndk; set ANDROID_NDK_HOME or ANDROID_NDK_ROOT", try android.describeFailure(error.AndroidNdkNotFound));
    android.missing = "freebsd";
    try std.testing.expectEqualStrings("the Android NDK has no prebuilt toolchain for a freebsd host", try android.describeFailure(error.UnsupportedHost));
}
