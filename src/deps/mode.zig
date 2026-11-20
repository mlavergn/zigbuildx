/// How `Deps` treats sibling checkouts.
pub const Mode = enum {
    /// The developer's checkouts: fast-forwarded when clean, otherwise left alone.
    develop,
    /// A distribution build: each sibling is built at the ref its manifest declares, or the build fails.
    dist,
};
