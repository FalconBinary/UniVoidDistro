//! thor: the void-hardperf-light security policy inside libxbps (docs/18).
//!
//! Built into the object file thor_policy.o and linked into libxbps (the patch
//! patches/0001-thor-policy-hooks.patch), so it applies in every xbps-* program:
//! xbps-install, xbps-remove, xbps-reconfigure and thor itself. Calling xbps-install
//! directly does not bypass it.
//!
//! What it does:
//!  * SUID/SGID: stripped before the file reaches the disk. Only doas and unix_chkpwd
//!    (without it swaylock cannot check the password) and the paths in /etc/thor/keep.conf
//!    are allowed. What INSTALL scripts set (chmod u+s, setcap) is stripped after configuration.
//!  * /etc/kernel.d hooks (run as root at every UKI build), dracut modules (they would end
//!    up in the initramfs), /etc/profile.d and bashrc.d scripts (run in every shell) are not
//!    extracted unless they are in the baseline /etc/thor/baseline;
//!  * sysctl.d files of packages are masked by a same-named file in /etc/sysctl.d (a 99-*
//!    file of a package would override 30-vh-hardening);
//!  * udev rules with MODE 0666/0777 (a device for everyone) are masked;
//!  * packages on the deny list (compilers, polkit, cups...) cancel the transaction, also on
//!    updates; permission comes from /etc/thor/allow.conf (thor allow NAME).
//!
//! The baseline: while the system is being installed the policy runs in learn mode
//! (/etc/thor/policy.conf: mode=learn): hooks, modules and rules of the base system packages
//! are not neutralised but recorded in the baseline. Then the installer sets mode=enforce.
//! SUID/SGID, capabilities and the deny list apply in both modes.
//!
//! No libc: Linux system calls only. Policy errors never abort the transaction: they are
//! reported on stderr and the file is neutralised (failing towards the safe side).
const std = @import("std");
const linux = std.os.linux;
const mem = std.mem;
const rules = @import("rules.zig");
const denyReason = rules.denyReason;
const suid_allowed = rules.suid_allowed;
const caps_allowed = rules.caps_allowed;
const base = rules.base;
const isKernelHook = rules.isKernelHook;
const dracutModule = rules.dracutModule;
const isLoginScript = rules.isLoginScript;
const isSysctl = rules.isSysctl;
const isUdevRule = rules.isUdevRule;
const udevWorldMode = rules.udevWorldMode;

const THOR_EXTRACT: c_int = 0;
const THOR_SKIP: c_int = 1;

// ---------------------------------------------------------------- state

var cfg_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
var tmp_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);

const Config = struct {
    root: []const u8 = "",
    learn: bool = false,
    baseline: std.StringHashMapUnmanaged(void) = .empty,
    keep: std.StringHashMapUnmanaged(void) = .empty,
    allow: std.StringHashMapUnmanaged(void) = .empty,
};
var cfg: ?Config = null;

/// The policy config for an installation root (loaded once per process).
fn config(rootdir: []const u8) *Config {
    if (cfg) |*c| if (mem.eql(u8, c.root, rootdir)) return c;
    _ = cfg_arena.reset(.free_all);
    const a = cfg_arena.allocator();
    var c: Config = .{ .root = a.dupe(u8, rootdir) catch oom() };
    if (readFile(a, join(a, rootdir, "/etc/thor/policy.conf"))) |text| {
        var it = mem.tokenizeScalar(u8, text, '\n');
        while (it.next()) |raw| {
            const line = mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const eq = mem.indexOfScalar(u8, line, '=') orelse continue;
            const k = mem.trim(u8, line[0..eq], " \t");
            const v = mem.trim(u8, line[eq + 1 ..], " \t\"");
            if (mem.eql(u8, k, "mode")) c.learn = mem.eql(u8, v, "learn");
        }
    }
    loadList(a, &c.baseline, join(a, rootdir, "/etc/thor/baseline"));
    loadList(a, &c.keep, join(a, rootdir, "/etc/thor/keep.conf"));
    loadList(a, &c.allow, join(a, rootdir, "/etc/thor/allow.conf"));
    cfg = c;
    return &cfg.?;
}

/// one entry per line; "#" starts a comment
fn loadList(a: mem.Allocator, set: *std.StringHashMapUnmanaged(void), path: [:0]const u8) void {
    const text = readFile(a, path) orelse return;
    var it = mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        set.put(a, line, {}) catch oom();
    }
}

fn oom() noreturn {
    @panic("thor policy: out of memory");
}

// ---------------------------------------------------------------- system calls

