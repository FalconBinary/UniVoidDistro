//! vh-limine-update: rebuilds the boot chain on the ESP (docs/03-boot.md).
//!
//! 1. Keeps the KEEP newest UKIs on the ESP (plus the UKI of the running kernel), deletes the rest.
//! 2. Signs the UKIs with the db key (sbctl).
//! 3. Writes limine.conf: one entry per UKI, the path carrying its BLAKE2B hash (Limine checks the file).
//! 4. Takes a clean BOOTX64.EFI from the limine package, enrolls the BLAKE2B of the config
//!    into it (limine enroll-config), signs it and atomically replaces the copy on the ESP.
//!
//! With Secure Boot and the enrolled hash, Limine checks the config at every boot, disables
//! the editor and requires a hash on every path.
//!
//! UniVoidDistro: a second series, the machine UKIs linux-A.B.C-vh_N.efi (vh-kconf install),
//! rotated on their own (KEEP_MACHINE) after the stock entries, which stay at the head of the
//! menu and are never deleted for them. A new machine UKI is on trial: booted through Limine's
//! one-shot entry, and Limine's default (LoaderEntryDefault) after MACHINE_BOOTS good boots;
//! limine.conf does not change for either (lib/assess.zig, docs/uni/kernel.md).
//!
//! UniVoidDistro, track G: the gaming boot (vh-game boot on, docs/uni/game.md). While
//! /etc/vh/game-boot exists, the newest stock UKI has a twin in EFI/vh-game, the same image
//! with ia32_emulation=1 (lib/twin.zig), signed and last in the menu as "(games)"; never the
//! default. --game-once makes it the next boot's one-shot entry (vh-game play).
//!
//!   vh-limine-update [--new VERSION] [--dry-run]
//!   vh-limine-update --booted | --status | --retry [NAME] | --demote | --game-once
const std = @import("std");
const vh = @import("vh");
const hash = @import("hash");
const assess = @import("assess");
const twin = @import("twin");
const linux = std.os.linux;
const mem = std.mem;

const ESP = "/boot/efi";
const UKI_DIR = ESP ++ "/EFI/void";
const LIMINE_DIR = ESP ++ "/EFI/BOOT";
const LIMINE_SRC = "/usr/share/limine/BOOTX64.EFI";
const BOOT_CONF = "/etc/vh/boot.conf";
const DB_KEY = "/var/lib/sbctl/keys/db/db.key";
// the boot assessment of the machine UKIs (docs/uni/kernel.md)
const ASSESS = "/var/lib/vh/boot-assess";
const ASSESS_LOCK = "/var/lib/vh/boot-assess.lock";
const ASSESS_MSG = "/run/vh/boot-assess";
const CHECK_DONE = "/run/vh/check.done";
const BOOT_ID = "/proc/sys/kernel/random/boot_id";
const TOTP_CONF = "/etc/vh/totp.conf";
/// how long --booted waits for the verdict of vh-kconf check (the vh-check service starts 5 s
/// after the services)
const VERDICT_WAIT_S = 120;
/// the gaming boot (vh-game boot on): this file turns it on; the twin lives in a directory of
/// its own on the ESP, under the stock UKI's file name
const GAME_MARK = "/etc/vh/game-boot";
const GAME_DIR = ESP ++ "/EFI/vh-game";

const Series = enum { stock, machine };

const Uki = struct {
    name: []const u8,
    /// "6.18.56_1" or "6.18.57-vh_2", as in the file name
    ver: []const u8,
    v: [4]u64,
    series: Series = .stock,
};

/// linux-A.B.C_D.efi (stock) or linux-A.B.C-vh_N.efi (a machine kernel, uname -r A.B.C-vh)
/// -> the version numbers; null means not a UKI
pub fn parseUki(name: []const u8) ?Uki {
    if (!vh.startsWith(name, "linux-") or !vh.endsWith(name, ".efi")) return null;
    const end = name.len - 4;
    const seps = [3]u8{ '.', '.', '_' };
    var u: Uki = .{ .name = name, .ver = name[6..end], .v = undefined };
    var p: usize = 6;
    for (0..4) |i| {
        var q = p;
        while (q < end and std.ascii.isDigit(name[q])) q += 1;
        if (q == p or q - p > 9) return null;
        u.v[i] = std.fmt.parseInt(u64, name[p..q], 10) catch return null;
        if (i == 2 and vh.startsWith(name[q..end], "-vh_")) {
            u.series = .machine;
            p = q + 4;
            continue;
        }
        if (i < 3 and (q >= end or name[q] != seps[i])) return null;
        if (i == 3 and q != end) return null;
        p = q + 1;
    }
    return u;
}

fn findVer(list: []const Uki, ver: []const u8) ?Uki {
    for (list) |u| if (vh.eql(u.ver, ver)) return u;
    return null;
}

/// descending by version, ties broken by descending name
fn ukiDesc(_: void, x: Uki, y: Uki) bool {
    for (0..4) |i| if (x.v[i] != y.v[i]) return x.v[i] > y.v[i];
    return mem.order(u8, x.name, y.name) == .gt;
}

fn secureBootEnabled() bool {
    const dir = "/sys/firmware/efi/efivars";
    const names = vh.listDir(dir) catch return false;
    var first: ?[]const u8 = null;
    for (names) |n| if (vh.startsWith(n, "SecureBoot-")) {
        if (first == null or vh.lessStr({}, n, first.?)) first = n;
    };
    const d = vh.readFile(vh.fmt("{s}/{s}", .{ dir, first orelse return false })) catch return false;
    return d.len > 4 and d[4] == 1;
}

