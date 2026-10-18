//! vh-stage1: the mounts of stage 1. runit-void's 00-pseudofs.sh, 03-filesystems.sh and
//! 04-swap.sh natively (fstab parsed here, the mount(2) flags of mount(8)), plus the
//! vh remounts of 04-vh-mounts.sh (hidepid, nosuid/nodev/noexec on /proc, /dev/shm, /run, /dev).
const std = @import("std");
const linux = std.os.linux;
const mem = std.mem;
const vh = @import("vh");
const sys = @import("sys.zig");
const MS = sys.MS;

// ---------------------------------------------------------------- 00-pseudofs.sh

/// mount what is not mounted yet: proc, sysfs, /run, /dev, devpts, /dev/shm, securityfs,
/// efivarfs, cgroup2 (unified), bpffs (new: for vh-sched)
pub fn pseudofs(container: bool, cgroup_mode: []const u8) void {
    sys.msg("Mounting pseudo-filesystems...", .{});
    mountIf("/proc", "proc", "proc", MS.NOSUID | MS.NOEXEC | MS.NODEV, null);
    mountIf("/sys", "sys", "sysfs", MS.NOSUID | MS.NOEXEC | MS.NODEV, null);
    mountIf("/run", "run", "tmpfs", MS.NOSUID | MS.NODEV, "mode=0755");
    mountIf("/dev", "dev", "devtmpfs", MS.NOSUID, "mode=0755");
    for ([_][]const u8{ "/run/runit", "/run/lvm", "/run/user", "/run/lock", "/run/log", "/dev/pts", "/dev/shm" }) |d|
        vh.mkdirs(sys.p(d), 0o755);
    mountIf("/dev/pts", "devpts", "devpts", MS.NOSUID | MS.NOEXEC, "mode=0620,gid=5");
    mountIf("/dev/shm", "shm", "tmpfs", MS.NOSUID | MS.NODEV, "mode=1777");
    mountIf("/sys/kernel/security", "securityfs", "securityfs", 0, null);
    if (vh.isDir(sys.p("/sys/firmware/efi/efivars")))
        mountIf("/sys/firmware/efi/efivars", "efivarfs", "efivarfs", MS.NOSUID | MS.NOEXEC | MS.NODEV, null);
    if (!mem.eql(u8, cgroup_mode, "unified") and cgroup_mode.len > 0)
        sys.warn("CGROUP_MODE={s}: vh-stage1 mounts cgroup2 only (unified)", .{cgroup_mode});
    vh.mkdirs(sys.p("/sys/fs/cgroup"), 0o755);
    if (container) {
        // as runit-void: try, never fail
        if (!sys.isMountpoint(sys.p("/sys/fs/cgroup")))
            sys.mount("cgroup2", sys.p("/sys/fs/cgroup"), "cgroup2", 0, "nsdelegate") catch {};
    } else mountIf("/sys/fs/cgroup", "cgroup2", "cgroup2", 0, "nsdelegate");
    // not in runit-void: the BPF file system for the pinned links of vh-sched (docs/ROADMAP.md, S)
    if (vh.isDir(sys.p("/sys/fs/bpf")))
        mountIf("/sys/fs/bpf", "bpf", "bpf", MS.NOSUID | MS.NODEV | MS.NOEXEC, "mode=0700");
}

fn mountIf(target: []const u8, src: []const u8, fstype: []const u8, flags: u32, data: ?[]const u8) void {
    const t = sys.p(target);
    if (sys.isMountpoint(t)) {
        sys.detail("{s}: already mounted", .{target});
        return;
    }
    sys.mount(src, t, fstype, flags, data) catch {
        sys.fail("mount {s} ({s}): {s}", .{ target, fstype, vh.serr() });
        return;
    };
    sys.detail("mounted {s} ({s})", .{ target, fstype });
}

// ---------------------------------------------------------------- fstab

