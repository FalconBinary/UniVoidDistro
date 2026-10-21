//! The boot assessment of a machine UKI (docs/uni/kernel.md, "The boot assessment").
//!
//! A machine UKI on trial is booted through Limine's one-shot entry (LoaderEntryOneShot of
//! systemd's Boot Loader Interface, which Limine erases before any entry boots); after
//! MACHINE_BOOTS good boots it becomes Limine's default (LoaderEntryDefault). limine.conf does
//! not change for either. Here: the variables through efivarfs, the identifiers Limine gives
//! its menu entries, the verdict of vh-kconf check, the state file and the decisions, which
//! are pure functions of the state and of what one boot looked like (the unit tests run them
//! without firmware). vh-limine-update is the only user.
const std = @import("std");
const vh = @import("vh");
const linux = std.os.linux;
const mem = std.mem;

/// systemd's Boot Loader Interface vendor GUID, as Limine uses it (12.9.3: common/lib/bli.c)
pub const bli_guid = "4a67b082-0a4c-41cf-b6c7-440b29bb8c4f";
pub const efivars = "/sys/firmware/efi/efivars";
/// EFI_VARIABLE_NON_VOLATILE | EFI_VARIABLE_BOOTSERVICE_ACCESS | EFI_VARIABLE_RUNTIME_ACCESS
pub const attr_nv: u32 = 0x7;
/// LoaderFeatures: one-shot entry control (systemd's EFI_LOADER_FEATURE_ENTRY_ONESHOT)
pub const feature_oneshot: u64 = 1 << 3;
/// how many good boots of a trial make it the default when boot.conf does not say
pub const default_boots = 3;

// ---------------------------------------------------------------- menu entries

/// The menu name of a machine UKI, the same in every role (on trial, the default, an older
/// one), so that its identifier never changes: "Void Linux 6.18.57-vh_2 (machine kernel)".
pub fn entryName(ver: []const u8) []const u8 {
    return vh.fmt("Void Linux {s} (machine kernel)", .{ver});
}

/// "linux-6.18.57-vh_2.efi" -> "6.18.57-vh_2"; the name itself when it is not a UKI's
pub fn verOf(uki: []const u8) []const u8 {
    if (vh.startsWith(uki, "linux-") and vh.endsWith(uki, ".efi") and uki.len > 10) return uki[6 .. uki.len - 4];
    return uki;
}

/// "6.18.57-vh_2" -> "6.18.57-vh", the release the kernel reports (uname -r)
pub fn releaseOf(ver: []const u8) []const u8 {
    return ver[0 .. mem.lastIndexOfScalar(u8, ver, '_') orelse ver.len];
}

/// Limine's identifier of a top-level menu entry (12.9.3, common/menu.c): the entry's path,
/// that is its name with "\", "/" and "#" escaped by a backslash, mapped onto
/// [A-Za-z0-9+_.@-] with "/" to "." and every other byte to "-", at most 232 bytes; an empty,
/// "." or ".." result gains a "-". Limine appends "-N" to a later duplicate, which unique names
/// never get.
pub fn entryId(name: []const u8) []const u8 {
    var path: std.ArrayList(u8) = .empty;
    for (name) |c| {
        if (c == '\\' or c == '/' or c == '#') path.append(vh.gpa, '\\') catch vh.oom();
        path.append(vh.gpa, c) catch vh.oom();
    }
    var out: std.ArrayList(u8) = .empty;
    for (path.items) |c| {
        if (out.items.len >= 256 - 24) break;
        const keep = std.ascii.isAlphanumeric(c) or c == '+' or c == '_' or c == '.' or c == '@' or c == '-';
        out.append(vh.gpa, if (keep) c else if (c == '/') '.' else '-') catch vh.oom();
    }
    if (out.items.len == 0 or vh.eql(out.items, ".") or vh.eql(out.items, "..")) out.append(vh.gpa, '-') catch vh.oom();
    return out.items;
}

/// the identifier of a machine UKI's entry, from its file name
pub fn ukiId(uki: []const u8) []const u8 {
    return entryId(entryName(verOf(uki)));
}

/// The menu name of the gaming boot (vh-game boot on, docs/uni/game.md): the stock UKI VER
/// with ia32 on, "Void Linux 6.18.58_1 (games)". Its identifier ends in game_id_suffix.
pub fn gameEntryName(ver: []const u8) []const u8 {
    return vh.fmt("Void Linux {s} (games)", .{ver});
}

pub const game_id_suffix = "--games-";

/// the identifier of the gaming entry of the twin UKI (its file name is the stock UKI's)
pub fn gameId(uki: []const u8) []const u8 {
    return entryId(gameEntryName(verOf(uki)));
}

/// an identifier (or, from Limine before 12.7, a path) of the gaming entry
pub fn isGameEntry(selected: []const u8) bool {
    return vh.endsWith(selected, game_id_suffix) or vh.endsWith(selected, " (games)");
}

// ---------------------------------------------------------------- EFI variables

/// a string as an EFI variable of the Boot Loader Interface holds it: UTF-16LE and a NUL
pub fn utf16(s: []const u8) []const u8 {
    const out = vh.gpa.alloc(u8, (s.len + 1) * 2) catch vh.oom();
    for (s, 0..) |c, i| {
        out[2 * i] = c;
        out[2 * i + 1] = 0;
    }
    out[2 * s.len] = 0;
    out[2 * s.len + 1] = 0;
    return out;
}

