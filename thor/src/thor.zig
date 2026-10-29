//! thor: the void-hardperf-light package manager, based on xbps (docs/18).
//!
//!   doas thor install PKG... [-y] [-j N] [xbps-install options]
//!   doas thor update [-y] [-j N]
//!   doas thor fetch [-j N] [xbps-install options]   -- download only (and verify the signatures)
//!   doas thor remove PKG... [xbps-remove options]
//!   thor search WORD
//!   doas thor mirror [--write]                       -- the fastest mirror
//!   doas thor keep PATH...  /  doas thor allow PKG...  -- policy exceptions
//!   doas thor baseline                               -- the baseline from the installed packages
//!   thor policy                                      -- the policy mode and exceptions
//!
//! Installation: the plan comes from "xbps-install -n"; the missing packages and signatures
//! are downloaded in parallel (N worker processes using libxbps's stock downloader: TLS,
//! proxies, .part resumption, keep-alive, proven upstream code), then the ordinary
//! xbps-install runs: it verifies the RSA signature of every package in the cache itself and
//! installs them under the thor policy (built into libxbps). The workers run with lowered
//! CPU and disk priority: the download does not get in the way.
const std = @import("std");
const vh = @import("vh");
const rules = @import("rules");
const linux = std.os.linux;
const mem = std.mem;
const c = @import("c"); // libxbps: src/xbps_c.h -> translate-c (build.zig)

const version = "0.60.7.1";
const conf_path = "/etc/thor/thor.conf";
const default_jobs = 4;
const max_jobs = 8;

/// Void HTTPS mirrors (https://xmirror.voidlinux.org, October 2026)
const mirrors = [_][]const u8{
    "https://repo-default.voidlinux.org",
    "https://repo-fi.voidlinux.org",
    "https://repo-de.voidlinux.org",
    "https://repo-fastly.voidlinux.org",
    "https://mirrors.summithq.com/voidlinux",
    "https://mirrors.cicku.me/voidlinux",
    "https://voidlinux.mirror-services.net/voidlinux",
    "https://mirrors.dotsrc.org/voidlinux",
    "https://void.mirror.lynnfra.net",
    "https://ftp.cc.uoc.gr/mirrors/linux/voidlinux",
    "https://voidlinux.mirror.garr.it",
    "https://void.sakamoto.pl",
    "https://mirror.yandex.ru/mirrors/voidlinux",
    "https://ftp.lysator.liu.se/pub/voidlinux",
    "https://mirror.accum.se/mirror/voidlinux",
    "https://mirror.puzzle.ch/voidlinux",
    "https://mirror.vofr.net/voidlinux",
    "https://mirrors.lug.mtu.edu/voidlinux",
    "https://void.tuxmirrors.xyz",
    "https://mirror.aarnet.edu.au/pub/voidlinux",
    "https://repo.jing.rocks/voidlinux",
    "https://mirror.freedif.org/voidlinux",
    "https://mirrors.tuna.tsinghua.edu.cn/voidlinux",
    "https://mirror.linux.ec/voidlinux",
};

fn usage() noreturn {
    vh.flush();
    _ = vh.writeAllFd(2,
        \\doas thor install PKG... [-y] [-j N] [xbps-install options]
        \\doas thor update [-y] [-j N]
        \\doas thor fetch [-j N] [xbps-install options]
        \\doas thor remove PKG... [xbps-remove options]
        \\thor search WORD
        \\doas thor mirror [--write]
        \\doas thor keep PATH...
        \\doas thor allow PKG...
        \\doas thor baseline
        \\thor policy
        \\
    ) catch {};
    vh.exit(2);
}

pub fn main(init: std.process.Init.Minimal) void {
    const args = vh.init(init, "thor");
    if (args.len == 0) usage();
    const cmd = args[0];
    const rest = args[1..];
    if (vh.eql(cmd, "install")) return transaction(rest, .install);
    if (vh.eql(cmd, "update")) return transaction(rest, .update);
    if (vh.eql(cmd, "fetch")) return transaction(rest, .fetch);
    if (vh.eql(cmd, "remove")) return execWith("xbps-remove", &.{}, rest);
    if (vh.eql(cmd, "search")) return execWith("xbps-query", &.{"-Rs"}, rest);
    if (vh.eql(cmd, "mirror")) return mirror(rest);
    if (vh.eql(cmd, "keep")) return addList(rest, "/etc/thor/keep.conf", .keep);
    if (vh.eql(cmd, "allow")) return addList(rest, "/etc/thor/allow.conf", .allow);
    if (vh.eql(cmd, "baseline")) return baseline(rest);
    if (vh.eql(cmd, "policy")) return showPolicy();
    if (vh.eql(cmd, "--version") or vh.eql(cmd, "-V")) {
        vh.out("thor {s} (xbps 0.60.7 + the void-hardperf-light policy)\n", .{version});
        return vh.flush();
    }
    usage();
}

fn needRoot(what: []const u8) void {
    if (linux.geteuid() != 0) vh.die("run: doas thor {s} ...", .{what});
}