fn isMount(path: []const u8) bool {
    const a = vh.stat(path, false) catch return false;
    if (vh.S.isLnk(a.mode)) return false;
    const b = vh.stat(vh.fmt("{s}/..", .{path}), false) catch return false;
    return a.dev_major != b.dev_major or a.dev_minor != b.dev_minor or a.ino == b.ino;
}

fn sign(path: []const u8, dry: bool, offline: bool) void {
    if (!vh.pathExists(DB_KEY)) {
        if (offline)
            vh.die("the key media is not attached (" ++ DB_KEY ++ "): signing is impossible.\n" ++
                "  Attach it and retry: doas vh-keys mount && doas xbps-reconfigure -f " ++
                "<kernel package>; then doas vh-keys umount (docs/13, sb-offline-keys)", .{});
        if (secureBootEnabled())
            vh.die("Secure Boot is on but the key " ++ DB_KEY ++ " is missing: the firmware will not boot an " ++
                "unsigned UKI. limine.conf is unchanged; the previous kernel will boot", .{});
        vh.out("  no Secure Boot keys yet (" ++ DB_KEY ++ "): {s} is not signed\n", .{path});
        return;
    }
    if (dry) return vh.out("  + sbctl sign {s}\n", .{path});
    var out: std.ArrayList(u8) = .empty;
    var err: std.ArrayList(u8) = .empty;
    if (vh.runOpts(&.{ "sbctl", "sign", path }, .{ .out = &out, .err = &err }) != 0)
        vh.die("sbctl sign {s}: {s}{s}", .{ path, out.items, err.items });
}

fn copyFile(src: []const u8, dst: []const u8) void {
    const d = vh.readFile(src) catch vh.die("{s}: {s}", .{ src, vh.serr() });
    const fd = vh.openFd(dst, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .NOFOLLOW = true }, 0o644) catch
        vh.die("{s}: {s}", .{ dst, vh.serr() });
    vh.writeAllFd(fd, d) catch vh.die("{s}: {s}", .{ dst, vh.serr() });
    _ = vh.sys(linux.close(fd)) catch vh.die("{s}: {s}", .{ dst, vh.serr() });
}

fn replaceAtomic(src: []const u8, dst: []const u8) void {
    const d = vh.readFile(src) catch vh.die("{s}: {s}", .{ src, vh.serr() });
    vh.writeAtomic(dst, d, 0o644);
}

/// mkdtemp: a 0700 directory with a random suffix
fn mkdtemp(prefix: []const u8) []const u8 {
    const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    for (0..100) |_| {
        var r: [6]u8 = undefined;
        _ = linux.getrandom(&r, r.len, 0);
        var s: [6]u8 = undefined;
        for (r, 0..) |b, i| s[i] = alphabet[b % alphabet.len];
        const p = vh.fmt("{s}{s}", .{ prefix, s });
        if (vh.sys(linux.mkdir(vh.z(p).ptr, 0o700))) |_| return p else |_| if (vh.errno != .EXIST) break;
    }
    vh.die("mkdtemp: {s}", .{vh.serr()});
}

fn usage() noreturn {
    vh.writeAllFd(2, "vh-limine-update [--new VERSION] [--dry-run]\n" ++
        "vh-limine-update --booted | --status | --retry [NAME] | --demote | --game-once\n") catch {};
    vh.exit(2);
}

const Mode = enum { update, booted, status, retry, demote, game_once };

