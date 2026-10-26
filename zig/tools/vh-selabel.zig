//! vh-selabel: the SELinux labels of the system's files, from the file_contexts of the policy
//! (selinux/, docs/uni/selinux.md), without libselinux: a walk that sets the security.selinux
//! attribute where it differs from what the table says. Used by the installer in the chroot,
//! by stage 1 for the tmpfs mounts (/run, /dev, /tmp) after it mounts them, by vh-update after
//! the packages changed, and by hand.
//!
//!   vh-selabel [options] PATH...        label the trees (default: /)
//!       --check            report what differs, change nothing (exit 1 when something does)
//!       --root DIR         the system's root is DIR (the installer's chroot, the tests): the
//!                          table's paths are relative to it
//!       --contexts FILE    the table (default /etc/vh/selinux/file_contexts)
//!       --one-fs           do not cross into other file systems (the default for /)
//!       -v                 every change
//! Pseudo and foreign file systems (proc, sysfs, cgroup2, bpf, securityfs, selinuxfs, efivarfs,
//! devpts, vfat, debugfs, tracefs, pstore, binfmt_misc, mqueue, hugetlbfs) are skipped, their
//! mount point included (its inode is the other file system's root and takes no xattr: the
//! installer's chroot, kvm-smoke run 40333027036): their labels come from the policy's genfscon
//! and fsuse statements. A named path on such a file system is skipped the same way.
const std = @import("std");
const linux = std.os.linux;
const mem = std.mem;
const vh = @import("vh");
const selabel = @import("selabel");

pub const default_contexts = "/etc/vh/selinux/file_contexts";
const xattr = "security.selinux";

const Statfs = extern struct {
    f_type: i64,
    f_bsize: i64,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_fsid: [2]i32,
    f_namelen: i64,
    f_frsize: i64,
    f_flags: i64,
    f_spare: [4]i64,
};

/// file systems whose labels are the kernel's (genfscon, fsuse task) or that have no xattrs
const skipped_fs = [_]i64{
    0x9fa0, // proc
    0x62656572, // sysfs
    0x63677270, // cgroup2
    0x27e0eb, // cgroup
    0xcafe4a11, // bpf
    0x73636673, // securityfs
    0xf97cff8c, // selinuxfs
    0xde5e81e4, // efivarfs
    0x1cd1, // devpts
    0x4d44, // msdos/vfat
    0x64626720, // debugfs
    0x74726163, // tracefs
    0x6165676c, // pstore
    0x42494e4d, // binfmt_misc
    0x19800202, // mqueue
    0x958458f6, // hugetlbfs
    0x9123683e, // btrfs? no: kept (xattr); listed for the record only when it is not: see fsType
    0x454d444d, // (unused)
};

fn fsType(path: []const u8) ?i64 {
    var st: Statfs = undefined;
    const rc = linux.syscall2(.statfs, @intFromPtr(vh.z(path).ptr), @intFromPtr(&st));
    if (linux.errno(rc) != .SUCCESS) return null;
    return st.f_type;
}

fn skipFs(t: i64) bool {
    if (t == 0x9123683e or t == 0x454d444d) return false;
    for (skipped_fs) |x| if (x == t) return true;
    return false;
}

const Opts = struct {
    check: bool = false,
    root: []const u8 = "",
    verbose: bool = false,
    one_fs: bool = true,
};

const Counts = struct { seen: usize = 0, changed: usize = 0, unlabeled: usize = 0, errors: usize = 0, skipped_fs: usize = 0 };

fn currentLabel(path: []const u8, buf: []u8) ?[]const u8 {
    const rc = linux.lgetxattr(vh.z(path).ptr, xattr, buf.ptr, buf.len);
    if (linux.errno(rc) != .SUCCESS) return null;
    var v = buf[0..rc];
    if (v.len > 0 and v[v.len - 1] == 0) v = v[0 .. v.len - 1];
    return v;
}

/// one path: compare and set
fn label(t: *const selabel.Table, o: Opts, real: []const u8, logical: []const u8, mode: u32, c: *Counts) void {
    c.seen += 1;
    const want = t.lookup(logical, selabel.kindOf(mode)) orelse {
        c.unlabeled += 1;
        if (o.verbose) vh.out("no line for {s}\n", .{logical});
        return;
    };
    var buf: [256]u8 = undefined;
    const have = currentLabel(real, &buf);
    if (have != null and vh.eql(have.?, want)) return;
    c.changed += 1;
    if (o.check or o.verbose) vh.out("{s}: {s} -> {s}\n", .{ logical, have orelse "(none)", want });
    if (o.check) return;
    const z = vh.z(want);
    const rc = linux.lsetxattr(vh.z(real).ptr, xattr, z.ptr, z.len + 1, 0);
    if (linux.errno(rc) != .SUCCESS) {
        c.errors += 1;
        vh.errno = linux.errno(rc);
        vh.warn("{s}: setxattr: {s}", .{ logical, vh.serr() });
    }
}

