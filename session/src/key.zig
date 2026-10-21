//! The gaming kernel's module key (vh-game key, docs/uni/game.md, G3b): RSA-4096, SHA-512, a
//! self-signed X.509 certificate with the extensions of the kernel's own signing key
//! (certs/default_x509.genkey). The gaming kernel is built to trust this certificate alone
//! (CONFIG_MODULE_SIG_KEY); the private key signs the NVIDIA modules (G3c), never inside the
//! build's sandbox. It is encrypted under a passphrase (PKCS#8, AES-256, scrypt) and is in the
//! clear only in a pipe between two openssl processes, never on a disk.
//!
//! The key lives next to the Secure Boot keys, in /var/lib/sbctl/keys/vh-game: on the system's
//! encrypted disk, or with optional/sb-offline-keys on the keys' medium, which vh-keys mount
//! binds there. OpenSSL comes from a root of its own (profile keys), made for one use and
//! removed after it: the system has no openssl of its own.
const std = @import("std");
const vh = @import("vh");
const profiles = @import("profiles");
const common = @import("common.zig");
const roots = @import("roots.zig");
const sys = @import("sys.zig");
const linux = std.os.linux;
const mem = std.mem;

/// sbctl's keys (or the medium of optional/sb-offline-keys bound over it)
pub const sb_keys = "/var/lib/sbctl/keys";
pub const dir = sb_keys ++ "/vh-game";
pub const key_name = "module.key";
pub const cert_name = "module.crt";
/// the root of OpenSSL, for one use
const root_name = "keys";

/// the shortest passphrase taken: it guards a key that makes the kernel load code
pub const min_passphrase = 12;

/// the certificate's request: the kernel's own extensions for a module signing key
pub const genkey =
    \\# vh-game key (docs/uni/game.md, G3b): the extensions of the kernel's certs/default_x509.genkey
    \\[ req ]
    \\distinguished_name = dn
    \\prompt = no
    \\x509_extensions = ext
    \\[ dn ]
    \\CN = vh-game module key
    \\O = UniVoidDistro
    \\[ ext ]
    \\basicConstraints = critical,CA:FALSE
    \\keyUsage = digitalSignature
    \\subjectKeyIdentifier = hash
    \\authorityKeyIdentifier = keyid
    \\
;

pub fn certPath(S: common.System) []const u8 {
    return S.path(dir ++ "/" ++ cert_name);
}

pub fn keyPath(S: common.System) []const u8 {
    return S.path(dir ++ "/" ++ key_name);
}

/// whether the Secure Boot keys are offline (optional/sb-offline-keys: KEYS_OFFLINE=yes)
fn keysOffline(S: common.System) bool {
    var conf: vh.Kv = .{};
    conf.read(S.path("/etc/vh/boot.conf"), false);
    return vh.eql(conf.get("KEYS_OFFLINE", "no"), "yes");
}

/// The key's directory, where the Secure Boot keys are: refused while they are offline and their
/// medium is not attached, or when the system has none yet.
fn keysPlace(S: common.System) []const u8 {
    const k = S.path(sb_keys);
    if (keysOffline(S) and S.prefix.len == 0 and !roots.isMountPoint(k))
        vh.die("the Secure Boot keys are offline and their medium is not attached: doas vh-keys mount (the module key lives beside them)", .{});
    if (!vh.isDir(k)) vh.die("{s}: no Secure Boot keys yet (stage 2: 20-firstboot.sh); the module key lives beside them", .{k});
    return k;
}

