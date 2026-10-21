//! The gaming kernel, built on the machine (vh-game kernel build, docs/uni/game.md, G3b): the
//! machine kernel's pipeline of the kernel-custom workflow with the feature game, run here.
//!
//!   1. kernel.org's tarball of the pinned version (/root/vh/kernel/pins/linux-tarball.sha256),
//!      downloaded by xbps-fetch and checked against the pin's SHA-256 and size;
//!   2. the build root (profile kbuild: clang, lld, make and the kernel's tools), made by thor;
//!   3. vh-kconf resolve with the features auto,game, on the system: this machine's hw.zon and
//!      plan, the pins and profiles of /root/vh;
//!   4. in the sandbox: the tarball unpacked, localyesconfig and olddefconfig;
//!   5. vh-kconf diff (exit 2: a mandatory symbol lost) and the gaming kernel's invariants;
//!   6. in the sandbox: bzImage and modules (Module.symvers for the NVIDIA modules of G3c);
//!   7. the kernel's files, as a kernel-custom run lays them out (BUILD, SHA256SUMS ...), into
//!      /var/lib/vh/game/kernel/KVER: what vh-kconf install takes;
//!   8. the build root and the tree removed: no compiler stays on the disk.
//!
//! The sandbox: namespaces of its own (mount, PID, network, IPC, UTS), the build root read-only
//! as /, the work directory at /work the one place it writes, its own /proc and a /dev of five
//! harmless nodes, no network at all, then the user build_uid (no account has it), no
//! capability, no new privileges. The kernel's tree is untrusted input there: nothing it runs
//! reaches the key, the network or the system's files.
const std = @import("std");
const builtin = @import("builtin");
const vh = @import("vh");
const profiles = @import("profiles");
const common = @import("common.zig");
const roots = @import("roots.zig");
const rmtree = @import("rmtree.zig");
const sys = @import("sys.zig");
const key = @import("key.zig");
const linux = std.os.linux;
const mem = std.mem;
const MS = sys.MS;

/// the build's user: a uid no account has, so that the build owns nothing but its own files
pub const build_uid: u32 = 65530;
const root_name = "kbuild";
/// the build's files: the tarball, resolve's output and the tree (removed after the build)
pub const work_dir = "/var/lib/vh/kbuild";
/// the gaming kernels built, one directory per version, as vh-kconf install takes them
pub const kernel_dir = "/var/lib/vh/game/kernel";
pub const pins_file = "/root/vh/kernel/pins/linux-tarball.sha256";
/// what a build needs on the disk at most [estimate: the build root 1.2 GiB, the tarball and its
/// tree 1.7 GiB, the objects with their debug information for BTF 4-6 GiB]
pub const space_needed_gib = 10;

pub const Pin = struct { sha256: []const u8, name: []const u8, size: u64, kver: []const u8 };

/// the newest line of the pins file: "SHA256  linux-A.B.C.tar.xz  SIZE"
pub fn parsePins(text: []const u8) ?Pin {
    var best: ?Pin = null;
    var lines = mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const l = vh.strip(raw);
        if (l.len == 0 or l[0] == '#') continue;
        var f = mem.tokenizeAny(u8, l, " \t");
        const sha = f.next() orelse continue;
        const name = f.next() orelse continue;
        const size_s = f.next() orelse continue;
        if (sha.len != 64 or !allHex(sha)) continue;
        if (!vh.startsWith(name, "linux-") or !vh.endsWith(name, ".tar.xz")) continue;
        const kver = name["linux-".len .. name.len - ".tar.xz".len];
        if (!isVersion(kver)) continue;
        const size = std.fmt.parseInt(u64, size_s, 10) catch continue;
        const p: Pin = .{ .sha256 = sha, .name = name, .size = size, .kver = kver };
        if (best == null or newer(kver, best.?.kver)) best = p;
    }
    return best;
}

