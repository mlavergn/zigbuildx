/// How `Deps` treats sibling checkouts.
pub const Mode = enum {
    /// The developer's checkouts: fast-forwarded when clean, otherwise left alone.
    develop,
    /// A CI build: each sibling is brought to the ref its manifest declares, or the build fails.
    ci,
};
