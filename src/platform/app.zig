const std = @import("std");

/// A file placed in an app bundle under its own name.
pub const AppFile = struct {
    const Self = @This();
    /// The file.
    path: std.Build.LazyPath,
    /// Its name in the bundle directory it lands in: `libshim.dylib` in `Contents/Frameworks`.
    name: []const u8,
};

/// What a Linux desktop entry's launcher may hand the app on its command line:
/// the `Exec` field code (`%f`, `%F`, `%u`, `%U`).
pub const AppOpens = enum {
    const Self = @This();
    /// Nothing: the app opens no files (no field code).
    nothing,
    /// One local file or folder (`%f`).
    file,
    /// Any number of local files or folders (`%F`).
    files,
    /// One file or URL (`%u`).
    url,
    /// Any number of files or URLs (`%U`).
    urls,

    /// Returns the `Exec` field code, with the space before it.
    ///
    /// - `self`: What the app opens.
    /// - Returns: ` %f`, ` %F`, ` %u` or ` %U`, or empty for `nothing`.
    fn execSuffix(self: Self) []const u8 {
        return switch (self) {
            .nothing => "",
            .file => " %f",
            .files => " %F",
            .url => " %u",
            .urls => " %U",
        };
    }
};

/// What `App.addBundle` assembles and `App.addInstall` installs.
pub const AppBundle = struct {
    const Self = @This();
    /// The app's name: `Hello` builds `Hello.app/Contents/MacOS/Hello`, `bin/Hello` and `Hello.desktop`.
    name: []const u8,
    /// The bundle identifier, reverse DNS (`com.example.hello`): `CFBundleIdentifier`.
    identifier: []const u8,
    /// The version, such as `build.zig.zon`'s: `CFBundleShortVersionString` and
    /// `CFBundleVersion`, without a pre-release or build suffix (`1.2.0-rc1` gives `1.2.0`).
    version: []const u8,
    /// The executable; its target picks the layout.
    exe: *std.Build.Step.Compile,
    /// The macOS icon, installed as `Contents/Resources/<name>.icns`; null for none.
    icns: ?std.Build.LazyPath = null,
    /// The Linux icon, a 256×256 PNG under `share/icons/hicolor`; null for none.
    png: ?std.Build.LazyPath = null,
    /// Dynamic libraries for `Contents/Frameworks`; any adds the
    /// `@executable_path/../Frameworks` rpath to `exe`.
    frameworks: []const AppFile = &.{},
    /// Files for `Contents/Resources`.
    resources: []const AppFile = &.{},
    /// Raw `<key>…</key>` lines added at the end of `Info.plist`'s dictionary.
    plist_extra: []const u8 = "",
    /// The desktop entry's `Comment`; empty for none.
    comment: []const u8 = "",
    /// The desktop entry's `Categories`.
    categories: []const u8 = "Development;",
    /// What the desktop entry's launcher hands the app: `.file` passes one
    /// file (`Exec=<name> %f`).
    opens: AppOpens = .nothing,
    /// The desktop entry's `MimeType`, the types a file manager offers the app
    /// for (`text/plain;inode/directory;`); empty for none. Needs `opens`.
    mime_types: []const u8 = "",
    /// A directory under the prefix the Linux layout goes in (`Hello` gives
    /// `Hello/bin`, `Hello/share/…`); empty for the prefix itself.
    linux_subdir: []const u8 = "",
};