fn allHex(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// A.B.C, each a number
pub fn isVersion(s: []const u8) bool {
    var it = mem.splitScalar(u8, s, '.');
    var n: usize = 0;
    while (it.next()) |p| : (n += 1) {
        if (p.len == 0 or p.len > 6) return false;
        for (p) |c| if (!std.ascii.isDigit(c)) return false;
    }
    return n == 3;
}

fn newer(a: []const u8, b: []const u8) bool {
    var ia = mem.splitScalar(u8, a, '.');
    var ib = mem.splitScalar(u8, b, '.');
    while (true) {
        const x = ia.next() orelse return false;
        const y = ib.next() orelse return true;
        const nx = std.fmt.parseInt(u64, x, 10) catch 0;
        const ny = std.fmt.parseInt(u64, y, 10) catch 0;
        if (nx != ny) return nx > ny;
    }
}

/// kernel.org's address of a tarball: v6.x for 6.y.z
pub fn tarballUrl(p: Pin) []const u8 {
    const major = p.kver[0 .. mem.indexOfScalar(u8, p.kver, '.') orelse p.kver.len];
    return vh.fmt("https://cdn.kernel.org/pub/linux/kernel/v{s}.x/{s}", .{ major, p.name });
}

/// The gaming kernel's invariants in its final .config: what makes it the gaming kernel, and
/// the machine kernel's hardening it keeps (kernel-custom checks the same of a machine kernel).
/// The problems; empty when it is one.
pub fn invariants(config: []const u8) []const []const u8 {
    var out: vh.Strv = .{};
    const want = [_][2][]const u8{
        .{ "CONFIG_IA32_EMULATION", "y" },
        .{ "CONFIG_MODULES", "y" },
        .{ "CONFIG_MODULE_SIG", "y" },
        .{ "CONFIG_MODULE_SIG_FORCE", "y" },
        .{ "CONFIG_MODULE_SIG_SHA512", "y" },
        .{ "CONFIG_MODULE_SIG_KEY", "\"certs/vh-game.pem\"" },
        .{ "CONFIG_LOCALVERSION", "\"-vh-game\"" },
        .{ "CONFIG_LOCK_DOWN_KERNEL_FORCE_CONFIDENTIALITY", "y" },
        .{ "CONFIG_CFI", "y" },
        .{ "CONFIG_SCHED_CLASS_EXT", "y" },
        .{ "CONFIG_DEBUG_INFO_BTF", "y" },
        .{ "CONFIG_NTSYNC", "y" },
    };
    for (want) |w| {
        const got = configValue(config, w[0]);
        if (got == null or !vh.eql(got.?, w[1])) out.add(vh.fmt("{s}={s} (wanted {s})", .{ w[0], got orelse "not set", w[1] }));
    }
    for ([_][]const u8{ "CONFIG_MODULE_UNLOAD", "CONFIG_MODULE_FORCE_LOAD", "CONFIG_IO_URING", "CONFIG_DRM_NOUVEAU" }) |off| {
        if (configValue(config, off)) |v| out.add(vh.fmt("{s}={s} (wanted not set)", .{ off, v }));
    }
    return out.slice();
}

/// a symbol's value in a .config ("y", "\"text\""); null when it is not set
pub fn configValue(config: []const u8, sym: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    var lines = mem.tokenizeScalar(u8, config, '\n');
    while (lines.next()) |l| {
        if (vh.startsWith(l, sym) and l.len > sym.len and l[sym.len] == '=') found = l[sym.len + 1 ..];
        if (vh.startsWith(l, "# ") and vh.endsWith(l, " is not set") and vh.eql(l[2 .. l.len - " is not set".len], sym)) found = null;
    }
    return found;
}

// ---------------------------------------------------------------- the sandbox

/// ARGV in the build root ROOT, its work directory WORK at /work, as build_uid, in namespaces of
/// its own; ENV its whole environment. The exit code (128 + N for signal N).
pub fn sandbox(root: []const u8, work: []const u8, argv: []const []const u8, env: []const []const u8) u8 {
    // everything the child needs is made before the fork
    var args: std.ArrayList(?[*:0]const u8) = .empty;
    for (argv) |a| args.append(vh.gpa, vh.z(a).ptr) catch vh.oom();
    args.append(vh.gpa, null) catch vh.oom();
    var envs: std.ArrayList(?[*:0]const u8) = .empty;
    for (env) |e| envs.append(vh.gpa, vh.z(e).ptr) catch vh.oom();
    envs.append(vh.gpa, null) catch vh.oom();
    const sb: Box = .{ .root = root, .work = work, .argv = @ptrCast(args.items.ptr), .envp = @ptrCast(envs.items.ptr) };
    vh.flush();
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) vh.die("fork: {s}", .{vh.strerror(linux.errno(pid))});
    if (pid == 0) {
        sb.enter() catch {
            vh.warn("the build's sandbox: {s}: {s}", .{ box_step, vh.serr() });
            linux.exit_group(125);
        };
    }
    return waitCode(@intCast(pid));
}

