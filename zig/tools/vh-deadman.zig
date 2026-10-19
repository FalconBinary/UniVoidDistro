//! vh-deadman: wiping the LUKS key and plaintext from RAM (optional/deadman, docs/13).
//!
//! Two shutdown modes:
//!   alarm    -- the tag (a USB device) is removed or the key combination is pressed on the
//!               built-in keyboard: the volume key is wiped within a fraction of a second,
//!               the data of the last seconds is not saved;
//!   regular  -- runit stage 3 (power button, lid, idle, doas poweroff): the services are
//!               stopped, the data is flushed, the root is read-only; then the same wipe
//!               (shutdown.d/85-vh-deadman.sh calls "vh-deadman final").
//!
//! The sequence after the trigger (no fork, exec, disk reads or memory allocation: everything
//! is opened and locked in RAM in advance, mlockall):
//!   1. DM_DEV_SUSPEND with NOFLUSH|SKIP_LOCKFS plus DM_TARGET_MSG "key wipe" for every dm-crypt
//!      volume: the volume key is wiped from kernel memory; after this the disk cannot be read;
//!   2. kill(-1, SIGKILL): process memory is freed and (init_on_free=1) zeroed;
//!   3. swapoff and a zram reset: zsmalloc does not zero freed objects itself;
//!   4. drop_caches=3: the page cache with decrypted files, dentries and inodes;
//!   5. with MOR: the VhPoweroff flag in NVRAM and sysrq b; the firmware wipes RAM at POST and
//!      the initramfs powers the machine off on the flag (91vhdeadman); without MOR: sysrq o (power-off).
//! Residual risk: processes stuck in D state on the suspended volume, and dirty pages of
//! recently written files (without MOR they stay in RAM until power is lost); a long press of
//! the power button bypasses all of this.
//!
//!   vh-deadman daemon   -- the resident mode (the runit service vh-deadman)
//!   vh-deadman final    -- the end of a regular shutdown (stage 3)
//!   vh-deadman test     -- show what was found, changing nothing
const std = @import("std");
const vh = @import("vh");
const input = @import("input");
const linux = std.os.linux;
const mem = std.mem;

const CONF = "/etc/vh/deadman.conf";
/// INTERNAL_INPUT: the built-in keyboards the installer named from the probe (vh-acpid's too)
const ACPI_CONF = "/etc/vh/acpi.conf";
/// GUID LINUX_EFI_CRASH_GUID: efivarfs creates variables with it as deletable, so the
/// initramfs removes the flag without chattr. The name does not start with dump-, so
/// efi-pstore leaves it alone.
const EFI_FLAG = "VhPoweroff-cfc8fc79-be2e-4ddc-97f0-9f98bfe298a0";
const MOR_VAR = "/sys/firmware/efi/efivars/MemoryOverwriteRequestControl-e20939be-32d4-41be-a150-897f85d49829";
const MAX_VOL = 16;

const usage_text =
    \\vh-deadman daemon   -- the resident mode (the runit service vh-deadman)
    \\vh-deadman final    -- the end of a regular shutdown (stage 3)
    \\vh-deadman test     -- show what was found, changing nothing
    \\
;

// ---------------------------------------------------------------- device-mapper (linux/dm-ioctl.h)

const DM_NAME_LEN = 128;
const DM_UUID_LEN = 129;
const DM_VERSION_MAJOR = 4;
const DM_SUSPEND_FLAG: u32 = 1 << 1;
const DM_SKIP_LOCKFS_FLAG: u32 = 1 << 10;
const DM_NOFLUSH_FLAG: u32 = 1 << 11;

/// struct dm_ioctl
pub const DmIoctl = extern struct {
    version: [3]u32,
    data_size: u32,
    data_start: u32,
    target_count: u32,
    open_count: i32,
    flags: u32,
    event_nr: u32,
    padding: u32,
    dev: u64,
    name: [DM_NAME_LEN]u8,
    uuid: [DM_UUID_LEN]u8,
    data: [7]u8,
};
comptime {
    std.debug.assert(@sizeOf(DmIoctl) == 312);
}

fn dmIowr(cmd: u32) u32 {
    return (3 << 30) | (@as(u32, @sizeOf(DmIoctl)) << 16) | (0xfd << 8) | cmd;
}
pub const DM_DEV_SUSPEND = dmIowr(6);
pub const DM_TARGET_MSG = dmIowr(14);