/// Installs a GUI executable the way its platform expects.
///
/// A macOS target gets a `<name>.app` bundle at the top of the prefix,
/// installed unsigned; a Linux target gets `bin/<name>`, a desktop entry and an
/// icon under `share/`; any other target gets the executable alone.
pub const App = struct {
    const Self = @This();
    /// `LSMinimumSystemVersion` when the target states no macOS floor.
    pub const default_macos_min = "13.0";
    /// The `share/icons/hicolor` size directory the Linux icon goes in.
    pub const linux_icon_size = "256x256";
    /// The most numbers `CFBundleVersion` takes: `major.minor.patch`.
    pub const max_version_numbers = 3;
    /// The rpath `frameworks` adds, where the bundle keeps them.
    pub const frameworks_rpath = "@executable_path/../Frameworks";
    /// Characters an app name may not hold: path separators, line breaks, and
    /// what a desktop entry's quoted `Exec` argument would have to escape.
    const name_forbidden = "/\\\r\n\"`$%";
    /// Characters that make a desktop entry's `Exec` argument need quotes.
    const exec_reserved = " \t'<>~|&;*?#()";

    /// Assembles `<name>.app` for a macOS target, from any host.
    ///
    /// - `b`: The build graph.
    /// - `options`: The app.
    /// - Returns: The `<name>.app` directory, or null when the target is not macOS.
    pub fn addBundle(b: *std.Build, options: AppBundle) ?std.Build.LazyPath {
        const target = Self.targetOf(b, options);
        if (target.result.os.tag != .macos) return null;
        const bundle = b.fmt("{s}.app", .{options.name});
        const contents = b.fmt("{s}/Contents", .{bundle});
        const files = b.addWriteFiles();
        files.step.name = b.fmt("app bundle {s}", .{bundle});
        if (Self.addProblemFail(b, options)) |fail| files.step.dependOn(fail);
        // A version the check refuses still writes a plist; the failure above stops the build first.
        const version = Self.bundleVersion(options.version) orelse options.version;
        const macos_min = Self.macosMin(b.allocator, target.query) catch @panic("OOM");
        _ = files.add(b.fmt("{s}/Info.plist", .{contents}), Self.plistText(b.allocator, options, version, macos_min) catch @panic("OOM"));
        _ = files.addCopyFile(options.exe.getEmittedBin(), b.fmt("{s}/MacOS/{s}", .{ contents, options.name }));
        if (options.icns) |icns| _ = files.addCopyFile(icns, b.fmt("{s}/Resources/{s}.icns", .{ contents, options.name }));
        for (options.resources) |file| _ = files.addCopyFile(file.path, b.fmt("{s}/Resources/{s}", .{ contents, file.name }));
        for (options.frameworks) |file| _ = files.addCopyFile(file.path, b.fmt("{s}/Frameworks/{s}", .{ contents, file.name }));
        // Special, not a path: normalizing would collapse `@executable_path/..`. Once, as a
        // consumer may add it itself.
        if (options.frameworks.len != 0 and !Self.hasRPath(options.exe.root_module, Self.frameworks_rpath)) {
            options.exe.root_module.addRPathSpecial(Self.frameworks_rpath);
        }
        return files.getDirectory().path(b, bundle);
    }

    /// Creates a step installing the app for its target's platform.
    ///
    /// - `b`: The build graph.
    /// - `options`: The app.
    /// - `bundle`: `addBundle`'s answer for these options, or null to assemble it here.
    /// - Returns: The install step, not yet attached to any step.
    pub fn addInstall(b: *std.Build, options: AppBundle, bundle: ?std.Build.LazyPath) *std.Build.Step {
        const target = Self.targetOf(b, options);
        switch (target.result.os.tag) {
            .macos => {
                const dir = bundle orelse Self.addBundle(b, options).?;
                // At the top of the prefix, where a packager looks for it.
                const bundle_name = b.fmt("{s}.app", .{options.name});
                const install = b.addInstallDirectory(.{ .source_dir = dir, .install_dir = .prefix, .install_subdir = bundle_name });
                install.step.name = b.fmt("install {s}", .{bundle_name});
                return &install.step;
            },
            .linux => return Self.addLinuxInstall(b, options),
            else => {
                const install = b.addInstallArtifact(options.exe, .{});
                if (Self.addProblemFail(b, options)) |fail| install.step.dependOn(fail);
                return &install.step;
            },
        }
    }

    /// Creates the Linux install: the executable, its desktop entry and its icon.
    ///
    /// - `b`: The build graph.
    /// - `options`: The app.
    /// - Returns: The executable's install step, which depends on the others.
    fn addLinuxInstall(b: *std.Build, options: AppBundle) *std.Build.Step {
        const subdir = options.linux_subdir;
        const bin = Self.linuxPath(b.allocator, subdir, "bin") catch @panic("OOM");
        const install = b.addInstallArtifact(options.exe, .{ .dest_dir = .{ .override = .{ .custom = bin } }, .dest_sub_path = options.name });
        const desktop_name = b.fmt("{s}.desktop", .{options.name});
        const desktop = b.addWriteFiles().add(desktop_name, Self.desktopText(b.allocator, options) catch @panic("OOM"));
        const applications = Self.linuxPath(b.allocator, subdir, b.fmt("share/applications/{s}", .{desktop_name})) catch @panic("OOM");
        const install_desktop = b.addInstallFile(desktop, applications);
        install.step.dependOn(&install_desktop.step);
        const install_icon = if (options.png) |png| b.addInstallFile(png, Self.linuxPath(b.allocator, subdir, b.fmt("share/icons/hicolor/{s}/apps/{s}.png", .{ Self.linux_icon_size, options.name })) catch @panic("OOM")) else null;
        if (install_icon) |icon| install.step.dependOn(&icon.step);
        // Every install waits on the failure, or bad options would still install the desktop entry and icon.
        if (Self.addProblemFail(b, options)) |fail| {
            install.step.dependOn(fail);
            install_desktop.step.dependOn(fail);
            if (install_icon) |icon| icon.step.dependOn(fail);
        }
        return &install.step;
    }

    /// Creates a step failing with the options' first problem, when they have one.
    ///
    /// - `b`: The build graph.
    /// - `options`: The app.
    /// - Returns: The failing step, for the steps that must not run, or null when nothing is wrong.
    fn addProblemFail(b: *std.Build, options: AppBundle) ?*std.Build.Step {
        const message = Self.problem(b.allocator, options) catch @panic("OOM") orelse return null;
        return &b.addFail(message).step;
    }

    /// Reports whether `module` already has the special rpath `rpath`.
    ///
    /// - `module`: The module.
    /// - `rpath`: The special rpath (`@executable_path/../Frameworks`).
    /// - Returns: `true` when one of its rpaths is `rpath`.
    fn hasRPath(module: *const std.Build.Module, rpath: []const u8) bool {
        for (module.rpaths.items) |existing| switch (existing) {
            .special => |special| if (std.mem.eql(u8, special, rpath)) return true,
            .lazy_path => {},
        };
        return false;
    }

    /// Returns the executable's target, or the host's when its module has none.
    ///
    /// - `b`: The build graph.
    /// - `options`: The app.
    /// - Returns: The target.
    fn targetOf(b: *std.Build, options: AppBundle) std.Build.ResolvedTarget {
        return options.exe.root_module.resolved_target orelse b.graph.host;
    }

    /// Joins a path under the prefix to the Linux layout's directory.
    ///
    /// - `allocator`: Owns the joined path.
    /// - `subdir`: `AppBundle.linux_subdir`; empty for the prefix itself.
    /// - `path`: The path under it.
    /// - Returns: The path relative to the prefix, `path` itself without a `subdir`; allocation errors.
    fn linuxPath(allocator: std.mem.Allocator, subdir: []const u8, path: []const u8) ![]const u8 {
        if (subdir.len == 0) return path;
        return allocator.print("{s}/{s}", .{ subdir, path });
    }

    /// Describes the first thing wrong with `options`, as the build's failure message.
    ///
    /// - `allocator`: Owns the message.
    /// - `options`: The app.
    /// - Returns: The message, or null when nothing is wrong; allocation errors.
    fn problem(allocator: std.mem.Allocator, options: AppBundle) !?[]u8 {
        const name = options.name;
        if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or std.mem.findAny(u8, name, Self.name_forbidden) != null) {
            return try allocator.print("app name \"{s}\" must be non-empty, not . or .., with no / \\ \" ` $ % or line break", .{name});
        }
        if (!Self.isValidIdentifier(options.identifier)) {
            return try allocator.print("{s}: identifier \"{s}\" must be reverse DNS of letters, digits, '.' and '-' (com.example.app)", .{ options.name, options.identifier });
        }
        if (Self.bundleVersion(options.version) == null) {
            return try allocator.print("{s}: version \"{s}\" must be one to three numbers (1.2.3), optionally with a -pre-release or +build suffix", .{ options.name, options.version });
        }
        for ([_][]const u8{ options.comment, options.categories, options.mime_types }) |value| {
            if (std.mem.findAny(u8, value, "\r\n") != null) return try allocator.print("{s}: a desktop entry value holds a line break", .{options.name});
        }
        if (options.mime_types.len != 0 and options.opens == .nothing) {
            return try allocator.print("{s}: mime_types needs opens, or the app is offered files it is never handed", .{options.name});
        }
        if (options.linux_subdir.len != 0 and !Self.isContainedPath(options.linux_subdir)) {
            return try allocator.print("{s}: linux_subdir \"{s}\" must be a relative path with no . or .. part", .{ options.name, options.linux_subdir });
        }
        for ([_][]const AppFile{ options.frameworks, options.resources }) |files| for (files) |file| {
            if (!Self.isContainedPath(file.name)) return try allocator.print("{s}: bundle file name \"{s}\" must be a relative path with no . or .. part", .{ options.name, file.name });
        };
        return null;
    }

    /// Returns `version` without a pre-release or build suffix, when one to three numbers remain.
    ///
    /// - `version`: The version (`1.2.0-rc1+42`).
    /// - Returns: The numbers (`1.2.0`), a slice of `version`, or null when they are not one to three numbers.
    fn bundleVersion(version: []const u8) ?[]const u8 {
        const numbers = version[0 .. std.mem.findAny(u8, version, "-+") orelse version.len];
        var parts = std.mem.splitScalar(u8, numbers, '.');
        var count: usize = 0;
        while (parts.next()) |part| : (count += 1) {
            if (part.len == 0 or count == Self.max_version_numbers) return null;
            for (part) |c| if (!std.ascii.isDigit(c)) return null;
        }
        return numbers;
    }

    /// Reports whether `identifier` is usable as `CFBundleIdentifier`.
    ///
    /// - `identifier`: The identifier.
    /// - Returns: `true` when it is non-empty and only letters, digits, `.` and `-`.
    fn isValidIdentifier(identifier: []const u8) bool {
        if (identifier.len == 0) return false;
        for (identifier) |c| if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-') return false;
        return true;
    }

    /// Reports whether `path` stays inside the directory it is joined to.
    ///
    /// - `path`: A relative path (`en.lproj/Main.strings`).
    /// - Returns: `true` when it is non-empty, not absolute or drive-qualified, with no empty, `.` or `..` part and no line break.
    fn isContainedPath(path: []const u8) bool {
        if (std.mem.findAny(u8, path, ":\r\n") != null) return false;
        var parts = std.mem.splitAny(u8, path, "/\\");
        while (parts.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
        }
        return true;
    }

    /// Returns `LSMinimumSystemVersion` for a target: its explicit macOS floor, else `default_macos_min`.
    /// Never the resolved version, which for a native build is the host's own.
    ///
    /// - `allocator`: Allocates the text when it is not the default.
    /// - `query`: The target as asked for (`-Dtarget`, `-Dmacos-min`).
    /// - Returns: `major.minor`, with `.patch` when it is not 0; allocation errors.
    fn macosMin(allocator: std.mem.Allocator, query: std.Target.Query) ![]const u8 {
        const min = query.os_version_min orelse return Self.default_macos_min;
        const version = switch (min) {
            .semver => |semver| semver,
            .none, .windows => return Self.default_macos_min,
        };
        if (version.patch == 0) return allocator.print("{d}.{d}", .{ version.major, version.minor });
        return allocator.print("{d}.{d}.{d}", .{ version.major, version.minor, version.patch });
    }

    /// Returns the bundle's `Info.plist`.
    ///
    /// - `allocator`: Owns the text.
    /// - `options`: The app.
    /// - `version`: Both version keys' value, from `bundleVersion`.
    /// - `macos_min`: `LSMinimumSystemVersion`, from `macosMin`.
    /// - Returns: The plist's XML; allocation errors.
    fn plistText(allocator: std.mem.Allocator, options: AppBundle, version: []const u8, macos_min: []const u8) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        const name = try Self.xmlEscaped(scratch, options.name);
        const icon = if (options.icns == null) "" else try scratch.print("    <key>CFBundleIconFile</key><string>{s}</string>\n", .{name});
        const escaped_version = try Self.xmlEscaped(scratch, version);
        return allocator.print(
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            \\<plist version="1.0">
            \\<dict>
            \\    <key>CFBundleName</key><string>{s}</string>
            \\    <key>CFBundleDisplayName</key><string>{s}</string>
            \\    <key>CFBundleExecutable</key><string>{s}</string>
            \\    <key>CFBundleIdentifier</key><string>{s}</string>
            \\{s}    <key>CFBundlePackageType</key><string>APPL</string>
            \\    <key>CFBundleShortVersionString</key><string>{s}</string>
            \\    <key>CFBundleVersion</key><string>{s}</string>
            \\    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
            \\    <key>LSMinimumSystemVersion</key><string>{s}</string>
            \\    <key>NSHighResolutionCapable</key><true/>
            \\    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
            \\{s}</dict>
            \\</plist>
            \\
        , .{
            name,
            name,
            name,
            try Self.xmlEscaped(scratch, options.identifier),
            icon,
            escaped_version,
            escaped_version,
            macos_min,
            try Self.lineTerminated(scratch, options.plist_extra),
        });
    }

    /// Returns `text` ending in a line break, or empty when `text` is.
    ///
    /// - `allocator`: Owns a copy when one is made.
    /// - `text`: The text.
    /// - Returns: The text; allocation errors.
    fn lineTerminated(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
        if (text.len == 0 or text[text.len - 1] == '\n') return text;
        return allocator.print("{s}\n", .{text});
    }

    /// Returns the Linux desktop entry.
    ///
    /// - `allocator`: Owns the text.
    /// - `options`: The app.
    /// - Returns: The entry; allocation errors.
    fn desktopText(allocator: std.mem.Allocator, options: AppBundle) ![]u8 {
        var text: std.ArrayList(u8) = .empty;
        errdefer text.deinit(allocator);
        try text.print(allocator, "[Desktop Entry]\nType=Application\nName={s}\n", .{options.name});
        if (options.comment.len != 0) {
            // A desktop entry string reads `\` as an escape.
            const comment = try std.mem.replaceOwned(u8, allocator, options.comment, "\\", "\\\\");
            defer allocator.free(comment);
            try text.print(allocator, "Comment={s}\n", .{comment});
        }
        // Quoted when it holds a space or another reserved character; `problem` refuses what quotes would escape.
        const quote = if (std.mem.findAny(u8, options.name, Self.exec_reserved) != null) "\"" else "";
        try text.print(allocator, "Exec={s}{s}{s}{s}\n", .{ quote, options.name, quote, options.opens.execSuffix() });
        if (options.png != null) try text.print(allocator, "Icon={s}\n", .{options.name});
        try text.print(allocator, "StartupWMClass={s}\nTerminal=false\nCategories={s}\n", .{ options.name, options.categories });
        if (options.mime_types.len != 0) try text.print(allocator, "MimeType={s}\n", .{options.mime_types});
        return text.toOwnedSlice(allocator);
    }

    /// Returns `text` with XML's special characters escaped.
    ///
    /// - `allocator`: Owns the result.
    /// - `text`: The text.
    /// - Returns: The escaped text; allocation errors.
    fn xmlEscaped(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
        var escaped: std.ArrayList(u8) = .empty;
        errdefer escaped.deinit(allocator);
        for (text) |c| try escaped.appendSlice(allocator, switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            else => &.{c},
        });
        return escaped.toOwnedSlice(allocator);
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