const Box = struct {
    root: []const u8,
    work: []const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,

    fn at(b: Box, p: []const u8) []const u8 {
        return vh.fmt("{s}{s}", .{ b.root, p });
    }

    /// the namespaces; the program is PID 1 of the PID namespace (when it ends, the kernel ends
    /// whatever of the build is left), and runs as build_uid
    fn enter(b: Box) vh.Error!noreturn {
        box_step = "namespaces";
        try sys.unshare(linux.CLONE.NEWNS | linux.CLONE.NEWPID | linux.CLONE.NEWNET | linux.CLONE.NEWIPC | linux.CLONE.NEWUTS);
        const pid = linux.fork();
        if (linux.errno(pid) != .SUCCESS) return error.Sys;
        if (pid != 0) linux.exit_group(waitCode(@intCast(pid)));
        try b.mounts();
        // the bounding set first, while CAP_SETPCAP is there; the uid change then clears the
        // permitted and effective sets (no SECBIT_KEEP_CAPS), and no exec can give any back
        box_step = "the capabilities";
        var cap: usize = 0;
        while (cap < 64) : (cap += 1) {
            const rc = linux.prctl(@intFromEnum(linux.PR.CAPBSET_DROP), cap, 0, 0, 0);
            if (linux.errno(rc) == .INVAL) break;
            _ = try vh.sys(rc);
        }
        box_step = "the build's user";
        const none = [_]linux.gid_t{};
        _ = try vh.sys(linux.setgroups(0, &none));
        _ = try vh.sys(linux.setresgid(build_uid, build_uid, build_uid));
        _ = try vh.sys(linux.setresuid(build_uid, build_uid, build_uid));
        try sys.noNewPrivs();
        _ = try vh.sys(linux.chdir("/work"));
        box_step = "exec";
        _ = linux.execve(b.argv[0].?, b.argv, b.envp);
        return error.Sys;
    }

    fn mounts(b: Box) vh.Error!void {
        box_step = "mount propagation";
        try sys.mount(null, "/", null, MS.REC | MS.PRIVATE, null);
        box_step = "the build root";
        try sys.bind(b.root, b.root, MS.RDONLY | MS.NOSUID | MS.NODEV);
        box_step = "/work";
        try sys.bind(b.work, b.at("/work"), MS.NOSUID | MS.NODEV);
        box_step = "/tmp";
        try sys.mount("tmpfs", b.at("/tmp"), "tmpfs", MS.NOSUID | MS.NODEV, "mode=1777");
        box_step = "/proc";
        try sys.mount("proc", b.at("/proc"), "proc", MS.NOSUID | MS.NODEV | MS.NOEXEC, null);
        box_step = "/dev";
        try sys.mount("tmpfs", b.at("/dev"), "tmpfs", MS.NOSUID | MS.NOEXEC, "mode=0755,size=64k");
        for ([_][]const u8{ "null", "zero", "full", "random", "urandom" }) |d| {
            const dst = b.at(vh.fmt("/dev/{s}", .{d}));
            try sys.touch(dst, 0o666);
            try sys.bind(vh.fmt("/dev/{s}", .{d}), dst, MS.NOSUID | MS.NOEXEC);
        }
        for ([_][2][]const u8{ .{ "/proc/self/fd", "fd" }, .{ "/proc/self/fd/0", "stdin" }, .{ "/proc/self/fd/1", "stdout" }, .{ "/proc/self/fd/2", "stderr" } }) |l|
            try sys.symlink(l[0], b.at(vh.fmt("/dev/{s}", .{l[1]})));
        box_step = "the host name";
        try sys.sethostname("kbuild");
        box_step = "pivot_root";
        try sys.pivotHere(b.root);
    }
};

