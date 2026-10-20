//! The system calls of the gaming session that zig/lib/vh.zig has no wrapper for: mounts,
//! namespaces, capabilities, the hostname, the loopback interface. Each returns vh.Error with
//! vh.errno set, as vh.zig's do.
const std = @import("std");
const vh = @import("vh");
const linux = std.os.linux;
const mem = std.mem;

pub const MS = linux.MS;

pub fn mount(src: ?[]const u8, dst: []const u8, fstype: ?[]const u8, flags: u32, data: ?[]const u8) vh.Error!void {
    const s: ?[*:0]const u8 = if (src) |x| vh.z(x).ptr else null;
    const f: ?[*:0]const u8 = if (fstype) |x| vh.z(x).ptr else null;
    const d: usize = if (data) |x| @intFromPtr(vh.z(x).ptr) else 0;
    _ = try vh.sys(linux.mount(s, vh.z(dst).ptr, f, flags, d));
}

/// a bind mount of SRC at DST with the per-mount flags FLAGS (nosuid, nodev, noexec, rdonly):
/// MS_BIND copies the source mount's flags, the remount sets these
pub fn bind(src: []const u8, dst: []const u8, flags: u32) vh.Error!void {
    try mount(src, dst, null, MS.BIND, null);
    try mount(null, dst, null, MS.REMOUNT | MS.BIND | flags, null);
}

pub fn umount(path: []const u8, flags: u32) vh.Error!void {
    _ = try vh.sys(linux.umount2(vh.z(path).ptr, flags));
}

pub fn unshare(flags: usize) vh.Error!void {
    _ = try vh.sys(linux.unshare(flags));
}

pub fn sethostname(name: []const u8) vh.Error!void {
    _ = try vh.sys(linux.syscall2(.sethostname, @intFromPtr(name.ptr), name.len));
}

pub fn umask(mode: u32) void {
    _ = linux.syscall1(.umask, mode);
}

/// the new root: chdir there, pivot_root(".", ".") stacks the old root on top of it, and
/// unmounting "." (detached) takes the old root away (pivot_root(2), "pivot_root(".", ".")")
pub fn pivotHere(new_root: []const u8) vh.Error!void {
    _ = try vh.sys(linux.chdir(vh.z(new_root).ptr));
    _ = try vh.sys(linux.pivot_root(".", "."));
    _ = try vh.sys(linux.umount2(".", linux.MNT.DETACH));
    _ = try vh.sys(linux.chdir("/"));
}

pub fn noNewPrivs() vh.Error!void {
    _ = try vh.sys(linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0));
}

/// Every capability gone: the bounding set first (while CAP_SETPCAP is still there), then the
/// effective, permitted and inheritable sets. An execve after it gives none back: the user is
/// not root in its namespace and no file has capabilities (thor strips them).
pub fn dropCaps() vh.Error!void {
    var cap: usize = 0;
    while (cap < 64) : (cap += 1) {
        const rc = linux.prctl(@intFromEnum(linux.PR.CAPBSET_DROP), cap, 0, 0, 0);
        if (linux.errno(rc) == .INVAL) break; // past the last capability this kernel knows
        _ = try vh.sys(rc);
    }
    _ = linux.prctl(@intFromEnum(linux.PR.CAP_AMBIENT), linux.PR.CAP_AMBIENT_CLEAR_ALL, 0, 0, 0);
    var hdr: linux.cap_user_header_t = .{ .version = 0x20080522, .pid = 0 };
    const data = [2]linux.cap_user_data_t{ .{ .effective = 0, .permitted = 0, .inheritable = 0 }, .{ .effective = 0, .permitted = 0, .inheritable = 0 } };
    _ = try vh.sys(linux.capset(&hdr, &data[0]));
}

/// the loopback interface of a new network namespace up (it starts down)
pub fn loopbackUp() vh.Error!void {
    const fd: vh.fd_t = @intCast(try vh.sys(linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0)));
    defer vh.close(fd);
    var ifr = mem.zeroes(linux.ifreq);
    @memcpy(ifr.ifrn.name[0..2], "lo");
    _ = try vh.sys(linux.ioctl(fd, linux.SIOCGIFFLAGS, @intFromPtr(&ifr)));
    ifr.ifru.flags.UP = true;
    _ = try vh.sys(linux.ioctl(fd, linux.SIOCSIFFLAGS, @intFromPtr(&ifr)));
}

/// an empty file to bind a device node or a socket onto
pub fn touch(path: []const u8, mode: u32) vh.Error!void {
    const fd = try vh.openFd(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .NOFOLLOW = true }, mode);
    vh.close(fd);
}

pub fn mkdir(path: []const u8, mode: u32) vh.Error!void {
    _ = vh.sys(linux.mkdir(vh.z(path).ptr, mode)) catch |e| if (vh.errno != .EXIST) return e;
}

pub fn symlink(target: []const u8, path: []const u8) vh.Error!void {
    _ = try vh.sys(linux.symlink(vh.z(target).ptr, vh.z(path).ptr));
}

