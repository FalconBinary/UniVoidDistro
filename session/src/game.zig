//! vh-game: the gaming session on tty3 (track G, session/README.md, docs/uni/game.md).
//!
//!   doas vh-game install    the game user (its password asked for), its home /home/game, the
//!                           gaming root /var/lib/vh/roots/game with the Vulkan driver of this
//!                           machine's GPU (the plan) and a sound server of its own, the login
//!                           of game on tty3, the sound cards' playback and control nodes for
//!                           game (a udev rule: an ACL entry on each)
//!   doas vh-game tty on     the getty of tty3, until the next boot or tty off: no process of the
//!                           gaming session runs before this
//!   doas vh-game tty off
//!   doas vh-game boot on    the gaming boot (G3): the stock UKI's twin with ia32 on, the last
//!                           entry of Limine's menu; in that boot every process but the gaming
//!                           session's is under a filter that kills a 32-bit system call (boot.zig)
//!   doas vh-game boot off
//!   doas vh-game play       the next boot, once, is the gaming one: reboot into it now
//!   doas vh-game key new    the gaming kernel's module key (G3b): RSA-4096 under a passphrase,
//!                           beside the Secure Boot keys (key.zig); key show, key remove
//!   doas vh-game kernel build   the gaming kernel, built here in a build root that is removed
//!                           after it, without network or privileges (kbuild.zig)
//!   doas vh-game remove     everything install and boot on made, the home with it; the system
//!                           is then what it was before the install, byte for byte
//!   vh-game status
//!
//! install takes --password-stdin, --password-hash HASH, --plan-env FILE; remove takes --yes;
//! play takes --no-reboot. --prefix DIR acts on a system root in DIR, --thor PATH runs another
//! thor, --limine-update PATH another vh-limine-update, --any-arch installs on another
//! architecture than x86_64 (the tests). stage1 and stage2 are the gaming boot's own (runit).
//! Every change of a system file is a line added and taken away again exactly (lines.zig,
//! accounts.zig). Static PIE, ReleaseSafe, std.os.linux only (zig/README.md).
const std = @import("std");
const builtin = @import("builtin");
const vh = @import("vh");
const profiles = @import("profiles");
const common = @import("common.zig");
const accounts = @import("accounts.zig");
const lines = @import("lines.zig");
const roots = @import("roots.zig");
const rmtree = @import("rmtree.zig");
const sys = @import("sys.zig");
const acl = @import("acl.zig");
const boot = @import("boot.zig");
const key = @import("key.zig");
const kbuild = @import("kbuild.zig");
const linux = std.os.linux;
const mem = std.mem;
const G = common.game;

const usage =
    \\usage: doas vh-game install [--password-stdin | --password-hash HASH] [--plan-env FILE]
    \\       doas vh-game tty on|off
    \\       doas vh-game boot on|off
    \\       doas vh-game play [--no-reboot]
    \\       doas vh-game key new [--password-stdin] | show | remove
    \\       doas vh-game kernel build [--jobs N]
    \\       doas vh-game remove [--yes]
    \\       vh-game status
    \\
;

const Cfg = struct {
    o: roots.Opts = .{},
    password_stdin: bool = false,
    password_hash: ?[]const u8 = null,
    plan_env: ?[]const u8 = null,
    yes: bool = false,
    /// the tests of another architecture (tests/session/run.sh on an ARM Mac)
    any_arch: bool = false,
    /// play: the one-shot entry only, the reboot left to the user (the VM rig)
    no_reboot: bool = false,
    /// vh-limine-update, or a stand-in for the tests (the ESP is not mounted for one)
    limine: ?[]const u8 = null,
    /// kernel build: make's jobs (0: the CPUs and the memory decide)
    jobs: u32 = 0,
    /// kernel build, the tests: a downloaded tarball, another vh-kconf
    tarball: ?[]const u8 = null,
    kconf: ?[]const u8 = null,
};

