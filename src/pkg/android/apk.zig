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
        const base = link.addOutputFileArg("base.apk");
        if (options.resources) |resources| {
            const compile = b.addSystemCommand(&.{ android.tool("aapt2"), "compile", "--dir" });
            compile.setName(b.fmt("aapt2 compile {s}", .{options.name}));
            compile.addDirectoryArg(resources);
            try Self.addDirectoryInputs(b, compile, resources);
            compile.addArg("-o");
            link.addFileArg(compile.addOutputFileArg("resources.zip"));
        }

        const staging = b.addWriteFiles();
        for (options.libraries) |lib| {
            const target = (lib.root_module.resolved_target orelse return error.NotAndroid).result;
            const abi = mod.AndroidAbi.fromTarget(target) orelse return error.NotAndroid;
            _ = staging.addCopyFile(lib.getEmittedBin(), b.fmt("lib/{s}/{s}", .{ abi.dirName(), lib.out_filename }));
        }
        const zip = b.addRunArtifact(mod.HostTool.add(b, "apk-zip", "apk_zip.zig", @embedFile("apk_zip.zig")));
        zip.setName(b.fmt("apk-zip {s}", .{options.name}));
        zip.addFileArg(base);
        const unaligned = zip.addOutputFileArg("unaligned.apk");
        zip.addDirectoryArg(staging.getDirectory());

        const align_step = b.addSystemCommand(&.{ android.tool("zipalign"), "-P", "16", "-f", "4" });
        align_step.setName(b.fmt("zipalign {s}", .{options.name}));
        align_step.addFileArg(unaligned);
        const aligned = align_step.addOutputFileArg("aligned.apk");

        const sign = b.addSystemCommand(&.{ android.tool("apksigner"), "sign", "--ks" });
        sign.setName(b.fmt("apksigner {s}", .{options.name}));
        sign.addFileArg(options.keystore orelse Self.debugKeystore(android, b));
        sign.addArgs(&.{ "--ks-pass", options.keystore_password, "--out" });
        const apk = sign.addOutputFileArg(b.fmt("{s}.apk", .{options.name}));
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
        if (android.debug_keystore) |path| return .{ .cwd_relative = path };
        const keytool = b.addSystemCommand(&.{ android.javaTool("keytool"), "-genkeypair", "-keystore" });
        keytool.setName("keytool debug.keystore");
        const keystore = keytool.addOutputFileArg("debug.keystore");
        keytool.addArgs(&.{ "-storepass", "android", "-keypass", "android", "-alias", "androiddebugkey", "-keyalg", "RSA", "-validity", "10000", "-dname", "CN=Android Debug,O=Android,C=US" });
        return keystore;
    }

    /// Makes `run` depend on every file under `dir`, not only on its path.
    ///
    /// A Run step hashes a directory argument's path, not its contents, so an
    /// edited `res/` would leave the cached `aapt2 compile` output in place. A
    /// generated directory needs nothing: its path changes with its contents.
    /// The walk happens while the graph is declared, so an added or removed
    /// file changes the inputs too.
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
            .src_path => |source| source.owner.pathFromRoot(source.sub_path),
            .cwd_relative => |path| path,
            .dependency => |dep| dep.dependency.builder.pathFromRoot(dep.sub_path),
        };
        var handle = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
        defer handle.close(io);
        var walker = try handle.walk(b.allocator);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind == .file) run.addFileInput(.{ .cwd_relative = b.pathJoin(&.{ root, entry.path }) });
        }
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