/// Returns an app for the text tests, which never read its executable.
///
/// - Returns: The app.
fn testBundle() AppBundle {
    // SAFETY: the text builders and checks under test never read `exe`.
    return .{ .name = "Hello", .identifier = "com.example.hello", .version = "1.2.0", .exe = undefined };
}

test "bundleVersion strips a suffix and refuses anything but one to three numbers" {
    try std.testing.expectEqualStrings("1.2.0", App.bundleVersion("1.2.0").?);
    try std.testing.expectEqualStrings("1.2.0", App.bundleVersion("1.2.0-rc1").?);
    try std.testing.expectEqualStrings("1.2.3", App.bundleVersion("1.2.3+build.7").?);
    try std.testing.expectEqualStrings("1.2.3", App.bundleVersion("1.2.3-rc.1+42").?);
    try std.testing.expectEqualStrings("7", App.bundleVersion("7").?);
    try std.testing.expectEqualStrings("1.2", App.bundleVersion("1.2").?);
    for ([_][]const u8{ "", "1.2.3.4", "abc", "1..2", "1.2.", "-rc1", "v1.2.3" }) |version| {
        try std.testing.expectEqual(null, App.bundleVersion(version));
    }
}

test "isValidIdentifier accepts reverse DNS only" {
    try std.testing.expect(App.isValidIdentifier("com.example.hello"));
    try std.testing.expect(App.isValidIdentifier("com.example.hello-app2"));
    for ([_][]const u8{ "", "com.example.hello app", "com/example", "com.example.héllo", "com_example" }) |identifier| {
        try std.testing.expect(!App.isValidIdentifier(identifier));
    }
}