pub fn main(init: std.process.Init.Minimal) void {
    const args = vh.init(init, "vh-limine-update");
    vh.setenv("PATH", "/usr/bin");
    var newver: ?[]const u8 = null;
    var dry = false;
    var mode: Mode = .update;
    var retry_name: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (vh.eql(args[i], "--dry-run")) {
            dry = true;
        } else if (vh.eql(args[i], "--new") and i + 1 < args.len) {
            i += 1;
            newver = args[i];
        } else if (vh.startsWith(args[i], "--new=")) {
            newver = args[i][6..];
        } else if (mode == .update and vh.eql(args[i], "--booted")) {
            mode = .booted;
        } else if (mode == .update and vh.eql(args[i], "--status")) {
            mode = .status;
        } else if (mode == .update and vh.eql(args[i], "--demote")) {
            mode = .demote;
        } else if (mode == .update and vh.eql(args[i], "--game-once")) {
            mode = .game_once;
        } else if (mode == .update and vh.eql(args[i], "--retry")) {
            mode = .retry;
            if (i + 1 < args.len and !vh.startsWith(args[i + 1], "--")) {
                i += 1;
                retry_name = args[i];
            }
        } else usage();
    }
    // the boot assessment: EFI variables and the state, limine.conf untouched
    if (mode != .update) {
        if (newver != null or dry) usage();
        const cf = readConf();
        switch (mode) {
            .booted => cmdBooted(cf),
            .status => cmdStatus(cf),
            .retry => cmdRetry(cf, retry_name),
            .demote => cmdDemote(cf),
            .game_once => cmdGameOnce(),
            .update => unreachable,
        }
        vh.exit(0);
    }

    if (!isMount(ESP)) vh.die(ESP ++ " is not mounted: signing cancelled (the UKI must not land on the root file system)", .{});
    const cf = readConf();
    const keep_n = cf.keep;
    const timeout = cf.timeout;
    const offline = cf.offline;

    var ukis: std.ArrayList(Uki) = .empty;
    // UniVoidDistro: the machine series, rotated on its own (KEEP_MACHINE)
    var machine: std.ArrayList(Uki) = .empty;
    const names = vh.listDir(UKI_DIR) catch &.{};
    for (names) |n| {
        if (parseUki(n)) |u| {
            if (u.series == .machine) machine.append(vh.gpa, u) catch vh.oom() else ukis.append(vh.gpa, u) catch vh.oom();
        } else if (vh.endsWith(n, ".efi")) {
            vh.out("  warning: unknown file " ++ UKI_DIR ++ "/{s}: leaving it alone\n", .{n});
        }
    }
    if (ukis.items.len == 0 and machine.items.len > 0)
        vh.die("no stock UKI in " ++ UKI_DIR ++ ": the stock signed UKI is the fallback of every machine kernel; reinstall the kernel package (xbps-reconfigure -f)", .{});
    if (ukis.items.len == 0) vh.die("no UKIs in " ++ UKI_DIR, .{});
    mem.sort(Uki, ukis.items, {}, ukiDesc);
    mem.sort(Uki, machine.items, {}, ukiDesc);
    if (newver) |nv| {
        if (findVer(ukis.items, nv) == null and findVer(machine.items, nv) == null)
            vh.die("no UKI was created for {s}: see the dracut output above", .{nv});
    }

    // keep: indices into ukis
    var keep: std.ArrayList(usize) = .empty;
    for (0..@min(ukis.items.len, @as(usize, @intCast(keep_n)))) |k| keep.append(vh.gpa, k) catch vh.oom();
    var un: linux.utsname = undefined;
    _ = linux.uname(&un);
    const release = mem.sliceTo(&un.release, 0);
    for (ukis.items, 0..) |u, k| {
        if (vh.eql(u.ver, release) and mem.indexOfScalar(usize, keep.items, k) == null)
            keep.append(vh.gpa, k) catch vh.oom(); // the kernel we are running on is never deleted
    }

    // the machine series: the newest KEEP_MACHINE, the default, the trial and the one running
    // (by the entry this boot started; without the Boot Loader Interface, by its release)
    const with_machine = machine.items.len > 0 or vh.pathExists(ASSESS);
    var st: assess.State = .{};
    var facts: assess.Facts = .{};
    var keep_m: std.ArrayList(usize) = .empty;
    if (with_machine) {
        if (!dry) lock();
        st = loadState();
        facts = assess.readFacts(.{}, BOOT_ID);
        for (0..@min(machine.items.len, @as(usize, @intCast(cf.keep_machine)))) |k| keep_m.append(vh.gpa, k) catch vh.oom();
        for (machine.items, 0..) |u, k| {
            const running = if (facts.selected != null) facts.started(u.name) else vh.eql(assess.releaseOf(u.ver), release);
            if ((running or vh.eql(u.name, st.default) or vh.eql(u.name, st.trial)) and mem.indexOfScalar(usize, keep_m.items, k) == null)
                keep_m.append(vh.gpa, k) catch vh.oom();
        }
        // newest first in the menu, after the stock entries
        mem.sort(usize, keep_m.items, {}, std.sort.asc(usize));
    }

    // Check and sign first, delete afterwards: a signing failure leaves the ESP as it was
    // (the previous limine.conf points at the previous, signed UKIs).
    if (offline and newver != null and !dry) {
        const path = vh.fmt(UKI_DIR ++ "/linux-{s}.efi", .{newver.?});
        if (vh.run(&.{ "/usr/local/sbin/vh-uki-verify", path, newver.? }) != 0)
            vh.die("the UKI input check failed: signing cancelled (docs/13)", .{});
    }
    for (keep.items) |k| sign(vh.fmt(UKI_DIR ++ "/{s}", .{ukis.items[k].name}), dry, offline);
    for (keep_m.items) |k| sign(vh.fmt(UKI_DIR ++ "/{s}", .{machine.items[k].name}), dry, offline);
    // UniVoidDistro, track G: the gaming boot's twin of the newest stock UKI, made and signed
    // before anything is deleted
    const game: ?Game = if (vh.pathExists(GAME_MARK)) gameTwin(ukis.items[0].name, dry, offline) else null;
    for (ukis.items, 0..) |u, k| {
        if (mem.indexOfScalar(usize, keep.items, k) != null) continue;
        vh.out("  deleting the outdated UKI {s}\n", .{u.name});
        const path = vh.fmt(UKI_DIR ++ "/{s}", .{u.name});
        if (!dry) vh.unlink(path) catch vh.die("{s}: {s}", .{ path, vh.serr() });
    }
    for (machine.items, 0..) |u, k| {
        if (mem.indexOfScalar(usize, keep_m.items, k) != null) continue;
        vh.out("  deleting the outdated machine UKI {s}\n", .{u.name});
        const path = vh.fmt(UKI_DIR ++ "/{s}", .{u.name});
        if (!dry) vh.unlink(path) catch vh.die("{s}: {s}", .{ path, vh.serr() });
    }
    gameCleanup(if (game) |g| g.name else null, dry);

    var c: std.ArrayList(u8) = .empty;
    c.print(vh.gpa, "# Generated by vh-limine-update; do not edit by hand:\n" ++
        "# the hash of this file is enrolled into BOOTX64.EFI, any edit means the boot is refused.\n" ++
        "timeout: {d}\neditor_enabled: no\nhash_mismatch_panic: yes\nverbose: no\n", .{timeout}) catch vh.oom();
    for (keep.items, 0..) |k, j| {
        const u = ukis.items[k];
        const path = vh.fmt(UKI_DIR ++ "/{s}", .{u.name});
        const h = hash.blake2bFile(path) catch vh.die("{s}: {s}", .{ path, vh.serr() });
        c.print(vh.gpa, "\n/Void Linux {s}{s}\n    protocol: efi\n    path: boot():/EFI/void/{s}#{s}\n", .{
            u.ver, if (j > 0) " (previous kernel)" else "", u.name, h,
        }) catch vh.oom();
    }
    // the machine entries: one name in every role, so that Limine's identifier stays the same
    var on_esp: std.ArrayList(assess.OnEsp) = .empty;
    for (keep_m.items) |k| {
        const u = machine.items[k];
        const path = vh.fmt(UKI_DIR ++ "/{s}", .{u.name});
        const h = hash.blake2bFile(path) catch vh.die("{s}: {s}", .{ path, vh.serr() });
        c.print(vh.gpa, "\n/{s}\n    protocol: efi\n    path: boot():/EFI/void/{s}#{s}\n", .{ assess.entryName(u.ver), u.name, h }) catch vh.oom();
        on_esp.append(vh.gpa, .{ .name = u.name, .hash = h }) catch vh.oom();
    }
    // the gaming entry last: never the default, booted by vh-game play (the one-shot entry) or
    // from the menu
    if (game) |g| {
        const path = vh.fmt(GAME_DIR ++ "/{s}", .{g.name});
        const h = if (g.ready) hash.blake2bFile(path) catch vh.die("{s}: {s}", .{ path, vh.serr() }) else "(the twin a real run makes)";
        c.print(vh.gpa, "\n/{s}\n    protocol: efi\n    path: boot():/EFI/vh-game/{s}#{s}\n", .{ assess.gameEntryName(assess.verOf(g.name)), g.name, h }) catch vh.oom();
    }
    const conf_hash = hash.blake2bHex(c.items);

    // the assessment against this menu: a default or a trial gone or rebuilt, a new trial
    var act: assess.Action = .{ .state = st };
    var trial_new = false;
    if (with_machine) {
        act = assess.reconcile(st, on_esp.items);
        if (newver) |nv| if (findVer(machine.items, nv)) |u| {
            for (on_esp.items) |e| if (vh.eql(e.name, u.name)) {
                act.state = assess.install(act.state, u.name, e.hash);
            };
            // a trial at its start (the same trial installed again keeps its count)
            trial_new = vh.eql(act.state.trial, u.name) and act.state.good == 0 and act.state.armed.len == 0;
        };
    }

    if (newver != null and !dry and vh.pathExists(TOTP_CONF)) {
        // optional/tpm2-totp: a new UKI changes PCR 4; at the next boot the initramfs offers
        // to reseal the secret (the flag is only the presence of the file)
        vh.mkdirs("/var/lib/vh", 0o700);
        if (vh.openFd("/var/lib/vh/totp-reseal", .{ .ACCMODE = .WRONLY, .CREAT = true, .NOFOLLOW = true }, 0o600)) |fd| vh.close(fd) else |_| {}
        vh.outs("  tpm2-totp: at the next boot the code will not match once; reseal it (RESEAL)\n");
    }

    if (dry) {
        vh.out("{s}\n", .{c.items});
        vh.out("  + limine enroll-config BOOTX64.EFI {s}\n", .{conf_hash});
        if (with_machine) {
            for (act.events) |e| vh.out("  + {s}\n", .{e});
            const s2 = act.state;
            if (s2.trial.len > 0 and s2.status == .trying and s2.armed.len == 0)
                vh.out("  + LoaderEntryOneShot {s} ({s})\n", .{ assess.ukiId(s2.trial), if (facts.oneshotWorks()) "this boot's Limine takes it" else "not now: this boot's loader takes no one-shot entry" });
        }
        vh.exit(0);
    }

    vh.mkdirs(LIMINE_DIR, 0o755);
    const td = mkdtemp("/tmp/vh-limine.");
    const cfg_tmp = vh.fmt("{s}/limine.conf", .{td});
    const efi_tmp = vh.fmt("{s}/BOOTX64.EFI", .{td});
    {
        const fd = vh.openFd(cfg_tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o644) catch
            vh.die("{s}: {s}", .{ cfg_tmp, vh.serr() });
        vh.writeAllFd(fd, c.items) catch vh.die("{s}: {s}", .{ cfg_tmp, vh.serr() });
        _ = vh.sys(linux.close(fd)) catch vh.die("{s}: {s}", .{ cfg_tmp, vh.serr() });
    }
    copyFile(LIMINE_SRC, efi_tmp); // a clean copy: neither the signature nor the old hash is inherited
    var out: std.ArrayList(u8) = .empty;
    var err: std.ArrayList(u8) = .empty;
    if (vh.runOpts(&.{ "limine", "enroll-config", efi_tmp, conf_hash }, .{ .out = &out, .err = &err }) != 0) {
        vh.unlink(cfg_tmp) catch {};
        vh.unlink(efi_tmp) catch {};
        _ = linux.rmdir(vh.z(td).ptr);
        vh.die("limine enroll-config: {s}{s}", .{ out.items, err.items });
    }
    sign(efi_tmp, false, offline);
    // The order matters: the config first, then the bootloader. A failure between the two
    // gives "hash mismatch" (a refused boot, but not a bypassed check); a rerun fixes it.
    replaceAtomic(cfg_tmp, LIMINE_DIR ++ "/limine.conf");
    replaceAtomic(efi_tmp, LIMINE_DIR ++ "/BOOTX64.EFI");
    vh.unlink(cfg_tmp) catch {};
    vh.unlink(efi_tmp) catch {};
    _ = linux.rmdir(vh.z(td).ptr);
    linux.sync();
    vh.out("  limine.conf: {d} entries, config hash {s}... enrolled into Limine\n", .{ keep.items.len + keep_m.items.len + @intFromBool(game != null), conf_hash[0..16] });
    gameOneShot(if (game) |g| g.name else null);
    if (with_machine) {
        const v: assess.Vars = .{};
        var s2 = apply(act, v);
        // a trial not set yet: the next boot tries it, when this boot's Limine takes one-shot entries
        if (s2.trial.len > 0 and s2.status == .trying and s2.armed.len == 0) s2 = arm(s2, facts, v);
        if (trial_new) {
            const fallback = if (s2.default.len > 0) vh.fmt("the machine kernel {s}", .{assess.verOf(s2.default)}) else vh.fmt("the stock UKI {s}", .{ukis.items[0].ver});
            if (s2.armed.len > 0) {
                vh.out("  the machine kernel {s} is on trial: the next boot tries it once (Limine's one-shot entry); a boot that does not reach its end leaves the one after to {s}; after {d} good boots it becomes Limine's default (docs/uni/kernel.md)\n", .{ assess.verOf(s2.trial), fallback, cf.boots });
            } else {
                vh.out("  the machine kernel {s} is on trial, not set for the next boot: {s}\n", .{ assess.verOf(s2.trial), s2.reason });
            }
        }
        saveState(s2);
    }
    vh.exit(0);
}