/// the strings of a UTF-16LE value, each ended by a NUL (LoaderEntries holds several); a string
/// with a character that is not printable ASCII is dropped (identifiers are ASCII)
pub fn utf16List(d: []const u8) []const []const u8 {
    var list: vh.Strv = .{};
    var cur: std.ArrayList(u8) = .empty;
    var ok = true;
    var i: usize = 0;
    while (i + 1 < d.len) : (i += 2) {
        const c = @as(u16, d[i]) | (@as(u16, d[i + 1]) << 8);
        if (c == 0) {
            if (ok and cur.items.len > 0) list.add(cur.items);
            cur = .empty;
            ok = true;
            continue;
        }
        if (c < 0x20 or c > 0x7e) ok = false else cur.append(vh.gpa, @intCast(c)) catch vh.oom();
    }
    if (ok and cur.items.len > 0) list.add(cur.items);
    return list.slice();
}

/// the first string of a UTF-16LE value; null when there is none
pub fn fromUtf16(d: []const u8) ?[]const u8 {
    const l = utf16List(d);
    return if (l.len > 0) l[0] else null;
}

/// FS_IOC_GETFLAGS, FS_IOC_SETFLAGS (_IOR/_IOW('f', 1/2, long)) and FS_IMMUTABLE_FL
const FS_IOC_GETFLAGS: u32 = 0x80086601;
const FS_IOC_SETFLAGS: u32 = 0x40086602;
const FS_IMMUTABLE_FL: u64 = 0x10;

/// The variables of the Boot Loader Interface in efivarfs (the directory is a parameter for
/// the tests). efivarfs makes a variable it does not know immutable (chattr +i): the flag is
/// cleared before a write or a delete, as efibootmgr and systemd do.
pub const Vars = struct {
    dir: []const u8 = efivars,

    pub fn path(self: Vars, name: []const u8) []const u8 {
        return vh.fmt("{s}/{s}-{s}", .{ self.dir, name, bli_guid });
    }

    /// the data without the 4 bytes of attributes; null when the variable does not exist
    pub fn read(self: Vars, name: []const u8) ?[]const u8 {
        const d = vh.readFile(self.path(name)) catch return null;
        if (d.len < 4) return null;
        return d[4..];
    }

    pub fn string(self: Vars, name: []const u8) ?[]const u8 {
        return fromUtf16(self.read(name) orelse return null);
    }

    /// a non-volatile string variable: the attributes and the data in one write, as efivarfs takes it
    pub fn writeString(self: Vars, name: []const u8, value: []const u8) vh.Error!void {
        const p = self.path(name);
        mutable(p);
        const data = utf16(value);
        const buf = vh.gpa.alloc(u8, 4 + data.len) catch vh.oom();
        mem.writeInt(u32, buf[0..4], attr_nv, .little);
        @memcpy(buf[4..], data);
        const fd = try vh.openFd(p, .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o644);
        defer vh.close(fd);
        const w = try vh.sysRetry(linux.write, .{ fd, buf.ptr, buf.len });
        if (w != buf.len) {
            vh.errno = .IO;
            return error.Sys;
        }
    }

    pub fn delete(self: Vars, name: []const u8) vh.Error!void {
        const p = self.path(name);
        if (!vh.pathExists(p)) return;
        mutable(p);
        vh.unlink(p) catch if (vh.errno != .NOENT) return error.Sys;
    }
};

fn mutable(p: []const u8) void {
    const fd = vh.openFd(p, .{ .ACCMODE = .RDONLY }, 0) catch return;
    defer vh.close(fd);
    // the kernel reads and writes an int behind the long of the ioctl's number
    var flags: u64 = 0;
    if (linux.errno(linux.ioctl(fd, FS_IOC_GETFLAGS, @intFromPtr(&flags))) != .SUCCESS) return;
    if (flags & FS_IMMUTABLE_FL == 0) return;
    flags &= ~FS_IMMUTABLE_FL;
    _ = linux.ioctl(fd, FS_IOC_SETFLAGS, @intFromPtr(&flags));
}

// ---------------------------------------------------------------- one boot

/// what vh-kconf check said of this boot (/run/vh/check.done)
pub const Verdict = union(enum) {
    /// no summary: vh-check did not run, or not yet
    none,
    good,
    bad: []const u8,
};

/// "VH_CHECK machine=same|different devices=N firmware=N lost=N": good with the same machine
/// and no device that lost its driver. The firmware count does not decide (iwlwifi logs a
/// failed load for every newer API it tries first), nor do new devices without a driver; a
/// summary without lost= (an older vh-kconf) is read by devices=.
pub fn verdict(line: []const u8) Verdict {
    const l = vh.strip(line);
    if (!vh.startsWith(l, "VH_CHECK ")) return .none;
    var machine: []const u8 = "";
    var devices: ?u64 = null;
    var lost: ?u64 = null;
    var it = mem.tokenizeScalar(u8, l["VH_CHECK ".len..], ' ');
    while (it.next()) |kv| {
        const eq = mem.indexOfScalar(u8, kv, '=') orelse continue;
        const k = kv[0..eq];
        const v = kv[eq + 1 ..];
        if (vh.eql(k, "machine")) machine = v;
        if (vh.eql(k, "devices")) devices = std.fmt.parseInt(u64, v, 10) catch null;
        if (vh.eql(k, "lost")) lost = std.fmt.parseInt(u64, v, 10) catch null;
    }
    if (machine.len == 0 or (lost == null and devices == null)) return .none;
    if (!vh.eql(machine, "same")) return .{ .bad = "vh-kconf check found another machine than the one of /etc/vh/hw.zon" };
    const n = lost orelse devices.?;
    if (n > 0) return .{ .bad = vh.fmt("vh-kconf check found {d} device(s) without the driver they had at installation (/run/vh/check)", .{n}) };
    return .good;
}

