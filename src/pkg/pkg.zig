const std = @import("std");
const mod = @import("module.zig");

/// The Apple signing settings in a project's `signing.zon`.
///
/// ```zig
/// .{
///     .apple_id = "dev@example.com",
///     .apple_password = "abcd-efgh-ijkl-mnop",
///     .apple_name = "Example Corp",
///     .apple_team = "ABCDE12345",
/// }
/// ```
///
/// Signing needs `apple_name` and `apple_team`; notarizing needs all four.
const Signing = struct {
    const Self = @This();
    apple_id: ?[]const u8 = null,
    apple_password: ?[]const u8 = null,
    apple_name: ?[]const u8 = null,
    apple_team: ?[]const u8 = null,

    /// Parses `signing.zon`; an unknown field is an error, and an empty string counts as unset.
    ///
    /// Parameters:
    /// - `allocator`: allocator for the strings; use an arena, as nothing is freed individually.
    /// - `source`: the file.
    /// - `diag`: receives the reason when the file does not parse.
    ///
    /// Return: the settings; `error.ParseZon` with `diag` filled, or `error.OutOfMemory`.
    fn parse(allocator: std.mem.Allocator, source: [:0]const u8, diag: *std.zon.parse.Diagnostics) !Self {
        var self = try std.zon.parse.fromSliceAlloc(Self, allocator, source, diag, .{});
        inline for (.{ "apple_id", "apple_password", "apple_name", "apple_team" }) |field| {
            if (@field(self, field)) |value| {
                if (value.len == 0) @field(self, field) = null;
            }
        }
        return self;
    }

    /// Reports whether the identities for signing are set.
    ///
    /// Parameters:
    /// - `self`: the settings.
    ///
    /// Return: `true` when `apple_name` and `apple_team` are set.
    fn canSign(self: *const Self) bool {
        return self.apple_name != null and self.apple_team != null;
    }
};

/// What to package.
pub const PkgOptions = struct {
    const Self = @This();
    /// The programs to install in `bin`, all built for one target.
    executables: []const *std.Build.Step.Compile,
    /// A directory of script templates replacing the embedded ones of the
    /// same name: `preinstall`, `postinstall`, `uninstall.sh` (macOS),
    /// `preinst`, `postrm`, `profile.sh` (Linux). They are filled in the
    /// same way: `{pkg_name}`, `{pkg_id}`, `{pkg_org}`.
    scripts: ?std.Build.LazyPath = null,
};