// ---------------------------------------------------------------- the boot assessment

const Conf = struct { keep: i64, timeout: i64, offline: bool, keep_machine: i64, boots: u32 };

fn readConf() Conf {
    var conf: vh.Kv = .{};
    conf.set("KEEP", "2");
    conf.set("TIMEOUT", "1");
    conf.set("KEYS_OFFLINE", "no");
    conf.set("KEEP_MACHINE", "2");
    conf.set("MACHINE_BOOTS", "3");
    conf.read(BOOT_CONF, false);
    const keep_n = conf.int("KEEP", "2");
    const timeout = conf.int("TIMEOUT", "1");
    if (keep_n < 1 or keep_n > 5 or timeout < 0 or timeout > 30) vh.die("invalid KEEP/TIMEOUT in " ++ BOOT_CONF, .{});
    const keep_m = conf.int("KEEP_MACHINE", "2");
    const boots = conf.int("MACHINE_BOOTS", "3");
    if (keep_m < 1 or keep_m > 5 or boots < 1 or boots > 10) vh.die("invalid KEEP_MACHINE/MACHINE_BOOTS in " ++ BOOT_CONF, .{});
    return .{ .keep = keep_n, .timeout = timeout, .offline = vh.eql(conf.get("KEYS_OFFLINE", "no"), "yes"), .keep_machine = keep_m, .boots = @intCast(boots) };
}