pub fn main(init: std.process.Init.Minimal) void {
    const all = vh.init(init, "vh-game");
    // doas keeps the admin's umask, 077: the roots' directories, and the files that package
    // scripts make in a root (the loader's cache, font and icon caches), must stay readable to
    // the root's own user, as vh-update keeps the system's
    sys.umask(0o022);
    var c: Cfg = .{};
    var args: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < all.len) : (i += 1) {
        const a = all[i];
        if (vh.eql(a, "--password-stdin")) {
            c.password_stdin = true;
        } else if (vh.eql(a, "--yes") or vh.eql(a, "-y")) {
            c.yes = true;
        } else if (vh.eql(a, "--any-arch")) {
            c.any_arch = true;
        } else if (vh.eql(a, "--no-reboot")) {
            c.no_reboot = true;
        } else if (vh.eql(a, "--prefix") or vh.eql(a, "--thor") or vh.eql(a, "--password-hash") or vh.eql(a, "--plan-env") or vh.eql(a, "--limine-update") or
            vh.eql(a, "--jobs") or vh.eql(a, "--tarball") or vh.eql(a, "--kconf"))
        {
            if (i + 1 >= all.len) vh.die("{s} needs a value", .{a});
            i += 1;
            const v = all[i];
            if (vh.eql(a, "--prefix")) c.o.sys.prefix = v;
            if (vh.eql(a, "--thor")) c.o.thor = v;
            if (vh.eql(a, "--password-hash")) c.password_hash = v;
            if (vh.eql(a, "--plan-env")) c.plan_env = v;
            if (vh.eql(a, "--limine-update")) c.limine = v;
            if (vh.eql(a, "--jobs")) c.jobs = std.fmt.parseInt(u32, v, 10) catch vh.die("--jobs: not a number: {s}", .{v});
            if (vh.eql(a, "--tarball")) c.tarball = v;
            if (vh.eql(a, "--kconf")) c.kconf = v;
        } else args.append(vh.gpa, a) catch vh.oom();
    }
    const argv = args.items;
    if (argv.len == 0 or vh.eql(argv[0], "--help") or vh.eql(argv[0], "-h")) {
        vh.outs(usage);
        vh.exit(if (argv.len == 0) 2 else 0);
    }
    const cmd = argv[0];
    if (vh.eql(cmd, "status")) vh.exit(status(c));
    if (vh.eql(cmd, "key") and argv.len == 2 and vh.eql(argv[1], "show")) vh.exit(key.show(c.o.sys));
    common.needRoot(vh.fmt("vh-game {s}", .{cmd}));
    if (vh.eql(cmd, "install")) {
        install(c);
        vh.exit(0);
    }
    if (vh.eql(cmd, "remove")) {
        remove(c);
        vh.exit(0);
    }
    if (vh.eql(cmd, "tty") and argv.len == 2 and vh.eql(argv[1], "on")) vh.exit(ttyOn(c));
    if (vh.eql(cmd, "tty") and argv.len == 2 and vh.eql(argv[1], "off")) vh.exit(ttyOff(c));
    if (vh.eql(cmd, "boot") and argv.len == 2 and vh.eql(argv[1], "on")) vh.exit(bootOn(c));
    if (vh.eql(cmd, "boot") and argv.len == 2 and vh.eql(argv[1], "off")) vh.exit(bootOff(c));
    if (vh.eql(cmd, "play") and argv.len == 1) vh.exit(play(c));
    if (vh.eql(cmd, "key") and argv.len == 2 and vh.eql(argv[1], "new")) {
        const pass = if (c.password_stdin) vh.readLine() orelse vh.die("no passphrase on stdin", .{}) else askTwice("The passphrase of the module key (asked again at every signing): ");
        key.new(c.o, pass);
        std.crypto.secureZero(u8, @constCast(pass));
        vh.exit(0);
    }
    if (vh.eql(cmd, "key") and argv.len == 2 and vh.eql(argv[1], "remove")) {
        key.remove(c.o.sys);
        vh.exit(0);
    }
    if (vh.eql(cmd, "kernel") and argv.len == 2 and vh.eql(argv[1], "build")) {
        const dir = kbuild.build(.{ .o = c.o, .jobs = c.jobs, .tarball = c.tarball, .kconf = c.kconf orelse "/usr/local/sbin/vh-kconf" });
        vh.out("VH_GAME kernel built={s}\n", .{dir});
        vh.exit(0);
    }
    // the gaming boot's own: stage 1 (98-vh-game.sh, vh-stage1) and stage 2 (runit, through the
    // marker's first line)
    if (vh.eql(cmd, "stage1") and argv.len == 1) vh.exit(boot.stage1());
    if (vh.eql(cmd, "stage2")) boot.stage2();
    vh.warn("unknown command {s}", .{cmd});
    vh.outs(usage);
    vh.exit(2);
}

// ---------------------------------------------------------------- install

