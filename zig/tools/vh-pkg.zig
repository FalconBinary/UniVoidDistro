//! vh-pkg: installing and removing programs (docs/12, section "Programs").
//!
//!   doas vh-pkg add PKG... [--ignore DEPENDENCY...] [--keep PATH...] [-y]
//!   doas vh-pkg rm PKG...                -- remove together with the dependencies nobody needs any more
//!   doas vh-pkg scan PKG...              -- SUID and capabilities that came back after updates
//!
//! Neutralising packages is done by the thor policy inside libxbps (docs/18): SUID is
//! stripped before the file reaches the disk, kernel.d/dracut/profile.d hooks are not
//! extracted, sysctl.d files and 0666 udev rules are masked, the deny list is also checked on
//! updates. vh-pkg remains a wrapper with the familiar options:
//!   --ignore NAME  -- the dependency is not installed (ignorepkg in /etc/xbps.d; check that
//!                     the program works without it);
//!   --keep PATH    -- a policy exception (thor keep);
//!   after installing and removing: orphans (xbps-remove -o). xbps leaves the edited configs
//!   of removed packages in place; their paths go to /var/lib/vh/removed-conf.list, and
//!   vh-deep-clean moves them into the backup.
const std = @import("std");
const vh = @import("vh");
const mem = std.mem;

const IGNORE = "/etc/xbps.d/51-vh-pkg-ignore.conf";
const CONF_LEDGER = "/var/lib/vh/removed-conf.list";

fn pkgname(pkgver: []const u8) []const u8 {
    const d = mem.lastIndexOfScalar(u8, pkgver, '-') orelse return pkgver;
    return pkgver[0..d];
}

/// a line into a file unless it is already there; the first line of a new file is the header
fn appendUnique(path: []const u8, line: []const u8, header: []const u8) bool {
    const text = vh.readFile(path) catch "";
    var it = mem.tokenizeScalar(u8, text, '\n');
    var empty = true;
    while (it.next()) |l| {
        if (vh.eql(l, line)) return false;
        empty = false;
    }
    var b: std.ArrayList(u8) = .empty;
    if (empty) {
        b.print(vh.gpa, "{s}\n", .{header}) catch vh.oom();
    } else {
        b.appendSlice(vh.gpa, text) catch vh.oom();
        if (text[text.len - 1] != '\n') b.append(vh.gpa, '\n') catch vh.oom();
    }
    b.print(vh.gpa, "{s}\n", .{line}) catch vh.oom();
    vh.writeAtomic(path, b.items, 0o644);
    return true;
}

fn must(argv: []const []const u8) void {
    const rc = vh.run(argv);
    if (rc != 0) vh.die("{s}: exit code {d}", .{ argv[0], rc });
}

/// the configs of the packages the plan (xbps-remove -...n) removes go to the journal for vh-deep-clean
fn recordConf(plan: []const []const u8) void {
    var o: std.ArrayList(u8) = .empty;
    _ = vh.runOpts(plan, .{ .out = &o });
    var lines = mem.tokenizeScalar(u8, o.items, '\n');
    while (lines.next()) |l| {
        var f = mem.tokenizeAny(u8, l, vh.space);
        const f0 = f.next() orelse continue;
        const f1 = f.next() orelse continue;
        if (!vh.eql(f1, "remove")) continue;
        var c: std.ArrayList(u8) = .empty;
        _ = vh.runOpts(&.{ "xbps-query", "-p", "conf_files", pkgname(f0) }, .{ .out = &c });
        var files = mem.tokenizeScalar(u8, c.items, '\n');
        while (files.next()) |raw| {
            const file = vh.strip(raw);
            if (file.len == 0 or file[0] != '/') continue;
            vh.mkdirs("/var/lib/vh", 0o755);
            _ = appendUnique(CONF_LEDGER, file, "# void-hardperf-light: configs of removed packages; vh-deep-clean moves them away");
        }
    }
}

fn removeOrphans() void {
    recordConf(&.{ "xbps-remove", "-on" });
    _ = vh.run(&.{ "xbps-remove", "-oy" });
}