/// What one boot looked like, from the late-boot service (or what the boot loader of this boot
/// says, for the runs of vh-limine-update in between).
pub const Facts = struct {
    /// /proc/sys/kernel/random/boot_id
    id: []const u8 = "",
    /// LoaderInfo: a boot loader with the Boot Loader Interface started this boot ("" = none)
    loader: []const u8 = "",
    /// LoaderFeatures
    features: u64 = 0,
    /// LoaderEntrySelected
    selected: ?[]const u8 = null,
    /// LoaderEntries; null when the loader publishes none (Limine before 12.7)
    entries: ?[]const []const u8 = null,
    /// LoaderEntryOneShot as it is now
    oneshot: ?[]const u8 = null,
    /// LoaderEntryDefault as it is now
    default: ?[]const u8 = null,
    verdict: Verdict = .none,

    /// the loader takes a one-shot entry by the identifiers this module computes (Limine 12.7 and later)
    pub fn oneshotWorks(f: Facts) bool {
        return f.loader.len > 0 and f.features & feature_oneshot != 0 and f.entries != null;
    }

    pub fn lists(f: Facts, id: []const u8) bool {
        for (f.entries orelse return false) |e| if (vh.eql(e, id)) return true;
        return false;
    }

    /// this boot started the entry of the machine UKI: its identifier, or its path (the
    /// entry's name) as Limine before 12.7 reported it
    pub fn started(f: Facts, uki: []const u8) bool {
        const s = f.selected orelse return false;
        return vh.eql(s, ukiId(uki)) or vh.eql(s, entryName(verOf(uki)));
    }
};

pub fn readFacts(v: Vars, boot_id_path: []const u8) Facts {
    var f: Facts = .{ .id = vh.rd(boot_id_path) };
    f.loader = v.string("LoaderInfo") orelse "";
    if (v.read("LoaderFeatures")) |d| {
        if (d.len >= 8) f.features = mem.readInt(u64, d[0..8], .little);
    }
    f.selected = v.string("LoaderEntrySelected");
    if (v.read("LoaderEntries")) |d| f.entries = utf16List(d);
    f.oneshot = v.string("LoaderEntryOneShot");
    f.default = v.string("LoaderEntryDefault");
    return f;
}

// ---------------------------------------------------------------- the state

pub const Status = enum { trying, failed };

/// /var/lib/vh/boot-assess
pub const State = struct {
    /// the machine UKI that is Limine's default ("" = the newest stock UKI) and its BLAKE2B
    default: []const u8 = "",
    default_hash: []const u8 = "",
    /// the machine UKI on trial ("" = none) and its BLAKE2B
    trial: []const u8 = "",
    trial_hash: []const u8 = "",
    status: Status = .trying,
    /// good boots in a row
    good: u32 = 0,
    /// the boot that set the one-shot entry ("" = not set)
    armed: []const u8 = "",
    /// the last boot judged
    last: []const u8 = "",
    /// why the trial failed, or why it waits
    reason: []const u8 = "",

    pub fn empty(st: State) bool {
        return st.default.len == 0 and st.trial.len == 0;
    }
};

/// one line of printable ASCII: what the state file and the admin's message may hold
fn oneLine(s: []const u8) []const u8 {
    const out = vh.dupe(s);
    for (out) |*c| if (c.* < 0x20 or c.* > 0x7e) {
        c.* = '?';
    };
    return out;
}

pub fn parseState(text: []const u8) State {
    var st: State = .{};
    var lines = mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = vh.strip(raw);
        if (line.len == 0 or line[0] == '#') continue;
        const eq = mem.indexOfScalar(u8, line, '=') orelse continue;
        const k = line[0..eq];
        const v = vh.dupe(line[eq + 1 ..]);
        if (vh.eql(k, "DEFAULT")) st.default = v;
        if (vh.eql(k, "DEFAULT_HASH")) st.default_hash = v;
        if (vh.eql(k, "TRIAL")) st.trial = v;
        if (vh.eql(k, "TRIAL_HASH")) st.trial_hash = v;
        if (vh.eql(k, "TRIAL_STATE")) st.status = if (vh.eql(v, "failed")) .failed else .trying;
        if (vh.eql(k, "TRIAL_GOOD")) st.good = std.fmt.parseInt(u32, v, 10) catch 0;
        if (vh.eql(k, "TRIAL_ARMED")) st.armed = v;
        if (vh.eql(k, "TRIAL_LAST")) st.last = v;
        if (vh.eql(k, "TRIAL_REASON")) st.reason = v;
    }
    return st;
}

pub fn renderState(st: State) []const u8 {
    return vh.fmt(
        \\# vh-limine-update: the boot assessment of the machine UKIs (docs/uni/kernel.md); written by the tool
        \\DEFAULT={s}
        \\DEFAULT_HASH={s}
        \\TRIAL={s}
        \\TRIAL_HASH={s}
        \\TRIAL_STATE={s}
        \\TRIAL_GOOD={d}
        \\TRIAL_ARMED={s}
        \\TRIAL_LAST={s}
        \\TRIAL_REASON={s}
        \\
    , .{ oneLine(st.default), oneLine(st.default_hash), oneLine(st.trial), oneLine(st.trial_hash), @tagName(st.status), st.good, oneLine(st.armed), oneLine(st.last), oneLine(st.reason) });
}

// ---------------------------------------------------------------- the decisions

/// What a decision asks of the variables and the system, and what it says.
pub const Action = struct {
    state: State,
    /// LoaderEntryOneShot := the identifier of the trial
    arm: bool = false,
    /// delete LoaderEntryOneShot, which names this identifier
    disarm: ?[]const u8 = null,
    /// LoaderEntryDefault := this identifier
    set_default: ?[]const u8 = null,
    /// delete LoaderEntryDefault
    clear_default: bool = false,
    /// optional/tpm2-totp: the code was sealed on a boot path that is no longer the next one
    reseal: bool = false,
    /// what changed, one line each, for the service's log and the admin's login
    events: []const []const u8 = &.{},
};

