// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Конфиг RefursWM. Он компилируется прямо в бинарник: поправил → `zig build` → перезапустил.
//! Никакого парсинга файлов при старте и никакой перезагрузки на лету — ноль работы в рантайме.
//! Ошибка в конфиге = ошибка компиляции, а не сюрприз после входа в сессию.
//!
//! Void-Hardened-Refurs: это конфиг сборки void-hardened (docs/08, docs/12). Его собирает
//! install/build-desktop.sh из live-среды; правка = пересборка (docs/09).
const t = @import("types.zig");
const Mod = t.Mod;
const hex = t.hex;

// ------------------------------------------------------------------ вид

/// Тема при запуске; переключается хоткеем (toggle_theme).
pub const theme: t.Theme = .dark;

/// Цвета RefursWM: "#RRGGBB", только непрозрачные. Бар RefursLine их не берёт — у него свои
/// палитры в его config.zig, это две независимые настройки.
///   active     — рамка окна в фокусе
///   inactive   — рамка остальных окон
///   background — фон рабочего стола (виден, пока нет обоев)
pub const dark = t.Palette{
    .active = hex("#89b4fa"),
    .inactive = hex("#45475a"),
    .background = hex("#1e1e2e"),
};
pub const light = t.Palette{
    .active = hex("#1e66f5"),
    .inactive = hex("#bcc0cc"),
    .background = hex("#eff1f5"),
};

/// Команды при смене темы — чтобы GTK/Qt/порталы тоже стали тёмными/светлыми.
/// Запускаются напрямую (без shell). Нет программы — тихо пропускается.
pub const theme_hooks_dark = [_]t.Cmd{
    &.{ "gsettings", "set", "org.gnome.desktop.interface", "color-scheme", "prefer-dark" },
};
pub const theme_hooks_light = [_]t.Cmd{
    &.{ "gsettings", "set", "org.gnome.desktop.interface", "color-scheme", "prefer-light" },
};

/// Толщина рамки, пиксели.
pub const border: i32 = 2;
/// Зазор между окнами и от краёв экрана.
pub const gaps_in: i32 = 6;
pub const gaps_out: i32 = 10;

/// Принудительно рисовать рамки самому (SSD), чтобы приложения не рисовали свои заголовки.
pub const server_side_decorations = true;

/// Tearing: полноэкранная игра, сама попросившая об этом (vsync выключен в игре), получает кадр
/// на экран сразу, без ожидания vblank — минимальная задержка ввода. Остальные окна — всегда с vsync.
pub const allow_tearing = true;

// ------------------------------------------------------------------ раскладка

/// Режим новых рабочих столов: .dwindle (как Hyprland) или .scroll (бесконечная лента колонок).
pub const default_mode: t.Mode = .dwindle;
/// Ширина новой колонки в scroll-режиме (доля экрана) и пресеты для cycle_width.
pub const scroll_width: f32 = 0.5;
pub const scroll_widths = [_]f32{ 1.0 / 3.0, 0.5, 2.0 / 3.0, 1.0 };
/// true — колонка в фокусе всегда по центру; false — лента сдвигается минимально.
pub const scroll_center = false;

/// Фокус следует за курсором (без клика).
pub const focus_follows_mouse = true;

// ------------------------------------------------------------------ ввод

pub const xkb_layout: [*:0]const u8 = "us,ru";
pub const xkb_variant: [*:0]const u8 = "";
pub const xkb_options: [*:0]const u8 = "grp:alt_shift_toggle";
pub const repeat_rate: i32 = 35;
pub const repeat_delay: i32 = 280;

pub const touchpad_tap = true;
pub const touchpad_natural_scroll = true;
pub const touchpad_disable_while_typing = true;

/// null = тема по умолчанию (XCURSOR_THEME).
pub const cursor_theme: ?[*:0]const u8 = null;
pub const cursor_size: u32 = 24;

// ------------------------------------------------------------------ мониторы

/// Имена — из `wlr-randr` или лога RefursWM. Не перечисленные включаются в предпочтительном режиме.
pub const outputs = [_]t.OutputCfg{
    // .{ .name = "eDP-1", .scale = 1.25 },
    // .{ .name = "HDMI-A-1", .width = 2560, .height = 1440, .refresh = 144000, .x = 1920, .y = 0, .vrr = true },
};

// ------------------------------------------------------------------ правила окон

pub const rules = [_]t.Rule{
    .{ .app_id = "pavucontrol", .float = true },
    // окна песочниц (app_id «vh-sandbox[.…]» ставит vh-wlfilter, подделать нельзя) —
    // на отдельный стол 9; фокус сами не берут, полный экран сами не включают
    .{ .app_id_prefix = "vh-sandbox", .workspace = 9 },
};

