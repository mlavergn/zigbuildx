//! Barrel for `src/platform/`: target platforms' SDKs and toolchains, and the app laid out as each platform runs it.

const std = @import("std");

/// Locates an Apple platform's SDK and pins the macOS deployment floor.
pub const Xcode = @import("xcode.zig").Xcode;
/// What `Xcode.addXcframework` assembles.
pub const Xcframework = @import("xcode.zig").Xcframework;
/// Builds Swift dylibs and links modules against them.
pub const Swift = @import("swift.zig").Swift;
/// What `Swift.addDylib` compiles.
pub const SwiftDylib = @import("swift.zig").SwiftDylib;
/// Installs a GUI executable as its platform expects: a macOS `.app`, a Linux desktop entry.
pub const App = @import("app.zig").App;
/// What `App.addBundle` assembles and `App.addInstall` installs.
pub const AppBundle = @import("app.zig").AppBundle;
/// A file placed in an app bundle under its own name.
pub const AppFile = @import("app.zig").AppFile;
/// What a Linux desktop entry's launcher may hand the app on its command line.
pub const AppOpens = @import("app.zig").AppOpens;
/// Builds Android native libraries.
pub const Android = @import("android.zig").Android;
/// An Android ABI and its Zig target.
pub const AndroidAbi = @import("android_abi.zig").AndroidAbi;

test {
    std.testing.refAllDecls(@This());
}
