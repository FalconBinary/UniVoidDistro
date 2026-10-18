// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Landlock: what the compositor may still touch in the file system. The config is compiled in, so
//! at run time it reads nothing of the user's but cursor themes; it writes only the Mesa shader cache
//! and shared memory. No TCP at all (ABI 4), no abstract unix sockets or signals outside itself
//! (ABI 6), nowhere anything executable. Two stages: `startup` right after the launcher is forked
//! (before Mesa starts threads, so every thread is confined) also allows creating the Wayland sockets
//! and reading the user's xkb rules; `running`, stacked on top before the event loop, drops that.
//! The rule list is pure (tested on any host); `apply` makes the syscalls.
const std = @import("std");
const linux = std.os.linux;

pub const fs = struct {
    pub const execute: u64 = 1 << 0;
    pub const write_file: u64 = 1 << 1;
    pub const read_file: u64 = 1 << 2;
    pub const read_dir: u64 = 1 << 3;
    pub const remove_dir: u64 = 1 << 4;
    pub const remove_file: u64 = 1 << 5;
    pub const make_char: u64 = 1 << 6;
    pub const make_dir: u64 = 1 << 7;
    pub const make_reg: u64 = 1 << 8;
    pub const make_sock: u64 = 1 << 9;
    pub const make_fifo: u64 = 1 << 10;
    pub const make_block: u64 = 1 << 11;
    pub const make_sym: u64 = 1 << 12;
    pub const refer: u64 = 1 << 13; // ABI 2
    pub const truncate: u64 = 1 << 14; // ABI 3
    pub const ioctl_dev: u64 = 1 << 15; // ABI 5
    /// rights that apply to a file (not a directory)
    pub const on_files = execute | write_file | read_file | truncate | ioctl_dev;
};

/// Everything a kernel with this ABI version can restrict.
pub fn handledFs(abi: u32) u64 {
    var h: u64 = (1 << 13) - 1;
    if (abi >= 2) h |= fs.refer;
    if (abi >= 3) h |= fs.truncate;
    if (abi >= 5) h |= fs.ioctl_dev;
    return h;
}

const ro = fs.read_file | fs.read_dir;
const devdir = fs.read_file | fs.write_file | fs.read_dir | fs.ioctl_dev;
const devfile = fs.read_file | fs.write_file;
const shm = fs.read_file | fs.write_file | fs.read_dir | fs.make_reg | fs.remove_file | fs.truncate;
const cache = fs.read_file | fs.write_file | fs.read_dir | fs.remove_dir | fs.remove_file | fs.make_dir | fs.make_reg | fs.refer | fs.truncate;
/// wl_display_add_socket_auto and the sandbox socket: socket + lock file, stale ones removed
const runtime = fs.make_sock | fs.make_reg | fs.read_file | fs.write_file | fs.remove_file | fs.truncate;

pub const Stage = enum { startup, running };

pub const Env = struct {
    home: ?[]const u8 = null,
    xdg_cache_home: ?[]const u8 = null,
    xdg_data_home: ?[]const u8 = null,
    xdg_config_home: ?[]const u8 = null,
    xdg_runtime_dir: ?[]const u8 = null,
    xcursor_path: ?[]const u8 = null,
    /// libinput's device quirks, read when libinput starts (built with RefursWM, see deps/libinput.zig)
    quirks_dir: ?[]const u8 = null,

    pub fn fromProcess() Env {
        const get = struct {
            fn f(name: [*:0]const u8) ?[]const u8 {
                const v = std.c.getenv(name) orelse return null;
                const s = std.mem.span(v);
                // relative values are ignored by everything that reads them, so here too
                return if (s.len > 1 and s[0] == '/') s else null;
            }
        }.f;
        return .{
            .home = get("HOME"),
            .xdg_cache_home = get("XDG_CACHE_HOME"),
            .xdg_data_home = get("XDG_DATA_HOME"),
            .xdg_config_home = get("XDG_CONFIG_HOME"),
            .xdg_runtime_dir = get("XDG_RUNTIME_DIR"),
            .xcursor_path = if (std.c.getenv("XCURSOR_PATH")) |v| std.mem.span(v) else null,
        };
    }
};

pub const Rule = struct { path: []const u8, access: u64 };

pub const max_rules = 40;