test "problem names the first bad option" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(null, try App.problem(allocator, testBundle()));

    var bundle = testBundle();
    bundle.identifier = "com example";
    const identifier = (try App.problem(allocator, bundle)).?;
    defer allocator.free(identifier);
    try std.testing.expect(std.mem.find(u8, identifier, "identifier \"com example\"") != null);

    bundle = testBundle();
    bundle.version = "1.2.3.4";
    const version = (try App.problem(allocator, bundle)).?;
    defer allocator.free(version);
    try std.testing.expect(std.mem.find(u8, version, "version \"1.2.3.4\"") != null);

    bundle = testBundle();
    bundle.name = "bin/Hello";
    const name = (try App.problem(allocator, bundle)).?;
    defer allocator.free(name);
    try std.testing.expect(std.mem.find(u8, name, "app name") != null);

    for ([_][]const u8{ "..", ".", "Bill$", "50%", "Say \"hi\"" }) |bad| {
        bundle = testBundle();
        bundle.name = bad;
        const message = (try App.problem(allocator, bundle)).?;
        defer allocator.free(message);
        try std.testing.expect(std.mem.find(u8, message, "app name") != null);
    }

    bundle = testBundle();
    bundle.linux_subdir = "../outside";
    const subdir = (try App.problem(allocator, bundle)).?;
    defer allocator.free(subdir);
    try std.testing.expect(std.mem.find(u8, subdir, "linux_subdir") != null);

    bundle = testBundle();
    bundle.resources = &.{.{ .path = std.Build.LazyPath.zig_lib, .name = "../../escape" }};
    const resource = (try App.problem(allocator, bundle)).?;
    defer allocator.free(resource);
    try std.testing.expect(std.mem.find(u8, resource, "bundle file name \"../../escape\"") != null);

    bundle = testBundle();
    bundle.resources = &.{.{ .path = std.Build.LazyPath.zig_lib, .name = "en.lproj/Main.strings" }};
    bundle.linux_subdir = "Hello";
    try std.testing.expectEqual(null, try App.problem(allocator, bundle));

    bundle = testBundle();
    bundle.comment = "two\nlines";
    const comment = (try App.problem(allocator, bundle)).?;
    defer allocator.free(comment);
    try std.testing.expect(std.mem.find(u8, comment, "line break") != null);

    bundle = testBundle();
    bundle.mime_types = "text/plain;\ninode/directory;";
    bundle.opens = .file;
    const mime_break = (try App.problem(allocator, bundle)).?;
    defer allocator.free(mime_break);
    try std.testing.expect(std.mem.find(u8, mime_break, "line break") != null);

    bundle.mime_types = "text/plain;";
    try std.testing.expectEqual(null, try App.problem(allocator, bundle));
    bundle.opens = .nothing;
    const mime_unopened = (try App.problem(allocator, bundle)).?;
    defer allocator.free(mime_unopened);
    try std.testing.expect(std.mem.find(u8, mime_unopened, "mime_types needs opens") != null);
}

