/// Where an absent `.path` dependency comes from.
pub const Source = union(enum) {
    /// A git repository to clone (`.clone`).
    clone: []const u8,
    /// A zip to download and unpack (`.archive`).
    archive: []const u8,
};
