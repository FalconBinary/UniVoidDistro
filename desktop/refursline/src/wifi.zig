// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Меню Wi‑Fi RefursLine — через iwd по D-Bus.
//!
//! Список сетей, подключение к открытым и WPA/WPA2/WPA3 Personal (и скрытым) сетям, отключение,
//! «забыть». 802.1X iwd берёт только из файла администратора (/var/lib/iwd/<SSID>.8021x): такая
//! сеть становится «известной», и меню просто подключается к ней.
//! `refursline wifi ТЕМА toggle` — радио вкл/выкл без окна (ПКМ по значку в баре).
//! Клавиатура: Tab/Shift+Tab, ↑/↓, Enter, Esc, Ctrl+V — вставить, Ctrl+U — очистить поле.

const std = @import("std");
const sys = @import("sys.zig");
const draw = @import("draw.zig");
const theme = @import("theme.zig");
const cfg = @import("config.zig");
const iwd = @import("iwd.zig");
const ui = @import("ui.zig");

const PAD = ui.PAD;
const ROW_H: f32 = 44;
const LIST_Y: f32 = 62;
const FIELD_H: f32 = 34;
const LABEL_W: f32 = 124;
const STEP: f32 = 42;

const View = enum { list, password, hidden, actions, connecting, done };
var view: View = .list;
var form_view: View = .password; // куда вернуться при неудаче

var nets: [48]iwd.Net = undefined;
var list: ui.List = .{};
var target: iwd.Net = .{};
var target_hidden = false;
var reenter = false; // сохранённый ключ не подошёл — старый удаляется при отправке
var iwd_ok = false;
var loaded = false; // список ещё не загружен: окно показывается сразу, данные — на следующем тике
var ticks: u32 = 0;

const F = enum(u8) { ssid, password };
var fields: [2]ui.Field = @as([2]ui.Field, @splat(.{}));
var reveal = false;
var hsec: u8 = 1; // скрытая сеть: 0 открытая, 1 personal

const hsec_label = [_][]const u8{ "Open", "WPA/WPA2/WPA3 Personal" };

const Wid = enum(u8) { none, row, more, toggle, back, other, field, select, eye, primary, secondary, act_connect, act_disconnect, act_forget };

fn wid(w: ui.Widget) Wid {
    return @enumFromInt(w.id);
}

// ================================================================= запуск

pub fn main() noreturn {
    if (sys.argIs(3, "toggle")) {
        // без окна: переключить радио и выйти
        if (!iwd.init()) {
            sys.log("{s}", .{iwd.lastError()});
            sys.exit(1);
        }
        if (!iwd.setEnabled(!iwd.wifi_enabled)) {
            sys.log("{s}", .{iwd.lastError()});
            sys.exit(1);
        }
        sys.exit(0);
    }
    ui.begin("wifi");
    iwd_ok = iwd.init();
    if (!iwd_ok) ui.setMsg(iwd.lastError());
    ui.run(.{
        .width = cfg.menu_width,
        .height = cfg.menu_height,
        .layout = layout,
        .paint = paint,
        .activate = activate,
        .back = goBack,
        .submit = submit,
        .key = onKey,
        .scroll = onScroll,
        .tick = onTick,
        .field = fieldAt,
        .cycle = cycleSelect,
        .extra_fd = busFd,
        .on_extra = onBus,
        .start = start,
        .cleanup = cleanup,
        .hover_local = true,
    }, .{}, .{});
}

fn start() void {
    list.visible = @intFromFloat((ui.H() - LIST_Y - 64) / ROW_H);
    // меню появляется сразу («Searching for networks…»), список грузится на первом тике таймера
    if (iwd_ok) ui.setTimer(1, SCAN_MS) else armTimer();
}

fn busFd() i32 {
    return if (iwd_ok) iwd.bus.fd else -1;
}

/// сигналы iwd: новые сети показываются, как только iwd их нашёл,
/// а результат подключения — как только устройство сменило состояние.
fn onBus() void {
    // второй проход: синхронные вызовы из handleSignals могли прочитать сигналы в буфер
    for (0..2) |_| {
        if (!iwd_ok) return;
        iwd.bus.pump() catch {
            iwd_ok = false;
            ui.setMsg("lost connection to the Wi‑Fi service");
            return;
        };
        handleSignals();
    }
}

fn handleSignals() void {
    if (iwd.nets_changed and view == .list and loaded and !refresh_pending) {
        // iwd шлёт изменения пачкой (сети, конец скана) — перечитать один раз, чуть позже;
        // следующий скан — через полный интервал после свежих результатов
        refresh_pending = true;
        ui.setTimer(SETTLE_MS, SCAN_MS);
    }
    if (iwd.state_changed and view == .connecting) {
        iwd.state_changed = false;
        checkProgress();
    }
}