/// The directory of the xbps programs is the one thor lives in (/usr/bin; in the build
/// tree DESTDIR/usr/bin). Not from PATH and not from an environment variable: no program
/// can be substituted.
fn binDir() []const u8 {
    const exe = vh.readlink("/proc/self/exe") catch vh.die("/proc/self/exe: {s}", .{vh.serr()});
    return std.fs.path.dirname(exe) orelse "/usr/bin";
}

fn xbpsBin(prog: []const u8) []const u8 {
    return vh.fmt("{s}/{s}", .{ binDir(), prog });
}

/// replace the process with an xbps program
fn execWith(prog: []const u8, pre: []const []const u8, rest: []const []const u8) noreturn {
    var argv: std.ArrayList([]const u8) = .empty;
    argv.append(vh.gpa, prog) catch vh.oom();
    argv.appendSlice(vh.gpa, pre) catch vh.oom();
    argv.appendSlice(vh.gpa, rest) catch vh.oom();
    const cargv = vh.gpa.allocSentinel(?[*:0]const u8, argv.items.len, null) catch vh.oom();
    for (argv.items, 0..) |a, i| cargv[i] = vh.z(a).ptr;
    vh.flush();
    const path = vh.z(xbpsBin(prog));
    const rc = linux.execve(path.ptr, cargv.ptr, vh.envp);
    vh.errno = linux.errno(rc);
    vh.die("{s}: {s}", .{ path, vh.serr() });
}

// ---------------------------------------------------------------- thor config

const Conf = struct {
    jobs: usize = default_jobs,
    /// KB/s for the whole download; 0 means no limit
    ratelimit: u64 = 0,
    fallback: std.ArrayList([]const u8) = .empty,
};

fn readConf(root: []const u8) Conf {
    var cf: Conf = .{};
    const text = vh.readFile(vh.fmt("{s}{s}", .{ mem.trimEnd(u8, root, "/"), conf_path })) catch return cf;
    var it = mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = vh.strip(raw);
        if (line.len == 0 or line[0] == '#') continue;
        const eq = mem.indexOfScalar(u8, line, '=') orelse continue;
        const k = vh.strip(line[0..eq]);
        const v = vh.strip(line[eq + 1 ..]);
        if (vh.eql(k, "parallel")) {
            const n = vh.parseLong(v) orelse vh.die("{s}: parallel={s}: a number is required", .{ conf_path, v });
            cf.jobs = @intCast(std.math.clamp(n, 1, max_jobs));
        } else if (vh.eql(k, "ratelimit")) {
            const n = vh.parseLong(v) orelse vh.die("{s}: ratelimit={s}: a number is required (KB/s)", .{ conf_path, v });
            cf.ratelimit = @intCast(@max(n, 0));
        } else if (vh.eql(k, "mirror-fallback")) {
            cf.fallback.append(vh.gpa, mem.trimEnd(u8, v, "/")) catch vh.oom();
        }
    }
    return cf;
}

// ---------------------------------------------------------------- libxbps

var xhp: c.struct_xbps_handle = mem.zeroes(c.struct_xbps_handle);

fn setStr(dst: []u8, s: []const u8) void {
    if (s.len >= dst.len) vh.die("{s}: path too long", .{s});
    @memcpy(dst[0..s.len], s);
    dst[s.len] = 0;
}

/// Initialise libxbps with the root, cache and config from the xbps-install options.
fn xbpsInit(opt: XbpsPaths) void {
    if (opt.root) |r| setStr(&xhp.rootdir, r);
    if (opt.cache) |d| setStr(&xhp.cachedir, d);
    if (opt.conf) |d| setStr(&xhp.confdir, d);
    xhp.flags |= c.XBPS_FLAG_DISABLE_SYSLOG;
    // the pkgdb lock's descriptor: libxbps sets it only in xbps_pkgdb_lock, which thor never
    // calls (the xbps-install it execs takes the lock itself), and in the zeroed handle it is 0,
    // stdin. xbps_end, run before that exec, unlocks by closing the descriptor: with 0 the
    // exec'd xbps-install read EOF at its "[Y/n]" question and aborted every installation
    // without -y (tests/thor/package_test.sh, "without -y")
    xhp.lock_fd = -1;
    const rv = c.xbps_init(&xhp);
    if (rv != 0) {
        vh.errno = @enumFromInt(rv);
        vh.die("could not initialise xbps: {s}", .{vh.serr()});
    }
}

fn cstr(a: []const u8) []const u8 {
    return mem.sliceTo(a, 0);
}

const XbpsPaths = struct { root: ?[]const u8 = null, cache: ?[]const u8 = null, conf: ?[]const u8 = null };

// ---------------------------------------------------------------- installation

const Mode = enum { install, update, fetch };

const Job = struct {
    pkgver: []const u8,
    /// the repository URL from the plan (.../current or .../current/nonfree)
    repo: []const u8,
    file: []const u8,
    size: u64,
};

