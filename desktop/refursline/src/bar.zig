// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Бар RefursLine: панель на каждом мониторе и обои под ней, в одном процессе.
//!
//! Работает только в RefursWM: соединение открывает сам компоновщик (WAYLAND_SOCKET, grant
//! `.shell`), и только на нём есть refurs-shell — рабочие столы, заголовок окна, режим раскладки,
//! раскладка клавиатуры и тема приходят событиями, без опроса и без отдельного IPC-сокета.
//!
//! Нагрузка: процесс спит в ppoll и просыпается только по событиям — раз в минуту для часов, по
//! событиям ядра для Wi‑Fi/Bluetooth/батареи, по вводу и по событиям RefursWM. Кадр рисуется
//! только при изменении, и только изменившиеся элементы: остальное копируется из прошлого кадра,
//! компоновщику уходит прямоугольник каждого изменённого элемента. Пиксели обоев живут только у
//! компоновщика: после загрузки в текстуру буфер освобождается.

const std = @import("std");
const sys = @import("sys.zig");
const wl = @import("wl.zig");
const p = wl.p;
const draw = @import("draw.zig");
const status = @import("status.zig");
const battery = @import("battery.zig");
const tz = @import("tz.zig");
const ttf = @import("ttf.zig");
const img = @import("img.zig");
const broker = @import("broker.zig");
const sandbox = @import("sandbox.zig");
const theme = @import("theme.zig");
const cfg = @import("config.zig");

const MAX_BARS = 8;
const MAX_SLOTS = 16;
const MAX_HITS = 32;
const WS = 9;

const Kind = enum(u8) {
    none,
    display,
    registry,
    callback,
    compositor,
    shm,
    pool,
    buffer,
    wbuffer,
    surface,
    wsurface,
    layer_shell,
    layer_surface,
    wlayer,
    seat,
    pointer,
    output,
    cursor_mgr,
    cursor_dev,
    viewporter,
    viewport,
    frac_mgr,
    frac,
    wfrac,
    spb,
    shell,
    shell_out,
};

const Buf = struct { id: u32 = 0, busy: bool = false };
const Slot = struct { item: cfg.Item, x: f32, w: f32, stamp: u64 = 0 };
const Hit = struct { item: cfg.Item, idx: u8 = 0, x: f32, w: f32 };
const Cols = struct { x0: u32, x1: u32 };

/// Поверхность обоев одного монитора.
const Wall = struct {
    surface: u32 = 0,
    layer: u32 = 0,
    viewport: u32 = 0,
    frac: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,
    scale: u32 = 1,
    s120: u32 = 0,
    configured: bool = false,
    dirty: bool = false,
    buffer: u32 = 0,

    fn pixelSize(o: *const Wall) [2]u32 {
        if (o.s120 > 0 and o.viewport != 0) return .{ @max(1, (o.w * o.s120 + 60) / 120), @max(1, (o.h * o.s120 + 60) / 120) };
        return .{ o.w * o.scale, o.h * o.scale };
    }
};

const Bar = struct {
    used: bool = false,
    out_name: u32 = 0,
    output: u32 = 0,
    out_ver: u32 = 0,
    shell_out: u32 = 0,
    ws: u8 = 0,
    mode: u8 = 0,
    active: bool = false,

    surface: u32 = 0,
    layer: u32 = 0,
    viewport: u32 = 0,
    frac: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,
    scale: u32 = 1,
    s120: u32 = 0,
    configured: bool = false,
    dirty: bool = false,
    /// следующий кадр — целиком
    full: bool = true,
    pool: u32 = 0,
    mem: ?[*]u8 = null,
    mem_len: usize = 0,
    pw: u32 = 0,
    ph: u32 = 0,
    bufs: [2]Buf = .{ .{}, .{} },
    /// буфер содержит целый кадр (предпоследний показанный)
    valid: [2]bool = .{ false, false },
    last: ?u1 = null,
    /// столбцы, которыми последний кадр отличается от предыдущего
    dmg: [MAX_SLOTS]Cols = undefined,
    ndmg: usize = 0,
    opaque_on: bool = false,
    opaque_w: u32 = 0,
    opaque_h: u32 = 0,

    slots: [MAX_SLOTS]Slot = undefined,
    nslots: usize = 0,
    hits: [MAX_HITS]Hit = undefined,
    nhits: usize = 0,
    hover: ?Hit = null,

    wall: Wall = .{},

    fn S(b: *const Bar) f32 {
        if (b.s120 > 0 and b.viewport != 0) return @as(f32, @floatFromInt(b.s120)) / 120.0;
        return @floatFromInt(b.scale);
    }
};

var conn: wl.Conn = .{};
var kinds: [wl.MAX_IDS]Kind = @splat(.none);
var owner: [wl.MAX_IDS]u8 = @splat(0);
var bars: [MAX_BARS]Bar = undefined;

var registry: u32 = 0;
var compositor: u32 = 0;
var compositor_ver: u32 = 0;
var shm: u32 = 0;
var layer_shell: u32 = 0;
var seat: u32 = 0;
var seat_ver: u32 = 0;
var pointer: u32 = 0;
var cursor_mgr: u32 = 0;
var cursor_dev: u32 = 0;
var viewporter: u32 = 0;
var frac_mgr: u32 = 0;
var spb: u32 = 0;
var shell: u32 = 0;
var sync_done = false;
var ready = false;

var ptr_bar: ?u8 = null;
var ptr_x: f32 = 0;
var ptr_y: f32 = 0;
var scroll_acc: f32 = 0;
var last_click: [@typeInfo(cfg.Item).@"enum".field_names.len * 3]u32 = @splat(0);

// состояние от RefursWM
var occupied: u32 = 0;
var title_buf: [256]u8 = undefined;
var title_len: usize = 0;
var kb_buf: [8]u8 = undefined;
var kb_len: usize = 0;
/// пачка событий refurs-shell ещё не закончилась (done): не рисовать промежуточное состояние
var shell_pending = false;

var wifi_state: status.Wifi = .{};
var bt_state: status.Bt = .none;
var bat: battery.State = .{};
var clock_buf: [64]u8 = undefined;
var clock_len: usize = 0;
var clock_hour: u32 = 99;

var clock_timer: i32 = -1;
var poll_timer: i32 = -1;
var poll_period: u32 = 0;
var burst: u32 = 0;

// обои
var wall_dir_buf: [512]u8 = undefined;
var wall_dir: [:0]const u8 = "";
var wall_name: [256]u8 = undefined;
var wall_len: usize = 0;
var state_fd: i32 = -1;

/// Каналы с меню обоев и питания (fd 3 у меню): строки "get", "set ИМЯ", "lock", "quit".
const Chan = struct { fd: i32 = -1, menu: broker.Menu = .run };
const MAX_CHANS = 4;
var chans: [MAX_CHANS]Chan = @splat(.{});

// ================================================================= запуск

pub fn main() noreturn {
    for (&bars) |*b| b.* = .{};
    if (sys.getuid() == 0) fatal("запуск от root запрещён");
    if (!sys.lockFile("refursline.lock")) {
        sys.log("бар уже запущен", .{});
        sys.exit(0);
    }
    conn.connectSocket() catch fatal("нет WAYLAND_SOCKET: бар запускает RefursWM (autostart с grant .shell, см. README)");
    const self_fd = sys.openSelf() catch fatal("не открыть собственный файл (/proc/self/exe)");
    // broker уходит первым: у него не будет ни сокета Wayland, ни других дескрипторов бара
    if (!broker.start(self_fd)) fatal("не запустить процесс broker");
    sys.close(self_fd);

    tz.load();
    status.init();
    bat = battery.read();
    _ = ttf.load(&cfg.font_paths);
    openWallState();

    kinds[1] = .display;
    registry = create(.registry, 0);
    conn.req(1, p.wl_display, .get_registry, .{registry});
    roundtrip();
    if (compositor == 0 or shm == 0 or layer_shell == 0) fatal("нет wl_compositor/wl_shm/zwlr_layer_shell_v1");
    if (shell == 0) fatal("нет refurs-shell: бар работает только в RefursWM и только с grant .shell");
    roundtrip(); // имена и масштабы мониторов, первое состояние от RefursWM
    ready = true;
    for (&bars, 0..) |*b, i| if (b.used) setupBar(@intCast(i));

    clock_timer = sys.timerfdCreate(sys.CLOCK_REALTIME) catch fatal("timerfd");
    poll_timer = sys.timerfdCreate(sys.CLOCK_MONOTONIC) catch fatal("timerfd");
    armClock();
    _ = updateClock();
    refreshStatus(true, true);

    if (cfg.sandbox) {
        const paths = [_][:0]const u8{ "/sys", "/proc", "/usr/share/zoneinfo", "/etc/localtime", tz.path, wall_dir };
        sandbox.apply(&paths, &.{}, .{
            .ioctl = status.HCIGETDEVINFO,
            // lseek/ftruncate — файл выбранных обоев; socketpair — канал с меню; getrandom — случайные обои
            .extra = &.{ .lseek, .socketpair, .getrandom },
        });
    }

    while (true) {
        renderWalls();
        if (!shell_pending) {
            for (&bars, 0..) |*b, i| if (b.used and b.configured and b.dirty) render(@intCast(i));
        }
        conn.flush() catch fatal("запись в сокет Wayland");

        var fds: [7 + MAX_CHANS]sys.PollFd = undefined;
        fds[0] = .{ .fd = conn.fd, .events = sys.POLLIN };
        fds[1] = .{ .fd = clock_timer, .events = sys.POLLIN };
        fds[2] = .{ .fd = poll_timer, .events = sys.POLLIN };
        fds[3] = .{ .fd = status.route_fd, .events = sys.POLLIN };
        fds[4] = .{ .fd = status.uevent_fd, .events = sys.POLLIN };
        fds[5] = .{ .fd = status.mgmt_fd, .events = sys.POLLIN };
        fds[6] = .{ .fd = -1, .events = 0 };
        for (chans, 0..) |c, k| fds[7 + k] = .{ .fd = c.fd, .events = sys.POLLIN };
        _ = sys.poll(&fds, -1) catch continue;
        if (sys.tracing()) traceWake(&fds);

        if (fds[0].revents != 0) readWayland();
        if (fds[1].revents != 0) onClockTimer();
        if (fds[2].revents != 0) onPollTimer();
        if (fds[3].revents != 0 or fds[4].revents != 0) {
            const ch = status.drainEvents(fds[3].revents != 0, fds[4].revents != 0);
            refreshStatus(ch.wifi, ch.bt);
            if (ch.bat) refreshBattery();
        }
        if (fds[5].revents != 0 and status.mgmt_fd >= 0) {
            if (status.drainMgmt()) refreshStatus(false, true);
        }
        for (&chans, 0..) |*c, k| if (fds[7 + k].revents != 0 and c.fd >= 0) onChannel(c);
    }
}

