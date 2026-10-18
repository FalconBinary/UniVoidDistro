// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Настройки RefursLine. Конфиг вкомпилирован, как у RefursWM: поправил → `zig build` →
//! перезапустил бар (Super+Shift+B). Ошибка в конфиге — ошибка сборки, при старте ничего не
//! разбирается. Цвета бара — только здесь, независимо от цветов RefursWM; от RefursWM приходит
//! лишь выбор тёмной или светлой палитры (Super+Shift+T).

const hex = @import("color.zig").hex;

pub const Position = enum { top, bottom };
pub const ClockFormat = enum { hm, hms, date_hm, full };

/// Элементы панели.
pub const Item = enum {
    launcher, // лаунчер: ЛКМ — приложения, ПКМ — команды
    workspaces, // рабочие столы 1..9: клик — перейти, колесо — листать
    mode, // режим раскладки стола (dwindle/scroll): клик — переключить
    title, // заголовок окна в фокусе
    clock, // дата и время: клик — календарь
    layout, // раскладка клавиатуры (us/ru)
    wifi, // ЛКМ — меню, ПКМ — радио вкл/выкл
    bluetooth, // ЛКМ — меню, ПКМ — вкл/выкл
    battery, // заряд; скрыт, если батареи нет
    wallpaper, // ЛКМ — выбор обоев, ПКМ — случайные
    power, // ЛКМ — меню питания, ПКМ — заблокировать
};

pub const left = [_]Item{ .launcher, .workspaces, .mode, .title };
pub const center = [_]Item{.clock};
pub const right = [_]Item{ .layout, .wifi, .bluetooth, .battery, .wallpaper, .power };

// ---------------------------------------------------------------- геометрия (логические пиксели)

pub const position: Position = .top;
pub const height: u32 = 34;
pub const margin_edge: i32 = 6; // отступ от края экрана
pub const margin_side: i32 = 10; // отступы слева и справа
pub const border_width: f32 = 0; // рамка (0 — нет), цвет — border
pub const padding: f32 = 6; // внутренний отступ по краям
pub const spacing: f32 = 2; // промежуток между кнопками
pub const button: f32 = 26; // размер кнопки (область клика и подсветки)
pub const icon: f32 = 16; // размер иконки
pub const icon_stroke: f32 = 1.6; // толщина линий иконок
pub const hover_effect = true; // подсветка кнопки под курсором

/// Шрифт панели и меню — первый найденный файл (TrueType .ttf с контурами glyf; CFF/OTF нет).
/// Свой путь — первым. Моноширинные цифры (Noto Sans, DejaVu Sans) не дают часам дёргаться.
pub const font_paths = [_][]const u8{
    "/usr/share/fonts/noto/NotoSans-Regular.ttf", // Arch
    "/usr/share/fonts/TTF/DejaVuSans.ttf", // Arch, Void
    "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf", // Debian/Ubuntu
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", // Debian/Ubuntu
    "/usr/share/fonts/google-noto/NotoSans-Regular.ttf", // Fedora
    "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf", // Fedora
    "/usr/share/fonts/TTF/Inter-Regular.ttf",
};

pub const text_size: f32 = 12; // часы, заголовок, раскладка, заряд
/// .hm — 13:31, .hms — 13:31:05 (будит бар каждую секунду), .date_hm — 12.10  13:31,
/// .full — Mon, 12 October 2026  13:31
pub const clock_format: ClockFormat = .full;

pub const ws_dot: f32 = 16; // ширина ячейки стола
pub const ws_active: f32 = 30; // ширина активного стола
pub const hide_empty_ws = false; // прятать пустые неактивные столы
/// Ширина заголовка окна (часть панели, отведённая под него; длинный обрезается многоточием).
pub const title_width: f32 = 420;

/// Батарея: ниже этого процента значок красный.
pub const battery_low: u8 = 15;

// ---------------------------------------------------------------- безопасность

/// Песочница: seccomp (нет exec, новых сокетов, записи файлов) + Landlock (чтение только /sys,
/// /proc, tzdata, шрифта и каталога обоев). Программы запускает отдельный процесс-broker, и
/// только меню RefursLine. Выключать имеет смысл только для отладки.
pub const sandbox = true;

// ---------------------------------------------------------------- цвета
// Только "#RRGGBB": все цвета непрозрачные, без скруглений, прозрачности и затемнений.
// Подсветка (hover, menu_hover) — отдельный сплошной цвет, а не полупрозрачный слой.

pub const Theme = struct {
    background: u32,
    border: u32,
    hover: u32, // кнопка под курсором
    icon: u32, // лаунчер, обои, текст раскладки и заголовка
    ws_active: u32,
    ws_occupied: u32,
    ws_empty: u32,
    ws_other: u32, // стол показан на другом мониторе
    clock: u32,
    title: u32,
    wifi: u32,
    wifi_inactive: u32,
    off: u32, // зачёркнутое радио, низкий заряд
    bt_on: u32,
    bt_connected: u32,
    bt_off: u32,
    battery: u32,
    charging: u32,
    power: u32,
    // меню
    menu_background: u32,
    menu_text: u32,
    menu_muted: u32,
    menu_accent: u32, // главная кнопка, выбранное, фокус
    menu_accent_hover: u32, // главная кнопка под курсором
    menu_accent_text: u32, // текст на акцентной кнопке
    menu_field: u32, // поля ввода и второстепенные кнопки
    menu_border: u32,
    menu_hover: u32, // строка или кнопка под курсором
    menu_error: u32,
    // обои
    wallpaper: u32, // поля вокруг картинки в режиме .fit и фон, пока обоев нет
};