fn transaction(args_in: []const [:0]const u8, mode: Mode) void {
    needRoot(@tagName(mode));
    // thor's own options (-j N) are separated; everything else goes to xbps-install as it is
    var pass: std.ArrayList([]const u8) = .empty;
    // options without package names, for the repository sync (xbps-install -S)
    var sync_args: std.ArrayList([]const u8) = .empty;
    var paths: XbpsPaths = .{};
    var jobs_opt: ?usize = null;
    var i: usize = 0;
    while (i < args_in.len) : (i += 1) {
        const a = args_in[i];
        if ((vh.eql(a, "-j") or vh.eql(a, "--jobs")) and i + 1 < args_in.len) {
            i += 1;
            const n = vh.parseLong(args_in[i]) orelse usage();
            jobs_opt = @intCast(std.math.clamp(n, 1, max_jobs));
            continue;
        }
        pass.append(vh.gpa, a) catch vh.oom();
        if (vh.startsWith(a, "--repository=") or vh.startsWith(a, "--rootdir=") or vh.startsWith(a, "--config=") or
            vh.startsWith(a, "--cachedir="))
            sync_args.append(vh.gpa, a) catch vh.oom();
        if ((vh.eql(a, "-R") or vh.eql(a, "--repository")) and i + 1 < args_in.len) {
            i += 1;
            pass.append(vh.gpa, args_in[i]) catch vh.oom();
            sync_args.appendSlice(vh.gpa, &.{ a, args_in[i] }) catch vh.oom();
            continue;
        }
        // the paths thor itself needs (the package cache)
        const takes = [_]struct { s: []const u8, l: []const u8, f: enum { root, cache, conf } }{
            .{ .s = "-r", .l = "--rootdir", .f = .root },
            .{ .s = "-c", .l = "--cachedir", .f = .cache },
            .{ .s = "-C", .l = "--config", .f = .conf },
        };
        for (takes) |t| {
            if ((vh.eql(a, t.s) or vh.eql(a, t.l)) and i + 1 < args_in.len) {
                i += 1;
                pass.append(vh.gpa, args_in[i]) catch vh.oom();
                sync_args.appendSlice(vh.gpa, &.{ a, args_in[i] }) catch vh.oom();
                switch (t.f) {
                    .root => paths.root = args_in[i],
                    .cache => paths.cache = args_in[i],
                    .conf => paths.conf = args_in[i],
                }
            }
        }
    }
    if (mode == .update) pass.insert(vh.gpa, 0, "-u") catch vh.oom();
    if (mode == .fetch) pass.insert(vh.gpa, 0, "-D") catch vh.oom();

    // strict network mode (optional/strict-net): root opens the mirrors for a while
    if (paths.root == null and vh.pathExists("/etc/vh/optional/strict-net")) {
        if (vh.run(&.{ "/usr/local/sbin/vh-net", "xbps", "30" }) != 0) vh.die("vh-net xbps did not open the mirrors", .{});
    }

    xbpsInit(paths);
    const root = cstr(&xhp.rootdir);
    const cf = readConf(root);
    const jobs = jobs_opt orelse cf.jobs;

    // 1. repository sync, separately: in dry-run mode (-n) xbps-install does not sync them;
    // the path and repository options are the same as for the installation
    var sync_argv: std.ArrayList([]const u8) = .empty;
    sync_argv.appendSlice(vh.gpa, &.{ xbpsBin("xbps-install"), "-S" }) catch vh.oom();
    sync_argv.appendSlice(vh.gpa, sync_args.items) catch vh.oom();
    const src = vh.run(sync_argv.items);
    if (src != 0) vh.exit(src);

    // 2. the plan: the list of actions (xbps-install -n)
    var plan_argv: std.ArrayList([]const u8) = .empty;
    plan_argv.appendSlice(vh.gpa, &.{ xbpsBin("xbps-install"), "-n" }) catch vh.oom();
    for (pass.items) |a| if (!vh.eql(a, "-y") and !vh.eql(a, "--yes")) plan_argv.append(vh.gpa, a) catch vh.oom();
    var out: std.ArrayList(u8) = .empty;
    var err: std.ArrayList(u8) = .empty;
    const rc = vh.runOpts(plan_argv.items, .{ .out = &out, .err = &err });
    if (rc != 0) {
        vh.outs(out.items);
        vh.flush();
        _ = vh.writeAllFd(2, err.items) catch {};
        vh.exit(rc);
    }

    // 3. what to download: packages from remote repositories that are not in the cache yet
    const cache = cstr(&xhp.cachedir);
    var todo: std.ArrayList(Job) = .empty;
    var lines = mem.tokenizeScalar(u8, out.items, '\n');
    while (lines.next()) |line| {
        var f: [6][]const u8 = undefined;
        var n: usize = 0;
        var it = mem.tokenizeScalar(u8, line, ' ');
        while (it.next()) |w| : (n += 1) {
            if (n == f.len) break;
            f[n] = w;
        }
        if (n != 6) continue;
        const action = f[1];
        if (!vh.eql(action, "install") and !vh.eql(action, "update") and !vh.eql(action, "reinstall") and
            !vh.eql(action, "download")) continue;
        if (!vh.startsWith(f[3], "https://") and !vh.startsWith(f[3], "http://")) continue;
        const file = vh.fmt("{s}.{s}.xbps", .{ f[0], f[2] });
        const dest = vh.fmt("{s}/{s}", .{ cache, file });
        if (vh.pathExists(dest) and vh.pathExists(vh.fmt("{s}.sig2", .{dest}))) continue;
        todo.append(vh.gpa, .{ .pkgver = f[0], .repo = f[3], .file = file, .size = std.fmt.parseInt(u64, f[5], 10) catch 0 }) catch vh.oom();
    }

    // 4. the parallel download
    if (todo.items.len > 0) {
        vh.mkdirs(cache, 0o755);
        download(todo.items, cache, @min(jobs, todo.items.len), cf);
    }

    // 5. the ordinary xbps-install: signature checks from the cache, installation, the policy
    c.xbps_end(&xhp);
    if (mode == .fetch) pass.append(vh.gpa, "-y") catch vh.oom();
    execWith("xbps-install", &.{}, pass.items);
}

