const std = @import("std");

/// An Android ABI: what an APK names the directory holding its native libraries.
pub const AndroidAbi = enum {
    const Self = @This();

    /// 64-bit ARM (`arm64-v8a`).
    arm64V8a,
    /// 32-bit ARMv7 (`armeabi-v7a`).
    armeabiV7a,
    /// 64-bit x86 (`x86_64`).
    x86_64,
    /// 32-bit x86 (`x86`).
    x86,

    /// Returns the ABI's directory under `lib/` in an APK.
    ///
    /// - `self`: The ABI.
    /// - Returns: The name, e.g. `arm64-v8a`.
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
    /// - `self`: The ABI.
    /// - Returns: The triple, e.g. `aarch64-linux-android`.
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
    /// - `self`: The ABI.
    /// - `api`: The minimum Android API level.
    /// - Returns: The query.
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
    /// - `target`: The target.
    /// - Returns: The ABI, or null when `target` is not Android.
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