fn join(a: mem.Allocator, root: []const u8, path: []const u8) [:0]const u8 {
    const r = mem.trimEnd(u8, root, "/");
    return std.fmt.allocPrintSentinel(a, "{s}{s}", .{ r, path }, 0) catch oom();
}

fn ok(rc: usize) bool {
    return linux.errno(rc) == .SUCCESS;
}

fn openRetry(path: [:0]const u8, flags: linux.O, mode: linux.mode_t) ?linux.fd_t {
    var f = flags;
    f.CLOEXEC = true;
    while (true) {
        const rc = linux.open(path.ptr, f, mode);
        switch (linux.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => return null,
        }
    }
}

fn readFile(a: mem.Allocator, path: [:0]const u8) ?[]u8 {
    const fd = openRetry(path, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0) orelse return null;
    defer _ = linux.close(fd);
    var b: std.ArrayList(u8) = .empty;
    while (true) {
        b.ensureUnusedCapacity(a, 65536) catch oom();
        const rc = linux.read(fd, b.unusedCapacitySlice().ptr, 65536);
        switch (linux.errno(rc)) {
            .SUCCESS => if (rc == 0) break else {
                b.items.len += rc;
            },
            .INTR => continue,
            else => return null,
        }
        if (b.items.len > 16 << 20) return null; // a config or udev rule above 16 MB is not our case
    }
    return b.items;
}

fn writeAll(fd: linux.fd_t, data: []const u8) bool {
    var p = data;
    while (p.len > 0) {
        const rc = linux.write(fd, p.ptr, p.len);
        switch (linux.errno(rc)) {
            .SUCCESS => p = p[rc..],
            .INTR => continue,
            else => return false,
        }
    }
    return true;
}

fn lstatMode(path: [:0]const u8) ?u32 {
    var st: linux.Statx = undefined;
    if (!ok(linux.statx(linux.AT.FDCWD, path.ptr, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .MODE = true }, &st))) return null;
    return st.mode;
}

fn exists(path: [:0]const u8) bool {
    return lstatMode(path) != null;
}

/// the directories on the way to a file, like mkdir -p
fn mkdirs(a: mem.Allocator, dir: []const u8) void {
    var i: usize = 1;
    while (i <= dir.len) : (i += 1) {
        if (i < dir.len and dir[i] != '/') continue;
        const p = a.dupeSentinel(u8, dir[0..i], 0) catch oom();
        _ = linux.mkdir(p.ptr, 0o755);
    }
}

/// Append a line to a file (created with a header); O_NOFOLLOW, never through a symlink.
fn appendLine(a: mem.Allocator, path: [:0]const u8, header: []const u8, line: []const u8) void {
    mkdirs(a, std.fs.path.dirname(path) orelse "/");
    const fd = openRetry(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .NOFOLLOW = true }, 0o644) orelse {
        say("{s}: could not write", .{path});
        return;
    };
    defer _ = linux.close(fd);
    var st: linux.Statx = undefined;
    if (ok(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .SIZE = true }, &st)) and st.size == 0)
        _ = writeAll(fd, header);
    _ = writeAll(fd, std.fmt.allocPrint(a, "{s}\n", .{line}) catch oom());
}

/// A new file (never overwrites an existing one): the mask for udev/sysctl.
fn createFile(a: mem.Allocator, path: [:0]const u8, text: []const u8) bool {
    mkdirs(a, std.fs.path.dirname(path) orelse "/");
    const fd = openRetry(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true }, 0o644) orelse return false;
    defer _ = linux.close(fd);
    return writeAll(fd, text);
}

// ---------------------------------------------------------------- reporting

/// a message on stderr: "thor: ..."
fn say(comptime f: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "thor: " ++ f ++ "\n", args) catch return;
    _ = writeAll(2, s);
}

/// a policy action: on stderr and in the log /var/log/thor.log
fn act(c: *Config, pkgver: []const u8, comptime f: []const u8, args: anytype) void {
    const a = tmp_arena.allocator();
    const msg = std.fmt.allocPrint(a, f, args) catch oom();
    say("{s}: {s}", .{ pkgver, msg });
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(ts.sec, 0)) };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    const line = std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} {s}: {s}", .{
        day.year,                 md.month.numeric(),         md.day_index + 1,
        ds.getHoursIntoDay(),     ds.getMinutesIntoHour(),    ds.getSecondsIntoMinute(),
        pkgver,                   msg,
    }) catch oom();
    appendLine(a, join(a, c.root, "/var/log/thor.log"), "", line);
}

