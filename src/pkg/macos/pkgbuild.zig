const std = @import("std");
const log = std.log.scoped(.zigbuildx_pkgbuild);
const mod = @import("../module.zig");

/// Builds and notarizes a macOS installer package with Apple's tools.
///
/// `Pkg` stages the package and calls `build`, which signs the programs with
/// `codesign` and builds the `.pkg` with `pkgbuild`; `notarize` submits it to
/// Apple with `notarytool` and staples the ticket. The identities and
/// credentials come from the project's `signing.zon`.
pub const Pkgbuild = struct {
    const Self = @This();

    /// Stages, signs and builds the macOS `.pkg` with `codesign` and `pkgbuild`.
    ///
    /// Without a `signing.zon`, the package is built unsigned, with a warning.
    ///
    /// Parameters:
    /// - `pkg`: the package.
    /// - `stage`: an empty staging directory.
    ///
    /// Return: nothing; `error.MakeFailed`, or IO errors.
    pub fn build(pkg: *mod.Pkg, stage: []const u8) !void {
        const b = pkg.step.owner;
        const root = b.pathJoin(&.{ stage, "root" });
        const scripts = b.pathJoin(&.{ stage, "scripts" });
        const bins = try pkg.copyExecutables(b.pathJoin(&.{ root, "bin" }));
        try pkg.writeScript(b.pathJoin(&.{ root, "uninstall.sh" }), "uninstall.sh", true);
        try pkg.writeScript(b.pathJoin(&.{ scripts, "preinstall" }), "preinstall", true);
        try pkg.writeScript(b.pathJoin(&.{ scripts, "postinstall" }), "postinstall", true);

        const signing = try pkg.signing();
        const out = try pkg.outputPath();
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(b.allocator, &.{ "pkgbuild", "--identifier", pkg.id(), "--version", pkg.version });
        if (signing) |settings| {
            const application = b.fmt("Developer ID Application: {s} ({s})", .{ settings.apple_name.?, settings.apple_team.? });
            for (bins) |bin| try pkg.runTool(&.{ "codesign", "-s", application, "--timestamp", "-o", "runtime", "-f", bin }, null, null);
            try argv.appendSlice(b.allocator, &.{ "--sign", b.fmt("Developer ID Installer: {s} ({s})", .{ settings.apple_name.?, settings.apple_team.? }) });
        } else {
            log.warn("no signing.zon in {s}; building {s} unsigned", .{ b.build_root.path orelse ".", std.fs.path.basename(out) });
        }
        try argv.appendSlice(b.allocator, &.{ "--scripts", scripts, "--install-location", b.fmt("/usr/local/{s}/{s}", .{ pkg.orgLabel(), pkg.name }), "--root", root, out });
        try pkg.runTool(argv.items, null, null);
    }

    /// Notarizes the macOS package with `notarytool` and staples the ticket to it.
    ///
    /// Parameters:
    /// - `pkg`: the package, already built by `build`.
    ///
    /// Return: nothing; `error.MakeFailed` when credentials are missing or Apple
    /// does not accept the package.
    pub fn notarize(pkg: *mod.Pkg) !void {
        const step = &pkg.notarize_step;
        const settings = try pkg.signing() orelse return step.fail("pkg-notarize needs a signing.zon with .apple_id, .apple_password, .apple_name and .apple_team", .{});
        const apple_id = settings.apple_id orelse return step.fail("signing.zon has no .apple_id", .{});
        const password = settings.apple_password orelse return step.fail("signing.zon has no .apple_password", .{});
        const out = try pkg.outputPath();
        const b = step.owner;
        const submit = [_][]const u8{ "xcrun", "notarytool", "submit", out, "--apple-id", apple_id, "--team-id", settings.apple_team.?, "--password", password, "--wait" };
        const result = try std.process.run(b.allocator, b.graph.io, .{ .argv = &submit });
        try pkg.checkTool(&submit, result, password);
        if (std.mem.indexOf(u8, result.stdout, "status: Accepted") == null) {
            return step.fail("Apple did not accept {s}:\n{s}", .{ std.fs.path.basename(out), result.stdout });
        }
        try pkg.runTool(&.{ "xcrun", "stapler", "staple", out }, null, null);
    }
};