/// a whole file written at once (uid_map, gid_map, setgroups take one write)
pub fn writeOnce(path: []const u8, data: []const u8) vh.Error!void {
    const fd = try vh.openFd(path, .{ .ACCMODE = .WRONLY }, 0);
    defer vh.close(fd);
    const n = try vh.sysRetry(linux.write, .{ fd, data.ptr, data.len });
    if (n != data.len) {
        vh.errno = .IO;
        return error.Sys;
    }
}

pub fn chown(path: []const u8, uid: u32, gid: u32) vh.Error!void {
    _ = try vh.sys(linux.fchownat(linux.AT.FDCWD, vh.z(path).ptr, uid, gid, linux.AT.SYMLINK_NOFOLLOW));
}

pub fn chmod(path: []const u8, mode: u32) vh.Error!void {
    _ = try vh.sys(linux.fchmodat(linux.AT.FDCWD, vh.z(path).ptr, mode));
}

/// the processes whose real user is UID (from /proc/PID/status), this one excepted
pub fn processesOf(uid: u32) []const linux.pid_t {
    var out: std.ArrayList(linux.pid_t) = .empty;
    const self = linux.getpid();
    const names = vh.listDir("/proc") catch return out.items;
    for (names) |n| {
        const pid = std.fmt.parseInt(linux.pid_t, n, 10) catch continue;
        if (pid == self) continue;
        const status = vh.readFile(vh.fmt("/proc/{d}/status", .{pid})) catch continue;
        var it = mem.splitScalar(u8, status, '\n');
        while (it.next()) |l| {
            if (!vh.startsWith(l, "Uid:")) continue;
            var f = mem.tokenizeAny(u8, l[4..], " \t");
            const real = std.fmt.parseInt(u32, f.next() orelse break, 10) catch break;
            if (real == uid) out.append(vh.gpa, pid) catch vh.oom();
            break;
        }
    }
    return out.items;
}

/// the command line of a process, its NUL separators kept
pub fn cmdline(pid: linux.pid_t) []const u8 {
    return vh.readFile(vh.fmt("/proc/{d}/cmdline", .{pid})) catch "";
}

/// sleep for MS milliseconds
pub fn sleepMs(ms: u64) void {
    var ts: linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
    while (linux.errno(linux.nanosleep(&ts, &ts)) == .INTR) {}
}

/// struct statfs of the 64-bit Linux ABIs (asm-generic/statfs.h, the word a long)
const Statfs = extern struct {
    type: i64,
    bsize: i64,
    blocks: u64,
    bfree: u64,
    bavail: u64,
    files: u64,
    ffree: u64,
    fsid: [2]i32,
    namelen: i64,
    frsize: i64,
    flags: i64,
    spare: [4]i64,
};

/// The per-mount flags of the mount PATH is on, as mount(2) takes them (statfs's ST_* bits). A
/// remount inside a user namespace must keep every flag the mount had when it was copied in
/// (MNT_LOCK_*: read-only, nosuid, nodev, noexec and the atime mode), or it is refused.
pub fn mountFlags(path: []const u8) vh.Error!u32 {
    var st = mem.zeroes(Statfs);
    _ = try vh.sys(linux.syscall2(.statfs, @intFromPtr(vh.z(path).ptr), @intFromPtr(&st)));
    const ST = struct {
        const RDONLY = 0x1;
        const NOSUID = 0x2;
        const NODEV = 0x4;
        const NOEXEC = 0x8;
        const NOATIME = 0x400;
        const NODIRATIME = 0x800;
        const RELATIME = 0x1000;
        const NOSYMFOLLOW = 0x2000;
    };
    const f: u64 = @bitCast(st.flags);
    var m: u32 = 0;
    if (f & ST.RDONLY != 0) m |= MS.RDONLY;
    if (f & ST.NOSUID != 0) m |= MS.NOSUID;
    if (f & ST.NODEV != 0) m |= MS.NODEV;
    if (f & ST.NOEXEC != 0) m |= MS.NOEXEC;
    if (f & ST.NOATIME != 0) m |= MS.NOATIME;
    if (f & ST.NODIRATIME != 0) m |= MS.NODIRATIME;
    if (f & ST.RELATIME != 0) m |= MS.RELATIME;
    if (f & ST.NOSYMFOLLOW != 0) m |= 256; // MS_NOSYMFOLLOW
    return m;
}

/// A bind mount inside the session's namespace, with EXTRA added to the flags it came with
/// (EXTRA 0: no remount). REC binds the mounts below SRC too.
pub fn bindKeep(src: []const u8, dst: []const u8, rec: bool, extra: u32) vh.Error!void {
    const rec_flag: u32 = if (rec) MS.REC else 0;
    try mount(src, dst, null, MS.BIND | rec_flag, null);
    if (extra == 0) return;
    const flags = try mountFlags(dst);
    try mount(null, dst, null, MS.REMOUNT | MS.BIND | flags | extra, null);
}