// ------------------------------------------------------------------ безопасность

/// Привилегированные протоколы: снимок экрана, буфер обмена в фоне, виртуальные клавиатура/мышь,
/// гамма. Их получает ТОЛЬКО программа, которую запустил сам RefursWM (хоткей, автозапуск,
/// REFURS_STARTUP), и только если её абсолютный путь есть в этом списке: она получает свой
/// приватный сокет с нужными протоколами. Та же программа, набранная в терминале, и любой
/// вредонос под вашим пользователем этих протоколов не увидят. Программы в песочнице
/// (flatpak, сокет `wayland-N-sandbox`) не получают их никогда.
///   .screencopy    — grim, wf-recorder, OBS
///   .data_control  — история буфера (wl-paste --watch cliphist store)
///   .virtual_input — wayvnc, wtype
///   .gamma         — wlsunset, gammastep
///   .shell         — бар RefursLine: рабочие столы, заголовок окна, раскладка, тема; переключение
///                    столов, блокировка, выход (протокол refurs-shell)
pub const grants = [_]t.Grant{
    .{ .path = bar, .caps = .{ .shell = true } },
    // void-hardened: grim не ставится; снимки экрана — добавить пакет и раскомментировать
    // .{ .path = "/usr/bin/grim", .caps = .{ .screencopy = true } },
    // .{ .path = "/usr/bin/wl-paste", .caps = .{ .data_control = true } },
    // .{ .path = "/usr/bin/wayvnc", .caps = .{ .screencopy = true, .virtual_input = true } },
    // .{ .path = "/usr/bin/wlsunset", .caps = .{ .gamma = true } },
};

/// Чем блокировать экран (ext-session-lock-v1). Хоткей `.lock`. Абсолютный путь: подменить
/// локер, положив свой `swaylock` в каталог из $PATH, не выйдет.
pub const lock_command: t.Cmd = &.{"/usr/bin/swaylock"};

/// Приоритет реального времени (SCHED_RR) для композитора: курсор и кадры не тормозят, когда
/// процессор занят сборкой или игрой. Нужен лимит rtprio (см. README); без него — тихо пропускается.
/// Запущенные программы его не наследуют.
/// void-hardened: выключено. Лимит rtprio дал бы SCHED_RR любому процессу пользователя.
pub const realtime = false;

// ------------------------------------------------------------------ автозапуск

/// Бар RefursLine (github.com/FalconBinary/RefursLine). Абсолютный путь: grant выше выдаётся
/// только по нему. Нет бара — в логе строка «cannot run», хоткеи меню ничего не делают.
pub const bar = "/usr/local/bin/refursline";

pub const autostart = [_]t.Cmd{
    &.{"/usr/bin/pipewire"},
    // фильтрующий прокси для песочниц поверх сокета wayland-N-sandbox (docs/08)
    &.{"/usr/local/bin/vh-wlfilter"},
    &.{bar},
    // блокировка после 5 минут простоя и перед сном
    &.{ "/usr/bin/swayidle", "-w", "timeout", "300", "/usr/bin/swaylock -f", "before-sleep", "/usr/bin/swaylock -f" },
};

// ------------------------------------------------------------------ хоткеи

/// Главный модификатор (Super/Win). Им же: ЛКМ — перетащить окно, ПКМ — изменить размер.
pub const mod = Mod.super;
const S = mod;
const SS = mod | Mod.shift;
const SC = mod | Mod.ctrl;

pub const terminal: t.Cmd = &.{"/usr/bin/foot"};
// без бара: лаунчер fuzzel — .{ .mods = S, .key = "d", .action = .{ .spawn = &.{"fuzzel"} } }