/// A worker's result record: fixed size <= PIPE_BUF, so the pipe write is atomic.
const Result = extern struct {
    idx: u32,
    ok: u8,
    msg_len: u8,
    msg: [250]u8,
};

/// the mirror URL with the same path (.../current[/nonfree]), for the fallback mirrors
fn swapMirror(repo: []const u8, base: []const u8) ?[]const u8 {
    const p = mem.indexOf(u8, repo, "/current") orelse return null;
    return vh.fmt("{s}{s}", .{ base, repo[p..] });
}

fn download(todo: []const Job, cache: []const u8, nworkers: usize, cf: Conf) void {
    var total: u64 = 0;
    for (todo) |j| total += j.size;
    vh.out("Downloading {d} packages ({s}), workers: {d}, mirror: {s}\n", .{
        todo.len, human(total), nworkers, mirrorOf(todo[0].repo),
    });
    vh.flush();
    const t0 = now();

    var jp: [2]vh.fd_t = undefined;
    var rp: [2]vh.fd_t = undefined;
    _ = vh.sys(linux.pipe2(&jp, .{ .CLOEXEC = true })) catch vh.die("pipe: {s}", .{vh.serr()});
    _ = vh.sys(linux.pipe2(&rp, .{ .CLOEXEC = true })) catch vh.die("pipe: {s}", .{vh.serr()});

    var pids: [max_jobs]linux.pid_t = undefined;
    const rate_each: u64 = if (cf.ratelimit > 0) @max(cf.ratelimit * 1024 / nworkers, 1) else 0;
    for (0..nworkers) |w| {
        vh.flush();
        const pid = vh.sys(linux.fork()) catch vh.die("fork: {s}", .{vh.serr()});
        if (pid == 0) {
            vh.close(jp[1]);
            vh.close(rp[0]);
            worker(todo, cache, jp[0], rp[1], rate_each, cf.fallback.items);
        }
        pids[w] = @intCast(pid);
    }
    vh.close(jp[0]);
    vh.close(rp[1]);
    // all jobs at once: the workers take them one by one (4 bytes), whoever is free
    for (0..todo.len) |k| {
        const idx: u32 = @intCast(k);
        vh.writeAllFd(jp[1], mem.asBytes(&idx)) catch vh.die("job pipe: {s}", .{vh.serr()});
    }
    vh.close(jp[1]);

    var done: usize = 0;
    var failed: usize = 0;
    var got: u64 = 0;
    while (true) {
        var r: Result = undefined;
        const n = vh.readFd(rp[0], mem.asBytes(&r)) catch break;
        if (n == 0) break;
        if (n != @sizeOf(Result)) vh.die("result pipe: truncated record", .{});
        done += 1;
        const j = todo[r.idx];
        if (r.ok == 1) {
            got += j.size;
            vh.out("  [{d}/{d}] {s}  {s}\n", .{ done, todo.len, j.pkgver, human(j.size) });
        } else {
            failed += 1;
            vh.out("  [{d}/{d}] {s}  NOT downloaded: {s}\n", .{ done, todo.len, j.pkgver, r.msg[0..r.msg_len] });
        }
        vh.flush();
    }
    vh.close(rp[0]);
    for (pids[0..nworkers]) |pid| {
        var st: u32 = 0;
        _ = linux.wait4(pid, @ptrCast(&st), 0, null);
    }
    const dt = @max(now() - t0, 0.001);
    vh.out("Downloaded {s} in {d:.1} s ({s}/s)", .{ human(got), dt, human(@intFromFloat(@as(f64, @floatFromInt(got)) / dt)) });
    if (failed > 0) vh.out("; {d} not downloaded: xbps-install will try itself", .{failed});
    vh.outs("\n\n");
    vh.flush();
}

fn now() f64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(f64, @floatFromInt(ts.sec)) + @as(f64, @floatFromInt(ts.nsec)) / 1e9;
}