/// struct dm_ioctl with its data; the size is a multiple of 8
const DmReq = extern struct { io: DmIoctl, data: [64]u8 };

fn dmInit(r: *DmReq, name: []const u8, flags: u32, payload: []const u8) void {
    r.* = mem.zeroes(DmReq);
    r.io.version = .{ DM_VERSION_MAJOR, 0, 0 };
    r.io.data_size = @intCast((@sizeOf(DmIoctl) + payload.len + 7) & ~@as(usize, 7));
    r.io.data_start = @sizeOf(DmIoctl);
    r.io.flags = flags;
    const n = @min(name.len, DM_NAME_LEN - 1);
    @memcpy(r.io.name[0..n], name[0..n]);
    const bytes: [*]u8 = @ptrCast(r);
    @memcpy(bytes[@sizeOf(DmIoctl)..][0..payload.len], payload);
}

const Vol = struct { name: []const u8, susp: DmReq, msg: DmReq };

/// everything the wipe needs, opened and prepared in advance
var W: struct {
    dmctl: vh.fd_t = -1,
    drop: vh.fd_t = -1,
    sysrq: vh.fd_t = -1,
    efi: vh.fd_t = -1,
    vol: [MAX_VOL]Vol = undefined,
    nvol: usize = 0,
    zdev: [MAX_VOL][:0]const u8 = undefined,
    zreset: [MAX_VOL]vh.fd_t = undefined,
    nz: usize = 0,
} = .{};

/// directory entries with a prefix, by name (like glob)
fn globDir(dir: []const u8, prefix: []const u8) []const []const u8 {
    const names = vh.listDir(dir) catch return &.{};
    var s: vh.Strv = .{};
    for (names) |n| if (vh.startsWith(n, prefix)) s.add(n);
    s.sort();
    return s.slice();
}

fn wiperInit() void {
    if (linux.errno(linux.mlockall(.{ .CURRENT = true, .FUTURE = true })) != .SUCCESS)
        vh.log("mlockall: {s}; the daemon's memory may end up in zram", .{vh.strerror(linux.errno(linux.mlockall(.{ .CURRENT = true, .FUTURE = true })))});
    W.dmctl = vh.openFd("/dev/mapper/control", .{ .ACCMODE = .RDWR }, 0) catch vh.die("/dev/mapper/control: {s}", .{vh.serr()});
    for (globDir("/sys/block", "dm-")) |b| {
        if (W.nvol >= MAX_VOL) break;
        const d = vh.fmt("/sys/block/{s}/dm", .{b});
        if (!vh.pathExists(d)) continue;
        if (!vh.startsWith(vh.rd(vh.fmt("{s}/uuid", .{d})), "CRYPT-")) continue;
        const name = vh.rd(vh.fmt("{s}/name", .{d}));
        const v = &W.vol[W.nvol];
        W.nvol += 1;
        v.name = name[0..@min(name.len, DM_NAME_LEN - 1)];
        dmInit(&v.susp, name, DM_SUSPEND_FLAG | DM_SKIP_LOCKFS_FLAG | DM_NOFLUSH_FLAG, "");
        // struct dm_target_msg: the sector (u64) and the message text
        dmInit(&v.msg, name, 0, "\x00\x00\x00\x00\x00\x00\x00\x00key wipe\x00");
    }
    for (globDir("/sys/block", "zram")) |n| {
        if (W.nz >= MAX_VOL) break;
        const fd = vh.openFd(vh.fmt("/sys/block/{s}/reset", .{n}), .{ .ACCMODE = .WRONLY }, 0) catch continue;
        W.zdev[W.nz] = vh.z(vh.fmt("/dev/{s}", .{n}));
        W.zreset[W.nz] = fd;
        W.nz += 1;
    }
    W.drop = vh.openFd("/proc/sys/vm/drop_caches", .{ .ACCMODE = .WRONLY }, 0) catch
        vh.die("/proc/sys/vm/drop_caches, /proc/sysrq-trigger: {s}", .{vh.serr()});
    W.sysrq = vh.openFd("/proc/sysrq-trigger", .{ .ACCMODE = .WRONLY }, 0) catch
        vh.die("/proc/sys/vm/drop_caches, /proc/sysrq-trigger: {s}", .{vh.serr()});
    if (vh.pathExists(MOR_VAR))
        W.efi = vh.openFd("/sys/firmware/efi/efivars", .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0) catch -1;
    // warm-up: the first calls must not page anything in
    if (linux.errno(linux.write(W.drop, "1", 1)) != .SUCCESS)
        vh.log("drop_caches: {s}", .{vh.strerror(linux.errno(linux.write(W.drop, "1", 1)))});
}