const List = struct {
    rules: [max_rules]Rule = undefined,
    n: usize = 0,
    fba: std.heap.FixedBufferAllocator,

    fn add(l: *List, path: []const u8, access: u64) void {
        if (l.n == max_rules or path.len == 0 or path[0] != '/') return;
        l.rules[l.n] = .{ .path = path, .access = access };
        l.n += 1;
    }
    /// `base` + `rel`, or nothing without a base
    fn join(l: *List, base: ?[]const u8, rel: []const u8, access: u64) void {
        const b = base orelse return;
        const p = std.fmt.allocPrint(l.fba.allocator(), "{s}{s}", .{ b, rel }) catch return;
        l.add(p, access);
    }
};

/// The allowed paths of `stage`. Strings live in `buf`; rules for missing paths are skipped later.
pub fn rules(stage: Stage, env: Env, buf: []u8, out: *[max_rules]Rule) []Rule {
    var l: List = .{ .fba = std.heap.FixedBufferAllocator.init(buf) };
    // libraries, drivers, xkb data, icons, quirks; udev and DRM in sysfs; our own /proc
    for ([_][]const u8{ "/usr", "/etc", "/sys", "/proc", "/run/udev" }) |p| l.add(p, ro);
    l.add("/dev/dri", devdir);
    for ([_][]const u8{ "/dev/null", "/dev/zero", "/dev/urandom", "/dev/random" }) |p| l.add(p, devfile);
    // wlroots: keymaps, dmabuf feedback tables and shm buffers come from shm_open
    l.add("/dev/shm", shm);
    // Mesa shader cache
    if (env.xdg_cache_home) |p| l.add(p, cache) else l.join(env.home, "/.cache", cache);
    // cursor themes (loaded when a monitor with a new scale appears), see wlroots xcursor.c
    if (env.xcursor_path) |xp| {
        var it = std.mem.tokenizeScalar(u8, xp, ':');
        while (it.next()) |p| {
            if (p[0] == '~') l.join(env.home, p[1..], ro) else l.add(p, ro);
        }
    } else {
        if (env.xdg_data_home) |p| l.join(p, "/icons", ro) else l.join(env.home, "/.local/share/icons", ro);
        l.join(env.home, "/.icons", ro);
        l.join(env.home, "/.cursors", ro);
    }
    l.join(env.home, "/.drirc", ro);
    if (stage == .startup) {
        l.add(env.xdg_runtime_dir orelse "", runtime);
        if (env.xdg_config_home) |p| l.join(p, "/xkb", ro) else l.join(env.home, "/.config/xkb", ro);
        l.join(env.home, "/.xkb", ro);
        // logind sessions: libelogind reads the machine id
        l.add("/var/lib/dbus", ro);
        if (env.quirks_dir) |p| l.add(p, ro);
    }
    @memcpy(out[0..l.n], l.rules[0..l.n]);
    return out[0..l.n];
}

// ---------------------------------------------------------------- syscalls

const RulesetAttr = extern struct { handled_access_fs: u64, handled_access_net: u64, scoped: u64 };
const PathBeneath = extern struct { allowed_access: u64 align(4), parent_fd: i32 };
const create_ruleset_version = 1;
const rule_path_beneath = 1;
const net_bind_tcp = 1 << 0;
const net_connect_tcp = 1 << 1;
const scope_abstract_unix_socket = 1 << 0;
const scope_signal = 1 << 1;

fn ok(rc: usize) bool {
    return linux.errno(rc) == .SUCCESS;
}

/// The Landlock ABI of the running kernel, or 0 if Landlock is off or missing.
pub fn abiVersion() u32 {
    const rc = linux.syscall3(.landlock_create_ruleset, 0, 0, create_ruleset_version);
    return if (ok(rc)) @intCast(rc) else 0;
}