fn cleanup() void {
    for (&fields) |*f| f.clear();
    sys.secureZero(iwd.bus.out);
}

fn fieldAt(idx: u16) ?*ui.Field {
    return if (idx < fields.len) &fields[idx] else null;
}

// ================================================================= логика

/// Перечитать список сетей. Включено ли радио, сообщает сигнал — отдельно не спрашиваем.
fn refresh() void {
    iwd.nets_changed = false; // даже с выключенным радио: иначе сигнал снова и снова переназначал бы обновление
    list.setCount(if (iwd.wifi_enabled) iwd.networks(&nets) else 0);
    ui.redraw();
}

/// Как часто просить iwd сканировать, пока список открыт. Сам список обновляется по сигналам.
const SCAN_MS = 10_000;
/// Сколько ждать после первого сигнала об изменении списка, чтобы собрать всю пачку.
const SETTLE_MS = 40;
var refresh_pending = false;

/// Таймер: в списке — повторные сканы сетей; при подключении — анимация точек
/// (результат приходит сигналом, опрос — только запасной путь).
fn armTimer() void {
    switch (view) {
        .connecting => ui.setTimer(500, 500),
        .done => ui.setTimer(900, 0),
        .list => ui.setTimer(SCAN_MS, SCAN_MS),
        else => ui.setTimer(0, 0), // в формах ничего не опрашивается
    }
}

fn setView(v: View) void {
    view = v;
    refresh_pending = false;
    armTimer();
    ui.resetFocus(v == .actions);
}

fn onTick() void {
    ticks +%= 1;
    switch (view) {
        .list => {
            if (!iwd_ok) return;
            if (!loaded) {
                // сначала то, что iwd уже знает (список показывается сразу), потом новый скан
                loaded = true;
                refresh();
                if (iwd.wifi_enabled) iwd.scan();
            } else if (refresh_pending) {
                refresh_pending = false;
                refresh();
            } else if (iwd.wifi_enabled) iwd.scan(); // результаты приходят сигналами (InterfacesAdded, конец скана)
        },
        .connecting => {
            ui.redrawText(ui.H() / 2 + 14, 14); // анимация точек — только её строка
            if (ticks > 90 * 1000 / 500) return fail("Timed out");
            // результат приходит ответом на Connect; проверка ничего не стоит
            // (ответ iwd — это ответ на Connect, проверить его ничего не стоит)
            checkProgress(); // ответ iwd на Connect — проверка ничего не стоит
        },
        .done => ui.quit(),
        else => {},
    }
    onBus();
}

fn checkProgress() void {
    switch (iwd.progress()) {
        .working => {},
        .done => {
            for (&fields) |*f| f.clear();
            setView(.done);
        },
        .failed => fail(iwd.lastError()),
    }
}

fn fail(why: []const u8) void {
    // сохранённый ключ не подошёл — предложить ввести заново
    if (form_view == .list) {
        reenter = true;
        form_view = switch (target.sec) {
            .psk, .sae => .password,
            else => .list,
        };
    }
    setView(form_view);
    ui.setMsg(why);
}

fn startConnecting(from: View) void {
    form_view = from;
    ticks = 0;
    ui.clearMsg();
    setView(.connecting);
}

fn goBack() void {
    ui.clearMsg();
    switch (view) {
        .list => ui.quit(),
        .connecting => {
            _ = iwd.disconnect();
            setView(.list);
            refresh();
        },
        else => setView(.list),
    }
}

fn clearForm() void {
    for (&fields) |*f| f.clear();
    reveal = false;
    ui.clearMsg();
}

fn chooseNet(i: usize, right: bool) void {
    if (i >= list.n) return;
    target = nets[i];
    target_hidden = false;
    reenter = false;
    clearForm();
    if (target.active or (right and target.known)) return setView(.actions);
    if (target.known) {
        if (iwd.activateSaved(target.conn.get(), target.ap.get())) startConnecting(.list) else ui.setMsg(iwd.lastError());
        return;
    }
    switch (target.sec) {
        .open, .owe => connectSimple(),
        .psk, .sae => setView(.password),
        // iwd берёт 802.1X только из файла root — формы нет
        .eap => ui.setMsg(iwd_eap),
        .wep => ui.setMsg("WEP is outdated and insecure — not supported"),
    }
}

const iwd_eap = "802.1X with iwd: the administrator creates /var/lib/iwd/<SSID>.8021x";