fn describe() []const u8 {
    var names: std.ArrayList(u8) = .empty;
    for (W.vol[0..W.nvol], 0..) |v, i| names.print(vh.gpa, "{s}{s}", .{ if (i > 0) ", " else "", v.name }) catch vh.oom();
    return vh.fmt("dm-crypt volumes: {s}; zram: {d}; MOR: {s}", .{
        if (W.nvol > 0) names.items else "none", W.nz, if (W.efi >= 0) "yes" else "no",
    });
}

/// System calls on descriptors opened in advance only: no memory, no disk.
fn wipe(reboot: bool) noreturn {
    for (W.vol[0..W.nvol]) |*v| {
        // the next volume is wiped even if this one failed
        _ = linux.ioctl(W.dmctl, DM_DEV_SUSPEND, @intFromPtr(&v.susp));
        _ = linux.ioctl(W.dmctl, DM_TARGET_MSG, @intFromPtr(&v.msg));
    }
    _ = linux.kill(-1, .KILL);
    var ts: linux.timespec = .{ .sec = 0, .nsec = 300 * 1000 * 1000 };
    _ = linux.nanosleep(&ts, null); // processes exit, swap slots are freed
    for (0..W.nz) |i| {
        _ = linux.syscall1(.swapoff, @intFromPtr(W.zdev[i].ptr));
        _ = linux.write(W.zreset[i], "1", 1); // a busy device: RAM is wiped below anyway
    }
    _ = linux.write(W.drop, "3", 1);
    if (W.efi < 0) {
        // no MOR: the firmware will not wipe RAM; power off bypassing userspace, no reboot
        _ = linux.write(W.sysrq, if (reboot) "b" else "o", 1);
        while (true) _ = linux.pause();
    }
    if (!reboot) {
        const rc = linux.openat(W.efi, EFI_FLAG, .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true }, 0o644);
        if (linux.errno(rc) == .SUCCESS) {
            const fd: vh.fd_t = @intCast(rc);
            const v = [_]u8{ 0x07, 0x00, 0x00, 0x00, 0x01 }; // NV|BS|RT + 1 byte
            _ = linux.write(fd, &v, v.len);
            _ = linux.close(fd);
        }
    }
    _ = linux.write(W.sysrq, "b", 1); // a reboot through the firmware: MOR wipes RAM
    while (true) _ = linux.pause();
}

/// a hex number like strtoul(..., 16): an optional "0x"; null when there are no digits or above 0xFFFF
fn hex16(s: []const u8) ?u16 {
    const t = if (vh.startsWith(s, "0x") or vh.startsWith(s, "0X")) s[2..] else s;
    if (t.len == 0) return null;
    return std.fmt.parseInt(u16, t, 16) catch null;
}

/// TAG = vid:pid (hex, as in lsusb)
pub fn parseTag(tag: []const u8) ?[2]u16 {
    const colon = mem.indexOfScalar(u8, tag, ':') orelse return null;
    const rest = tag[colon + 1 ..];
    const end = mem.indexOfScalar(u8, rest, ':') orelse rest.len;
    return .{ hex16(tag[0..colon]) orelse return null, hex16(rest[0..end]) orelse return null };
}

fn parseTagOrDie(tag: []const u8) [2]u16 {
    return parseTag(tag) orelse vh.die("TAG={s}: vid:pid is required (lsusb)", .{tag});
}

/// is such a USB device present; its DEVPATH (without /sys)
fn tagPresent(vp: [2]u16) ?[]const u8 {
    for (globDir("/sys/bus/usb/devices", "")) |n| {
        const d = vh.fmt("/sys/bus/usb/devices/{s}", .{n});
        const v = vh.rd(vh.fmt("{s}/idVendor", .{d}));
        if (v.len == 0) continue;
        const q = vh.rd(vh.fmt("{s}/idProduct", .{d}));
        if ((hex16(v) orelse continue) != vp[0] or (hex16(q) orelse continue) != vp[1]) continue;
        const real = vh.realpath(d) catch continue;
        if (vh.startsWith(real, "/sys")) return real[4..];
    }
    return null;
}

