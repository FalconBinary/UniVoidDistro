// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Клиент BlueZ по D-Bus: адаптер, устройства, подключение, сопряжение и свой агент
//! сопряжения (подтверждение кода, ввод PIN). Радио и протоколы — у системного bluetoothd.

const std = @import("std");
const sys = @import("sys.zig");
const dbus = @import("dbus.zig");

const BZ = "org.bluez";
const OM = "org.freedesktop.DBus.ObjectManager";
const PROPS = "org.freedesktop.DBus.Properties";
const ADAPTER = "org.bluez.Adapter1";
const DEVICE = "org.bluez.Device1";
const BATTERY = "org.bluez.Battery1";
const AGENT_MGR = "org.bluez.AgentManager1";
const AGENT = "org.bluez.Agent1";
pub const AGENT_PATH = "/org/refursline/agent";

pub const Path = struct {
    buf: [96]u8 = undefined,
    len: u8 = 0,

    pub fn set(p: *Path, s: []const u8) void {
        const k = @min(s.len, p.buf.len);
        std.mem.copyForwards(u8, p.buf[0..k], s[0..k]); // источник может быть этим же буфером
        p.len = @intCast(k);
    }
    pub fn get(p: *const Path) []const u8 {
        return p.buf[0..p.len];
    }
    pub fn eql(p: *const Path, s: []const u8) bool {
        return std.mem.eql(u8, p.get(), s);
    }
};

pub const Kind = enum(u8) { generic, headphones, speaker, keyboard, mouse, gamepad, phone, computer };

pub const Dev = struct {
    path: Path = .{},
    name_buf: [64]u8 = undefined,
    name_len: u8 = 0,
    has_name: bool = false, // настоящее имя, а не адрес
    kind: Kind = .generic,
    paired: bool = false, // Paired или Bonded
    p_paired: bool = false,
    p_bonded: bool = false,
    alias_seen: bool = false,
    trusted: bool = false,
    connected: bool = false,
    battery: u8 = 255, // 255 — неизвестно
    rssi: i16 = -32768, // нет данных
    // для `refursline bt … scan`
    random: bool = false, // случайный BLE-адрес (телефоны, часы, метки)
    classic: bool = false, // есть класс устройства — значит, найдено как классическое (BR/EDR)
    maker: u16 = 0xffff, // производитель из BLE-рекламы, 0xffff — нет

    pub fn name(d: *const Dev) []const u8 {
        return d.name_buf[0..d.name_len];
    }
};

pub var bus: dbus.Conn = .{};
pub var adapter: Path = .{};
pub var powered = false;
pub var discovering = false;

/// Устройства адаптера. Таблица загружается один раз (load) и дальше живёт по сигналам
/// bluetoothd (InterfacesAdded/Removed, PropertiesChanged): во время поиска не нужно
/// запрашивать все объекты снова и снова — новое устройство появляется в момент сигнала.
pub const MAX_DEVS = 255;
pub var devs: [MAX_DEVS]Dev = undefined;
pub var ndev: usize = 0;
/// изменилось что-то видимое (устройство, имя, состояние, адаптер) — список надо пересобрать
pub var changed = false;
/// изменился только уровень сигнала (RSSI) — пересборки на следующем тике достаточно
pub var rssi_changed = false;

var owner_buf: [64]u8 = undefined;
var owner_len: usize = 0;
var rfkill_fd: i32 = -1;

var err_buf: [200]u8 = undefined;
var err_len: usize = 0;
var body_buf: [4096]u8 = undefined;

pub fn lastError() []const u8 {
    return err_buf[0..err_len];
}

fn setError(m: []const u8) void {
    err_len = @min(m.len, err_buf.len);
    @memcpy(err_buf[0..err_len], m[0..err_len]);
}

