// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Маленький процесс для команд меню (питание: reboot/poweroff через doas/sudo; Bluetooth:
//! включить/выключить службу). Форкается до любых соединений и песочницы меню и умеет одно:
//!   'C' <номер> — запустить команду из таблицы, разобранной при компиляции (config.zig):
//!                 простую — напрямую через execve, со спецсимволами shell — через /bin/sh -c.
//! Само меню после этого не может запускать программы.

const std = @import("std");
const sys = @import("sys.zig");

var sock: i32 = -1;

/// Команда, разобранная при компиляции.
pub const Cmd = struct {
    argv: ?[*:null]const ?[*:0]const u8 = null, // простая: слова через пробел
    shell: ?[*:0]const u8 = null, // со спецсимволами — целиком в /bin/sh -c
    alt: ?[*:null]const ?[*:0]const u8 = null, // простая команда вместо этой, если argv[0] не установлен
};

/// Символы, с которыми строка — просто слова через пробел и shell не нужен.
fn plain(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', ' ', '-', '_', '.', '/', '=', ',', '+', ':', '@', '%' => true,
        else => false,
    };
}

/// Разобрать команду из config.zig при компиляции. Простые команды запускаются без shell:
/// на процесс меньше на каждый клик (и без загрузки libc для /bin/sh).
pub fn compile(comptime s: ?[*:0]const u8) ?Cmd {
    const z = s orelse return null;
    comptime {
        const str = std.mem.span(z);
        for (str) |c| if (!plain(c)) return .{ .shell = z };
        var words: [32]?[*:0]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.tokenizeScalar(u8, str, ' ');
        while (it.next()) |w| : (n += 1) {
            // "FOO=bar program" — присваивание переменной, его понимает только shell
            if (n == 0 and std.mem.indexOfScalar(u8, w, '=') != null) return .{ .shell = z };
            words[n] = std.fmt.comptimePrint("{s}", .{w});
        }
        if (n == 0) return null;
        var av: [n:null]?[*:0]const u8 = undefined;
        for (0..n) |i| av[i] = words[i];
        const final = av;
        return .{ .argv = &final };
    }
}

/// Команда с запасной на случай, если её программа не установлена (doas → sudo): обе простые,
/// пробуются одна за другой в том же процессе — без shell и лишнего процесса.
pub fn compileAlt(comptime s: ?[*:0]const u8, comptime alt: ?[*:0]const u8) ?Cmd {
    comptime {
        var c = compile(s) orelse return null;
        const a = compile(alt) orelse return c;
        if (c.argv == null or a.argv == null) @compileError("a command with a fallback must be simple: no shell characters");
        c.alt = a.argv;
        return c;
    }
}

pub fn start(cmds: []const ?Cmd) bool {
    const pair = sys.socketpair() catch return false;
    const pid = sys.fork() catch {
        sys.close(pair[0]);
        sys.close(pair[1]);
        return false;
    };
    if (pid == 0) {
        // ни сокета Wayland, ни D-Bus, ни канала к бару: только свой конец пары и stdin/stdout/stderr
        const own = sys.keepOnlyFd(pair[1]);
        serve(own, cmds);
    }
    sys.close(pair[1]);
    sock = pair[0];
    return true;
}

// ---------------------------------------------------------------- сторона меню

pub fn run(slot: u8) void {
    const m = [2]u8{ 'C', slot };
    sys.sendAll(sock, &m) catch {};
}

// ---------------------------------------------------------------- сторона broker

fn serve(fd: i32, cmds: []const ?Cmd) noreturn {
    var buf: [256]u8 = undefined;
    while (true) {
        const n = sys.read(fd, &buf) catch sys.exit(0);
        if (n == 0) sys.exit(0); // меню закрылось
        const msg = buf[0..n];
        switch (msg[0]) {
            'C' => if (n == 2 and msg[1] < cmds.len) {
                if (cmds[msg[1]]) |c| {
                    if (c.argv) |av| sys.spawnArgv(av, null, c.alt) else if (c.shell) |sh| sys.spawnShell(sh);
                }
            },
            else => {},
        }
    }
}