fn stripQuiet() void {
    var o: std.ArrayList(u8) = .empty;
    _ = vh.runOpts(&.{ "/usr/local/sbin/vh-suid-strip", "--quiet" }, .{ .out = &o, .err = &o });
}

fn usage() noreturn {
    vh.flush();
    vh.writeAllFd(2,
        \\doas vh-pkg add PKG... [--ignore DEPENDENCY...] [--keep PATH...] [-y]
        \\doas vh-pkg scan PKG...
        \\doas vh-pkg rm PKG...
        \\
    ) catch {};
    vh.exit(2);
}

pub fn main(init: std.process.Init.Minimal) void {
    const args = vh.init(init, "vh-pkg");
    // programs only from /usr/bin (vh.run looks them up in the process PATH)
    vh.setenv("PATH", "/usr/bin");
    // the admin's umask is 077 (doas does not change it): package triggers would create
    // shared caches (MIME database, icons, gdk-pixbuf loaders) that only root can read (docs/08)
    _ = std.os.linux.syscall1(.umask, 0o022);
    if (std.os.linux.geteuid() != 0) vh.die("run: doas vh-pkg ...", .{});
    if (args.len < 1) usage();
    const cmd = args[0];
    const is_add = vh.eql(cmd, "add");
    const is_scan = vh.eql(cmd, "scan");
    const is_rm = vh.eql(cmd, "rm");
    if (!is_add and !is_scan and !is_rm) usage();

    var pkgs: vh.Strv = .{};
    var ignore: vh.Strv = .{};
    var keep: vh.Strv = .{};
    var yes = false;
    var opts = true;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (opts and vh.eql(a, "--")) {
            opts = false;
        } else if (opts and is_add and vh.eql(a, "--ignore") and i + 1 < args.len) {
            i += 1;
            ignore.add(args[i]);
        } else if (opts and is_add and vh.startsWith(a, "--ignore=")) {
            ignore.add(a[9..]);
        } else if (opts and !is_rm and vh.eql(a, "--keep") and i + 1 < args.len) {
            i += 1;
            keep.add(args[i]);
        } else if (opts and !is_rm and vh.startsWith(a, "--keep=")) {
            keep.add(a[7..]);
        } else if (opts and is_add and (vh.eql(a, "-y") or vh.eql(a, "--yes"))) {
            yes = true;
        } else if (opts and a.len > 0 and a[0] == '-') {
            usage();
        } else {
            pkgs.add(a);
        }
    }
    if (pkgs.len() == 0) usage();

    if (is_scan) {
        // the file inspection is done by thor at every installation and update (docs/18);
        // here only the SUID bits and capabilities that came back around xbps
        stripQuiet();
        vh.outs("package files are inspected by thor at installation and update (log: /var/log/thor.log)\n");
        vh.flush();
        return;
    }
    if (is_rm) {
        var a: std.ArrayList([]const u8) = .empty;
        a.appendSlice(vh.gpa, &.{ "xbps-remove", "-Rn" }) catch vh.oom();
        a.appendSlice(vh.gpa, pkgs.slice()) catch vh.oom();
        recordConf(a.items);
        a.items[1] = "-Ry";
        must(a.items);
        removeOrphans();
        return;
    }

    // add
    for (keep.slice()) |k| must(&.{ "thor", "keep", k });
    for (ignore.slice()) |dep| {
        const line = vh.fmt("ignorepkg={s}", .{dep});
        if (appendUnique(IGNORE, line, "# void-hardperf-light: dependencies vh-pkg skips at the admin's request (docs/12)"))
            vh.out("{s}: the dependency will not be installed (check that the program works)\n", .{line});
    }
    var a: std.ArrayList([]const u8) = .empty;
    a.appendSlice(vh.gpa, &.{ "thor", "install" }) catch vh.oom();
    if (yes) a.append(vh.gpa, "-y") catch vh.oom();
    a.appendSlice(vh.gpa, pkgs.slice()) catch vh.oom();
    const rc = vh.run(a.items);
    if (rc != 0) vh.exit(rc);
    removeOrphans();
    stripQuiet();
    vh.outs("\nTo check the whole system: doas vh-audit\n");
    vh.flush();
}