fn mirrorOf(repo: []const u8) []const u8 {
    const p = mem.indexOf(u8, repo, "/current") orelse return repo;
    return repo[0..p];
}

fn human(b: u64) []const u8 {
    const f: f64 = @floatFromInt(b);
    if (b >= 1 << 30) return vh.fmt("{d:.1} GB", .{f / (1 << 30)});
    if (b >= 1 << 20) return vh.fmt("{d:.1} MB", .{f / (1 << 20)});
    if (b >= 1 << 10) return vh.fmt("{d:.0} KB", .{f / (1 << 10)});
    return vh.fmt("{d} B", .{b});
}

// --- the worker (a separate process)

var rl_rate: u64 = 0;
var rl_start: f64 = 0;
var rl_bytes: u64 = 0;
var rl_file_last: i64 = 0;

/// rate limiting: the libxbps progress callback pauses when the worker is ahead of its quota
fn fetchCb(xfcd: [*c]const c.struct_xbps_fetch_cb_data, _: ?*anyopaque) callconv(.c) void {
    if (rl_rate == 0) return;
    const d = xfcd.*;
    if (d.cb_start) rl_file_last = 0;
    if (!d.cb_update) return;
    const dl: i64 = d.file_dloaded;
    if (dl > rl_file_last) rl_bytes += @intCast(dl - rl_file_last);
    rl_file_last = dl;
    const want = @as(f64, @floatFromInt(rl_bytes)) / @as(f64, @floatFromInt(rl_rate));
    const ahead = want - (now() - rl_start);
    if (ahead > 0.01) {
        const ns: u64 = @intFromFloat(ahead * 1e9);
        var ts: linux.timespec = .{ .sec = @intCast(ns / 1_000_000_000), .nsec = @intCast(ns % 1_000_000_000) };
        _ = linux.nanosleep(&ts, null);
    }
}

fn worker(todo: []const Job, cache: []const u8, jfd: vh.fd_t, rfd: vh.fd_t, rate: u64, fallback: []const []const u8) noreturn {
    // stay out of the way: low CPU and disk priority (ioprio best-effort, 7)
    _ = linux.syscall3(.setpriority, 0, 0, 10);
    _ = linux.syscall3(.ioprio_set, 1, 0, (2 << 13) | 7);
    rl_rate = rate;
    rl_start = now();
    xhp.fetch_cb = fetchCb;
    while (true) {
        var idx: u32 = undefined;
        const n = vh.readFd(jfd, mem.asBytes(&idx)) catch break;
        if (n != @sizeOf(u32)) break;
        const j = todo[idx];
        var r: Result = .{ .idx = idx, .ok = 0, .msg_len = 0, .msg = undefined };
        var why: []const u8 = "";
        // the main mirror, then the fallbacks; the .sig2 signature last: xbps counts a package
        // as downloaded only when both the package and the signature are there
        var tries: std.ArrayList([]const u8) = .empty;
        tries.append(vh.gpa, j.repo) catch vh.oom();
        for (fallback) |fb| if (swapMirror(j.repo, fb)) |u| tries.append(vh.gpa, u) catch vh.oom();
        for (tries.items) |repo| {
            const dest = vh.fmt("{s}/{s}", .{ cache, j.file });
            if (fetch(vh.fmt("{s}/{s}", .{ repo, j.file }), dest) and
                fetch(vh.fmt("{s}/{s}.sig2", .{ repo, j.file }), vh.fmt("{s}.sig2", .{dest})))
            {
                r.ok = 1;
                break;
            }
            why = vh.fmt("{s}: {s}", .{ mirrorOf(repo), fetchErr() });
        }
        if (r.ok == 0) {
            const m = why[0..@min(why.len, r.msg.len)];
            @memcpy(r.msg[0..m.len], m);
            r.msg_len = @intCast(m.len);
        }
        vh.writeAllFd(rfd, mem.asBytes(&r)) catch break;
    }
    linux.exit_group(0);
}

/// the text of the last libxbps download error (NULL means a non-network error: errno)
fn fetchErr() []const u8 {
    const e = c.xbps_fetch_error_string();
    if (e != null) return mem.span(e);
    vh.errno = @enumFromInt(@as(u16, @intCast(std.c._errno().*)));
    return vh.serr();
}

fn fetch(url: []const u8, dest: []const u8) bool {
    return c.xbps_fetch_file_dest(&xhp, vh.z(url).ptr, vh.z(dest).ptr, null) >= 0;
}

// ---------------------------------------------------------------- mirrors

const Probe = struct { base: []const u8, rtt: f64 = -1, speed: f64 = -1 };