fn traceWake(fds: []const sys.PollFd) void {
    const names = [_][]const u8{ " wayland", " clock", " poll", " net", " devices", " bluetooth", "", " menu", " menu", " menu", " menu" };
    var buf: [128]u8 = undefined;
    var n: usize = 0;
    for (fds, names) |f, nm| {
        if (f.revents == 0 or n + nm.len > buf.len) continue;
        @memcpy(buf[n..][0..nm.len], nm);
        n += nm.len;
    }
    sys.tracef("wakeup:{s}", .{buf[0..n]});
}

fn fatal(what: []const u8) noreturn {
    sys.say(&.{what});
    sys.exit(1);
}

fn create(kind: Kind, own: u8) u32 {
    const id = conn.newId();
    kinds[id] = kind;
    owner[id] = own;
    return id;
}

fn forget(id: *u32) void {
    if (id.* != 0) kinds[id.*] = .none;
    id.* = 0;
}

fn roundtrip() void {
    const cb = create(.callback, 0);
    conn.req(1, p.wl_display, .sync, .{cb});
    conn.flush() catch fatal("запись в сокет Wayland");
    sync_done = false;
    while (!sync_done) readWayland();
}

fn readWayland() void {
    const alive = conn.fill() catch fatal("чтение из сокета Wayland");
    if (!alive) {
        sys.log("RefursWM закрыл соединение", .{});
        sys.exit(0);
    }
    while (conn.next()) |e| dispatch(e);
}

// ================================================================= таймеры и состояние

fn armClock() void {
    const step: i64 = if (cfg.clock_format == .hms) 1 else 60;
    const now = sys.realtime();
    const next = now - @mod(now, step) + step;
    sys.timerfdArm(clock_timer, sys.TFD_TIMER_ABSTIME | sys.TFD_TIMER_CANCEL_ON_SET, next, @intCast(step)) catch {};
}

/// Запасной опрос — только для того, о чём ядро не сообщает событием: несколько секунд после
/// переключения радио (не всякий драйвер шлёт событие) и системы без netlink. Уровень сигнала
/// Wi‑Fi и батарея перечитываются с минутным тиком часов — отдельных пробуждений нет.
fn pollPeriod() u32 {
    if (burst > 0) return 1;
    if (!status.events()) return 30;
    if (bt_state != .none and !status.btEvents()) return 30;
    return 0;
}

fn armPoll() void {
    const s = pollPeriod();
    if (s == poll_period) return;
    poll_period = s;
    sys.timerfdArm(poll_timer, 0, s, s) catch {};
}

fn drainTimer(fd: i32) bool {
    var exp: [8]u8 = undefined;
    _ = sys.read(fd, &exp) catch return sys.last_errno == sys.ECANCELED;
    return false;
}

fn onClockTimer() void {
    if (drainTimer(clock_timer)) armClock();
    if (updateClock()) markAll(false);
    if (wifi_state.state == .connected) {
        const lvl = status.signalLevel();
        if (lvl != wifi_state.level) {
            wifi_state.level = lvl;
            markAll(false);
        }
    }
    refreshBattery();
}

fn onPollTimer() void {
    _ = drainTimer(poll_timer);
    if (burst > 0) burst -= 1;
    refreshStatus(true, true);
}

fn refreshStatus(do_wifi: bool, do_bt: bool) void {
    var changed = false;
    if (do_wifi) {
        const w = status.wifi();
        if (w.state != wifi_state.state or w.level != wifi_state.level) changed = true;
        wifi_state = w;
    }
    if (do_bt) {
        const b = status.bluetooth();
        if (b != bt_state) changed = true;
        bt_state = b;
    }
    if (changed) markAll(false);
    armPoll();
}

fn refreshBattery() void {
    const b = battery.read();
    if (b.eql(bat)) return;
    // появилась или пропала батарея — меняется раскладка панели
    const relayout = b.present != bat.present;
    bat = b;
    markAll(relayout);
}

fn two(buf: []u8, v: u32) void {
    buf[0] = '0' + @as(u8, @intCast((v / 10) % 10));
    buf[1] = '0' + @as(u8, @intCast(v % 10));
}

const wshort = [_][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
const months = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };

fn updateClock() bool {
    var t = tz.now();
    if (t.hour != clock_hour) {
        // часовой пояс перечитывается раз в час (смена пояса, обновление tzdata)
        if (clock_hour != 99) {
            tz.load();
            t = tz.now();
        }
        clock_hour = t.hour;
    }
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    if (cfg.clock_format == .full) {
        if (ttf.font != null) {
            const d = std.fmt.bufPrint(&buf, "{s}, {d} {s} {d}  ", .{ wshort[t.wday % 7], t.day, months[(t.month -% 1) % 12], t.year }) catch "";
            n = d.len;
        } else {
            two(buf[0..], t.day);
            buf[2] = '.';
            two(buf[3..], t.month);
            buf[5] = '.';
            const y = std.fmt.bufPrint(buf[6..], "{d}  ", .{t.year}) catch "";
            n = 6 + y.len;
        }
    }
    if (cfg.clock_format == .date_hm) {
        two(buf[0..], t.day);
        buf[2] = '.';
        two(buf[3..], t.month);
        buf[5] = ' ';
        buf[6] = ' ';
        n = 7;
    }
    two(buf[n..], t.hour);
    buf[n + 2] = ':';
    two(buf[n + 3 ..], t.min);
    n += 5;
    if (cfg.clock_format == .hms) {
        buf[n] = ':';
        two(buf[n + 1 ..], t.sec);
        n += 3;
    }
    if (n == clock_len and std.mem.eql(u8, buf[0..n], clock_buf[0..n])) return false;
    @memcpy(clock_buf[0..n], buf[0..n]);
    clock_len = n;
    return true;
}

fn clockText() []const u8 {
    return clock_buf[0..clock_len];
}

fn fontPx(size: f32, S: f32) u16 {
    return @intFromFloat(@round(size * S));
}

/// Размер шрифта часов: цифры примерно text_size высотой.
fn clockFontSize(S: f32) u16 {
    return @intFromFloat(@round(cfg.text_size * 1.3 * S));
}

fn clockWidth(S: f32) f32 {
    if (ttf.font != null) return ttf.width(clockText(), clockFontSize(S)) / S;
    return draw.textWidth(clockText(), cfg.text_size);
}

/// Что-то показанное изменилось. relayout — могли поменяться размеры элементов.
fn markAll(relayout: bool) void {
    for (&bars) |*b| if (b.used) {
        b.dirty = true;
        if (relayout) b.full = true;
    };
}

// ================================================================= события Wayland

