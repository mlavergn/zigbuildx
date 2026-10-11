const std = @import("std");
const log = std.log.scoped(.zigbuildx_tool);
const mod = @import("module.zig");

/// zigbuildx's host program: one command per job a build step hands it.
///
/// Built for the build host through `HostTool.add` and run by `Run` steps, so
/// the work behaves the same on every host and needs no shell tools. Each
/// command lives with the extension it serves; this only dispatches.
pub const Tool = struct {
    const Self = @This();

    /// A command's name and the function that runs it.
    const Command = struct {
        name: []const u8,
        run: *const fn (process_init: std.process.Init, args: []const [:0]const u8) anyerror!void,
    };

    /// Every command, by the name a step passes first.
    const commands = [_]Command{
        .{ .name = "apk-zip", .run = mod.pkg.android.ApkZip.command },
        .{ .name = "deb", .run = mod.pkg.Deb.command },
        .{ .name = "deps", .run = mod.Deps.command },
        .{ .name = "deps-mark", .run = mod.Deps.mark },
        .{ .name = "docs-patch", .run = mod.Docs.command },
        .{ .name = "pkg", .run = mod.pkg.Pkg.command },
    };

    /// Runs the command `args[0]` names.
    ///
    /// Parameters:
    /// - `process_init`: the process's allocator and IO.
    /// - `args`: the command line after the program's path.
    ///
    /// Return: nothing; `error.InvalidArguments` for an unknown or missing
    /// command, or the command's own errors.
    pub fn dispatch(process_init: std.process.Init, args: []const [:0]const u8) !void {
        if (args.len > 0) {
            for (Self.commands) |entry| {
                if (std.mem.eql(u8, entry.name, args[0])) return entry.run(process_init, args);
            }
        }
        log.err("usage: zigbuildx <command> [args]; commands: apk-zip, deb, deps, deps-mark, docs-patch, pkg", .{});
        return error.InvalidArguments;
    }
};

/// Runs zigbuildx's host program.
///
/// Parameters:
/// - `init`: the process's allocator, IO and arguments.
///
/// Return: nothing; the command's errors, which fail the step that ran it.
/// One the command has already explained exits 1 without a second message.
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    Tool.dispatch(init, args[1..]) catch |err| switch (err) {
        error.AutodocChanged, error.DepsFailed, error.InvalidArguments, error.PkgFailed => std.process.exit(1),
        else => return err,
    };
}

// -----------------------------------------------------------------------------
// Unit Tests

test "every command is unique and dispatches" {
    for (Tool.commands, 0..) |entry, i| {
        for (Tool.commands[i + 1 ..]) |other| try std.testing.expect(!std.mem.eql(u8, entry.name, other.name));
    }
}
