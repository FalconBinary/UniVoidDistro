//! vh-kconf check: is this still the machine the system was planned for (docs/uni/runtime.md)?
//! At boot (the vh-check service) the running system is probed and compared with
//! /etc/vh/hw.zon, the probe of the installation:
//!   - another machine: the architecture, the CPU model (vendor, family and model; on ARM the
//!     implementer and part) or the board (DMI baseboard, else the system, else the device
//!     tree's model) differ;
//!   - devices without a driver: one that had a driver at installation and has none now, or a
//!     new one, unless the kernel refuses its module (module_blacklist= of its command line);
//!   - firmware that failed to load this boot (the kernel log), and whether the plan's firmware
//!     trim (/etc/xbps.d/40-vh-firmware.conf) left it out.
//! OUT/check.done always gets the summary line "VH_CHECK machine=same|different devices=N
//! firmware=N lost=N" (lost: the devices that had a driver at installation and have none now,
//! the verdict the boot assessment of a machine kernel reads, docs/uni/kernel.md); with a
//! finding, OUT/check gets the message the admin sees at login on tty2, and OUT/plan a fresh
//! plan of the running system (vh-plan, run by argv). Nothing found: OUT/check is removed.
//! On a machine kernel (release *-vh) the modules its build left out on purpose count as
//! refused, as module_blacklist= does on the stock kernel: modules.deny, the plan's deny list,
//! the modules of the features the plan does not select (resolve.denyList).
//! The stock kernel writes its own view of the machine at each boot (/var/lib/vh/check/stock.zon,
//! when the machine is the same), and a machine kernel's devices are judged against that view:
//! the probe of the installation was made by the live image's kernel, another version, and a
//! driver that moved between them is no loss of the machine kernel's (kernel 6.18 drives the
//! fixed ACPI power button with tiny_power_button, the live image's 6.12 with button).
const std = @import("std");
const vh = @import("vh");
const hw = @import("hw.zig");
const probe = @import("probe.zig");
const alias = @import("alias.zig");
const resolve = @import("resolve.zig");
const linux = std.os.linux;
const mem = std.mem;

pub const Opts = struct {
    /// a snapshot instead of the live system (tests): the probe reads it, /proc/cmdline too
    from: []const u8 = "",
    /// the system's files under this directory (tests): /etc, /usr/lib/firmware, /lib/modules,
    /// /root/vh, /run/vh, /usr/local/sbin; an option given explicitly is taken as it is
    root: []const u8 = "",
    hw: ?[]const u8 = null,
    /// the kernel log as text (tests); /dev/kmsg otherwise
    kmsg: ?[]const u8 = null,
    out: ?[]const u8 = null,
    /// hwdb/, kernel/pins and the configuration of the fresh plan (what the installer copied)
    repo: ?[]const u8 = null,
    /// the planner; "none" makes no fresh plan
    vh_plan: ?[]const u8 = null,
    /// the plan of the installation: its deny list and features, on a machine kernel
    plan: ?[]const u8 = null,
    /// the running kernel's modules.alias and modules.builtin.modinfo
    alias: ?[]const u8 = null,
    builtin: ?[]const u8 = null,
    /// the stock kernel's view of the machine: written on a stock kernel, read on a machine one
    stock: ?[]const u8 = null,
};

/// buses into which hardware is plugged: a new device there without a driver is news even
/// when no module of this kernel knows it; elsewhere (acpi, platform, wmi ...) the firmware
/// describes many devices no driver claims, so only a module that would drive one counts
const plug_buses = [_][]const u8{ "pci", "usb", "hid", "sdio", "mmc", "spi", "i2c", "serio", "virtio", "thunderbolt", "pcmcia" };

/// text from the firmware or the kernel log, shown on a terminal: control characters become "?"
fn printable(s: []const u8) []const u8 {
    const out = vh.dupe(s);
    for (out) |*c| if (c.* < 0x20 or c.* == 0x7f) {
        c.* = '?';
    };
    return out;
}

fn cpuName(c: hw.Cpu) []const u8 {
    if (c.implementer.len > 0) return vh.fmt("implementer {s} part {s}", .{ c.implementer, c.part });
    return vh.fmt("{s} family {d} model {d}{s}", .{ c.vendor, c.family, c.model, if (c.model_name.len > 0) vh.fmt(" ({s})", .{c.model_name}) else "" });
}

/// the board: the DMI baseboard, else the system's maker and product, else the device tree's model
fn board(h: hw.Hw) []const u8 {
    const m = h.machine;
    if (m.board_vendor.len > 0 or m.board_name.len > 0) return vh.fmt("{s} {s}", .{ m.board_vendor, m.board_name });
    if (m.sys_vendor.len > 0 or m.product_name.len > 0) return vh.fmt("{s} {s}", .{ m.sys_vendor, m.product_name });
    if (h.firmware.dt_model.len > 0) return h.firmware.dt_model;
    return "(not described)";
}