fn clearTrial(st: *State) void {
    st.trial = "";
    st.trial_hash = "";
    st.status = .trying;
    st.good = 0;
    st.armed = "";
    st.reason = "";
}

const Out = struct {
    a: Action,
    ev: vh.Strv = .{},

    fn fail(o: *Out, why: []const u8) void {
        o.a.state.status = .failed;
        o.a.state.reason = why;
        o.a.state.armed = "";
        o.ev.add(vh.fmt("the machine kernel {s} failed its trial: {s}", .{ verOf(o.a.state.trial), why }));
    }

    fn done(o: *Out) Action {
        o.a.events = o.ev.slice();
        return o.a;
    }
};

/// The late-boot service (vh-limine-update --booted): this boot against the state; `boots` is
/// MACHINE_BOOTS. See the table of docs/uni/kernel.md, "The state machine".
pub fn booted(st0: State, f: Facts, boots: u32) Action {
    var o: Out = .{ .a = .{ .state = st0 } };
    const st = &o.a.state;
    if (st.last.len > 0 and vh.eql(st.last, f.id)) return o.done();
    st.last = f.id;
    var promoted = false;
    if (st.trial.len > 0 and st.status == .trying) promoted = trial(&o, f, boots);

    // the default machine UKI: LoaderEntryDefault belongs to the tool
    if (st.default.len > 0) {
        const id = ukiId(st.default);
        if (!promoted and f.loader.len > 0 and f.entries != null and (f.default == null or !vh.eql(f.default.?, id))) {
            o.a.set_default = id;
            o.ev.add(vh.fmt("LoaderEntryDefault named {s} instead of the default machine kernel {s}: set back", .{ f.default orelse "nothing", verOf(st.default) }));
        }
        if (f.started(st.default)) {
            switch (f.verdict) {
                .bad => |why| o.ev.add(vh.fmt("the default machine kernel {s} booted, but {s}: doas vh-limine-update --demote makes the stock UKI the default again", .{ verOf(st.default), why })),
                else => {},
            }
        } else if (!promoted and f.loader.len > 0 and !(st.trial.len > 0 and f.started(st.trial)) and
            !(f.selected != null and isGameEntry(f.selected.?)))
        {
            // the gaming boot is chosen on purpose (vh-game play), not a fallback
            o.ev.add(vh.fmt("this boot is {s}, not the default machine kernel {s}: if {s} failed, doas vh-limine-update --demote makes the stock UKI the default again", .{ f.selected orelse "another entry", verOf(st.default), verOf(st.default) }));
        }
    } else if (f.default != null) {
        // no machine UKI has passed: a default entry in NVRAM would override the stock one
        o.a.clear_default = true;
        o.ev.add(vh.fmt("LoaderEntryDefault named {s} while no machine kernel has passed: deleted, the stock UKI is the default", .{f.default.?}));
    }
    return o.done();
}

/// the trial in this boot; true when it became the default
fn trial(o: *Out, f: Facts, boots: u32) bool {
    const st = &o.a.state;
    const id = ukiId(st.trial);
    const ver = verOf(st.trial);
    const armed_now = st.armed.len > 0 and vh.eql(st.armed, f.id);
    if (f.started(st.trial)) {
        // this boot started the trial's entry: the one-shot entry, or the menu
        if (st.armed.len > 0 and !armed_now and f.loader.len > 0 and f.oneshot != null and vh.eql(f.oneshot.?, id)) {
            o.fail("Limine started the trial but left LoaderEntryOneShot in place: with this boot loader a trial that hangs would be booted again");
            o.a.disarm = id;
            return false;
        }
        switch (f.verdict) {
            .good => {
                st.good += 1;
                st.reason = "";
                if (st.good >= boots) {
                    o.a.set_default = id;
                    o.ev.add(vh.fmt("the machine kernel {s} booted well {d} times in a row: it is Limine's default now", .{ ver, st.good }));
                    st.default = st.trial;
                    st.default_hash = st.trial_hash;
                    clearTrial(st);
                    return true;
                }
                o.a.arm = true;
                st.armed = f.id;
                o.ev.add(vh.fmt("the machine kernel {s} on trial: {d} of {d} good boots; the next boot tries it again", .{ ver, st.good, boots }));
            },
            .bad => |why| {
                o.fail(vh.fmt("it booted, but {s}", .{why}));
                o.a.reseal = true;
            },
            .none => {
                o.fail("it booted, but vh-kconf check gave no verdict (the vh-check service)");
                o.a.reseal = true;
            },
        }
        return false;
    }
    // set during this very boot (vh-limine-update --new before the service): the next boot is the trial
    if (armed_now) return false;
    if (st.armed.len > 0) {
        // set in an earlier boot, and this boot started another entry
        if (f.oneshot != null and vh.eql(f.oneshot.?, id)) {
            if (f.loader.len > 0) {
                o.fail("Limine ran but left LoaderEntryOneShot in place: with this boot loader a trial is not safe");
                o.a.disarm = id;
            }
            // else no Limine this boot: the trial waits for one
            return false;
        }
        if (f.loader.len > 0 and f.entries != null and !f.lists(id)) {
            o.fail(vh.fmt("Limine does not list the entry {s}, so the trial was not attempted", .{id}));
            return false;
        }
        o.fail(vh.fmt("the trial boot did not reach the end of the boot (it failed, was interrupted, or another entry was chosen in the menu); this boot is {s}", .{f.selected orelse "not one of Limine's"}));
        o.a.reseal = true;
        return false;
    }
    // not set yet: the boot loader of the install's boot could not take one-shot entries
    if (f.oneshotWorks() and f.lists(id)) {
        o.a.arm = true;
        st.armed = f.id;
        st.reason = "";
        o.ev.add(vh.fmt("the machine kernel {s} on trial: the next boot tries it ({d} of {d} good boots)", .{ ver, st.good, boots }));
    } else if (f.loader.len == 0) {
        st.reason = "no Limine in this boot: the trial waits for a boot through Limine";
    } else if (!f.oneshotWorks()) {
        st.reason = vh.fmt("{s} takes no one-shot entry by identifier (Limine 12.7 or later): boot the entry from the menu {d} times", .{ f.loader, boots });
        o.ev.add(vh.fmt("the machine kernel {s} on trial: {s}", .{ ver, st.reason }));
    } else {
        st.reason = vh.fmt("Limine does not list the entry {s} yet", .{id});
        o.ev.add(vh.fmt("the machine kernel {s} on trial: {s}", .{ ver, st.reason }));
    }
    return false;
}