pub const Entry = struct {
    spec: []const u8,
    file: []const u8,
    vfstype: []const u8,
    opts: []const u8,
    freq: u32 = 0,
    passno: u32 = 0,
};

/// the entries of an fstab text (comments and blank lines dropped, \040 decoded)
pub fn parseFstab(text: []const u8) []const Entry {
    var list: std.ArrayList(Entry) = .empty;
    var lines = mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = vh.strip(raw);
        if (line.len == 0 or line[0] == '#') continue;
        var f = mem.tokenizeAny(u8, line, " \t");
        const spec = f.next() orelse continue;
        const file = f.next() orelse continue;
        const vfstype = f.next() orelse continue;
        const opts = f.next() orelse "defaults";
        const freq = if (f.next()) |x| std.fmt.parseInt(u32, x, 10) catch 0 else 0;
        const passno = if (f.next()) |x| std.fmt.parseInt(u32, x, 10) catch 0 else 0;
        list.append(vh.gpa, .{
            .spec = sys.MountInfo.unescape(spec),
            .file = sys.MountInfo.unescape(file),
            .vfstype = vfstype,
            .opts = opts,
            .freq = freq,
            .passno = passno,
        }) catch vh.oom();
    }
    return list.items;
}

pub fn readFstab() []const Entry {
    const text = vh.readFile(sys.p("/etc/fstab")) catch return &.{};
    return parseFstab(text);
}

/// the mount(2) flags and the file-system data string of an fstab option list, as
/// mount(8) translates them (the "no" forms clear; user/users/owner/group imply nosuid,nodev,noexec)
pub const Opts = struct {
    flags: u32 = 0,
    data: []const u8 = "",
    noauto: bool = false,
    netdev: bool = false,
    nofail: bool = false,
    bind: bool = false,
    rbind: bool = false,
    swap_prio: ?u32 = null,
    discard: bool = false,
};

pub fn parseOpts(opts: []const u8) Opts {
    var o: Opts = .{};
    var data: std.ArrayList(u8) = .empty;
    var it = mem.splitScalar(u8, opts, ',');
    while (it.next()) |raw| {
        const w = vh.strip(raw);
        if (w.len == 0) continue;
        if (flagOf(w)) |f| {
            if (f.set) o.flags |= f.bits else o.flags &= ~f.bits;
            continue;
        }
        if (vh.eql(w, "defaults") or vh.eql(w, "auto") or vh.eql(w, "nouser") or vh.eql(w, "loud") or
            vh.eql(w, "async") or vh.eql(w, "atime") or vh.eql(w, "diratime") or vh.eql(w, "nomand") or
            vh.eql(w, "norelatime") or vh.eql(w, "nostrictatime") or vh.eql(w, "nolazytime") or vh.eql(w, "noiversion") or vh.eql(w, "nosymfollow-off"))
        {
            continue;
        }
        if (vh.eql(w, "noauto")) {
            o.noauto = true;
        } else if (vh.eql(w, "_netdev")) {
            o.netdev = true;
        } else if (vh.eql(w, "nofail")) {
            o.nofail = true;
        } else if (vh.eql(w, "bind")) {
            o.bind = true;
            o.flags |= MS.BIND;
        } else if (vh.eql(w, "rbind")) {
            o.bind = true;
            o.rbind = true;
            o.flags |= MS.BIND | MS.REC;
        } else if (vh.eql(w, "user") or vh.eql(w, "users") or vh.eql(w, "owner") or vh.eql(w, "group")) {
            o.flags |= MS.NOSUID | MS.NODEV | MS.NOEXEC;
        } else if (vh.startsWith(w, "x-") or vh.startsWith(w, "comment=")) {
            continue;
        } else if (vh.startsWith(w, "pri=")) {
            o.swap_prio = std.fmt.parseInt(u32, w[4..], 10) catch null;
        } else if (vh.eql(w, "discard") or vh.startsWith(w, "discard=")) {
            o.discard = true;
            // discard is also a file-system option (xfs, ext4): it stays in the data string
            if (data.items.len > 0) data.append(vh.gpa, ',') catch vh.oom();
            data.appendSlice(vh.gpa, w) catch vh.oom();
        } else {
            if (data.items.len > 0) data.append(vh.gpa, ',') catch vh.oom();
            data.appendSlice(vh.gpa, w) catch vh.oom();
        }
    }
    o.data = data.items;
    return o;
}

