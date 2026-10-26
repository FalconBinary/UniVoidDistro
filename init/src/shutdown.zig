//! vh-init: stage 3 natively, what runit-void's /etc/runit/3 and its shutdown.d scripts do
//! (docs/ROADMAP.md, I: "Shutdown"): every remaining process TERM then KILL, the seed for the
//! next boot, the wtmp record, swap off, the file systems synced and read-only, the deadman
//! module's final step when it is enabled, then reboot(2). Each step is timed into the kernel
//! log like stage 1; nothing here is allowed to fail the shutdown.
const std = @import("std");
const linux = std.os.linux;
const mem = std.mem;
const vh = @import("vh");
const sys = @import("sys.zig");
const seed = @import("seed.zig");
const misc = @import("misc.zig");

pub const Kind = enum { poweroff, reboot, halt };

fn note(comptime f: []const u8, args: anytype) void {
    sys.msg(f, args);
    _ = sys.kmsg("vh-init: " ++ f, args);
}

/// a short wait for processes to exit after a signal, reaping them as they go (at most `ms`)
fn waitChildren(ms: u64) void {
    const t0 = sys.monoUs();
    while (sys.monoUs() - t0 < ms * 1000) {
        var st: i32 = 0;
        const rc = linux.wait4(-1, &st, linux.W.NOHANG, null);
        const e = linux.errno(rc);
        if (e == .CHILD) return; // nothing left to reap
        if (rc == 0) {
            const ts: linux.timespec = .{ .sec = 0, .nsec = 50_000_000 };
            _ = linux.nanosleep(&ts, null);
        }
    }
}

/// every swap device off (zram, fstab swap)
fn swapoffAll() void {
    const text = vh.readFile("/proc/swaps") catch return;
    var lines = mem.tokenizeScalar(u8, text, '\n');
    _ = lines.next(); // the header
    while (lines.next()) |line| {
        var f = mem.tokenizeAny(u8, line, " \t");
        const dev = f.next() orelse continue;
        _ = linux.syscall1(.swapoff, @intFromPtr(vh.z(dev).ptr));
    }
}

/// the mounts in the reverse order of mountinfo (the deepest first): detached lazily, the
/// root remounted read-only; API file systems are left to the kernel
fn umountAll() void {
    const info = sys.MountInfo.load();
    var k: usize = info.entries.len;
    while (k > 0) {
        k -= 1;
        const e = info.entries[k];
        if (vh.eql(e.target, "/") or vh.startsWith(e.target, "/proc") or vh.startsWith(e.target, "/sys") or vh.startsWith(e.target, "/dev") or vh.startsWith(e.target, "/run")) continue;
        _ = linux.umount2(vh.z(e.target).ptr, linux.MNT.DETACH);
    }
    _ = linux.mount(null, "/", null, linux.MS.REMOUNT | linux.MS.RDONLY, 0);
}

/// the whole of stage 3; returns only when reboot(2) itself failed (a container without the right)
pub fn run(kind: Kind, container: bool) void {
    const t0 = sys.monoUs();
    note("stage 3: {s}", .{@tagName(kind)});
    // 1. whatever still runs (the manager has stopped the services): TERM, a moment, KILL
    _ = linux.kill(-1, .TERM);
    waitChildren(2000);
    _ = linux.kill(-1, .KILL);
    waitChildren(500);
    if (!container) {
        // 2. the seed for the next boot (the same algorithm as at boot: seedrng)
        seed.load(false);
        // 3. the shutdown record of wtmp (halt -w)
        misc.wtmpShutdown();
        // 4. swap off, before the root goes read-only
        swapoffAll();
    }
    linux.sync();
    // 5. the deadman module: wipes the volume key and reboots through the firmware (MOR); it does not return
    if (!container and vh.pathExists("/etc/vh/optional/deadman") and vh.isRegular("/usr/local/sbin/vh-deadman")) {
        note("wiping the LUKS key and RAM (vh-deadman final)...", .{});
        _ = sys.exec(&.{ "/usr/local/sbin/vh-deadman", "final" });
    }
    if (!container) umountAll();
    linux.sync();
    note("stage 3 done in {d} ms", .{(sys.monoUs() - t0 + 500) / 1000});
    const cmd: linux.LINUX_REBOOT.CMD = switch (kind) {
        .poweroff => .POWER_OFF,
        .reboot => .RESTART,
        .halt => .HALT,
    };
    const rc = linux.reboot(.MAGIC1, .MAGIC2, cmd, null);
    sys.fail("reboot(2): {s}", .{@tagName(linux.errno(rc))});
}