/// what makes `now` another machine than `was`: one line per difference, none for the same machine
pub fn machineDiff(was: hw.Hw, now: hw.Hw) []const []const u8 {
    var out: vh.Strv = .{};
    if (!vh.eql(was.archName(), now.archName())) out.add(vh.fmt("architecture {s}, was {s}", .{ now.archName(), was.archName() }));
    const w = was.cpu;
    const n = now.cpu;
    if (!vh.eql(w.vendor, n.vendor) or w.family != n.family or w.model != n.model or !vh.eql(w.implementer, n.implementer) or !vh.eql(w.part, n.part))
        out.add(printable(vh.fmt("CPU {s}, was {s}", .{ cpuName(n), cpuName(w) })));
    if (!vh.eql(board(was), board(now))) out.add(printable(vh.fmt("board {s}, was {s}", .{ board(now), board(was) })));
    return out.slice();
}

/// the modules the kernel refuses: module_blacklist= of its command line, normalised
pub fn refusedModules(cmdline: []const u8) []const []const u8 {
    var out: vh.Strv = .{};
    var it = mem.tokenizeAny(u8, cmdline, " \t\n");
    while (it.next()) |p| {
        if (!vh.startsWith(p, "module_blacklist=")) continue;
        var ms = mem.tokenizeScalar(u8, p["module_blacklist=".len..], ',');
        while (ms.next()) |m| out.add(alias.normalize(m));
    }
    return out.slice();
}

/// a kernel built by vh-kconf resolve: CONFIG_LOCALVERSION="-vh" of kernel/profiles/base
pub fn isMachineKernel(release: []const u8) bool {
    return vh.endsWith(release, "-vh");
}

/// the refused modules of a machine kernel: those of the command line and those its build left
/// out (resolve.denyList of the installation's plan, the plan's features); the command line's
/// alone when there is no plan
pub fn machineRefused(cmdline_refused: []const []const u8, plan_path: []const u8, profiles: []const u8) []const []const u8 {
    var out: vh.Strv = .{};
    for (cmdline_refused) |m| if (!out.has(m)) out.add(m);
    if (!vh.pathExists(plan_path)) {
        vh.warn("{s}: no plan: the modules this machine kernel was built without are not known", .{plan_path});
        return out.slice();
    }
    const plan = resolve.loadPlan(plan_path);
    const d = resolve.denyList(plan, resolve.features(plan, "auto"), profiles);
    for (d.list.slice()) |m| if (!out.has(m)) out.add(m);
    return out.slice();
}

fn has(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (vh.eql(x, s)) return true;
    return false;
}

fn findDevice(h: hw.Hw, bus: []const u8, name: []const u8) ?hw.Device {
    for (h.devices) |d| if (vh.eql(d.bus, bus) and vh.eql(d.name, name)) return d;
    return null;
}

pub const Driverless = struct {
    /// one line per device, in the order of the probe
    lines: []const []const u8,
    /// how many of them had a driver at installation
    lost: usize,
};

/// The devices without a driver that are news: one that had a driver at installation and has
/// none now (lost), a new one on a bus hardware is plugged into, a new one elsewhere that a
/// module of this kernel would drive. A module the kernel refuses explains its device: not listed.
/// `at` says where `was` comes from: "at installation", or the stock kernel's view.
pub fn driverless(was: hw.Hw, now: hw.Hw, refused: []const []const u8, table: ?*const alias.Table, at: []const u8) Driverless {
    var out: vh.Strv = .{};
    var lost: usize = 0;
    for (now.devices) |d| {
        if (d.driver.len > 0 or vh.eql(d.bus, "dmi")) continue;
        const what = printable(vh.fmt("{s} {s} ({s})", .{ d.bus, d.name, d.modalias }));
        if (findDevice(was, d.bus, d.name)) |w| {
            if (w.driver.len == 0) continue;
            const m = alias.normalize(if (w.module.len > 0) w.module else w.driver);
            if (has(refused, m)) continue;
            out.add(vh.fmt("{s}: had the driver {s} {s}, has none now", .{ what, printable(w.driver), at }));
            lost += 1;
            continue;
        }
        var mods: vh.Strv = .{};
        if (table) |t| {
            const mt = t.match(d.modalias);
            for (mt.loadable) |x| if (!has(refused, x) and !mods.has(x)) mods.add(x);
            for (mt.builtin) |x| if (!has(refused, x) and !mods.has(x)) mods.add(x);
            // every module that would drive it is refused: the policy explains it
            if (mods.len() == 0 and mt.any()) continue;
        }
        if (mods.len() > 0) {
            out.add(vh.fmt("{s}: new; {s} would drive it but is not bound (loaded after the module lock? doas /root/vh/install/30-lock.sh, then reboot)", .{ what, mods.join(", ") }));
        } else if (has(&plug_buses, d.bus)) {
            out.add(vh.fmt("{s}: new; {s}", .{ what, if (table != null) "no driver of this kernel matches it" else "no driver is bound (this kernel has no module tables to ask)" }));
        }
    }
    return .{ .lines = out.slice(), .lost = lost };
}

pub const FwFail = struct {
    /// the firmware file the driver asked for
    file: []const u8,
    /// the driver and device that asked, as the kernel names them ("iwlwifi 0000:00:14.3")
    device: []const u8,
};

