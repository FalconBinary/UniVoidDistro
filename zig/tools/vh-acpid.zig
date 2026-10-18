//! vh-acpid: the lid and the power button without acpid and without suspend (docs/05, docs/12).
//!
//! Reads only two built-in ACPI input devices: "Lid Switch" (PNP0C0D) and "Power Button"
//! (LNXPWRBN / PNP0C0C). USB keyboards and virtual devices (uinput) are not listened to:
//! their events never get here.
//!
//!   lid closed                -> lock the everyday user's screen (swaylock);
//!   closed longer than LID_MIN -> regular poweroff (suspend is forbidden: the LUKS key is in
//!                                RAM, and a running laptop in a bag overheats);
//!   external monitor connected -> the lid does nothing (working with the lid closed);
//!   power button              -> POWER_KEY: poweroff (default) | lock | ignore;
//!   idle (IDLE_*_MIN > 0)     -> lock and regular poweroff after a time without PHYSICAL
//!                                input: only the built-in keyboard (i8042) and touchpad
//!                                (I2C-HID/PS2) count. The browser's idle-inhibit, USB devices
//!                                and uinput do not extend the session; a grabbed device
//!                                (EVIOCGRAB) = no input = poweroff, failing towards the safe side.
//!                                Off by default; optional/deadman enables it.
//!
//! The regular poweroff is /usr/bin/poweroff: runit stage 3 stops the services, flushes the
//! data and unmounts the file systems. A long press of the button (4 s) is a hardware
//! power-off that bypasses this daemon.
//!
//! Settings: /etc/vh/acpi.conf. Waiting is a blocking poll(): not a single wakeup at idle.
const std = @import("std");
const vh = @import("vh");
const linux = std.os.linux;
const mem = std.mem;

const CONF = "/etc/vh/acpi.conf";
const ENV = "/etc/vh/vh.env";
const MAX_DEV = 32;

const EV_KEY = 1;
const EV_SW = 5;
const SW_LID = 0;
const KEY_POWER = 116;
/// EVIOCGSW(8): _IOC(_IOC_READ, 'E', 0x1b, 8)
const EVIOCGSW8: u32 = (2 << 30) | (8 << 16) | (@as(u32, 'E') << 8) | 0x1b;

/// struct input_event on a 64-bit kernel: timeval + type + code + value
const InputEvent = extern struct { sec: i64, usec: i64, type: u16, code: u16, value: i32 };

const Kind = enum { lid, power, input };

fn now() f64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(f64, @floatFromInt(ts.sec)) + @as(f64, @floatFromInt(ts.nsec)) / 1e9;
}

/// What kind of input device this is: the lid, the power button (ACPI only), built-in input
/// for the idle watchdog (i8042, I2C-HID and explicitly named sysfs path parts), or nothing.
pub fn classify(name: []const u8, phys: []const u8, real: []const u8, extra: []const []const u8) ?Kind {
    const first = phys[0 .. mem.indexOfScalar(u8, phys, '/') orelse phys.len];
    var ext = false;
    for (extra) |e| ext = ext or mem.indexOf(u8, real, e) != null;
    if (vh.eql(name, "Lid Switch") and vh.startsWith(phys, "PNP0C0D/")) return .lid;
    if (vh.eql(name, "Power Button") and (vh.eql(first, "LNXPWRBN") or vh.eql(first, "PNP0C0C"))) return .power;
    if (mem.indexOf(u8, real, "/virtual/") != null) return null; // uinput and the like: not physical input
    if (vh.startsWith(phys, "isa0060/serio") or
        (mem.indexOf(u8, real, "/i2c-") != null and mem.indexOf(u8, real, "/usb") == null) or ext)
        return .input;
    return null;
}

const Found = struct { lid: ?[]const u8 = null, power: ?[]const u8 = null, builtin: vh.Strv = .{} };

/// /dev/input/eventN via /sys/class/input/event* (in glob order, by name)
fn findDevices(extra: []const []const u8) Found {
    var f: Found = .{};
    const all = vh.listDir("/sys/class/input") catch return f;
    var evs: vh.Strv = .{};
    for (all) |n| if (vh.startsWith(n, "event")) evs.add(n);
    evs.sort();
    for (evs.slice()) |e| {
        const ev = vh.fmt("/sys/class/input/{s}", .{e});
        const name = vh.rd(vh.fmt("{s}/device/name", .{ev}));
        const phys = vh.rd(vh.fmt("{s}/device/phys", .{ev}));
        const real = vh.realpath(vh.fmt("{s}/device", .{ev})) catch "";
        const node = vh.fmt("/dev/input/{s}", .{e});
        switch (classify(name, phys, real, extra) orelse continue) {
            .lid => if (f.lid == null) {
                f.lid = node;
            },
            .power => if (f.power == null) {
                f.power = node;
            },
            .input => f.builtin.add(node),
        }
    }
    return f;
}