pub const binds = [_]t.Bind{
    .{ .mods = S, .key = "Return", .action = .{ .spawn = terminal } },
    // меню бара RefursLine
    .{ .mods = S, .key = "d", .action = .{ .bar = .run } },
    .{ .mods = SS, .key = "d", .action = .{ .bar = .commands } },
    .{ .mods = S, .key = "n", .action = .{ .bar = .wifi } },
    .{ .mods = SS, .key = "n", .action = .{ .bar = .bluetooth } },
    .{ .mods = S, .key = "p", .action = .{ .bar = .wallpaper } },
    .{ .mods = S, .key = "c", .action = .{ .bar = .calendar } },
    .{ .mods = S, .key = "Escape", .action = .{ .bar = .power } },
    // перезапустить бар, если он упал (второй экземпляр сам выходит)
    .{ .mods = SC, .key = "b", .action = .{ .spawn = &.{bar} } },
    // браузер в песочнице (docs/08): доверенный профиль и одноразовый для недоверенных сайтов
    .{ .mods = S, .key = "b", .action = .{ .spawn = &.{ "/usr/local/bin/vh-browse", "trusted" } } },
    .{ .mods = SS, .key = "b", .action = .{ .spawn = &.{ "/usr/local/bin/vh-browse", "untrusted" } } },
    // флешки (optional/usb-auth): подключить только как накопитель / отключить
    .{ .mods = S, .key = "u", .action = .{ .spawn = &.{ "/usr/bin/foot", "-H", "doas", "-n", "/usr/local/sbin/vh-usb", "attach" } } },
    .{ .mods = SS, .key = "u", .action = .{ .spawn = &.{ "/usr/bin/foot", "-H", "doas", "-n", "/usr/local/sbin/vh-usb", "detach" } } },
    // яркость и звук
    .{ .mods = 0, .key = "XF86MonBrightnessUp", .action = .{ .spawn = &.{ "/usr/local/bin/vh-backlight", "+5" } } },
    .{ .mods = 0, .key = "XF86MonBrightnessDown", .action = .{ .spawn = &.{ "/usr/local/bin/vh-backlight", "-5" } } },
    .{ .mods = 0, .key = "XF86AudioRaiseVolume", .action = .{ .spawn = &.{ "/usr/bin/wpctl", "set-volume", "-l", "1.0", "@DEFAULT_AUDIO_SINK@", "5%+" } } },
    .{ .mods = 0, .key = "XF86AudioLowerVolume", .action = .{ .spawn = &.{ "/usr/bin/wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "5%-" } } },
    .{ .mods = 0, .key = "XF86AudioMute", .action = .{ .spawn = &.{ "/usr/bin/wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle" } } },
    .{ .mods = 0, .key = "XF86AudioMicMute", .action = .{ .spawn = &.{ "/usr/bin/wpctl", "set-mute", "@DEFAULT_AUDIO_SOURCE@", "toggle" } } },
    // снимок экрана в $XDG_PICTURES_DIR (grim из списка grants)
    // .{ .mods = 0, .key = "Print", .action = .{ .spawn = &.{"/usr/bin/grim"} } },
    .{ .mods = S, .key = "q", .action = .close },
    .{ .mods = SS, .key = "e", .action = .quit },
    .{ .mods = S, .key = "l", .action = .lock },

    .{ .mods = S, .key = "Left", .action = .{ .focus = .left } },
    .{ .mods = S, .key = "Right", .action = .{ .focus = .right } },
    .{ .mods = S, .key = "Up", .action = .{ .focus = .up } },
    .{ .mods = S, .key = "Down", .action = .{ .focus = .down } },
    .{ .mods = SS, .key = "Left", .action = .{ .move = .left } },
    .{ .mods = SS, .key = "Right", .action = .{ .move = .right } },
    .{ .mods = SS, .key = "Up", .action = .{ .move = .up } },
    .{ .mods = SS, .key = "Down", .action = .{ .move = .down } },
    .{ .mods = SC, .key = "Left", .action = .{ .resize = .{ -40, 0 } } },
    .{ .mods = SC, .key = "Right", .action = .{ .resize = .{ 40, 0 } } },
    .{ .mods = SC, .key = "Up", .action = .{ .resize = .{ 0, -40 } } },
    .{ .mods = SC, .key = "Down", .action = .{ .resize = .{ 0, 40 } } },

    .{ .mods = S, .key = "space", .action = .toggle_float },
    .{ .mods = S, .key = "f", .action = .fullscreen },
    .{ .mods = S, .key = "Tab", .action = .toggle_mode },
    .{ .mods = S, .key = "s", .action = .toggle_split },
    .{ .mods = S, .key = "r", .action = .cycle_width },
    .{ .mods = S, .key = "bracketleft", .action = .{ .column_merge = .left } },
    .{ .mods = S, .key = "bracketright", .action = .{ .column_merge = .right } },
    .{ .mods = S, .key = "backslash", .action = .column_expel },
    .{ .mods = SS, .key = "t", .action = .toggle_theme },
} ++ workspaceBinds();

/// Super+1..9 — рабочий стол, Super+Shift+1..9 — отправить окно туда.
fn workspaceBinds() [18]t.Bind {
    const keys = [_][:0]const u8{ "1", "2", "3", "4", "5", "6", "7", "8", "9" };
    var out: [18]t.Bind = undefined;
    for (keys, 0..) |k, i| {
        out[i * 2] = .{ .mods = S, .key = k, .action = .{ .workspace = i + 1 } };
        out[i * 2 + 1] = .{ .mods = SS, .key = k, .action = .{ .move_to_workspace = i + 1 } };
    }
    return out;
}