/// the message of a kernel log line: without a /dev/kmsg record header ("6,339,5140900,-;") or
/// a dmesg time stamp ("[    5.140900] ")
pub fn messageOf(line: []const u8) []const u8 {
    if (mem.indexOfScalar(u8, line, ';')) |semi| {
        var header = semi > 0 and std.ascii.isDigit(line[0]);
        for (line[0..semi]) |c| header = header and (std.ascii.isDigit(c) or c == ',' or c == '-' or c == '+' or c == 'c');
        if (header) return line[semi + 1 ..];
    }
    if (vh.startsWith(line, "[")) {
        if (mem.indexOfScalar(u8, line, ']')) |end| return mem.trimStart(u8, line[end + 1 ..], " ");
    }
    return line;
}

/// every firmware file a driver failed to load, in the order of the log, each once
pub fn firmwareFailures(log: []const u8) []const FwFail {
    var out: std.ArrayList(FwFail) = .empty;
    var lines = mem.tokenizeScalar(u8, log, '\n');
    while (lines.next()) |raw| {
        const msg = messageOf(raw);
        var file: []const u8 = "";
        var dev: []const u8 = "";
        const direct = "Direct firmware load for ";
        const failed = "firmware: failed to load ";
        if (mem.indexOf(u8, msg, direct)) |i| {
            const rest = msg[i + direct.len ..];
            file = rest[0 .. mem.indexOf(u8, rest, " failed with error") orelse continue];
            dev = mem.trimEnd(u8, msg[0..i], ": ");
        } else if (mem.indexOf(u8, msg, failed)) |i| {
            const rest = msg[i + failed.len ..];
            file = rest[0 .. mem.indexOf(u8, rest, " (") orelse rest.len];
            dev = mem.trimEnd(u8, msg[0..i], ": ");
        } else continue;
        if (file.len == 0) continue;
        var seen = false;
        for (out.items) |f| seen = seen or vh.eql(f.file, file);
        if (!seen) out.append(vh.gpa, .{ .file = vh.dupe(file), .device = vh.dupe(dev) }) catch vh.oom();
    }
    return out.items;
}

/// the firmware the plan keeps on disk: the "noextract=!/usr/lib/firmware/PATTERN" lines of
/// the installer's xbps file; null when there is none (every file was extracted)
pub fn keepPatterns(conf: ?[]const u8) ?[]const []const u8 {
    const text = conf orelse return null;
    var out: vh.Strv = .{};
    var lines = mem.tokenizeScalar(u8, text, '\n');
    const p = "noextract=!/usr/lib/firmware/";
    while (lines.next()) |raw| {
        const line = vh.strip(raw);
        if (vh.startsWith(line, p)) out.add(line[p.len..]);
    }
    return out.slice();
}

/// what a firmware failure means: whether the file is on disk, and whether the trim left it out
pub fn firmwareLine(f: FwFail, keep: ?[]const []const u8, fwdir: []const u8) []const u8 {
    const what = printable(vh.fmt("{s} for {s}", .{ f.file, if (f.device.len > 0) f.device else "a driver" }));
    for ([_][]const u8{ "", ".zst", ".xz" }) |ext| {
        if (vh.pathExists(vh.fmt("{s}/{s}{s}", .{ fwdir, f.file, ext })))
            return vh.fmt("{s}: on disk, yet it did not load (dmesg)", .{what});
    }
    const pats = keep orelse return vh.fmt("{s}: not on disk (no package ships it?)", .{what});
    for (pats) |p| if (alias.fnmatch(p, f.file))
        return vh.fmt("{s}: kept by the plan but not on disk (is the package that ships it installed?)", .{what});
    return vh.fmt("{s}: the firmware trim leaves it out (/etc/xbps.d/40-vh-firmware.conf: keep it there, or in VH_FIRMWARE_KEEP, and reinstall its package with xbps-install -f)", .{what});
}

/// the kernel log of this boot, one message per line: /dev/kmsg gives a record per read; the
/// dictionary lines after a record's first line are dropped
fn readKmsg() []const u8 {
    const fd = vh.openFd("/dev/kmsg", .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0) catch {
        vh.warn("/dev/kmsg: {s}: firmware failures not checked", .{vh.serr()});
        return "";
    };
    defer vh.close(fd);
    var out: std.ArrayList(u8) = .empty;
    var buf: [8192]u8 = undefined;
    while (true) {
        const rc = linux.read(fd, &buf, buf.len);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            // records overwritten before they were read: go on with the next one
            .PIPE, .INTR => continue,
            // EAGAIN: the end of the log
            else => break,
        }
        if (rc == 0) break;
        const rec = buf[0..rc];
        out.appendSlice(vh.gpa, rec[0 .. mem.indexOfScalar(u8, rec, '\n') orelse rec.len]) catch vh.oom();
        out.append(vh.gpa, '\n') catch vh.oom();
    }
    return out.items;
}

pub const Result = struct {
    machine: []const []const u8,
    devices: []const []const u8,
    firmware: []const []const u8,
    /// of the devices, those that had a driver at installation
    lost: usize = 0,

    pub fn any(self: Result) bool {
        return self.machine.len > 0 or self.devices.len > 0 or self.firmware.len > 0;
    }

    pub fn summary(self: Result) []const u8 {
        return vh.fmt("VH_CHECK machine={s} devices={d} firmware={d} lost={d}\n", .{ if (self.machine.len > 0) "different" else "same", self.devices.len, self.firmware.len, self.lost });
    }
};