fn connectSimple() void {
    if (iwd.addAndActivate(.{ .ssid = target.ssid(), .hidden = target_hidden, .sec = target.sec }, target.ap.get())) {
        startConnecting(.list);
    } else ui.setMsg(iwd.lastError());
}

fn onKey(k: ui.Key) bool {
    if (view != .list) return false;
    switch (k.code) {
        ui.K_UP, ui.K_DOWN => {
            ui.focus = .{}; // стрелки снова двигаются по списку, а не по кнопке
            list.move(if (k.code == ui.K_UP) -1 else 1);
        },
        ui.K_ENTER, ui.K_KPENTER => {
            if (ui.focus.id != 0) return false; // в фокусе кнопка — нажать её
            if (list.n > 0) chooseNet(list.sel, false);
        },
        else => return false,
    }
    return true;
}

fn onScroll(d: i32) void {
    if (view == .list) list.scrollBy(d);
}

fn activate(w: ui.Widget, right: bool) void {
    switch (wid(w)) {
        .row => {
            list.sel = w.idx;
            chooseNet(w.idx, right);
        },
        .more => {
            target = nets[w.idx];
            setView(.actions);
        },
        .toggle => {
            if (iwd.setEnabled(!iwd.wifi_enabled)) refresh() else ui.setMsg(iwd.lastError());
        },
        .back => goBack(),
        .other => {
            clearForm();
            hsec = 1;
            target_hidden = true;
            setView(.hidden);
        },
        .eye => reveal = !reveal,
        .primary => submit(),
        .secondary => goBack(),
        .act_connect => {
            if (iwd.activateSaved(target.conn.get(), target.ap.get())) startConnecting(.list) else ui.setMsg(iwd.lastError());
        },
        .act_disconnect => {
            if (iwd.disconnect()) {
                setView(.list);
                refresh();
            } else ui.setMsg(iwd.lastError());
        },
        .act_forget => {
            if (target.known and iwd.forget(target.conn.get())) {
                setView(.list);
                refresh();
            } else ui.setMsg(iwd.lastError());
        },
        .field, .select, .none => {},
    }
}

fn cycleSelect(idx: u16, back_dir: bool) void {
    _ = back_dir;
    if (idx == 2) hsec ^= 1;
    ui.redraw();
}

fn val(f: F) []const u8 {
    return fields[@intFromEnum(f)].text();
}

fn submit() void {
    ui.clearMsg();
    switch (view) {
        .password => {
            const pw = val(.password);
            if (target.sec == .psk and (pw.len < 8 or pw.len > 63)) return ui.setMsg("A WPA password is 8 to 63 characters");
            if (pw.len == 0) return ui.setMsg("Enter the password");
            if (reenter and target.known) _ = iwd.forget(target.conn.get());
            if (iwd.addAndActivate(.{ .ssid = target.ssid(), .hidden = target_hidden, .sec = target.sec, .psk = pw }, target.ap.get())) {
                startConnecting(.password);
            } else ui.setMsg(iwd.lastError());
        },
        .hidden => {
            const ssid = val(.ssid);
            if (ssid.len == 0 or ssid.len > 32) return ui.setMsg("The network name is 1 to 32 bytes");
            target = .{};
            @memcpy(target.ssid_buf[0..ssid.len], ssid);
            target.ssid_len = @intCast(ssid.len);
            target_hidden = true;
            switch (hsec) {
                0 => {
                    target.sec = .open;
                    connectSimple();
                },
                1 => {
                    target.sec = .psk;
                    const pw = val(.password);
                    if (pw.len < 8 or pw.len > 63) return ui.setMsg("A WPA password is 8 to 63 characters");
                    if (iwd.addAndActivate(.{ .ssid = ssid, .hidden = true, .sec = .psk, .psk = pw }, "")) startConnecting(.hidden) else ui.setMsg(iwd.lastError());
                },
                else => {},
            }
        },
        else => {},
    }
}

// ================================================================= раскладка

/// Строки формы скрытой сети: (поле/выбор, индекс, подпись).
const FormRow = struct { id: Wid, idx: u8, label: []const u8 };

fn hiddenRows(out: *[8]FormRow) usize {
    var n: usize = 0;
    out[n] = .{ .id = .field, .idx = @intFromEnum(F.ssid), .label = "Network name" };
    n += 1;
    out[n] = .{ .id = .select, .idx = 2, .label = "Security" };
    n += 1;
    if (hsec == 1) {
        out[n] = .{ .id = .field, .idx = @intFromEnum(F.password), .label = "Password" };
        n += 1;
    }
    return n;
}