var box_step: []const u8 = "";

fn waitCode(pid: linux.pid_t) u8 {
    var st: i32 = 0;
    while (true) {
        const rc = linux.wait4(pid, &st, 0, null);
        if (linux.errno(rc) == .INTR) continue;
        if (linux.errno(rc) != .SUCCESS) return 126;
        break;
    }
    const s: u32 = @bitCast(st);
    if (linux.W.IFEXITED(s)) return linux.W.EXITSTATUS(s);
    return @truncate(128 + @as(u32, @intFromEnum(linux.W.TERMSIG(s))));
}

// ---------------------------------------------------------------- the build

pub const Opts = struct {
    o: roots.Opts = .{},
    /// make's jobs; 0: the CPUs, at most one per GiB of available memory
    jobs: u32 = 0,
    /// vh-kconf (the tests give another)
    kconf: []const u8 = "/usr/local/sbin/vh-kconf",
    /// a tarball already downloaded (the tests): checked against the pin all the same
    tarball: ?[]const u8 = null,
};

fn path(S: common.System, p: []const u8) []const u8 {
    return S.path(p);
}

/// vh-game kernel build: the files of the gaming kernel in kernel_dir/KVER; its directory
pub fn build(b: Opts) []const u8 {
    const S = b.o.sys;
    if (builtin.cpu.arch != .x86_64) vh.die("the gaming kernel is built on x86_64 machines (its profile, the pins: x86_64)", .{});
    // what the build stands on, before anything is made
    const cert = vh.readFile(key.certPath(S)) catch vh.die("{s}: {s}: the gaming kernel trusts the module key alone (doas vh-game key new)", .{ key.certPath(S), vh.serr() });
    if (key.pemBody(cert, "CERTIFICATE") == null) vh.die("{s}: not one PEM certificate", .{key.certPath(S)});
    const pin_text = vh.readFile(S.path(pins_file)) catch vh.die("{s}: {s} (the repository copy of the installation: /root/vh)", .{ S.path(pins_file), vh.serr() });
    const pin = parsePins(pin_text) orelse vh.die("{s}: no tarball line (SHA256  linux-A.B.C.tar.xz  SIZE)", .{S.path(pins_file)});
    for ([_][]const u8{ "/etc/vh/hw.zon", "/etc/vh/plan.zon" }) |p| if (!vh.isRegular(S.path(p))) vh.die("{s}: missing (the installation's probe and plan)", .{S.path(p)});
    if (!vh.isRegular(b.kconf)) vh.die("{s}: missing (install/build-tools.sh)", .{b.kconf});
    const free = freeGiB(S.path(common.vh_dir));
    if (free < space_needed_gib) vh.die("{s} has {d} GiB free: the build needs about {d} GiB while it runs (the build root, the tree, its objects), all of it freed after", .{ S.path(common.vh_dir), free, space_needed_gib });
    const jobs = if (b.jobs > 0) b.jobs else defaultJobs();
    vh.log("the gaming kernel {s}-vh-game: {d} jobs; the build root is made, then removed (about {d} GiB free needed, {d} free)", .{ pin.kver, jobs, space_needed_gib, free });

    // a fresh work directory, the build's user's
    const work = S.path(work_dir);
    if (vh.pathExists(work)) rmtree.removeTree(work);
    sys.mkdir(work, 0o700) catch vh.die("{s}: {s}", .{ work, vh.serr() });
    sys.chown(work, build_uid, build_uid) catch vh.die("{s}: {s}", .{ work, vh.serr() });
    defer cleanup(b.o);

    // 1. the tarball
    const tarball = vh.fmt("{s}/{s}", .{ work, pin.name });
    if (b.tarball) |given| {
        copyFile(given, tarball);
    } else {
        vh.log("downloading {s}", .{tarballUrl(pin)});
        if (vh.run(&.{ "/usr/bin/xbps-fetch", "-o", tarball, tarballUrl(pin) }) != 0) die(b.o, "xbps-fetch could not download {s}", .{tarballUrl(pin)});
    }
    checkTarball(b.o, tarball, pin);

    // 2. the build root; its /work is the mount point of the work directory
    const profile = profiles.get(root_name).?;
    if (roots.exists(b.o, root_name)) roots.remove(b.o, root_name);
    roots.after_failure = "the gaming kernel was not built";
    roots.create(b.o, root_name, profile, &.{}, null);
    const root = roots.path(b.o, root_name);
    sys.mkdir(vh.fmt("{s}/work", .{root}), 0o755) catch die(b.o, "{s}/work: {s}", .{ root, vh.serr() });

    // 3. resolve, as kernel-custom: hw.zon, the plan, the pins and profiles; the features of the
    // plan and game
    const resolve = vh.fmt("{s}/resolve", .{work});
    if (vh.run(&.{ b.kconf, "resolve", "--hw", S.path("/etc/vh/hw.zon"), "--plan", S.path("/etc/vh/plan.zon"), "--out", resolve, "--repo", S.path("/root/vh"), "--features", "auto,game" }) != 0)
        die(b.o, "vh-kconf resolve failed (above)", .{});
    // the key's certificate, the only one the kernel trusts
    const tree_name = vh.fmt("linux-{s}", .{pin.kver});
    vh.writeAtomic(vh.fmt("{s}/vh-game.pem", .{work}), cert, 0o644);

    // 4. the tree and its configuration, in the sandbox
    const env = buildEnv();
    const configure = vh.fmt(
        \\set -eu
        \\tar -xJf /work/{s}
        \\cd /work/{s}
        \\cp /work/resolve/.config .config
        \\cp /work/vh-game.pem certs/vh-game.pem
        \\printf 'CONFIG_MODULE_SIG_KEY="certs/vh-game.pem"\n' >> .config
        \\# yes dies of SIGPIPE when make is done: the pipeline's status is make's
        \\yes "" | make LLVM=1 localyesconfig LSMOD=/work/resolve/lsmod >/dev/null
        \\make LLVM=1 olddefconfig >/dev/null
    , .{ pin.name, tree_name });
    if (sandbox(root, work, &.{ "/bin/bash", "-c", configure }, env) != 0) die(b.o, "the kernel's configuration failed in the build's sandbox (above)", .{});

    // 5. what survived, and the gaming kernel's invariants
    const tree = vh.fmt("{s}/{s}", .{ work, tree_name });
    const drc = vh.run(&.{ b.kconf, "diff", "--oracle", "localyesconfig", "--config", vh.fmt("{s}/.config", .{tree}), "--requested", vh.fmt("{s}/fragment.config", .{resolve}), "--lsmod", vh.fmt("{s}/lsmod", .{resolve}), "--kernel", tree });
    if (drc != 0) die(b.o, "vh-kconf diff: a symbol the gaming kernel must have did not survive the kernel's own configuration ({d}, above)", .{drc});
    const config = vh.readFile(vh.fmt("{s}/.config", .{tree})) catch die(b.o, "{s}/.config: {s}", .{ tree, vh.serr() });
    const bad = invariants(config);
    if (bad.len > 0) die(b.o, "not the gaming kernel: {s}", .{mem.join(vh.gpa, "; ", bad) catch vh.oom()});

    // 6. the kernel, in the sandbox
    const kcflags = vh.strip(vh.readFile(vh.fmt("{s}/kcflags", .{resolve})) catch "");
    const make = vh.fmt(
        \\set -eu
        \\cd /work/{s}
        \\make LLVM=1 KCFLAGS="{s}" -j{d} bzImage modules
    , .{ tree_name, kcflags, jobs });
    vh.log("building the kernel (clang, {d} jobs) [estimate: 20 to 60 minutes]", .{jobs});
    if (sandbox(root, work, &.{ "/bin/bash", "-c", make }, env) != 0) die(b.o, "the kernel's build failed in the build's sandbox (above)", .{});

    // 7. its files, as a kernel-custom run lays them out
    const out = collect(b.o, pin, tree, resolve, kcflags);
    vh.log("the gaming kernel {s}-vh-game is built: {s}", .{ pin.kver, out });
    return out;
}

