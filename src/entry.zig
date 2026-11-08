/// One dependency of a `build.zig.zon`, reduced to the fields `Deps` reads.
pub const Entry = struct {
    const Self = @This();
    /// The dependency's field name in `.dependencies`.
    name: []const u8,
    /// Where a fetched dependency comes from; only `Deps.pin` reads it.
    url: ?[]const u8 = null,
    /// A fetched dependency's package hash (`.hash`); only `Vendor` reads it.
    hash: ?[]const u8 = null,
    /// Where a local dependency lives (`.path`).
    path: ?[]const u8 = null,
    /// The repository to clone an absent `.path` from (`.clone`).
    clone: ?[]const u8 = null,
    /// The zip to unpack an absent `.path` from (`.archive`).
    archive: ?[]const u8 = null,
    /// The checkout a worktree is created from (`.checkout`).
    checkout: ?[]const u8 = null,
    /// The commit a worktree is pinned to (`.sha`).
    sha: ?[]const u8 = null,
    /// The tag a worktree or sibling is pinned to (`.tag`).
    tag: ?[]const u8 = null,
    /// The branch a worktree or sibling follows (`.branch`).
    branch: ?[]const u8 = null,
    /// Whether Zig fetches it only when a build asks for it (`.lazy = true`).
    lazy: bool = false,
};