fn install(c: Cfg) void {
    const S = c.o.sys;
    if (!c.any_arch and builtin.cpu.arch != .x86_64) vh.die("the gaming session is for x86_64 machines (Steam and nearly every game are x86_64)", .{});
    // nothing of the session may be there already: install changes nothing before this holds,
    // and remove takes away only what install made
    const f0 = accounts.Files.lock(S.prefix);
    const passwd0 = f0.read("passwd") orelse vh.die("{s}: missing", .{f0.path("passwd")});
    const group0 = f0.read("group") orelse vh.die("{s}: missing", .{f0.path("group")});
    f0.unlock();
    if (accounts.find(passwd0, G.user) != null) vh.die("a user {s} exists already: is the gaming session installed? (vh-game status)", .{G.user});
    if (accounts.find(group0, G.user) != null) vh.die("a group {s} exists already", .{G.user});
    for (G.groups) |g| if (accounts.find(group0, g) == null) vh.die("no group {s}: the system is not one UniVoidDistro installed", .{g});
    if (vh.pathExists(S.path(G.home))) vh.die("{s} exists already", .{S.path(G.home)});
    if (roots.exists(c.o, G.root)) vh.die("the root {s} exists already", .{roots.path(c.o, G.root)});
    if (!vh.isDir(S.path(G.getty))) vh.die("{s}: no getty service for {s} (runit-void)", .{ S.path(G.getty), G.tty });
    const access = S.path("/etc/security/access.conf");
    const access0 = vh.readFile(access) catch vh.die("{s}: {s}", .{ access, vh.serr() });
    if (lines.insertBeforeDenyAll(access0, accessLine()) == null) vh.die("{s}: no line that denies everyone else (- : ALL : ALL)", .{access});
    const shells = S.path("/etc/shells");
    const fstab = S.path("/etc/fstab");
    for ([_][]const u8{ shells, fstab }) |p| if (!vh.isRegular(p)) vh.die("{s}: missing", .{p});
    if (!vh.isRegular(S.path(G.shell))) vh.die("{s}: missing (install/build-tools.sh installs it)", .{S.path(G.shell)});
    if (vh.pathExists(S.path(G.sound_rule))) vh.die("{s} exists already", .{S.path(G.sound_rule)});
    if (!vh.isDir(S.path("/etc/udev/rules.d"))) vh.die("{s}: missing", .{S.path("/etc/udev/rules.d")});
    if (!vh.isRegular(S.path("/usr/bin/setfacl"))) vh.die("{s}: missing (acl-progs): the udev rule of the sound cards runs it", .{S.path("/usr/bin/setfacl")});

    // the Vulkan driver of this machine's GPU: a rule of hwdb, through the plan
    const pkgs = gamePackages(c);
    const hash = password(c);

    // the account: game, its own group, seatd's socket and the render nodes
    const f = accounts.Files.lock(S.prefix);
    const passwd = f.read("passwd").?;
    const group = f.read("group").?;
    const id = accounts.freeId(passwd, group, 1000, 60000) orelse vh.die("no free user id from 1000 to 60000", .{});
    const u: accounts.User = .{ .name = G.user, .id = id, .gecos = G.gecos, .home = G.home, .shell = G.shell, .hash = hash, .days = @divFloor(vh.now(), 86400) };
    f.write("passwd", lines.append(passwd, u.passwdLine()));
    f.write("shadow", lines.append(f.read("shadow") orelse vh.die("{s}: missing", .{f.path("shadow")}), u.shadowLine()));
    var g = lines.append(group, u.groupLine());
    for (G.groups) |grp| g = accounts.addMember(g, grp, G.user).?;
    f.write("group", g);
    if (f.read("gshadow")) |gs0| {
        var gs = lines.append(gs0, u.gshadowLine());
        for (G.groups) |grp| gs = accounts.addMember(gs, grp, G.user) orelse gs;
        f.write("gshadow", gs);
    }
    f.unlock();
    vh.log("the user {s} ({d}), in the groups {s}", .{ G.user, id, mem.join(vh.gpa, " ", &G.groups) catch vh.oom() });

    // the home: games and their data run from it, so it is a mount of its own with exec
    // (/home is noexec), still without SUID bits and device nodes
    const home = S.path(G.home);
    sys.mkdir(home, 0o700) catch vh.die("{s}: {s}", .{ home, vh.serr() });
    sys.chown(home, id, id) catch vh.die("{s}: {s}", .{ home, vh.serr() });
    const fstab0 = vh.readFile(fstab) catch vh.die("{s}: {s}", .{ fstab, vh.serr() });
    roots.writeKeeping(fstab, lines.append(fstab0, common.fstabBind(G.home)));
    sys.bind(home, home, sys.MS.NOSUID | sys.MS.NODEV) catch vh.die("mount {s}: {s}", .{ home, vh.serr() });

    // the root
    const profile = profiles.get(G.root).?;
    roots.after_failure = "the account and the home of game are made, the root is not: doas vh-game remove takes them away";
    roots.create(c.o, G.root, profile, pkgs, .{ .uid = id, .gid = id });
    const root = roots.path(c.o, G.root);
    // the game user inside it (programs look their user up), and the place its home is bound to
    for ([_][2][]const u8{
        .{ "/etc/passwd", vh.fmt("{s}:x:{d}:{d}:{s}:{s}:/bin/bash", .{ G.user, id, id, G.gecos, G.home }) },
        .{ "/etc/group", vh.fmt("{s}:x:{d}:", .{ G.user, id }) },
    }) |e| {
        const p = vh.fmt("{s}{s}", .{ root, e[0] });
        const old = vh.readFile(p) catch vh.die("{s}: {s}", .{ p, vh.serr() });
        roots.writeKeeping(p, lines.append(old, e[1]));
    }
    sys.mkdir(vh.fmt("{s}{s}", .{ root, G.home }), 0o755) catch vh.die("{s}{s}: {s}", .{ root, G.home, vh.serr() });
    sys.chmod(vh.fmt("{s}{s}", .{ root, G.home }), 0o755) catch vh.die("{s}{s}: {s}", .{ root, G.home, vh.serr() });
    vh.mkdirs(vh.fmt("{s}/etc/profile.d", .{root}), 0o755);
    vh.writeAtomic(vh.fmt("{s}/etc/profile.d/zz-vh-game.sh", .{root}),
        \\# vh-game: the login shell of the gaming session (vh-game-enter starts it in this root)
        \\export LIBSEAT_BACKEND=seatd
        \\case $- in *i*) echo "The gaming session: a game runs in gamescope, for example: gamescope -f -- vkcube" ;; esac
        \\
    , 0o644);
    soundConfig(root);

    // the login: tty3 for game in pam_access, its shell in /etc/shells (pam_shells)
    roots.writeKeeping(access, lines.insertBeforeDenyAll(vh.readFile(access) catch vh.die("{s}: {s}", .{ access, vh.serr() }), accessLine()).?);
    const shells0 = vh.readFile(shells) catch vh.die("{s}: {s}", .{ shells, vh.serr() });
    roots.writeKeeping(shells, lines.append(shells0, G.shell));

    // the sound cards: their playback and control nodes for game, at every boot and hotplug by
    // the udev rule, and the nodes there now at once
    vh.writeAtomic(S.path(G.sound_rule), G.sound_rule_text, 0o644);
    const nodes = if (S.prefix.len == 0) soundAcl(id, true) else 0;
    vh.log("sound: {d} playback and control node(s) of the sound cards for {s} (an ACL entry each; {s})", .{ nodes, G.user, G.sound_rule });

    vh.log("installed: log in as {s} on {s} after doas vh-game tty on (until the next boot); the gaming boot with ia32: doas vh-game boot on", .{ G.user, G.tty });
    vh.out("VH_GAME installed user={s} uid={d} root={s} packages={s} sound={d}\n", .{ G.user, id, roots.path(.{}, G.root), mem.join(vh.gpa, ",", pkgs) catch vh.oom(), nodes });
}

