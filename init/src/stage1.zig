//! vh-stage1: runit's stage 1 (/etc/runit/1) and the core-services of void-hardperf-light
//! as one Zig program without a shell (docs/ROADMAP.md, I: "Stage 1 natively"). runit
//! stays PID 1 and runs this file; stage 2 and 3 are unchanged. The steps are the ones of
//! runit-void's /etc/runit/core-services/*.sh plus the *-vh-* scripts, in the same order
//! (see `steps`); the programs that cannot be replaced (udevd, udevadm, modprobe, nft,
//! apparmor_parser) are run by argv. Each step is timed; "vh-stage1: done in N ms" and
//! the per-step times go to the kernel log for bench/init.
//!
//!   vh-stage1                 stage 1 (how runit runs it as /etc/runit/1)
//!   vh-stage1 --install       install as /etc/runit/1, keep the previous file as 1.orig
//!   vh-stage1 --rollback      put /etc/runit/1.orig back
//!   vh-stage1 --status        which stage 1 is installed; the markers of this boot
//!   vh-stage1 --list          the steps in order
//!   vh-stage1 --step A,B ...  only these steps (tests); --root DIR puts every path under DIR;
//!                             --force runs the steps that are skipped in a container; -v prints every setting
const std = @import("std");
const linux = std.os.linux;
const mem = std.mem;
const vh = @import("vh");
const sys = @import("sys.zig");
const mounts = @import("mounts.zig");
const sysctl = @import("sysctl.zig");
const misc = @import("misc.zig");
const vhsteps = @import("vhsteps.zig");
const udev = @import("udev.zig");
const setup = @import("setup.zig");

pub const version = "0.1.0";

comptime {
    _ = @import("seed.zig");
    _ = @import("tz.zig");
}

const Ctx = struct {
    container: bool = false,
    /// --force: the steps and parts skipped in a container run anyway (tests)
    force: bool = false,
    rc: vh.Kv = .{},
    conf: vh.Kv = .{},
    env: vh.Kv = .{},
};
var ctx: Ctx = .{};

const Step = struct {
    name: []const u8,
    run: *const fn () void,
    /// runit-void skips it in a container (LXC, podman, docker)
    not_in_container: bool = false,
};

/// the order of runit-void's core-services with the vh scripts interleaved by their numbers
pub const steps = [_]Step{
    .{ .name = "pseudofs", .run = stPseudofs }, // 00-pseudofs.sh
    .{ .name = "vh-selinux", .run = vhsteps.selinuxLoad }, // the policy, before any process is started (docs/uni/selinux.md)
    .{ .name = "static-devnodes", .run = misc.staticDevnodes }, // 01-static-devnodes.sh
    .{ .name = "kmods", .run = misc.kmods, .not_in_container = true }, // 02-kmods.sh
    .{ .name = "udev-start", .run = udev.start, .not_in_container = true }, // 02-udev.sh
    .{ .name = "udev-trigger", .run = udev.trigger, .not_in_container = true },
    .{ .name = "udev-settle", .run = udev.settle, .not_in_container = true },
    .{ .name = "console", .run = stConsole, .not_in_container = true }, // 03-console-setup.sh
    .{ .name = "remount-root", .run = mounts.remountRoot, .not_in_container = true }, // 03-filesystems.sh
    .{ .name = "mount-all", .run = mounts.mountAll, .not_in_container = true },
    .{ .name = "vh-selinux-label", .run = vhsteps.selinuxLabel }, // the labels of what stage 1 mounted
    .{ .name = "swap", .run = mounts.swapAll, .not_in_container = true }, // 04-swap.sh
    .{ .name = "vh-mounts", .run = stVhMounts }, // 04-vh-mounts.sh
    .{ .name = "misc", .run = stMisc }, // 05-misc.sh
    .{ .name = "vh-zram", .run = stZram }, // 05-vh-zram.sh
    .{ .name = "vh-nftables", .run = vhsteps.nftables }, // 06-vh-nftables.sh
    .{ .name = "vh-mm", .run = vhsteps.thp }, // 07-vh-mm.sh
    .{ .name = "sysctl", .run = sysctl.apply }, // 08-sysctl.sh
    .{ .name = "vh-apparmor", .run = vhsteps.apparmor }, // 09-vh-apparmor.sh
    .{ .name = "runit-control", .run = misc.runitControl }, // 10-runit-control.sh
    .{ .name = "vh-runtime", .run = stRuntime }, // 11-vh-runtime.sh
    .{ .name = "vh-suid", .run = vhsteps.suid }, // 12-vh-suid.sh
    .{ .name = "dmesg", .run = misc.dmesgLog }, // 97-dmesg.sh
    .{ .name = "sbin-merge", .run = misc.sbinMerge }, // 98-sbin-merge.sh
    .{ .name = "vh-game", .run = vhsteps.game }, // 98-vh-game.sh (vh-game boot on)
    .{ .name = "cleanup", .run = misc.cleanup }, // 99-cleanup.sh
    .{ .name = "vh-modlock", .run = vhsteps.modlock }, // 99-zz-vh-modlock.sh
};