fn call(path: []const u8, iface: []const u8, member: []const u8, sig: []const u8, body: []const u8) ?dbus.Reply {
    const r = bus.call(BZ, path, iface, member, sig, body) catch |e| {
        setError(switch (e) {
            error.Timeout => "bluetoothd is not responding",
            else => "error talking to bluetoothd",
        });
        return null;
    };
    if (!r.ok()) {
        setError(friendly(r.err_name, r.message()));
        return null;
    }
    return r;
}

// ================================================================= запуск

/// Подключение к системной шине и bluetoothd. /dev/rfkill открывается заранее —
/// чтобы снимать мягкую блокировку без утилиты rfkill (и уже в песочнице).
pub fn init() bool {
    rfkill_fd = sys.openRW("/dev/rfkill") catch -1;
    bus.connectSystem() catch {
        setError("no access to the D-Bus system bus");
        return false;
    };
    return attach("");
}

/// Уникальное имя запущенного bluetoothd на шине (":1.42"), null — не запущен.
/// Дешёвая проверка по уже открытому соединению — работает в песочнице.
fn nameOwner(buf: *[64]u8) ?[]const u8 {
    var w = dbus.W{ .buf = &body_buf };
    w.str(BZ);
    const r = bus.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner", "s", w.bytes()) catch {
        setError("error talking to D-Bus");
        return null;
    };
    if (!r.ok()) {
        setError("The Bluetooth service (bluetoothd) is not running");
        return null;
    }
    var rr = r.reader();
    const o = rr.str();
    if (rr.bad or o.len == 0) return null;
    const k = @min(o.len, buf.len);
    @memcpy(buf[0..k], o[0..k]);
    return buf[0..k];
}

/// bluetoothd, с которым говорим (пусто — пока никакого).
pub fn owner() []const u8 {
    return owner_buf[0..owner_len];
}