fn bottomButtons() void {
    const bw = (ui.W() - 2 * PAD - 10) / 2;
    const y = ui.H() - PAD - 38;
    ui.add(Wid.secondary, 0, .button, PAD, y, bw, 38);
    ui.add(Wid.primary, 0, .button, PAD + bw + 10, y, bw, 38);
}

fn back() void {
    ui.add(Wid.back, 0, .plain, PAD - 8, 16, 30, 30);
}

fn layout() void {
    ui.nwid = 0;
    const W = ui.W();
    switch (view) {
        .list => {
            if (iwd_ok) ui.add(Wid.toggle, 0, .toggle, W - PAD - 40, 20, 40, 22);
            var i = list.scroll;
            var y = LIST_Y;
            while (i < list.n and i < list.scroll + list.visible) : (i += 1) {
                ui.add(Wid.row, i, .row, PAD - 8, y, W - 2 * PAD + 16, ROW_H - 4);
                if (nets[i].known) ui.add(Wid.more, i, .plain, W - PAD - 34, y + 6, 28, 28);
                y += ROW_H;
            }
            if (iwd_ok and iwd.wifi_enabled) ui.add(Wid.other, 0, .button, PAD, ui.H() - PAD - 38, W - 2 * PAD, 38);
        },
        .password => {
            back();
            ui.add(Wid.field, @intFromEnum(F.password), .field, PAD, 112, W - 2 * PAD, FIELD_H);
            ui.add(Wid.eye, 0, .plain, W - PAD - 32, 115, 28, 28);
            bottomButtons();
        },
        .hidden => {
            back();
            var rows: [8]FormRow = undefined;
            const n = hiddenRows(&rows);
            var y: f32 = 64;
            for (rows[0..n]) |r| {
                ui.add(r.id, r.idx, if (r.id == .field) .field else .select, PAD + LABEL_W, y, W - 2 * PAD - LABEL_W, FIELD_H);
                y += STEP;
            }
            bottomButtons();
        },
        .actions => {
            back();
            var y: f32 = 110;
            if (target.active) {
                ui.add(Wid.act_disconnect, 0, .button, PAD, y, W - 2 * PAD, 40);
            } else {
                ui.add(Wid.act_connect, 0, .button, PAD, y, W - 2 * PAD, 40);
            }
            y += 50;
            if (target.known) ui.add(Wid.act_forget, 0, .button, PAD, y, W - 2 * PAD, 40);
        },
        .connecting => ui.add(Wid.secondary, 0, .button, (W - 140) / 2, ui.H() - PAD - 38, 140, 38),
        .done => {},
    }
}

// ================================================================= отрисовка

fn signal(cv: *draw.Canvas, x: f32, y: f32, strength: u8, on: u32, off: u32) void {
    const lvl: u8 = if (strength > 75) 4 else if (strength > 50) 3 else if (strength > 25) 2 else 1;
    var i: u8 = 0;
    while (i < 4) : (i += 1) {
        const fi: f32 = @floatFromInt(i);
        const h = 4 + fi * 3.3;
        ui.rect(cv, x + fi * 4.5, y + 14 - h, 3, h, if (i < lvl) on else off);
    }
}

fn secLabel(s: iwd.Security) []const u8 {
    return switch (s) {
        .open => "Open network",
        .owe => "Open (OWE, encrypted)",
        .psk => "WPA/WPA2 Personal",
        .sae => "WPA3 Personal",
        .eap => "Enterprise 802.1X",
        .wep => "WEP — not supported",
    };
}

fn paint(cv: *draw.Canvas) void {
    const t = &theme.t;
    const W = ui.W();
    const H = ui.H();
    switch (view) {
        .list => paintList(cv),
        .password => {
            ui.header(cv, target.ssid(), secLabel(target.sec), true);
            _ = ui.text(cv, "Password", PAD, 102, 13, t.menu_muted, W);
            paintWidgets(cv);
            ui.paintMsg(cv, 168);
        },
        .hidden => {
            ui.header(cv, "Other network", "", true);
            var rows: [8]FormRow = undefined;
            const n = hiddenRows(&rows);
            var y: f32 = 64;
            for (rows[0..n]) |r| {
                _ = ui.text(cv, r.label, PAD, ui.mid(y, FIELD_H, 13), 13, t.menu_muted, PAD + LABEL_W - 6);
                y += STEP;
            }
            paintWidgets(cv);
            ui.paintMsg(cv, y + 16);
        },
        .actions => {
            ui.header(cv, target.ssid(), if (target.active) "Connected" else "Saved network", true);
            paintWidgets(cv);
            ui.paintMsg(cv, 230);
        },
        .connecting => {
            ui.centered(cv, target.ssid(), W / 2, H / 2 - 18, 18, t.menu_text);
            var b: [40]u8 = undefined;
            _ = ui.text(cv, ui.dots("Connecting", ticks, &b), W / 2 - ui.textW("Connecting...", 14) / 2, H / 2 + 14, 14, t.menu_muted, W);
            paintWidgets(cv);
        },
        .done => ui.paintDone(cv, "Connected"),
    }
}