/// one writer of the state at a time (the service at boot, a kernel hook, the admin); held until exit
fn lock() void {
    vh.mkdirs("/var/lib/vh", 0o700);
    const fd = vh.openFd(ASSESS_LOCK, .{ .ACCMODE = .RDWR, .CREAT = true, .NOFOLLOW = true }, 0o600) catch
        vh.die("{s}: {s}", .{ ASSESS_LOCK, vh.serr() });
    _ = vh.sysRetry(linux.flock, .{ fd, @as(i32, 2) }) catch vh.die("{s}: {s}", .{ ASSESS_LOCK, vh.serr() }); // LOCK_EX
}

fn loadState() assess.State {
    const text = vh.readFile(ASSESS) catch return .{};
    return assess.parseState(text);
}

fn saveState(st: assess.State) void {
    vh.mkdirs("/var/lib/vh", 0o700);
    vh.writeAtomic(ASSESS, assess.renderState(st), 0o600);
}

/// the variables a decision asks for; a variable that cannot be written is reported, and a
/// trial that could not be set is not counted as set
fn apply(a: assess.Action, v: assess.Vars) assess.State {
    var st = a.state;
    for (a.events) |e| vh.out("  {s}\n", .{e});
    if (a.disarm) |id| {
        if (v.string("LoaderEntryOneShot")) |cur| if (vh.eql(cur, id))
            v.delete("LoaderEntryOneShot") catch vh.warn("LoaderEntryOneShot: {s}", .{vh.serr()});
    }
    if (a.clear_default) v.delete("LoaderEntryDefault") catch vh.warn("LoaderEntryDefault: {s}", .{vh.serr()});
    if (a.set_default) |id| v.writeString("LoaderEntryDefault", id) catch
        vh.warn("LoaderEntryDefault: {s}: the next boot sets it again", .{vh.serr()});
    if (a.arm) {
        v.writeString("LoaderEntryOneShot", assess.ukiId(st.trial)) catch {
            st.armed = "";
            st.reason = vh.fmt("LoaderEntryOneShot could not be set: {s}", .{vh.serr()});
            vh.warn("{s}", .{st.reason});
        };
    }
    if (a.reseal) askReseal("the trial's boot may have sealed the code");
    return st;
}