fn dispatch(e: wl.Event) void {
    if (e.obj >= wl.MAX_IDS) return;
    var a = e.args;
    const own = owner[e.obj];
    switch (kinds[e.obj]) {
        .display => switch (wl.ev(p.wl_display, e.op)) {
            .@"error" => {
                const obj = a.uint();
                const code = a.uint();
                sys.log("ошибка протокола (объект {d}, код {d}): {s}", .{ obj, code, a.string() });
                sys.exit(1);
            },
            .delete_id => {
                const id = a.uint();
                if (id < wl.MAX_IDS) kinds[id] = .none;
                conn.releaseId(id);
            },
            else => {},
        },
        .registry => switch (wl.ev(p.wl_registry, e.op)) {
            .global => {
                const name = a.uint();
                const iface = a.string();
                const ver = a.uint();
                onGlobal(name, iface, ver);
            },
            .global_remove => onGlobalRemove(a.uint()),
            else => {},
        },
        .callback => if (wl.ev(p.wl_callback, e.op) == .done) {
            sync_done = true;
        },
        .seat => if (wl.ev(p.wl_seat, e.op) == .capabilities) onSeatCaps(a.uint()),
        .pointer => onPointer(e.op, &a),
        .output => if (wl.ev(p.wl_output, e.op) == .scale and compositor_ver < 6) {
            const s = a.int();
            setScale(own, s);
            setWallScale(own, s);
        },
        .surface => if (wl.ev(p.wl_surface, e.op) == .preferred_buffer_scale) setScale(own, a.int()),
        .wsurface => if (wl.ev(p.wl_surface, e.op) == .preferred_buffer_scale) setWallScale(own, a.int()),
        .frac => if (wl.ev(p.wp_fractional_scale_v1, e.op) == .preferred_scale) {
            const s = std.math.clamp(a.uint(), 60, 480);
            const b = &bars[own];
            if (s != b.s120) {
                b.s120 = s;
                b.dirty = true;
                b.full = true;
            }
        },
        .wfrac => if (wl.ev(p.wp_fractional_scale_v1, e.op) == .preferred_scale) {
            const s = std.math.clamp(a.uint(), 60, 480);
            const o = &bars[own].wall;
            if (s != o.s120) {
                o.s120 = s;
                o.dirty = true;
            }
        },
        .layer_surface => onLayer(own, e.op, &a),
        .wlayer => onWallLayer(own, e.op, &a),
        .buffer => if (wl.ev(p.wl_buffer, e.op) == .release) {
            bars[own / 2].bufs[own % 2].busy = false;
        },
        .wbuffer => if (wl.ev(p.wl_buffer, e.op) == .release) {
            // компоновщик загрузил обои в текстуру: буфер больше не нужен ни ему, ни нам
            conn.req(e.obj, p.wl_buffer, .destroy, .{});
            kinds[e.obj] = .none;
            if (bars[own].wall.buffer == e.obj) bars[own].wall.buffer = 0;
        },
        .shell => onShell(e.op, &a),
        .shell_out => onShellOut(own, e.op, &a),
        else => {},
    }
}

fn bind(name: u32, iface: []const u8, ver: u32, kind: Kind, own: u8) u32 {
    const id = create(kind, own);
    conn.req(registry, p.wl_registry, .bind, .{ name, wl.str(iface), ver, id });
    return id;
}

fn onGlobal(name: u32, iface: []const u8, ver: u32) void {
    const eql = std.mem.eql;
    if (eql(u8, iface, p.wl_compositor.name) and compositor == 0) {
        compositor_ver = @min(ver, 6);
        compositor = bind(name, iface, compositor_ver, .compositor, 0);
    } else if (eql(u8, iface, p.wl_shm.name) and shm == 0) {
        shm = bind(name, iface, 1, .shm, 0);
    } else if (eql(u8, iface, p.zwlr_layer_shell_v1.name) and layer_shell == 0) {
        layer_shell = bind(name, iface, @min(ver, 3), .layer_shell, 0);
    } else if (eql(u8, iface, p.wl_seat.name) and seat == 0) {
        seat_ver = @min(ver, 5);
        seat = bind(name, iface, seat_ver, .seat, 0);
    } else if (eql(u8, iface, p.wp_cursor_shape_manager_v1.name) and cursor_mgr == 0) {
        cursor_mgr = bind(name, iface, 1, .cursor_mgr, 0);
        if (pointer != 0 and cursor_dev == 0) makeCursorDevice();
    } else if (eql(u8, iface, p.wp_viewporter.name) and viewporter == 0) {
        viewporter = bind(name, iface, 1, .viewporter, 0);
    } else if (eql(u8, iface, p.wp_fractional_scale_manager_v1.name) and frac_mgr == 0) {
        frac_mgr = bind(name, iface, 1, .frac_mgr, 0);
    } else if (eql(u8, iface, p.wp_single_pixel_buffer_manager_v1.name) and spb == 0) {
        spb = bind(name, iface, 1, .spb, 0);
    } else if (eql(u8, iface, p.zrefurs_shell_v1.name) and shell == 0) {
        shell = bind(name, iface, 1, .shell, 0);
        shell_pending = true; // всё состояние придёт пачкой до done
    } else if (eql(u8, iface, p.wl_output.name)) {
        for (&bars, 0..) |*b, i| {
            if (b.used) continue;
            const idx: u8 = @intCast(i);
            b.* = .{ .used = true, .out_name = name, .out_ver = @min(ver, 4) };
            b.output = bind(name, iface, b.out_ver, .output, idx);
            if (ready) setupBar(idx);
            break;
        }
    }
}

fn onGlobalRemove(name: u32) void {
    for (&bars, 0..) |*b, i| if (b.used and b.out_name == name) destroyBar(@intCast(i));
}

fn onSeatCaps(caps: u32) void {
    const has_pointer = caps & 1 != 0;
    if (has_pointer and pointer == 0) {
        pointer = create(.pointer, 0);
        conn.req(seat, p.wl_seat, .get_pointer, .{pointer});
        if (cursor_mgr != 0) makeCursorDevice();
    } else if (!has_pointer and pointer != 0) {
        if (cursor_dev != 0) conn.req(cursor_dev, p.wp_cursor_shape_device_v1, .destroy, .{});
        forget(&cursor_dev);
        if (seat_ver >= 3) conn.req(pointer, p.wl_pointer, .release, .{});
        forget(&pointer);
        ptr_bar = null;
    }
}

fn makeCursorDevice() void {
    cursor_dev = create(.cursor_dev, 0);
    conn.req(cursor_mgr, p.wp_cursor_shape_manager_v1, .get_pointer, .{ cursor_dev, pointer });
}

fn setScale(own: u8, s: i32) void {
    const b = &bars[own];
    const v: u32 = @intCast(std.math.clamp(s, 1, 4));
    if (v != b.scale) {
        b.scale = v;
        b.dirty = true;
        b.full = true;
    }
}

fn setWallScale(own: u8, s: i32) void {
    const o = &bars[own].wall;
    const v: u32 = @intCast(std.math.clamp(s, 1, 4));
    if (v != o.scale) {
        o.scale = v;
        o.dirty = true;
    }
}

fn onLayer(own: u8, op: u16, a: *wl.Args) void {
    const b = &bars[own];
    switch (wl.ev(p.zwlr_layer_surface_v1, op)) {
        .configure => {
            const serial = a.uint();
            const w = a.uint();
            const h = a.uint();
            conn.req(b.layer, p.zwlr_layer_surface_v1, .ack_configure, .{serial});
            const nw: u32 = if (w > 0) @min(w, 16384) else 1280;
            const nh: u32 = if (h > 0) @min(h, 512) else cfg.height;
            // тот же размер (RefursWM пересчитывает слои при каждом новом слое): кадр не нужен,
            // хватит пустого commit, чтобы ack вступил в силу
            if (b.configured and nw == b.w and nh == b.h) {
                conn.req(b.surface, p.wl_surface, .commit, .{});
                return;
            }
            b.w = nw;
            b.h = nh;
            b.configured = true;
            b.dirty = true;
            b.full = true;
        },
        .closed => destroyBar(own),
        else => {},
    }
}

// ---------------------------------------------------------------- refurs-shell

fn onShell(op: u16, a: *wl.Args) void {
    shell_pending = true;
    switch (wl.ev(p.zrefurs_shell_v1, op)) {
        .workspaces => {
            occupied = a.uint();
            markAll(cfg.hide_empty_ws);
        },
        .focus => {
            const t = a.string();
            title_len = cleanText(&title_buf, t);
            markAll(false);
        },
        .keyboard_layout => {
            _ = a.uint();
            const n = a.string();
            kb_len = 0;
            for (n) |c| {
                if (kb_len == kb_buf.len) break;
                if (!std.ascii.isAlphanumeric(c)) continue;
                kb_buf[kb_len] = std.ascii.toUpper(c);
                kb_len += 1;
            }
            markAll(false);
        },
        .theme => {
            const old_bg = theme.t.wallpaper;
            theme.set(a.uint() != 0);
            markAll(true);
            // поля обоев в режиме .fit — цвет wallpaper из темы бара
            if (cfg.wallpaper_mode == .fit and theme.t.wallpaper != old_bg) for (&bars) |*b| {
                if (b.used and b.wall.surface != 0) b.wall.dirty = true;
            };
        },
        .open => openMenu(a.uint()),
        .done => shell_pending = false,
        else => {},
    }
}