/// the message the admin sees at login; `plan` says where the fresh plan is, or why there is none
pub fn message(r: Result, hw_path: []const u8, plan: []const u8) []const u8 {
    var t: std.ArrayList(u8) = .empty;
    const w = struct {
        fn line(b: *std.ArrayList(u8), comptime f: []const u8, args: anytype) void {
            b.print(vh.gpa, f ++ "\n", args) catch vh.oom();
        }
    }.line;
    w(&t, "vh-kconf check: this boot differs from {s}, the probe this system was planned from.", .{hw_path});
    if (r.machine.len > 0) {
        w(&t, "", .{});
        w(&t, "Another machine: the plan, the kernel and the firmware on disk were chosen for the other one.", .{});
        for (r.machine) |x| w(&t, "  {s}", .{x});
        w(&t, "  (the devices are not compared: the fresh plan describes them)", .{});
    }
    if (r.devices.len > 0) {
        w(&t, "", .{});
        w(&t, "Devices without a driver ({d}):", .{r.devices.len});
        for (r.devices) |x| w(&t, "  {s}", .{x});
    }
    if (r.firmware.len > 0) {
        w(&t, "", .{});
        w(&t, "Firmware that failed to load ({d}):", .{r.firmware.len});
        for (r.firmware) |x| w(&t, "  {s}", .{x});
    }
    w(&t, "", .{});
    w(&t, "{s}", .{plan});
    w(&t, "What it means and what to do: docs/uni/runtime.md, \"vh-kconf check\".", .{});
    t.appendSlice(vh.gpa, r.summary()) catch vh.oom();
    return t.items;
}

/// `was` is the installation's probe, which tells the machine; `base` the view the devices are
/// judged against (the same, or the stock kernel's on a machine kernel), `at` names it.
pub fn compare(was: hw.Hw, base: hw.Hw, at: []const u8, now: hw.Hw, refused: []const []const u8, table: ?*const alias.Table, log: []const u8, keep: ?[]const []const u8, fwdir: []const u8) Result {
    const machine = machineDiff(was, now);
    var fw: vh.Strv = .{};
    for (firmwareFailures(log)) |f| fw.add(firmwareLine(f, keep, fwdir));
    // another machine has other devices: listing them all would hide the point
    const dl: Driverless = if (machine.len > 0) .{ .lines = &.{}, .lost = 0 } else driverless(base, now, refused, table, at);
    return .{
        .machine = machine,
        .devices = dl.lines,
        .firmware = fw.slice(),
        .lost = dl.lost,
    };
}

/// a fresh plan of the running system in DIR: hw.zon, then vh-plan by argv; the line that says
/// where it is, or why there is none
fn freshPlan(now: hw.Hw, dir: []const u8, vh_plan: []const u8, repo: []const u8) []const u8 {
    if (vh.eql(vh_plan, "none")) return "No fresh plan was made (--vh-plan none).";
    if (linux.errno(linux.access(vh.z(vh_plan).ptr, linux.X_OK)) != .SUCCESS)
        return vh.fmt("No fresh plan: {s} is missing (install/plan.sh builds it).", .{vh_plan});
    vh.mkdirs(dir, 0o755);
    const hw_path = vh.fmt("{s}/hw.zon", .{dir});
    vh.writeAtomic(hw_path, hw.render(now), 0o644);
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(vh.gpa, &.{ vh_plan, "plan", "--hw", hw_path, "--hwdb", vh.fmt("{s}/hwdb", .{repo}), "--pins", vh.fmt("{s}/kernel/pins", .{repo}), "--config", vh.fmt("{s}/vh.conf.example", .{repo}) }) catch vh.oom();
    const conf = vh.fmt("{s}/vh.conf", .{repo});
    if (vh.pathExists(conf)) argv.appendSlice(vh.gpa, &.{ "--config", conf }) catch vh.oom();
    argv.appendSlice(vh.gpa, &.{ "--out", dir }) catch vh.oom();
    var out: std.ArrayList(u8) = .empty;
    var err: std.ArrayList(u8) = .empty;
    const rc = vh.runOpts(argv.items, .{ .out = &out, .err = &err });
    // 3: the security gate refuses the machine; the plan is written all the same
    if (rc != 0 and rc != 3) return vh.fmt("No fresh plan: vh-plan failed ({d}): {s}", .{ rc, printable(vh.strip(err.items)) });
    const first = vh.strip(out.items[0 .. mem.indexOfScalar(u8, out.items, '\n') orelse out.items.len]);
    return vh.fmt("A fresh plan of this boot: {s}/plan-report.txt (vh-plan: {s}); compare it with /etc/vh/plan-report.txt.", .{ dir, printable(first) });
}