fn die(o: roots.Opts, comptime f: []const u8, args: anytype) noreturn {
    vh.warn(f, args);
    cleanup(o);
    vh.exit(1);
}

/// the build root and the work directory go, whatever happened
fn cleanup(o: roots.Opts) void {
    if (roots.exists(o, root_name)) roots.remove(o, root_name);
    const work = o.sys.path(work_dir);
    if (vh.pathExists(work)) rmtree.removeTree(work);
}

fn buildEnv() []const []const u8 {
    return &.{
        "PATH=/usr/bin:/usr/sbin",
        "HOME=/tmp",
        "LANG=C",
        "LC_ALL=C",
        "KBUILD_BUILD_USER=vh",
        "KBUILD_BUILD_HOST=kbuild",
        "KBUILD_BUILD_VERSION=1",
    };
}

/// the tarball against the pin: its size, then its SHA-256
fn checkTarball(o: roots.Opts, p: []const u8, pin: Pin) void {
    const fd = vh.openFd(p, .{ .ACCMODE = .RDONLY }, 0) catch die(o, "{s}: {s}", .{ p, vh.serr() });
    defer vh.close(fd);
    const st = vh.fstat(fd) catch die(o, "{s}: {s}", .{ p, vh.serr() });
    if (st.size != pin.size) die(o, "{s}: {d} bytes, the pin says {d}: not the tarball of kernel.org", .{ p, st.size, pin.size });
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    const buf = vh.gpa.alloc(u8, 1 << 20) catch vh.oom();
    while (true) {
        const n = vh.readFd(fd, buf) catch die(o, "{s}: {s}", .{ p, vh.serr() });
        if (n == 0) break;
        h.update(buf[0..n]);
    }
    var d: [32]u8 = undefined;
    h.final(&d);
    const hex = std.fmt.bytesToHex(d, .lower);
    if (!vh.eql(&hex, pin.sha256)) die(o, "{s}: sha256 {s}, the pin says {s}: not the tarball of kernel.org", .{ p, &hex, pin.sha256 });
}

