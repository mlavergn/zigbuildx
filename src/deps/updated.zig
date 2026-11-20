/// What `Sync.update` did to the worktrees that follow a branch.
pub const Updated = struct {
    const Self = @This();
    /// Worktrees fast-forwarded.
    moved: usize = 0,
    /// Worktrees skipped (uncommitted changes, commits of their own, branch
    /// gone) or whose checkout could not be fetched.
    failed: usize = 0,
};