const Flag = struct { bits: u32, set: bool };

fn flagOf(w: []const u8) ?Flag {
    const table = [_]struct { name: []const u8, bits: u32, set: bool }{
        .{ .name = "ro", .bits = MS.RDONLY, .set = true },
        .{ .name = "rw", .bits = MS.RDONLY, .set = false },
        .{ .name = "nosuid", .bits = MS.NOSUID, .set = true },
        .{ .name = "suid", .bits = MS.NOSUID, .set = false },
        .{ .name = "nodev", .bits = MS.NODEV, .set = true },
        .{ .name = "dev", .bits = MS.NODEV, .set = false },
        .{ .name = "noexec", .bits = MS.NOEXEC, .set = true },
        .{ .name = "exec", .bits = MS.NOEXEC, .set = false },
        .{ .name = "sync", .bits = MS.SYNCHRONOUS, .set = true },
        .{ .name = "dirsync", .bits = MS.DIRSYNC, .set = true },
        .{ .name = "mand", .bits = MS.MANDLOCK, .set = true },
        .{ .name = "noatime", .bits = MS.NOATIME, .set = true },
        .{ .name = "nodiratime", .bits = MS.NODIRATIME, .set = true },
        .{ .name = "relatime", .bits = MS.RELATIME, .set = true },
        .{ .name = "strictatime", .bits = MS.STRICTATIME, .set = true },
        .{ .name = "lazytime", .bits = MS.LAZYTIME, .set = true },
        .{ .name = "silent", .bits = MS.SILENT, .set = true },
        .{ .name = "iversion", .bits = MS.I_VERSION, .set = true },
        .{ .name = "nosymfollow", .bits = sys.MS_NOSYMFOLLOW, .set = true },
        .{ .name = "symfollow", .bits = sys.MS_NOSYMFOLLOW, .set = false },
        .{ .name = "remount", .bits = MS.REMOUNT, .set = true },
    };
    for (table) |t| if (vh.eql(t.name, w)) return .{ .bits = t.bits, .set = t.set };
    return null;
}

/// UUID=, LABEL=, PARTUUID=, PARTLABEL= through the udev links in /dev/disk
pub fn resolveSpec(spec: []const u8) []const u8 {
    const forms = [_]struct { tag: []const u8, dir: []const u8 }{
        .{ .tag = "UUID=", .dir = "/dev/disk/by-uuid/" },
        .{ .tag = "LABEL=", .dir = "/dev/disk/by-label/" },
        .{ .tag = "PARTUUID=", .dir = "/dev/disk/by-partuuid/" },
        .{ .tag = "PARTLABEL=", .dir = "/dev/disk/by-partlabel/" },
    };
    for (forms) |f| if (vh.startsWith(spec, f.tag)) return vh.fmt("{s}{s}", .{ f.dir, spec[f.tag.len..] });
    return spec;
}

/// mount -a skips these types (runit-void: -t nosysfs,nonfs,nonfs4,nosmbfs,nocifs)
fn skippedType(t: []const u8) bool {
    for ([_][]const u8{ "sysfs", "nfs", "nfs4", "smbfs", "cifs", "swap" }) |x| if (vh.eql(t, x)) return true;
    return false;
}

// ---------------------------------------------------------------- 03-filesystems.sh

