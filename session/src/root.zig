//! vh-root: the roots under /var/lib/vh/roots/NAME (track G, session/README.md).
//!
//!   doas vh-root create NAME [--profile P] [--packages "A B ..."]
//!       a root of the profile P (by default the one called NAME), with its packages and these
//!   doas vh-root install NAME PKG...      packages into the root, under its thor policy
//!   doas vh-root update NAME              thor update in the root
//!   doas vh-root remove NAME              the root and everything in it
//!   vh-root list                          the roots: profile, packages, size, thor policy
//!   vh-root profiles                      the profiles this build knows
//!
//! --prefix DIR acts on a system root in DIR, --thor PATH runs another thor (the tests).
//! Static PIE, ReleaseSafe, std.os.linux only (zig/README.md).
const std = @import("std");
const vh = @import("vh");
const profiles = @import("profiles");
const common = @import("common.zig");
const roots = @import("roots.zig");

const usage =
    \\usage: doas vh-root create NAME [--profile P] [--packages "A B ..."]
    \\       doas vh-root install NAME PKG...
    \\       doas vh-root update NAME
    \\       doas vh-root remove NAME
    \\       vh-root list
    \\       vh-root profiles
    \\
;

pub fn main(init: std.process.Init.Minimal) void {
    const all = vh.init(init, "vh-root");
    var o: roots.Opts = .{};
    var args: std.ArrayList([]const u8) = .empty;
    var profile_name: ?[]const u8 = null;
    var packages: []const u8 = "";
    var i: usize = 0;
    while (i < all.len) : (i += 1) {
        const a = all[i];
        const takes = [_][]const u8{ "--prefix", "--thor", "--profile", "--packages" };
        var took = false;
        for (takes) |opt| if (vh.eql(a, opt)) {
            if (i + 1 >= all.len) vh.die("{s} needs a value", .{opt});
            i += 1;
            const v = all[i];
            if (vh.eql(opt, "--prefix")) o.sys.prefix = v;
            if (vh.eql(opt, "--thor")) o.thor = v;
            if (vh.eql(opt, "--profile")) profile_name = v;
            if (vh.eql(opt, "--packages")) packages = v;
            took = true;
        };
        if (!took) args.append(vh.gpa, a) catch vh.oom();
    }
    const argv = args.items;
    if (argv.len == 0 or vh.eql(argv[0], "--help") or vh.eql(argv[0], "-h")) {
        vh.outs(usage);
        vh.exit(if (argv.len == 0) 2 else 0);
    }
    const cmd = argv[0];
    if (vh.eql(cmd, "list")) {
        roots.list(o);
        vh.exit(0);
    }
    if (vh.eql(cmd, "profiles")) {
        for (profiles.all) |p| vh.out("{s}\t{s}\n", .{ p.name, p.why });
        vh.exit(0);
    }
    if (argv.len < 2) {
        vh.outs(usage);
        vh.exit(2);
    }
    const name = argv[1];
    common.needRoot(vh.fmt("vh-root {s}", .{cmd}));
    if (vh.eql(cmd, "create")) {
        const p = profiles.get(profile_name orelse name) orelse vh.die("no profile {s} (vh-root profiles)", .{profile_name orelse name});
        roots.create(o, name, p, common.words(packages), null);
        vh.exit(0);
    }
    if (vh.eql(cmd, "install")) vh.exit(roots.install(o, name, argv[2..]));
    if (vh.eql(cmd, "update")) vh.exit(roots.update(o, name));
    if (vh.eql(cmd, "remove")) {
        roots.remove(o, name);
        vh.exit(0);
    }
    vh.warn("unknown command {s}", .{cmd});
    vh.outs(usage);
    vh.exit(2);
}