/// --new of a machine UKI, or --retry NAME: the UKI is on trial, from no good boot. The
/// default machine UKI installed again (the same file) stays the default, and the trial
/// installed again goes on where it was.
pub fn install(st0: State, uki: []const u8, hash: []const u8) State {
    var st = st0;
    if (vh.eql(st.default, uki) and vh.eql(st.default_hash, hash)) return st;
    if (vh.eql(st.trial, uki) and vh.eql(st.trial_hash, hash) and st.status == .trying) return st;
    clearTrial(&st);
    st.trial = uki;
    st.trial_hash = hash;
    return st;
}

/// --retry: the trial again, from no good boot; null without one
pub fn retry(st0: State) ?State {
    if (st0.trial.len == 0) return null;
    return install(st0, st0.trial, st0.trial_hash);
}

/// --demote: the stock UKI is the default again; the machine UKI stays in the menu. null when
/// no machine UKI is the default.
pub fn demote(st0: State) ?State {
    if (st0.default.len == 0) return null;
    var st = st0;
    st.default = "";
    st.default_hash = "";
    return st;
}

pub const OnEsp = struct { name: []const u8, hash: []const u8 };

fn hashOf(esp: []const OnEsp, name: []const u8) ?[]const u8 {
    for (esp) |e| if (vh.eql(e.name, name)) return e.hash;
    return null;
}

/// A run that writes limine.conf: the state against the machine UKIs it keeps, with their
/// BLAKE2B. A default or a trial whose UKI is gone is forgotten; one whose BLAKE2B changed is
/// another kernel: a trial starts again, a default stops being one and is tried anew.
pub fn reconcile(st0: State, esp: []const OnEsp) Action {
    var o: Out = .{ .a = .{ .state = st0 } };
    const st = &o.a.state;
    if (st.trial.len > 0) {
        if (hashOf(esp, st.trial)) |h| {
            if (!vh.eql(h, st.trial_hash)) {
                if (st.armed.len > 0) o.a.disarm = ukiId(st.trial);
                o.ev.add(vh.fmt("the machine UKI {s} on trial changed on the ESP: its trial starts again", .{st.trial}));
                st.* = install(st.*, st.trial, h);
            }
        } else {
            if (st.armed.len > 0) o.a.disarm = ukiId(st.trial);
            o.ev.add(vh.fmt("the machine UKI {s} on trial is no longer on the ESP: its trial ends", .{st.trial}));
            clearTrial(st);
        }
    }
    if (st.default.len > 0) {
        if (hashOf(esp, st.default)) |h| {
            if (!vh.eql(h, st.default_hash)) {
                o.a.clear_default = true;
                o.ev.add(vh.fmt("the default machine UKI {s} changed on the ESP: the stock UKI is the default until it has passed its trial again", .{st.default}));
                const name = st.default;
                st.default = "";
                st.default_hash = "";
                if (st.trial.len == 0) st.* = install(st.*, name, h);
            }
        } else {
            o.a.clear_default = true;
            o.ev.add(vh.fmt("the default machine UKI {s} is no longer on the ESP: the stock UKI is the default", .{st.default}));
            st.default = "";
            st.default_hash = "";
        }
    }
    return o.done();
}

/// the summary line of --status, for vh-audit
pub fn summary(st: State, boots: u32) []const u8 {
    return vh.fmt("VH_BOOT_ASSESS default={s} trial={s} state={s} good={d} boots={d} armed={s}\n", .{
        if (st.default.len > 0) st.default else "stock",
        if (st.trial.len > 0) st.trial else "none",
        if (st.trial.len > 0) @tagName(st.status) else "none",
        st.good,
        boots,
        if (st.armed.len > 0) "yes" else "no",
    });
}

// ---------------------------------------------------------------- tests

const t = std.testing;

fn has(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (contains(x, s)) return true;
    return false;
}

fn contains(s: []const u8, part: []const u8) bool {
    return mem.indexOf(u8, s, part) != null;
}

