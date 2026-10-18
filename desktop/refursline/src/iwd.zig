// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Клиент iwd по D-Bus — единственный Wi‑Fi-бэкенд RefursLine (как в void-hardened):
//! список сетей, подключение (открытые, WPA/WPA2/WPA3 Personal, скрытые), отключение, «забыть»,
//! радио вкл/выкл. Без NetworkManager — меньше кода и зависимостей.
//!
//! Пароли: во время Network.Connect iwd спрашивает наш агент (net.connman.iwd.Agent.RequestPassphrase).
//! Агент отвечает только уникальному имени самого iwd, а пароль стирается сразу после ответа.
//! iwd сохраняет сеть сам («известная сеть»), как только подключение удалось.
//! 802.1X: настройки предприятия iwd берёт только из /var/lib/iwd/<SSID>.8021x, который пишет root —
//! меню так и говорит, а не пытается.

const std = @import("std");
const sys = @import("sys.zig");
const dbus = @import("dbus.zig");

pub const NAME = "net.connman.iwd";
const OM = "org.freedesktop.DBus.ObjectManager";
const PROPS = "org.freedesktop.DBus.Properties";
const STATION = "net.connman.iwd.Station";
const DEVICE = "net.connman.iwd.Device";
const NETWORK = "net.connman.iwd.Network";
const KNOWN = "net.connman.iwd.KnownNetwork";
const ADAPTER = "net.connman.iwd.Adapter";
const AGENT_MGR = "net.connman.iwd.AgentManager";
const AGENT = "net.connman.iwd.Agent";
const AGENT_PATH = "/org/refursline/wifi";

pub const Security = enum(u8) { open, wep, psk, sae, owe, eap };

pub const Path = struct {
    buf: [128]u8 = undefined,
    len: u8 = 0,

    pub fn set(p: *Path, v: []const u8) void {
        const k = @min(v.len, p.buf.len);
        std.mem.copyForwards(u8, p.buf[0..k], v[0..k]); // источник может быть этим же буфером
        p.len = @intCast(k);
    }
    pub fn get(p: *const Path) []const u8 {
        return p.buf[0..p.len];
    }
};

pub const Net = struct {
    ssid_buf: [32]u8 = undefined,
    ssid_len: u8 = 0,
    ap: Path = .{},
    conn: Path = .{}, // KnownNetwork, если сеть сохранена
    strength: u8 = 0,
    sec: Security = .open,
    active: bool = false,
    known: bool = false,

    pub fn ssid(n: *const Net) []const u8 {
        return n.ssid_buf[0..n.ssid_len];
    }
};

/// Что нужно новому подключению.
pub const Spec = struct {
    ssid: []const u8,
    hidden: bool = false,
    sec: Security,
    psk: []const u8 = "",
};

pub const Progress = enum { working, done, failed };

pub var bus: dbus.Conn = .{};
pub var wifi_enabled: bool = true;
/// Список сетей изменился (новые/пропавшие, скан закончен) — стоит перечитать.
pub var nets_changed = false;
/// Устройство сменило состояние — стоит проверить ход подключения.
pub var state_changed = false;
/// Объект сети, к которой идёт подключение.
pub var activating: Path = .{};

var err_buf: [200]u8 = undefined;
var err_len: usize = 0;

pub fn lastError() []const u8 {
    return err_buf[0..err_len];
}

pub fn setError(msg: []const u8) void {
    err_len = @min(msg.len, err_buf.len);
    @memcpy(err_buf[0..err_len], msg[0..err_len]);
}

/// Системная шина, владелец имени iwd (сигналы и вызовы агента — только от него), устройство.
pub fn init() bool {
    bus.connectSystem() catch {
        setError("no access to the D-Bus system bus");
        return false;
    };
    var b: [64]u8 = undefined;
    var w = dbus.W{ .buf = &b };
    w.str(NAME);
    const r = bus.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner", "s", w.bytes()) catch {
        setError("error talking to the D-Bus system bus");
        return false;
    };
    if (!r.ok()) {
        setError("iwd is not running (sudo sv up iwd)");
        return false;
    }
    var rr = r.reader();
    const owner = rr.str();
    if (rr.bad or owner.len == 0) {
        setError("iwd is not running");
        return false;
    }
    return initOwner(owner);
}