/// remount / read-write with the options of its fstab line. runit-void first remounts
/// read-only and runs fsck -A; that happens here only when an fstab line has a pass number
/// (none in this system: XFS checks itself at mount). dmraid, mdadm, btrfs, LVM, crypttab
/// and ZFS are not handled: they are not part of this system (the root is opened by dracut).
pub fn remountRoot() void {
    if (sys.root.len > 0) {
        sys.note("remount-root: skipped under --root", .{});
        return;
    }
    const entries = readFstab();
    for ([_][]const u8{ "dmraid", "mdadm", "btrfs", "vgchange", "zpool" }) |prog|
        if (sys.inPath(prog)) sys.warn("{s} is installed but vh-stage1 does not run it (runit-void's 03-filesystems.sh does): vh-stage1 --rollback if it is needed at boot", .{prog});
    if (vh.pathExists(sys.p("/etc/crypttab")))
        sys.warn("/etc/crypttab exists but vh-stage1 does not activate it (dracut opens the root volume)", .{});

    var root_opts: Opts = .{};
    var needs_fsck = false;
    for (entries) |e| {
        if (vh.eql(e.file, "/")) root_opts = parseOpts(e.opts);
        if (e.passno > 0 and !vh.eql(e.vfstype, "swap")) needs_fsck = true;
    }
    if (needs_fsck and !fastboot()) {
        sys.msg("Remounting rootfs read-only...", .{});
        sys.mount(null, "/", null, MS.REMOUNT | MS.RDONLY | (root_opts.flags & ~@as(u32, MS.RDONLY)), root_opts.data) catch {
            sys.fail("remount / ro: {s}", .{vh.serr()});
            sys.emergency();
        };
        sys.msg("Checking filesystems:", .{});
        var argv: std.ArrayList([]const u8) = .empty;
        argv.appendSlice(vh.gpa, &.{ "fsck", "-A", "-T", "-a", "-t", "noopts=_netdev" }) catch vh.oom();
        if (vh.pathExists(sys.p("/forcefsck")) or cmdlineHas("forcefsck")) argv.append(vh.gpa, "-f") catch vh.oom();
        const rc = sys.exec(argv.items);
        if (rc > 1) {
            sys.fail("fsck returned {d}", .{rc});
            sys.emergency();
        }
    }
    sys.msg("Mounting rootfs read-write...", .{});
    sys.mount(null, "/", null, MS.REMOUNT | (root_opts.flags & ~@as(u32, MS.RDONLY)), root_opts.data) catch {
        sys.fail("remount / rw: {s}", .{vh.serr()});
        sys.emergency();
    };
}

fn fastboot() bool {
    return vh.pathExists(sys.p("/fastboot")) or cmdlineHas("fastboot");
}

fn cmdlineHas(word: []const u8) bool {
    const text = vh.rd("/proc/cmdline");
    var it = mem.tokenizeAny(u8, text, " \t\n");
    while (it.next()) |w| if (vh.eql(w, word)) return true;
    return false;
}

/// mount -a -O no_netdev: every fstab line that is not noauto, not _netdev, not of a
/// network type and not mounted yet. A bind with options is two calls, like mount(8):
/// bind first, then remount,bind with the flags. Failures of lines without nofail lead
/// to the emergency shell, as in runit-void.
pub fn mountAll() void {
    sys.msg("Mounting all non-network filesystems...", .{});
    const info = sys.MountInfo.load();
    const entries = readFstab();
    var failed: usize = 0;
    for (entries) |e| {
        if (vh.eql(e.file, "/") or skippedType(e.vfstype)) continue;
        const o = parseOpts(e.opts);
        if (o.noauto or o.netdev) continue;
        const target = sys.p(e.file);
        if (o.bind) {
            const source = sys.p(e.spec);
            if (info.isBound(source, target)) {
                sys.detail("{s}: already mounted", .{e.file});
                continue;
            }
            if (!bindMount(source, target, o)) {
                if (o.nofail) sys.detail("{s}: not mounted (nofail)", .{e.file}) else failed += 1;
            } else sys.detail("mounted {s} on {s} (bind{s})", .{ e.spec, e.file, if (o.flags & ~@as(u32, MS.BIND | MS.REC) != 0) ", with options" else "" });
            continue;
        }
        if (info.isMounted(target)) {
            sys.detail("{s}: already mounted", .{e.file});
            continue;
        }
        const src = resolveSpec(e.spec);
        sys.mount(src, target, e.vfstype, o.flags, o.data) catch {
            if (o.nofail) {
                sys.detail("{s}: not mounted (nofail): {s}", .{ e.file, vh.serr() });
            } else {
                sys.fail("mount {s} on {s} ({s}): {s}", .{ e.spec, e.file, e.vfstype, vh.serr() });
                failed += 1;
            }
            continue;
        };
        sys.detail("mounted {s} on {s} ({s})", .{ e.spec, e.file, e.vfstype });
    }
    if (failed > 0) sys.emergency();
}