fn stPseudofs() void {
    mounts.pseudofs(ctx.container, ctx.rc.get("CGROUP_MODE", "unified"));
}

fn stConsole() void {
    misc.console(.{
        .font = ctx.rc.get("FONT", ""),
        .font_map = ctx.rc.get("FONT_MAP", ""),
        .font_unimap = ctx.rc.get("FONT_UNIMAP", ""),
        .ttys = vh.parseLong(ctx.rc.get("TTYS", "12")) orelse 12,
        .keymap = ctx.rc.get("KEYMAP", ""),
        .hardwareclock = ctx.rc.get("HARDWARECLOCK", ""),
    });
}

fn stVhMounts() void {
    mounts.vhMounts(ctx.conf.get("VH_SHM_SIZE", "25%"));
}

fn stMisc() void {
    const skip = std.ascii.eqlIgnoreCase(ctx.rc.get("SEEDRNG_SKIP_CREDIT", "false"), "true");
    misc.misc(ctx.container and !ctx.force, skip, ctx.rc.get("HOSTNAME", ""), ctx.rc.get("TIMEZONE", ""));
}

fn stZram() void {
    const percent = vh.parseLong(ctx.conf.get("VH_ZRAM_PERCENT", "50")) orelse 50;
    vhsteps.zram(ctx.conf.get("VH_ZRAM_ALGO", "zstd"), @intCast(@max(percent, 0)));
}

fn stRuntime() void {
    vhsteps.runtime(ctx.env.get("VH_USER", "user"), ctx.env.get("VH_BROWSER_USER", "browser"));
}

/// LXC, podman (the container variable), docker (/.dockerenv), as detect_container
fn detectContainer() bool {
    return vh.getenv("container") != null or vh.pathExists("/.dockerenv");
}

const Timing = struct { name: []const u8, us: u64 };

/// stage 1 for vh-init (PID 1): every step, the markers as vh-stage1 writes them; the number of errors
pub fn runBoot() usize {
    run(null, false);
    return sys.failures;
}

/// the whole stage 1, or only the selected steps
fn run(selected: ?[]const []const u8, force: bool) void {
    const t0 = sys.monoUs();
    ctx.container = detectContainer();
    ctx.force = force;
    ctx.rc.read(sys.p("/etc/rc.conf"), true);
    ctx.conf.read(sys.p(setup.conf), true);
    ctx.env.read(sys.p("/etc/vh/vh.env"), true);
    const whole = selected == null;
    if (whole) sys.msg("void-hardperf-light: stage 1 (vh-stage1 {s})", .{version});
    if (ctx.container) sys.detail("container detected: udev, modules, console, fstab and swap are skipped{s}", .{if (force) " (--force: not skipped)" else ""});
    // the start marker at the entry (after an initramfs /dev exists already); without /dev
    // it is written after the pseudofs step, with that step's time named
    var marked = false;
    if (whole) marked = sys.kmsg("vh-stage1: start", .{});

    var times: std.ArrayList(Timing) = .empty;
    for (steps, 0..) |s, i| {
        if (selected) |names| {
            var wanted = false;
            for (names) |n| if (vh.eql(n, s.name)) {
                wanted = true;
                break;
            };
            if (!wanted) continue;
        }
        if (s.not_in_container and ctx.container and !force) continue;
        const a = sys.monoUs();
        s.run();
        const dt = sys.monoUs() - a;
        times.append(vh.gpa, .{ .name = s.name, .us = dt }) catch vh.oom();
        if (whole and i == 0 and !marked) marked = sys.kmsg("vh-stage1: start (after pseudofs, {d} ms)", .{(dt + 500) / 1000});
    }
    const total = sys.monoUs() - t0;

    var line: std.ArrayList(u8) = .empty;
    for (times.items) |t| line.print(vh.gpa, "{s}={d} ", .{ t.name, (t.us + 500) / 1000 }) catch vh.oom();
    if (whole) {
        sys.msg("Initialization complete, running stage 2...", .{});
        _ = sys.kmsg("vh-stage1: done in {d} ms ({d} errors)", .{ (total + 500) / 1000, sys.failures });
        for (splitLine(line.items, 900), 0..) |part, i| _ = sys.kmsg("vh-stage1: steps{s} {s}", .{ if (i == 0) "" else " (cont.)", part });
        vh.mkdirs(sys.p("/run/vh"), 0o755);
        _ = sys.writeFile(sys.p(setup.status_file), vh.fmt("done {d} ms\nerrors {d}\nsteps {s}\n", .{ (total + 500) / 1000, sys.failures, line.items }), 0o644);
    } else {
        for (times.items) |t| vh.out("{s}: {d}.{d:0>3} ms\n", .{ t.name, t.us / 1000, t.us % 1000 });
        vh.out("total {d}.{d:0>3} ms, {d} errors\n", .{ total / 1000, total % 1000, sys.failures });
    }
    vh.flush();
}