fn status(s: []const u8) void {
    const fd = vh.openFd("/run/vh/deadman", .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .NOFOLLOW = true }, 0o644) catch return;
    defer vh.close(fd);
    vh.writeAllFd(fd, vh.fmt("{s}\n", .{s})) catch {};
}

/// the value of KEY= in a uevent message (fields separated by \0)
pub fn uev(d: []const u8, key: []const u8) []const u8 {
    var it = mem.splitScalar(u8, d, 0);
    while (it.next()) |f| {
        if (f.len > key.len and vh.startsWith(f, key) and f[key.len] == '=') return f[key.len + 1 ..];
    }
    return "";
}

// linux/watchdog.h: _IOWR('W', 6, int) and _IOR('W', 7, int)
const WDIOC_SETTIMEOUT: u32 = (3 << 30) | (4 << 16) | (@as(u32, 'W') << 8) | 6;
const WDIOC_GETTIMEOUT: u32 = (2 << 30) | (4 << 16) | (@as(u32, 'W') << 8) | 7;
/// the timeout asked of the board's watchdog, whatever its driver: a dead or hung daemon
/// resets the machine within a minute
const WD_TIMEOUT: i32 = 60;

/// How often the daemon pets the watchdog, in seconds: a third of the timeout the driver
/// accepted, at most every 10 s, at least every second. A driver may refuse 60 s and keep a
/// shorter limit of its own; null or nonsense (the driver cannot say) keeps 10 s.
pub fn petInterval(timeout: ?i32) u32 {
    const t = timeout orelse return 10;
    if (t <= 0) return 10;
    return @intCast(@max(@min(@divTrunc(t, 3), 10), 1));
}

/// the timeout of an open watchdog: 60 s asked, what the driver kept read back; null when it
/// cannot say
fn wdTimeout(wd: vh.fd_t) ?i32 {
    var want: i32 = WD_TIMEOUT;
    _ = linux.ioctl(wd, WDIOC_SETTIMEOUT, @intFromPtr(&want));
    var got: i32 = 0;
    if (linux.errno(linux.ioctl(wd, WDIOC_GETTIMEOUT, @intFromPtr(&got))) != .SUCCESS) return null;
    return got;
}

const EV_KEY = 1;
const KEY_RIGHTCTRL = 97;
const KEY_RIGHTALT = 100;
const KEY_END = 107;
const InputEvent = extern struct { sec: i64, usec: i64, type: u16, code: u16, value: i32 };
/// the most input devices the combination listens to
const MAX_KBD = 16;

/// Does the alarm combination listen to this input device: built into the machine, by the
/// rule of vh-acpid's idle watchdog (zig/lib/input.zig: PS/2, I2C, the places of
/// INTERNAL_INPUT, never uinput), and with a key of the combination in its bitmap (sysfs
/// capabilities/key), so that a touchpad never wakes the daemon. One key is enough: a keyboard
/// may send its modifiers and its other keys through two input devices, and the keys held at
/// once count across all of them.
pub fn comboKeyboard(phys: []const u8, real: []const u8, keys: []const u8, places: []const []const u8) bool {
    if (!input.isBuiltin(phys, real, places)) return false;
    for ([_]u16{ KEY_RIGHTCTRL, KEY_RIGHTALT, KEY_END }) |k| if (input.hasKey(keys, k)) return true;
    return false;
}

/// the places of INTERNAL_INPUT in /etc/vh/acpi.conf
fn internalInput() []const []const u8 {
    var acpi: vh.Kv = .{};
    acpi.read(ACPI_CONF, true);
    var places: vh.Strv = .{};
    var it = mem.tokenizeAny(u8, acpi.get("INTERNAL_INPUT", ""), " \t");
    while (it.next()) |t| places.add(t);
    return places.slice();
}

/// the input devices the combination listens to, by their names in /sys/class/input (event0 ...)
fn comboKeyboards() []const []const u8 {
    const places = internalInput();
    var found: vh.Strv = .{};
    for (globDir("/sys/class/input", "event")) |e| {
        const d = vh.fmt("/sys/class/input/{s}/device", .{e});
        const real = vh.realpath(d) catch continue;
        if (comboKeyboard(vh.rd(vh.fmt("{s}/phys", .{d})), real, vh.rd(vh.fmt("{s}/capabilities/key", .{d})), places)) found.add(e);
    }
    return found.slice();
}