fn copyFile(src: []const u8, dst: []const u8) void {
    const data = vh.readFile(src) catch vh.die("{s}: {s}", .{ src, vh.serr() });
    vh.writeAtomic(dst, data, 0o644);
}

/// the free GiB of the file system of PATH
fn freeGiB(p: []const u8) u64 {
    const Statfs = extern struct { type: i64, bsize: i64, blocks: u64, bfree: u64, bavail: u64, files: u64, ffree: u64, fsid: [2]i32, namelen: i64, frsize: i64, flags: i64, spare: [4]i64 };
    var s: Statfs = undefined;
    if (linux.errno(linux.syscall2(.statfs, @intFromPtr(vh.z(p).ptr), @intFromPtr(&s))) != .SUCCESS) return 0;
    return s.bavail * @as(u64, @intCast(s.bsize)) >> 30;
}

/// the CPUs this process may run on, at most one job per GiB of available memory, at least 1
fn defaultJobs() u32 {
    var set: linux.cpu_set_t = undefined;
    var cpus: u32 = 1;
    if (linux.errno(linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &set)) == .SUCCESS) {
        var n: u32 = 0;
        for (set) |w| n += @popCount(w);
        if (n > 0) cpus = n;
    }
    const mem_gib = memAvailableGiB();
    if (mem_gib > 0 and mem_gib < cpus) return @max(1, mem_gib);
    return cpus;
}