/// The gaming root's own sound server, which vh-game-enter starts in a session that has a sound
/// card: PipeWire, which starts WirePlumber and its pulse server (Proton, Wine and Steam speak
/// pulse, SDL speaks PipeWire), linked in as the system links them (install/chroot.sh); and
/// WirePlumber without what the session cannot reach anyway: Bluetooth (BlueZ is on the system's
/// D-Bus), cameras, MIDI, D-Bus itself.
fn soundConfig(root: []const u8) void {
    const pw = vh.fmt("{s}/etc/pipewire/pipewire.conf.d", .{root});
    vh.mkdirs(pw, 0o755);
    for ([_][2][]const u8{
        .{ "10-wireplumber.conf", "/usr/share/examples/wireplumber/10-wireplumber.conf" },
        .{ "20-pipewire-pulse.conf", "/usr/share/examples/pipewire/20-pipewire-pulse.conf" },
    }) |l| {
        const p = vh.fmt("{s}/{s}", .{ pw, l[0] });
        sys.symlink(l[1], p) catch vh.die("{s}: {s}", .{ p, vh.serr() });
    }
    vh.writeAtomic(vh.fmt("{s}/60-vh-game.conf", .{pw}), pipewire_conf, 0o644);
    const pulse = vh.fmt("{s}/etc/pipewire/pipewire-pulse.conf.d", .{root});
    vh.mkdirs(pulse, 0o755);
    vh.writeAtomic(vh.fmt("{s}/60-vh-game.conf", .{pulse}), pulse_conf, 0o644);
    const wp = vh.fmt("{s}/etc/wireplumber/wireplumber.conf.d", .{root});
    vh.mkdirs(wp, 0o755);
    vh.writeAtomic(vh.fmt("{s}/60-vh-game.conf", .{wp}), wireplumber_conf, 0o644);
}

const pipewire_conf =
    \\# vh-game (docs/uni/game.md, G2): the gaming session's PipeWire. No realtime scheduling (the
    \\# desktop's PipeWire has none either), and nothing that looks for D-Bus, which the session
    \\# does not have: the portal, JACK's D-Bus detection, the X11 bell.
    \\context.properties = {
    \\    module.rt = false
    \\    module.portal = false
    \\    module.jackdbus-detect = false
    \\    module.x11.bell = false
    \\}
    \\
;

const pulse_conf =
    \\# vh-game (docs/uni/game.md, G2): the gaming session's pulse server, on its usual socket
    \\# ($XDG_RUNTIME_DIR/pulse/native, the session's own); no name on D-Bus, which the session
    \\# does not have.
    \\pulse.properties = {
    \\    server.dbus-name = ""
    \\}
    \\
;

const wireplumber_conf =
    \\# vh-game (docs/uni/game.md, G2): the gaming session's own WirePlumber, for the sound cards
    \\# alone. Nothing of Bluetooth (BlueZ is on the system's D-Bus, out of the session's reach),
    \\# cameras, MIDI or D-Bus: less memory, and nothing probed in vain.
    \\wireplumber.profiles = {
    \\  main = {
    \\    hardware.bluetooth = disabled
    \\    hardware.video-capture = disabled
    \\    monitor.bluez = disabled
    \\    monitor.bluez-midi = disabled
    \\    monitor.v4l2 = disabled
    \\    monitor.libcamera = disabled
    \\    monitor.alsa-midi = disabled
    \\    support.dbus = disabled
    \\    support.system-dbus = disabled
    \\    support.reserve-device = disabled
    \\    monitor.alsa.reserve-device = disabled
    \\    support.portal-permissionstore = disabled
    \\    script.client.access-portal = disabled
    \\    support.logind = disabled
    \\    support.mpris = disabled
    \\  }
    \\}
    \\
;

