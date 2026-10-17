const std = @import("std");
const log = std.log.scoped(.zigbuildx_pkgbuild);
const mod = @import("../module.zig");

/// Builds and notarizes a macOS installer package with Apple's tools.
///
/// The host tool's `pkg` command calls `build`, which stages the package,
/// signs the programs with `codesign` and builds the `.pkg` with `pkgbuild`;
/// `notarize` submits it to Apple with `notarytool` and staples the ticket.
/// The identities and credentials come from the project's `signing.zon`.
pub const Pkgbuild = struct {
    const Self = @This();

    /// Stages, signs and builds the macOS `.pkg` with `codesign` and `pkgbuild`.
    ///
    /// Without a `signing.zon`, the package is built unsigned, with a warning.
    ///
    /// Parameters:
    /// - `run`: the host tool's `pkg` run.
    /// - `stage`: an empty staging directory.
    /// - `out`: where the package goes.
    ///
    /// Return: nothing; `error.PkgFailed`, or IO errors.
    pub fn build(run: *const mod.PkgRun, stage: []const u8, out: []const u8) !void {
        const allocator = run.allocator;
        const root = try std.Io.Dir.path.join(allocator, &.{ stage, "root" });
        const scripts = try std.Io.Dir.path.join(allocator, &.{ stage, "scripts" });
        const bins = try run.copyExecutables(try std.Io.Dir.path.join(allocator, &.{ root, "bin" }));
        const libs = try run.copyLibraries(try std.Io.Dir.path.join(allocator, &.{ root, "lib" }));
        try run.writeScript(try std.Io.Dir.path.join(allocator, &.{ root, "uninstall.sh" }), "uninstall.sh", true);
        try run.writeScript(try std.Io.Dir.path.join(allocator, &.{ scripts, "preinstall" }), "preinstall", true);
        try run.writeScript(try std.Io.Dir.path.join(allocator, &.{ scripts, "postinstall" }), "postinstall", true);

        const signing = try run.signing();
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(allocator, &.{ "pkgbuild", "--identifier", run.id(), "--version", run.version });
        if (signing) |settings| {
            const application = try allocator.print("Developer ID Application: {s} ({s})", .{ settings.apple_name.?, settings.apple_team.? });
            // Notarization refuses a package holding any unsigned Mach-O, libraries included.
            for (libs) |lib| _ = try run.runTool(&.{ "codesign", "-s", application, "--timestamp", "-o", "runtime", "-f", lib }, null);
            for (bins) |bin| _ = try run.runTool(&.{ "codesign", "-s", application, "--timestamp", "-o", "runtime", "-f", bin }, null);
            try argv.appendSlice(allocator, &.{ "--sign", try allocator.print("Developer ID Installer: {s} ({s})", .{ settings.apple_name.?, settings.apple_team.? }) });
        } else {
            log.warn("no signing.zon in {s}; building {s} unsigned", .{ run.root, std.Io.Dir.path.basename(out) });
        }
        try argv.appendSlice(allocator, &.{ "--scripts", scripts, "--install-location", try allocator.print("/usr/local/{s}/{s}", .{ run.orgLabel(), run.name }), "--root", root, out });
        _ = try run.runTool(argv.items, null);
    }

    /// Notarizes a macOS package with `notarytool` and staples the ticket to it.
    ///
    /// Parameters:
    /// - `run`: the host tool's `pkg` run, for `signing.zon`.
    /// - `out`: the package, changed in place.
    ///
    /// Return: nothing; `error.PkgFailed` when credentials are missing or Apple
    /// does not accept the package.
    pub fn notarize(run: *const mod.PkgRun, out: []const u8) !void {
        const settings = try run.signing() orelse return run.fail("pkg-notarize needs a signing.zon with .apple_id, .apple_password, .apple_name and .apple_team", .{});
        const apple_id = settings.apple_id orelse return run.fail("signing.zon has no .apple_id", .{});
        const password = settings.apple_password orelse return run.fail("signing.zon has no .apple_password", .{});
        const result = try run.runTool(&.{ "xcrun", "notarytool", "submit", out, "--apple-id", apple_id, "--team-id", settings.apple_team.?, "--password", password, "--wait" }, password);
        if (std.mem.find(u8, result.stdout, "status: Accepted") == null) {
            return run.fail("Apple did not accept {s}:\n{s}", .{ std.Io.Dir.path.basename(out), result.stdout });
        }
        _ = try run.runTool(&.{ "xcrun", "stapler", "staple", out }, null);
    }
};
