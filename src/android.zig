const std = @import("std");
const log = std.log.scoped(.zigbuildx_android);

/// An Android ABI: what an APK names the directory holding its native libraries.
pub const AndroidAbi = enum {
    const Self = @This();

    arm64V8a,
    armeabiV7a,
    x86_64,
    x86,

    /// Returns the ABI's directory under `lib/` in an APK.
    ///
    /// Parameters:
    /// - `self`: the ABI.
    ///
    /// Return: the name, e.g. `arm64-v8a`.
    pub fn dirName(self: Self) []const u8 {
        return switch (self) {
            .arm64V8a => "arm64-v8a",
            .armeabiV7a => "armeabi-v7a",
            .x86_64 => "x86_64",
            .x86 => "x86",
        };
    }

    /// Returns the NDK sysroot's directory for the ABI, under `usr/include` and `usr/lib`.
    ///
    /// Parameters:
    /// - `self`: the ABI.
    ///
    /// Return: the triple, e.g. `aarch64-linux-android`.
    pub fn triple(self: Self) []const u8 {
        return switch (self) {
            .arm64V8a => "aarch64-linux-android",
            .armeabiV7a => "arm-linux-androideabi",
            .x86_64 => "x86_64-linux-android",
            .x86 => "i686-linux-android",
        };
    }

    /// Returns the Zig target query for the ABI at Android API level `api`.
    ///
    /// Parameters:
    /// - `self`: the ABI.
    /// - `api`: the minimum Android API level.
    ///
    /// Return: the query.
    pub fn query(self: Self, api: u32) std.Target.Query {
        // The 32-bit ABIs name a CPU, since Android's baselines sit above Zig's:
        // armeabi-v7a devices are ARMv7-A with NEON (Cortex-A7), and x86 devices guarantee SSSE3.
        return switch (self) {
            .arm64V8a => .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .android, .android_api_level = api },
            .armeabiV7a => .{ .cpu_arch = .arm, .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_a7 }, .os_tag = .linux, .abi = .androideabi, .android_api_level = api },
            .x86_64 => .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .android, .android_api_level = api },
            .x86 => .{ .cpu_arch = .x86, .cpu_model = .{ .explicit = &std.Target.x86.cpu.i686 }, .cpu_features_add = std.Target.x86.featureSet(&.{.ssse3}), .os_tag = .linux, .abi = .android, .android_api_level = api },
        };
    }

    /// Returns the ABI a resolved target builds for.
    ///
    /// Parameters:
    /// - `target`: the target.
    ///
    /// Return: the ABI, or null when `target` is not Android.
    pub fn fromTarget(target: std.Target) ?Self {
        if (!target.abi.isAndroid()) return null;
        return switch (target.cpu.arch) {
            .aarch64 => .arm64V8a,
            .arm, .thumb => .armeabiV7a,
            .x86_64 => .x86_64,
            .x86 => .x86,
            else => null,
        };
    }
};

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
    /// Parameters:
    /// - `b`: the build graph; must outlive the handle.
    ///
    /// Return: the handle.
    pub fn init(b: *std.Build) !Self {
        var self = Self.initWith(b.allocator, b.graph.io);
        self.b = b;
        return self;
    }

    /// Creates an unresolved handle with no build graph, for the unit tests.
    ///
    /// Parameters:
    /// - `allocator`: backs the resolved paths; must outlive the handle.
    /// - `io`: IO for inspecting the SDK.
    ///
    /// Return: the handle, usable with `resolveFrom` but not `resolve` or `configure`.
    fn initWith(allocator: std.mem.Allocator, io: std.Io) Self {
        return Self{ .arena = std.heap.ArenaAllocator.init(allocator), .io = io };
    }

    /// Frees the resolved paths.
    ///
    /// Parameters:
    /// - `self`: the handle.
    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    /// Locates the SDK, the NDK and the NDK sysroot for this host.
    /// Poisons the configure cache: every build that resolves Android configures again.
    ///
    /// Parameters:
    /// - `self`: the handle to populate; its build graph's environment and host are read.
    ///
    /// Return: nothing; `error.AndroidSdkNotFound` naming what is missing.
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
    /// Parameters:
    /// - `b`: the build graph.
    /// - `abi`: the ABI.
    /// - `api`: the minimum API level, which the NDK's libraries are chosen by.
    ///
    /// Return: the resolved target.
    pub fn resolveTarget(b: *std.Build, abi: AndroidAbi, api: u32) std.Build.ResolvedTarget {
        return b.resolveTargetQuery(abi.query(api));
    }

    /// Makes `lib` link against the NDK: libc, the libc file, and 16 KB pages.
    ///
    /// Parameters:
    /// - `self`: a resolved handle.
    /// - `lib`: a library whose target came from `resolveTarget`.
    ///
    /// Return: nothing; `error.NotAndroid` when `lib`'s target is not Android.
    pub fn configure(self: *Self, lib: *std.Build.Step.Compile) !void {
        std.debug.assert(self.loaded);
        const resolved = lib.root_module.resolved_target orelse {
            log.err("{s} has no target; give it one from resolveTarget", .{lib.name});
            return error.NotAndroid;
        };
        const target = resolved.result;
        const abi = AndroidAbi.fromTarget(target) orelse {
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
    /// Parameters:
    /// - `self`: the handle.
    /// - `environ`: the build's environment.
    /// - `host`: the build host's OS, which picks the NDK prebuilt.
    ///
    /// Return: nothing; `error.AndroidSdkNotFound`, `error.AndroidNdkNotFound` or `error.UnsupportedHost`, naming the path in `missing`.
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
    /// Parameters:
    /// - `self`: the handle `resolveFrom` failed on; its `missing` names the path.
    /// - `err`: the error `resolveFrom` returned.
    ///
    /// Return: the message, owned by the handle; allocation errors.
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
    /// Parameters:
    /// - `self`: a resolved handle.
    /// - `abi`: the ABI.
    /// - `api`: the API level, which selects the sysroot's `usr/lib/<triple>/<api>`.
    ///
    /// Return: the file's text, owned by the handle; allocation errors.
    fn libCText(self: *Self, abi: AndroidAbi, api: u32) ![]const u8 {
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
    /// Parameters:
    /// - `self`: the handle.
    /// - `path`: the directory.
    ///
    /// Return: the entry's name, or null when the directory is absent or holds none; IO errors.
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
    /// Parameters:
    /// - `name`: a versioned name, e.g. `35.0.1` or `android-35`.
    ///
    /// Return: the numbers, or null when `name` holds none.
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
    /// Parameters:
    /// - `host`: the host OS.
    ///
    /// Return: the name, or null for a host the NDK does not support.
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
    /// Parameters:
    /// - `allocator`: owns the path.
    /// - `environ`: the build's environment.
    /// - `host`: the host OS.
    ///
    /// Return: the path; `error.AndroidSdkNotFound` when the home directory is unknown.
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

test "every ABI round-trips through its target" {
    const io = std.testing.io;
    for (std.enums.values(AndroidAbi)) |abi| {
        const target = try std.zig.system.resolveTargetQuery(io, abi.query(30));
        try std.testing.expectEqual(abi, AndroidAbi.fromTarget(target).?);
        try std.testing.expectEqual(@as(u32, 30), target.os.version_range.linux.android);
    }
    const desktop = try std.zig.system.resolveTargetQuery(io, .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu });
    try std.testing.expectEqual(@as(?AndroidAbi, null), AndroidAbi.fromTarget(desktop));
}

test "versionOf reads the numbers in a name" {
    try std.testing.expectEqual([4]u32{ 35, 0, 1, 0 }, Android.versionOf("35.0.1").?);
    try std.testing.expectEqual([4]u32{ 35, 0, 0, 0 }, Android.versionOf("android-35").?);
    try std.testing.expectEqual([4]u32{ 27, 2, 12479018, 0 }, Android.versionOf("27.2.12479018").?);
    try std.testing.expectEqual(@as(?[4]u32, null), Android.versionOf("android-Baklava"));
}

/// Builds a fake SDK under `root`: two NDKs, the newer with a sysroot for every host.
///
/// Parameters:
/// - `io`: IO for the filesystem.
/// - `root`: the directory to build it in.
///
/// Return: nothing; IO errors.
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
        const target = try std.zig.system.resolveTargetQuery(io, AndroidAbi.arm64V8a.query(30));
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