fn onShellOut(own: u8, op: u16, a: *wl.Args) void {
    shell_pending = true;
    const b = &bars[own];
    switch (wl.ev(p.zrefurs_shell_output_v1, op)) {
        .workspace => {
            b.ws = @intCast(@min(a.uint(), WS - 1));
            // активный стол шире: раскладка этой панели меняется, другие показывают «занят там»
            markAll(true);
        },
        .mode => {
            b.mode = @intCast(@min(a.uint(), 1));
            b.dirty = true;
        },
        .active => {
            b.active = a.uint() != 0;
            b.dirty = true;
        },
        else => {},
    }
}

/// Строка от компоновщика ещё раз: только целые символы UTF-8, без управляющих (компоновщик уже
/// чистит, но бар не доверяет никому).
fn cleanText(out: []u8, src: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < src.len) {
        const k = std.unicode.utf8ByteSequenceLength(src[i]) catch {
            i += 1;
            continue;
        };
        if (i + k > src.len) break;
        const ch = src[i..][0..k];
        const cp = std.unicode.utf8Decode(ch) catch {
            i += 1;
            continue;
        };
        i += k;
        if (cp < 0x20 or (cp >= 0x7f and cp < 0xa0)) continue;
        if (n + k > out.len) break;
        @memcpy(out[n..][0..k], ch);
        n += k;
    }
    return n;
}

// ---------------------------------------------------------------- указатель

fn barBySurface(id: u32) ?u8 {
    for (&bars, 0..) |*b, i| if (b.used and b.surface == id) return @intCast(i);
    return null;
}

fn onPointer(op: u16, a: *wl.Args) void {
    switch (wl.ev(p.wl_pointer, op)) {
        .enter => {
            const serial = a.uint();
            const surf = a.uint();
            ptr_x = a.fixed();
            ptr_y = a.fixed();
            ptr_bar = barBySurface(surf);
            if (cursor_dev != 0) conn.req(cursor_dev, p.wp_cursor_shape_device_v1, .set_shape, .{ serial, p.wp_cursor_shape_device_v1.shape.default });
            updateHover();
        },
        .leave => {
            if (ptr_bar) |i| setHover(i, null);
            ptr_bar = null;
        },
        .motion => {
            _ = a.uint();
            ptr_x = a.fixed();
            ptr_y = a.fixed();
            updateHover();
        },
        .button => {
            _ = a.uint();
            const time = a.uint();
            const button = a.uint();
            const state = a.uint();
            if (state == 1) if (ptr_bar) |i| click(i, button, time);
        },
        .axis => {
            _ = a.uint();
            const axis = a.uint();
            const v = a.fixed();
            if (axis == 0) if (ptr_bar) |i| wheel(i, v);
        },
        else => {},
    }
}

fn hitAt(b: *const Bar, x: f32) ?Hit {
    for (b.hits[0..b.nhits]) |h| if (x >= h.x and x < h.x + h.w) return h;
    return null;
}

fn sameHit(a: ?Hit, b: ?Hit) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.item == b.?.item and a.?.idx == b.?.idx;
}

fn setHover(i: u8, h: ?Hit) void {
    if (!cfg.hover_effect) return;
    const b = &bars[i];
    if (sameHit(b.hover, h)) return;
    b.hover = h;
    b.dirty = true;
}

fn clickable(item: cfg.Item) bool {
    return switch (item) {
        .title, .layout, .battery => false,
        else => true,
    };
}

fn updateHover() void {
    const i = ptr_bar orelse return;
    const h = hitAt(&bars[i], ptr_x);
    setHover(i, if (h != null and clickable(h.?.item)) h else null);
}

const BTN_LEFT = 0x110;
const BTN_RIGHT = 0x111;

fn click(i: u8, button: u32, time: u32) void {
    const b = &bars[i];
    const h = hitAt(b, ptr_x) orelse return;
    const right = switch (button) {
        BTN_LEFT => false,
        BTN_RIGHT => true,
        else => return,
    };
    if (h.item == .workspaces) {
        if (!right and b.shell_out != 0) conn.req(b.shell_out, p.zrefurs_shell_output_v1, .workspace, .{@as(u32, h.idx)});
        return;
    }
    if (h.item == .mode) {
        if (b.shell_out != 0) conn.req(b.shell_out, p.zrefurs_shell_output_v1, .toggle_mode, .{});
        return;
    }
    // защита от двойного клика: одно действие не чаще раза в 400 мс
    const slot = @as(usize, @intFromEnum(h.item)) * 3 + @intFromBool(right);
    if (last_click[slot] != 0 and time -% last_click[slot] < 400) return;
    last_click[slot] = time;
    switch (h.item) {
        .launcher => open(if (right) .commands else .run),
        .clock => if (!right) open(.calendar),
        .wifi => {
            open(if (right) .wifi_toggle else .wifi);
            if (right) startBurst();
        },
        .bluetooth => {
            open(if (right) .bt_toggle else .bluetooth);
            if (right or !status.btEvents()) startBurst();
        },
        .wallpaper => if (right) randomWallpaper() else open(.wallpaper),
        .power => if (right) conn.req(shell, p.zrefurs_shell_v1, .lock, .{}) else open(.power),
        else => {},
    }
}

/// Не каждое переключение радио приходит событием: несколько секунд проверяем чаще.
fn startBurst() void {
    burst = 6;
    armPoll();
}

fn wheel(i: u8, v: f32) void {
    scroll_acc += v;
    if (@abs(scroll_acc) < 15.0) return;
    const dir: i32 = if (scroll_acc > 0) 1 else -1;
    scroll_acc = 0;
    const b = &bars[i];
    const h = hitAt(b, ptr_x) orelse return;
    if (h.item != .workspaces or b.shell_out == 0) return;
    conn.req(b.shell_out, p.zrefurs_shell_output_v1, .cycle, .{dir});
}

// ---------------------------------------------------------------- меню

fn openMenu(m: u32) void {
    const s = p.zrefurs_shell_v1.menu;
    open(switch (m) {
        s.run => .run,
        s.commands => .commands,
        s.wifi => .wifi,
        s.bluetooth => .bluetooth,
        s.wallpaper => .wallpaper,
        s.power => .power,
        s.calendar => .calendar,
        else => return,
    });
}

/// Меню запускает broker. Обоям и питанию нужен канал к бару: пара сокетов, один конец
/// становится fd 3 меню, другой бар слушает. Повторное открытие закрывает меню (его замок).
fn open(m: broker.Menu) void {
    const targ = theme.encode();
    var ch: i32 = -1;
    if (m == .wallpaper or m == .power) {
        const pair = sys.socketpair() catch return broker.open(m, targ, -1);
        for (&chans) |*c| if (c.fd < 0) {
            c.* = .{ .fd = pair[0], .menu = m };
            ch = pair[1];
            break;
        };
        if (ch < 0) sys.close(pair[0]); // все каналы заняты: меню без канала
        if (ch < 0) sys.close(pair[1]);
    }
    broker.open(m, targ, ch);
    sys.close(ch);
}

fn onChannel(c: *Chan) void {
    var buf: [320]u8 = undefined;
    const n = sys.read(c.fd, &buf) catch 0;
    if (n == 0) {
        sys.close(c.fd);
        c.fd = -1;
        return;
    }
    const line = std.mem.trimEnd(u8, buf[0..n], "\n");
    const eql = std.mem.eql;
    switch (c.menu) {
        .power => if (eql(u8, line, "lock")) {
            conn.req(shell, p.zrefurs_shell_v1, .lock, .{});
        } else if (eql(u8, line, "quit")) {
            conn.req(shell, p.zrefurs_shell_v1, .quit, .{});
        },
        .wallpaper => {
            var reply: [300]u8 = undefined;
            const r: []const u8 = if (eql(u8, line, "get"))
                sys.joinZ(&reply, &.{ "cur ", wall_name[0..wall_len] })
            else if (std.mem.startsWith(u8, line, "set "))
                setWallpaper(line[4..])
            else
                "err unknown command";
            _ = sys.write(c.fd, r) catch {};
        },
        else => {},
    }
}

// ================================================================= панели

fn setupBar(i: u8) void {
    const b = &bars[i];
    b.surface = create(.surface, i);
    conn.req(compositor, p.wl_compositor, .create_surface, .{b.surface});
    if (viewporter != 0 and frac_mgr != 0) {
        b.viewport = create(.viewport, i);
        conn.req(viewporter, p.wp_viewporter, .get_viewport, .{ b.viewport, b.surface });
        b.frac = create(.frac, i);
        conn.req(frac_mgr, p.wp_fractional_scale_manager_v1, .get_fractional_scale, .{ b.frac, b.surface });
    }
    b.layer = create(.layer_surface, i);
    const L = p.zwlr_layer_shell_v1.layer;
    conn.req(layer_shell, p.zwlr_layer_shell_v1, .get_layer_surface, .{ b.layer, b.surface, b.output, L.top, wl.str("refursline") });
    const LS = p.zwlr_layer_surface_v1;
    conn.req(b.layer, LS, .set_size, .{ 0, cfg.height });
    const A = LS.anchor;
    conn.req(b.layer, LS, .set_anchor, .{switch (cfg.position) {
        .top => A.top | A.left | A.right,
        .bottom => A.bottom | A.left | A.right,
    }});
    conn.req(b.layer, LS, .set_exclusive_zone, .{@as(i32, @intCast(cfg.height))});
    const top: i32 = if (cfg.position == .top) cfg.margin_edge else 0;
    const bottom: i32 = if (cfg.position == .bottom) cfg.margin_edge else 0;
    conn.req(b.layer, LS, .set_margin, .{ top, cfg.margin_side, bottom, cfg.margin_side });
    conn.req(b.surface, p.wl_surface, .commit, .{});
    if (shell != 0) {
        b.shell_out = create(.shell_out, i);
        conn.req(shell, p.zrefurs_shell_v1, .get_output, .{ b.shell_out, b.output });
        shell_pending = true;
    }
    if (wall_len > 0) setupWall(i);
}