pub const dark = Theme{
    .background = hex("#1e1e2e"),
    .border = hex("#45475a"),
    .hover = hex("#313244"),
    .icon = hex("#cdd6f4"),
    .ws_active = hex("#89b4fa"),
    .ws_occupied = hex("#cdd6f4"),
    .ws_empty = hex("#585b70"),
    .ws_other = hex("#9399b2"),
    .clock = hex("#cdd6f4"),
    .title = hex("#a6adc8"),
    .wifi = hex("#cdd6f4"),
    .wifi_inactive = hex("#585b70"),
    .off = hex("#f38ba8"),
    .bt_on = hex("#cdd6f4"),
    .bt_connected = hex("#89b4fa"),
    .bt_off = hex("#585b70"),
    .battery = hex("#cdd6f4"),
    .charging = hex("#a6e3a1"),
    .power = hex("#f38ba8"),
    .menu_background = hex("#1e1e2e"),
    .menu_text = hex("#cdd6f4"),
    .menu_muted = hex("#7f849c"),
    .menu_accent = hex("#89b4fa"),
    .menu_accent_hover = hex("#b4befe"),
    .menu_accent_text = hex("#1e1e2e"),
    .menu_field = hex("#313244"),
    .menu_border = hex("#45475a"),
    .menu_hover = hex("#45475a"),
    .menu_error = hex("#f38ba8"),
    .wallpaper = hex("#1e1e2e"),
};

pub const light = Theme{
    .background = hex("#eff1f5"),
    .border = hex("#bcc0cc"),
    .hover = hex("#ccd0da"),
    .icon = hex("#4c4f69"),
    .ws_active = hex("#1e66f5"),
    .ws_occupied = hex("#4c4f69"),
    .ws_empty = hex("#acb0be"),
    .ws_other = hex("#7c7f93"),
    .clock = hex("#4c4f69"),
    .title = hex("#5c5f77"),
    .wifi = hex("#4c4f69"),
    .wifi_inactive = hex("#acb0be"),
    .off = hex("#d20f39"),
    .bt_on = hex("#4c4f69"),
    .bt_connected = hex("#1e66f5"),
    .bt_off = hex("#acb0be"),
    .battery = hex("#4c4f69"),
    .charging = hex("#40a02b"),
    .power = hex("#d20f39"),
    .menu_background = hex("#eff1f5"),
    .menu_text = hex("#4c4f69"),
    .menu_muted = hex("#8c8fa1"),
    .menu_accent = hex("#1e66f5"),
    .menu_accent_hover = hex("#7287fd"),
    .menu_accent_text = hex("#eff1f5"),
    .menu_field = hex("#ccd0da"),
    .menu_border = hex("#bcc0cc"),
    .menu_hover = hex("#bcc0cc"),
    .menu_error = hex("#d20f39"),
    .wallpaper = hex("#eff1f5"),
};

// ---------------------------------------------------------------- меню

pub const menu_width: u32 = 400; // Wi‑Fi и Bluetooth
pub const menu_height: u32 = 500;

/// Питание: спрашивать подтверждение для выхода, перезагрузки и выключения.
pub const power_confirm = true;
/// Перед сном блокировать экран (команда блокировки из конфига RefursWM).
pub const lock_before_suspend = true;

/// Каталог обоев (~ — домашний). JPEG и PNG.
pub const wallpaper_dir = "~/Pictures/wallpapers";
/// .fill — заполнить экран с обрезкой краёв, .fit — целиком, с полями цвета wallpaper из темы.
pub const wallpaper_mode: enum { fill, fit } = .fill;

/// Без systemd-logind (Void с runit) перезагрузка и выключение — этими командами, без shell;
/// *_fallback запускается, только если doas не установлен (тот же процесс). Нужно узкое правило
/// без пароля:
///   /etc/doas.conf:            permit nopass youruser as root cmd /usr/bin/poweroff args
///   /etc/sudoers.d/refursline: youruser ALL=(root) NOPASSWD: /usr/bin/reboot, /usr/bin/poweroff
/// null — кнопка скрыта, когда logind нет.
pub const reboot_cmd: ?[*:0]const u8 = "doas -n /usr/bin/reboot";
pub const reboot_fallback: ?[*:0]const u8 = null; // void-hardened: sudo нет, только doas
pub const poweroff_cmd: ?[*:0]const u8 = "doas -n /usr/bin/poweroff";
pub const poweroff_fallback: ?[*:0]const u8 = null;

/// Bluetooth по требованию: если bluetoothd не запущен, переключатель в меню запускает
/// bt_service_on_cmd и ждёт службу; выключение — bt_service_off_cmd.
/// void-hardened: при VH_BLUETOOTH=optional install/build-desktop.sh ставит сюда
/// "doas -n /usr/local/sbin/vh-bluetooth on" / "… off". null — не нужно.
pub const bt_service_on_cmd: ?[*:0]const u8 = null;
pub const bt_service_off_cmd: ?[*:0]const u8 = null;

// ---------------------------------------------------------------- лаунчер

pub const launcher_width: u32 = 520;
pub const launcher_rows: u32 = 7;
/// Иконки приложений (PNG из темы иконок). false — только плитки с буквой.
pub const launcher_icons = true;
/// Тема иконок; "" — как у GTK (gtk-icon-theme-name в ~/.config/gtk-3.0/settings.ini).
/// Читается только PNG: для SVG-тем (Papirus) иконки берутся из hicolor или рисуется буква.
pub const icon_theme = "";
/// Терминал для приложений с Terminal=true и для Shift+Enter: команда дописывается в конец.
/// foot, kitty — как есть; alacritty, xterm, ghostty — .{ "alacritty", "-e" }.
pub const terminal = [_][:0]const u8{"foot"};