test "entry names and Limine's identifiers" {
    // the example of docs/uni/kernel.md, as Limine 12.9.3 makes it
    try t.expectEqualStrings("Void-Linux-6.18.57-vh_2--machine-kernel-", entryId("Void Linux 6.18.57-vh_2 (machine kernel)"));
    try t.expectEqualStrings("Void-Linux-6.18.57-vh_2--machine-kernel-", ukiId("linux-6.18.57-vh_2.efi"));
    try t.expectEqualStrings("Void-Linux-6.18.57_1", entryId("Void Linux 6.18.57_1"));
    try t.expectEqualStrings("Void-Linux-6.18.56_1--previous-kernel-", entryId("Void Linux 6.18.56_1 (previous kernel)"));
    // the gaming entry (vh-game boot on): the twin's file name is the stock UKI's
    try t.expectEqualStrings("Void-Linux-6.18.58_1--games-", gameId("linux-6.18.58_1.efi"));
    try t.expect(isGameEntry(gameId("linux-6.18.58_1.efi")) and isGameEntry("Void Linux 6.18.58_1 (games)"));
    try t.expect(!isGameEntry("Void-Linux-6.18.58_1") and !isGameEntry(ukiId("linux-6.18.57-vh_2.efi")) and
        !isGameEntry("Void-Linux-6.18.56_1--previous-kernel-"));
    // the escaped characters of a path, kept bytes, the empty and dot names
    try t.expectEqualStrings("a-.b--c--d", entryId("a/b#c\\d"));
    try t.expectEqualStrings("x+y@z.w_v-u", entryId("x+y@z.w_v-u"));
    try t.expectEqualStrings("-", entryId(""));
    try t.expectEqualStrings("..-", entryId(".."));
    // at most 232 bytes
    const long = vh.gpa.alloc(u8, 300) catch vh.oom();
    @memset(long, 'a');
    try t.expectEqual(@as(usize, 232), entryId(long).len);
    try t.expectEqualStrings("6.18.57-vh_2", verOf("linux-6.18.57-vh_2.efi"));
    try t.expectEqualStrings("6.18.57-vh", releaseOf("6.18.57-vh_2"));
    try t.expectEqualStrings("Void Linux 6.18.57-vh_2 (machine kernel)", entryName("6.18.57-vh_2"));
}

test "UTF-16 values, the verdict, the state file" {
    const u = utf16("Ab-1");
    try t.expectEqualSlices(u8, &.{ 'A', 0, 'b', 0, '-', 0, '1', 0, 0, 0 }, u);
    try t.expectEqualStrings("Ab-1", fromUtf16(u).?);
    try t.expectEqualStrings("Ab-1", fromUtf16(u[0 .. u.len - 2]).?); // without the NUL
    // LoaderEntries: several strings, a non-ASCII one dropped
    const list = utf16List(&.{ 'a', 0, 0, 0, 0xe9, 0, 'x', 0, 0, 0, 'b', 0, 'c', 0, 0, 0 });
    try t.expectEqual(@as(usize, 2), list.len);
    try t.expectEqualStrings("a", list[0]);
    try t.expectEqualStrings("bc", list[1]);
    try t.expect(fromUtf16(&.{ 0, 0 }) == null);

    try t.expect(verdict("VH_CHECK machine=same devices=0 firmware=3 lost=0") == .good);
    // a new device without a driver (a phone) is no failure of the kernel; a lost one is
    try t.expect(verdict("VH_CHECK machine=same devices=1 firmware=0 lost=0") == .good);
    try t.expect(verdict("VH_CHECK machine=same devices=2 firmware=0 lost=1") == .bad);
    try t.expect(verdict("VH_CHECK machine=different devices=0 firmware=0 lost=0") == .bad);
    // an older vh-kconf: devices decides
    try t.expect(verdict("VH_CHECK machine=same devices=0 firmware=0") == .good);
    try t.expect(verdict("VH_CHECK machine=same devices=1 firmware=0") == .bad);
    try t.expect(verdict("") == .none);
    try t.expect(verdict("VH_CHECK nonsense") == .none);

    const st: State = .{ .default = "linux-6.18.57-vh_1.efi", .default_hash = "aa", .trial = "linux-6.18.58-vh_1.efi", .trial_hash = "bb", .status = .failed, .good = 2, .armed = "", .last = "id-2", .reason = "it broke\nbadly" };
    const back = parseState(renderState(st));
    try t.expectEqualStrings(st.default, back.default);
    try t.expectEqualStrings(st.trial_hash, back.trial_hash);
    try t.expectEqual(Status.failed, back.status);
    try t.expectEqual(@as(u32, 2), back.good);
    try t.expectEqualStrings("id-2", back.last);
    try t.expectEqualStrings("it broke?badly", back.reason);
    try t.expect(parseState("").empty());
    try t.expectEqualStrings("VH_BOOT_ASSESS default=linux-6.18.57-vh_1.efi trial=linux-6.18.58-vh_1.efi state=failed good=2 boots=3 armed=no\n", summary(st, 3));
}

const trial_uki = "linux-6.18.58-vh_1.efi";
const default_uki = "linux-6.18.57-vh_1.efi";
const stock_id = "Void-Linux-6.18.58_1";

/// a boot through Limine 12.9.3 whose menu has the stock entry, the default and the trial
fn limine(id: []const u8, selected: []const u8, v: Verdict) Facts {
    const entries = vh.gpa.dupe([]const u8, &[_][]const u8{ stock_id, ukiId(default_uki), ukiId(trial_uki) }) catch vh.oom();
    return .{
        .id = id,
        .loader = "Limine 12.9.3",
        .features = 0x200f,
        .selected = selected,
        .entries = entries,
        .verdict = v,
    };
}