/// Объект устройства: интерфейс Device и, пока оно включено, Station (тот же путь).
var station: Path = .{};
/// Его адаптер: Adapter.Powered — это мягкая блокировка rfkill.
var adapter: Path = .{};
var body_buf: [4 * 1024]u8 = undefined;
var connect_serial: u32 = 0;
/// Пароль для идущего подключения: отдаётся iwd один раз, по его запросу.
var pending: [64]u8 = undefined;
var pending_len: usize = 0;
var have_pending = false;


fn call(path: []const u8, iface: []const u8, member: []const u8, sig: []const u8, body: []const u8) ?dbus.Reply {
    const r = bus.call(NAME, path, iface, member, sig, body) catch |e| {
        setError(switch (e) {
            error.Timeout => "iwd is not responding",
            else => "error talking to iwd",
        });
        return null;
    };
    if (!r.ok()) {
        setError(r.message());
        return null;
    }
    return r;
}

// ================================================================= инициализация

const Scan = struct { found: bool = false, powered: ?bool = null };

/// owner — уникальное имя iwd на шине (из GetNameOwner): сигналы и вызовы агента принимаются только от него.
fn initOwner(owner: []const u8) bool {
    bus.setPeer(owner);
    var sc = Scan{};
    {
        var serials = [1]u32{bus.sendCall(NAME, "/", OM, "GetManagedObjects", "", "") catch 0};
        bus.collect(&serials, &sc, gotObjects) catch {};
    }
    if (!sc.found) {
        setError("Wi‑Fi adapter not found (iwd)");
        return false;
    }
    if (sc.powered) |p| wifi_enabled = p;
    addMatch("type='signal',sender='" ++ NAME ++ "'");
    bus.on_signal = onSignal;
    bus.on_method = onMethod;
    var w = dbus.W{ .buf = &body_buf };
    w.str(AGENT_PATH);
    _ = call("/net/connman/iwd", AGENT_MGR, "RegisterAgent", "o", w.bytes()) orelse return false;
    return true;
}

/// Первое устройство в режиме station — с ним и работает меню. Ищется по интерфейсу Device:
/// у выключенного устройства нет интерфейса Station, а меню всё равно должно уметь его включить.
fn gotObjects(sc: *Scan, _: usize, rep: dbus.Reply) void {
    if (!rep.ok()) return;
    const eql = std.mem.eql;
    var r = rep.reader();
    const end = r.arrayEnd(8);
    while (r.p < end and !r.bad and !sc.found) {
        r.alignTo(8);
        const path = r.str();
        var is_dev = false;
        var is_station = true; // Mode: "station" (по умолчанию), "ap" или "ad-hoc"
        var powered: ?bool = null;
        var adp: []const u8 = "";
        const iend = r.arrayEnd(8);
        while (r.p < iend and !r.bad) {
            r.alignTo(8);
            const iface = r.str();
            const dev = eql(u8, iface, DEVICE);
            if (dev) is_dev = true;
            const pend = r.arrayEnd(8);
            while (r.p < pend and !r.bad) {
                r.alignTo(8);
                const key = r.str();
                const vs = r.sig();
                if (dev and eql(u8, key, "Powered") and eql(u8, vs, "b")) {
                    powered = r.boolean();
                } else if (dev and eql(u8, key, "Mode") and eql(u8, vs, "s")) {
                    is_station = eql(u8, r.str(), "station");
                } else if (dev and eql(u8, key, "Adapter") and eql(u8, vs, "o")) {
                    adp = r.str();
                } else r.skip(vs);
            }
            r.p = @max(r.p, pend);
        }
        r.p = @max(r.p, iend);
        if (is_dev and is_station and !r.bad) {
            station.set(path);
            adapter.set(adp);
            sc.found = true;
            sc.powered = powered;
        }
    }
}