/// Game's ACL entry (read and write) on the sound cards' playback and control nodes there now
/// (ADD), as the udev rule gives it at every boot and hotplug; or game's entry taken off every
/// node of /dev/snd (the mode alone again where nothing else is left). The number of nodes.
fn soundAcl(uid: u32, add: bool) usize {
    var n: usize = 0;
    for (vh.listDir(common.snd_dir) catch return 0) |name| {
        if (add and !common.playbackNode(name)) continue;
        const p = vh.fmt("{s}/{s}", .{ common.snd_dir, name });
        const st = vh.stat(p, false) catch continue;
        if (st.mode & vh.S.IFMT != vh.S.IFCHR) continue;
        const old = sys.getXattr(p, acl.name);
        if (add) {
            if (old) |x| if (acl.userPerm(x, uid)) |perm| if ((perm & 6) == 6) {
                n += 1;
                continue;
            };
            const new = acl.withUser(old, st.mode & 0o7777, uid, 6) orelse {
                vh.warn("{s}: an access ACL this program cannot read; left as it is", .{p});
                continue;
            };
            sys.setXattr(p, acl.name, new) catch {
                vh.warn("{s}: the ACL: {s}", .{ p, vh.serr() });
                continue;
            };
            n += 1;
        } else {
            const x = old orelse continue;
            const w = acl.withoutUser(x, uid) orelse continue;
            if (w.acl) |a| {
                sys.setXattr(p, acl.name, a) catch vh.die("{s}: the ACL: {s}", .{ p, vh.serr() });
            } else {
                sys.removeXattr(p, acl.name) catch vh.die("{s}: the ACL: {s}", .{ p, vh.serr() });
                sys.chmod(p, (st.mode & 0o7707) | (@as(u32, w.group) << 3)) catch vh.die("{s}: {s}", .{ p, vh.serr() });
            }
            n += 1;
        }
    }
    return n;
}

fn accessLine() []const u8 {
    return vh.fmt("+ : {s} : {s}", .{ G.user, G.tty });
}

/// VH_PLAN_GAME_PACKAGES of a fresh plan of this machine (or of --plan-env)
fn gamePackages(c: Cfg) []const []const u8 {
    const S = c.o.sys;
    var env_path = c.plan_env orelse "";
    if (env_path.len == 0) {
        const out = S.path("/run/vh/game-plan");
        vh.mkdirs(out, 0o700);
        var argv: std.ArrayList([]const u8) = .empty;
        argv.appendSlice(vh.gpa, &.{ S.path("/usr/local/sbin/vh-plan"), "plan", "--hw", S.path("/etc/vh/hw.zon"), "--hwdb", S.path("/root/vh/hwdb"), "--pins", S.path("/root/vh/kernel/pins"), "--config", S.path("/root/vh/vh.conf.example") }) catch vh.oom();
        if (vh.isRegular(S.path("/root/vh/vh.conf"))) argv.appendSlice(vh.gpa, &.{ "--config", S.path("/root/vh/vh.conf") }) catch vh.oom();
        argv.appendSlice(vh.gpa, &.{ "--out", out }) catch vh.oom();
        var o: std.ArrayList(u8) = .empty;
        var e: std.ArrayList(u8) = .empty;
        const rc = vh.runOpts(argv.items, .{ .out = &o, .err = &e });
        // 3: the gate refuses the machine (an installed tiered one); the plan is written all the same
        if (rc != 0 and rc != 3) vh.die("vh-plan failed ({d}): {s}", .{ rc, vh.strip(e.items) });
        env_path = vh.fmt("{s}/plan.env", .{out});
    }
    const env = vh.readFile(env_path) catch vh.die("{s}: {s}", .{ env_path, vh.serr() });
    const v = common.planValue(env, "VH_PLAN_GAME_PACKAGES") orelse vh.die("{s} names no package of the gaming root: hwdb and vh-plan are older than vh-game (install/build-tools.sh, /root/vh)", .{env_path});
    const w = common.words(v);
    if (w.len == 0) vh.die("the plan of this machine has no Vulkan driver for the gaming root ({s})", .{env_path});
    for (w) |p| for (p) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '+')) vh.die("{s}: not a package name: {s}", .{ env_path, p });
    return w;
}

/// the yescrypt hash of the game user's password: typed twice on the terminal, or one line of
/// stdin; libxcrypt hashes it (vh-hashpw, as for the installer's VM tests), with the cost of
/// system-auth (rounds=7)
fn password(c: Cfg) []const u8 {
    if (c.password_hash) |h| {
        if (!vh.startsWith(h, "$y$")) vh.die("--password-hash: not a yescrypt hash", .{});
        return h;
    }
    const pw = if (c.password_stdin) vh.readLine() orelse vh.die("no password on stdin", .{}) else askTwice("The password of game (its login on tty3): ");
    if (pw.len == 0) vh.die("an empty password is not allowed", .{});
    var o: std.ArrayList(u8) = .empty;
    const rc = vh.runOpts(&.{ c.o.sys.path("/root/vh/tools/vh-hashpw"), "7" }, .{ .in = pw, .out = &o });
    std.crypto.secureZero(u8, @constCast(pw));
    const h = vh.strip(o.items);
    if (rc != 0 or !vh.startsWith(h, "$y$")) vh.die("vh-hashpw gave no yescrypt hash ({d})", .{rc});
    return h;
}

fn askTwice(prompt: []const u8) []const u8 {
    const fd = vh.openFd("/dev/tty", .{ .ACCMODE = .RDWR }, 0) catch vh.die("/dev/tty: {s} (--password-stdin reads it from stdin)", .{vh.serr()});
    defer vh.close(fd);
    var old: linux.termios = undefined;
    _ = vh.sys(linux.tcgetattr(fd, &old)) catch vh.die("/dev/tty: {s}", .{vh.serr()});
    var quiet = old;
    quiet.lflag.ECHO = false;
    const a = readSecret(fd, &old, &quiet, prompt);
    const b = readSecret(fd, &old, &quiet, "The same again: ");
    if (!vh.eql(a, b)) vh.die("the two differ", .{});
    return a;
}