/// The TCP connect time to port 443 (no TLS): a rough latency filter.
fn tcpRtt(host: []const u8) f64 {
    var hints = mem.zeroes(std.c.addrinfo);
    hints.socktype = std.c.SOCK.STREAM;
    var res: ?*std.c.addrinfo = null;
    if (@intFromEnum(std.c.getaddrinfo(vh.z(host).ptr, "443", &hints, &res)) != 0) return -1;
    defer std.c.freeaddrinfo(res.?);
    const ai = res.?;
    const fd_rc = linux.socket(@intCast(ai.family), linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
    const fd: vh.fd_t = @intCast(vh.sys(fd_rc) catch return -1);
    defer vh.close(fd);
    const t0 = now();
    const rc = linux.connect(fd, @ptrCast(ai.addr.?), ai.addrlen);
    const e = linux.errno(rc);
    if (e != .SUCCESS and e != .INPROGRESS) return -1;
    var p = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.OUT, .revents = 0 }};
    const n = linux.poll(&p, 1, 3000);
    if (linux.errno(n) != .SUCCESS or n == 0) return -1;
    var soerr: i32 = 0;
    var len: linux.socklen_t = @sizeOf(i32);
    _ = linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.ERROR, @ptrCast(&soerr), &len);
    if (soerr != 0) return -1;
    return now() - t0;
}

fn hostOf(base: []const u8) []const u8 {
    const s = if (mem.indexOf(u8, base, "://")) |p| base[p + 3 ..] else base;
    return s[0 .. mem.indexOfScalar(u8, s, '/') orelse s.len];
}

fn mirror(args: []const [:0]const u8) void {
    var write = false;
    for (args) |a| {
        if (vh.eql(a, "--write")) write = true else usage();
    }
    if (write) needRoot("mirror");
    xbpsInit(.{});
    const arch = cstr(&xhp.native_arch);
    // the repository directory for the architecture, as in Void: x86_64 is current, musl is
    // current/musl, everything else current/ARCH
    const sub = if (vh.eql(arch, "x86_64")) "" else if (vh.endsWith(arch, "-musl")) "/musl" else vh.fmt("/{s}", .{arch});

    vh.out("Latency to {d} HTTPS mirrors (TCP, port 443)...\n", .{mirrors.len});
    vh.flush();
    var probes: [mirrors.len]Probe = undefined;
    for (mirrors, 0..) |m, i| probes[i] = .{ .base = m, .rtt = tcpRtt(hostOf(m)) };
    std.mem.sort(Probe, &probes, {}, struct {
        fn lt(_: void, a: Probe, b: Probe) bool {
            if (a.rtt < 0) return false;
            if (b.rtt < 0) return true;
            return a.rtt < b.rtt;
        }
    }.lt);

    // speed: the repository index (a few MB) from the nearest mirrors, up to 4 that answer (10 attempts)
    const tmp = "/var/tmp/thor-mirror";
    vh.mkdirs(tmp, 0o700);
    vh.out("Speed (the {s}-repodata index) from the nearest:\n", .{arch});
    vh.flush();
    var tested: usize = 0;
    var answered: usize = 0;
    for (&probes) |*p| {
        if (p.rtt < 0 or tested == 10 or answered == 4) continue;
        tested += 1;
        const url = vh.fmt("{s}/current{s}/{s}-repodata", .{ p.base, sub, arch });
        const dest = vh.fmt("{s}/repodata", .{tmp});
        vh.unlink(dest) catch {};
        vh.unlink(vh.fmt("{s}.part", .{dest})) catch {};
        const t0 = now();
        if (fetch(url, dest)) {
            const st = vh.stat(dest, false) catch continue;
            p.speed = @as(f64, @floatFromInt(st.size)) / @max(now() - t0, 0.001);
        }
        if (p.speed > 0) answered += 1;
        if (p.speed > 0)
            vh.out("  {s:<48} {d:>5.0} ms  {s}/s\n", .{ p.base, p.rtt * 1000, human(@intFromFloat(p.speed)) })
        else
            vh.out("  {s:<48} {d:>5.0} ms  error: {s}\n", .{ p.base, p.rtt * 1000, fetchErr() });
        vh.flush();
    }
    _ = vh.run(&.{ "rm", "-rf", tmp });
    var best: std.ArrayList(Probe) = .empty;
    for (probes) |p| if (p.speed > 0) best.append(vh.gpa, p) catch vh.oom();
    if (best.items.len == 0) vh.die("no mirror answered: check the network", .{});
    std.mem.sort(Probe, best.items, {}, struct {
        fn gt(_: void, a: Probe, b: Probe) bool {
            return a.speed > b.speed;
        }
    }.gt);
    vh.out("\nBest: {s}\n", .{best.items[0].base});
    if (!write) {
        vh.outs("To write it into /etc/xbps.d and /etc/thor/thor.conf: doas thor mirror --write\n");
        return vh.flush();
    }
    writeMirrors(best.items);
}