/// set the one-shot entry of the trial, when this boot's Limine takes one
fn arm(st0: assess.State, f: assess.Facts, v: assess.Vars) assess.State {
    var st = st0;
    if (!f.oneshotWorks()) {
        st.reason = if (f.loader.len == 0)
            "this boot did not go through Limine: vh-boot-assess sets the trial at a boot that does"
        else
            vh.fmt("{s} takes no one-shot entry by identifier (Limine 12.7 or later)", .{f.loader});
        return st;
    }
    v.writeString("LoaderEntryOneShot", assess.ukiId(st.trial)) catch {
        st.reason = vh.fmt("LoaderEntryOneShot could not be set: {s}", .{vh.serr()});
        return st;
    };
    st.armed = f.id;
    st.reason = "";
    return st;
}

/// optional/tpm2-totp: the flag the initramfs reads to offer a reseal (docs/13)
fn askReseal(why: []const u8) void {
    if (!vh.pathExists(TOTP_CONF)) return;
    vh.mkdirs("/var/lib/vh", 0o700);
    if (vh.openFd("/var/lib/vh/totp-reseal", .{ .ACCMODE = .WRONLY, .CREAT = true, .NOFOLLOW = true }, 0o600)) |fd| vh.close(fd) else |_| {}
    vh.out("  tpm2-totp: {s}: the next boot offers to reseal it (RESEAL)\n", .{why});
}

/// the verdict of vh-kconf check of this boot, waiting for the vh-check service
fn waitVerdict() assess.Verdict {
    var waited: u32 = 0;
    while (true) {
        const v = assess.verdict(vh.rd(CHECK_DONE));
        if (v != .none or waited >= VERDICT_WAIT_S) return v;
        var ts: linux.timespec = .{ .sec = 1, .nsec = 0 };
        _ = linux.nanosleep(&ts, null);
        waited += 1;
    }
}

/// /run/vh/boot-assess, shown at the admin's login: what this boot changed and where the
/// trial stands; removed when there is nothing to say
fn writeMessage(st: assess.State, events: []const []const u8, boots: u32) void {
    var t: std.ArrayList(u8) = .empty;
    for (events) |e| t.print(vh.gpa, "  {s}\n", .{e}) catch vh.oom();
    // where the trial stands, unless this boot's events said it already
    if (st.trial.len > 0) switch (st.status) {
        .trying => if (events.len == 0) t.print(vh.gpa, "  on trial: the machine kernel {s}, {d} of {d} good boots{s}\n", .{
            assess.verOf(st.trial), st.good, boots, if (st.armed.len > 0) "; the next boot tries it" else vh.fmt("; {s}", .{st.reason}),
        }) catch vh.oom(),
        .failed => {
            if (events.len == 0) t.print(vh.gpa, "  the machine kernel {s} failed its trial and is not the default: {s}\n", .{ assess.verOf(st.trial), st.reason }) catch vh.oom();
            t.appendSlice(vh.gpa, "  to try it again: doas vh-limine-update --retry\n") catch vh.oom();
        },
    };
    if (t.items.len == 0) {
        vh.unlink(ASSESS_MSG) catch {};
        return;
    }
    vh.mkdirs("/run/vh", 0o755);
    vh.writeAtomic(ASSESS_MSG, vh.fmt("vh-limine-update: the boot assessment of the machine kernel (docs/uni/kernel.md)\n{s}", .{t.items}), 0o644);
}

/// --booted: the vh-boot-assess service, once a boot
fn cmdBooted(cf: Conf) void {
    if (!vh.pathExists(ASSESS)) return; // no machine UKI was ever installed
    const v: assess.Vars = .{};
    var f = assess.readFacts(v, BOOT_ID);
    const st0 = loadState();
    // the verdict decides a boot of the trial or of the default; it does not need the lock
    if ((st0.trial.len > 0 and f.started(st0.trial)) or (st0.default.len > 0 and f.started(st0.default)))
        f.verdict = waitVerdict();
    lock();
    const a = assess.booted(loadState(), f, cf.boots);
    const st = apply(a, v);
    saveState(st);
    writeMessage(st, a.events, cf.boots);
}

/// --status: the state, and this boot as the boot loader reports it
fn cmdStatus(cf: Conf) void {
    const st = loadState();
    const f = assess.readFacts(.{}, BOOT_ID);
    vh.outs("the boot assessment of the machine kernel (docs/uni/kernel.md)\n");
    if (st.default.len > 0)
        vh.out("  the default: the machine kernel {s} ({s}); the stock UKI heads the menu\n", .{ assess.verOf(st.default), st.default })
    else
        vh.outs("  the default: the newest stock UKI\n");
    if (st.trial.len == 0) {
        vh.outs("  on trial: none\n");
    } else switch (st.status) {
        .trying => vh.out("  on trial: the machine kernel {s} ({s}), {d} of {d} good boots, {s}\n", .{
            assess.verOf(st.trial), st.trial, st.good, cf.boots, if (st.armed.len > 0) "set for the next boot" else if (st.reason.len > 0) st.reason else "not set yet",
        }),
        .failed => vh.out("  failed its trial: the machine kernel {s} ({s}): {s}\n", .{ assess.verOf(st.trial), st.trial, st.reason }),
    }
    vh.out("  this boot: {s}; one-shot entries: {s}; started: {s}; LoaderEntryOneShot: {s}; LoaderEntryDefault: {s}\n", .{
        if (f.loader.len > 0) f.loader else "no Boot Loader Interface",
        if (f.oneshotWorks()) "yes" else "no",
        f.selected orelse "-",
        f.oneshot orelse "-",
        f.default orelse "-",
    });
    if (vh.pathExists(GAME_MARK) or (f.selected != null and assess.isGameEntry(f.selected.?)))
        vh.out("  the gaming boot (docs/uni/game.md): {s}; this boot is {s}\n", .{
            if (vh.pathExists(GAME_MARK)) "on, the last entry of the menu" else "off",
            if (f.selected != null and assess.isGameEntry(f.selected.?)) "the gaming one" else "not the gaming one",
        });
    vh.outs(assess.summary(st, cf.boots));
}

