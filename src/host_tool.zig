const std = @import("std");

/// Builds one of zigbuildx's own programs for the build host.
///
/// Some extensions do their work in a program rather than a shell command, so
/// it behaves the same on every host and needs nothing installed. The program's
/// source is embedded in zigbuildx and written out by the consumer's build, which
/// compiles it like any other artifact — and caches it the same way.
pub const HostTool = struct {
    const Self = @This();

    /// Returns `source`, a single-file program using only `std`, compiled for the build host.
    ///
    /// Parameters:
    /// - `b`: the consumer's build graph.
    /// - `name`: the executable's name.
    /// - `file_name`: the source's file name, as error messages will show it.
    /// - `source`: the program, usually `@embedFile` of a sibling file.
    ///
    /// Return: the executable.
    pub fn add(b: *std.Build, name: []const u8, file_name: []const u8, source: []const u8) *std.Build.Step.Compile {
        const root = b.addWriteFiles().add(file_name, source);
        return b.addExecutable(.{ .name = name, .root_module = b.createModule(.{
            .root_source_file = root,
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }) });
    }
};