/// Builds an installable package of a project's executables: `zig build pkg`.
///
/// The format follows the executables' target OS: a `.pkg` for macOS, a
/// `.deb` for Linux, an `.msi` for Windows, all written to `zig-out/pkg/`.
/// Each installs the programs in a `bin` directory under
/// `/usr/local/<org>/<name>` (`%LOCALAPPDATA%\<org>\<name>` on Windows) and
/// puts it on `PATH`.
///
/// The project's `build.zig.zon` supplies `.name`, `.version` and `.org`, a
/// reverse-DNS organisation such as `"com.example"`. The package id is
/// `<org>.<name>`; paths use only the last label of `.org`. Without `.org`,
/// `zig build pkg` fails; nothing else in the build is affected.
///
/// The install scripts are templates embedded in zigbuildx, filled in with the
/// package's name, id and organisation; `PkgOptions.scripts` can replace them.
pub const Pkg = struct {
    const Self = @This();

    /// The embedded templates, by the file name they are installed or staged as.
    const templates = [_]struct { name: []const u8, text: []const u8 }{
        .{ .name = "preinstall", .text = @embedFile("macos/preinstall") },
        .{ .name = "postinstall", .text = @embedFile("macos/postinstall") },
        .{ .name = "uninstall.sh", .text = @embedFile("macos/uninstall.sh") },
        .{ .name = "preinst", .text = @embedFile("linux/preinst") },
        .{ .name = "postrm", .text = @embedFile("linux/postrm") },
        .{ .name = "profile.sh", .text = @embedFile("linux/profile.sh") },
    };

    /// Builds and stages the package.
    step: std.Build.Step,
    /// Notarizes and staples the macOS package.
    notarize_step: std.Build.Step,
    /// The package's `.name`.
    name: []const u8,
    /// The package's `.org`, in reverse DNS.
    org: []const u8,
    /// The package's `.version`.
    version: []const u8,
    /// One line describing the package, from `.description` or the name.
    description: []const u8,
    executables: []const *std.Build.Step.Compile,
    scripts: ?std.Build.LazyPath,
    /// The target the executables are built for; valid unless `problem` is set.
    // SAFETY: populated by add() before first read, unless problem is set.
    target: std.Target = undefined,
    /// Why the package cannot be built, reported when `zig build pkg` runs.
    problem: ?[]const u8 = null,
    /// The staged tree, for `deb` on Linux.
    staged: std.Build.GeneratedFile,

    /// Declares `zig build pkg`, and `zig build pkg-notarize` for a macOS target.
    ///
    /// A missing `.org` or another problem does not fail the build graph: it
    /// fails `zig build pkg` with a message, so every other step still works.
    ///
    /// Parameters:
    /// - `b`: the project's build graph.
    /// - `zon`: the project's `@import("build.zig.zon")`.
    /// - `options`: what to package.
    ///
    /// Return: the package, whose `step` builds it.
    pub fn add(b: *std.Build, comptime zon: anytype, options: PkgOptions) *Self {
        const self = b.allocator.create(Self) catch @panic("OOM");
        self.* = .{
            .step = .init(.{ .id = .custom, .name = "pkg", .owner = b, .makeFn = Self.make }),
            .notarize_step = .init(.{ .id = .custom, .name = "pkg notarize", .owner = b, .makeFn = Self.makeNotarize }),
            .name = @tagName(zon.name),
            .org = if (@hasField(@TypeOf(zon), "org")) zon.org else "",
            .version = zon.version,
            .description = if (@hasField(@TypeOf(zon), "description")) zon.description else @tagName(zon.name),
            .executables = b.allocator.dupe(*std.Build.Step.Compile, options.executables) catch @panic("OOM"),
            .scripts = options.scripts,
            // SAFETY: set to &self.step on the next line, once self has an address.
            .staged = .{ .step = undefined },
        };
        self.staged.step = &self.step;
        self.problem = self.check();
        for (self.executables) |exe| self.step.dependOn(&exe.step);
        if (options.scripts) |scripts| scripts.addStepDependencies(&self.step);

        const top = b.step("pkg", "Build an installable package for -Dtarget's OS into zig-out/pkg");
        if (self.problem == null and self.target.os.tag == .linux) {
            // dpkg-deb is not on every host, so a program of zigbuildx's own writes the .deb.
            const pack = b.addRunArtifact(mod.HostTool.add(b, "deb", "deb.zig", @embedFile("linux/deb.zig")));
            pack.setName("pkg deb");
            // The staged tree's path never changes, and a Run step hashes a
            // directory argument's path, not its contents: without this, an
            // edited program would leave the cached .deb in place. Packing is
            // cheap, and the staging step reruns on every `zig build pkg` anyway.
            pack.has_side_effects = true;
            pack.addDirectoryArg(.{ .generated = .{ .file = &self.staged } });
            const file_name = self.fileName(b.allocator) catch @panic("OOM");
            const deb = pack.addOutputFileArg(file_name);
            const install = b.addInstallFileWithDir(deb, .prefix, b.fmt("pkg/{s}", .{file_name}));
            top.dependOn(&install.step);
        } else {
            top.dependOn(&self.step);
        }
        if (self.problem == null and self.target.os.tag == .macos) {
            self.notarize_step.dependOn(&self.step);
            const notarize = b.step("pkg-notarize", "Notarize and staple the macOS package (uploads it to Apple and waits)");
            notarize.dependOn(&self.notarize_step);
        }
        return self;
    }

    /// Copies the executables into `dir`.
    ///
    /// Parameters:
    /// - `self`: the package.
    /// - `dir`: the destination, created if absent.
    ///
    /// Return: the copies' paths; IO errors.
    pub fn copyExecutables(self: *Self, dir: []const u8) ![]const []const u8 {
        const b = self.step.owner;
        const io = b.graph.io;
        try std.Io.Dir.cwd().createDirPath(io, dir);
        var copies: std.ArrayList([]const u8) = .empty;
        for (self.executables) |exe| {
            const source = try exe.getEmittedBin().getPath4(b, &self.step);
            const from = b.pathResolve(&.{ source.root_dir.path orelse ".", source.sub_path });
            const to = b.pathJoin(&.{ dir, exe.out_filename });
            try std.Io.Dir.cwd().copyFile(from, std.Io.Dir.cwd(), to, io, .{});
            try copies.append(b.allocator, to);
        }
        return copies.items;
    }

    /// Fills template `name` and writes it to `path`.
    ///
    /// Parameters:
    /// - `self`: the package.
    /// - `path`: where to write it; its directory is created if absent.
    /// - `name`: the template's name.
    /// - `executable`: whether the file is a script to mark executable.
    ///
    /// Return: nothing; IO errors.
    pub fn writeScript(self: *Self, path: []const u8, name: []const u8, executable: bool) !void {
        const b = self.step.owner;
        const io = b.graph.io;
        const text = try Self.fill(b.allocator, try self.template(name), self.name, self.id(), self.orgLabel());
        try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text, .flags = .{ .permissions = if (executable) .executable_file else .default_file } });
    }

    /// Reads `signing.zon` from the project root, refusing one that git would commit.
    ///
    /// Parameters:
    /// - `self`: the package.
    ///
    /// Return: the settings, or `null` when there is no file;
    /// `error.MakeFailed` when git does not ignore it, it does not parse, or
    /// it lacks `apple_name` or `apple_team`, or IO errors.
    pub fn signing(self: *Self) !?Signing {
        const b = self.step.owner;
        const io = b.graph.io;
        const root = b.build_root.path orelse ".";
        const source = b.build_root.handle.readFileAllocOptions(io, "signing.zon", b.allocator, .limited(1 << 16), .of(u8), 0) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        const ignored = mod.Git.isIgnored(b.allocator, io, root, "signing.zon") catch return self.step.fail("cannot check that git ignores {s}/signing.zon", .{root});
        if (!ignored) return self.step.fail("{s}/signing.zon holds Apple credentials, but git does not ignore it; add signing.zon to .gitignore", .{root});
        var diag: std.zon.parse.Diagnostics = .{};
        const settings = Signing.parse(b.allocator, source, &diag) catch |err| switch (err) {
            error.ParseZon => return self.step.fail("{s}/signing.zon: {f}", .{ root, diag }),
            else => return err,
        };
        if (!settings.canSign()) return self.step.fail("{s}/signing.zon needs .apple_name and .apple_team", .{root});
        return settings;
    }

    /// Runs a packaging tool and fails the step when it fails.
    ///
    /// Parameters:
    /// - `self`: the package.
    /// - `argv`: the command.
    /// - `cwd`: where it runs, or `null` for the build's own directory.
    /// - `secret`: text to hide in any message, e.g. a password in `argv`.
    ///
    /// Return: nothing; `error.MakeFailed` with the tool's output, or spawn errors.
    pub fn runTool(self: *Self, argv: []const []const u8, cwd: ?[]const u8, secret: ?[]const u8) !void {
        const b = self.step.owner;
        const result = std.process.run(b.allocator, b.graph.io, .{ .argv = argv, .cwd = if (cwd) |dir| .{ .path = dir } else .inherit }) catch |err| {
            return self.step.fail("cannot run {s} [{any}]", .{ argv[0], err });
        };
        try self.checkTool(argv, result, secret);
    }

    /// Fails the step when a tool exited non-zero, with its output.
    ///
    /// Parameters:
    /// - `self`: the package.
    /// - `argv`: the command, for the message.
    /// - `result`: what it returned.
    /// - `secret`: text to hide in the message.
    ///
    /// Return: nothing; `error.MakeFailed` on failure.
    pub fn checkTool(self: *Self, argv: []const []const u8, result: std.process.RunResult, secret: ?[]const u8) !void {
        switch (result.term) {
            .exited => |code| if (code == 0) return,
            else => {},
        }
        const b = self.step.owner;
        var output = try std.mem.concat(b.allocator, u8, &.{ result.stdout, result.stderr });
        if (secret) |hidden| {
            // replaceOwned asserts a non-empty needle; an empty secret hides nothing anyway.
            if (hidden.len > 0) output = try std.mem.replaceOwned(u8, b.allocator, output, hidden, "<redacted>");
        }
        return self.step.fail("{s} failed [{any}]:\n{s}", .{ argv[0], result.term, std.mem.trim(u8, output, " \t\r\n") });
    }

    /// Returns where the package is written, creating `zig-out/pkg`.
    ///
    /// Parameters:
    /// - `self`: the package.
    ///
    /// Return: the path; IO errors.
    pub fn outputPath(self: *Self) ![]const u8 {
        const b = self.step.owner;
        const dir = b.getInstallPath(.prefix, "pkg");
        try std.Io.Dir.cwd().createDirPath(b.graph.io, dir);
        return b.pathJoin(&.{ dir, try self.fileName(b.allocator) });
    }

    /// Returns the package id: `<org>.<name>`.
    ///
    /// Parameters:
    /// - `self`: the package.
    ///
    /// Return: the id.
    pub fn id(self: *const Self) []const u8 {
        return self.step.owner.fmt("{s}.{s}", .{ self.org, self.name });
    }

    /// Returns the organisation's label for paths: the last label of `.org`.
    ///
    /// Parameters:
    /// - `self`: the package.
    ///
    /// Return: e.g. `example` for `com.example`.
    pub fn orgLabel(self: *const Self) []const u8 {
        const dot = std.mem.lastIndexOfScalar(u8, self.org, '.') orelse return self.org;
        return self.org[dot + 1 ..];
    }

    /// Checks what `zig build pkg` needs, and records the executables' target.
    ///
    /// Parameters:
    /// - `self`: the package.
    ///
    /// Return: why the package cannot be built, or `null`.
    fn check(self: *Self) ?[]const u8 {
        const b = self.step.owner;
        if (self.org.len == 0) return "build.zig.zon has no .org; add the organisation in reverse DNS, e.g. .org = \"com.example\"";
        if (!Self.isSafe(self.org) or !Self.isSafe(self.orgLabel())) return b.fmt(".org = \"{s}\" may hold only letters, digits, '.', '-' and '_'", .{self.org});
        if (!Self.isSafe(self.name)) return b.fmt(".name = .{s} may hold only letters, digits, '.', '-' and '_' to be packaged", .{self.name});
        if (self.executables.len == 0) return "Pkg.add was given no executables";
        for (self.executables, 0..) |exe, i| {
            for (self.executables[i + 1 ..]) |other| {
                if (std.mem.eql(u8, exe.out_filename, other.out_filename)) return b.fmt("two executables install as bin/{s}; give them different names", .{exe.out_filename});
            }
        }
        self.target = self.executables[0].rootModuleTarget();
        for (self.executables[1..]) |exe| {
            const other = exe.rootModuleTarget();
            if (other.os.tag != self.target.os.tag or other.cpu.arch != self.target.cpu.arch) return b.fmt("{s} is built for {t}-{t}, but {s} for {t}-{t}; package one target at a time", .{ self.executables[0].name, self.target.cpu.arch, self.target.os.tag, exe.name, other.cpu.arch, other.os.tag });
        }
        return switch (self.target.os.tag) {
            .macos => null,
            .linux => if (mod.Deb.arch(self.target.cpu.arch) == null) b.fmt("no Debian architecture for {t}", .{self.target.cpu.arch}) else if (!mod.Deb.isName(self.name)) b.fmt("{s} is not a Debian package name: lowercase letters, digits, '+', '-' and '.', starting with a letter or digit", .{self.name}) else null,
            .windows => if (mod.Msi.arch(self.target.cpu.arch) == null) b.fmt("wixl cannot build an installer for {t}", .{self.target.cpu.arch}) else null,
            else => b.fmt("no package format for {t}; build for macOS, Linux or Windows", .{self.target.os.tag}),
        };
    }

    /// Builds the package: `Pkgbuild` for macOS, `Msi` for Windows, and for Linux the staged tree the `deb` tool packs.
    ///
    /// Parameters:
    /// - `step`: the `step` field of a `Pkg`.
    /// - `options`: unused.
    ///
    /// Return: nothing; `error.MakeFailed` with the reason, or IO errors.
    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
        _ = options;
        const self: *Self = @fieldParentPtr("step", step);
        if (self.problem) |problem| return step.fail("{s}", .{problem});
        const b = step.owner;
        const io = b.graph.io;
        const stage = try b.cache_root.join(b.allocator, &.{ "zigbuildx-pkg", b.fmt("{s}-{t}-{t}", .{ self.name, self.target.os.tag, self.target.cpu.arch }) });
        try std.Io.Dir.cwd().deleteTree(io, stage);
        try std.Io.Dir.cwd().createDirPath(io, stage);
        switch (self.target.os.tag) {
            .macos => try mod.Pkgbuild.build(self, stage),
            .linux => try self.stageDeb(stage),
            .windows => try mod.Msi.build(self, stage),
            else => unreachable,
        }
    }

    /// Stages the `.deb`'s `control` and `data` trees, for `deb`.
    ///
    /// Parameters:
    /// - `self`: the package; its `staged` path is set.
    /// - `stage`: an empty staging directory.
    ///
    /// Return: nothing; IO errors.
    fn stageDeb(self: *Self, stage: []const u8) !void {
        const b = self.step.owner;
        const io = b.graph.io;
        const prefix = b.fmt("usr/local/{s}/{s}", .{ self.orgLabel(), self.name });
        _ = try self.copyExecutables(b.pathJoin(&.{ stage, "data", prefix, "bin" }));
        try self.writeScript(b.pathJoin(&.{ stage, "data", "etc", "profile.d", b.fmt("{s}.sh", .{self.name}) }), "profile.sh", false);
        try self.writeScript(b.pathJoin(&.{ stage, "control", "preinst" }), "preinst", true);
        try self.writeScript(b.pathJoin(&.{ stage, "control", "postrm" }), "postrm", true);
        const control = b.fmt(
            \\Package: {s}
            \\Version: {s}
            \\Architecture: {s}
            \\Maintainer: {s}
            \\Section: utils
            \\Priority: optional
            \\Description: {s}
            \\
        , .{ self.name, self.version, mod.Deb.arch(self.target.cpu.arch).?, self.orgLabel(), self.summary() });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = b.pathJoin(&.{ stage, "control", "control" }), .data = control });
        self.staged.path = stage;
    }

    /// Notarizes the macOS package and staples the ticket to it; see `Pkgbuild.notarize`.
    ///
    /// Parameters:
    /// - `step`: the `notarize_step` field of a `Pkg`.
    /// - `options`: unused.
    ///
    /// Return: nothing; `error.MakeFailed` when credentials are missing or Apple
    /// does not accept the package.
    fn makeNotarize(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
        _ = options;
        const self: *Self = @fieldParentPtr("notarize_step", step);
        try mod.Pkgbuild.notarize(self);
    }

    /// Returns template `name`: the project's, when `Options.scripts` has one, else the embedded one.
    ///
    /// Parameters:
    /// - `self`: the package.
    /// - `name`: the template's name.
    ///
    /// Return: its text; IO errors.
    fn template(self: *Self, name: []const u8) ![]const u8 {
        const b = self.step.owner;
        if (self.scripts) |scripts| {
            const dir = try scripts.getPath4(b, &self.step);
            const path = b.pathResolve(&.{ dir.root_dir.path orelse ".", dir.sub_path, name });
            if (std.Io.Dir.cwd().readFileAlloc(b.graph.io, path, b.allocator, .limited(1 << 20))) |text| {
                return text;
            } else |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            }
        }
        for (Self.templates) |embedded| {
            if (std.mem.eql(u8, embedded.name, name)) return embedded.text;
        }
        unreachable;
    }

    /// Fills a template's `{pkg_name}`, `{pkg_id}` and `{pkg_org}`.
    ///
    /// Parameters:
    /// - `allocator`: allocator for the result.
    /// - `text`: the template.
    /// - `name`: the package name.
    /// - `package_id`: the package id.
    /// - `org`: the organisation's path label.
    ///
    /// Return: the filled text, owned by the caller.
    fn fill(allocator: std.mem.Allocator, text: []const u8, name: []const u8, package_id: []const u8, org: []const u8) ![]u8 {
        const with_name = try std.mem.replaceOwned(u8, allocator, text, "{pkg_name}", name);
        defer allocator.free(with_name);
        const with_id = try std.mem.replaceOwned(u8, allocator, with_name, "{pkg_id}", package_id);
        defer allocator.free(with_id);
        return std.mem.replaceOwned(u8, allocator, with_id, "{pkg_org}", org);
    }

    /// Returns the package's file name, in each platform's convention.
    ///
    /// Parameters:
    /// - `self`: the package.
    /// - `allocator`: allocator for the name.
    ///
    /// Return: `<name>-<version>.pkg`, `<name>_<version>_<arch>.deb` or `<name>-<version>-<arch>.msi`.
    fn fileName(self: *const Self, allocator: std.mem.Allocator) ![]const u8 {
        return switch (self.target.os.tag) {
            .macos => std.fmt.allocPrint(allocator, "{s}-{s}.pkg", .{ self.name, self.version }),
            .linux => std.fmt.allocPrint(allocator, "{s}_{s}_{s}.deb", .{ self.name, self.version, mod.Deb.arch(self.target.cpu.arch).? }),
            .windows => std.fmt.allocPrint(allocator, "{s}-{s}-{s}.msi", .{ self.name, self.version, mod.Msi.arch(self.target.cpu.arch).? }),
            else => unreachable,
        };
    }

    /// Returns the description's first line, for the one-line summaries packages carry.
    ///
    /// Parameters:
    /// - `self`: the package.
    ///
    /// Return: the summary.
    fn summary(self: *const Self) []const u8 {
        const line = std.mem.sliceTo(self.description, '\n');
        return if (line.len == 0) self.name else line;
    }

    /// Reports whether `text` is safe in a path and a script: letters, digits, `.`, `-`, `_`.
    ///
    /// Parameters:
    /// - `text`: a name.
    ///
    /// Return: `true` when non-empty and safe.
    fn isSafe(text: []const u8) bool {
        if (text.len == 0) return false;
        for (text) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-' and c != '_') return false;
        }
        return true;
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test "every packager compiles for every host" {
    // The build steps run in a consumer's build runner on any host, but nothing
    // in the tests calls them, and Zig compiles only what is referenced.
    // Taking their addresses compiles them, so `make cross` checks the macOS,
    // Linux and Windows paths for Windows and Linux hosts too.
    _ = &Pkg.make;
    _ = &Pkg.makeNotarize;
}