// ---------------------------------------------------------------- the gaming boot

/// the gaming UKI of a run: its name (the stock UKI's), and whether it is on the ESP as the
/// twin (false only for a --dry-run that would make it)
const Game = struct { name: []const u8, ready: bool };

/// The twin of the stock UKI NAME in GAME_DIR: kept when the one there is its twin already,
/// else made (a temporary file, then renamed over it); signed either way.
fn gameTwin(name: []const u8, dry: bool, offline: bool) Game {
    const src = vh.fmt(UKI_DIR ++ "/{s}", .{name});
    const dst = vh.fmt(GAME_DIR ++ "/{s}", .{name});
    const p = twin.plan(src) catch |e| switch (e) {
        error.Sys => vh.die("{s}: {s}", .{ src, vh.serr() }),
        else => |te| vh.die("no gaming UKI from the stock UKI {s}: {s}; limine.conf is unchanged (doas vh-game boot off turns the gaming boot off)", .{ name, twin.describe(te) }),
    };
    if (!twin.same(src, dst, p)) {
        if (dry) {
            vh.out("  + the gaming UKI " ++ GAME_DIR ++ "/{s}: the stock UKI with ia32_emulation=1\n", .{name});
            sign(dst, true, offline);
            return .{ .name = name, .ready = false };
        }
        vh.mkdirs(GAME_DIR, 0o755);
        const tmp = vh.fmt(GAME_DIR ++ "/.{s}.tmp", .{name});
        vh.unlink(tmp) catch {};
        twin.write(src, tmp, p) catch {
            const why = vh.serr();
            vh.unlink(tmp) catch {};
            vh.die("the gaming UKI {s}: {s} (room on the ESP: df -h " ++ ESP ++ "); limine.conf is unchanged", .{ dst, why });
        };
        _ = vh.sys(linux.rename(vh.z(tmp).ptr, vh.z(dst).ptr)) catch {
            const why = vh.serr();
            vh.unlink(tmp) catch {};
            vh.die("{s}: {s}", .{ dst, why });
        };
        vh.out("  the gaming UKI {s}: the stock UKI with ia32_emulation=1\n", .{name});
    }
    sign(dst, dry, offline);
    return .{ .name = name, .ready = true };
}

/// Every file of GAME_DIR but the gaming UKI KEEP (an older kernel's twin, the temporary file
/// of a run cut off); with no KEEP (the gaming boot is off) the directory too.
fn gameCleanup(keep: ?[]const u8, dry: bool) void {
    const names = vh.listDir(GAME_DIR) catch return;
    for (names) |n| {
        if (keep) |k| if (vh.eql(n, k)) continue;
        vh.out("  deleting the gaming UKI {s}\n", .{n});
        const path = vh.fmt(GAME_DIR ++ "/{s}", .{n});
        if (!dry) vh.unlink(path) catch vh.die("{s}: {s}", .{ path, vh.serr() });
    }
    if (keep == null) {
        vh.out("  the gaming boot is off: " ++ GAME_DIR ++ " goes\n", .{});
        if (!dry) _ = vh.sys(linux.rmdir(GAME_DIR)) catch vh.die(GAME_DIR ++ ": {s}", .{vh.serr()});
    }
}

/// A one-shot entry of vh-game play for a gaming UKI no longer in the menu: renamed to the one
/// there is (a kernel update between play and the reboot), or taken away (the gaming boot off).
fn gameOneShot(name: ?[]const u8) void {
    const v: assess.Vars = .{};
    const cur = v.string("LoaderEntryOneShot") orelse return;
    if (!assess.isGameEntry(cur)) return;
    if (name) |n| {
        const id = assess.gameId(n);
        if (vh.eql(cur, id)) return;
        v.writeString("LoaderEntryOneShot", id) catch return vh.warn("LoaderEntryOneShot: {s}", .{vh.serr()});
        vh.out("  the next boot is the gaming one of {s} now\n", .{assess.verOf(n)});
    } else {
        v.delete("LoaderEntryOneShot") catch return vh.warn("LoaderEntryOneShot: {s}", .{vh.serr()});
        vh.outs("  the next boot is no longer the gaming one: the gaming boot is off\n");
    }
}

/// --game-once (vh-game play): the gaming entry is the next boot's, once (Limine erases the
/// one-shot entry before it boots it); the boot after it is the default again. Refused while a
/// machine kernel's trial waits for that boot.
fn cmdGameOnce() void {
    if (!vh.pathExists(GAME_MARK)) vh.die("the gaming boot is off: doas vh-game boot on", .{});
    // the state exists once a machine UKI was installed; without it there is no trial to wait for
    if (vh.pathExists(ASSESS)) {
        lock();
        const st = loadState();
        if (st.trial.len > 0 and st.status == .trying and st.armed.len > 0)
            vh.die("the next boot is the trial of the machine kernel {s} (Limine's one-shot entry): play after it, or choose \"(games)\" in Limine's menu", .{assess.verOf(st.trial)});
    }
    const f = assess.readFacts(.{}, BOOT_ID);
    if (!f.oneshotWorks()) vh.die("{s}: choose \"(games)\" in Limine's menu at the next boot", .{
        if (f.loader.len == 0) "this boot did not go through Limine" else vh.fmt("{s} takes no one-shot entry by identifier (Limine 12.7 or later)", .{f.loader}),
    });
    const mounted = mountEsp();
    var name: ?[]const u8 = null;
    for (vh.listDir(GAME_DIR) catch &.{}) |n| if (parseUki(n)) |u| if (u.series == .stock) {
        name = n;
    };
    if (mounted) umountEsp();
    const n = name orelse vh.die("no gaming UKI in " ++ GAME_DIR ++ ": doas vh-game boot on makes it", .{});
    const id = assess.gameId(n);
    const v: assess.Vars = .{};
    v.writeString("LoaderEntryOneShot", id) catch vh.die("LoaderEntryOneShot: {s}", .{vh.serr()});
    vh.out("  the next boot, once: {s}{s}\n", .{ assess.gameEntryName(assess.verOf(n)), if (f.lists(id)) "" else " (in Limine's menu from the next boot on)" });
}