/// Найти bluetoothd на уже подключённой шине: при запуске и снова после того, как служба
/// запущена по требованию (config.bt_service_on_cmd). `not` — только что остановленный экземпляр:
/// пока он завершается, он не считается. Новых сокетов нет, так что работает в песочнице.
pub fn attach(not: []const u8) bool {
    var ob: [64]u8 = undefined;
    const o = nameOwner(&ob) orelse return false;
    if (std.mem.eql(u8, o, not)) return false;
    owner_len = o.len;
    @memcpy(owner_buf[0..owner_len], o);
    // сигналы только от самого bluetoothd — адресный «сигнал» от другого процесса игнорируется
    bus.setPeer(owner_buf[0..owner_len]);

    // шина обрабатывает наши сообщения по порядку: правило действует до следующего вызова, ответа ждать не нужно.
    // Правило называет общеизвестное имя, поэтому покрывает и bluetoothd, запущенный позже, — добавляется один раз.
    if (!matched) {
        var w = dbus.W{ .buf = &body_buf };
        w.str("type='signal',sender='org.bluez'");
        bus.callNoReply("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "AddMatch", "s", w.bytes());
        matched = true;
    }
    bus.on_signal = onSignal;
    return true;
}

var matched = false;

fn onSignal(path: []const u8, iface: []const u8, member: []const u8, sig: []const u8, body: []const u8) void {
    const eql = std.mem.eql;
    var r = dbus.R{ .d = body };
    if (eql(u8, iface, OM) and eql(u8, member, "InterfacesAdded") and eql(u8, sig, "oa{sa{sv}}")) {
        const p = r.str();
        if (r.bad or !(isDevPath(p) or (adapter.len == 0 and isAdapterPath(p)))) return;
        applyObject(&r, p);
    } else if (eql(u8, iface, OM) and eql(u8, member, "InterfacesRemoved") and eql(u8, sig, "oas")) {
        const p = r.str();
        const end = r.arrayEnd(4);
        while (r.p < end and !r.bad) {
            switch (whichOf(r.str())) {
                .device => removeDev(p),
                .battery => if (find(p)) |d| {
                    d.battery = 255;
                    changed = true;
                },
                .adapter => if (adapter.eql(p)) {
                    adapter.len = 0;
                    powered = false;
                    discovering = false;
                    ndev = 0;
                    changed = true;
                },
                .other => {},
            }
        }
    } else if (eql(u8, iface, PROPS) and eql(u8, member, "PropertiesChanged") and eql(u8, sig, "sa{sv}as")) {
        switch (whichOf(r.str())) {
            .device, .battery => |w| {
                if (!isDevPath(path)) return;
                const d = find(path) orelse devFor(path) orelse return;
                applyProps(&r, w, d);
                // RSSI пропадает, когда поиск заканчивается
                const end = r.arrayEnd(4);
                while (r.p < end and !r.bad) {
                    if (eql(u8, r.str(), "RSSI")) d.rssi = -32768;
                }
            },
            .adapter => if (adapter.eql(path)) applyProps(&r, .adapter, null),
            .other => {},
        }
    }
}

// ================================================================= таблица устройств

const Which = enum { other, device, adapter, battery };

fn whichOf(iface: []const u8) Which {
    const eql = std.mem.eql;
    if (eql(u8, iface, DEVICE)) return .device;
    if (eql(u8, iface, ADAPTER)) return .adapter;
    if (eql(u8, iface, BATTERY)) return .battery;
    return .other;
}

/// /org/bluez/hciN — без вложенных объектов
fn isAdapterPath(p: []const u8) bool {
    const pre = "/org/bluez/hci";
    return std.mem.startsWith(u8, p, pre) and std.mem.indexOfScalar(u8, p[pre.len..], '/') == null;
}

/// Устройство нашего адаптера: /org/bluez/hci0/dev_XX_XX… (без вложенных объектов).
fn isDevPath(p: []const u8) bool {
    const a = adapter.get();
    return a.len > 0 and p.len > a.len + 1 and std.mem.startsWith(u8, p, a) and p[a.len] == '/' and
        std.mem.indexOfScalar(u8, p[a.len + 1 ..], '/') == null;
}

fn find(path: []const u8) ?*Dev {
    for (devs[0..ndev]) |*d| {
        if (d.path.eql(path)) return d;
    }
    return null;
}

/// Показывается ли устройство хотя бы в одном списке меню (иначе это BLE-шум).
fn useful(d: *const Dev) bool {
    return d.paired or d.connected or d.has_name or d.kind != .generic;
}

/// Новая запись. Если таблица полна, вытеснить самый слабый безымянный BLE-шум:
/// десятки чужих телефонов и меток не должны вытеснять нужные устройства.
fn devFor(path: []const u8) ?*Dev {
    var slot: ?usize = null;
    if (ndev < devs.len) {
        slot = ndev;
        ndev += 1;
    } else {
        for (devs[0..ndev], 0..) |*d, i| {
            if (useful(d)) continue;
            if (slot == null or d.rssi < devs[slot.?].rssi) slot = i;
        }
    }
    const i = slot orelse return null;
    devs[i] = .{};
    devs[i].path.set(path);
    return &devs[i];
}

fn removeDev(path: []const u8) void {
    for (devs[0..ndev], 0..) |*d, i| {
        if (!d.path.eql(path)) continue;
        devs[i] = devs[ndev - 1];
        ndev -= 1;
        changed = true;
        return;
    }
}

fn setLabel(d: *Dev, s: []const u8) void {
    d.name_len = @intCast(@min(s.len, d.name_buf.len));
    @memcpy(d.name_buf[0..d.name_len], s[0..d.name_len]);
}

/// Один объект из GetManagedObjects или InterfacesAdded: a{sa{sv}}.
fn applyObject(r: *dbus.R, path: []const u8) void {
    const iend = r.arrayEnd(8);
    while (r.p < iend and !r.bad) {
        r.alignTo(8);
        const w = whichOf(r.str());
        switch (w) {
            .device, .battery => {
                if (find(path) orelse devFor(path)) |d| applyProps(r, w, d) else r.skip("a{sv}");
            },
            .adapter => {
                // первый найденный адаптер — наш
                if (adapter.len == 0) adapter.set(path);
                if (adapter.eql(path)) applyProps(r, .adapter, null) else r.skip("a{sv}");
            },
            .other => r.skip("a{sv}"),
        }
    }
    r.p = @max(r.p, iend);
}

/// Словарь свойств a{sv} одного интерфейса → запись устройства (или адаптер).
fn applyProps(r: *dbus.R, w: Which, dev: ?*Dev) void {
    const eql = std.mem.eql;
    const pend = r.arrayEnd(8);
    while (r.p < pend and !r.bad) {
        r.alignTo(8);
        const key = r.str();
        const vs = r.sig();
        const vt = if (vs.len == 1) vs[0] else 0;
        var minor = false; // меняется только сигнал или реклама — список сразу не пересобирать
        if (w == .adapter) {
            if (vt == 'b' and eql(u8, key, "Powered")) {
                powered = r.boolean();
            } else if (vt == 'b' and eql(u8, key, "Discovering")) {
                discovering = r.boolean();
            } else {
                r.skip(vs);
                continue;
            }
        } else if (w == .battery) {
            const d = dev.?;
            if (vt == 'y' and eql(u8, key, "Percentage")) d.battery = @min(r.byte(), 100) else {
                r.skip(vs);
                continue;
            }
        } else {
            const d = dev.?;
            if (vt == 's' and eql(u8, key, "Alias")) {
                setLabel(d, r.str());
                d.alias_seen = true;
            } else if (vt == 's' and eql(u8, key, "Name")) {
                const nm = r.str();
                d.has_name = nm.len > 0;
                if (!d.alias_seen or d.name_len == 0) setLabel(d, nm);
            } else if (vt == 's' and eql(u8, key, "Icon")) {
                d.kind = kindOf(r.str());
            } else if (vt == 'b' and eql(u8, key, "Paired")) {
                d.p_paired = r.boolean();
            } else if (vt == 'b' and eql(u8, key, "Bonded")) {
                d.p_bonded = r.boolean();
            } else if (vt == 'b' and eql(u8, key, "Trusted")) {
                d.trusted = r.boolean();
            } else if (vt == 'b' and eql(u8, key, "Connected")) {
                d.connected = r.boolean();
            } else if (vt == 'n' and eql(u8, key, "RSSI")) {
                d.rssi = @bitCast(r.u16_());
                minor = true;
            } else if (vt == 's' and eql(u8, key, "AddressType")) {
                d.random = eql(u8, r.str(), "random");
            } else if (vt == 'u' and eql(u8, key, "Class")) {
                _ = r.u32_();
                d.classic = true;
            } else if (eql(u8, vs, "a{qv}") and eql(u8, key, "ManufacturerData")) {
                const mend = r.arrayEnd(8);
                if (r.p < mend) {
                    r.alignTo(8);
                    d.maker = r.u16_();
                }
                r.p = @max(r.p, mend);
                minor = true;
            } else {
                r.skip(vs);
                continue;
            }
            d.paired = d.p_paired or d.p_bonded;
        }
        if (minor) rssi_changed = true else changed = true;
    }
    r.p = @max(r.p, pend);
}

/// Зарегистрировать свой агент сопряжения (только для сопряжений, начатых нами).
pub fn registerAgent() bool {
    var w = dbus.W{ .buf = &body_buf };
    w.str(AGENT_PATH);
    w.str("KeyboardDisplay");
    bus.on_method = onMethod;
    _ = call("/org/bluez", AGENT_MGR, "RegisterAgent", "os", w.bytes()) orelse return false;
    return true;
}

// ================================================================= устройства

fn kindOf(icon: []const u8) Kind {
    const eql = std.mem.eql;
    if (eql(u8, icon, "audio-headset") or eql(u8, icon, "audio-headphones")) return .headphones;
    if (std.mem.startsWith(u8, icon, "audio")) return .speaker;
    if (eql(u8, icon, "input-keyboard")) return .keyboard;
    if (eql(u8, icon, "input-mouse") or eql(u8, icon, "input-tablet")) return .mouse;
    if (eql(u8, icon, "input-gaming")) return .gamepad;
    if (eql(u8, icon, "phone")) return .phone;
    if (eql(u8, icon, "computer")) return .computer;
    return .generic;
}

/// Загрузить адаптер и все устройства (GetManagedObjects). Дальше таблицу ведут сигналы.
/// Возвращает число устройств.
pub fn load() usize {
    const rep = call("/", OM, "GetManagedObjects", "", "") orelse return 0;
    ndev = 0;
    adapter.len = 0;
    powered = false;
    discovering = false;
    var r = rep.reader();
    const end = r.arrayEnd(8);
    while (r.p < end and !r.bad) {
        r.alignTo(8);
        const path = r.str();
        applyObject(&r, path);
    }
    changed = true;
    if (r.bad) {
        setError("invalid reply from bluetoothd");
        ndev = 0;
        return 0;
    }
    if (adapter.len == 0) {
        setError("Bluetooth adapter not found");
        ndev = 0;
        return 0;
    }
    // только устройства нашего адаптера: /org/bluez/hci0/dev_...
    var k: usize = 0;
    for (devs[0..ndev]) |d| {
        if (isDevPath(d.path.get())) {
            devs[k] = d;
            k += 1;
        }
    }
    ndev = k;
    return k;
}

// ================================================================= действия

/// Снять мягкую блокировку Bluetooth (как `rfkill unblock bluetooth`).
fn rfkillUnblock() void {
    if (rfkill_fd < 0) return;
    // struct rfkill_event { u32 idx; u8 type; u8 op; u8 soft; u8 hard; }
    const ev = [8]u8{ 0, 0, 0, 0, 2, 3, 0, 0 }; // RFKILL_TYPE_BLUETOOTH, RFKILL_OP_CHANGE_ALL, soft=0
    _ = sys.write(rfkill_fd, &ev) catch {};
}

fn setBool(path: []const u8, iface: []const u8, name: []const u8, v: bool) bool {
    var w = dbus.W{ .buf = &body_buf };
    w.str(iface);
    w.str(name);
    w.sig("b");
    w.boolean(v);
    _ = call(path, PROPS, "Set", "ssv", w.bytes()) orelse return false;
    return true;
}

pub fn setPowered(on: bool) bool {
    if (adapter.len == 0) {
        setError("Bluetooth adapter not found");
        return false;
    }
    if (on) rfkillUnblock();
    // после снятия rfkill адаптеру нужно мгновение, чтобы стать доступным:
    // повторять часто (каждые 50 мс, до 2 с), чтобы не ждать дольше нужного
    var attempt: u32 = 0;
    while (attempt < 40) : (attempt += 1) {
        if (setBool(adapter.get(), ADAPTER, "Powered", on)) {
            powered = on;
            return true;
        }
        if (!on) return false;
        var none = [0]sys.PollFd{};
        _ = sys.poll(&none, 50) catch {};
    }
    return false;
}

/// Начать поиск. «Уже идёт» — не ошибка; иначе false и текст в lastError.
pub fn startDiscovery() bool {
    const r = bus.call(BZ, adapter.get(), ADAPTER, "StartDiscovery", "", "") catch {
        setError("error talking to bluetoothd");
        return false;
    };
    if (r.ok() or std.mem.endsWith(u8, r.err_name, "InProgress")) return true;
    setError(friendly(r.err_name, r.message()));
    return false;
}

pub fn stopDiscovery() void {
    _ = bus.call(BZ, adapter.get(), ADAPTER, "StopDiscovery", "", "") catch {};
}

fn devCall(path: []const u8, member: []const u8) ?u32 {
    return bus.callAsync(BZ, path, DEVICE, member, "", "") catch {
        setError("error talking to bluetoothd");
        return null;
    };
}

pub fn connect(dev: []const u8) ?u32 {
    return devCall(dev, "Connect");
}

pub fn disconnect(dev: []const u8) ?u32 {
    return devCall(dev, "Disconnect");
}

pub fn pair(dev: []const u8) ?u32 {
    return devCall(dev, "Pair");
}

pub fn cancelPairing(dev: []const u8) void {
    _ = devCall(dev, "CancelPairing");
}

pub fn trust(dev: []const u8) void {
    _ = setBool(dev, DEVICE, "Trusted", true);
}

pub fn remove(dev: []const u8) bool {
    var w = dbus.W{ .buf = &body_buf };
    w.str(dev);
    _ = call(adapter.get(), ADAPTER, "RemoveDevice", "o", w.bytes()) orelse return false;
    return true;
}

/// Понятное сообщение для ошибки BlueZ.
pub fn friendly(name: []const u8, text: []const u8) []const u8 {
    const has = struct {
        fn f(s: []const u8, sub: []const u8) bool {
            return std.mem.indexOf(u8, s, sub) != null;
        }
    }.f;
    if (has(text, "page-timeout") or has(text, "Page Timeout") or has(text, "Host is down") or has(text, "le-connection-abort"))
        return "The device is not responding — turn it on and bring it closer";
    if (has(name, "AuthenticationCanceled")) return "Pairing canceled";
    if (has(name, "AuthenticationRejected") or has(name, "AuthenticationFailed")) return "Pairing rejected — check the code";
    if (has(name, "AuthenticationTimeout")) return "Timed out";
    if (has(name, "ConnectionAttemptFailed")) return "Could not connect";
    if (has(name, "AlreadyExists")) return "The device is already paired";
    if (has(name, "InProgress")) return "The operation is already in progress";
    if (has(name, "NotReady")) return "The adapter is not ready";
    if (has(name, "Blocked") or has(text, "rfkill")) return "Bluetooth is blocked (rfkill)";
    if (has(name, "NotAvailable") or has(text, "profile-unavailable")) return "The device doesn't support the required profile";
    if (has(name, "AccessDenied") or has(name, "NotAuthorized")) return "Permission denied — check the polkit/D-Bus policy";
    if (text.len > 0) return text;
    return name;
}

// ================================================================= агент сопряжения

pub const ReqKind = enum { none, confirm, authorize, ask_pin, ask_passkey, show_passkey, show_pin };

pub const Req = struct {
    kind: ReqKind = .none,
    serial: u32 = 0,
    flags: u8 = 0,
    sender_buf: [64]u8 = undefined,
    sender_len: usize = 0,
    device: Path = .{},
    passkey: u32 = 0,
    entered: u16 = 0,
    pin_buf: [17]u8 = undefined,
    pin_len: usize = 0,

    pub fn pin(q: *const Req) []const u8 {
        return q.pin_buf[0..q.pin_len];
    }
    fn deferred(q: *const Req) bool {
        return switch (q.kind) {
            .confirm, .authorize, .ask_pin, .ask_passkey => true,
            else => false,
        };
    }
};

pub var req: Req = .{};
/// агенту пришёл запрос или отмена — экран надо перерисовать
pub var req_changed = false;

fn incoming(q: *const Req, sender: []const u8) dbus.Incoming {
    return .{ .serial = q.serial, .flags = q.flags, .sender = sender, .path = AGENT_PATH, .iface = AGENT, .member = "", .sig = "", .body = "" };
}

/// Отклонить ожидающий запрос (если есть).
pub fn rejectPending() void {
    if (!req.deferred()) {
        req.kind = .none;
        return;
    }
    const m = incoming(&req, req.sender_buf[0..req.sender_len]);
    bus.replyError(&m, "org.bluez.Error.Rejected", "rejected by the user");
    req.kind = .none;
}

/// Ответ пользователя на запрос агента. Для ask_pin/ask_passkey — введённое значение.
pub fn answer(accept: bool, value: []const u8) void {
    if (!req.deferred()) return;
    const m = incoming(&req, req.sender_buf[0..req.sender_len]);
    if (!accept) {
        bus.replyError(&m, "org.bluez.Error.Rejected", "rejected by the user");
    } else switch (req.kind) {
        .ask_pin => {
            var w = dbus.W{ .buf = &body_buf };
            w.str(value);
            bus.reply(&m, "s", w.bytes());
            sys.secureZero(&body_buf);
        },
        .ask_passkey => {
            const v = std.fmt.parseInt(u32, value, 10) catch 0;
            var w = dbus.W{ .buf = &body_buf };
            w.u32_(@min(v, 999999));
            bus.reply(&m, "u", w.bytes());
        },
        else => bus.reply(&m, "", ""),
    }
    req.kind = .none;
}

fn onMethod(c: *dbus.Conn, m: *const dbus.Incoming) void {
    const eql = std.mem.eql;
    if (!eql(u8, m.path, AGENT_PATH) or !eql(u8, m.iface, AGENT)) {
        return c.replyError(m, "org.freedesktop.DBus.Error.UnknownObject", "no such object");
    }
    // отвечать только самому bluetoothd
    if (!eql(u8, m.sender, owner_buf[0..owner_len])) {
        return c.replyError(m, "org.freedesktop.DBus.Error.AccessDenied", "access denied");
    }
    var r = m.reader();
    const mem = m.member;
    if (eql(u8, mem, "Release") or eql(u8, mem, "AuthorizeService")) return c.reply(m, "", "");
    if (eql(u8, mem, "Cancel")) {
        req.kind = .none;
        req_changed = true;
        return c.reply(m, "", "");
    }
    // новый запрос заменяет старый (старый отклоняется)
    rejectPending();
    var q = Req{ .serial = m.serial, .flags = m.flags };
    q.sender_len = @min(m.sender.len, q.sender_buf.len);
    @memcpy(q.sender_buf[0..q.sender_len], m.sender[0..q.sender_len]);
    if (eql(u8, mem, "DisplayPasskey") and eql(u8, m.sig, "ouq")) {
        q.device.set(r.str());
        q.passkey = r.u32_();
        q.entered = r.u16_();
        q.kind = .show_passkey;
        c.reply(m, "", "");
    } else if (eql(u8, mem, "DisplayPinCode") and eql(u8, m.sig, "os")) {
        q.device.set(r.str());
        const p = r.str();
        q.pin_len = @min(p.len, q.pin_buf.len);
        @memcpy(q.pin_buf[0..q.pin_len], p[0..q.pin_len]);
        q.kind = .show_pin;
        c.reply(m, "", "");
    } else if (eql(u8, mem, "RequestConfirmation") and eql(u8, m.sig, "ou")) {
        q.device.set(r.str());
        q.passkey = r.u32_();
        q.kind = .confirm;
    } else if (eql(u8, mem, "RequestAuthorization") and eql(u8, m.sig, "o")) {
        q.device.set(r.str());
        q.kind = .authorize;
    } else if (eql(u8, mem, "RequestPinCode") and eql(u8, m.sig, "o")) {
        q.device.set(r.str());
        q.kind = .ask_pin;
    } else if (eql(u8, mem, "RequestPasskey") and eql(u8, m.sig, "o")) {
        q.device.set(r.str());
        q.kind = .ask_passkey;
    } else {
        return c.replyError(m, "org.bluez.Error.Rejected", "not supported");
    }
    if (r.bad) {
        q.kind = .none;
        return c.replyError(m, "org.bluez.Error.Rejected", "invalid arguments");
    }
    req = q;
    req_changed = true;
}