test "the trial: armed, good boots, the default after MACHINE_BOOTS" {
    const tid = ukiId(trial_uki);
    var st = install(.{}, trial_uki, "h1");
    try t.expectEqual(Status.trying, st.status);
    try t.expectEqual(@as(u32, 0), st.good);
    // vh-limine-update --new armed it during boot 0; the service of boot 0 judges nothing
    st.armed = "b0";
    var a = booted(st, limine("b0", stock_id, .good), 3);
    try t.expect(!a.arm and a.set_default == null and a.state.good == 0);
    try t.expectEqualStrings("b0", a.state.last);
    // the service ran twice in boot 0: nothing more
    try t.expectEqual(@as(usize, 0), booted(a.state, limine("b0", stock_id, .good), 3).events.len);
    // boot 1: Limine erased the one-shot entry and started the trial; a good verdict
    a = booted(a.state, limine("b1", tid, .good), 3);
    try t.expect(a.arm and a.state.good == 1 and a.set_default == null);
    try t.expectEqualStrings("b1", a.state.armed);
    try t.expect(has(a.events, "1 of 3 good boots"));
    a = booted(a.state, limine("b2", tid, .good), 3);
    try t.expect(a.arm and a.state.good == 2);
    // boot 3: the third good boot makes it the default; no one-shot entry any more
    a = booted(a.state, limine("b3", tid, .good), 3);
    try t.expect(!a.arm);
    try t.expectEqualStrings(tid, a.set_default.?);
    try t.expectEqualStrings(trial_uki, a.state.default);
    try t.expectEqualStrings("h1", a.state.default_hash);
    try t.expectEqualStrings("", a.state.trial);
    try t.expect(has(a.events, "it is Limine's default now"));
    // boot 4: Limine started the default; LoaderEntryDefault names it: nothing to say
    var f4 = limine("b4", tid, .good);
    f4.default = tid;
    a = booted(a.state, f4, 3);
    try t.expect(a.set_default == null and !a.clear_default and a.events.len == 0);
    // MACHINE_BOOTS=1: the first good boot decides
    var one = install(.{}, trial_uki, "h1");
    one.armed = "b0";
    try t.expectEqualStrings(tid, booted(one, limine("b1", tid, .good), 1).set_default.?);
    // a good boot of the trial's entry chosen in the menu, never armed, counts as well
    try t.expectEqual(@as(u32, 1), booted(install(.{}, trial_uki, "h1"), limine("b1", tid, .good), 3).state.good);
    // Limine before 12.7 reports the entry's path
    var old = limine("b1", entryName(verOf(trial_uki)), .good);
    old.entries = null;
    try t.expectEqual(@as(u32, 1), booted(install(.{}, trial_uki, "h1"), old, 3).state.good);
}

test "the trial: every way it fails" {
    const tid = ukiId(trial_uki);
    var armed = install(.{ .default = default_uki, .default_hash = "hd" }, trial_uki, "h1");
    armed.armed = "b0";
    // the trial's boot, with a lost driver or no verdict
    var a = booted(armed, limine("b1", tid, .{ .bad = "vh-kconf check found 1 device(s) without the driver" }), 3);
    try t.expectEqual(Status.failed, a.state.status);
    try t.expect(!a.arm and a.reseal and a.state.armed.len == 0);
    try t.expect(has(a.events, "failed its trial: it booted, but vh-kconf check found 1 device"));
    a = booted(armed, limine("b1", tid, .none), 3);
    try t.expect(a.state.status == .failed and has(a.events, "gave no verdict"));
    // Limine consumed the one-shot entry, the trial never reached the service, this is the default
    a = booted(armed, limine("b2", ukiId(default_uki), .good), 3);
    try t.expect(a.state.status == .failed and a.reseal);
    try t.expect(has(a.events, "did not reach the end of the boot"));
    try t.expect(contains(a.state.reason, "this boot is Void-Linux-6.18.57-vh_1--machine-kernel-"));
    // the same, after a good boot: the count does not survive a failure
    var two = armed;
    two.good = 2;
    try t.expectEqual(Status.failed, booted(two, limine("b3", stock_id, .good), 3).state.status);
    // Limine did not know the identifier: not the kernel's fault, but the trial stops
    var unknown = limine("b2", stock_id, .good);
    unknown.entries = &.{stock_id};
    a = booted(armed, unknown, 3);
    try t.expect(a.state.status == .failed and !a.reseal and contains(a.state.reason, "not attempted"));
    // a Limine that left the variable after a boot
    var left = limine("b2", stock_id, .good);
    left.oneshot = tid;
    a = booted(armed, left, 3);
    try t.expect(a.state.status == .failed);
    try t.expectEqualStrings(tid, a.disarm.?);
    var left2 = limine("b2", tid, .good);
    left2.oneshot = tid;
    a = booted(armed, left2, 3);
    try t.expect(a.state.status == .failed and contains(a.state.reason, "left LoaderEntryOneShot"));
    // no Limine this boot (another boot path): the trial waits, still armed
    a = booted(armed, .{ .id = "b2", .oneshot = tid, .verdict = .good }, 3);
    try t.expect(a.state.status == .trying);
    try t.expectEqualStrings("b0", a.state.armed);
    // a failed trial is not tried again by itself
    var failed = armed;
    failed.status = .failed;
    failed.armed = "";
    a = booted(failed, limine("b9", stock_id, .good), 3);
    try t.expect(!a.arm and a.state.status == .failed);
    // --retry: from no good boot, then armed by the next service
    const r = retry(failed).?;
    try t.expect(r.status == .trying and r.good == 0 and r.reason.len == 0);
    a = booted(r, limine("b10", stock_id, .good), 3);
    try t.expect(a.arm);
    try t.expectEqualStrings("b10", a.state.armed);
    try t.expect(retry(.{}) == null);
}