/// a kmsg line holds about 1000 bytes: the step list is split at a space
pub fn splitLine(text: []const u8, max: usize) []const []const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var rest = mem.trimEnd(u8, text, " ");
    while (rest.len > max) {
        const cut = mem.lastIndexOfScalar(u8, rest[0..max], ' ') orelse max;
        parts.append(vh.gpa, rest[0..cut]) catch vh.oom();
        rest = mem.trimStart(u8, rest[cut..], " ");
    }
    parts.append(vh.gpa, rest) catch vh.oom();
    return parts.items;
}

fn usage() noreturn {
    vh.outs(
        \\vh-stage1: runit stage 1 without a shell (void-hardperf-light, init/)
        \\  vh-stage1                 run stage 1 (as /etc/runit/1)
        \\  vh-stage1 --install       install as /etc/runit/1; the previous file becomes /etc/runit/1.orig
        \\  vh-stage1 --rollback      restore /etc/runit/1.orig
        \\  vh-stage1 --status        which stage 1 is installed, the markers of this boot
        \\  vh-stage1 --list          the steps in order
        \\  vh-stage1 [--step A,B] [--root DIR] [--force] [-v]   tests: only these steps, paths under DIR
        \\
    );
    vh.exit(2);
}

pub fn main(init: std.process.Init.Minimal) void {
    const args = vh.init(init, "vh-stage1");
    vh.setenv("PATH", "/usr/bin:/usr/sbin:/usr/local/sbin:/usr/local/bin");
    _ = linux.syscall1(.umask, 0o022);
    var selected: ?[]const []const u8 = null;
    var force = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (vh.eql(a, "--install")) {
            vh.exit(setup.install());
        } else if (vh.eql(a, "--rollback")) {
            vh.exit(setup.rollback());
        } else if (vh.eql(a, "--status")) {
            vh.exit(setup.status());
        } else if (vh.eql(a, "--version")) {
            vh.out("vh-stage1 {s}\n", .{version});
            vh.exit(0);
        } else if (vh.eql(a, "--list")) {
            for (steps) |s| vh.out("{s}{s}\n", .{ s.name, if (s.not_in_container) "  (not in a container)" else "" });
            vh.exit(0);
        } else if (vh.eql(a, "--step")) {
            i += 1;
            if (i >= args.len) usage();
            var list: std.ArrayList([]const u8) = .empty;
            var it = mem.tokenizeScalar(u8, args[i], ',');
            while (it.next()) |n| {
                var known = false;
                for (steps) |s| if (vh.eql(s.name, n)) {
                    known = true;
                    break;
                };
                if (!known) vh.die("unknown step {s} (vh-stage1 --list)", .{n});
                list.append(vh.gpa, n) catch vh.oom();
            }
            selected = list.items;
            sys.boot_mode = false;
        } else if (vh.eql(a, "--root")) {
            i += 1;
            if (i >= args.len) usage();
            sys.root = mem.trimEnd(u8, args[i], "/");
            sys.boot_mode = false;
        } else if (vh.eql(a, "--force")) {
            force = true;
        } else if (vh.eql(a, "-v")) {
            sys.verbose = true;
        } else usage();
    }
    run(selected, force);
    vh.exit(0);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "steps: the order of the core-services" {
    var prev: usize = 0;
    for ([_][]const u8{ "pseudofs", "vh-selinux", "udev-settle", "remount-root", "vh-selinux-label", "vh-mounts", "vh-zram", "vh-nftables", "sysctl", "vh-apparmor", "vh-suid", "vh-game", "cleanup", "vh-modlock" }) |name| {
        var idx: usize = 0;
        for (steps, 0..) |s, i| if (vh.eql(s.name, name)) {
            idx = i;
        };
        try testing.expect(idx >= prev);
        prev = idx;
    }
    try testing.expectEqualStrings("vh-modlock", steps[steps.len - 1].name);
    try testing.expectEqualStrings("pseudofs", steps[0].name);
}

test "the kmsg step line is split at spaces" {
    const parts = splitLine("a=1 b=22 c=333 d=4444 ", 9);
    try testing.expectEqual(@as(usize, 3), parts.len);
    try testing.expectEqualStrings("a=1 b=22", parts[0]);
    try testing.expectEqualStrings("c=333", parts[1]);
    try testing.expectEqualStrings("d=4444", parts[2]);
    try testing.expectEqual(@as(usize, 1), splitLine("short", 900).len);
}