fn memAvailableGiB() u32 {
    const text = vh.readFile("/proc/meminfo") catch return 0;
    var lines = mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |l| if (vh.startsWith(l, "MemAvailable:")) {
        var f = mem.tokenizeAny(u8, l["MemAvailable:".len..], " \t");
        const kib = std.fmt.parseInt(u64, f.next() orelse return 0, 10) catch return 0;
        return @intCast(kib >> 20);
    };
    return 0;
}

/// the kernel's files into kernel_dir/KVER, named and summed as a kernel-custom run's
fn collect(o: roots.Opts, pin: Pin, tree: []const u8, resolve: []const u8, kcflags: []const u8) []const u8 {
    const S = o.sys;
    const kd = S.path(kernel_dir);
    vh.mkdirs(S.path("/var/lib/vh/game"), 0o700);
    vh.mkdirs(kd, 0o700);
    const out = vh.fmt("{s}/{s}", .{ kd, pin.kver });
    if (vh.pathExists(out)) rmtree.removeTree(out);
    sys.mkdir(out, 0o700) catch die(o, "{s}: {s}", .{ out, vh.serr() });
    const k = pin.kver;
    const files = [_][2][]const u8{
        .{ vh.fmt("{s}/arch/x86/boot/bzImage", .{tree}), vh.fmt("bzImage-vh-{s}", .{k}) },
        .{ vh.fmt("{s}/.config", .{tree}), vh.fmt("config-vh-{s}", .{k}) },
        .{ vh.fmt("{s}/System.map", .{tree}), vh.fmt("System.map-vh-{s}", .{k}) },
        .{ vh.fmt("{s}/modules.builtin", .{tree}), vh.fmt("modules.builtin-vh-{s}", .{k}) },
        .{ vh.fmt("{s}/modules.builtin.modinfo", .{tree}), vh.fmt("modules.builtin.modinfo-vh-{s}", .{k}) },
        .{ vh.fmt("{s}/Module.symvers", .{tree}), vh.fmt("Module.symvers-vh-{s}", .{k}) },
        .{ vh.fmt("{s}/resolve-report.txt", .{resolve}), "resolve-report.txt" },
        .{ vh.fmt("{s}/fragment.config", .{resolve}), "fragment.config" },
        .{ vh.fmt("{s}/lsmod", .{resolve}), "lsmod" },
        .{ S.path("/etc/vh/plan.zon"), "plan.zon" },
        .{ S.path("/etc/vh/hw.zon"), "hw.zon" },
    };
    for (files) |f| {
        const data = vh.readFile(f[0]) catch die(o, "{s}: {s}", .{ f[0], vh.serr() });
        vh.writeAtomic(vh.fmt("{s}/{s}", .{ out, f[1] }), data, 0o600);
    }
    const hw_sum = sha256Hex(vh.readFile(S.path("/etc/vh/hw.zon")) catch "");
    const build_text = vh.fmt(
        \\kernel-custom local: linux-{s}, features auto,game, commit vh-game, run {d}
        \\hw.zon: hw.zon sha256 {s}
        \\built on this machine by vh-game kernel build ({s} UTC): KCFLAGS={s} LLVM=1, the build root of the profile kbuild
        \\
    , .{ k, vh.now(), hw_sum, vh.utcTime(vh.now()), kcflags });
    vh.writeAtomic(vh.fmt("{s}/BUILD", .{out}), build_text, 0o600);
    // SHA256SUMS, as sha256sum writes it
    var sums: std.ArrayList(u8) = .empty;
    var names: vh.Strv = .{};
    for (files) |f| names.add(f[1]);
    names.add("BUILD");
    for (names.slice()) |n| {
        const data = vh.readFile(vh.fmt("{s}/{s}", .{ out, n })) catch die(o, "{s}/{s}: {s}", .{ out, n, vh.serr() });
        sums.print(vh.gpa, "{s}  {s}\n", .{ sha256Hex(data), n }) catch vh.oom();
    }
    vh.writeAtomic(vh.fmt("{s}/SHA256SUMS", .{out}), sums.items, 0o600);
    return out;
}