/// "event0 (AT Translated Set 2 keyboard), event5 (...)": the log and the test mode
fn keyboardsText(names: []const []const u8) []const u8 {
    if (names.len == 0) return "no built-in keyboard";
    var s: std.ArrayList(u8) = .empty;
    for (names, 0..) |e, i| s.print(vh.gpa, "{s}{s} ({s})", .{ if (i > 0) ", " else "", e, vh.rd(vh.fmt("/sys/class/input/{s}/device/name", .{e})) }) catch vh.oom();
    return s.items;
}

fn daemonLoop(conf: *const vh.Kv) noreturn {
    const tag = conf.get("TAG", "");
    const combo = vh.eql(conf.get("COMBO", "no"), "yes");
    var armed: [512]u8 = undefined;
    var armed_len: usize = 0;
    var prod_buf: [32]u8 = undefined;
    var prod: []const u8 = "";
    // the uevent socket, then the keyboards of the combination (kbd_name: their event names)
    var pfd: [1 + MAX_KBD]linux.pollfd = undefined;
    var kbd_name: [1 + MAX_KBD][]const u8 = undefined;
    var np: usize = 0;
    var nl: vh.fd_t = -1;
    var wd: vh.fd_t = -1;
    if (tag.len > 0) {
        const vp = parseTagOrDie(tag);
        prod = std.fmt.bufPrint(&prod_buf, "{x}/{x}/", .{ vp[0], vp[1] }) catch unreachable;
        const rc = linux.socket(linux.AF.NETLINK, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 15); // NETLINK_KOBJECT_UEVENT
        nl = @intCast(vh.sys(rc) catch vh.die("netlink uevent: {s}", .{vh.serr()}));
        var sa = mem.zeroes(linux.sockaddr.nl);
        sa.family = linux.AF.NETLINK;
        sa.groups = 1;
        _ = vh.sys(linux.bind(nl, @ptrCast(&sa), @sizeOf(linux.sockaddr.nl))) catch vh.die("netlink uevent: {s}", .{vh.serr()});
        pfd[np] = .{ .fd = nl, .events = linux.POLL.IN, .revents = 0 };
        np += 1;
        if (tagPresent(vp)) |p| {
            armed_len = @min(p.len, armed.len);
            @memcpy(armed[0..armed_len], p[0..armed_len]);
        }
    }
    var kbds: vh.Strv = .{};
    if (combo) {
        for (comboKeyboards()) |e| {
            if (kbds.len() >= MAX_KBD) break;
            const node = vh.fmt("/dev/input/{s}", .{e});
            const fd = vh.openFd(node, .{ .ACCMODE = .RDONLY }, 0) catch {
                vh.log("{s}: {s}", .{ node, vh.serr() });
                continue;
            };
            pfd[np] = .{ .fd = fd, .events = linux.POLL.IN, .revents = 0 };
            kbd_name[np] = e;
            np += 1;
            kbds.add(e);
        }
    }
    var pet_s: u32 = 10;
    var wd_timeout: ?i32 = null;
    if (vh.eql(conf.get("WATCHDOG", "no"), "yes") and vh.pathExists("/dev/watchdog")) {
        wd = vh.openFd("/dev/watchdog", .{ .ACCMODE = .WRONLY }, 0) catch -1;
        if (wd >= 0) {
            wd_timeout = wdTimeout(wd);
            pet_s = petInterval(wd_timeout);
        }
    }
    vh.mkdirs("/run/vh", 0o755);
    status(if (armed_len > 0) "armed" else "disarmed");
    vh.log("{s}; tag {s}: {s}; combination: {s}; watchdog: {s}", .{
        describe(),                              if (tag.len > 0) tag else "-",
        if (armed_len > 0) "inserted" else "absent", if (combo) keyboardsText(kbds.slice()) else "no",
        if (wd < 0) "no" else if (wd_timeout) |t| vh.fmt("timeout {d} s, petted every {d} s", .{ t, pet_s }) else vh.fmt("petted every {d} s", .{pet_s}),
    });
    var rctrl = false;
    var ralt = false;
    var end = false;
    const S = struct {
        var buf: [8192]u8 = undefined;
    };
    while (true) {
        if (wd >= 0) {
            const e = linux.errno(linux.write(wd, "\x00", 1));
            if (e != .SUCCESS) vh.log("watchdog: {s}", .{vh.strerror(e)});
        }
        const r = linux.poll(&pfd, np, if (wd >= 0) @as(i32, @intCast(pet_s * 1000)) else -1);
        const pe = linux.errno(r);
        if (pe != .SUCCESS and pe != .INTR) {
            vh.errno = pe;
            vh.die("poll: {s}", .{vh.serr()});
        }
        if (pe != .SUCCESS) continue;
        for (pfd[0..np], 0..) |*p, i| {
            if (p.revents == 0) continue;
            if (p.fd == nl) {
                var from: linux.sockaddr.nl = undefined;
                var fl: linux.socklen_t = @sizeOf(linux.sockaddr.nl);
                const n = linux.recvfrom(nl, &S.buf, S.buf.len - 1, 0, @ptrCast(&from), &fl);
                if (linux.errno(n) != .SUCCESS or n == 0 or from.pid != 0) continue; // kernel messages only
                const d = S.buf[0..n];
                if (!vh.eql(uev(d, "SUBSYSTEM"), "usb") or !vh.eql(uev(d, "DEVTYPE"), "usb_device") or
                    !vh.startsWith(uev(d, "PRODUCT"), prod)) continue;
                const action = uev(d, "ACTION");
                const devpath = uev(d, "DEVPATH");
                if (vh.eql(action, "add")) {
                    armed_len = @min(devpath.len, armed.len);
                    @memcpy(armed[0..armed_len], devpath[0..armed_len]);
                    status("armed");
                } else if (vh.eql(action, "remove") and armed_len > 0 and vh.eql(devpath, armed[0..armed_len])) {
                    vh.log("tag removed: alarm shutdown", .{});
                    wipe(false);
                }
            } else {
                var ev: [64]InputEvent = undefined;
                const n = linux.read(p.fd, @ptrCast(&ev), @sizeOf(@TypeOf(ev)));
                const e = linux.errno(n);
                if (e == .INTR or e == .AGAIN) continue;
                if (e != .SUCCESS or n == 0) {
                    // the keyboard is gone (unplugged, its USB device reset): poll skips a
                    // negative descriptor, and the keys it held no longer count
                    vh.log("{s}: {s}: the combination no longer listens to it", .{ kbd_name[i], if (e != .SUCCESS) vh.strerror(e) else "end of input" });
                    vh.close(p.fd);
                    p.fd = -1;
                    rctrl = false;
                    ralt = false;
                    end = false;
                    continue;
                }
                for (ev[0 .. n / @sizeOf(InputEvent)]) |x| {
                    if (x.type != EV_KEY or x.value == 2) continue;
                    const down = x.value == 1;
                    switch (x.code) {
                        KEY_RIGHTCTRL => rctrl = down,
                        KEY_RIGHTALT => ralt = down,
                        KEY_END => end = down,
                        else => {},
                    }
                    if (rctrl and ralt and end) {
                        vh.log("alarm combination: shutdown", .{});
                        wipe(false);
                    }
                }
            }
        }
    }
}