fn freeBuffers(b: *Bar) void {
    for (&b.bufs) |*bf| {
        if (bf.id != 0) conn.req(bf.id, p.wl_buffer, .destroy, .{});
        forget(&bf.id);
        bf.busy = false;
    }
    if (b.pool != 0) conn.req(b.pool, p.wl_shm_pool, .destroy, .{});
    forget(&b.pool);
    if (b.mem) |m| sys.munmap(m, b.mem_len);
    b.mem = null;
    b.pw = 0;
    b.ph = 0;
    b.last = null;
    b.valid = .{ false, false };
}

fn destroyBar(i: u8) void {
    const b = &bars[i];
    if (!b.used) return;
    destroyWall(i);
    freeBuffers(b);
    if (b.shell_out != 0) conn.req(b.shell_out, p.zrefurs_shell_output_v1, .destroy, .{});
    forget(&b.shell_out);
    if (b.frac != 0) conn.req(b.frac, p.wp_fractional_scale_v1, .destroy, .{});
    forget(&b.frac);
    if (b.viewport != 0) conn.req(b.viewport, p.wp_viewport, .destroy, .{});
    forget(&b.viewport);
    if (b.layer != 0) conn.req(b.layer, p.zwlr_layer_surface_v1, .destroy, .{});
    forget(&b.layer);
    if (b.surface != 0) conn.req(b.surface, p.wl_surface, .destroy, .{});
    forget(&b.surface);
    if (b.output != 0 and b.out_ver >= 3) conn.req(b.output, p.wl_output, .release, .{});
    forget(&b.output);
    if (ptr_bar == i) ptr_bar = null;
    b.* = .{};
    markAll(true); // «стол показан на другом мониторе» у оставшихся
}

fn ensureBuffers(i: u8) bool {
    const b = &bars[i];
    const S = b.S();
    const pw: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(b.w)) * S));
    const ph: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(b.h)) * S));
    if (b.pool != 0 and pw == b.pw and ph == b.ph) return true;
    freeBuffers(b);
    const stride = pw * 4;
    const size: usize = @as(usize, stride) * ph;
    const total = size * 2;
    if (total == 0 or total > std.math.maxInt(i32)) return false; // wl_shm: размер пула — i32
    const fd = sys.memfd("refursline") catch return false;
    defer sys.close(fd);
    sys.ftruncate(fd, total) catch return false;
    const mem = sys.mmap(total, fd) catch return false;
    b.mem = mem;
    b.mem_len = total;
    b.pw = pw;
    b.ph = ph;
    b.pool = create(.pool, i);
    conn.req(shm, p.wl_shm, .create_pool, .{ b.pool, wl.Fd{ .fd = fd }, @as(i32, @intCast(total)) });
    conn.flush() catch fatal("запись в сокет Wayland"); // дескриптор отправлен — можно закрыть
    for (&b.bufs, 0..) |*bf, k| {
        bf.* = .{ .id = create(.buffer, i * 2 + @as(u8, @intCast(k))) };
        conn.req(b.pool, p.wl_shm_pool, .create_buffer, .{ bf.id, @as(i32, @intCast(k * size)), @as(i32, @intCast(pw)), @as(i32, @intCast(ph)), @as(i32, @intCast(stride)), p.wl_shm.format.argb8888 });
    }
    b.full = true;
    return true;
}

fn pixels(b: *const Bar, k: u1) []u32 {
    const n = @as(usize, b.pw) * b.ph;
    const px: [*]u32 = @ptrCast(@alignCast(b.mem.? + @as(usize, k) * n * 4));
    return px[0..n];
}

/// Копирует столбцы [x0, x1) всех строк из src в dst.
fn copyCols(dst: []u32, src: []const u32, w: u32, h: u32, c: Cols) void {
    var y: usize = 0;
    while (y < h) : (y += 1) {
        const o = y * w;
        @memcpy(dst[o + c.x0 .. o + c.x1], src[o + c.x0 .. o + c.x1]);
    }
}

fn render(i: u8) void {
    const b = &bars[i];
    const t0 = sys.traceStart();
    if (!ensureBuffers(i)) return;
    // Буфер последнего кадра, если компоновщик его уже отпустил (wlroots с GPU загружает shm в
    // текстуру и отпускает сразу): в нём уже последний кадр — правим только изменённое, без
    // копирования. Иначе — второй буфер, догнав его до последнего кадра.
    const reuse = b.last != null and !b.bufs[b.last.?].busy;
    const k: u1 = if (b.last) |l| (if (reuse) l else ~l) else 0;
    if (b.bufs[k].busy) return; // компоновщик ещё читает оба — дорисуем после release

    var old: [MAX_SLOTS]Slot = undefined;
    const nold = b.nslots;
    @memcpy(old[0..nold], b.slots[0..nold]);
    layout(b);
    const S = b.S();
    for (b.slots[0..b.nslots]) |*s| s.stamp = stampOf(b, s.item);

    var full = b.full or b.last == null or !b.valid[k] or nold != b.nslots;
    if (!full) for (old[0..nold], b.slots[0..b.nslots]) |o, n| {
        if (o.item != n.item or o.x != n.x or o.w != n.w) full = true;
    };

    var dmg: [MAX_SLOTS]Cols = undefined;
    var which: [MAX_SLOTS]u8 = undefined; // какой элемент в каком прямоугольнике
    var nd: usize = 0;
    if (!full) {
        for (old[0..nold], b.slots[0..b.nslots], 0..) |o, n, si| if (o.stamp != n.stamp) {
            const x0: u32 = @intFromFloat(@max(0, @floor(n.x * S) - 1));
            const x1: u32 = @intFromFloat(@min(@as(f32, @floatFromInt(b.pw)), @ceil((n.x + n.w) * S) + 1));
            if (x1 > x0) {
                dmg[nd] = .{ .x0 = x0, .x1 = x1 };
                which[nd] = @intCast(si);
                nd += 1;
            }
        };
        if (nd == 0) {
            b.dirty = false;
            return;
        }
    }

    var cv = draw.Canvas{ .px = pixels(b, k), .w = @intCast(b.pw), .h = @intCast(b.ph) };
    if (full) {
        paintBg(b, &cv);
        for (b.slots[0..b.nslots]) |*s| paintSlot(b, &cv, s.*, S);
        nd = 1;
        dmg[0] = .{ .x0 = 0, .x1 = b.pw };
    } else {
        // в чужом буфере — предпоследний кадр: догнать до последнего (его повреждения)
        if (!reuse) {
            const prev = pixels(b, b.last.?);
            for (b.dmg[0..b.ndmg]) |c| copyCols(cv.px, prev, b.pw, b.ph, c);
        }
        for (dmg[0..nd], which[0..nd]) |c, si| {
            cv.clip(@intCast(c.x0), 0, @intCast(c.x1), @intCast(b.ph));
            paintBg(b, &cv);
            // соседний элемент мог залезть в полосу на пиксель запаса — перерисовать и его край
            for (b.slots[0..b.nslots], 0..) |n, sj| {
                const nx0 = n.x * S;
                const nx1 = (n.x + n.w) * S;
                if (sj == si or (nx1 > @as(f32, @floatFromInt(c.x0)) and nx0 < @as(f32, @floatFromInt(c.x1))))
                    paintSlot(b, &cv, n, S);
            }
        }
        cv.unclip();
    }

    syncOpaque(b);
    const SF = p.wl_surface;
    conn.req(b.surface, SF, .attach, .{ b.bufs[k].id, @as(i32, 0), @as(i32, 0) });
    if (b.s120 > 0 and b.viewport != 0) {
        if (compositor_ver >= 3) conn.req(b.surface, SF, .set_buffer_scale, .{@as(i32, 1)});
        conn.req(b.viewport, p.wp_viewport, .set_destination, .{ @as(i32, @intCast(b.w)), @as(i32, @intCast(b.h)) });
    } else if (compositor_ver >= 3) conn.req(b.surface, SF, .set_buffer_scale, .{@as(i32, @intCast(b.scale))});
    for (dmg[0..nd]) |c| {
        if (compositor_ver >= 4) {
            conn.req(b.surface, SF, .damage_buffer, .{ @as(i32, @intCast(c.x0)), @as(i32, 0), @as(i32, @intCast(c.x1 - c.x0)), @as(i32, @intCast(b.ph)) });
        } else conn.req(b.surface, SF, .damage, .{ @as(i32, 0), @as(i32, 0), @as(i32, @intCast(b.w)), @as(i32, @intCast(b.h)) });
    }
    conn.req(b.surface, SF, .commit, .{});
    b.bufs[k].busy = true;
    b.valid[k] = true;
    // второй буфер отстал больше чем на один кадр: повреждений двух кадров не храним — при
    // следующем использовании он перерисуется целиком
    if (reuse) b.valid[~k] = false;
    b.last = k;
    @memcpy(b.dmg[0..nd], dmg[0..nd]);
    b.ndmg = nd;
    b.dirty = false;
    b.full = false;
    if (sys.tracing()) sys.tracef("frame {d}: {d} µs, {s} {d} areas{s}", .{ i, sys.traceSince(t0), if (full) "full" else "partial", nd, if (reuse and !full) ", same buffer" else "" });
}