/// repository= in every /etc/xbps.d/*.conf (main, nonfree; comments are kept) and the
/// fallback mirrors in /etc/thor/thor.conf
fn writeMirrors(best: []const Probe) void {
    const dir = "/etc/xbps.d";
    const names = vh.listDir(dir) catch vh.die("{s}: {s}", .{ dir, vh.serr() });
    var changed: usize = 0;
    for (names) |name| {
        if (!vh.endsWith(name, ".conf")) continue;
        const path = vh.fmt("{s}/{s}", .{ dir, name });
        if (!vh.isRegular(path)) continue;
        const old = vh.readFile(path) catch continue;
        var out: std.ArrayList(u8) = .empty;
        var n: usize = 0;
        var it = mem.splitScalar(u8, mem.trimEnd(u8, old, "\n"), '\n');
        while (it.next()) |line| {
            if (vh.startsWith(line, "repository=http")) {
                // local repositories (thor) and foreign paths without /current stay as they are
                if (swapMirror(line["repository=".len..], best[0].base)) |u| {
                    out.print(vh.gpa, "repository={s}\n", .{u}) catch vh.oom();
                    n += 1;
                    continue;
                }
            }
            out.print(vh.gpa, "{s}\n", .{line}) catch vh.oom();
        }
        if (n == 0) continue;
        vh.writeAtomic(path, out.items, 0o644);
        vh.out("  {s}: {s}\n", .{ path, best[0].base });
        changed += 1;
    }
    if (changed == 0) vh.outs("  no repository= lines with a Void mirror in /etc/xbps.d: nothing changed\n");

    var tc: std.ArrayList(u8) = .empty;
    const prev = vh.readFile(conf_path) catch "";
    var lit = mem.splitScalar(u8, mem.trimEnd(u8, prev, "\n"), '\n');
    while (lit.next()) |line| {
        if (line.len == 0 or vh.startsWith(vh.strip(line), "mirror-fallback")) continue;
        tc.print(vh.gpa, "{s}\n", .{line}) catch vh.oom();
    }
    if (prev.len == 0) tc.appendSlice(vh.gpa, "# thor (docs/18): parallel=N (1-8), ratelimit=KB/s (0 means no limit),\n# mirror-fallback=URL: fallback mirrors (thor mirror --write)\n") catch vh.oom();
    for (best[1..@min(best.len, 4)]) |p| {
        tc.print(vh.gpa, "mirror-fallback={s}\n", .{p.base}) catch vh.oom();
        vh.out("  fallback: {s}\n", .{p.base});
    }
    vh.mkdirs("/etc/thor", 0o755);
    vh.writeAtomic(conf_path, tc.items, 0o644);
    if (vh.pathExists("/etc/vh/optional/strict-net"))
        vh.outs("  strict network mode: vh-net xbps opens the new mirrors at the next run\n");
    vh.flush();
}

// ---------------------------------------------------------------- policy exceptions

/// a line into a file unless it is already there; the first line of a new file is the header
fn appendUnique(path: []const u8, line: []const u8, header: []const u8) bool {
    const text = vh.readFile(path) catch "";
    var it = mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |l| if (vh.eql(l, line)) return false;
    var b: std.ArrayList(u8) = .empty;
    if (text.len == 0) {
        b.print(vh.gpa, "{s}\n", .{header}) catch vh.oom();
    } else {
        b.appendSlice(vh.gpa, text) catch vh.oom();
        if (text[text.len - 1] != '\n') b.append(vh.gpa, '\n') catch vh.oom();
    }
    b.print(vh.gpa, "{s}\n", .{line}) catch vh.oom();
    vh.mkdirs(std.fs.path.dirname(path).?, 0o755);
    vh.writeAtomic(path, b.items, 0o644);
    return true;
}

fn addList(args: []const [:0]const u8, path: []const u8, kind: enum { keep, allow }) void {
    needRoot(if (kind == .keep) "keep" else "allow");
    if (args.len == 0) usage();
    for (args) |a| {
        switch (kind) {
            .keep => {
                if (a.len == 0 or a[0] != '/') vh.die("{s}: a full path is required", .{a});
                const hdr = "# thor: paths the policy leaves alone: SUID, hooks, dracut modules, sysctl.d, udev (docs/18)";
                if (appendUnique(path, a, hdr))
                    vh.out("{s}: the policy leaves it alone; to get the file extracted, reinstall the package:\n   doas xbps-install -f $(xbps-query -o {s} | cut -d: -f1)\n", .{ a, a })
                else
                    vh.out("{s}: already in {s}\n", .{ a, path });
            },
            .allow => {
                const why = rules.denyReason(a) orelse {
                    vh.out("{s}: not on the deny list, nothing to allow\n", .{a});
                    continue;
                };
                vh.out("{s} is on the deny list: {s}\n", .{ a, why });
                if (!vh.ask("Allow installing and updating this package?", false)) vh.die("cancelled", .{});
                const hdr = "# thor: deny-list packages the admin allowed (docs/18)";
                if (appendUnique(path, a, hdr)) vh.out("{s}: allowed\n", .{a}) else vh.out("{s}: already allowed\n", .{a});
            },
        }
    }
    vh.flush();
}

// ---------------------------------------------------------------- the baseline

const Base = struct { list: std.ArrayList([]const u8) = .empty };

fn addBase(b: *Base, s: []const u8) void {
    for (b.list.items) |x| if (vh.eql(x, s)) return;
    b.list.append(vh.gpa, vh.dupe(s)) catch vh.oom();
}