test "macosMin takes the explicit floor, never the resolved version" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqualStrings(App.default_macos_min, try App.macosMin(allocator, .{}));
    try std.testing.expectEqualStrings(App.default_macos_min, try App.macosMin(allocator, .{ .os_tag = .macos }));
    const floor = try App.macosMin(allocator, .{ .os_tag = .macos, .os_version_min = .{ .semver = .{ .major = 14, .minor = 0, .patch = 0 } } });
    defer allocator.free(floor);
    try std.testing.expectEqualStrings("14.0", floor);
    const patch = try App.macosMin(allocator, .{ .os_tag = .macos, .os_version_min = .{ .semver = .{ .major = 26, .minor = 1, .patch = 2 } } });
    defer allocator.free(patch);
    try std.testing.expectEqualStrings("26.1.2", patch);
}

test "plistText fills the keys and escapes XML" {
    const allocator = std.testing.allocator;
    var bundle = testBundle();
    bundle.name = "Hi & <Bye>";
    const plain = try App.plistText(allocator, bundle, "1.2.0", "14.0");
    defer allocator.free(plain);
    try std.testing.expect(std.mem.find(u8, plain, "<key>CFBundleExecutable</key><string>Hi &amp; &lt;Bye&gt;</string>") != null);
    try std.testing.expect(std.mem.find(u8, plain, "<key>CFBundleIdentifier</key><string>com.example.hello</string>") != null);
    try std.testing.expect(std.mem.find(u8, plain, "<key>CFBundleShortVersionString</key><string>1.2.0</string>") != null);
    try std.testing.expect(std.mem.find(u8, plain, "<key>CFBundleVersion</key><string>1.2.0</string>") != null);
    try std.testing.expect(std.mem.find(u8, plain, "<key>LSMinimumSystemVersion</key><string>14.0</string>") != null);
    // No icon, no icon key.
    try std.testing.expectEqual(null, std.mem.find(u8, plain, "CFBundleIconFile"));
    try std.testing.expect(std.mem.endsWith(u8, plain, "<true/>\n</dict>\n</plist>\n"));
}