/// learn mode: the path goes into the baseline
fn learn(c: *Config, path: []const u8) void {
    if (c.baseline.contains(path)) return;
    const a = cfg_arena.allocator();
    const p = a.dupe(u8, path) catch oom();
    c.baseline.put(a, p, {}) catch oom();
    appendLine(tmp_arena.allocator(), join(tmp_arena.allocator(), c.root, "/etc/thor/baseline"),
        "# thor: hooks, dracut modules, login scripts, sysctl.d files and udev rules of the base\n" ++
        "# system that the policy leaves alone (docs/18). Written during installation (mode=learn).\n", path);
}

fn allowed(c: *Config, key: []const u8) bool {
    return c.baseline.contains(key) or c.keep.contains(key);
}

/// an empty same-named file in /etc masks the package's file (udev, sysctl)
fn mask(c: *Config, path: []const u8, dst_dir: []const u8, why: []const u8) []const u8 {
    const a = tmp_arena.allocator();
    const dst = std.fmt.allocPrint(a, "{s}/{s}", .{ dst_dir, base(path) }) catch oom();
    const text = std.fmt.allocPrint(a, "# void-hardperf-light (thor): masks {s}: {s}\n", .{ path, why }) catch oom();
    const full = join(a, c.root, dst);
    if (exists(full)) return std.fmt.allocPrint(a, "{s} already exists", .{dst}) catch oom();
    if (!createFile(a, full, text)) return std.fmt.allocPrint(a, "NOT masked: could not create {s}", .{dst}) catch oom();
    return std.fmt.allocPrint(a, "masked by {s}", .{dst}) catch oom();
}

// ---------------------------------------------------------------- entry points (C)

fn span(p: [*:0]const u8) []const u8 {
    return mem.span(p);
}

export fn thor_unpack_entry(rootdir_c: [*:0]const u8, pkgver_c: [*:0]const u8, path_c: [*:0]const u8, mode: *c_uint) c_int {
    defer _ = tmp_arena.reset(.retain_capacity);
    const c = config(span(rootdir_c));
    const pkgver = span(pkgver_c);
    const path = span(path_c);

    // SUID/SGID: before the file reaches the disk, in either mode
    const m: u32 = mode.*;
    if (m & 0o170000 == 0o100000 and m & 0o6000 != 0) {
        const keep = for (suid_allowed) |s| {
            if (mem.eql(u8, s, path)) break true;
        } else c.keep.contains(path);
        if (!keep) {
            mode.* = m & ~@as(c_uint, 0o6000);
            act(c, pkgver, "SUID/SGID stripped: {s} (root runs it without the bit anyway)", .{path});
        }
    }

    const key: ?[]const u8 = if (isKernelHook(path) or isLoginScript(path)) path else dracutModule(path);
    if (key) |k| {
        if (allowed(c, k)) return THOR_EXTRACT;
        if (c.learn) {
            learn(c, k);
            return THOR_EXTRACT;
        }
        const why = if (isKernelHook(path))
            "kernel hook: runs as root at every UKI build"
        else if (isLoginScript(path))
            "login script: would run in every shell, including the admin's"
        else
            "dracut module: would end up in the initramfs";
        act(c, pkgver, "{s} not extracted: {s} (to allow it: doas thor keep {s})", .{ path, why, k });
        return THOR_SKIP;
    }

    if (isSysctl(path) and !allowed(c, path)) {
        if (c.learn) {
            learn(c, path);
        } else {
            const r = mask(c, path, "/etc/sysctl.d", "would override the hardening sysctls");
            act(c, pkgver, "sysctl {s}: {s}", .{ path, r });
        }
    }
    return THOR_EXTRACT;
}

export fn thor_after_extract(rootdir_c: [*:0]const u8, pkgver_c: [*:0]const u8, path_c: [*:0]const u8) void {
    defer _ = tmp_arena.reset(.retain_capacity);
    const path = span(path_c);
    if (!isUdevRule(path)) return;
    const c = config(span(rootdir_c));
    if (allowed(c, path)) return;
    const a = tmp_arena.allocator();
    const full = join(a, c.root, path);
    const mode = lstatMode(full) orelse return;
    if (mode & 0o170000 != 0o100000) return;
    const text = readFile(a, full) orelse return;
    if (!udevWorldMode(text)) return;
    if (c.learn) {
        learn(c, path);
        return;
    }
    const pkgver = span(pkgver_c);
    if (mem.startsWith(u8, path, "/etc/")) {
        // a file in /etc cannot be masked, so it is deleted (an update extracts it again,
        // and the policy deletes it again)
        _ = linux.unlink(full.ptr);
        act(c, pkgver, "udev {s}: gives the device to everyone (MODE 0666): deleted", .{path});
    } else {
        const r = mask(c, path, "/etc/udev/rules.d", "a device for everyone");
        act(c, pkgver, "udev {s}: gives the device to everyone (MODE 0666): {s}", .{ path, r });
    }
}

