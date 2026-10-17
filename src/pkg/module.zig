const std = @import("std");

/// The parent barrel, for the zigbuildx types the packagers use.
const parent = @import("../module.zig");

pub const Pkg = @import("pkg.zig").Pkg;
pub const PkgLibrary = @import("pkg.zig").PkgLibrary;
pub const PkgOptions = @import("pkg.zig").PkgOptions;
pub const PkgRun = @import("pkg.zig").PkgRun;
pub const Signing = @import("pkg.zig").Signing;
pub const Pkgbuild = @import("macos/pkgbuild.zig").Pkgbuild;
pub const Deb = @import("linux/deb.zig").Deb;
pub const Msi = @import("windows/msi.zig").Msi;
pub const android = @import("android/module.zig");
pub const Git = parent.Git;
pub const HostTool = parent.HostTool;
pub const Android = parent.Android;
pub const AndroidAbi = parent.AndroidAbi;

test {
    std.testing.refAllDecls(@This());
}