fn baselinePkg(h: ?*c.struct_xbps_handle, obj: c.xbps_object_t, key: [*c]const u8, arg: ?*anyopaque, done: [*c]bool) callconv(.c) c_int {
    _ = obj;
    _ = done;
    const b: *Base = @ptrCast(@alignCast(arg.?));
    const filesd = c.xbps_pkgdb_get_pkg_files(h, key);
    if (filesd == null) return 0;
    for ([_][*:0]const u8{ "files", "conf_files" }) |kind| {
        const a: c.xbps_array_t = @ptrCast(c.xbps_dictionary_get(filesd, kind));
        var i: c_uint = 0;
        while (i < c.xbps_array_count(a)) : (i += 1) {
            var file: [*c]const u8 = null;
            const d: c.xbps_dictionary_t = @ptrCast(c.xbps_array_get(a, i));
            _ = c.xbps_dictionary_get_cstring_nocopy(d, "file", &file);
            if (file == null) continue;
            const p = mem.span(file);
            if (rules.isKernelHook(p) or rules.isLoginScript(p) or rules.isSysctl(p)) {
                addBase(b, p);
            } else if (rules.dracutModule(p)) |m| {
                addBase(b, m);
            } else if (rules.isUdevRule(p)) {
                const text = vh.readFile(vh.fmt("{s}{s}", .{ mem.trimEnd(u8, cstr(&xhp.rootdir), "/"), p })) catch continue;
                if (rules.udevWorldMode(text)) addBase(b, p);
            }
        }
    }
    return 0;
}

fn baseline(args: []const [:0]const u8) void {
    needRoot("baseline");
    var paths: XbpsPaths = .{};
    if (args.len == 2 and (vh.eql(args[0], "-r") or vh.eql(args[0], "--rootdir"))) paths.root = args[1] else if (args.len != 0) usage();
    xbpsInit(paths);
    var b: Base = .{};
    const rv = c.xbps_pkgdb_foreach_cb(&xhp, baselinePkg, &b);
    if (rv != 0) {
        vh.errno = @enumFromInt(rv);
        vh.die("pkgdb: {s}", .{vh.serr()});
    }
    std.mem.sort([]const u8, b.list.items, {}, vh.lessStr);
    var text: std.ArrayList(u8) = .empty;
    text.appendSlice(vh.gpa, "# thor: hooks, dracut modules, login scripts, sysctl.d files and udev rules of the base\n# system that the policy leaves alone (docs/18). Written by thor baseline.\n") catch vh.oom();
    for (b.list.items) |p| text.print(vh.gpa, "{s}\n", .{p}) catch vh.oom();
    const root = mem.trimEnd(u8, cstr(&xhp.rootdir), "/");
    const dst = vh.fmt("{s}/etc/thor/baseline", .{root});
    vh.mkdirs(vh.fmt("{s}/etc/thor", .{root}), 0o755);
    vh.writeAtomic(dst, text.items, 0o644);
    vh.out("{s}: {d} entries\n", .{ dst, b.list.items.len });
    vh.flush();
}

fn showPolicy() void {
    const mode_text = vh.readFile("/etc/thor/policy.conf") catch "";
    const learn = mem.indexOf(u8, mode_text, "mode=learn") != null;
    vh.out("mode: {s}\n", .{if (learn) "learn (system installation: base hooks are recorded in the baseline)" else "enforce"});
    for ([_][]const u8{ "/etc/thor/baseline", "/etc/thor/keep.conf", "/etc/thor/allow.conf" }) |p| {
        const t = vh.readFile(p) catch {
            vh.out("{s}: none\n", .{p});
            continue;
        };
        var n: usize = 0;
        var it = mem.tokenizeScalar(u8, t, '\n');
        while (it.next()) |l| {
            if (l.len > 0 and l[0] != '#') n += 1;
        }
        vh.out("{s}: {d}\n", .{ p, n });
    }
    vh.outs("SUID/SGID allowed: ");
    for (rules.suid_allowed, 0..) |s, i| vh.out("{s}{s}", .{ if (i > 0) " " else "", s });
    vh.outs("\ncapabilities allowed: ");
    for (rules.caps_allowed, 0..) |s, i| vh.out("{s}{s}", .{ if (i > 0) " " else "", s });
    vh.out("\ndeny list: {d} packages (thor allow NAME to allow one)\nlog: /var/log/thor.log\n", .{rules.deny.len});
    vh.flush();
}

test "swapMirror" {
    try std.testing.expectEqualStrings("https://b/current/nonfree", swapMirror("https://a/x/current/nonfree", "https://b").?);
    try std.testing.expect(swapMirror("https://a/repo", "https://b") == null);
    try std.testing.expectEqualStrings("repo-fi.voidlinux.org", hostOf("https://repo-fi.voidlinux.org"));
    try std.testing.expectEqualStrings("mirror.yandex.ru", hostOf("https://mirror.yandex.ru/mirrors/voidlinux"));
}
