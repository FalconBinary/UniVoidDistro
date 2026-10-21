//! The root profiles of vh-root (session/README.md): what a root under /var/lib/vh/roots/NAME
//! is made of, and the exceptions to thor's deny list that hold inside that root only. Compiled
//! in from the *.zon files of this directory, checked against this type at build time.

pub const Profile = struct {
    name: []const u8,
    /// one line for vh-root list
    why: []const u8,
    /// the packages every root of this profile gets (thor -r ROOT install)
    packages: []const []const u8,
    /// names of thor's deny list allowed in this root (ROOT/etc/thor/allow.conf)
    allow: []const []const u8 = &.{},
    /// xbps noextract patterns of the root (ROOT/etc/xbps.d/30-vh-noextract.conf)
    noextract: []const []const u8 = &.{},
    /// the files of the system's /etc/xbps.d copied into the root: its repositories
    repositories: []const []const u8,
    /// the mode of the root's own directory
    mode: u32 = 0o700,
};

pub const all = [_]Profile{
    @import("game.zon"),
    @import("kbuild.zon"),
    @import("keys.zon"),
};

pub fn get(name: []const u8) ?Profile {
    for (all) |p| if (eql(p.name, name)) return p;
    return null;
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}