export fn thor_transaction_pkg(rootdir_c: [*:0]const u8, pkgname_c: [*:0]const u8, reason: *?[*:0]const u8) c_int {
    const c = config(span(rootdir_c));
    const name = span(pkgname_c);
    const why = denyReason(name) orelse return 0;
    if (c.allow.contains(name)) return 0;
    reason.* = why.ptr;
    return 1;
}

export fn thor_post_file(rootdir_c: [*:0]const u8, pkgver_c: [*:0]const u8, path_c: [*:0]const u8, installed: c_int) void {
    defer _ = tmp_arena.reset(.retain_capacity);
    const c = config(span(rootdir_c));
    const pkgver = span(pkgver_c);
    const path = span(path_c);
    const a = tmp_arena.allocator();
    const full = join(a, c.root, path);
    const mode = lstatMode(full) orelse return;
    const reg = mode & 0o170000 == 0o100000;
    const keep = c.keep.contains(path) or for (suid_allowed) |s| {
        if (mem.eql(u8, s, path)) break true;
    } else false;

    if (reg and !keep) {
        // SUID/SGID set by an INSTALL script
        if (mode & 0o6000 != 0) {
            if (ok(linux.fchmodat(linux.AT.FDCWD, full.ptr, mode & 0o7777 & ~@as(u32, 0o6000)))) {
                act(c, pkgver, "SUID/SGID stripped: {s} (set by the package script)", .{path});
            } else {
                act(c, pkgver, "SUID/SGID NOT stripped: {s}; strip it by hand", .{path});
            }
        }
        // file capabilities (setcap in an INSTALL script)
        const caps_ok = for (caps_allowed) |s| {
            if (mem.eql(u8, s, path)) break true;
        } else false;
        var buf: [256]u8 = undefined;
        if (!caps_ok and ok(linux.lgetxattr(full.ptr, "security.capability", &buf, buf.len))) {
            if (ok(linux.lremovexattr(full.ptr, "security.capability"))) {
                act(c, pkgver, "capabilities stripped: {s}", .{path});
            } else {
                act(c, pkgver, "capabilities NOT stripped: {s}; run setcap -r {s}", .{ path, path });
            }
        }
    }
    if (installed == 0 or c.learn) return;

    // report only: in this system none of these start on their own (like the old vh-pkg)
    if (mem.startsWith(u8, path, "/etc/sv/") and mem.endsWith(u8, path, "/run") and path.len > 12 and
        mem.indexOfScalarPos(u8, path, 8, '/') == path.len - 4)
    {
        const svc = path[8 .. path.len - 4];
        const link = join(a, c.root, std.fmt.allocPrint(a, "/var/service/{s}", .{svc}) catch oom());
        say("{s}: runit service {s}: {s}", .{ pkgver, svc, if (exists(link)) "ENABLED; check whether it is needed" else "installed but not enabled (Void does not enable it itself)" });
    } else if (mem.startsWith(u8, path, "/usr/share/dbus-1/system-services/")) {
        say("{s}: D-Bus service {s}: will not start on its own (activation is off)", .{ pkgver, base(path) });
    } else if (mem.startsWith(u8, path, "/etc/xdg/autostart/") or mem.startsWith(u8, path, "/etc/cron")) {
        say("{s}: autostart {s}: RefursWM and runit do not run it", .{ pkgver, path });
    } else if (mem.startsWith(u8, path, "/usr/lib/modprobe.d/") or mem.startsWith(u8, path, "/etc/modprobe.d/")) {
        say("{s}: modprobe.d {s}: check it (modules_disabled, module_blacklist)", .{ pkgver, path });
    } else if (reg and isUdevRule(path) and !allowed(c, path)) {
        const text = readFile(a, full) orelse return;
        if (mem.indexOf(u8, text, "RUN=") != null or mem.indexOf(u8, text, "RUN+=") != null or
            mem.indexOf(u8, text, "MODE") != null or mem.indexOf(u8, text, "GROUP") != null or
            mem.indexOf(u8, text, "OWNER") != null)
            say("{s}: udev {s}: a permission/run rule; check it", .{ pkgver, path });
    }
}

test {
    _ = rules;
}