/// vh-game key new: the key and its certificate, the passphrase asked twice on the terminal (or
/// one line of stdin); refused when a key is there already
pub fn new(o: roots.Opts, passphrase: []const u8) void {
    const S = o.sys;
    if (passphrase.len < min_passphrase) vh.die("the passphrase has {d} characters: at least {d}", .{ passphrase.len, min_passphrase });
    _ = keysPlace(S);
    const d = S.path(dir);
    if (vh.pathExists(d)) vh.die("{s} exists already: the module key is made once (its certificate is built into the gaming kernel)", .{d});

    const profile = profiles.get(root_name).?;
    roots.after_failure = "no module key was made";
    roots.create(o, root_name, profile, &.{}, null);
    const root = roots.path(o, root_name);
    const out = vh.fmt("{s}/out", .{root});
    sys.mkdir(out, 0o700) catch fail(o, "{s}: {s}", .{ out, vh.serr() });
    vh.writeAtomic(vh.fmt("{s}/x509.genkey", .{out}), genkey, 0o600);

    // genpkey | pkcs8: the key in the clear only in the pipe between the two
    const pipe = makePipe(o);
    const pass1 = passPipe(o, passphrase);
    const gen = spawn(root, &.{ "/usr/bin/openssl", "genpkey", "-quiet", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:4096" }, null, pipe[1], null);
    // scrypt at OpenSSL's memory limit for it (32 MiB: N 2^14 with r 8 uses 16 MiB), four times
    // its work (p 4): every openssl that reads the key again must stay within that limit
    const enc = spawn(root, &.{ "/usr/bin/openssl", "pkcs8", "-topk8", "-v2", "aes-256-cbc", "-scrypt", "-scrypt_N", "16384", "-scrypt_r", "8", "-scrypt_p", "4", "-passout", "fd:3", "-out", "/out/" ++ key_name }, pipe[0], null, pass1);
    vh.close(pipe[0]);
    vh.close(pipe[1]);
    vh.close(pass1);
    if (wait(gen) != 0 or wait(enc) != 0) fail(o, "openssl could not make the key (above)", .{});
    const pass2 = passPipe(o, passphrase);
    const req = spawn(root, &.{ "/usr/bin/openssl", "req", "-new", "-x509", "-config", "/out/x509.genkey", "-key", "/out/" ++ key_name, "-passin", "fd:3", "-sha512", "-days", "36500", "-out", "/out/" ++ cert_name }, null, null, pass2);
    vh.close(pass2);
    if (wait(req) != 0) fail(o, "openssl could not make the certificate (above)", .{});

    const key = vh.readFile(vh.fmt("{s}/{s}", .{ out, key_name })) catch fail(o, "the key: {s}", .{vh.serr()});
    const cert = vh.readFile(vh.fmt("{s}/{s}", .{ out, cert_name })) catch fail(o, "the certificate: {s}", .{vh.serr()});
    if (!vh.startsWith(key, "-----BEGIN ENCRYPTED PRIVATE KEY-----")) fail(o, "the key is not an encrypted PKCS#8 key", .{});
    const der = pemBody(cert, "CERTIFICATE") orelse fail(o, "the certificate is not one PEM certificate", .{});

    // the key's place: written there, then synced (a copy: the medium is another file system)
    sys.mkdir(d, 0o700) catch vh.die("{s}: {s}", .{ d, vh.serr() });
    sys.chmod(d, 0o700) catch vh.die("{s}: {s}", .{ d, vh.serr() });
    writeSynced(keyPath(S), key, 0o600);
    writeSynced(certPath(S), cert, 0o644);
    roots.remove(o, root_name);
    vh.log("the module key is made: {s} (encrypted), {s}", .{ keyPath(S), certPath(S) });
    vh.out("VH_GAME key fingerprint={s}\n", .{fingerprint(der)});
}

/// vh-game key show
pub fn show(S: common.System) u8 {
    const cert = vh.readFile(certPath(S)) catch {
        vh.out("module key: none ({s}; doas vh-game key new)\nVH_GAME key none\n", .{S.path(dir)});
        return 0;
    };
    const der = pemBody(cert, "CERTIFICATE") orelse vh.die("{s}: not one PEM certificate", .{certPath(S)});
    const key = vh.readFile(keyPath(S)) catch "";
    const encrypted = vh.startsWith(key, "-----BEGIN ENCRYPTED PRIVATE KEY-----");
    vh.out("module key: {s}, the private key {s}\n", .{ S.path(dir), if (key.len == 0) "missing" else if (encrypted) "encrypted" else "NOT ENCRYPTED" });
    vh.out("VH_GAME key fingerprint={s} private={s}\n", .{ fingerprint(der), if (key.len == 0) "missing" else if (encrypted) "encrypted" else "clear" });
    return 0;
}

/// vh-game key remove (and vh-game remove): the key and its directory; the key's medium must be
/// attached when the keys are offline
pub fn remove(S: common.System) void {
    const d = S.path(dir);
    if (!vh.pathExists(d)) {
        if (keysOffline(S) and S.prefix.len == 0 and !roots.isMountPoint(S.path(sb_keys)))
            vh.warn("the Secure Boot keys are offline: a module key on their medium stays (doas vh-keys mount, then doas vh-game key remove)", .{});
        return;
    }
    for ([_][]const u8{ keyPath(S), certPath(S) }) |p| if (vh.pathExists(p)) vh.unlink(p) catch vh.die("{s}: {s}", .{ p, vh.serr() });
    _ = vh.sys(linux.rmdir(vh.z(d).ptr)) catch vh.die("{s}: {s} (a file of its own in it?)", .{ d, vh.serr() });
    vh.log("the module key is removed: {s}", .{d});
}

// ---------------------------------------------------------------- openssl in its root

fn fail(o: roots.Opts, comptime f: []const u8, args: anytype) noreturn {
    vh.warn(f, args);
    if (roots.exists(o, root_name)) roots.remove(o, root_name);
    vh.exit(1);
}

fn makePipe(o: roots.Opts) [2]vh.fd_t {
    var p: [2]i32 = undefined;
    _ = vh.sys(linux.pipe2(&p, .{ .CLOEXEC = true })) catch fail(o, "pipe: {s}", .{vh.serr()});
    return .{ p[0], p[1] };
}

/// a pipe whose reading end gives the passphrase and a newline, as openssl's fd:N reads it
fn passPipe(o: roots.Opts, passphrase: []const u8) vh.fd_t {
    const p = makePipe(o);
    vh.writeAllFd(p[1], passphrase) catch fail(o, "pipe: {s}", .{vh.serr()});
    vh.writeAllFd(p[1], "\n") catch fail(o, "pipe: {s}", .{vh.serr()});
    vh.close(p[1]);
    return p[0];
}

/// a program of ROOT, run as root inside it (chroot), with these descriptors as its stdin,
/// stdout and fd 3 (null: its own); its environment is empty but PATH
fn spawn(root: []const u8, argv: []const []const u8, in: ?vh.fd_t, out: ?vh.fd_t, fd3: ?vh.fd_t) linux.pid_t {
    var args: std.ArrayList(?[*:0]const u8) = .empty;
    for (argv) |a| args.append(vh.gpa, vh.z(a).ptr) catch vh.oom();
    args.append(vh.gpa, null) catch vh.oom();
    const argz: [*:null]const ?[*:0]const u8 = @ptrCast(args.items.ptr);
    const envp = [_:null]?[*:0]const u8{"PATH=/usr/bin"};
    const rootz = vh.z(root);
    const pid = linux.fork();
    if (pid == 0) {
        if (linux.errno(linux.chroot(rootz.ptr)) != .SUCCESS or linux.errno(linux.chdir("/")) != .SUCCESS) linux.exit_group(126);
        if (in) |f| moveFd(f, 0);
        if (out) |f| moveFd(f, 1);
        if (fd3) |f| moveFd(f, 3);
        _ = linux.execve(argz[0].?, argz, &envp);
        linux.exit_group(127);
    }
    if (linux.errno(pid) != .SUCCESS) vh.die("fork: {s}", .{vh.strerror(linux.errno(pid))});
    return @intCast(pid);
}

/// F to the descriptor TARGET of a child about to exec: dup2, which leaves the copy without
/// CLOEXEC; when F is TARGET already (a pipe made while 0-3 were free), dup2 does nothing, so
/// CLOEXEC is cleared instead
fn moveFd(f: vh.fd_t, target: i32) void {
    if (f == target) {
        _ = linux.fcntl(f, linux.F.SETFD, 0);
    } else _ = linux.dup2(f, target);
}

fn wait(pid: linux.pid_t) u32 {
    var st: i32 = 0;
    while (true) {
        const rc = linux.wait4(pid, &st, 0, null);
        if (linux.errno(rc) == .INTR) continue;
        break;
    }
    const s: u32 = @bitCast(st);
    return if (linux.W.IFEXITED(s)) linux.W.EXITSTATUS(s) else 128 + @as(u32, @intFromEnum(linux.W.TERMSIG(s)));
}

fn writeSynced(p: []const u8, data: []const u8, mode: u32) void {
    const fd = vh.openFd(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true }, mode) catch vh.die("{s}: {s}", .{ p, vh.serr() });
    defer vh.close(fd);
    vh.writeAllFd(fd, data) catch vh.die("{s}: {s}", .{ p, vh.serr() });
    _ = vh.sys(linux.fsync(fd)) catch vh.die("{s}: {s}", .{ p, vh.serr() });
}

// ---------------------------------------------------------------- PEM and the fingerprint

/// the DER of the one PEM block of type WHAT in TEXT; null when there is none, or more than one
pub fn pemBody(text: []const u8, what: []const u8) ?[]const u8 {
    const begin = vh.fmt("-----BEGIN {s}-----", .{what});
    const end = vh.fmt("-----END {s}-----", .{what});
    const b = mem.indexOf(u8, text, begin) orelse return null;
    if (mem.indexOf(u8, text[b + begin.len ..], begin) != null) return null;
    const e = mem.indexOf(u8, text[b..], end) orelse return null;
    var b64: std.ArrayList(u8) = .empty;
    for (text[b + begin.len .. b + e]) |c| if (!vh.isSpace(c)) b64.append(vh.gpa, c) catch vh.oom();
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(b64.items) catch return null;
    const der = vh.gpa.alloc(u8, n) catch vh.oom();
    dec.decode(der, b64.items) catch return null;
    if (der.len < 2 or der[0] != 0x30) return null; // a DER SEQUENCE
    return der;
}

/// the certificate's SHA-256 fingerprint, as openssl x509 -fingerprint -sha256 prints it
pub fn fingerprint(der: []const u8) []const u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(der, &d, .{});
    var out: std.ArrayList(u8) = .empty;
    for (d, 0..) |c, i| out.print(vh.gpa, "{s}{X:0>2}", .{ if (i > 0) ":" else "", c }) catch vh.oom();
    return out.items;
}

