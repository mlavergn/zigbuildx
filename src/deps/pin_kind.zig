/// What a worktree dependency is pinned to.
pub const PinKind = enum {
    /// A commit; the worktree is detached there.
    sha,
    /// A tag; the worktree is detached at its commit.
    tag,
    /// A branch; the worktree is on `<consumer>/<branch>`.
    branch,
};