fn paintList(cv: *draw.Canvas) void {
    const t = &theme.t;
    const W = ui.W();
    const H = ui.H();
    ui.header(cv, "Wi‑Fi", "", false);
    if (!iwd_ok) {
        ui.centered(cv, "Wi‑Fi service is unavailable", W / 2, H / 2 - 8, 15, t.menu_text);
        ui.centered(cv, ui.msg(), W / 2, H / 2 + 16, 12, t.menu_muted);
        return;
    }
    if (!iwd.wifi_enabled) {
        ui.centered(cv, "Wi‑Fi is off", W / 2, H / 2, 15, t.menu_muted);
    } else if (list.n == 0) {
        ui.centered(cv, "Searching for networks…", W / 2, H / 2, 15, t.menu_muted);
    }
    paintWidgets(cv);
    ui.paintMsg(cv, H - PAD - 52);
    ui.scrollbar(cv, &list, LIST_Y, ROW_H);
}

fn paintWidgets(cv: *draw.Canvas) void {
    const t = &theme.t;
    for (ui.widgets[0..ui.nwid]) |w| {
        const hov = ui.isHover(w);
        switch (wid(w)) {
            .row => {
                const n = &nets[w.idx];
                if (list.lit(w)) ui.rect(cv, w.x, w.y, w.w, w.h, t.menu_hover);
                signal(cv, w.x + 12, w.y + (w.h - 14) / 2, n.strength, if (n.active) t.menu_accent else t.menu_text, t.menu_border);
                const name_c = if (n.active) t.menu_accent else t.menu_text;
                var right = w.x + w.w - 12;
                if (n.known) right -= 30;
                if (n.active) {
                    ui.icon(cv, &ui.ic_check, right - 16, w.y + (w.h - 16) / 2, 16, 2, t.menu_accent);
                    right -= 22;
                }
                if (n.sec != .open and n.sec != .owe) {
                    ui.icon(cv, &ui.ic_lock, right - 14, w.y + (w.h - 14) / 2, 14, 1.6, t.menu_muted);
                    right -= 20;
                }
                if (n.sec == .eap) {
                    const tag = "802.1X";
                    const tw = ui.textW(tag, 11);
                    _ = ui.text(cv, tag, right - tw, ui.mid(w.y, w.h, 11), 11, t.menu_muted, ui.W());
                    right -= tw + 8;
                }
                _ = ui.text(cv, n.ssid(), w.x + 38, ui.mid(w.y, w.h, 14), 14, name_c, right - 6);
            },
            .more => {
                if (hov) ui.rect(cv, w.x, w.y, w.w, w.h, t.menu_hover);
                ui.icon(cv, &ui.ic_more, w.x + 6, w.y + 6, 16, 1, t.menu_muted);
            },
            .toggle => ui.toggle(cv, w, iwd.wifi_enabled),
            .back => ui.paintBack(cv, w),
            .other => ui.button(cv, w, "Other network…", .secondary),
            .primary => ui.button(cv, w, "Connect", .primary),
            .secondary => ui.button(cv, w, "Cancel", .secondary),
            .act_connect => ui.button(cv, w, "Connect", .primary),
            .act_disconnect => ui.button(cv, w, "Disconnect", .secondary),
            .act_forget => ui.button(cv, w, "Forget network", .danger),
            .field => {
                const fi: F = @enumFromInt(w.idx);
                ui.field(cv, w, &fields[w.idx], placeholder(fi), fi == .password and !reveal, if (view == .password) 28 else 0);
            },
            .select => ui.select(cv, w, hsec_label[hsec]),
            .eye => {
                const c = if (hov) t.menu_text else t.menu_muted;
                ui.icon(cv, &ui.ic_eye, w.x + 6, w.y + 6, 16, 1.5, c);
                if (!reveal) ui.icon(cv, &ui.ic_slash, w.x + 6, w.y + 6, 16, 1.5, c);
            },
            .none => {},
        }
    }
}

fn placeholder(f: F) []const u8 {
    return switch (f) {
        .ssid => "hidden network name",
        .password => "",
    };
}