fn bindMount(source: []const u8, target: []const u8, o: Opts) bool {
    const rec: u32 = if (o.rbind) MS.REC else 0;
    sys.mount(source, target, null, MS.BIND | rec, null) catch {
        sys.fail("bind {s} on {s}: {s}", .{ source, target, vh.serr() });
        return false;
    };
    const extra = o.flags & ~@as(u32, MS.BIND | MS.REC);
    if (extra != 0) {
        sys.mount(null, target, null, MS.REMOUNT | MS.BIND | extra, null) catch {
            sys.fail("remount,bind {s}: {s}", .{ target, vh.serr() });
            return false;
        };
    }
    return true;
}

// ---------------------------------------------------------------- 04-swap.sh

/// swapon -a: the swap lines of fstab (this system has none: zram instead)
pub fn swapAll() void {
    const entries = readFstab();
    var any = false;
    for (entries) |e| if (vh.eql(e.vfstype, "swap")) {
        any = true;
        break;
    };
    if (!any) {
        sys.detail("no swap in fstab", .{});
        return;
    }
    sys.msg("Initializing swap...", .{});
    var failed: usize = 0;
    for (entries) |e| {
        if (!vh.eql(e.vfstype, "swap")) continue;
        const o = parseOpts(e.opts);
        if (o.noauto) continue;
        var flags: u32 = 0;
        if (o.swap_prio) |prio| flags |= sys.SWAP_FLAG_PREFER | (prio & sys.SWAP_FLAG_PRIO_MASK);
        if (o.discard) flags |= sys.SWAP_FLAG_DISCARD;
        const dev = resolveSpec(e.spec);
        _ = vh.sys(linux.syscall2(.swapon, @intFromPtr(vh.z(dev).ptr), flags)) catch {
            if (o.nofail) continue;
            sys.fail("swapon {s}: {s}", .{ e.spec, vh.serr() });
            failed += 1;
        };
    }
    if (failed > 0) sys.emergency();
}

// ---------------------------------------------------------------- 04-vh-mounts.sh

/// the mount options runit-void does not set: hidepid=invisible with the proc group on
/// /proc, nosuid/nodev/noexec and the size on /dev/shm, nosuid/nodev/noexec on /run,
/// nosuid/noexec on /dev
pub fn vhMounts(shm_size: []const u8) void {
    sys.msg("vh: pseudo-filesystem mount options...", .{});
    const data = if (sys.groupId("proc")) |gid| vh.fmt("hidepid=invisible,gid={d}", .{gid}) else "hidepid=invisible";
    remount("/proc", MS.NOSUID | MS.NODEV | MS.NOEXEC, data);
    remount("/dev/shm", MS.NOSUID | MS.NODEV | MS.NOEXEC, vh.fmt("size={s}", .{shm_size}));
    remount("/run", MS.NOSUID | MS.NODEV | MS.NOEXEC, null);
    remount("/dev", MS.NOSUID | MS.NOEXEC, null);
}