fn lidClosed(fd: vh.fd_t) bool {
    var sw: [8]u8 = @splat(0);
    if (linux.errno(linux.ioctl(fd, EVIOCGSW8, @intFromPtr(&sw))) != .SUCCESS) return false;
    return sw[0] & (1 << SW_LID) != 0;
}

/// is an external monitor connected (working with the lid closed)
fn externalDisplay() bool {
    const dir = "/sys/class/drm";
    const names = vh.listDir(dir) catch return false;
    var sorted: vh.Strv = .{};
    for (names) |n| if (vh.startsWith(n, "card") and mem.indexOfScalar(u8, n, '-') != null) sorted.add(n);
    sorted.sort();
    for (sorted.slice()) |n| {
        const st = vh.fmt("{s}/{s}/status", .{ dir, n });
        if (!vh.pathExists(st)) continue;
        if (mem.indexOf(u8, st, "-eDP-") != null or mem.indexOf(u8, st, "-LVDS-") != null or mem.indexOf(u8, st, "-DSI-") != null) continue;
        if (vh.eql(vh.rd(st), "connected")) return true;
    }
    return false;
}

const Pw = struct { uid: u32, gid: u32, dir: []const u8 };

/// the /etc/passwd entry by name (like getpwnam)
fn getpwnam(user: []const u8) ?Pw {
    const pw = vh.readFile("/etc/passwd") catch return null;
    var lines = mem.tokenizeScalar(u8, pw, '\n');
    while (lines.next()) |l| {
        var f = mem.splitScalar(u8, l, ':');
        const name = f.next() orelse continue;
        if (!vh.eql(name, user)) continue;
        _ = f.next();
        const uid = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue;
        const gid = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue;
        _ = f.next();
        return .{ .uid = uid, .gid = gid, .dir = f.next() orelse continue };
    }
    return null;
}

/// swaylock in the user's session: their UID, GID and groups, a clean environment
fn lockSession(user: []const u8) void {
    const pw = (if (user.len > 0) getpwnam(user) else null) orelse return;
    const rt = vh.fmt("/run/user/{d}", .{pw.uid});
    const names = vh.listDir(rt) catch return;
    var socks: vh.Strv = .{};
    for (names) |n| if (vh.startsWith(n, "wayland-") and !vh.endsWith(n, ".lock")) socks.add(n);
    socks.sort();
    if (socks.len() == 0) return; // no session running: nothing to lock
    const argv = [_][]const u8{
        "/usr/bin/setpriv",                         vh.fmt("--reuid={d}", .{pw.uid}), vh.fmt("--regid={d}", .{pw.gid}),
        "--init-groups",                            "--reset-env",                    "--no-new-privs",
        "--",                                       "env",                            "-i",
        "PATH=/usr/bin",                            vh.fmt("HOME={s}", .{pw.dir}),     vh.fmt("XDG_RUNTIME_DIR={s}", .{rt}),
        vh.fmt("WAYLAND_DISPLAY={s}", .{socks.slice()[0]}), "swaylock",               "-f",
    };
    const cargv = vh.gpa.allocSentinel(?[*:0]const u8, argv.len, null) catch vh.oom();
    for (argv, 0..) |a, i| cargv[i] = vh.z(a).ptr;
    vh.flush();
    const rc = linux.fork();
    if (linux.errno(rc) != .SUCCESS) {
        vh.errno = linux.errno(rc);
        return vh.log("swaylock did not start: {s}", .{vh.serr()});
    }
    if (rc == 0) {
        const nul = linux.open("/dev/null", .{ .ACCMODE = .RDWR }, 0);
        if (linux.errno(nul) == .SUCCESS) {
            const fd: vh.fd_t = @intCast(nul);
            _ = linux.dup2(fd, 0);
            _ = linux.dup2(fd, 1);
            _ = linux.dup2(fd, 2);
        }
        vh.closeFdsFrom(3);
        _ = linux.execve(cargv[0].?, cargv.ptr, vh.envp);
        linux.exit_group(127);
    }
    // swaylock -f backgrounds itself once the screen is locked; wait at most 10 s
    const pid: linux.pid_t = @intCast(rc);
    const end = now() + 10;
    var st: u32 = 0;
    while (linux.wait4(pid, @ptrCast(&st), linux.W.NOHANG, null) == 0) {
        if (now() >= end) {
            _ = linux.kill(pid, .KILL);
            _ = linux.wait4(pid, @ptrCast(&st), 0, null);
            vh.log("swaylock did not start: timeout", .{});
            break;
        }
        var ts: linux.timespec = .{ .sec = 0, .nsec = 50 * 1000 * 1000 };
        _ = linux.nanosleep(&ts, null);
    }
}