fn readSecret(fd: vh.fd_t, old: *const linux.termios, quiet: *const linux.termios, prompt: []const u8) []const u8 {
    vh.writeAllFd(fd, prompt) catch {};
    _ = linux.tcsetattr(fd, .FLUSH, quiet);
    var line: std.ArrayList(u8) = .empty;
    while (true) {
        var ch: [1]u8 = undefined;
        const r = vh.readFd(fd, &ch) catch break;
        if (r == 0 or ch[0] == '\n') break;
        line.append(vh.gpa, ch[0]) catch vh.oom();
    }
    _ = linux.tcsetattr(fd, .FLUSH, old);
    vh.writeAllFd(fd, "\n") catch {};
    return line.items;
}

// ---------------------------------------------------------------- remove

fn remove(c: Cfg) void {
    const S = c.o.sys;
    // the account, if it is there, must be the one install made
    const f0 = accounts.Files.lock(S.prefix);
    const passwd0 = f0.read("passwd") orelse "";
    f0.unlock();
    if (accounts.find(passwd0, G.user)) |l| {
        const gecos = accounts.field(l, 4) orelse "";
        const shell = accounts.field(l, 6) orelse "";
        if (!vh.eql(gecos, G.gecos) or !vh.eql(shell, G.shell)) vh.die("the user {s} is not the gaming session's (its comment or shell differs): nothing removed", .{G.user});
    }
    if (!c.yes) {
        vh.out("This removes the gaming session: the user {s}, its home {s} with everything in it (games, saves, settings), the root {s}, the login on {s}, the gaming boot, the gaming kernels built and their module key.\nType \"remove\" to continue: ", .{ G.user, G.home, roots.path(.{}, G.root), G.tty });
        vh.flush();
        const got = vh.readLine() orelse "";
        if (!vh.eql(vh.strip(got), "remove")) vh.die("cancelled", .{});
    }
    const uid: ?u32 = if (accounts.find(passwd0, G.user)) |l| std.fmt.parseInt(u32, accounts.field(l, 2) orelse "", 10) catch null else null;

    // the gaming boot first: its entry and the twin off the ESP, its files out of /etc
    if (vh.pathExists(S.path(boot.marker)) or vh.pathExists(S.path(boot.core_script))) _ = bootOff(c);

    // the session: the getty, then every process of game
    if (S.prefix.len == 0) _ = ttyOff(c);
    if (uid) |id| endProcesses(id);

    // the sound cards: the rule first, so that no event gives the entry back, then the entries
    const rule = S.path(G.sound_rule);
    if (vh.pathExists(rule)) vh.unlink(rule) catch vh.die("{s}: {s}", .{ rule, vh.serr() });
    if (S.prefix.len == 0) if (uid) |id| {
        _ = soundAcl(id, false);
    };

    roots.remove(c.o, G.root);
    // the gaming kernel: its module key, the kernels built and vh-kconf install's records of
    // them (with its lock and records directory when no machine kernel was ever installed)
    key.remove(S);
    const gd = S.path("/var/lib/vh/game");
    if (vh.isDir(gd)) rmtree.removeTree(gd);
    dropKernelRecords(S);

    const home = S.path(G.home);
    if (roots.isMountPoint(home)) sys.umount(home, 0) catch vh.die("umount {s}: {s}", .{ home, vh.serr() });
    editFile(S.path("/etc/fstab"), common.fstabBind(G.home));
    editFile(S.path("/etc/fstab"), common.fstabBindOld(G.home));
    if (vh.isDir(home)) rmtree.removeTree(home);
    editFile(S.path("/etc/security/access.conf"), accessLine());
    editFile(S.path("/etc/shells"), G.shell);
    const f = accounts.Files.lock(S.prefix);
    accounts.removeUser(f, G.user, &G.groups);
    f.unlock();
    if (vh.isDir(S.path("/run/vh/game-plan"))) rmtree.removeTree(S.path("/run/vh/game-plan"));
    vh.log("removed: the system is as it was before vh-game install", .{});
    vh.outs("VH_GAME removed\n");
}

/// vh-kconf install's records of the gaming kernels (/var/lib/vh/kernels/A.B.C-vh-game_N); its
/// lock and the records' directory too when nothing else is recorded there: they came with the
/// first install, a gaming kernel's
fn dropKernelRecords(S: common.System) void {
    const kd = S.path("/var/lib/vh/kernels");
    const names = vh.listDir(kd) catch return;
    var others: usize = 0;
    for (names) |n| {
        if (mem.indexOf(u8, n, "-vh-game_") != null) {
            rmtree.removeTree(vh.fmt("{s}/{s}", .{ kd, n }));
        } else others += 1;
    }
    if (others > 0) return;
    _ = vh.sys(linux.rmdir(vh.z(kd).ptr)) catch {};
    vh.unlink(S.path("/var/lib/vh/kconf-install.lock")) catch {};
}