fn remount(target: []const u8, flags: u32, data: ?[]const u8) void {
    sys.mount(null, sys.p(target), null, MS.REMOUNT | flags, data) catch {
        sys.fail("remount {s} ({s}): {s}", .{ target, data orelse "", vh.serr() });
        return;
    };
    sys.detail("remounted {s} ({s})", .{ target, data orelse "" });
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "fstab: parsing" {
    const text =
        "# comment\n" ++
        "UUID=abc\t/\t\txfs\trw,noatime\t0 0\n" ++
        "UUID=esp\t/boot/efi\tvfat\tnoauto,nosuid,nodev,noexec,fmask=0177,dmask=0077\t0 0\n" ++
        "tmpfs\t\t/tmp\t\ttmpfs\tnosuid,nodev,noexec,mode=1777,size=25%\t0 0\n" ++
        "/home\t\t/home\t\tnone\tbind,nosuid,nodev,noexec\t0 0\n" ++
        "/mnt/a\\040b\t/mnt/c\\040d\tnone\tbind\t0 2\n" ++
        "/dev/sdb1\tnone\tswap\tpri=10,discard\t0 0\n";
    const e = parseFstab(text);
    try testing.expectEqual(@as(usize, 6), e.len);
    try testing.expectEqualStrings("/", e[0].file);
    try testing.expectEqualStrings("xfs", e[0].vfstype);
    try testing.expectEqualStrings("/mnt/a b", e[4].spec);
    try testing.expectEqualStrings("/mnt/c d", e[4].file);
    try testing.expectEqual(@as(u32, 2), e[4].passno);
}

test "fstab: options to mount flags" {
    var o = parseOpts("rw,noatime");
    try testing.expectEqual(@as(u32, MS.NOATIME), o.flags);
    try testing.expectEqualStrings("", o.data);
    o = parseOpts("noauto,nosuid,nodev,noexec,fmask=0177,dmask=0077");
    try testing.expect(o.noauto);
    try testing.expectEqual(@as(u32, MS.NOSUID | MS.NODEV | MS.NOEXEC), o.flags);
    try testing.expectEqualStrings("fmask=0177,dmask=0077", o.data);
    o = parseOpts("nosuid,nodev,noexec,mode=1777,size=25%");
    try testing.expectEqualStrings("mode=1777,size=25%", o.data);
    o = parseOpts("bind,nosuid,nodev,noexec,nosymfollow");
    try testing.expect(o.bind);
    try testing.expectEqual(@as(u32, MS.BIND | MS.NOSUID | MS.NODEV | MS.NOEXEC | sys.MS_NOSYMFOLLOW), o.flags);
    o = parseOpts("rbind,ro");
    try testing.expect(o.rbind);
    try testing.expectEqual(@as(u32, MS.BIND | MS.REC | MS.RDONLY), o.flags);
    // user implies nosuid,nodev,noexec; a later exec takes noexec away again
    o = parseOpts("user,exec");
    try testing.expectEqual(@as(u32, MS.NOSUID | MS.NODEV), o.flags);
    o = parseOpts("defaults,_netdev,nofail,x-systemd.automount,comment=x");
    try testing.expect(o.netdev and o.nofail);
    try testing.expectEqual(@as(u32, 0), o.flags);
    try testing.expectEqualStrings("", o.data);
    o = parseOpts("pri=10,discard");
    try testing.expectEqual(@as(?u32, 10), o.swap_prio);
    try testing.expect(o.discard);
    o = parseOpts("ro,remount");
    try testing.expectEqual(@as(u32, MS.RDONLY | MS.REMOUNT), o.flags);
}

test "fstab: spec forms" {
    try testing.expectEqualStrings("/dev/disk/by-uuid/1234", resolveSpec("UUID=1234"));
    try testing.expectEqualStrings("/dev/disk/by-label/ESP", resolveSpec("LABEL=ESP"));
    try testing.expectEqualStrings("/dev/disk/by-partuuid/ab-cd", resolveSpec("PARTUUID=ab-cd"));
    try testing.expectEqualStrings("/dev/nvme0n1p2", resolveSpec("/dev/nvme0n1p2"));
    try testing.expectEqualStrings("tmpfs", resolveSpec("tmpfs"));
}
