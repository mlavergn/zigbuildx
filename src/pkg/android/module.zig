const std = @import("std");

/// The parent barrel, for the zigbuildx types the APK packager uses.
const parent = @import("../module.zig");

pub const Apk = @import("apk.zig").Apk;
pub const ApkOptions = @import("apk.zig").ApkOptions;
pub const ApkZip = @import("apk_zip.zig").ApkZip;
pub const Android = parent.Android;
pub const AndroidAbi = parent.AndroidAbi;
pub const HostTool = parent.HostTool;

test {
    std.testing.refAllDecls(@This());
}
