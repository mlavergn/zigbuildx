const std = @import("std");
const builtin = @import("builtin");

pub const is_debug = builtin.mode == .debug;

pub const ZipArchive = @import("zip_archive.zig").ZipArchive;
pub const Deps = @import("deps.zig").Deps;
pub const Git = @import("git.zig").Git;
pub const WorktreeHead = @import("git.zig").WorktreeHead;
pub const Xcode = @import("xcode.zig").Xcode;
pub const Swift = @import("swift.zig").Swift;
pub const Android = @import("android.zig").Android;
pub const AndroidAbi = @import("android.zig").AndroidAbi;
pub const Docs = @import("docs.zig").Docs;
pub const HostTool = @import("host_tool.zig").HostTool;
pub const Tool = @import("tool.zig").Tool;
pub const pkg = @import("pkg/module.zig");

test {
    std.testing.refAllDecls(@This());
}