pub fn main(init: std.process.Init.Minimal) void {
    const args = vh.init(init, "vh-deadman");
    if (linux.geteuid() != 0) vh.die("root is required", .{});
    const mode: []const u8 = if (args.len > 0) args[0] else "";
    var conf: vh.Kv = .{};
    conf.set("TAG", "");
    conf.set("COMBO", "no");
    conf.set("WATCHDOG", "no");
    conf.read(CONF, true);
    if (vh.eql(mode, "test")) {
        wiperInit();
        const tag = conf.get("TAG", "");
        const armed: ?[]const u8 = if (tag.len > 0) tagPresent(parseTagOrDie(tag)) else null;
        vh.out("{s} | tag: {s} {s}\n", .{ describe(), if (tag.len > 0) tag else "-", if (armed != null) "inserted" else "" });
        if (vh.eql(conf.get("COMBO", "no"), "yes")) vh.out("combination: {s}\n", .{keyboardsText(comboKeyboards())});
    } else if (vh.eql(mode, "final")) {
        wiperInit();
        if (vh.eql(conf.get("WATCHDOG", "no"), "yes")) {
            if (vh.openFd("/dev/watchdog", .{ .ACCMODE = .WRONLY }, 0)) |wd| _ = linux.write(wd, "\x00", 1) else |_| {}
        }
        const reboot = linux.errno(linux.access("/run/runit/reboot", linux.X_OK)) == .SUCCESS;
        vh.out("vh-deadman: wiping the key and RAM ({s})\n", .{if (reboot) "reboot" else "power-off"});
        vh.flush();
        wipe(reboot);
    } else if (vh.eql(mode, "daemon")) {
        wiperInit();
        daemonLoop(&conf);
    } else {
        vh.outs(usage_text);
        vh.exit(2);
    }
    vh.exit(0);
}