test "plistText names the icon and appends plist_extra inside the dictionary" {
    const allocator = std.testing.allocator;
    var bundle = testBundle();
    // Any path: the plist reads only whether there is one.
    bundle.icns = std.Build.LazyPath.zig_lib;
    bundle.plist_extra = "    <key>LSUIElement</key><true/>";
    const text = try App.plistText(allocator, bundle, "1.2.0", "13.0");
    defer allocator.free(text);
    try std.testing.expect(std.mem.find(u8, text, "    <key>CFBundleIconFile</key><string>Hello</string>\n    <key>CFBundlePackageType</key>") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "    <key>LSUIElement</key><true/>\n</dict>\n</plist>\n"));
}

test "desktopText writes the entry, leaving out an empty comment, a missing icon and no MIME types" {
    const allocator = std.testing.allocator;
    const bare = try App.desktopText(allocator, testBundle());
    defer allocator.free(bare);
    try std.testing.expectEqualStrings(
        \\[Desktop Entry]
        \\Type=Application
        \\Name=Hello
        \\Exec=Hello
        \\StartupWMClass=Hello
        \\Terminal=false
        \\Categories=Development;
        \\
    , bare);

    var bundle = testBundle();
    bundle.comment = "Says hello";
    bundle.png = std.Build.LazyPath.zig_lib;
    bundle.categories = "Utility;";
    bundle.opens = .file;
    bundle.mime_types = "text/plain;inode/directory;";
    const full = try App.desktopText(allocator, bundle);
    defer allocator.free(full);
    try std.testing.expectEqualStrings(
        \\[Desktop Entry]
        \\Type=Application
        \\Name=Hello
        \\Comment=Says hello
        \\Exec=Hello %f
        \\Icon=Hello
        \\StartupWMClass=Hello
        \\Terminal=false
        \\Categories=Utility;
        \\MimeType=text/plain;inode/directory;
        \\
    , full);
}

