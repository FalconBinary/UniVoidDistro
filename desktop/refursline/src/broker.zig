// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! broker — разделение привилегий. Форкается первым делом, до песочницы бара, и умеет ровно одно:
//! запустить меню RefursLine — этот же бинарник с одним из режимов из таблицы ниже.
//!
//!   бар → broker: 'M' <меню> <тема, 9 байт> [+ дескриптор канала через SCM_RIGHTS]
//!
//! Меню запускается через execveat по O_PATH-дескриптору собственного файла, открытому при
//! старте: без shell, без поиска в PATH, без строки команды. Канал (если есть) становится fd 3
//! меню — по нему обои и питание говорят с баром. Привилегированного сокета Wayland у broker нет:
//! keepFds закрывает его до первого сообщения, а из окружения WAYLAND_SOCKET убран.
//!
//! Сам бар после этого живёт в песочнице без exec, fork и новых сокетов: даже взломанный,
//! он может только попросить открыть одно из своих меню.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");

pub const Menu = enum(u8) { run, commands, wifi, bluetooth, wallpaper, power, calendar, wifi_toggle, bt_toggle };

/// argv[1] (и argv[3]) каждого режима; argv[2] — тема.
const modes = std.enums.EnumArray(Menu, struct { [*:0]const u8, ?[*:0]const u8 }).init(.{
    .run = .{ "run", null },
    .commands = .{ "run", "commands" },
    .wifi = .{ "wifi", null },
    .bluetooth = .{ "bt", null },
    .wallpaper = .{ "wall", null },
    .power = .{ "power", null },
    .calendar = .{ "cal", null },
    .wifi_toggle = .{ "wifi", "toggle" },
    .bt_toggle = .{ "bt", "toggle" },
});

const MSG = 2 + 1;
var sock: i32 = -1;

/// self_fd — O_PATH на собственный исполняемый файл (sys.openSelf).
pub fn start(self_fd: i32) bool {
    const pair = sys.socketpair() catch return false;
    const pid = sys.fork() catch {
        sys.close(pair[0]);
        sys.close(pair[1]);
        return false;
    };
    if (pid == 0) {
        // только свой конец пары (fd 3) и свой файл (fd 4): сокет Wayland, netlink и прочее бара — закрыты
        keepFds(pair[1], self_fd);
        sys.prepareEnv();
        serve(3, 4);
    }
    sys.close(pair[1]);
    sock = pair[0];
    return true;
}

fn keepFds(a: i32, b: i32) void {
    // через временные номера выше любых занятых: dup3 на занятый номер закрыл бы чужой fd
    const ta = dupHigh(a);
    const tb = dupHigh(b);
    dup3(ta, 3, sys.O_CLOEXEC);
    dup3(tb, 4, sys.O_CLOEXEC);
    closeFrom(5);
}

fn dupHigh(fd: i32) usize {
    return linux.syscall3(.fcntl, sys.ufd(fd), 1030, 100); // F_DUPFD_CLOEXEC
}

fn dup3(from: usize, to: usize, flags: usize) void {
    _ = linux.syscall3(.dup3, from, to, flags);
}

fn closeFrom(fd: usize) void {
    _ = linux.syscall3(.close_range, fd, std.math.maxInt(u32), 0);
}

// ---------------------------------------------------------------- сторона бара

/// Открыть меню. theme — "d" или "l" (theme.encode); channel — конец пары для меню или -1.
pub fn open(m: Menu, theme_arg: []const u8, channel: i32) void {
    var msg: [MSG]u8 = @splat(0);
    msg[0] = 'M';
    msg[1] = @intFromEnum(m);
    if (theme_arg.len > 0) msg[2] = theme_arg[0];
    const fds: []const i32 = if (channel >= 0) &.{channel} else &.{};
    _ = sys.sendmsgFds(sock, &msg, fds) catch {};
}

// ---------------------------------------------------------------- сторона broker

fn validTheme(t: []const u8) bool {
    return t.len == 1 and (t[0] == 'd' or t[0] == 'l');
}

fn serve(fd: i32, self_fd: i32) noreturn {
    while (true) {
        var buf: [64]u8 = undefined;
        var ch: i32 = -1;
        const n = sys.recvmsgFd(fd, &buf, &ch) catch sys.exit(0);
        if (n == 0) sys.exit(0); // бар завершился
        defer sys.close(ch);
        if (n != MSG or buf[0] != 'M' or buf[1] >= @typeInfo(Menu).@"enum".field_names.len) continue;
        const theme_arg = buf[2..MSG];
        if (!validTheme(theme_arg)) continue;
        var tz: [1:0]u8 = @splat(0);
        tz[0] = theme_arg[0];
        const mode = modes.get(@enumFromInt(buf[1]));
        const av = [_:null]?[*:0]const u8{ "refursline", mode[0], &tz, mode[1] };
        spawn(self_fd, &av, ch);
    }
}

/// Двойной fork + setsid: меню не зомби и не в группе бара. Канал — fd 3 меню, всё прочее закрыто.
fn spawn(self_fd: i32, av: [*:null]const ?[*:0]const u8, ch: i32) void {
    const pid = sys.fork() catch return;
    if (pid == 0) {
        _ = linux.syscall0(.setsid);
        const pid2 = sys.fork() catch sys.exit(1);
        if (pid2 == 0) {
            // fd 4 (свой файл) с CLOEXEC: execveat работает по нему, а меню его не унаследует
            if (ch >= 0) dup3(dupHigh(ch), 3, 0) else sys.close(3);
            closeFrom(5);
            sys.execveat(self_fd, av);
            sys.exit(127);
        }
        sys.exit(0);
    }
    var status: u32 = 0;
    _ = linux.syscall4(.wait4, pid, @intFromPtr(&status), 0, 0);
}

test "тема для меню проверяется строго" {
    try std.testing.expect(validTheme("d"));
    try std.testing.expect(validTheme("l"));
    try std.testing.expect(!validTheme("x"));
    try std.testing.expect(!validTheme("\x00"));
    try std.testing.expect(!validTheme("dd"));
}