test "the watchdog is petted at a third of its timeout" {
    try std.testing.expectEqual(@as(u32, 10), petInterval(60));
    try std.testing.expectEqual(@as(u32, 5), petInterval(15));
    try std.testing.expectEqual(@as(u32, 3), petInterval(10));
    try std.testing.expectEqual(@as(u32, 1), petInterval(2));
    try std.testing.expectEqual(@as(u32, 10), petInterval(null));
    try std.testing.expectEqual(@as(u32, 10), petInterval(0));
    try std.testing.expectEqual(@as(u32, 0xC0045706), WDIOC_SETTIMEOUT);
    try std.testing.expectEqual(@as(u32, 0x80045707), WDIOC_GETTIMEOUT);
}

test "parseTag and uev" {
    try std.testing.expectEqual([2]u16{ 0x1050, 0x0407 }, parseTag("1050:0407").?);
    try std.testing.expectEqual([2]u16{ 0x1050, 0x407 }, parseTag("0x1050:407:x").?);
    try std.testing.expect(parseTag("10500:1") == null);
    try std.testing.expect(parseTag("xyz") == null);
    const m = "add@/devices/x\x00ACTION=add\x00DEVPATH=/devices/pci/usb1/1-2\x00SUBSYSTEM=usb\x00";
    try std.testing.expectEqualStrings("/devices/pci/usb1/1-2", uev(m, "DEVPATH"));
    try std.testing.expectEqualStrings("", uev(m, "PRODUCT"));
}

test "the combination listens to the built-in keyboards: not a touchpad, a keyboard from outside or uinput" {
    const keyboard = "402000000 3803078f800d001 feffffdfffefffff fffffffffffffffe";
    const none: []const []const u8 = &.{};
    try std.testing.expect(comboKeyboard("isa0060/serio0/input0", "/sys/devices/platform/i8042/serio0/input/input0", keyboard, none));
    // the touchpad on the PS/2 controller is built in, but has none of the keys
    try std.testing.expect(!comboKeyboard("isa0060/serio1/input0", "/sys/devices/platform/i8042/serio1/input/input4", "e520 10000 0 0 0 0", none));
    try std.testing.expect(comboKeyboard("i2c-XYZ0001:00", "/sys/devices/platform/soc/a90000.i2c/i2c-2/2-003a/0018:1234:5678.0001/input/input3", keyboard, none));
    // a keyboard on internal USB, by the place the probe recorded (INTERNAL_INPUT)
    const places: []const []const u8 = &.{"/pci0000:00/0000:00:14.0/usb1/1-8/"};
    const usb = "/sys/devices/pci0000:00/0000:00:14.0/usb1/1-8/1-8:1.0/0003:1234:5678.0002/input/input5";
    try std.testing.expect(!comboKeyboard("usb-0000:00:14.0-8/input0", usb, keyboard, none));
    try std.testing.expect(comboKeyboard("usb-0000:00:14.0-8/input0", usb, keyboard, places));
    // its input device with End but without the modifiers counts; the volume keys' one does not
    try std.testing.expect(comboKeyboard("usb-0000:00:14.0-8/input1", "/sys/devices/pci0000:00/0000:00:14.0/usb1/1-8/1-8:1.1/0003:1234:5678.0003/input/input6", "80000000000 0", places));
    try std.testing.expect(!comboKeyboard("usb-0000:00:14.0-8/input2", "/sys/devices/pci0000:00/0000:00:14.0/usb1/1-8/1-8:1.2/0003:1234:5678.0004/input/input7", "e000000000000 0", places));
    // a keyboard plugged in from outside, and uinput that claims the PS/2 controller
    try std.testing.expect(!comboKeyboard("usb-0000:00:14.0-2/input0", "/sys/devices/pci0000:00/0000:00:14.0/usb1/1-2/1-2:1.0/0003:1234:9abc.0005/input/input8", keyboard, places));
    try std.testing.expect(!comboKeyboard("isa0060/serio0/input0", "/sys/devices/virtual/input/input12", keyboard, places));
}