const t = std.testing;

test "the module key: PEM, the fingerprint, the request" {
    // a certificate-like DER (a SEQUENCE), in PEM with its lines folded
    const der = [_]u8{ 0x30, 0x03, 0x02, 0x01, 0x05 };
    var b64: [16]u8 = undefined;
    const enc = std.base64.standard.Encoder.encode(&b64, &der);
    const pem = vh.fmt("junk\n-----BEGIN CERTIFICATE-----\n{s}\n{s}\n-----END CERTIFICATE-----\n", .{ enc[0..4], enc[4..] });
    try t.expectEqualSlices(u8, &der, pemBody(pem, "CERTIFICATE").?);
    try t.expect(pemBody(pem, "PRIVATE KEY") == null);
    try t.expect(pemBody(vh.fmt("{s}{s}", .{ pem, pem }), "CERTIFICATE") == null);
    try t.expect(pemBody("-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n", "CERTIFICATE") == null);
    // the SHA-256 of those five bytes, as openssl prints it
    const fp = fingerprint(&der);
    try t.expectEqual(@as(usize, 32 * 3 - 1), fp.len);
    try t.expect(std.ascii.isHex(fp[0]) and fp[2] == ':');
    // the kernel's signing key extensions, and no CA
    for ([_][]const u8{ "basicConstraints = critical,CA:FALSE", "keyUsage = digitalSignature", "subjectKeyIdentifier = hash", "authorityKeyIdentifier = keyid" }) |e|
        try t.expect(mem.indexOf(u8, genkey, e) != null);
}