test "desktopText gives Exec the field code of what the app opens" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { AppOpens, []const u8 }{
        .{ .nothing, "\nExec=Hello\n" },
        .{ .file, "\nExec=Hello %f\n" },
        .{ .files, "\nExec=Hello %F\n" },
        .{ .url, "\nExec=Hello %u\n" },
        .{ .urls, "\nExec=Hello %U\n" },
    };
    for (cases) |case| {
        var bundle = testBundle();
        bundle.opens = case[0];
        const text = try App.desktopText(allocator, bundle);
        defer allocator.free(text);
        try std.testing.expect(std.mem.find(u8, text, case[1]) != null);
    }

    var quoted = testBundle();
    quoted.name = "Zig App";
    quoted.opens = .file;
    const text = try App.desktopText(allocator, quoted);
    defer allocator.free(text);
    try std.testing.expect(std.mem.find(u8, text, "\nExec=\"Zig App\" %f\n") != null);
}

test "linuxPath puts the layout under linux_subdir" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqualStrings("bin", try App.linuxPath(allocator, "", "bin"));
    const nested = try App.linuxPath(allocator, "Hello", "share/applications/Hello.desktop");
    defer allocator.free(nested);
    try std.testing.expectEqualStrings("Hello/share/applications/Hello.desktop", nested);
}

test "isContainedPath refuses paths that leave their directory" {
    try std.testing.expect(App.isContainedPath("data.txt"));
    try std.testing.expect(App.isContainedPath("en.lproj/Main.strings"));
    for ([_][]const u8{ "", "/etc/passwd", "..", "a/../b", "./a", "a//b", "a/", "C:\\x", "a\\..\\b", "a\nb" }) |path| {
        try std.testing.expect(!App.isContainedPath(path));
    }
}

test "desktopText quotes an Exec name with a space and escapes a comment's backslash" {
    const allocator = std.testing.allocator;
    var bundle = testBundle();
    bundle.name = "Zig App";
    bundle.comment = "C:\\Temp";
    const text = try App.desktopText(allocator, bundle);
    defer allocator.free(text);
    try std.testing.expect(std.mem.find(u8, text, "\nExec=\"Zig App\"\n") != null);
    try std.testing.expect(std.mem.find(u8, text, "\nComment=C:\\\\Temp\n") != null);
    try std.testing.expect(std.mem.find(u8, text, "\nName=Zig App\n") != null);
}
