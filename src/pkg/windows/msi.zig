const std = @import("std");
const mod = @import("../module.zig");

/// Text escaped for an XML attribute value, for `{f}` in a format string.
const Escaped = struct {
    const Self = @This();
    text: []const u8,

    /// Writes the text with `&`, `<`, `>` and `"` escaped.
    ///
    /// Parameters:
    /// - `self`: the text.
    /// - `w`: where it goes.
    ///
    /// Return: nothing; write errors.
    pub fn format(self: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.text) |c| switch (c) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '"' => try w.writeAll("&quot;"),
            else => try w.writeByte(c),
        };
    }
};

/// Describes a per-user Windows installer, as the WiX source `wixl` builds the `.msi` from.
///
/// The installer puts the programs in `%LOCALAPPDATA%\<org>\<name>\bin`,
/// appends that directory to the user's `PATH`, and removes both on
/// uninstall; it needs no administrator rights. Every GUID is derived from the
/// package id, so the same package always has the same UpgradeCode and
/// component GUIDs and a newer version replaces an older one.
///
/// Written for the subset of WiX that `wixl` (msitools) supports, which
/// ignores `RemoveFolder`'s `Directory` attribute: each directory therefore
/// gets its own component to remove it, with a per-user registry value as its
/// key path.
pub const Msi = struct {
    const Self = @This();
    /// The product name: the package's `.name`.
    name: []const u8,
    /// The organisation directory and Manufacturer: the last label of `.org`.
    org: []const u8,
    /// The package id, `<org>.<name>` in reverse DNS; seeds every GUID.
    id: []const u8,
    /// The package version, `major.minor.patch` with optional suffixes.
    version: []const u8,
    /// The programs' file names, installed in `bin`.
    files: []const []const u8,

    /// Stages the `.msi`'s files and WiX source, and builds it with the `wixl` on `PATH`.
    ///
    /// Without `wixl`, the WiX source is copied to `zig-out/pkg/` and the step
    /// fails with the command that would build the installer.
    ///
    /// Parameters:
    /// - `pkg`: the package.
    /// - `stage`: an empty staging directory.
    ///
    /// Return: nothing; `error.MakeFailed`, or IO errors.
    pub fn build(pkg: *mod.Pkg, stage: []const u8) !void {
        const b = pkg.step.owner;
        const io = b.graph.io;
        _ = try pkg.copyExecutables(b.pathJoin(&.{ stage, "bin" }));
        var files: std.ArrayList([]const u8) = .empty;
        for (pkg.executables) |exe| try files.append(b.allocator, exe.out_filename);
        const msi = Self{ .name = pkg.name, .org = pkg.orgLabel(), .id = pkg.id(), .version = pkg.version, .files = files.items };
        const xml = msi.render(b.allocator) catch |err| switch (err) {
            error.InvalidVersion => return pkg.step.fail(".version = \"{s}\" is not one an MSI can carry: major.minor.patch, at most 255.255.65535", .{pkg.version}),
            else => return err,
        };
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = b.pathJoin(&.{ stage, "product.wxs" }), .data = xml });
        const out = try pkg.outputPath();
        const platform = Self.arch(pkg.target.cpu.arch).?;
        const argv = [_][]const u8{ "wixl", "-a", platform, "-o", out, "product.wxs" };
        const result = std.process.run(b.allocator, io, .{ .argv = &argv, .cwd = .{ .path = stage } }) catch |err| switch (err) {
            error.FileNotFound => {
                const wxs = b.getInstallPath(.prefix, b.fmt("pkg/{s}-{s}.wxs", .{ pkg.name, pkg.version }));
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = wxs, .data = xml });
                return pkg.step.fail("wixl is not on PATH (apt install wixl, or Homebrew's msitools); wrote {s}; to build the installer: cd {s} && wixl -a {s} -o {s} product.wxs", .{ wxs, stage, platform, out });
            },
            else => return err,
        };
        try pkg.checkTool(&argv, result, null);
    }

    /// Maps a CPU architecture to the `wixl -a` platform.
    ///
    /// `wixl` has no arm64 platform. An `x86` package installs on every
    /// Windows, and a per-user install under `%LOCALAPPDATA%` does not depend on
    /// the package's bitness, so arm64 programs ship in one.
    ///
    /// Parameters:
    /// - `cpu`: the target's architecture.
    ///
    /// Return: `x64` or `x86`, or `null` for any other.
    pub fn arch(cpu: std.Target.Cpu.Arch) ?[]const u8 {
        return switch (cpu) {
            .x86_64 => "x64",
            .x86, .aarch64 => "x86",
            else => null,
        };
    }

    /// Renders the `.wxs` file.
    ///
    /// Parameters:
    /// - `self`: the installer description.
    /// - `allocator`: allocator for the result.
    ///
    /// Return: the XML, owned by the caller; `error.InvalidVersion` when the
    /// version is not one an MSI can carry.
    pub fn render(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        const version = try Self.msiVersion(self.version);
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<Wix xmlns=\"http://schemas.microsoft.com/wix/2006/wi\">\n");
        try w.print("  <Product Id=\"*\" Name=\"{f}\" Language=\"1033\" Version=\"{s}\" Manufacturer=\"{f}\" UpgradeCode=\"{s}\">\n", .{ Escaped{ .text = self.name }, version, Escaped{ .text = self.org }, &Self.guid(self.id, "upgrade") });
        try w.writeAll("    <Package InstallerVersion=\"500\" Compressed=\"yes\" InstallScope=\"perUser\" />\n");
        try w.print("    <MajorUpgrade DowngradeErrorMessage=\"A newer version of {f} is already installed.\" />\n", .{Escaped{ .text = self.name }});
        try w.writeAll("    <Media Id=\"1\" Cabinet=\"product.cab\" EmbedCab=\"yes\" />\n");
        try w.writeAll("    <Directory Id=\"TARGETDIR\" Name=\"SourceDir\">\n      <Directory Id=\"LocalAppDataFolder\">\n");
        try w.print("        <Directory Id=\"OrgDir\" Name=\"{f}\">\n", .{Escaped{ .text = self.org }});
        try w.print("          <Directory Id=\"INSTALLDIR\" Name=\"{f}\">\n", .{Escaped{ .text = self.name }});
        try w.writeAll("            <Directory Id=\"BinDir\" Name=\"bin\">\n");
        try w.print("              <Component Id=\"Bin\" Guid=\"{s}\">\n", .{&Self.guid(self.id, "bin")});
        for (self.files, 0..) |file, i| {
            try w.print("                <File Id=\"file{d}\" Name=\"{f}\" Source=\"bin/{f}\" />\n", .{ i, Escaped{ .text = file }, Escaped{ .text = file } });
        }
        try self.keyPath(w, "bin", "                ");
        try w.writeAll("                <Environment Id=\"UserPath\" Name=\"PATH\" Value=\"[BinDir]\" Permanent=\"no\" Part=\"last\" Action=\"set\" System=\"no\" />\n");
        try w.writeAll("                <RemoveFolder Id=\"RemoveBin\" On=\"uninstall\" />\n              </Component>\n            </Directory>\n");
        try w.print("            <Component Id=\"InstallDir\" Guid=\"{s}\">\n", .{&Self.guid(self.id, "install")});
        try self.keyPath(w, "install", "              ");
        try w.writeAll("              <RemoveFolder Id=\"RemoveInstall\" On=\"uninstall\" />\n            </Component>\n          </Directory>\n");
        try w.print("          <Component Id=\"OrgDir\" Guid=\"{s}\">\n", .{&Self.guid(self.id, "org")});
        try self.keyPath(w, "org", "            ");
        try w.writeAll("            <RemoveFolder Id=\"RemoveOrg\" On=\"uninstall\" />\n          </Component>\n");
        try w.writeAll("        </Directory>\n      </Directory>\n    </Directory>\n");
        try w.writeAll("    <Feature Id=\"Main\" Level=\"1\">\n      <ComponentRef Id=\"Bin\" />\n      <ComponentRef Id=\"InstallDir\" />\n      <ComponentRef Id=\"OrgDir\" />\n    </Feature>\n");
        try w.writeAll("  </Product>\n</Wix>\n");
        return out.toOwnedSlice();
    }

    /// Reduces a package version to the `major.minor.build` an MSI carries.
    ///
    /// A prerelease or build suffix (`-rc.1`, `+abc`) is dropped; Windows
    /// compares only the three numbers.
    ///
    /// Parameters:
    /// - `version`: the package version.
    ///
    /// Return: the leading `major.minor.patch` of `version`;
    /// `error.InvalidVersion` when it is not three numbers within 255.255.65535.
    pub fn msiVersion(version: []const u8) ![]const u8 {
        const end = std.mem.indexOfAny(u8, version, "-+") orelse version.len;
        const core = version[0..end];
        var parts = std.mem.splitScalar(u8, core, '.');
        const limits = [_]u32{ 255, 255, 65535 };
        for (limits) |limit| {
            const part = parts.next() orelse return error.InvalidVersion;
            const number = std.fmt.parseInt(u32, part, 10) catch return error.InvalidVersion;
            if (number > limit) return error.InvalidVersion;
        }
        if (parts.next() != null) return error.InvalidVersion;
        return core;
    }

    /// Derives a stable GUID from the package id and a purpose, in the style of a name-based (version 5) UUID.
    ///
    /// Parameters:
    /// - `id`: the package id.
    /// - `purpose`: what the GUID is for, e.g. `upgrade` or a component.
    ///
    /// Return: the GUID, lowercase with dashes.
    pub fn guid(id: []const u8, purpose: []const u8) [36]u8 {
        var hash: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
        var sha1 = std.crypto.hash.Sha1.init(.{});
        sha1.update("zigbuildx.wix:");
        sha1.update(id);
        sha1.update(":");
        sha1.update(purpose);
        sha1.final(&hash);
        var bytes = hash[0..16].*;
        bytes[6] = (bytes[6] & 0x0f) | 0x50;
        bytes[8] = (bytes[8] & 0x3f) | 0x80;
        var out: [36]u8 = undefined;
        const hex = "0123456789abcdef";
        var at: usize = 0;
        for (bytes, 0..) |byte, i| {
            if (i == 4 or i == 6 or i == 8 or i == 10) {
                out[at] = '-';
                at += 1;
            }
            out[at] = hex[byte >> 4];
            out[at + 1] = hex[byte & 0x0f];
            at += 2;
        }
        return out;
    }

    /// Writes a component's key path: a value under `HKCU\Software\<org>\<name>`.
    ///
    /// A per-user component cannot use a file as its key path, so each one
    /// records itself in the user's registry instead.
    ///
    /// Parameters:
    /// - `self`: the installer description.
    /// - `w`: the XML being written.
    /// - `value`: the value's name, one per component.
    /// - `indent`: the line's leading spaces.
    ///
    /// Return: nothing; write errors.
    fn keyPath(self: *const Self, w: *std.Io.Writer, value: []const u8, indent: []const u8) !void {
        try w.print("{s}<RegistryValue Root=\"HKCU\" Key=\"Software\\{f}\\{f}\" Name=\"{s}\" Type=\"integer\" Value=\"1\" KeyPath=\"yes\" />\n", .{ indent, Escaped{ .text = self.org }, Escaped{ .text = self.name }, value });
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test "arch maps to wixl platforms, arm64 to x86" {
    try std.testing.expectEqualStrings("x64", Msi.arch(.x86_64).?);
    try std.testing.expectEqualStrings("x86", Msi.arch(.aarch64).?);
    try std.testing.expectEqual(null, Msi.arch(.riscv64));
}

test "msiVersion keeps three numbers and drops suffixes" {
    try std.testing.expectEqualStrings("1.2.3", try Msi.msiVersion("1.2.3"));
    try std.testing.expectEqualStrings("0.0.2", try Msi.msiVersion("0.0.2-rc.1+abc"));
    try std.testing.expectError(error.InvalidVersion, Msi.msiVersion("1.2"));
    try std.testing.expectError(error.InvalidVersion, Msi.msiVersion("256.0.0"));
    try std.testing.expectError(error.InvalidVersion, Msi.msiVersion("1.2.3.4"));
}

test "guid is stable, distinct per purpose, and shaped like a version 5 UUID" {
    const a = Msi.guid("com.acme.tool", "upgrade");
    try std.testing.expectEqualStrings(&a, &Msi.guid("com.acme.tool", "upgrade"));
    try std.testing.expect(!std.mem.eql(u8, &a, &Msi.guid("com.acme.tool", "bin")));
    try std.testing.expectEqual('5', a[14]);
    try std.testing.expectEqual('-', a[8]);
}

test "render writes a per-user product with the files, PATH entry and escaped names" {
    const allocator = std.testing.allocator;
    const wix = Msi{ .name = "tool", .org = "a&b", .id = "com.ab.tool", .version = "1.0.0", .files = &.{ "tool.exe", "helper.exe" } };
    const xml = try wix.render(allocator);
    defer allocator.free(xml);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<Wix xmlns=\"http://schemas.microsoft.com/wix/2006/wi\">") != null);
    try std.testing.expect(std.mem.endsWith(u8, xml, "</Wix>\n"));
    for ([_][]const u8{
        "InstallScope=\"perUser\"",
        "Manufacturer=\"a&amp;b\"",
        "<Directory Id=\"LocalAppDataFolder\">",
        "<File Id=\"file1\" Name=\"helper.exe\" Source=\"bin/helper.exe\" />",
        "<Environment Id=\"UserPath\" Name=\"PATH\" Value=\"[BinDir]\"",
        "Key=\"Software\\a&amp;b\\tool\"",
    }) |needle| {
        if (std.mem.indexOf(u8, xml, needle) == null) {
            std.debug.print("missing: {s}\n", .{needle});
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expect(std.mem.indexOf(u8, xml, &Msi.guid("com.ab.tool", "upgrade")) != null);
}
