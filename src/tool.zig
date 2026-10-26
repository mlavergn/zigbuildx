const std = @import("std");
const log = std.log.scoped(.zigbuildx_tool);
const mod = @import("module.zig");

/// zigbuildx's host program: one command per job a build step hands it.
///
/// Built for the build host through `ToolArtifact.add` and run by `Run` steps, so
/// the work behaves the same on every host and needs no shell tools. Each
/// command lives with the extension it serves; this only dispatches.
pub const Tool = struct {
    const Self = @This();

    /// A command's name and the function that runs it.
    const Command = struct {
        const Self = @This();
        /// The name a step passes first.
        name: []const u8,
        /// The command's method on the struct it serves.
        run: *const fn (process_init: std.process.Init, args: []const [:0]const u8) anyerror!void,
    };

    /// Every command, by the name a step passes first.
    const commands = [_]Command{
        .{ .name = "deps", .run = mod.Deps.command },
        .{ .name = "deps-mark", .run = mod.Deps.mark },
        .{ .name = "docs-patch", .run = mod.Docs.command },
        .{ .name = "pin", .run = mod.Deps.pin },
    };

    /// The usage line, listing `commands` so it cannot drift from them.
    const usage = usage: {
        var text: []const u8 = "usage: zigbuildx <command> [args]; commands:";
        for (Self.commands, 0..) |entry, i| text = text ++ (if (i == 0) " " else ", ") ++ entry.name;
        break :usage text;
    };

    /// Runs the command `args[0]` names.
    ///
    /// Parameters:
    /// - `process_init`: the process's allocator and IO.
    /// - `args`: the command line after the program's path.
    ///
    /// Return: nothing; `error.InvalidArguments` for an unknown or missing command, or the command's errors.
    pub fn dispatch(process_init: std.process.Init, args: []const [:0]const u8) !void {
        if (args.len > 0) {
            for (Self.commands) |entry| {
                if (std.mem.eql(u8, entry.name, args[0])) return entry.run(process_init, args);
            }
        }
        log.err("{s}", .{Self.usage});
        return error.InvalidArguments;
    }
};

/// Runs zigbuildx's host program.
///
/// Parameters:
/// - `init`: the process's allocator, IO and arguments.
///
/// Return: nothing; exits 1 on an error the command already reported, else returns the error.
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    // An empty argv has not even the program's path; there is no command to find.
    if (args.len == 0) {
        log.err("{s}", .{Tool.usage});
        std.process.exit(1);
    }
    Tool.dispatch(init, args[1..]) catch |err| switch (err) {
        error.AutodocChanged, error.DepsFailed, error.InvalidArguments => std.process.exit(1),
        else => return err,
    };
}

// -----------------------------------------------------------------------------
// Unit Tests

test "every command is unique and listed in the usage line" {
    try std.testing.expectEqualStrings("usage: zigbuildx <command> [args]; commands: deps, deps-mark, docs-patch, pin", Tool.usage);
    for (Tool.commands, 0..) |entry, i| {
        for (Tool.commands[i + 1 ..]) |other| try std.testing.expect(!std.mem.eql(u8, entry.name, other.name));
    }
}