pub fn run(o: Opts) u8 {
    const root = mem.trimEnd(u8, o.root, "/");
    const hw_path = o.hw orelse vh.fmt("{s}/etc/vh/hw.zon", .{root});
    const out = o.out orelse vh.fmt("{s}/run/vh", .{root});
    if (!vh.pathExists(hw_path)) {
        vh.warn("{s}: no probe of the installation to compare with", .{hw_path});
        return 2;
    }
    const was = hw.load(hw_path);
    const src: probe.Src = .{ .root = mem.trimEnd(u8, o.from, "/") };
    const now = probe.run(&src);
    const cmdline_refused = refusedModules(src.read("/proc/cmdline") orelse "");
    const refused = if (isMachineKernel(now.probe.kernel))
        machineRefused(cmdline_refused, o.plan orelse vh.fmt("{s}/etc/vh/plan.zon", .{root}), vh.fmt("{s}/kernel/profiles", .{o.repo orelse vh.fmt("{s}/root/vh", .{root})}))
    else
        cmdline_refused;
    // the running kernel's tables: which module would drive a device that has none
    var table: alias.Table = .{};
    var have_table = false;
    const mdir = vh.fmt("{s}/lib/modules/{s}", .{ root, now.probe.kernel });
    if (vh.readFile(o.alias orelse vh.fmt("{s}/modules.alias", .{mdir}))) |t| {
        table.loadAliases(t);
        have_table = true;
    } else |_| {}
    if (vh.readFile(o.builtin orelse vh.fmt("{s}/modules.builtin.modinfo", .{mdir}))) |t| {
        table.loadBuiltinModinfo(t);
        have_table = true;
    } else |_| {}
    const log = if (o.kmsg) |f| (vh.readFile(f) catch vh.die("{s}: {s}", .{ f, vh.serr() })) else readKmsg();
    const keep = keepPatterns(vh.readFile(vh.fmt("{s}/etc/xbps.d/40-vh-firmware.conf", .{root})) catch null);
    // a machine kernel's devices against the stock kernel's view, when that kernel has booted
    const state_dir = vh.fmt("{s}/var/lib/vh", .{root});
    const stock_path = o.stock orelse vh.fmt("{s}/check/stock.zon", .{state_dir});
    const machine_kernel = isMachineKernel(now.probe.kernel);
    const on_stock = machine_kernel and vh.pathExists(stock_path);
    const base = if (on_stock) hw.load(stock_path) else was;
    const at = if (on_stock) vh.fmt("on the stock kernel ({s})", .{base.probe.kernel}) else "at installation";
    const r = compare(was, base, at, now, refused, if (have_table) &table else null, log, keep, vh.fmt("{s}/usr/lib/firmware", .{root}));
    if (!machine_kernel and r.machine.len == 0) {
        // /var/lib/vh, the system's state, is root's alone: this service may be the first to
        // make it, and vh.mkdirs makes the directories above the last one 0755
        if (o.stock == null) vh.mkdirs(state_dir, 0o700);
        vh.mkdirs(std.fs.path.dirname(stock_path) orelse ".", 0o700);
        vh.writeAtomic(stock_path, hw.render(now), 0o600);
    }

    vh.mkdirs(out, 0o755);
    vh.writeAtomic(vh.fmt("{s}/check.done", .{out}), r.summary(), 0o644);
    const msg_path = vh.fmt("{s}/check", .{out});
    if (!r.any()) {
        vh.unlink(msg_path) catch {};
        vh.out("vh-kconf check: this boot matches {s} ({d} devices, no firmware failure)\n{s}", .{ hw_path, now.devices.len, r.summary() });
        return 0;
    }
    const plan = freshPlan(now, vh.fmt("{s}/plan", .{out}), o.vh_plan orelse vh.fmt("{s}/usr/local/sbin/vh-plan", .{root}), o.repo orelse vh.fmt("{s}/root/vh", .{root}));
    const text = message(r, hw_path, plan);
    vh.writeAtomic(msg_path, text, 0o644);
    vh.outs(text);
    return 1;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "check: the kernel log's firmware failures" {
    const log =
        \\6,1203,5140900,-;wifidrv 0000:00:14.3: Direct firmware load for wifi/chip-93.ucode failed with error -2
        \\6,1204,5140950,-;wifidrv 0000:00:14.3: loaded firmware version 77 chip-77.ucode
        \\[    7.002000] nicdrv 0000:03:00.0: Direct firmware load for nic/chip-2.fw failed with error -2
        \\[    7.002010] nicdrv 0000:03:00.0: Unable to load firmware nic/chip-2.fw (-2)
        \\4,1300,7100000,-;bluetooth hci0: firmware: failed to load bt/chip-1.sfi (-2)
        \\6,1301,7200000,-;wifidrv 0000:00:14.3: Direct firmware load for wifi/chip-93.ucode failed with error -2
        \\
    ;
    const f = firmwareFailures(log);
    try testing.expectEqual(@as(usize, 3), f.len);
    try testing.expectEqualStrings("wifi/chip-93.ucode", f[0].file);
    try testing.expectEqualStrings("wifidrv 0000:00:14.3", f[0].device);
    try testing.expectEqualStrings("nic/chip-2.fw", f[1].file);
    try testing.expectEqualStrings("nicdrv 0000:03:00.0", f[1].device);
    try testing.expectEqualStrings("bt/chip-1.sfi", f[2].file);
    try testing.expectEqualStrings("bluetooth hci0", f[2].device);
    try testing.expectEqualStrings("plain", messageOf("plain"));
    try testing.expectEqualStrings("a; b", messageOf("a; b"));
    try testing.expectEqualStrings("c;x", messageOf("c;x"));
    try testing.expectEqualStrings("x", messageOf("12,5,77,c;x"));
}

test "check: refused modules, kept firmware" {
    const r = refusedModules("root=UUID=x module_blacklist=sctp,mei_me,tiny-power-button quiet");
    try testing.expectEqual(@as(usize, 3), r.len);
    try testing.expect(has(r, "mei_me") and has(r, "tiny_power_button"));
    try testing.expectEqual(@as(usize, 0), refusedModules("quiet").len);
    const keep = keepPatterns("# x\nnoextract=/usr/lib/firmware/*\nnoextract=!/usr/lib/firmware/nic/*\nnoextract=!/usr/lib/firmware/wifi/chip-*\n").?;
    try testing.expectEqual(@as(usize, 2), keep.len);
    try testing.expect(keepPatterns(null) == null);
    const dir = vh.fmt("/tmp/vh-check-test-{d}", .{linux.getpid()});
    vh.mkdirs(vh.fmt("{s}/nic", .{dir}), 0o755);
    vh.writeAtomic(vh.fmt("{s}/nic/chip-2.fw.zst", .{dir}), "x", 0o644);
    try testing.expect(mem.indexOf(u8, firmwareLine(.{ .file = "nic/chip-2.fw", .device = "nicdrv 0000:03:00.0" }, keep, dir), "on disk, yet") != null);
    try testing.expect(mem.indexOf(u8, firmwareLine(.{ .file = "nic/chip-3.fw", .device = "" }, keep, dir), "kept by the plan but not on disk") != null);
    try testing.expect(mem.indexOf(u8, firmwareLine(.{ .file = "bt/chip-1.sfi", .device = "" }, keep, dir), "the firmware trim leaves it out") != null);
    try testing.expect(mem.indexOf(u8, firmwareLine(.{ .file = "bt/chip-1.sfi", .device = "" }, null, dir), "not on disk") != null);
    _ = vh.runOpts(&.{ "rm", "-rf", dir }, .{});
    try testing.expectEqualStrings("a?b", printable("a\x1bb"));
}

fn fixtureHw(name: []const u8) ?hw.Hw {
    const p = probe.repoPath(vh.fmt("kernel/hw/{s}.zon", .{name})) orelse return null;
    return hw.load(p);
}

test "check: the same machine, another machine" {
    const gf63 = fixtureHw("gf63") orelse return error.SkipZigTest;
    const amd = fixtureHw("amd-desktop") orelse return error.SkipZigTest;
    const rpi = fixtureHw("rpi5") orelse return error.SkipZigTest;
    try testing.expectEqual(@as(usize, 0), machineDiff(gf63, gf63).len);
    const d = machineDiff(gf63, amd);
    try testing.expectEqual(@as(usize, 2), d.len);
    try testing.expect(vh.startsWith(d[0], vh.fmt("CPU {s} family {d} model {d}", .{ amd.cpu.vendor, amd.cpu.family, amd.cpu.model })));
    try testing.expect(mem.indexOf(u8, d[1], ", was ") != null);
    // another architecture, another CPU, another board (a device tree's model)
    try testing.expectEqual(@as(usize, 3), machineDiff(gf63, rpi).len);
    // the same CPU model with another stepping or microcode is the same machine
    var updated = gf63;
    updated.cpu.microcode = "0xff";
    updated.cpu.stepping = 3;
    try testing.expectEqual(@as(usize, 0), machineDiff(gf63, updated).len);
}

test "check: devices without a driver" {
    const gf63 = fixtureHw("gf63") orelse return error.SkipZigTest;
    const at = probe.repoPath("kernel/pins/modules.alias") orelse return error.SkipZigTest;
    var table: alias.Table = .{};
    table.loadAliases(vh.readFile(at) catch return error.SkipZigTest);
    // the installed system's view of the same machine: nothing new
    try testing.expectEqual(@as(usize, 0), driverless(gf63, gf63, &.{}, &table, "at installation").lines.len);
    var devs: std.ArrayList(hw.Device) = .empty;
    for (gf63.devices) |d| {
        var x = d;
        // the Wi-Fi lost its driver; the ME interface lost its, but the kernel refuses it
        if (vh.eql(x.name, "0000:00:14.3") or vh.eql(x.driver, "mei_me")) {
            x.driver = "";
            x.module = "";
        }
        devs.append(vh.gpa, x) catch vh.oom();
    }
    // new: a USB Ethernet adapter a module of the kernel knows, a PCI card none knows, an
    // ACPI device none knows (not news), and a USB4 controller whose module the kernel refuses
    devs.appendSlice(vh.gpa, &.{
        .{ .bus = "usb", .name = "2-1:1.0", .modalias = "usb:v0B95p1790d0200dcFFdscFFdp00icFFiscFFip00in00" },
        .{ .bus = "pci", .name = "0000:05:00.0", .modalias = "pci:v0000ABCDd00001234sv00000000sd00000000bcFFsc00i00" },
        .{ .bus = "acpi", .name = "ABCD0001:00", .modalias = "acpi:ABCD0001:" },
        .{ .bus = "pci", .name = "0000:06:00.0", .modalias = "pci:v0000ABCDd00005678sv00000000sd00000000bc0Csc03i40" },
    }) catch vh.oom();
    var now = gf63;
    now.devices = devs.items;
    const dl = driverless(gf63, now, &.{ "mei_me", "thunderbolt" }, &table, "at installation");
    const r = dl.lines;
    try testing.expectEqual(@as(usize, 3), r.len);
    try testing.expect(mem.indexOf(u8, r[0], "0000:00:14.3") != null and mem.indexOf(u8, r[0], "had the driver iwlwifi") != null);
    try testing.expect(mem.indexOf(u8, r[1], "2-1:1.0") != null and mem.indexOf(u8, r[1], "ax88179_178a would drive it") != null);
    try testing.expect(mem.indexOf(u8, r[2], "0000:05:00.0") != null and mem.indexOf(u8, r[2], "no driver of this kernel") != null);
    // of the three only the Wi-Fi had a driver at installation: the verdict of a boot assessment
    try testing.expectEqual(@as(usize, 1), dl.lost);
}

test "check: a machine kernel against the stock kernel's view" {
    const q35 = fixtureHw("qemu-q35") orelse return error.SkipZigTest;
    // the rig at installation: the live image's 6.12 drove the fixed power button with button;
    // 6.18, the stock kernel and the machine one, leaves the ACPI device without a driver
    var devs: std.ArrayList(hw.Device) = .empty;
    var had = false;
    for (q35.devices) |d| {
        var x = d;
        if (vh.eql(x.name, "LNXPWRBN:00")) {
            had = vh.eql(x.driver, "button");
            x.driver = "";
            x.module = "";
        }
        devs.append(vh.gpa, x) catch vh.oom();
    }
    try testing.expect(had);
    var stock = q35;
    stock.devices = devs.items;
    stock.probe.kernel = "6.18.57_1";
    var now = stock;
    now.probe.kernel = "6.18.57-vh";
    // against the installation's probe the machine kernel lost the button ...
    const a = compare(q35, q35, "at installation", now, &.{}, null, "", null, "/nonexistent");
    try testing.expectEqual(@as(usize, 1), a.lost);
    try testing.expect(mem.indexOf(u8, a.devices[0], "LNXPWRBN:00") != null and mem.indexOf(u8, a.devices[0], "at installation") != null);
    // ... against the stock kernel's view it lost nothing, and it is still the same machine
    const b = compare(q35, stock, "on the stock kernel (6.18.57_1)", now, &.{}, null, "", null, "/nonexistent");
    try testing.expectEqual(@as(usize, 0), b.lost);
    try testing.expectEqual(@as(usize, 0), b.machine.len);
    // a device the stock kernel drives and the machine kernel does not is a loss, named so
    var lost_nic = std.ArrayList(hw.Device).empty;
    for (now.devices) |d| {
        var x = d;
        if (vh.eql(x.driver, "e1000")) {
            x.driver = "";
            x.module = "";
        }
        lost_nic.append(vh.gpa, x) catch vh.oom();
    }
    var now2 = now;
    now2.devices = lost_nic.items;
    const c = compare(q35, stock, "on the stock kernel (6.18.57_1)", now2, &.{}, null, "", null, "/nonexistent");
    try testing.expectEqual(@as(usize, 1), c.lost);
    try testing.expect(mem.indexOf(u8, c.devices[0], "had the driver e1000 on the stock kernel (6.18.57_1)") != null);
}

test "check: a machine kernel refuses what its build left out" {
    const gf63 = fixtureHw("gf63") orelse return error.SkipZigTest;
    const plan = probe.repoPath("tests/adapt/golden/gf63/strict/plan.zon") orelse return error.SkipZigTest;
    const profiles = probe.repoPath("kernel/profiles") orelse return error.SkipZigTest;
    try testing.expect(isMachineKernel("6.18.57-vh") and !isMachineKernel("6.18.57_1"));
    // the installer probed in the live system, where the camera and the card reader had their
    // drivers; the plan refuses both (VH_CAMERA=no, VH_CARDREADER=no), so the machine kernel
    // is built without them and the command line names no module
    var devs: std.ArrayList(hw.Device) = .empty;
    for (gf63.devices) |d| {
        var x = d;
        if (vh.eql(x.driver, "uvcvideo") or vh.eql(x.driver, "rtsx_pci")) {
            x.driver = "";
            x.module = "";
        }
        devs.append(vh.gpa, x) catch vh.oom();
    }
    var now = gf63;
    now.devices = devs.items;
    now.probe.kernel = "6.18.57-vh";
    // read as the stock kernel would read it: three devices lost their drivers
    try testing.expectEqual(@as(usize, 3), driverless(gf63, now, &.{}, null, "at installation").lost);
    // the machine kernel's refused modules: modules.deny, the plan's, the unselected features'
    const refused = machineRefused(&.{"sctp"}, plan, profiles);
    for ([_][]const u8{ "sctp", "tiny_power_button", "uvcvideo", "rtsx_pci", "nouveau", "mei_me", "videobuf2_common" }) |m|
        try testing.expect(has(refused, m));
    try testing.expect(!has(refused, "iwlwifi") and !has(refused, "btusb"));
    const dl = driverless(gf63, now, refused, null, "at installation");
    try testing.expectEqual(@as(usize, 0), dl.lost);
    try testing.expectEqual(@as(usize, 0), dl.lines.len);
    // without the plan only the command line's refusals are known
    const bare = machineRefused(&.{"sctp"}, "/nonexistent/plan.zon", profiles);
    try testing.expectEqual(@as(usize, 1), bare.len);
}

test "check: the whole run on a fixture, the message and the summary" {
    const from = probe.repoPath("tests/kernel/fixtures/gf63") orelse return error.SkipZigTest;
    const gf63 = probe.repoPath("kernel/hw/gf63.zon") orelse return error.SkipZigTest;
    const amd = probe.repoPath("kernel/hw/amd-desktop.zon") orelse return error.SkipZigTest;
    const dir = vh.fmt("/tmp/vh-check-run-{d}", .{linux.getpid()});
    _ = vh.runOpts(&.{ "rm", "-rf", dir }, .{});
    vh.mkdirs(vh.fmt("{s}/etc/xbps.d", .{dir}), 0o755);
    vh.writeAtomic(vh.fmt("{s}/etc/xbps.d/40-vh-firmware.conf", .{dir}), "noextract=/usr/lib/firmware/*\nnoextract=!/usr/lib/firmware/wifi/*\n", 0o644);
    const quiet = vh.fmt("{s}/quiet.log", .{dir});
    vh.writeAtomic(quiet, "6,1,1,-;usb 1-14: new full-speed USB device number 3 using xhci_hcd\n", 0o644);
    const fw = vh.fmt("{s}/fw.log", .{dir});
    vh.writeAtomic(fw, "6,1,1,-;bluetooth hci0: Direct firmware load for bt/chip-1.sfi failed with error -2\n", 0o644);
    // the same machine, a quiet log: nothing to say
    try testing.expectEqual(@as(u8, 0), run(.{ .from = from, .root = dir, .hw = gf63, .kmsg = quiet, .vh_plan = "none" }));
    try testing.expectEqualStrings("VH_CHECK machine=same devices=0 firmware=0 lost=0", vh.rd(vh.fmt("{s}/run/vh/check.done", .{dir})));
    try testing.expect(!vh.pathExists(vh.fmt("{s}/run/vh/check", .{dir})));
    // a firmware file the trim left out
    try testing.expectEqual(@as(u8, 1), run(.{ .from = from, .root = dir, .hw = gf63, .kmsg = fw, .vh_plan = "none" }));
    const msg = vh.readFile(vh.fmt("{s}/run/vh/check", .{dir})) catch return error.TestUnexpectedResult;
    try testing.expect(mem.indexOf(u8, msg, "bt/chip-1.sfi for bluetooth hci0: the firmware trim leaves it out") != null);
    try testing.expect(mem.indexOf(u8, msg, "VH_CHECK machine=same devices=0 firmware=1 lost=0") != null);
    // the disk moved to another machine
    try testing.expectEqual(@as(u8, 1), run(.{ .from = from, .root = dir, .hw = amd, .kmsg = quiet, .vh_plan = "none" }));
    try testing.expectEqualStrings("VH_CHECK machine=different devices=0 firmware=0 lost=0", vh.rd(vh.fmt("{s}/run/vh/check.done", .{dir})));
    // then the same machine again: the message goes away
    try testing.expectEqual(@as(u8, 0), run(.{ .from = from, .root = dir, .hw = gf63, .kmsg = quiet, .vh_plan = "none" }));
    try testing.expect(!vh.pathExists(vh.fmt("{s}/run/vh/check", .{dir})));
    _ = vh.runOpts(&.{ "rm", "-rf", dir }, .{});
}

test "check: the stock kernel's view and the state directory are root's alone" {
    const from = probe.repoPath("tests/kernel/fixtures/gf63") orelse return error.SkipZigTest;
    const gf63 = probe.repoPath("kernel/hw/gf63.zon") orelse return error.SkipZigTest;
    const dir = vh.fmt("/tmp/vh-check-modes-{d}", .{linux.getpid()});
    _ = vh.runOpts(&.{ "rm", "-rf", dir }, .{});
    vh.mkdirs(dir, 0o755);
    const quiet = vh.fmt("{s}/quiet.log", .{dir});
    vh.writeAtomic(quiet, "", 0o644);
    // the stock kernel on the same machine writes its view, and nothing of /var/lib/vh is
    // there yet: on the way to check/ vh.mkdirs alone would make /var/lib/vh 0755
    try testing.expectEqual(@as(u8, 0), run(.{ .from = from, .root = dir, .hw = gf63, .kmsg = quiet, .vh_plan = "none" }));
    for ([_]struct { []const u8, u32 }{ .{ "var/lib/vh", 0o700 }, .{ "var/lib/vh/check", 0o700 }, .{ "var/lib/vh/check/stock.zon", 0o600 } }) |x| {
        const st = vh.stat(vh.fmt("{s}/{s}", .{ dir, x[0] }), false) catch return error.TestUnexpectedResult;
        try testing.expectEqual(x[1], @as(u32, st.mode & 0o7777));
    }
    _ = vh.runOpts(&.{ "rm", "-rf", dir }, .{});
}