/// the line taken out of the file when it is there
fn editFile(p: []const u8, line: []const u8) void {
    const text = vh.readFile(p) catch return;
    if (lines.remove(text, line)) |t| roots.writeKeeping(p, t);
}

/// SIGKILL to every process of UID until none is left (the session's PID namespace dies with
/// its first process)
fn endProcesses(uid: u32) void {
    var round: usize = 0;
    while (round < 50) : (round += 1) {
        const pids = sys.processesOf(uid);
        if (pids.len == 0) return;
        for (pids) |p| _ = linux.kill(p, .KILL);
        sys.sleepMs(100);
    }
    vh.die("the processes of uid {d} do not end", .{uid});
}

// ---------------------------------------------------------------- tty3

fn ttyOn(c: Cfg) u8 {
    if (c.o.sys.prefix.len > 0) vh.die("tty on acts on the running system only", .{});
    const f = accounts.Files.lock("");
    const passwd = f.read("passwd") orelse "";
    f.unlock();
    if (accounts.find(passwd, G.user) == null) vh.die("the gaming session is not installed (doas vh-game install)", .{});
    if (vh.pathExists("/etc/runit/runsvdir/default/agetty-tty3")) {
        vh.log("{s} has a getty at every boot already (a link in /etc/runit/runsvdir/default)", .{G.tty});
        return 0;
    }
    if (boot.gettyRunsv() != null) {
        vh.log("the login of {s} on {s} is on already", .{ G.user, G.tty });
        return 0;
    }
    // in the gaming boot a getty started from here would inherit the x86_64 filter: tty3's login
    // runs outside it only as the boot starts it
    if (boot.gamingBoot(.{}) and boot.filtered())
        vh.die("this is the gaming boot: its login on {s} starts with the boot only, outside the x86_64 filter; it comes back with the next gaming boot (doas vh-game play)", .{G.tty});
    boot.spawnGetty() catch vh.die("runsv {s}: {s}", .{ G.getty, vh.serr() });
    sys.sleepMs(500);
    if (boot.gettyRunsv() == null) vh.die("runsv {s} did not start", .{G.getty});
    vh.log("the login of {s} is on {s} until the next boot (doas vh-game tty off ends it)", .{ G.user, G.tty });
    return 0;
}

fn ttyOff(c: Cfg) u8 {
    if (c.o.sys.prefix.len > 0) return 0;
    const pid = boot.gettyRunsv() orelse return 0;
    // TERM makes runsv stop the getty and exit (as sv exit)
    _ = linux.kill(pid, .TERM);
    var i: usize = 0;
    while (i < 50 and boot.gettyRunsv() != null) : (i += 1) sys.sleepMs(100);
    if (boot.gettyRunsv() != null) vh.die("runsv {s} does not end", .{G.getty});
    vh.log("the login of {s} on {s} is off", .{ G.user, G.tty });
    return 0;
}

// ---------------------------------------------------------------- the gaming boot

/// vh-game boot on: the marker and the stage-1 script, then vh-limine-update makes the twin of
/// the newest stock UKI and its entry. A failure leaves the gaming boot off.
fn bootOn(c: Cfg) u8 {
    const S = c.o.sys;
    if (!c.any_arch and builtin.cpu.arch != .x86_64) vh.die("the gaming boot is for x86_64 machines", .{});
    // the session first: a gaming boot without it would only open ia32
    const passwd = vh.readFile(S.path("/etc/passwd")) catch "";
    if (accounts.find(passwd, G.user) == null or !roots.exists(c.o, G.root)) vh.die("the gaming session is not installed (doas vh-game install)", .{});
    if (!vh.isRegular(S.path(boot.stage2_path))) vh.die("{s}: missing (runit-void)", .{S.path(boot.stage2_path)});
    if (!vh.isDir(S.path("/etc/runit/core-services"))) vh.die("{s}: missing (runit-void)", .{S.path("/etc/runit/core-services")});
    if (!vh.isDir(S.path("/etc/vh"))) vh.die("{s}: missing: the system is not one UniVoidDistro installed", .{S.path("/etc/vh")});
    vh.writeAtomic(S.path(boot.marker), boot.marker_text, 0o755);
    vh.writeAtomic(S.path(boot.core_script), boot.core_script_text, 0o644);
    const rc = limineUpdate(c, &.{});
    if (rc != 0) {
        vh.unlink(S.path(boot.marker)) catch {};
        vh.unlink(S.path(boot.core_script)) catch {};
        _ = limineUpdate(c, &.{});
        vh.die("vh-limine-update failed ({d}): the gaming boot stays off", .{rc});
    }
    vh.log("the gaming boot is on: the last entry of Limine's menu; doas vh-game play reboots into it once", .{});
    vh.outs("VH_GAME boot on\n");
    return 0;
}

/// vh-game boot off: the marker and the stage-1 script go, then vh-limine-update takes the
/// twin and its entry away (and a one-shot entry of play that waits for it)
fn bootOff(c: Cfg) u8 {
    const S = c.o.sys;
    for ([_][]const u8{ boot.marker, boot.core_script }) |p| if (vh.pathExists(S.path(p)))
        vh.unlink(S.path(p)) catch vh.die("{s}: {s}", .{ S.path(p), vh.serr() });
    const rc = limineUpdate(c, &.{});
    if (rc != 0) vh.die("vh-limine-update failed ({d}): the gaming entry is still in the menu until it runs (doas vh-game boot off)", .{rc});
    vh.log("the gaming boot is off: its entry and its UKI are gone", .{});
    vh.outs("VH_GAME boot off\n");
    return 0;
}