/// --retry [NAME]: assess the failed trial again, or the machine UKI NAME
fn cmdRetry(cf: Conf, name: ?[]const u8) void {
    lock();
    const st0 = loadState();
    var st: assess.State = undefined;
    if (name) |n| {
        const u = parseUki(n) orelse vh.die("{s}: not the name of a UKI (linux-A.B.C-vh_N.efi)", .{n});
        if (u.series != .machine) vh.die("{s}: a stock UKI needs no assessment", .{n});
        if (vh.eql(st0.default, n)) vh.die("{s} is the default already", .{n});
        const mounted = mountEsp();
        const path = vh.fmt(UKI_DIR ++ "/{s}", .{n});
        const h = hash.blake2bFile(path) catch {
            if (mounted) umountEsp();
            vh.die("{s}: {s}", .{ path, vh.serr() });
        };
        if (mounted) umountEsp();
        st = assess.install(st0, n, h);
    } else {
        st = assess.retry(st0) orelse vh.die("no machine UKI on trial: name one (--retry linux-A.B.C-vh_N.efi)", .{});
    }
    st = arm(st, assess.readFacts(.{}, BOOT_ID), .{});
    saveState(st);
    if (st.armed.len > 0)
        vh.out("  the machine kernel {s} is on trial again: the next boot tries it (0 of {d} good boots)\n", .{ assess.verOf(st.trial), cf.boots })
    else
        vh.out("  the machine kernel {s} is on trial again, not set for the next boot: {s}\n", .{ assess.verOf(st.trial), st.reason });
    writeMessage(st, &.{}, cf.boots);
}

/// --demote: the stock UKI is the default again (no signing: only the variable changes)
fn cmdDemote(cf: Conf) void {
    lock();
    const st0 = loadState();
    const st = assess.demote(st0) orelse vh.die("no machine kernel is the default: the stock UKI is", .{});
    const v: assess.Vars = .{};
    v.delete("LoaderEntryDefault") catch vh.die("LoaderEntryDefault: {s}", .{vh.serr()});
    saveState(st);
    vh.out("  the machine kernel {s} is no longer the default: the newest stock UKI is (to assess it again: doas vh-limine-update --retry {s})\n", .{ assess.verOf(st0.default), st0.default });
    askReseal("the default boot path is the stock UKI's now");
    writeMessage(st, &.{}, cf.boots);
}

/// the ESP for reading, if it is not mounted (it is noauto, docs/03); true when this run mounted it
fn mountEsp() bool {
    if (isMount(ESP)) return false;
    if (vh.run(&.{ "mount", "-o", "ro", ESP }) != 0 or !isMount(ESP)) vh.die(ESP ++ " could not be mounted", .{});
    return true;
}

fn umountEsp() void {
    _ = vh.run(&.{ "umount", ESP });
}

test "parseUki" {
    const u = parseUki("linux-6.18.56_1.efi").?;
    try std.testing.expectEqualStrings("6.18.56_1", u.ver);
    try std.testing.expectEqual(@as(u64, 56), u.v[2]);
    try std.testing.expect(parseUki("linux-6.18_1.efi") == null);
    try std.testing.expect(parseUki("linux-6.18.56_1x.efi") == null);
    try std.testing.expect(parseUki("linux-6.18.1234567890_1.efi") == null);
    try std.testing.expect(parseUki("other.efi") == null);
}

test "parseUki: the machine series" {
    const u = parseUki("linux-6.18.57-vh_2.efi").?;
    try std.testing.expectEqual(Series.machine, u.series);
    try std.testing.expectEqualStrings("6.18.57-vh_2", u.ver);
    try std.testing.expectEqual(@as(u64, 2), u.v[3]);
    try std.testing.expectEqual(Series.stock, parseUki("linux-6.18.57_1.efi").?.series);
    try std.testing.expect(parseUki("linux-6.18.57-vh_.efi") == null);
    try std.testing.expect(parseUki("linux-6.18.57-vh.efi") == null);
    try std.testing.expect(parseUki("linux-6.18.57-vhx_1.efi") == null);
    try std.testing.expect(parseUki("linux-6.18.57-vh_1_1.efi") == null);
    // the machine series sorts on its own: newest first
    var l = [_]Uki{ parseUki("linux-6.18.57-vh_1.efi").?, parseUki("linux-6.18.58-vh_1.efi").?, parseUki("linux-6.18.57-vh_2.efi").? };
    mem.sort(Uki, &l, {}, ukiDesc);
    try std.testing.expectEqualStrings("6.18.58-vh_1", l[0].ver);
    try std.testing.expectEqualStrings("6.18.57-vh_2", l[1].ver);
}