fn addMatch(rule: []const u8) void {
    var w = dbus.W{ .buf = &body_buf };
    w.str(rule);
    bus.callNoReply("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "AddMatch", "s", w.bytes());
}

fn onSignal(path: []const u8, iface: []const u8, member: []const u8, sig: []const u8, body: []const u8) void {
    const eql = std.mem.eql;
    if (eql(u8, iface, OM)) {
        // сеть появилась или пропала после скана
        if (eql(u8, member, "InterfacesAdded") or eql(u8, member, "InterfacesRemoved")) nets_changed = true;
        return;
    }
    if (!eql(u8, member, "PropertiesChanged") or !eql(u8, sig, "sa{sv}as")) return;
    var r = dbus.R{ .d = body };
    const which = r.str();
    if (eql(u8, which, NETWORK)) {
        nets_changed = true; // сменился Connected
        return;
    }
    if (!eql(u8, path, station.get())) return;
    const end = r.arrayEnd(8);
    while (r.p < end and !r.bad) {
        r.alignTo(8);
        const key = r.str();
        const vs = r.sig();
        if (eql(u8, which, DEVICE) and eql(u8, key, "Powered") and eql(u8, vs, "b")) {
            const on = r.boolean();
            if (!r.bad and on != wifi_enabled) {
                wifi_enabled = on;
                nets_changed = true;
            }
        } else if (eql(u8, which, STATION) and eql(u8, key, "State")) {
            state_changed = true;
            nets_changed = true;
            r.skip(vs);
        } else if (eql(u8, which, STATION) and eql(u8, key, "Scanning") and eql(u8, vs, "b")) {
            if (!r.boolean()) nets_changed = true; // скан закончен: свежий список
        } else r.skip(vs);
    }
}

// ================================================================= агент

fn onMethod(c: *dbus.Conn, m: *const dbus.Incoming) void {
    const eql = std.mem.eql;
    if (!eql(u8, m.path, AGENT_PATH) or !eql(u8, m.iface, AGENT)) {
        return c.replyError(m, "org.freedesktop.DBus.Error.UnknownObject", "no such object");
    }
    // пароль может спросить только сам iwd — не другой процесс на шине
    if (!eql(u8, m.sender, c.peer())) {
        return c.replyError(m, "org.freedesktop.DBus.Error.AccessDenied", "access denied");
    }
    if (eql(u8, m.member, "Release") or eql(u8, m.member, "Cancel")) {
        wipePending();
        return c.reply(m, "", "");
    }
    if (eql(u8, m.member, "RequestPassphrase") and have_pending) {
        var b: [128]u8 = undefined;
        var w = dbus.W{ .buf = &b };
        w.str(pending[0..pending_len]);
        c.reply(m, "s", w.bytes());
        sys.secureZero(&b);
        sys.secureZero(c.out);
        wipePending();
        return;
    }
    // пароля нет (сохранённый перестал подходить или 802.1X) — меню спросит пользователя снова
    c.replyError(m, "net.connman.iwd.Agent.Error.Canceled", "canceled");
}

fn wipePending() void {
    sys.secureZero(&pending);
    pending_len = 0;
    have_pending = false;
}

// ================================================================= радио и поиск

pub fn setEnabled(on: bool) bool {
    if (!setPowered(station.get(), DEVICE, on)) {
        // выключен сам адаптер (мягкая блокировка rfkill, например клавиша «в самолёте»): Adapter.Powered снимает её,
        // затем устройство поднимается за мгновение
        if (!on or adapter.len == 0 or !setPowered(adapter.get(), ADAPTER, true)) return false;
        var attempt: u32 = 0;
        while (!setPowered(station.get(), DEVICE, true)) : (attempt += 1) {
            if (attempt == 20) return false;
            var none = [0]sys.PollFd{};
            _ = sys.poll(&none, 50) catch {};
        }
    }
    wifi_enabled = on;
    return true;
}

fn setPowered(path: []const u8, iface: []const u8, on: bool) bool {
    var w = dbus.W{ .buf = &body_buf };
    w.str(iface);
    w.str("Powered");
    w.sig("b");
    w.boolean(on);
    _ = call(path, PROPS, "Set", "ssv", w.bytes()) orelse return false;
    return true;
}

/// Попросить iwd просканировать. «Уже сканирую» безвредно, поэтому ответа не ждём.
pub fn scan() void {
    bus.callNoReply(NAME, station.get(), STATION, "Scan", "", "");
}

// ================================================================= список сетей

const MAXN = 96;
const Seen = struct { path: Path = .{}, dbm: i16 = -10000 };
const Head = struct { seen: [MAXN]Seen = undefined, n: usize = 0, out: []Net, count: usize = 0, ok: bool = false };

/// Сети в порядке ранга iwd (по одной на SSID — iwd уже объединяет точки доступа).
pub fn networks(out: []Net) usize {
    nets_changed = false;
    var h = Head{ .out = out };
    var serials = [2]u32{
        bus.sendCall(NAME, station.get(), STATION, "GetOrderedNetworks", "", "") catch 0,
        bus.sendCall(NAME, "/", OM, "GetManagedObjects", "", "") catch 0,
    };
    if (serials[0] == 0 or serials[1] == 0) {
        setError("error talking to iwd");
        return 0;
    }
    bus.collect(&serials, &h, gotList) catch {
        setError("error talking to iwd");
        return 0;
    };
    // подключённая сверху, дальше ранг iwd (он уже учитывает диапазон и сигнал)
    std.mem.sort(Net, out[0..h.count], {}, struct {
        fn lt(_: void, a: Net, b: Net) bool {
            if (a.active != b.active) return a.active;
            return a.strength > b.strength;
        }
    }.lt);
    return h.count;
}

fn gotList(h: *Head, i: usize, rep: dbus.Reply) void {
    if (!rep.ok()) {
        setError(rep.message());
        return;
    }
    var r = rep.reader();
    if (i == 0) {
        // a(on): путь сети и сигнал в 100 * дБм
        const end = r.arrayEnd(8);
        while (r.p < end and !r.bad and h.n < MAXN) {
            r.alignTo(8);
            h.seen[h.n].path.set(r.str());
            h.seen[h.n].dbm = @bitCast(r.u16_());
            h.n += 1;
        }
        h.ok = !r.bad;
        return;
    }
    // GetManagedObjects приходит после GetOrderedNetworks: шина сохраняет порядок соединения
    const end = r.arrayEnd(8);
    while (r.p < end and !r.bad) {
        r.alignTo(8);
        const path = r.str();
        var net = Net{};
        var is_net = false;
        var on_station = false;
        const iend = r.arrayEnd(8);
        while (r.p < iend and !r.bad) {
            r.alignTo(8);
            const iface = r.str();
            const mine = std.mem.eql(u8, iface, NETWORK);
            if (mine) is_net = true;
            const pend = r.arrayEnd(8);
            while (r.p < pend and !r.bad) {
                r.alignTo(8);
                const key = r.str();
                const vs = r.sig();
                const eql = std.mem.eql;
                if (!mine) {
                    r.skip(vs);
                } else if (eql(u8, key, "Name") and eql(u8, vs, "s")) {
                    const s = r.str();
                    const k = @min(s.len, net.ssid_buf.len);
                    @memcpy(net.ssid_buf[0..k], s[0..k]);
                    net.ssid_len = @intCast(k);
                } else if (eql(u8, key, "Connected") and eql(u8, vs, "b")) {
                    net.active = r.boolean();
                } else if (eql(u8, key, "Type") and eql(u8, vs, "s")) {
                    const t = r.str();
                    net.sec = if (eql(u8, t, "psk")) .psk else if (eql(u8, t, "8021x")) .eap else if (eql(u8, t, "wep")) .wep else .open;
                } else if (eql(u8, key, "KnownNetwork") and eql(u8, vs, "o")) {
                    net.conn.set(r.str());
                    net.known = true;
                } else if (eql(u8, key, "Device") and eql(u8, vs, "o")) {
                    on_station = eql(u8, r.str(), station.get());
                } else r.skip(vs);
            }
            r.p = @max(r.p, pend);
        }
        r.p = @max(r.p, iend);
        if (!is_net or !on_station or net.ssid_len == 0 or h.count == h.out.len) continue;
        net.ap.set(path);
        net.strength = 0; // сейчас вне досягаемости — iwd ещё какое-то время хранит объект
        var visible = false;
        for (h.seen[0..h.n]) |s| {
            if (!std.mem.eql(u8, s.path.get(), path)) continue;
            visible = true;
            // −90 дБм и ниже → 0 %, −30 дБм и выше → 100 %
            const dbm = @divTrunc(@as(i32, s.dbm), 100);
            net.strength = @intCast(std.math.clamp(@divTrunc((dbm + 90) * 100, 60), 0, 100));
        }
        if (!visible and !net.active) continue;
        h.out[h.count] = net;
        h.count += 1;
    }
}

// ================================================================= действия

pub fn activateSaved(_: []const u8, ap: []const u8) bool {
    if (ap.len == 0) {
        setError("The network is not in range");
        return false;
    }
    wipePending(); // сохранённая сеть: ключ у iwd; если спросит — меню предложит ввести заново
    return connectAsync(ap, NETWORK, "Connect", "", "");
}

pub fn addAndActivate(spec: Spec, ap: []const u8) bool {
    switch (spec.sec) {
        .eap => {
            setError("802.1X with iwd: the administrator creates /var/lib/iwd/<SSID>.8021x");
            return false;
        },
        .wep => {
            setError("WEP is outdated and insecure — not supported");
            return false;
        },
        else => {},
    }
    wipePending();
    if (spec.sec == .psk or spec.sec == .sae) {
        if (spec.psk.len == 0 or spec.psk.len > pending.len) {
            setError("A WPA password is 8 to 63 characters");
            return false;
        }
        @memcpy(pending[0..spec.psk.len], spec.psk);
        pending_len = spec.psk.len;
        have_pending = true;
    }
    if (spec.hidden) {
        var w = dbus.W{ .buf = &body_buf };
        w.str(spec.ssid);
        return connectAsync(station.get(), STATION, "ConnectHiddenNetwork", "s", w.bytes());
    }
    if (ap.len == 0) {
        setError("The network is not in range");
        return false;
    }
    return connectAsync(ap, NETWORK, "Connect", "", "");
}

/// Connect возвращается, только когда iwd закончил (подключился или нет); тем временем он может спросить агент
/// пароль. Поэтому вызов асинхронный: результат забирает progress().
fn connectAsync(path: []const u8, iface: []const u8, member: []const u8, sig: []const u8, body: []const u8) bool {
    activating.set(path);
    connect_serial = bus.callAsync(NAME, path, iface, member, sig, body) catch {
        setError("error talking to iwd");
        wipePending();
        return false;
    };
    return true;
}

pub fn progress() Progress {
    if (connect_serial == 0) return .failed;
    const d = bus.result(connect_serial) orelse return .working;
    connect_serial = 0;
    wipePending();
    if (d.ok) return .done;
    const eql = std.mem.eql;
    const name = d.errName();
    if (eql(u8, name, "net.connman.iwd.AlreadyConnected")) return .done;
    setError(if (eql(u8, name, "net.connman.iwd.Failed"))
        "Could not connect — check the password"
    else if (eql(u8, name, "net.connman.iwd.Aborted") or eql(u8, name, "net.connman.iwd.Agent.Error.Canceled"))
        "Password required"
    else if (eql(u8, name, "net.connman.iwd.InvalidFormat"))
        "Wrong password format"
    else if (eql(u8, name, "net.connman.iwd.NotSupported"))
        "This network type is not supported"
    else if (eql(u8, name, "net.connman.iwd.NotFound") or eql(u8, name, "net.connman.iwd.NotAvailable"))
        "Network not found"
    else if (eql(u8, name, "net.connman.iwd.InProgress"))
        "Another connection is in progress"
    else
        d.message());
    return .failed;
}

pub fn disconnect() bool {
    if (connect_serial != 0) connect_serial = 0; // поздний ответ просто выбросится
    wipePending();
    _ = call(station.get(), STATION, "Disconnect", "", "") orelse return false;
    return true;
}

pub fn forget(conn: []const u8) bool {
    _ = call(conn, KNOWN, "Forget", "", "") orelse return false;
    return true;
}