/// Панель непрозрачна целиком: компоновщику — непрозрачная область, под ней он не рисует.
fn syncOpaque(b: *Bar) void {
    if (b.opaque_on and b.opaque_w == b.w and b.opaque_h == b.h) return;
    b.opaque_on = true;
    b.opaque_w = b.w;
    b.opaque_h = b.h;
    conn.setOpaque(compositor, b.surface, b.w, b.h);
}

// ================================================================= раскладка панели

fn addHit(b: *Bar, item: cfg.Item, idx: u8, x: f32, w: f32) void {
    if (b.nhits >= b.hits.len) return;
    b.hits[b.nhits] = .{ .item = item, .idx = idx, .x = x, .w = w };
    b.nhits += 1;
}

fn addSlot(b: *Bar, item: cfg.Item, x: f32, w: f32) void {
    if (b.nslots >= b.slots.len) return;
    b.slots[b.nslots] = .{ .item = item, .x = x, .w = w };
    b.nslots += 1;
}

/// Стол n показан на другом мониторе.
fn wsElsewhere(b: *const Bar, n: usize) bool {
    for (&bars) |*o| if (o.used and o != b and o.shell_out != 0 and o.ws == n) return true;
    return false;
}

fn wsVisible(b: *const Bar, n: usize) bool {
    if (!cfg.hide_empty_ws) return true;
    return n == b.ws or occupied & (@as(u32, 1) << @intCast(n)) != 0 or wsElsewhere(b, n);
}

fn batteryTextW() f32 {
    return if (ttf.font != null) ttf.width("100%", fontPx(cfg.text_size, 1)) + 4 else 0;
}

fn itemWidth(b: *const Bar, item: cfg.Item) f32 {
    return switch (item) {
        .workspaces => blk: {
            var w: f32 = 0;
            for (0..WS) |n| {
                if (!wsVisible(b, n)) continue;
                w += if (n == b.ws) cfg.ws_active else cfg.ws_dot;
            }
            break :blk w;
        },
        .title => if (ttf.font != null) cfg.title_width else 0,
        .clock => clockWidth(b.S()) + 16,
        .layout => if (ttf.font != null and kb_len > 0) 30 else 0,
        .battery => if (bat.present) cfg.button + batteryTextW() else 0,
        else => cfg.button,
    };
}

fn place(b: *Bar, item: cfg.Item, x0: f32, w: f32) void {
    addSlot(b, item, x0, w);
    if (item == .workspaces) {
        var x = x0;
        for (0..WS) |n| {
            if (!wsVisible(b, n)) continue;
            const cw = if (n == b.ws) cfg.ws_active else cfg.ws_dot;
            addHit(b, .workspaces, @intCast(n), x, cw);
            x += cw;
        }
    } else addHit(b, item, 0, x0, w);
}

fn layout(b: *Bar) void {
    b.nslots = 0;
    b.nhits = 0;
    const W: f32 = @floatFromInt(b.w);
    // центр: сначала, чтобы заголовок слева знал, где остановиться
    var cw: f32 = 0;
    for (cfg.center) |it| cw += itemWidth(b, it);
    const cx0 = (W - cw) / 2;
    var cx = cx0;
    for (cfg.center) |it| {
        const w = itemWidth(b, it);
        if (w == 0) continue;
        place(b, it, cx, w);
        cx += w;
    }
    var rx: f32 = W - cfg.padding;
    for (0..cfg.right.len) |k| {
        const it = cfg.right[cfg.right.len - 1 - k];
        const w = itemWidth(b, it);
        if (w == 0) continue;
        rx -= w;
        place(b, it, rx, w);
        rx -= cfg.spacing;
    }
    var x: f32 = cfg.padding;
    const limit = if (cfg.center.len > 0) cx0 - 12 else rx - 12;
    for (cfg.left) |it| {
        var w = itemWidth(b, it);
        if (it == .title) w = @min(w, limit - x);
        if (w <= 0) continue;
        place(b, it, x, w);
        x += w + cfg.spacing * 3;
    }
}

// ================================================================= отрисовка

/// Отпечаток всего, от чего зависит вид элемента: изменился — элемент перерисовывается.
fn stampOf(b: *const Bar, item: cfg.Item) u64 {
    var h = std.hash.Wyhash.init(@intFromEnum(item));
    if (b.hover) |hv| if (hv.item == item) h.update(std.mem.asBytes(&hv.idx));
    if (b.hover != null and b.hover.?.item == item) h.update("h");
    switch (item) {
        .workspaces => {
            h.update(std.mem.asBytes(&occupied));
            h.update(&.{ b.ws, @intFromBool(b.active) });
            var other: u16 = 0;
            for (0..WS) |n| if (wsElsewhere(b, n)) {
                other |= @as(u16, 1) << @intCast(n);
            };
            h.update(std.mem.asBytes(&other));
        },
        .mode => h.update(&.{b.mode}),
        .title => h.update(title_buf[0..title_len]),
        .clock => h.update(clockText()),
        .layout => h.update(kb_buf[0..kb_len]),
        .wifi => h.update(&.{ @intFromEnum(wifi_state.state), wifi_state.level }),
        .bluetooth => h.update(&.{@intFromEnum(bt_state)}),
        .battery => h.update(&.{ bat.percent, @intFromBool(bat.charging), @intFromBool(bat.full) }),
        else => {},
    }
    return h.final();
}

fn paintBg(b: *const Bar, cv: *draw.Canvas) void {
    const S = b.S();
    const W: f32 = @floatFromInt(b.pw);
    const H: f32 = @floatFromInt(b.ph);
    const c = &theme.t;
    cv.fillRect(0, 0, W, H, c.background);
    if (cfg.border_width > 0) {
        const bw = cfg.border_width * S;
        const frame = [_]draw.Prim{.{ .box = .{ .x = bw / 2, .y = bw / 2, .w = W - bw, .h = H - bw, .r = 0 } }};
        cv.prims(&frame, 0, 0, 1, bw, c.border);
    }
}

fn paintSlot(b: *const Bar, cv: *draw.Canvas, s: Slot, S: f32) void {
    const c = &theme.t;
    const H: f32 = @floatFromInt(b.h);
    const by = (H - cfg.button) / 2;
    if (cfg.hover_effect) if (b.hover) |hv| if (hv.item == s.item and s.item != .workspaces)
        cv.fillRect(s.x * S, by * S, s.w * S, cfg.button * S, c.hover);
    switch (s.item) {
        .workspaces => paintWorkspaces(b, cv, S, by),
        .clock => {
            const tw = clockWidth(S);
            const x = @round((s.x + (s.w - tw) / 2) * S);
            const y = @round((H - cfg.text_size) / 2 * S);
            if (ttf.font != null) {
                _ = ttf.drawText(cv, clockText(), x, y + cfg.text_size * S, clockFontSize(S), c.clock, (s.x + s.w) * S);
            } else draw.text(cv, clockText(), x, y, cfg.text_size * S, c.clock);
        },
        .title => paintTitle(cv, s, H, S),
        .layout => {
            const fs = fontPx(cfg.text_size, S);
            const t = kb_buf[0..kb_len];
            const tw = ttf.width(t, fs) / S;
            _ = ttf.drawText(cv, t, @round((s.x + (s.w - tw) / 2) * S), @round(baseline(H) * S), fs, c.icon, (s.x + s.w) * S);
        },
        .battery => paintBattery(cv, s, H, S),
        else => paintIcon(b, cv, s, by, S),
    }
}

fn baseline(H: f32) f32 {
    return H / 2 + cfg.text_size * 0.36;
}