fn sha256Hex(data: []const u8) []const u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &d, .{});
    return vh.dupe(&std.fmt.bytesToHex(d, .lower));
}

const t = std.testing;

test "the pins of the kernel's tarball" {
    const text =
        \\# comment
        \\5bd9acdc82ec5efc3790ae840e5aaa40dfde7efff261cf6dde902dc570acf98c  linux-6.18.57.tar.xz  154863520
        \\0000000000000000000000000000000000000000000000000000000000000000  linux-6.18.9.tar.xz  1
        \\zz  linux-6.19.1.tar.xz  1
        \\1111111111111111111111111111111111111111111111111111111111111111  linux-6.18.tar.xz  1
    ;
    const p = parsePins(text).?;
    try t.expectEqualStrings("6.18.57", p.kver);
    try t.expectEqual(@as(u64, 154863520), p.size);
    try t.expectEqualStrings("https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.57.tar.xz", tarballUrl(p));
    try t.expect(parsePins("# nothing\n") == null);
    try t.expect(newer("6.18.57", "6.18.9") and !newer("6.18.9", "6.18.57") and newer("7.0.1", "6.18.57"));
    try t.expect(isVersion("6.18.57") and !isVersion("6.18") and !isVersion("6.18.x"));
}

test "the gaming kernel's invariants" {
    const good =
        \\CONFIG_IA32_EMULATION=y
        \\CONFIG_MODULES=y
        \\CONFIG_MODULE_SIG=y
        \\CONFIG_MODULE_SIG_FORCE=y
        \\CONFIG_MODULE_SIG_SHA512=y
        \\CONFIG_MODULE_SIG_KEY="certs/vh-game.pem"
        \\CONFIG_LOCALVERSION="-vh-game"
        \\CONFIG_LOCK_DOWN_KERNEL_FORCE_CONFIDENTIALITY=y
        \\CONFIG_CFI=y
        \\CONFIG_SCHED_CLASS_EXT=y
        \\CONFIG_DEBUG_INFO_BTF=y
        \\CONFIG_NTSYNC=y
        \\# CONFIG_MODULE_UNLOAD is not set
        \\# CONFIG_IO_URING is not set
        \\
    ;
    try t.expectEqual(@as(usize, 0), invariants(good).len);
    // a machine kernel's: no modules, no ia32, its own release
    const machine = "CONFIG_LOCALVERSION=\"-vh\"\n# CONFIG_MODULES is not set\n# CONFIG_IA32_EMULATION is not set\n";
    try t.expect(invariants(machine).len >= 3);
    // an unload that came back
    try t.expectEqual(@as(usize, 1), invariants(vh.fmt("{s}CONFIG_MODULE_UNLOAD=y\n", .{good})).len);
    try t.expectEqualStrings("\"-vh-game\"", configValue(good, "CONFIG_LOCALVERSION").?);
    try t.expect(configValue(good, "CONFIG_IO_URING") == null and configValue(good, "CONFIG_NOPE") == null);
}