test "Signing reads signing.zon, treats empty strings as unset, and rejects unknown fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var diag: std.zon.parse.Diagnostics = .{};
    const settings = try Signing.parse(allocator,
        \\.{
        \\    .apple_id = "dev@example.com",
        \\    .apple_password = "a$b#c\"d",
        \\    .apple_name = "Example Corp",
        \\    .apple_team = "ABCDE12345",
        \\}
    , &diag);
    try std.testing.expectEqualStrings("dev@example.com", settings.apple_id.?);
    try std.testing.expectEqualStrings("a$b#c\"d", settings.apple_password.?);
    try std.testing.expect(settings.canSign());

    // Each parse needs a fresh Diagnostics.
    var partial_diag: std.zon.parse.Diagnostics = .{};
    const partial = try Signing.parse(allocator, ".{ .apple_name = \"x\", .apple_team = \"\" }", &partial_diag);
    try std.testing.expectEqual(null, partial.apple_team);
    try std.testing.expect(!partial.canSign());

    var typo: std.zon.parse.Diagnostics = .{};
    try std.testing.expectError(error.ParseZon, Signing.parse(allocator, ".{ .apple_pass = \"x\" }", &typo));
}

test "fill replaces every placeholder, and the embedded templates use only known ones" {
    const allocator = std.testing.allocator;
    const out = try Pkg.fill(allocator, "/usr/local/{pkg_org}/{pkg_name} {pkg_id} {pkg_name}", "tool", "com.acme.tool", "acme");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("/usr/local/acme/tool com.acme.tool tool", out);
    for (Pkg.templates) |embedded| {
        const filled = try Pkg.fill(allocator, embedded.text, "tool", "com.acme.tool", "acme");
        defer allocator.free(filled);
        try std.testing.expect(std.mem.indexOf(u8, filled, "{pkg_") == null);
    }
}

test "isSafe allows letters, digits, '.', '-' and '_'" {
    try std.testing.expect(Pkg.isSafe("com.acme-2_x"));
    try std.testing.expect(!Pkg.isSafe("a/b"));
    try std.testing.expect(!Pkg.isSafe(""));
}