fn walk(t: *const selabel.Table, o: Opts, real: []const u8, logical: []const u8, dev_major: u32, dev_minor: u32, c: *Counts) void {
    const st = vh.stat(real, false) catch {
        c.errors += 1;
        vh.warn("{s}: stat: {s}", .{ logical, vh.serr() });
        return;
    };
    if (!vh.S.isDir(st.mode)) {
        label(t, o, real, logical, st.mode, c);
        return;
    }
    // another file system below: skipped with its mount point when it is a pseudo one (or
    // any, with --one-fs); its root inode is the other file system's and takes no xattr
    if (st.dev_major != dev_major or st.dev_minor != dev_minor) {
        if (o.one_fs) {
            c.skipped_fs += 1;
            return;
        }
        if (fsType(real)) |ft| if (skipFs(ft)) {
            c.skipped_fs += 1;
            return;
        };
        label(t, o, real, logical, st.mode, c);
        walkDir(t, o, real, logical, st.dev_major, st.dev_minor, c);
        return;
    }
    label(t, o, real, logical, st.mode, c);
    walkDir(t, o, real, logical, dev_major, dev_minor, c);
}

fn walkDir(t: *const selabel.Table, o: Opts, real: []const u8, logical: []const u8, dev_major: u32, dev_minor: u32, c: *Counts) void {
    const names = vh.listDir(real) catch {
        c.errors += 1;
        vh.warn("{s}: readdir: {s}", .{ logical, vh.serr() });
        return;
    };
    for (names) |n| {
        const r = if (vh.eql(real, "/")) vh.fmt("/{s}", .{n}) else vh.fmt("{s}/{s}", .{ real, n });
        const l = if (vh.eql(logical, "/")) vh.fmt("/{s}", .{n}) else vh.fmt("{s}/{s}", .{ logical, n });
        walk(t, o, r, l, dev_major, dev_minor, c);
    }
}

fn usage() noreturn {
    vh.outs("vh-selabel [--check] [--root DIR] [--contexts FILE] [--one-fs|--all-fs] [-v] PATH...\n");
    vh.exit(2);
}

pub fn main(init: std.process.Init.Minimal) void {
    const args = vh.init(init, "vh-selabel");
    var o: Opts = .{};
    var contexts: []const u8 = default_contexts;
    var paths: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    var one_fs_set = false;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (vh.eql(a, "--check")) {
            o.check = true;
        } else if (vh.eql(a, "--root")) {
            i += 1;
            if (i >= args.len) usage();
            o.root = mem.trimEnd(u8, args[i], "/");
        } else if (vh.eql(a, "--contexts")) {
            i += 1;
            if (i >= args.len) usage();
            contexts = args[i];
        } else if (vh.eql(a, "--one-fs")) {
            o.one_fs = true;
            one_fs_set = true;
        } else if (vh.eql(a, "--all-fs")) {
            o.one_fs = false;
            one_fs_set = true;
        } else if (vh.eql(a, "-v")) {
            o.verbose = true;
        } else if (a.len > 0 and a[0] == '-') {
            usage();
        } else paths.append(vh.gpa, a) catch vh.oom();
    }
    if (paths.items.len == 0) paths.append(vh.gpa, "/") catch vh.oom();
    if (!one_fs_set) {
        // the whole root by default crosses into the tmpfs mounts and skips the pseudo file
        // systems; a named subtree stays on its own file system
        o.one_fs = !(paths.items.len == 1 and vh.eql(paths.items[0], "/"));
    }
    const cpath = if (vh.eql(contexts, default_contexts) and o.root.len > 0) vh.fmt("{s}{s}", .{ o.root, contexts }) else contexts;
    const text = vh.readFile(cpath) catch vh.die("{s}: {s}", .{ cpath, vh.serr() });
    const table = selabel.Table.parse(text) catch |e| vh.die("{s}: {s}", .{ cpath, @errorName(e) });
    var c: Counts = .{};
    for (paths.items) |p| {
        const logical = if (p.len > 1) mem.trimEnd(u8, p, "/") else p;
        const real = if (o.root.len == 0) logical else if (vh.eql(logical, "/")) o.root else vh.fmt("{s}{s}", .{ o.root, logical });
        const st = vh.stat(real, false) catch vh.die("{s}: {s}", .{ real, vh.serr() });
        if (!vh.S.isDir(st.mode)) {
            label(&table, o, real, logical, st.mode, &c);
            continue;
        }
        // a named directory on a pseudo file system (/dev/pts, /proc): the kernel's labels
        if (fsType(real)) |ft| if (skipFs(ft)) {
            c.skipped_fs += 1;
            if (o.verbose) vh.out("{s}: a file system whose labels are the kernel's, skipped\n", .{logical});
            continue;
        };
        label(&table, o, real, logical, st.mode, &c);
        walkDir(&table, o, real, logical, st.dev_major, st.dev_minor, &c);
    }
    vh.out("{d} files, {d} {s}, {d} without a line, {d} other file systems skipped, {d} errors ({d} contexts from {s})\n", .{ c.seen, c.changed, if (o.check) "differ" else "relabelled", c.unlabeled, c.skipped_fs, c.errors, table.specs.len, cpath });
    vh.flush();
    vh.exit(if (c.errors > 0 or (o.check and c.changed > 0)) 1 else 0);
}

test {
    _ = selabel;
}