fn execSimple(path: [:0]const u8, name: [:0]const u8) void {
    const argv = [_:null]?[*:0]const u8{name.ptr};
    vh.flush();
    vh.errno = linux.errno(linux.execve(path.ptr, &argv, vh.envp));
}

fn poweroff(reason: []const u8) noreturn {
    vh.log("regular poweroff: {s}", .{reason});
    execSimple("/usr/bin/poweroff", "poweroff");
    vh.die("poweroff: {s}", .{vh.serr()});
}

pub fn main(init: std.process.Init.Minimal) void {
    _ = vh.init(init, "vh-acpid");
    var conf: vh.Kv = .{};
    var env: vh.Kv = .{};
    conf.set("LID_MIN", "10");
    conf.set("POWER_KEY", "poweroff");
    conf.set("IDLE_LOCK_MIN", "0");
    conf.set("IDLE_POWEROFF_MIN", "0");
    conf.set("INTERNAL_INPUT", "");
    conf.read(CONF, true);
    env.read(ENV, true);
    const user = env.get("VH_USER", "");
    const lid_min: i64 = @max(conf.int("LID_MIN", "10"), 1);
    const power_key = conf.get("POWER_KEY", "poweroff");
    const idle_lock = conf.int("IDLE_LOCK_MIN", "0") * 60;
    const idle_off = conf.int("IDLE_POWEROFF_MIN", "0") * 60;

    var extra: vh.Strv = .{};
    var it = mem.tokenizeAny(u8, conf.get("INTERNAL_INPUT", ""), " \t");
    while (it.next()) |t| extra.add(t);
    var found = findDevices(extra.slice());
    if (idle_lock == 0 and idle_off == 0) found.builtin = .{};
    if (found.lid == null and found.power == null and found.builtin.len() == 0) {
        vh.log("neither an ACPI lid nor a power button found: exiting (a desktop PC or a VM?)", .{});
        execSimple("/usr/bin/pause", "pause"); // so runit does not restart us every second
        vh.die("pause: {s}", .{vh.serr()});
    }

    const Dev = struct { fd: vh.fd_t, kind: Kind };
    var devs: std.ArrayList(Dev) = .empty;
    var paths: std.ArrayList(struct { p: []const u8, k: Kind }) = .empty;
    if (found.lid) |p| paths.append(vh.gpa, .{ .p = p, .k = .lid }) catch vh.oom();
    if (found.power) |p| paths.append(vh.gpa, .{ .p = p, .k = .power }) catch vh.oom();
    for (found.builtin.slice()) |p| {
        if (paths.items.len >= MAX_DEV) break;
        paths.append(vh.gpa, .{ .p = p, .k = .input }) catch vh.oom();
    }
    var pfd: [MAX_DEV]linux.pollfd = undefined;
    var lid_fd: ?vh.fd_t = null;
    for (paths.items) |x| {
        const fd = vh.openFd(x.p, .{ .ACCMODE = .RDONLY }, 0) catch vh.die("{s}: {s}", .{ x.p, vh.serr() });
        pfd[devs.items.len] = .{ .fd = fd, .events = linux.POLL.IN, .revents = 0 };
        devs.append(vh.gpa, .{ .fd = fd, .kind = x.k }) catch vh.oom();
        if (x.k == .lid) lid_fd = fd;
        vh.log("{s}: {s}", .{ @tagName(x.k), x.p });
    }
    const nd = devs.items.len;
    const have_input = found.builtin.len() > 0;
    var closed_since: f64 = if (lid_fd != null and lidClosed(lid_fd.?)) now() else -1;
    var last_input = now();
    var idle_locked = false;
    const lid_s: f64 = @floatFromInt(lid_min * 60);
    const lock_s: f64 = @floatFromInt(idle_lock);
    const off_s: f64 = @floatFromInt(idle_off);

    while (true) {
        var t = now();
        var deadline: f64 = -1;
        var cand: [3]f64 = undefined;
        var nc: usize = 0;
        if (closed_since >= 0) {
            cand[nc] = closed_since + lid_s;
            nc += 1;
        }
        if (have_input and idle_lock != 0 and !idle_locked) {
            cand[nc] = last_input + lock_s;
            nc += 1;
        }
        if (have_input and idle_off != 0) {
            cand[nc] = last_input + off_s;
            nc += 1;
        }
        for (cand[0..nc]) |x| if (deadline < 0 or x < deadline) {
            deadline = x;
        };
        var timeout: i32 = -1;
        if (deadline >= 0) {
            const ms = (deadline - t) * 1000;
            timeout = if (ms <= 0) 0 else if (ms > std.math.maxInt(i32)) std.math.maxInt(i32) else @as(i32, @intFromFloat(ms)) + 1;
        }
        const r = linux.poll(&pfd, nd, timeout);
        switch (linux.errno(r)) {
            .SUCCESS => {},
            .INTR => continue,
            else => |e| {
                vh.errno = e;
                vh.die("poll: {s}", .{vh.serr()});
            },
        }
        if (r == 0) {
            t = now();
            if (have_input and idle_off != 0 and t >= last_input + off_s)
                poweroff(vh.fmt("no physical input for {d} min", .{@divTrunc(idle_off, 60)}));
            if (have_input and idle_lock != 0 and !idle_locked and t >= last_input + lock_s) {
                idle_locked = true;
                lockSession(user);
            }
            if (closed_since >= 0 and t >= closed_since + lid_s) {
                if (externalDisplay()) {
                    closed_since = -1; // a monitor was connected while the lid was closed
                    continue;
                }
                poweroff(vh.fmt("lid closed for more than {d} min", .{lid_min}));
            }
            continue;
        }
        for (devs.items, 0..) |d, i| {
            if (pfd[i].revents == 0) continue;
            var ev: [64]InputEvent = undefined;
            const n = linux.read(d.fd, @ptrCast(&ev), @sizeOf(@TypeOf(ev)));
            const e = linux.errno(n);
            if (e == .INTR or e == .AGAIN) continue;
            if (e != .SUCCESS or n == 0) {
                vh.errno = e;
                vh.die("reading {s}: {s}", .{ @tagName(d.kind), if (e != .SUCCESS) vh.serr() else "end of input" });
            }
            if (d.kind == .input) {
                last_input = now(); // the content is not parsed, only the fact
                idle_locked = false;
                continue;
            }
            for (ev[0 .. n / @sizeOf(InputEvent)]) |x| {
                if (d.kind == .lid and x.type == EV_SW and x.code == SW_LID) {
                    if (x.value == 1) {
                        if (externalDisplay()) {
                            vh.log("lid closed, external monitor present: doing nothing", .{});
                            continue;
                        }
                        closed_since = now();
                        lockSession(user);
                    } else {
                        closed_since = -1;
                    }
                } else if (d.kind == .power and x.type == EV_KEY and x.code == KEY_POWER and x.value == 1) {
                    if (vh.eql(power_key, "poweroff")) poweroff("power button") else if (vh.eql(power_key, "lock")) lockSession(user);
                }
            }
        }
    }
}