/// Confines the calling thread (and every thread and process it creates later) to `stage`'s rules.
/// The caller must have set no_new_privs. Returns the ABI version used, 0 when not available.
pub fn apply(stage: Stage, env: Env) u32 {
    const abi = abiVersion();
    if (abi == 0) return 0;
    const handled = handledFs(abi);
    var attr: RulesetAttr = .{
        .handled_access_fs = handled,
        // no rules for them: no TCP at all
        .handled_access_net = if (abi >= 4) net_bind_tcp | net_connect_tcp else 0,
        .scoped = if (abi >= 6) scope_abstract_unix_socket | scope_signal else 0,
    };
    const size: usize = if (abi >= 6) @sizeOf(RulesetAttr) else if (abi >= 4) 16 else 8;
    const rc = linux.syscall3(.landlock_create_ruleset, @intFromPtr(&attr), size, 0);
    if (!ok(rc)) return 0;
    const ruleset: linux.fd_t = @intCast(rc);
    defer _ = linux.close(ruleset);

    var buf: [4096]u8 = undefined;
    var list: [max_rules]Rule = undefined;
    for (rules(stage, env, &buf, &list)) |r| {
        var path: [std.fs.max_path_bytes:0]u8 = undefined;
        if (r.path.len >= path.len) continue;
        @memcpy(path[0..r.path.len], r.path);
        path[r.path.len] = 0;
        var access = r.access & handled;
        // a directory, else a file (only file rights)
        var fd_rc = linux.open(&path, .{ .PATH = true, .DIRECTORY = true, .CLOEXEC = true }, 0);
        if (linux.errno(fd_rc) == .NOTDIR) {
            fd_rc = linux.open(&path, .{ .PATH = true, .CLOEXEC = true }, 0);
            access &= fs.on_files;
        }
        if (!ok(fd_rc)) continue; // missing: nothing to allow
        const fd: linux.fd_t = @intCast(fd_rc);
        defer _ = linux.close(fd);
        const pb: PathBeneath = .{ .allowed_access = access, .parent_fd = fd };
        _ = linux.syscall4(.landlock_add_rule, @intCast(ruleset), rule_path_beneath, @intFromPtr(&pb), 0);
    }
    if (!ok(linux.syscall2(.landlock_restrict_self, @intCast(ruleset), 0))) return 0;
    return abi;
}

// ---------------------------------------------------------------- tests

const tt = std.testing;

fn find(list: []const Rule, path: []const u8) ?u64 {
    for (list) |r| if (std.mem.eql(u8, r.path, path)) return r.access;
    return null;
}

test "landlock rules: home stays closed except caches and cursor themes" {
    var buf: [4096]u8 = undefined;
    var out: [max_rules]Rule = undefined;
    const env: Env = .{ .home = "/home/u", .xdg_runtime_dir = "/run/user/1000" };
    const run = rules(.running, env, &buf, &out);
    try tt.expect(find(run, "/home/u") == null);
    try tt.expect(find(run, "/home/u/.config") == null);
    try tt.expect(find(run, "/home/u/.ssh") == null);
    try tt.expect(find(run, "/run/user/1000") == null);
    try tt.expectEqual(@as(?u64, cache), find(run, "/home/u/.cache"));
    try tt.expectEqual(@as(?u64, ro), find(run, "/home/u/.local/share/icons"));
    try tt.expectEqual(@as(?u64, ro), find(run, "/home/u/.icons"));
    for (run) |r| try tt.expect(r.access & fs.execute == 0);
    // writable: only the cache, shared memory and devices
    for (run) |r| if (r.access & (fs.write_file | fs.make_reg) != 0) {
        try tt.expect(std.mem.eql(u8, r.path, "/home/u/.cache") or std.mem.startsWith(u8, r.path, "/dev/"));
    };

    const start = rules(.startup, env, &buf, &out);
    try tt.expectEqual(@as(?u64, runtime), find(start, "/run/user/1000"));
    try tt.expectEqual(@as(?u64, ro), find(start, "/home/u/.config/xkb"));
}

test "landlock rules: XDG overrides and XCURSOR_PATH" {
    var buf: [4096]u8 = undefined;
    var out: [max_rules]Rule = undefined;
    const env: Env = .{ .home = "/h", .xdg_cache_home = "/c", .xdg_data_home = "/d", .xcursor_path = "~/cur:/opt/icons::relative" };
    const run = rules(.running, env, &buf, &out);
    try tt.expect(find(run, "/c") != null);
    try tt.expect(find(run, "/h/.cache") == null);
    try tt.expect(find(run, "/h/cur") != null);
    try tt.expect(find(run, "/opt/icons") != null);
    try tt.expect(find(run, "relative") == null);
    try tt.expect(find(run, "/d/icons") == null); // XCURSOR_PATH replaces the default list
}

test "landlock ABI masks" {
    try tt.expect(handledFs(1) & fs.refer == 0);
    try tt.expect(handledFs(2) & fs.refer != 0);
    try tt.expect(handledFs(4) & fs.ioctl_dev == 0);
    try tt.expect(handledFs(6) & fs.ioctl_dev != 0);
}
