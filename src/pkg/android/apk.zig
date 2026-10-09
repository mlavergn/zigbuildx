const std = @import("std");
const mod = @import("module.zig");

/// What `Apk.add` packages.
pub const ApkOptions = struct {
    const Self = @This();
    /// The APK's file name, without `.apk`.
    name: []const u8,
    manifest: std.Build.LazyPath,
    /// A `res/` directory, compiled by `aapt2`; null when the app has none.
    resources: ?std.Build.LazyPath = null,
    /// Shared libraries for Android targets, each placed under its ABI's `lib/` directory.
    libraries: []const *std.Build.Step.Compile,
    /// The signing keystore; null signs with `Apk.debugKeystore`.
    keystore: ?std.Build.LazyPath = null,
    /// `apksigner`'s `--ks-pass`: `pass:<password>`, `env:<VAR>` or `file:<path>`.
    keystore_password: []const u8 = "pass:android",
};

/// Packages Android native libraries into a signed, aligned APK.
///
/// Runs the SDK's `aapt2`, `zipalign` and `apksigner`, which a resolved
/// `Android` locates; adding the libraries to the APK is done in Zig by
/// `ApkZip`, so no `zip` or JDK `jar` is needed.
pub const Apk = struct {
    const Self = @This();

    /// Packages `options.libraries` into a signed, aligned APK.
    ///
    /// `aapt2` compiles the resources and links them with the manifest; the
    /// libraries are added stored, since Android maps them straight out of the
    /// APK; `zipalign -P 16` puts them on 16 KB boundaries; `apksigner` signs.
    ///
    /// Parameters:
    /// - `android`: a resolved `Android`, for the SDK tools.
    /// - `b`: the build graph.
    /// - `options`: what to package.
    ///
    /// Return: the signed APK; `error.NotAndroid` for a library with no Android target.
    pub fn add(android: *mod.Android, b: *std.Build, options: ApkOptions) !std.Build.LazyPath {
        std.debug.assert(android.loaded);

        const link = b.addSystemCommand(&.{ android.tool("aapt2"), "link", "-I", android.android_jar, "--manifest" });
        link.setName(b.fmt("aapt2 link {s}", .{options.name}));
        link.addFileArg(options.manifest);
        link.addArg("-o");
        const base = link.addOutputFileArg2("base.apk", .{});
        if (options.resources) |resources| {
            const compile = b.addSystemCommand(&.{ android.tool("aapt2"), "compile", "--dir" });
            compile.setName(b.fmt("aapt2 compile {s}", .{options.name}));
            compile.addDirectoryArg2(resources, .{});
            try Self.addDirectoryInputs(b, compile, resources);
            compile.addArg("-o");
            link.addFileArg(compile.addOutputFileArg2("resources.zip", .{}));
        }

        const staging = b.addWriteFiles();
        for (options.libraries) |lib| {
            const target = (lib.root_module.resolved_target orelse return error.NotAndroid).result;
            const abi = mod.AndroidAbi.fromTarget(target) orelse return error.NotAndroid;
            _ = staging.addCopyFile(lib.getEmittedBin(), b.fmt("lib/{s}/{s}", .{ abi.dirName(), try Self.fileName(b, lib) }));
        }
        const zip = b.addRunArtifact(mod.HostTool.add(b));
        zip.setName(b.fmt("apk-zip {s}", .{options.name}));
        zip.addArg("apk-zip");
        zip.addFileArg(base);
        const unaligned = zip.addOutputFileArg2("unaligned.apk", .{});
        zip.addDirectoryArg2(staging.getDirectory(), .{});

        const align_step = b.addSystemCommand(&.{ android.tool("zipalign"), "-P", "16", "-f", "4" });
        align_step.setName(b.fmt("zipalign {s}", .{options.name}));
        align_step.addFileArg(unaligned);
        const aligned = align_step.addOutputFileArg2("aligned.apk", .{});

        const sign = b.addSystemCommand(&.{ android.tool("apksigner"), "sign", "--ks" });
        sign.setName(b.fmt("apksigner {s}", .{options.name}));
        sign.addFileArg(options.keystore orelse Self.debugKeystore(android, b));
        sign.addArgs(&.{ "--ks-pass", options.keystore_password, "--out" });
        const apk = sign.addOutputFileArg2(b.fmt("{s}.apk", .{options.name}), .{});
        sign.addFileArg(aligned);
        return apk;
    }

    /// Returns a debug keystore: Android Studio's when one exists, else one generated into the build cache.
    ///
    /// A generated keystore lives as long as the cache does. Clearing the cache
    /// mints a new key, and a device then refuses the update until the app is
    /// uninstalled — use Android Studio's, or pass a real keystore for release.
    ///
    /// Parameters:
    /// - `android`: a resolved `Android`, for the keystore and `keytool`.
    /// - `b`: the build graph.
    ///
    /// Return: the keystore, password `android`, alias `androiddebugkey`.
    pub fn debugKeystore(android: *mod.Android, b: *std.Build) std.Build.LazyPath {
        if (android.debug_keystore) |path| return b.graph.cwdRelativePath(path);
        const keytool = b.addSystemCommand(&.{ android.javaTool("keytool"), "-genkeypair", "-keystore" });
        keytool.setName("keytool debug.keystore");
        const keystore = keytool.addOutputFileArg2("debug.keystore", .{});
        keytool.addArgs(&.{ "-storepass", "android", "-keypass", "android", "-alias", "androiddebugkey", "-keyalg", "RSA", "-validity", "10000", "-dname", "CN=Android Debug,O=Android,C=US" });
        return keystore;
    }

    /// Makes `run` depend on every file under `dir`, not only on its path.
    ///
    /// A Run step hashes a directory argument's path, not its contents, so an
    /// edited `res/` would leave the cached `aapt2 compile` output in place. A
    /// generated directory needs nothing: its path changes with its contents.
    /// The walk happens while the graph is declared, so every directory walked
    /// is also a configure input: Zig 0.17 reuses a configured graph, and an
    /// added or removed file must configure again to change the inputs.
    ///
    /// Parameters:
    /// - `b`: the build graph.
    /// - `run`: the step that reads `dir`.
    /// - `dir`: the directory.
    ///
    /// Return: nothing; IO errors from walking `dir`.
    fn addDirectoryInputs(b: *std.Build, run: *std.Build.Step.Run, dir: std.Build.LazyPath) !void {
        const io = b.graph.io;
        const root = switch (dir) {
            .generated => return,
            .src_path => |source| try source.owner.root.joinString(b.allocator, source.sub_path),
            .dependency => |dep| try dep.dependency.builder.root.joinString(b.allocator, dep.sub_path),
            .cwd_relative => |path| path,
            .relative => |relative| if (relative.base == .cwd) relative.sub_path else return,
        };
        var handle = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
        defer handle.close(io);
        b.dependOnDirectoryContents(dir);
        var walker = try handle.walk(b.allocator);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            switch (entry.kind) {
                .file => run.addFileInput(dir.path(b, entry.path)),
                .directory => b.dependOnDirectoryContents(dir.path(b, entry.path)),
                else => {},
            }
        }
    }

    /// Returns the file name `lib` is emitted as, e.g. `libmain.so`.
    ///
    /// `Compile.out_filename` is deprecated in Zig 0.17; this is how Zig itself
    /// derives it.
    ///
    /// Parameters:
    /// - `b`: the build graph, whose arena holds the name.
    /// - `lib`: the library.
    ///
    /// Return: the name; allocation errors.
    fn fileName(b: *std.Build, lib: *std.Build.Step.Compile) ![]const u8 {
        const target = lib.rootModuleTarget();
        return std.zig.binNameAlloc(b.allocator, .{
            .root_name = lib.name,
            .cpu_arch = target.cpu.arch,
            .os_tag = target.os.tag,
            .ofmt = target.ofmt,
            .abi = target.abi,
            .output_mode = .Lib,
            .link_mode = lib.linkage,
            .version = lib.version,
        });
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test "the packager compiles for every host" {
    // Nothing in the tests calls it, and Zig compiles only what is referenced;
    // taking its address compiles it, so `make cross` checks it for Windows and
    // Linux hosts too.
    _ = &Apk.add;
}
