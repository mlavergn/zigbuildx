const std = @import("std");
const log = std.log.scoped(.zigbuildx_pkg);
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
pub const Signing = struct {
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
        var self = try std.zon.parse.fromSlice(Self, .{ .gpa = allocator, .arena = allocator, .source = source, .diagnostics = diag });
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

/// The labels of a bundle id that a package's paths use.
pub const PkgLabels = struct {
    /// The organisation: the bundle id's second label, e.g. `example`.
    org: []const u8,
    /// The package: the bundle id's last label, e.g. `tool`.
    name: []const u8,
};

/// A shared library the programs load, and the file name it is installed as.
pub const PkgLibrary = struct {
    /// The file name in `lib`, e.g. `libfoo.dylib`; what the programs' install names expect.
    name: []const u8,
    /// The built library.
    path: std.Build.LazyPath,
};

/// What to package.
pub const PkgOptions = struct {
    const Self = @This();
    /// The programs to install in `bin`, all built for one target.
    executables: []const *std.Build.Step.Compile,
    /// The shared libraries the programs load, installed in `lib` beside
    /// `bin` (in `bin` on Windows, where a DLL is looked for beside its
    /// program) and signed as the programs are.
    libraries: []const PkgLibrary = &.{},
    /// A directory of script templates replacing the embedded ones of the
    /// same name: `preinstall`, `postinstall`, `uninstall.sh` (macOS),
    /// `preinst`, `postrm`, `profile.sh` (Linux). They are filled in the
    /// same way: `{pkg_name}`, `{pkg_id}`, `{pkg_org}`.
    scripts: ?std.Build.LazyPath = null,
};

/// One run of the host tool's `pkg` command: stages a package and builds it.
///
/// `Pkg` declares the steps while the graph is configured; this does the work
/// when the build runs, from what the command line hands it. All allocation
/// goes through `allocator`, an arena; nothing is freed individually.
pub const PkgRun = struct {
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

    /// A shared library to stage: the name it is installed as, and where it was built.
    const Library = struct {
        name: []const u8,
        path: []const u8,
    };

    allocator: std.mem.Allocator,
    io: std.Io,
    /// The package's name: the last label of `.bundle`.
    name: []const u8 = "",
    /// The package's `.bundle`: its bundle id, in reverse DNS.
    bundle: []const u8 = "",
    /// The package's `.version`.
    version: []const u8 = "",
    /// One line describing the package.
    summary: []const u8 = "",
    /// The Debian architecture, for a `.deb`.
    arch: []const u8 = "",
    /// The project root, where `signing.zon` is looked for.
    root: []const u8 = ".",
    /// The directory of template overrides, if any.
    scripts: ?[]const u8 = null,
    /// The built programs, by path.
    executables: []const []const u8 = &.{},
    /// The shared libraries, from each `--library=<name>=<path>`.
    libraries: std.ArrayList(Library) = .empty,

    /// Creates a run.
    ///
    /// Parameters:
    /// - `allocator`: an arena for everything the run allocates.
    /// - `io`: IO for the filesystem and the packaging tools.
    ///
    /// Return: the run, with no package described yet.
    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Self {
        return .{ .allocator = allocator, .io = io };
    }

    /// Reads `--key=value` options and, after `--`, the programs.
    ///
    /// `--library=<name>=<path>` may repeat, once per shared library.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `args`: the options.
    ///
    /// Return: nothing; `error.InvalidArguments` on an unknown option or a
    /// `--library` without a name, or `error.OutOfMemory`.
    pub fn parseArgs(self: *Self, args: []const [:0]const u8) !void {
        for (args, 0..) |arg, i| {
            if (std.mem.eql(u8, arg, "--")) {
                self.executables = args[i + 1 ..];
                return;
            }
            const eq = std.mem.findScalar(u8, arg, '=') orelse return error.InvalidArguments;
            const key = arg[0..eq];
            const value = arg[eq + 1 ..];
            inline for (.{ "name", "bundle", "version", "summary", "arch", "root" }) |field| {
                if (std.mem.eql(u8, key, "--" ++ field)) {
                    @field(self, field) = value;
                    break;
                }
            } else if (std.mem.eql(u8, key, "--scripts")) {
                self.scripts = value;
            } else if (std.mem.eql(u8, key, "--library")) {
                const split = std.mem.findScalar(u8, value, '=') orelse return error.InvalidArguments;
                if (split == 0 or split + 1 == value.len) return error.InvalidArguments;
                try self.libraries.append(self.allocator, .{ .name = value[0..split], .path = value[split + 1 ..] });
            } else {
                log.err("unknown option {s}", .{arg});
                return error.InvalidArguments;
            }
        }
    }

    /// Copies the programs into `dir`.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `dir`: the destination, created if absent.
    ///
    /// Return: the copies' paths; IO errors.
    pub fn copyExecutables(self: *const Self, dir: []const u8) ![]const []const u8 {
        try std.Io.Dir.cwd().createDirPath(self.io, dir);
        var copies: std.ArrayList([]const u8) = .empty;
        for (self.executables) |from| {
            const to = try std.Io.Dir.path.join(self.allocator, &.{ dir, std.Io.Dir.path.basename(from) });
            try std.Io.Dir.cwd().copyFile(from, std.Io.Dir.cwd(), to, self.io, .{});
            try copies.append(self.allocator, to);
        }
        return copies.items;
    }

    /// Copies the shared libraries into `dir`, each under its own name.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `dir`: the destination, created only when there is a library to copy.
    ///
    /// Return: the copies' paths; IO errors.
    pub fn copyLibraries(self: *const Self, dir: []const u8) ![]const []const u8 {
        if (self.libraries.items.len == 0) return &.{};
        try std.Io.Dir.cwd().createDirPath(self.io, dir);
        var copies: std.ArrayList([]const u8) = .empty;
        for (self.libraries.items) |library| {
            const to = try std.Io.Dir.path.join(self.allocator, &.{ dir, library.name });
            try std.Io.Dir.cwd().copyFile(library.path, std.Io.Dir.cwd(), to, self.io, .{});
            try copies.append(self.allocator, to);
        }
        return copies.items;
    }

    /// Fills template `name` and writes it to `path`.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `path`: where to write it; its directory is created if absent.
    /// - `name`: the template's name.
    /// - `executable`: whether the file is a script to mark executable.
    ///
    /// Return: nothing; IO errors.
    pub fn writeScript(self: *const Self, path: []const u8, name: []const u8, executable: bool) !void {
        const text = try Self.fill(self.allocator, try self.template(name), self.name, self.id(), self.orgLabel());
        try std.Io.Dir.cwd().createDirPath(self.io, std.Io.Dir.path.dirname(path).?);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = text, .flags = .{ .permissions = if (executable) .executable_file else .default_file } });
    }

    /// Reads `signing.zon` from the project root, refusing one that git would commit.
    ///
    /// Parameters:
    /// - `self`: the run.
    ///
    /// Return: the settings, or `null` when there is no file;
    /// `error.PkgFailed` when git does not ignore it, it does not parse, or
    /// it lacks `apple_name` or `apple_team`, or IO errors.
    pub fn signing(self: *const Self) !?Signing {
        const path = try std.Io.Dir.path.join(self.allocator, &.{ self.root, "signing.zon" });
        const source = std.Io.Dir.cwd().readFileAllocOptions(self.io, path, self.allocator, .limited(1 << 16), .of(u8), 0) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        const ignored = mod.Git.isIgnored(self.allocator, self.io, self.root, "signing.zon") catch return self.fail("cannot check that git ignores {s}", .{path});
        if (!ignored) return self.fail("{s} holds Apple credentials, but git does not ignore it; add signing.zon to .gitignore", .{path});
        // SAFETY: fromSlice sets it before returning error.ParseZon, the only path that reads it.
        var diag: std.zon.parse.Diagnostics = undefined;
        const settings = Signing.parse(self.allocator, source, &diag) catch |err| switch (err) {
            error.ParseZon => return self.fail("{f}", .{diag.fmt(path)}),
            else => return err,
        };
        if (!settings.canSign()) return self.fail("{s} needs .apple_name and .apple_team", .{path});
        return settings;
    }

    /// Runs a packaging tool and fails when it fails.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `argv`: the command.
    /// - `secret`: text to hide in any message, e.g. a password in `argv`.
    ///
    /// Return: what it printed; `error.PkgFailed` with the tool's output logged, or spawn errors.
    pub fn runTool(self: *const Self, argv: []const []const u8, secret: ?[]const u8) !std.process.RunResult {
        const result = std.process.run(self.allocator, self.io, .{ .argv = argv }) catch |err| {
            return self.fail("cannot run {s} [{any}]", .{ argv[0], err });
        };
        switch (result.term) {
            .exited => |code| if (code == 0) return result,
            else => {},
        }
        var output = try std.mem.concat(self.allocator, u8, &.{ result.stdout, result.stderr });
        if (secret) |hidden| {
            // replaceOwned asserts a non-empty needle; an empty secret hides nothing anyway.
            if (hidden.len > 0) output = try std.mem.replaceOwned(u8, self.allocator, output, hidden, "<redacted>");
        }
        return self.fail("{s} failed [{any}]:\n{s}", .{ argv[0], result.term, std.mem.trim(u8, output, " \t\r\n") });
    }

    /// Returns the package id: `.bundle`, the bundle id.
    ///
    /// Parameters:
    /// - `self`: the run.
    ///
    /// Return: the id.
    pub fn id(self: *const Self) []const u8 {
        return self.bundle;
    }

    /// Returns the organisation's label for paths: the second label of `.bundle`.
    ///
    /// Parameters:
    /// - `self`: the run.
    ///
    /// Return: e.g. `example` for `com.example.tool`; `.bundle` itself when it is not three labels.
    pub fn orgLabel(self: *const Self) []const u8 {
        const labels = Pkg.labels(self.bundle) orelse return self.bundle;
        return labels.org;
    }

    /// Logs why the package cannot be built.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `fmt`: the message format.
    /// - `args`: its arguments.
    ///
    /// Return: always `error.PkgFailed`.
    pub fn fail(self: *const Self, comptime fmt: []const u8, args: anytype) error{PkgFailed} {
        _ = self;
        log.err(fmt, args);
        return error.PkgFailed;
    }

    /// Stages the `.deb`'s `control` and `data` trees and packs them into `out`.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `stage`: an empty staging directory.
    /// - `out`: where the package goes.
    ///
    /// Return: nothing; IO errors.
    fn buildDeb(self: *const Self, stage: []const u8, out: []const u8) !void {
        const prefix = try self.allocator.print("usr/local/{s}/{s}", .{ self.orgLabel(), self.name });
        _ = try self.copyExecutables(try std.Io.Dir.path.join(self.allocator, &.{ stage, "data", prefix, "bin" }));
        _ = try self.copyLibraries(try std.Io.Dir.path.join(self.allocator, &.{ stage, "data", prefix, "lib" }));
        try self.writeScript(try std.Io.Dir.path.join(self.allocator, &.{ stage, "data", "etc", "profile.d", try self.allocator.print("{s}.sh", .{self.name}) }), "profile.sh", false);
        try self.writeScript(try std.Io.Dir.path.join(self.allocator, &.{ stage, "control", "preinst" }), "preinst", true);
        try self.writeScript(try std.Io.Dir.path.join(self.allocator, &.{ stage, "control", "postrm" }), "postrm", true);
        const control = try self.allocator.print(
            \\Package: {s}
            \\Version: {s}
            \\Architecture: {s}
            \\Maintainer: {s}
            \\Section: utils
            \\Priority: optional
            \\Description: {s}
            \\
        , .{ self.name, self.version, self.arch, self.orgLabel(), self.summary });
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = try std.Io.Dir.path.join(self.allocator, &.{ stage, "control", "control" }), .data = control });
        var staging = try std.Io.Dir.cwd().openDir(self.io, stage, .{});
        defer staging.close(self.io);
        const packer = try mod.Deb.init(self.allocator, self.io);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = out, .data = try packer.pack(staging) });
    }

    /// Returns template `name`: the project's, when `--scripts` has one, else the embedded one.
    ///
    /// Parameters:
    /// - `self`: the run.
    /// - `name`: the template's name.
    ///
    /// Return: its text; IO errors.
    fn template(self: *const Self, name: []const u8) ![]const u8 {
        if (self.scripts) |dir| {
            const path = try std.Io.Dir.path.join(self.allocator, &.{ dir, name });
            if (std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(1 << 20))) |text| {
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
};

/// Builds an installable package of a project's executables: `zig build pkg`.
///
/// The format follows the executables' target OS: a `.pkg` for macOS, a
/// `.deb` for Linux, an `.msi` for Windows, all installed to `zig-out/pkg/`.
/// Each installs the programs in a `bin` directory under
/// `/usr/local/<org>/<name>` (`%LOCALAPPDATA%\<org>\<name>` on Windows) and
/// puts it on `PATH`; each program keeps its own executable's name.
///
/// The project's `build.zig.zon` supplies `.version` and `.bundle`, the bundle
/// id in reverse DNS: three labels, such as `"com.example.tool"`. It is the
/// package id as written, and its second and last labels are the `<org>` and
/// `<name>` of every path, so `com.example.tool` installs to
/// `/usr/local/example/tool`. The project's own `.name` is not used. Without
/// a valid `.bundle`, `zig build pkg` fails; nothing else in the build is affected.
///
/// The install scripts are templates embedded in zigbuildx, filled in with the
/// package's name, id and organisation; `PkgOptions.scripts` can replace them.
///
/// A Zig 0.17 step cannot run code of its own, so the macOS and Linux packages
/// are staged and built by the host tool's `pkg` command (`PkgRun`); the
/// Windows one is staged by a `WriteFiles` step and built by `wixl`.
pub const Pkg = struct {
    const Self = @This();

    /// The step that installs the package into `zig-out/pkg/`, or fails with `problem`.
    step: *std.Build.Step,
    /// The package's name: the last label of `.bundle`.
    name: []const u8,
    /// The package's `.bundle`: its bundle id, in reverse DNS.
    bundle: []const u8,
    /// The package's `.version`.
    version: []const u8,
    /// One line describing the package, from `.description` or the name.
    description: []const u8,
    executables: []const *std.Build.Step.Compile,
    libraries: []const PkgLibrary,
    scripts: ?std.Build.LazyPath,
    /// The target the executables are built for; valid unless `problem` is set.
    // SAFETY: populated by check() before first read, unless problem is set.
    target: std.Target = undefined,
    /// Why the package cannot be built, reported when `zig build pkg` runs.
    problem: ?[]const u8 = null,

    /// Declares `zig build pkg`, and `zig build pkg-notarize` for a macOS target.
    ///
    /// A missing `.bundle` or another problem does not fail the build graph: it
    /// fails `zig build pkg` with a message, so every other step still works.
    ///
    /// Parameters:
    /// - `b`: the project's build graph.
    /// - `zon`: the project's `@import("build.zig.zon")`.
    /// - `options`: what to package.
    ///
    /// Return: the package, whose `step` builds and installs it.
    pub fn add(b: *std.Build, comptime zon: anytype, options: PkgOptions) *Self {
        const self = b.allocator.create(Self) catch @panic("OOM");
        const bundle: []const u8 = if (@hasField(@TypeOf(zon), "bundle")) zon.bundle else "";
        self.* = .{
            // SAFETY: set below, once check() has chosen the steps.
            .step = undefined,
            .name = if (Self.labels(bundle)) |split| split.name else @tagName(zon.name),
            .bundle = bundle,
            .version = zon.version,
            .description = if (@hasField(@TypeOf(zon), "description")) zon.description else @tagName(zon.name),
            .executables = b.allocator.dupe(*std.Build.Step.Compile, options.executables) catch @panic("OOM"),
            .libraries = b.allocator.dupe(PkgLibrary, options.libraries) catch @panic("OOM"),
            .scripts = options.scripts,
        };
        self.problem = self.check(b);
        const top = b.step("pkg", "Build an installable package for -Dtarget's OS into zig-out/pkg");
        self.step = if (self.problem) |problem| &b.addFail(problem).step else switch (self.target.os.tag) {
            .macos, .linux => self.addPackage(b),
            .windows => self.addMsi(b),
            else => unreachable,
        };
        top.dependOn(self.step);
        if (self.problem == null and self.target.os.tag == .macos) {
            const notarize = b.step("pkg-notarize", "Notarize and staple the macOS package (uploads it to Apple and waits)");
            notarize.dependOn(self.addNotarize(b));
        }
        return self;
    }

    /// `zigbuildx pkg <macos|linux|notarize> <out> [--key=value...] [-- <program>...]`: builds a package, or notarizes one.
    ///
    /// `macos` and `linux` stage the programs and scripts beside `out` and
    /// build the package there; `notarize` copies the package given as
    /// `--package` to `out`, then notarizes and staples the copy.
    ///
    /// Parameters:
    /// - `process_init`: the process's allocator and IO.
    /// - `args`: the command line after the program's path; `args[0]` is the command.
    ///
    /// Return: nothing; `error.InvalidArguments` on a bad command line,
    /// `error.PkgFailed` with the reason logged, or IO errors.
    pub fn command(process_init: std.process.Init, args: []const [:0]const u8) !void {
        if (args.len < 3) {
            log.err("usage: zigbuildx pkg <macos|linux|notarize> <out> [--key=value...] [-- <program>...]", .{});
            return error.InvalidArguments;
        }
        const allocator = process_init.arena.allocator();
        const io = process_init.io;
        var run = try PkgRun.init(allocator, io);
        const out = args[2];
        if (std.mem.eql(u8, args[1], "notarize")) {
            if (args.len != 5 or !std.mem.startsWith(u8, args[3], "--package=")) return error.InvalidArguments;
            try run.parseArgs(args[4..]);
            run.root = try std.Io.Dir.cwd().realPathFileAlloc(io, run.root, allocator);
            try std.Io.Dir.cwd().copyFile(args[3]["--package=".len..], std.Io.Dir.cwd(), out, io, .{});
            return mod.Pkgbuild.notarize(&run, out);
        }
        try run.parseArgs(args[3..]);
        run.root = try std.Io.Dir.cwd().realPathFileAlloc(io, run.root, allocator);
        const stage = try std.Io.Dir.path.join(allocator, &.{ std.Io.Dir.path.dirname(out) orelse ".", "stage" });
        try std.Io.Dir.cwd().deleteTree(io, stage);
        try std.Io.Dir.cwd().createDirPath(io, stage);
        // Only the package is kept; the staged copies of the programs would double the cache's share.
        defer std.Io.Dir.cwd().deleteTree(io, stage) catch |err| log.warn("cannot remove {s} [{any}]", .{ stage, err });
        if (std.mem.eql(u8, args[1], "macos")) return mod.Pkgbuild.build(&run, stage, out);
        if (std.mem.eql(u8, args[1], "linux")) return run.buildDeb(stage, out);
        log.err("unknown package format {s}", .{args[1]});
        return error.InvalidArguments;
    }

    /// Returns the labels of a bundle id that paths use: its second and last.
    ///
    /// Parameters:
    /// - `bundle`: a bundle id in reverse DNS.
    ///
    /// Return: e.g. `example` and `tool` for `com.example.tool`; `null` unless
    /// it is exactly three non-empty labels.
    pub fn labels(bundle: []const u8) ?PkgLabels {
        var parts = std.mem.splitScalar(u8, bundle, '.');
        const domain = parts.next() orelse return null;
        const org = parts.next() orelse return null;
        const name = parts.next() orelse return null;
        if (parts.next() != null or domain.len == 0 or org.len == 0 or name.len == 0) return null;
        return .{ .org = org, .name = name };
    }

    /// Declares the host tool run that builds the macOS or Linux package, and its install.
    ///
    /// Parameters:
    /// - `self`: the package, with no problem.
    /// - `b`: the build graph.
    ///
    /// Return: the install step.
    fn addPackage(self: *Self, b: *std.Build) *std.Build.Step {
        const run = b.addRunArtifact(mod.HostTool.add(b));
        const file_name = self.fileName(b);
        run.setName(b.fmt("pkg {s}", .{file_name}));
        run.addArgs(&.{ "pkg", @tagName(self.target.os.tag) });
        const out = run.addOutputFileArg2(file_name, .{});
        self.addOptions(b, run);
        if (self.target.os.tag == .linux) run.addArg(b.fmt("--arch={s}", .{mod.Deb.arch(self.target.cpu.arch).?}));
        for (self.libraries) |library| run.addFileArg2(library.path, .{ .prefix = b.fmt("--library={s}=", .{library.name}) });
        run.addArg("--");
        for (self.executables) |exe| run.addArtifactArg2(exe, .{});
        // Signing reads signing.zon and the keychain, and scripts are read from
        // a directory, none of which the step's inputs record: it always runs.
        run.has_side_effects = true;
        return &b.addInstallFileWithDir(out, .prefix, b.fmt("pkg/{s}", .{file_name})).step;
    }

    /// Declares the host tool run that notarizes a copy of the macOS package, and its install over the package.
    ///
    /// Parameters:
    /// - `self`: the macOS package, with no problem.
    /// - `b`: the build graph.
    ///
    /// Return: the install step.
    fn addNotarize(self: *Self, b: *std.Build) *std.Build.Step {
        const install = self.step.cast(std.Build.Step.InstallFile).?;
        const run = b.addRunArtifact(mod.HostTool.add(b));
        const file_name = self.fileName(b);
        run.setName(b.fmt("pkg notarize {s}", .{file_name}));
        run.addArgs(&.{ "pkg", "notarize" });
        const out = run.addOutputFileArg2(file_name, .{});
        run.addFileArg2(install.source, .{ .prefix = "--package=" });
        run.addDirectoryArg2(b.path("."), .{ .prefix = "--root=" });
        // It uploads to Apple: never cached.
        run.has_side_effects = true;
        const notarized = b.addInstallFileWithDir(out, .prefix, b.fmt("pkg/{s}", .{file_name}));
        // The same path as the plain package; written after it, never alongside.
        notarized.step.dependOn(self.step);
        return &notarized.step;
    }

    /// Declares the Windows package: a `WriteFiles` stage and `wixl`, or, without `wixl`, the stage installed for a host that has it.
    ///
    /// `wixl` is looked for while the graph is configured, which makes every
    /// build of a Windows package configure again; the message for a missing
    /// one is worth it.
    ///
    /// Parameters:
    /// - `self`: the Windows package, with no problem.
    /// - `b`: the build graph.
    ///
    /// Return: the step that installs the `.msi`, or fails after installing the stage.
    fn addMsi(self: *Self, b: *std.Build) *std.Build.Step {
        const stage = b.addWriteFiles();
        var files: std.ArrayList([]const u8) = .empty;
        for (self.executables) |exe| {
            const file = Self.exeName(exe);
            _ = stage.addCopyFile(exe.getEmittedBin(), b.fmt("bin/{s}", .{file}));
            files.append(b.allocator, file) catch @panic("OOM");
        }
        for (self.libraries) |library| {
            _ = stage.addCopyFile(library.path, b.fmt("bin/{s}", .{library.name}));
            files.append(b.allocator, library.name) catch @panic("OOM");
        }
        const msi = mod.Msi{ .name = self.name, .org = Self.labels(self.bundle).?.org, .id = self.bundle, .version = self.version, .files = files.items };
        const xml = msi.render(b.allocator) catch |err| switch (err) {
            error.InvalidVersion => return &b.addFail(b.fmt(".version = \"{s}\" is not one an MSI can carry: major.minor.patch, at most 255.255.65535", .{self.version})).step,
            error.OutOfMemory, error.WriteFailed => @panic("OOM"),
        };
        _ = stage.add("product.wxs", xml);
        const platform = mod.Msi.arch(self.target.cpu.arch).?;
        const file_name = self.fileName(b);
        const wixl = b.findProgram(.{ .names = &.{"wixl"} }) orelse {
            const dir = b.fmt("{s}-{s}-wix", .{ self.name, self.version });
            const install = b.addInstallDirectory(.{ .source_dir = stage.getDirectory(), .install_dir = .prefix, .install_subdir = b.fmt("pkg/{s}", .{dir}) });
            const fail = b.addFail(b.fmt("wixl is not on PATH (apt install wixl, or Homebrew's msitools); wrote zig-out/pkg/{s}; to build the installer: cd zig-out/pkg/{s} && wixl -a {s} -o ../{s} product.wxs", .{ dir, dir, platform, file_name }));
            fail.step.dependOn(&install.step);
            return &fail.step;
        };
        const run = b.addSystemCommand(&.{ wixl, "-a", platform, "-o" });
        run.setName(b.fmt("wixl {s}", .{file_name}));
        const out = run.addOutputFileArg2(file_name, .{});
        run.addArg("product.wxs");
        run.setCwd(stage.getDirectory());
        // wixl reads bin/ through the stage's path, which a Run step does not hash.
        for (self.executables) |exe| run.addFileInput(exe.getEmittedBin());
        for (self.libraries) |library| run.addFileInput(library.path);
        run.addFileInput(stage.getDirectory().path(b, "product.wxs"));
        return &b.addInstallFileWithDir(out, .prefix, b.fmt("pkg/{s}", .{file_name})).step;
    }

    /// Passes the package's identity, its scripts and the project root to the host tool.
    ///
    /// Parameters:
    /// - `self`: the package.
    /// - `b`: the build graph.
    /// - `run`: the host tool run.
    fn addOptions(self: *Self, b: *std.Build, run: *std.Build.Step.Run) void {
        run.addArgs(&.{
            b.fmt("--name={s}", .{self.name}),
            b.fmt("--bundle={s}", .{self.bundle}),
            b.fmt("--version={s}", .{self.version}),
            b.fmt("--summary={s}", .{self.summary()}),
        });
        if (self.scripts) |scripts| run.addDirectoryArg2(scripts, .{ .prefix = "--scripts=" });
        run.addDirectoryArg2(b.path("."), .{ .prefix = "--root=" });
    }

    /// Checks what `zig build pkg` needs, and records the executables' target.
    ///
    /// Parameters:
    /// - `self`: the package.
    /// - `b`: the build graph, for messages.
    ///
    /// Return: why the package cannot be built, or `null`.
    fn check(self: *Self, b: *std.Build) ?[]const u8 {
        if (self.bundle.len == 0) return "build.zig.zon has no .bundle; add the bundle id in reverse DNS, e.g. .bundle = \"com.example.tool\"";
        if (!Self.isSafe(self.bundle)) return b.fmt(".bundle = \"{s}\" may hold only letters, digits, '.', '-' and '_'", .{self.bundle});
        if (Self.labels(self.bundle) == null) return b.fmt(".bundle = \"{s}\" must be three labels, <domain>.<org>.<name>, e.g. \"com.example.tool\" for /usr/local/example/tool", .{self.bundle});
        if (self.executables.len == 0) return "Pkg.add was given no executables";
        for (self.executables, 0..) |exe, i| {
            for (self.executables[i + 1 ..]) |other| {
                if (std.mem.eql(u8, exe.name, other.name)) return b.fmt("two executables install as bin/{s}; give them different names", .{Self.exeName(exe)});
            }
        }
        for (self.libraries, 0..) |library, i| {
            if (!Self.isSafe(library.name)) return b.fmt("library name \"{s}\" may hold only letters, digits, '.', '-' and '_'", .{library.name});
            for (self.libraries[i + 1 ..]) |other| {
                if (std.mem.eql(u8, library.name, other.name)) return b.fmt("two libraries install as {s}; give them different names", .{library.name});
            }
            // Windows stages libraries in `bin` beside the programs.
            for (self.executables) |exe| {
                if (std.mem.eql(u8, library.name, Self.exeName(exe))) return b.fmt("library {s} has the name of an executable", .{library.name});
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

    /// Returns the file name an executable is emitted as: its name, plus `.exe` on Windows.
    ///
    /// `Compile.out_filename` is deprecated in Zig 0.17.
    ///
    /// Parameters:
    /// - `exe`: the executable.
    ///
    /// Return: the name; borrowed from `exe` unless the target adds an extension.
    fn exeName(exe: *std.Build.Step.Compile) []const u8 {
        const target = exe.rootModuleTarget();
        if (target.os.tag != .windows) return exe.name;
        return exe.step.owner.fmt("{s}{s}", .{ exe.name, target.exeFileExt() });
    }

    /// Returns the package's file name, in each platform's convention.
    ///
    /// Parameters:
    /// - `self`: the package, with no problem.
    /// - `b`: the build graph, whose arena holds the name.
    ///
    /// Return: `<name>-<version>.pkg`, `<name>_<version>_<arch>.deb` or `<name>-<version>-<arch>.msi`.
    fn fileName(self: *const Self, b: *std.Build) []const u8 {
        return switch (self.target.os.tag) {
            .macos => b.fmt("{s}-{s}.pkg", .{ self.name, self.version }),
            .linux => b.fmt("{s}_{s}_{s}.deb", .{ self.name, self.version, mod.Deb.arch(self.target.cpu.arch).? }),
            .windows => b.fmt("{s}-{s}-{s}.msi", .{ self.name, self.version, mod.Msi.arch(self.target.cpu.arch).? }),
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
    _ = &Pkg.add;
    _ = &Pkg.command;
}

test "Signing reads signing.zon, treats empty strings as unset, and rejects unknown fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    // SAFETY: fromSlice sets it before returning error.ParseZon, the only path that reads it.
    var diag: std.zon.parse.Diagnostics = undefined;
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

    const partial = try Signing.parse(allocator, ".{ .apple_name = \"x\", .apple_team = \"\" }", &diag);
    try std.testing.expectEqual(null, partial.apple_team);
    try std.testing.expect(!partial.canSign());

    try std.testing.expectError(error.ParseZon, Signing.parse(allocator, ".{ .apple_pass = \"x\" }", &diag));
}

test "fill replaces every placeholder, and the embedded templates use only known ones" {
    const allocator = std.testing.allocator;
    const out = try PkgRun.fill(allocator, "/usr/local/{pkg_org}/{pkg_name} {pkg_id} {pkg_name}", "tool", "com.acme.tool", "acme");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("/usr/local/acme/tool com.acme.tool tool", out);
    for (PkgRun.templates) |embedded| {
        const filled = try PkgRun.fill(allocator, embedded.text, "tool", "com.acme.tool", "acme");
        defer allocator.free(filled);
        try std.testing.expect(std.mem.find(u8, filled, "{pkg_") == null);
    }
}

test "parseArgs reads options and programs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var run = try PkgRun.init(arena.allocator(), std.testing.io);
    try run.parseArgs(&.{ "--name=tool", "--bundle=com.acme.tool", "--version=1.2.3", "--summary=A tool", "--scripts=s", "--library=libx.dylib=c/x=1/libx.dylib", "--library=liby.so=d/liby.so", "--", "a/tool", "b/helper" });
    try std.testing.expectEqualStrings("tool", run.name);
    try std.testing.expectEqualStrings("com.acme.tool", run.id());
    try std.testing.expectEqualStrings("acme", run.orgLabel());
    try std.testing.expectEqualStrings("s", run.scripts.?);
    try std.testing.expectEqual(@as(usize, 2), run.executables.len);
    try std.testing.expectEqual(@as(usize, 2), run.libraries.items.len);
    try std.testing.expectEqualStrings("libx.dylib", run.libraries.items[0].name);
    // Only the first `=` after the name splits: a path may hold one.
    try std.testing.expectEqualStrings("c/x=1/libx.dylib", run.libraries.items[0].path);
    try std.testing.expectEqualStrings("d/liby.so", run.libraries.items[1].path);
    try std.testing.expectError(error.InvalidArguments, run.parseArgs(&.{"--nope"}));
    try std.testing.expectError(error.InvalidArguments, run.parseArgs(&.{"--library=nopath"}));
    try std.testing.expectError(error.InvalidArguments, run.parseArgs(&.{"--library==a/libx.dylib"}));
}

test "isSafe allows letters, digits, '.', '-' and '_'" {
    try std.testing.expect(Pkg.isSafe("com.acme-2_x"));
    try std.testing.expect(!Pkg.isSafe("a/b"));
    try std.testing.expect(!Pkg.isSafe(""));
}

test "labels are the bundle id's second and last, and only for three" {
    const labels = Pkg.labels("com.example.tool").?;
    try std.testing.expectEqualStrings("example", labels.org);
    try std.testing.expectEqualStrings("tool", labels.name);
    try std.testing.expectEqual(null, Pkg.labels("com.example"));
    try std.testing.expectEqual(null, Pkg.labels("com.example.tools.tool"));
    try std.testing.expectEqual(null, Pkg.labels("com..tool"));
    try std.testing.expectEqual(null, Pkg.labels("solo"));
}