test "classify" {
    const none: []const []const u8 = &.{};
    try std.testing.expectEqual(Kind.lid, classify("Lid Switch", "PNP0C0D/button/input0", "/sys/devices/LNXSYSTM:00/PNP0C0D:00", none).?);
    try std.testing.expect(classify("Lid Switch", "usb-1/input0", "/sys/devices/x", none) == null);
    try std.testing.expectEqual(Kind.power, classify("Power Button", "LNXPWRBN/button/input0", "/sys/devices/LNXPWRBN:00", none).?);
    try std.testing.expectEqual(Kind.input, classify("AT Translated Set 2 keyboard", "isa0060/serio0/input0", "/sys/devices/platform/i8042", none).?);
    try std.testing.expect(classify("uinput", "isa0060/serio0", "/sys/devices/virtual/input/input9", none) == null);
    try std.testing.expectEqual(Kind.input, classify("MSFT0001:00", "i2c-MSFT", "/sys/devices/pci0000:00/i2c-0/x", none).?);
    try std.testing.expect(classify("kbd", "usb-0000:00:14.0-1/input0", "/sys/devices/pci0000:00/usb1/i2c-1", none) == null);
    const extra: []const []const u8 = &.{"/serio2"};
    try std.testing.expectEqual(Kind.input, classify("x", "y", "/sys/devices/platform/serio2/z", extra).?);
}
