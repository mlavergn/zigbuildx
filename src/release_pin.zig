const std = @import("std");

/// A release tag and the commit it names.
const Release = struct {
    const Self = @This();
    /// The tag, `v` and a semantic version.
    tag: []const u8,
    /// The commit it names; for an annotated tag, the commit, not the tag object.
    commit: []const u8,
    /// The tag's version.
    version: std.SemanticVersion,
};

/// Reads the `git+` URLs `zig fetch` writes and `git ls-remote` listings, for `Deps.pin`.
pub const ReleasePin = struct {
    const Self = @This();
    /// A SHA-1 commit's length in hex digits.
    const sha1_hex_len = 40;
    /// A SHA-256 commit's length in hex digits.
    const sha256_hex_len = 64;

    /// Returns the repository a `git+` dependency URL names, without its scheme prefix, ref or commit.
    ///
    /// - `url`: A `.url`, such as `git+https://host/x?ref=v1.0.0#<sha>` or `git+https://host/x#main`.
    /// - Returns: `https://host/x`, or null when `url` is not a `git+` URL.
    pub fn repository(url: []const u8) ?[]const u8 {
        const prefix = "git+";
        if (!std.mem.startsWith(u8, url, prefix)) return null;
        const rest = url[prefix.len..];
        return rest[0 .. std.mem.findAny(u8, rest, "?#") orelse rest.len];
    }

    /// Returns what a `git+` dependency URL is pinned to: its `?ref=`, else what follows `#`.
    ///
    /// - `url`: A `.url`.
    /// - Returns: The tag or branch (`v1.0.0`, `main`), a commit, or "" when it names none.
    pub fn ref(url: []const u8) []const u8 {
        const query = "?ref=";
        if (std.mem.find(u8, url, query)) |start| {
            const rest = url[start + query.len ..];
            return rest[0 .. std.mem.findScalar(u8, rest, '#') orelse rest.len];
        }
        const hash = std.mem.findScalar(u8, url, '#') orelse return "";
        return url[hash + 1 ..];
    }

    /// Returns the commit a `?ref=<ref>#<commit>` URL pins, as `zig fetch --save` writes it.
    ///
    /// - `url`: A `.url`.
    /// - Returns: The commit, or "" when `url` names none (`#<ref>` alone, as `zig fetch --save-exact` keeps it).
    pub fn commit(url: []const u8) []const u8 {
        if (std.mem.find(u8, url, "?ref=") == null) return "";
        const hash = std.mem.findScalar(u8, url, '#') orelse return "";
        return url[hash + 1 ..];
    }

    /// Reports whether a ref is a branch to follow: neither a release tag nor a commit.
    ///
    /// - `pinned`: A ref from a `.url`; "" is the default branch.
    /// - Returns: `true` for a branch.
    pub fn isBranch(pinned: []const u8) bool {
        return Self.releaseVersion(pinned) == null and !Self.isCommit(pinned);
    }

    /// Reads the version of a release tag: `v` and a semantic version, with no pre-release or build part.
    ///
    /// - `tag`: A tag or ref, such as `v3.6.0`, `v5.0.0-rc1` or `main`.
    /// - Returns: The version, or null when `tag` is not a release tag.
    pub fn releaseVersion(tag: []const u8) ?std.SemanticVersion {
        if (!std.mem.startsWith(u8, tag, "v")) return null;
        const version = std.SemanticVersion.parse(tag[1..]) catch return null;
        if (version.pre != null or version.build != null) return null;
        return version;
    }

    /// Returns the newest release tag in a `git ls-remote --tags` listing, with the commit it names.
    ///
    /// - `listing`: `<sha>\trefs/tags/<tag>` lines, and `<commit>\trefs/tags/<tag>^{}` for annotated tags.
    /// - Returns: The release, borrowed from `listing`, or null when there is no release tag.
    pub fn newestRelease(listing: []const u8) ?Release {
        var newest: ?Release = null;
        var lines = std.mem.tokenizeScalar(u8, listing, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            const marker = "\trefs/tags/";
            const start = std.mem.find(u8, line, marker) orelse continue;
            const sha = line[0..start];
            const name = line[start + marker.len ..];
            const peeled = std.mem.endsWith(u8, name, "^{}");
            const tag = if (peeled) name[0 .. name.len - "^{}".len] else name;
            const version = Self.releaseVersion(tag) orelse continue;
            if (newest) |best| {
                // The peeled line follows its tag's own: it replaces the tag object with the commit.
                if (std.mem.eql(u8, best.tag, tag)) {
                    if (peeled) newest.?.commit = sha;
                    continue;
                }
                if (version.order(best.version) != .gt) continue;
            }
            newest = .{ .tag = tag, .commit = sha, .version = version };
        }
        return newest;
    }

    /// Reports whether a ref is a full commit hash rather than a tag or branch.
    ///
    /// - `pinned`: A ref from a `.url`.
    /// - Returns: `true` for 40 or 64 hex digits.
    fn isCommit(pinned: []const u8) bool {
        if (pinned.len != Self.sha1_hex_len and pinned.len != Self.sha256_hex_len) return false;
        for (pinned) |c| if (!std.ascii.isHex(c)) return false;
        return true;
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test "ReleasePin reads a git+ URL's repository and ref" {
    try std.testing.expectEqualStrings("https://github.com/x/zigbuildx", ReleasePin.repository("git+https://github.com/x/zigbuildx?ref=v3.6.0#fba04ba852fc06317207bdc7119b58dc13638ac0").?);
    try std.testing.expectEqualStrings("https://github.com/x/zigbuildx", ReleasePin.repository("git+https://github.com/x/zigbuildx#main").?);
    try std.testing.expectEqual(null, ReleasePin.repository("https://example.com/zigbuildx.tar.gz"));
    try std.testing.expectEqualStrings("v3.6.0", ReleasePin.ref("git+https://github.com/x/zigbuildx?ref=v3.6.0#fba04ba852fc06317207bdc7119b58dc13638ac0"));
    try std.testing.expectEqualStrings("main", ReleasePin.ref("git+https://github.com/x/zigbuildx#main"));
    try std.testing.expectEqualStrings("", ReleasePin.ref("git+https://github.com/x/zigbuildx"));
}

test "ReleasePin takes an annotated tag's commit from its peeled line" {
    const listing =
        "1111111111111111111111111111111111111111\trefs/tags/v4.1.0\n" ++
        "2222222222222222222222222222222222222222\trefs/tags/v4.1.0^{}\n" ++
        "3333333333333333333333333333333333333333\trefs/tags/v4.0.0\n" ++
        "4444444444444444444444444444444444444444\trefs/tags/v4.0.0^{}\n";
    const newest = ReleasePin.newestRelease(listing).?;
    try std.testing.expectEqualStrings("v4.1.0", newest.tag);
    // The commit, not the tag object: a `?ref=v4.1.0#<commit>` URL names the commit.
    try std.testing.expectEqualStrings("2222222222222222222222222222222222222222", newest.commit);
}

test "ReleasePin reads the pinned commit and tells a branch from a tag or a commit" {
    try std.testing.expectEqualStrings("fba04ba852fc06317207bdc7119b58dc13638ac0", ReleasePin.commit("git+https://github.com/x/zigbuildx?ref=v3.6.0#fba04ba852fc06317207bdc7119b58dc13638ac0"));
    // `--save-exact` keeps `#<ref>`, which names no commit.
    try std.testing.expectEqualStrings("", ReleasePin.commit("git+https://github.com/x/zigbuildx#main"));
    try std.testing.expect(ReleasePin.isBranch("main"));
    try std.testing.expect(ReleasePin.isBranch(""));
    try std.testing.expect(!ReleasePin.isBranch("v4.1.0"));
    try std.testing.expect(!ReleasePin.isBranch("fba04ba852fc06317207bdc7119b58dc13638ac0"));
    try std.testing.expect(ReleasePin.isCommit("fba04ba852fc06317207bdc7119b58dc13638ac0"));
    try std.testing.expect(!ReleasePin.isCommit("fba04ba"));
}

test "ReleasePin picks the newest release tag by version, not by listing order" {
    const listing =
        "cc0f3e78820c1f628de09fd3cddb83d795a25542\trefs/tags/v1.0.0\n" ++
        "7075087e013cd2313cfa7ce1b603a8d2388632d5\trefs/tags/v3.10.0\n" ++
        "fba04ba852fc06317207bdc7119b58dc13638ac0\trefs/tags/v3.6.0\r\n" ++
        "4618f3da19ff5b7b259ad67b0c4ee22d5a1892ab\trefs/tags/v9.0.0-rc1\n" ++
        "6b20787689b19cad79ef2f1b2520b28dadf34299\trefs/tags/nightly\n";
    const newest = ReleasePin.newestRelease(listing).?;
    try std.testing.expectEqualStrings("v3.10.0", newest.tag);
    try std.testing.expectEqualStrings("7075087e013cd2313cfa7ce1b603a8d2388632d5", newest.commit);
    try std.testing.expectEqual(null, ReleasePin.newestRelease("6b20787689b19cad79ef2f1b2520b28dadf34299\trefs/tags/nightly\n"));
    try std.testing.expectEqual(null, ReleasePin.newestRelease(""));
    try std.testing.expectEqual(std.SemanticVersion{ .major = 4, .minor = 1, .patch = 0 }, ReleasePin.releaseVersion("v4.1.0").?);
    try std.testing.expectEqual(null, ReleasePin.releaseVersion("main"));
    try std.testing.expectEqual(null, ReleasePin.releaseVersion("4.1.0"));
}