fn paintWorkspaces(b: *const Bar, cv: *draw.Canvas, S: f32, by: f32) void {
    const c = &theme.t;
    for (b.hits[0..b.nhits]) |h| {
        if (h.item != .workspaces) continue;
        const n = h.idx;
        if (cfg.hover_effect) if (b.hover) |hv| if (hv.item == .workspaces and hv.idx == n)
            cv.fillRect(h.x * S, by * S, h.w * S, cfg.button * S, c.hover);
        const cx = (h.x + h.w / 2) * S;
        const cy = (by + cfg.button / 2) * S;
        const occ = occupied & (@as(u32, 1) << @intCast(n)) != 0;
        if (n == b.ws) {
            const pw = (h.w - 10) * S;
            const ph = 7 * S;
            cv.fillRect(cx - pw / 2, cy - ph / 2, pw, ph, if (b.active) c.ws_active else c.ws_other);
        } else {
            const other = wsElsewhere(b, n);
            const col = if (other) c.ws_other else if (occ) c.ws_occupied else c.ws_empty;
            const d: f32 = (if (occ or other) @as(f32, 7) else 5.5) * S;
            cv.fillRect(cx - d / 2, cy - d / 2, d, d, col);
        }
    }
}

const ELLIPSIS = "\u{2026}";

/// Заголовок окна; длинный — обрезан по границе символа с многоточием.
fn paintTitle(cv: *draw.Canvas, s: Slot, H: f32, S: f32) void {
    if (title_len == 0) return;
    const fs = fontPx(cfg.text_size, S);
    const t = title_buf[0..title_len];
    const avail = (s.w - 8) * S;
    const x = @round((s.x + 4) * S);
    const y = @round(baseline(H) * S);
    if (ttf.width(t, fs) <= avail) {
        _ = ttf.drawText(cv, t, x, y, fs, theme.t.title, (s.x + s.w) * S);
        return;
    }
    const room = avail - ttf.width(ELLIPSIS, fs);
    // ширина префикса растёт с длиной: двоичный поиск по границам символов
    var lo: usize = 0;
    var hi: usize = t.len;
    while (lo < hi) {
        var mid = (lo + hi + 1) / 2;
        while (mid > lo and mid < t.len and t[mid] & 0xc0 == 0x80) mid -= 1;
        if (mid == lo) break;
        if (ttf.width(t[0..mid], fs) <= room) lo = mid else hi = mid - 1;
    }
    const end = ttf.drawText(cv, t[0..lo], x, y, fs, theme.t.title, (s.x + s.w) * S);
    _ = ttf.drawText(cv, ELLIPSIS, end, y, fs, theme.t.title, (s.x + s.w) * S);
}

fn paintBattery(cv: *draw.Canvas, s: Slot, H: f32, S: f32) void {
    const c = &theme.t;
    const by = (H - cfg.button) / 2;
    const ox = @round((s.x + (cfg.button - cfg.icon) / 2) * S);
    const oy = @round((by + (cfg.button - cfg.icon) / 2) * S);
    const sc = cfg.icon / 16.0 * S;
    const st = cfg.icon_stroke * S;
    const low = bat.percent <= cfg.battery_low and !bat.charging;
    const col = if (bat.charging) c.charging else if (low) c.off else c.battery;
    cv.icon(&draw.icon_battery, ox, oy, sc, st, col);
    // уровень: внутри корпуса 1..13.5 × 4.5..11.5 по сетке 16×16
    const fw = 10.0 * @as(f32, @floatFromInt(bat.percent)) / 100.0;
    if (fw > 0.3) cv.fillRect(ox + 2.25 * sc, oy + 5.75 * sc, fw * sc, 4.5 * sc, col);
    if (bat.charging) cv.icon(&draw.icon_bolt, ox, oy, sc, st, c.background | 0xff000000);
    if (ttf.font == null) return;
    var tb: [8]u8 = undefined;
    const t = std.fmt.bufPrint(&tb, "{d}%", .{bat.percent}) catch return;
    const fs = fontPx(cfg.text_size, S);
    _ = ttf.drawText(cv, t, @round((s.x + cfg.button) * S), @round(baseline(H) * S), fs, col, (s.x + s.w) * S);
}

fn paintIcon(b: *const Bar, cv: *draw.Canvas, s: Slot, by: f32, S: f32) void {
    const c = &theme.t;
    const sc = cfg.icon / 16.0 * S;
    const ox = @round((s.x + (s.w - cfg.icon) / 2) * S);
    const oy = @round((by + (cfg.button - cfg.icon) / 2) * S);
    const st = cfg.icon_stroke * S;
    switch (s.item) {
        .launcher => cv.icon(&draw.icon_apps, ox, oy, sc, st, c.icon),
        .wallpaper => cv.icon(&draw.icon_wall, ox, oy, sc, st, c.icon),
        .power => cv.icon(&draw.icon_power, ox, oy, sc, st, c.power),
        .mode => cv.icon(if (b.mode == 0) &draw.icon_dwindle else &draw.icon_scroll, ox, oy, sc, st, c.icon),
        .wifi => {
            const w = wifi_state;
            const on = w.state == .connected or w.state == .disconnected;
            for (&draw.icon_wifi_arcs, 0..) |*arc, k| {
                const lit = w.state == .connected and k < w.level;
                cv.icon(arc, ox, oy, sc, st, if (lit) c.wifi else c.wifi_inactive);
            }
            cv.icon(&draw.icon_wifi_dot, ox, oy, sc, st, if (on) c.wifi else c.wifi_inactive);
            if (w.state == .off) cv.icon(&draw.icon_slash, ox, oy, sc, st, c.off);
        },
        .bluetooth => {
            const col = switch (bt_state) {
                .connected => c.bt_connected,
                .on => c.bt_on,
                .off, .none => c.bt_off,
            };
            cv.icon(&draw.icon_bt, ox, oy, sc, st, col);
            if (bt_state == .connected) cv.icon(&draw.icon_bt_dots, ox, oy, sc, st, col);
        },
        else => {},
    }
}

// ================================================================= обои

/// "~/…" → полный путь.
pub fn expandHome(buf: []u8, path: []const u8) ?[:0]const u8 {
    if (std.mem.startsWith(u8, path, "~/")) {
        const home = sys.getenv("HOME") orelse return null;
        return sys.joinZ(buf, &.{ home, path[1..] });
    }
    return sys.joinZ(buf, &.{path});
}

/// Только имя файла в каталоге обоев: без "/", не скрытый, без управляющих символов.
pub fn validName(n: []const u8) bool {
    if (n.len == 0 or n.len > 255 or n[0] == '.') return false;
    for (n) |c| if (c == '/' or c < 0x20 or c == 0x7f) return false;
    return true;
}

/// Каталог обоев и выбранный файл (~/.cache/refursline/wallpaper) — до песочницы.
fn openWallState() void {
    wall_dir = expandHome(&wall_dir_buf, cfg.wallpaper_dir) orelse "";
    const home = sys.getenv("HOME") orelse return;
    var b: [512]u8 = undefined;
    sys.mkdir(sys.joinZ(&b, &.{ home, "/.cache" }));
    sys.mkdir(sys.joinZ(&b, &.{ home, "/.cache/refursline" }));
    state_fd = sys.openCreate(sys.joinZ(&b, &.{ home, "/.cache/refursline/wallpaper" })) catch -1;
    if (state_fd < 0) return;
    const n = sys.read(state_fd, &wall_name) catch 0;
    const name = std.mem.trim(u8, wall_name[0..n], " \n\r");
    if (validName(name)) {
        std.mem.copyForwards(u8, wall_name[0..name.len], name);
        wall_len = name.len;
    }
}

fn saveWallState() void {
    if (state_fd < 0) return;
    _ = sys.lseek(state_fd, 0) catch return;
    _ = sys.write(state_fd, wall_name[0..wall_len]) catch {};
    sys.ftruncate(state_fd, wall_len) catch {};
}

fn setupWall(i: u8) void {
    const o = &bars[i].wall;
    if (o.surface != 0) return;
    o.* = .{};
    o.surface = create(.wsurface, i);
    conn.req(compositor, p.wl_compositor, .create_surface, .{o.surface});
    // пустая область ввода: обои не перехватывают указатель — пустой стол остаётся «пустым»
    // для RefursWM (активный монитор под курсором)
    const region = conn.newId();
    conn.req(compositor, p.wl_compositor, .create_region, .{region});
    conn.req(o.surface, p.wl_surface, .set_input_region, .{region});
    conn.req(region, p.wl_region, .destroy, .{});
    if (viewporter != 0) {
        o.viewport = create(.viewport, i);
        conn.req(viewporter, p.wp_viewporter, .get_viewport, .{ o.viewport, o.surface });
        if (frac_mgr != 0) {
            o.frac = create(.wfrac, i);
            conn.req(frac_mgr, p.wp_fractional_scale_manager_v1, .get_fractional_scale, .{ o.frac, o.surface });
        }
    }
    o.layer = create(.wlayer, i);
    const LS = p.zwlr_layer_surface_v1;
    conn.req(layer_shell, p.zwlr_layer_shell_v1, .get_layer_surface, .{ o.layer, o.surface, bars[i].output, p.zwlr_layer_shell_v1.layer.background, wl.str("wallpaper") });
    conn.req(o.layer, LS, .set_size, .{ 0, 0 });
    conn.req(o.layer, LS, .set_anchor, .{LS.anchor.top | LS.anchor.bottom | LS.anchor.left | LS.anchor.right});
    conn.req(o.layer, LS, .set_exclusive_zone, .{@as(i32, -1)});
    conn.req(o.surface, p.wl_surface, .commit, .{});
}