/// vh-game play: the gaming entry is the next boot's, once (Limine's one-shot entry), then the
/// reboot; the boot after the gaming one is the everyday one again
fn play(c: Cfg) u8 {
    if (c.o.sys.prefix.len > 0) vh.die("play acts on the running system only", .{});
    if (!vh.pathExists(boot.marker)) vh.die("the gaming boot is off: doas vh-game boot on", .{});
    const rc = vh.run(&.{ c.limine orelse "/usr/local/sbin/vh-limine-update", "--game-once" });
    if (rc != 0) vh.die("vh-limine-update --game-once failed ({d})", .{rc});
    if (c.no_reboot) {
        vh.log("the next boot is the gaming one", .{});
        return 0;
    }
    vh.log("rebooting into the gaming boot", .{});
    vh.flush();
    const r = vh.run(&.{"/usr/bin/reboot"});
    if (r != 0) vh.die("reboot failed ({d}): the next boot is the gaming one all the same", .{r});
    return 0;
}

/// vh-limine-update with the ESP mounted: it is noauto in fstab, so it is mounted for the run
/// and unmounted after it, as the kernel hooks do (05-vh-esp, 99-vh-esp). A stand-in of the
/// tests (--limine-update) runs without it.
fn limineUpdate(c: Cfg, extra: []const []const u8) u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    argv.append(vh.gpa, c.limine orelse "/usr/local/sbin/vh-limine-update") catch vh.oom();
    argv.appendSlice(vh.gpa, extra) catch vh.oom();
    if (c.limine != null) return vh.run(argv.items);
    const esp = "/boot/efi";
    const mounted = !roots.isMountPoint(esp);
    if (mounted and vh.run(&.{ "/usr/bin/mount", esp }) != 0) vh.die("could not mount the ESP ({s})", .{esp});
    const rc = vh.run(argv.items);
    if (mounted) {
        linux.sync();
        if (vh.run(&.{ "/usr/bin/umount", esp }) != 0) vh.warn("{s} is still mounted: doas umount {s}", .{ esp, esp });
    }
    return rc;
}

// ---------------------------------------------------------------- status

fn status(c: Cfg) u8 {
    const S = c.o.sys;
    const passwd = vh.readFile(S.path("/etc/passwd")) catch "";
    const line = accounts.find(passwd, G.user);
    const root = roots.path(c.o, G.root);
    const installed = line != null and vh.isDir(root);
    if (line) |l| vh.out("user: {s} ({s}), home {s}, shell {s}\n", .{ G.user, accounts.field(l, 2) orelse "?", accounts.field(l, 5) orelse "?", accounts.field(l, 6) orelse "?" }) else vh.out("user: no {s}\n", .{G.user});
    if (vh.isDir(root)) {
        var pol: vh.Kv = .{};
        pol.read(vh.fmt("{s}/etc/thor/policy.conf", .{root}), false);
        vh.out("root: {s}, {d} packages, thor policy {s}\n", .{ root, roots.packageCount(root), pol.get("mode", "?") });
    } else vh.out("root: none\n", .{});
    const tty_on = S.prefix.len == 0 and boot.gettyRunsv() != null;
    var sessions: usize = 0;
    var sound: usize = 0;
    if (line) |l| if (std.fmt.parseInt(u32, accounts.field(l, 2) orelse "", 10)) |id| {
        sessions = sys.processesOf(id).len;
        if (S.prefix.len == 0) sound = soundNodesOf(id);
    } else |_| {};
    vh.out("{s}: {s}; processes of {s}: {d}\n", .{ G.tty, if (tty_on) "on (until the next boot)" else "off", G.user, sessions });
    vh.out("sound: {d} playback and control node(s) for {s}; the udev rule {s}\n", .{ sound, G.user, if (vh.pathExists(S.path(G.sound_rule))) "in place" else "missing" });
    const boot_on = vh.pathExists(S.path(boot.marker));
    const gaming = boot.gamingBoot(S);
    vh.out("the gaming boot: {s}; this boot is {s}\n", .{ if (boot_on) "on (doas vh-game play)" else "off", if (gaming) "the gaming one" else "an everyday one" });
    // sound stays last: the tests read the line's end
    vh.out("VH_GAME status installed={s} tty={s} processes={d} boot={s} this={s} sound={d}\n", .{ if (installed) "yes" else "no", if (tty_on) "on" else "off", sessions, if (boot_on) "on" else "off", if (gaming) "game" else "everyday", sound });
    return 0;
}

/// the nodes of /dev/snd whose ACL lets UID read and write
fn soundNodesOf(uid: u32) usize {
    var n: usize = 0;
    for (vh.listDir(common.snd_dir) catch return 0) |name| {
        const x = sys.getXattr(vh.fmt("{s}/{s}", .{ common.snd_dir, name }), acl.name) orelse continue;
        if (acl.userPerm(x, uid)) |perm| if ((perm & 6) == 6) {
            n += 1;
        };
    }
    return n;
}