test "arming when the install's boot loader could not, and the default entry's upkeep" {
    const tid = ukiId(trial_uki);
    const did = ukiId(default_uki);
    const fresh = install(.{}, trial_uki, "h1");
    // a boot loader without one-shot entries, or without identifiers: the reason, no arming
    var no_bli = limine("b1", stock_id, .good);
    no_bli.features = 0;
    var a = booted(fresh, no_bli, 3);
    try t.expect(!a.arm and contains(a.state.reason, "takes no one-shot entry"));
    var no_ids = limine("b1", stock_id, .good);
    no_ids.entries = null;
    try t.expect(!booted(fresh, no_ids, 3).arm);
    a = booted(fresh, .{ .id = "b1" }, 3);
    try t.expect(!a.arm and contains(a.state.reason, "no Limine"));
    // a Limine 12.9.3 that lists the entry: armed now
    a = booted(fresh, limine("b1", stock_id, .good), 3);
    try t.expect(a.arm and a.state.status == .trying);

    // the default: LoaderEntryDefault is set back when it names something else or nothing
    const dflt: State = .{ .default = default_uki, .default_hash = "hd" };
    var f = limine("b5", did, .good);
    a = booted(dflt, f, 3);
    try t.expectEqualStrings(did, a.set_default.?);
    f.default = stock_id;
    try t.expectEqualStrings(did, booted(dflt, f, 3).set_default.?);
    // the default booted with a lost driver, or another entry booted: told, not acted on
    var bad = limine("b6", did, .{ .bad = "a lost driver" });
    bad.default = did;
    a = booted(dflt, bad, 3);
    try t.expect(a.set_default == null and !a.clear_default and has(a.events, "--demote"));
    var other = limine("b7", stock_id, .good);
    other.default = did;
    a = booted(dflt, other, 3);
    try t.expect(a.set_default == null and has(a.events, "not the default machine kernel"));
    // the gaming entry (vh-game play) is no fallback: nothing told, nothing acted on
    var game = limine("b7g", gameId("linux-6.18.58_1.efi"), .good);
    game.default = did;
    a = booted(dflt, game, 3);
    try t.expect(a.set_default == null and !a.clear_default and a.events.len == 0);
    // a default entry while no machine kernel has passed: deleted
    var stray = limine("b8", stock_id, .good);
    stray.default = tid;
    try t.expect(booted(fresh, stray, 3).clear_default);
    try t.expect(demote(dflt).?.default.len == 0 and demote(.{}) == null);
}

test "reconcile: the ESP against the state" {
    const st: State = .{ .default = default_uki, .default_hash = "hd", .trial = trial_uki, .trial_hash = "h1", .good = 1, .armed = "b1" };
    // both there, unchanged: nothing
    var a = reconcile(st, &.{ .{ .name = default_uki, .hash = "hd" }, .{ .name = trial_uki, .hash = "h1" } });
    try t.expect(a.events.len == 0 and !a.clear_default and a.disarm == null);
    // the trial rebuilt in place: its trial starts again
    a = reconcile(st, &.{ .{ .name = default_uki, .hash = "hd" }, .{ .name = trial_uki, .hash = "h2" } });
    try t.expect(a.state.good == 0 and a.state.armed.len == 0);
    try t.expectEqualStrings("h2", a.state.trial_hash);
    try t.expectEqualStrings(ukiId(trial_uki), a.disarm.?);
    // the trial gone, the default changed: the stock UKI is the default, the changed one waits
    a = reconcile(st, &.{.{ .name = default_uki, .hash = "hx" }});
    try t.expect(a.clear_default);
    try t.expectEqualStrings("", a.state.default);
    try t.expectEqualStrings(default_uki, a.state.trial);
    try t.expectEqualStrings("hx", a.state.trial_hash);
    // both gone
    a = reconcile(st, &.{});
    try t.expect(a.clear_default and a.state.empty());
    // the default installed again, the same file: it stays the default
    const again = install(.{ .default = default_uki, .default_hash = "hd" }, default_uki, "hd");
    try t.expectEqualStrings(default_uki, again.default);
    try t.expectEqualStrings("", again.trial);
    // the trial installed again goes on; a failed one starts anew
    const going: State = .{ .trial = trial_uki, .trial_hash = "h1", .good = 2, .armed = "b5" };
    try t.expectEqual(@as(u32, 2), install(going, trial_uki, "h1").good);
    var failed = going;
    failed.status = .failed;
    try t.expectEqual(@as(u32, 0), install(failed, trial_uki, "h1").good);
}

test "the variables through a directory like efivarfs" {
    const dir = vh.fmt("/tmp/vh-assess-test-{d}", .{linux.getpid()});
    _ = vh.runOpts(&.{ "rm", "-rf", dir }, .{});
    vh.mkdirs(dir, 0o755);
    const v: Vars = .{ .dir = dir };
    try t.expect(v.string("LoaderEntryOneShot") == null);
    try v.writeString("LoaderEntryOneShot", "Void-Linux-6.18.58-vh_1--machine-kernel-");
    const raw = vh.readFile(v.path("LoaderEntryOneShot")) catch return error.TestUnexpectedResult;
    try t.expectEqualSlices(u8, &.{ 7, 0, 0, 0, 'V', 0 }, raw[0..6]);
    try t.expectEqualStrings("Void-Linux-6.18.58-vh_1--machine-kernel-", v.string("LoaderEntryOneShot").?);
    try v.delete("LoaderEntryOneShot");
    try v.delete("LoaderEntryOneShot");
    try t.expect(v.read("LoaderEntryOneShot") == null);
    // what Limine publishes: LoaderInfo, LoaderFeatures, LoaderEntries
    vh.writeAtomic(v.path("LoaderInfo"), vh.fmt("\x06\x00\x00\x00{s}", .{utf16("Limine 12.9.3")}), 0o644);
    vh.writeAtomic(v.path("LoaderFeatures"), "\x06\x00\x00\x00\x0f\x20\x00\x00\x00\x00\x00\x00", 0o644);
    vh.writeAtomic(v.path("LoaderEntries"), vh.fmt("\x06\x00\x00\x00{s}{s}", .{ utf16("Void-Linux-6.18.58_1"), utf16("Void-Linux-6.18.58-vh_1--machine-kernel-") }), 0o644);
    vh.writeAtomic(vh.fmt("{s}/boot_id", .{dir}), "b-1\n", 0o644);
    const f = readFacts(v, vh.fmt("{s}/boot_id", .{dir}));
    try t.expectEqualStrings("b-1", f.id);
    try t.expectEqualStrings("Limine 12.9.3", f.loader);
    try t.expect(f.oneshotWorks() and f.lists("Void-Linux-6.18.58_1") and f.selected == null);
    _ = vh.runOpts(&.{ "rm", "-rf", dir }, .{});
}