fn destroyWall(i: u8) void {
    const o = &bars[i].wall;
    if (o.surface == 0) return;
    if (o.buffer != 0) conn.req(o.buffer, p.wl_buffer, .destroy, .{});
    forget(&o.buffer);
    if (o.frac != 0) conn.req(o.frac, p.wp_fractional_scale_v1, .destroy, .{});
    forget(&o.frac);
    if (o.viewport != 0) conn.req(o.viewport, p.wp_viewport, .destroy, .{});
    forget(&o.viewport);
    if (o.layer != 0) conn.req(o.layer, p.zwlr_layer_surface_v1, .destroy, .{});
    forget(&o.layer);
    conn.req(o.surface, p.wl_surface, .destroy, .{});
    forget(&o.surface);
    o.* = .{};
}

fn onWallLayer(own: u8, op: u16, a: *wl.Args) void {
    const o = &bars[own].wall;
    switch (wl.ev(p.zwlr_layer_surface_v1, op)) {
        .configure => {
            const serial = a.uint();
            const w = a.uint();
            const h = a.uint();
            conn.req(o.layer, p.zwlr_layer_surface_v1, .ack_configure, .{serial});
            if (w > 0 and h > 0 and (w != o.w or h != o.h or !o.configured)) o.dirty = true;
            o.w = @min(@max(w, 1), 16384);
            o.h = @min(@max(h, 1), 16384);
            o.configured = true;
        },
        .closed => destroyWall(own),
        else => {},
    }
}

fn wallPath(buf: []u8) [:0]const u8 {
    return sys.joinZ(buf, &.{ wall_dir, "/", wall_name[0..wall_len] });
}

/// Одно декодирование на все мониторы под самый большой, потом память сразу возвращается.
fn renderWalls() void {
    var need_w: u32 = 0;
    var need_h: u32 = 0;
    var any = false;
    for (&bars) |*b| {
        const o = &b.wall;
        if (!b.used or o.surface == 0 or !o.configured or !o.dirty) continue;
        const ps = o.pixelSize();
        need_w = @max(need_w, ps[0]);
        need_h = @max(need_h, ps[1]);
        any = true;
    }
    if (!any or wall_len == 0) return;
    var pb: [800]u8 = undefined;
    var pic = img.load(wallPath(&pb), need_w, need_h) catch |e| {
        sys.say(&.{ "обои ", wall_name[0..wall_len], ": ", @errorName(e) });
        for (&bars) |*b| b.wall.dirty = false;
        return;
    };
    defer pic.deinit();
    for (&bars, 0..) |*b, i| {
        if (b.used and b.wall.surface != 0 and b.wall.configured and b.wall.dirty) paintWall(@intCast(i), &pic);
    }
}

fn paintWall(i: u8, pic: *const img.Image) void {
    const o = &bars[i].wall;
    o.dirty = false;
    const ps = o.pixelSize();
    const pw = ps[0];
    const ph = ps[1];
    const size: usize = @as(usize, pw) * ph * 4;
    if (size > std.math.maxInt(i32)) return;
    const fd = sys.memfd("refursline-wall") catch return;
    defer sys.close(fd);
    sys.ftruncate(fd, size) catch return;
    const mem = sys.mmap(size, fd) catch return;
    const px: [*]u32 = @ptrCast(@alignCast(mem));
    const bg = theme.t.wallpaper & 0xffffff;
    img.render(pic, px[0 .. size / 4], pw, ph, if (cfg.wallpaper_mode == .fill) .fill else .fit, bg) catch @memset(px[0 .. size / 4], 0xff000000 | bg);
    // пиксели уже в общей памяти — своё отображение сразу убрать
    sys.munmap(mem, size);

    const pool = create(.pool, i);
    conn.req(shm, p.wl_shm, .create_pool, .{ pool, wl.Fd{ .fd = fd }, @as(i32, @intCast(size)) });
    conn.flush() catch fatal("запись в сокет Wayland");
    const buf = create(.wbuffer, i);
    conn.req(pool, p.wl_shm_pool, .create_buffer, .{ buf, @as(i32, 0), @as(i32, @intCast(pw)), @as(i32, @intCast(ph)), @as(i32, @intCast(pw * 4)), p.wl_shm.format.xrgb8888 });
    conn.req(pool, p.wl_shm_pool, .destroy, .{});
    kinds[pool] = .none;

    const SF = p.wl_surface;
    conn.req(o.surface, SF, .attach, .{ buf, @as(i32, 0), @as(i32, 0) });
    if (o.s120 > 0 and o.viewport != 0) {
        if (compositor_ver >= 3) conn.req(o.surface, SF, .set_buffer_scale, .{@as(i32, 1)});
        conn.req(o.viewport, p.wp_viewport, .set_destination, .{ @as(i32, @intCast(o.w)), @as(i32, @intCast(o.h)) });
    } else if (compositor_ver >= 3) conn.req(o.surface, SF, .set_buffer_scale, .{@as(i32, @intCast(o.scale))});
    if (compositor_ver >= 4) {
        conn.req(o.surface, SF, .damage_buffer, .{ @as(i32, 0), @as(i32, 0), @as(i32, @intCast(pw)), @as(i32, @intCast(ph)) });
    } else conn.req(o.surface, SF, .damage, .{ @as(i32, 0), @as(i32, 0), @as(i32, @intCast(o.w)), @as(i32, @intCast(o.h)) });
    conn.req(o.surface, SF, .commit, .{});
    // и прошлый, и этот буфер уничтожаются, когда компоновщик их отпустит (release)
    o.buffer = buf;
}

fn errText(e: img.Error) []const u8 {
    return switch (e) {
        error.Unsupported => "err unsupported format (JPEG or PNG required)",
        error.TooLarge => "err image is too large",
        error.NoMem => "err out of memory",
        error.Io => "err cannot open the file",
        error.Invalid => "err the file is corrupted",
    };
}

/// Сменить обои. Сначала декодирование (под самый большой монитор, один раз): битый файл не
/// испортит текущие. Ответ — для меню обоев.
fn setWallpaper(name: []const u8) []const u8 {
    if (!validName(name)) return "err invalid file name";
    var pb: [800]u8 = undefined;
    const path = sys.joinZ(&pb, &.{ wall_dir, "/", name });
    var need: [2]u32 = .{ 0, 0 };
    for (&bars) |*b| if (b.used and b.wall.surface != 0 and b.wall.configured) {
        const ps = b.wall.pixelSize();
        need = .{ @max(need[0], ps[0]), @max(need[1], ps[1]) };
    };
    // поверхностей обоев ещё нет (первые обои): проверить файл маленьким декодом
    var pic = img.load(path, @max(need[0], 64), @max(need[1], 64)) catch |e| return errText(e);
    defer pic.deinit();
    @memcpy(wall_name[0..name.len], name);
    wall_len = name.len;
    saveWallState();
    for (&bars, 0..) |*b, i| if (b.used) {
        if (b.wall.surface == 0) {
            setupWall(@intCast(i));
        } else if (b.wall.configured and need[0] > 0) {
            paintWall(@intCast(i), &pic);
        } else b.wall.dirty = true;
    };
    return "ok";
}

fn isImage(n: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, n, '.') orelse return false;
    const ext = n[dot + 1 ..];
    return std.ascii.eqlIgnoreCase(ext, "jpg") or std.ascii.eqlIgnoreCase(ext, "jpeg") or std.ascii.eqlIgnoreCase(ext, "png");
}

/// ПКМ по значку обоев: случайный файл из каталога, не текущий.
fn randomWallpaper() void {
    var d = sys.Dir.open(wall_dir) orelse return;
    defer d.deinit();
    var count: u64 = 0;
    var pick: [256]u8 = undefined;
    var pick_len: usize = 0;
    // выборка одного элемента за проход без списка в памяти (reservoir sampling)
    while (d.next()) |n| {
        if (!validName(n) or !isImage(n)) continue;
        if (std.mem.eql(u8, n, wall_name[0..wall_len])) continue;
        count += 1;
        if (sys.random() % count == 0) {
            @memcpy(pick[0..n.len], n);
            pick_len = n.len;
        }
    }
    if (pick_len == 0) return;
    const r = setWallpaper(pick[0..pick_len]);
    if (!std.mem.eql(u8, r, "ok")) sys.say(&.{ pick[0..pick_len], ": ", r });
}

test "имя обоев — только файл в каталоге" {
    const tt = std.testing;
    try tt.expect(validName("sea.jpg"));
    try tt.expect(!validName("../x.jpg"));
    try tt.expect(!validName(".hidden.png"));
    try tt.expect(!validName("a/b.png"));
    try tt.expect(!validName("a\nb.png"));
}

test "строки от компоновщика ещё раз чистятся" {
    var b: [16]u8 = undefined;
    const n = cleanText(&b, "a\x1bb\xffc\xd0\xb6xxxxxxxxxxxxxxxx");
    try std.testing.expect(n <= 16);
    try std.testing.expectEqualStrings("abc\xd0\xb6", b[0..5]);
}
