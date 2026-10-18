//! vh-wlfilter: a filtering Wayland proxy for the sandboxes (docs/08).
//!
//! The second layer on top of RefursWM's sandbox socket ($XDG_RUNTIME_DIR/$WAYLAND_DISPLAY-sandbox).
//! RefursWM already hides layer-shell, session-lock, idle-notify and every privileged protocol
//! from that socket's clients (a deny list). Without it any client of the main socket would see
//! screencopy, data-control (the clipboard), virtual-keyboard, input-method, layer-shell and so
//! on. This proxy listens on a separate socket for the sandboxes and shows a client only the
//! allowed globals (an allow list, stricter than RefursWM's deny list; the proxy never connects to
//! the main socket). It also:
//!   * refuses binding a hidden object by guessing its number (the connection is dropped);
//!   * marks the sandbox windows: app_id "vh-sandbox....", title "[sandbox] ..."; a client
//!     cannot forge this, and the RefursWM rule (app_id_prefix) relies on the app_id;
//!   * drops fullscreen requests (a fake lock screen); RefursWM refuses them for sandbox
//!     socket clients as well.
//!
//! The client's data is untrusted (the browser may be compromised): every field read checks
//! the message bounds, any parse error drops only that connection; the ReleaseSafe bounds
//! checks apply on top.
//!
//! Runs in the everyday user's session (autostart in RefursWM's config.zig).
//! Socket: /run/vh-sandbox/wayland (the directory is user:browser 2750, the socket 0660).
//! The daemon lives for the whole session: connection memory comes from the shared allocator and is freed.
const std = @import("std");
const vh = @import("vh");
const linux = std.os.linux;
const mem = std.mem;

/// connection memory (freed when the connection closes)
const A = std.heap.smp_allocator;

const LISTEN = "/run/vh-sandbox/wayland";
const MAX_FDS = 28; // how many fds libwayland passes in one sendmsg
const MAX_MSG = 4096; // the message size limit in libwayland
const HIGH_WATER = 1 << 20; // stop reading the source when the destination queue is larger
const RECV_SIZE = 65536;

/// The allow list of globals. A sandbox client simply does not see anything else.
const allowed = [_][]const u8{
    "wl_compositor",                  "wl_subcompositor",               "wl_shm",                   "wl_seat",              "wl_output",
    "wl_data_device_manager", // copy/paste (the clipboard goes to the focused window)
    "wl_drm", // mesa's legacy path to the render node
    "xdg_wm_base",                    "zxdg_decoration_manager_v1",     "org_kde_kwin_server_decoration_manager",
    "zxdg_output_manager_v1",
    "zwp_linux_dmabuf_v1",            "wp_linux_drm_syncobj_manager_v1",
    "wp_viewporter",                  "wp_fractional_scale_manager_v1", "wp_presentation",
    "wp_single_pixel_buffer_manager_v1", "wp_cursor_shape_manager_v1",
    "wp_color_manager_v1",            "wp_color_representation_manager_v1",
    "wp_content_type_manager_v1",     "wp_tearing_control_manager_v1",  "wp_alpha_modifier_v1",
    "wp_fifo_manager_v1",             "wp_commit_timing_manager_v1",
    "zwp_pointer_gestures_v1",        "zwp_relative_pointer_manager_v1",
    "zwp_pointer_constraints_v1",     "zwp_tablet_manager_v2",
    "zwp_text_input_manager_v3", // IME input into browser fields (not input-method!)
    "zwp_idle_inhibit_manager_v1", // video keeps the screen on (docs/05: the price)
};
// For reference, what is hidden (an incomplete list; EVERYTHING outside allowed is hidden):
// zwlr_screencopy_manager_v1, ext_image_copy_capture_manager_v1, zwlr_export_dmabuf_manager_v1,
// zwlr_data_control_manager_v1, ext_data_control_manager_v1, zwp_primary_selection_device_manager_v1,
// zwp_virtual_keyboard_manager_v1, zwlr_virtual_pointer_manager_v1, zwp_input_method_manager_v2,
// zwlr_layer_shell_v1, ext_session_lock_manager_v1, zwlr_foreign_toplevel_manager_v1,
// ext_foreign_toplevel_list_v1, zwlr_gamma_control_manager_v1, zwlr_output_power_manager_v1,
// zwlr_output_manager_v1, wp_drm_lease_device_v1, zwp_keyboard_shortcuts_inhibit_manager_v1,
// ext_idle_notifier_v1, xdg_activation_v1, zxdg_exporter_v2, ext_workspace_manager_v1.

const TITLE_PREFIX = "[sandbox] ";
const APPID_PREFIX = "vh-sandbox";

// request and event opcodes (wayland.xml, xdg-shell.xml)
const WL_DISPLAY_GET_REGISTRY = 1;
const WL_DISPLAY_DELETE_ID = 1; // event
const WL_REGISTRY_BIND = 0;
const WL_REGISTRY_GLOBAL = 0; // event
const WL_REGISTRY_GLOBAL_REMOVE = 1; // event
const XDG_WM_BASE_GET_XDG_SURFACE = 2;
const XDG_SURFACE_GET_TOPLEVEL = 1;
const XDG_TOPLEVEL_SET_TITLE = 2;
const XDG_TOPLEVEL_SET_APP_ID = 3;
const XDG_TOPLEVEL_SET_FULLSCREEN = 11;

// ---------------------------------------------------------------- connections

const Chunk = struct {
    next: ?*Chunk = null,
    /// the allocated memory (from the pool: may be larger than data)
    buf: []u8,
    data: []u8,
    off: usize = 0,
    fds: [MAX_FDS]i32 = undefined,
    nfds: usize = 0,
};

/// A pool of queue blocks: in the normal flow (without back pressure) no memory is allocated
/// or freed per message, and the daemon's RSS stays around a megabyte.
var pool: ?*Chunk = null;
var pool_n: usize = 0;
const POOL_MAX = 16;
const POOL_BUF = 8192;

fn chunkNew(len: usize) *Chunk {
    if (len <= POOL_BUF) {
        if (pool) |c| {
            pool = c.next;
            pool_n -= 1;
            c.* = .{ .buf = c.buf, .data = c.buf[0..len] };
            return c;
        }
    }
    const c = A.create(Chunk) catch vh.oom();
    const buf = A.alloc(u8, @max(len, POOL_BUF)) catch vh.oom();
    c.* = .{ .buf = buf, .data = buf[0..len] };
    return c;
}

fn chunkFree(c: *Chunk) void {
    if (c.buf.len == POOL_BUF and pool_n < POOL_MAX) {
        c.next = pool;
        pool = c;
        pool_n += 1;
        return;
    }
    A.free(c.buf);
    A.destroy(c);
}

/// One direction: the socket, the input buffer, the send queue.
const Side = struct {
    conn: *Conn,
    fd: i32,
    /// the tail of an incomplete message
    in: std.ArrayList(u8) = .empty,
    /// fds received and not yet passed on
    fds: std.ArrayList(i32) = .empty,
    head: ?*Chunk = null,
    tail: ?*Chunk = null,
    out_bytes: usize = 0,
    /// the events registered in epoll; 0 means not registered
    ev: u32 = 0,
};

const Set = std.AutoHashMapUnmanaged(u32, void);

const Conn = struct {
    /// c is the sandbox client, s the compositor
    c: Side,
    s: Side,
    registries: Set = .empty,
    wm_bases: Set = .empty,
    xdg_surfaces: Set = .empty,
    toplevels: Set = .empty,
    /// global name -> index into allowed (allowed ones only)
    names: std.AutoHashMapUnmanaged(u32, usize) = .empty,
    closed: bool = false,
    next_dead: ?*Conn = null,
};

var epfd: i32 = -1;
var lsock: i32 = -1;
var upstream: [108]u8 = undefined;
var upstream_len: usize = 0;
var dead: ?*Conn = null;

/// a parse error: the text for the log
const Perr = ?[]const u8;

fn get32(p: []const u8) u32 {
    return mem.readInt(u32, p[0..4], .native); // host byte order, as in libwayland
}

fn put32(b: *std.ArrayList(u8), v: u32) void {
    b.appendSlice(A, mem.asBytes(&v)) catch vh.oom();
}

const Str = struct { s: []const u8, next: usize };

/// a Wayland string: the length including the NUL, the bytes, padding to 4
fn getString(body: []const u8, off: usize) union(enum) { ok: Str, err: []const u8 } {
    if (off > body.len or body.len - off < 4) return .{ .err = "short message" };
    const n: u64 = get32(body[off..]);
    if (n == 0 or off + 4 + n > body.len) return .{ .err = "bad string" };
    return .{ .ok = .{ .s = body[off + 4 .. off + 4 + @as(usize, @intCast(n)) - 1], .next = off + 4 + @as(usize, @intCast((n + 3) & ~@as(u64, 3))) } };
}

fn putString(b: *std.ArrayList(u8), s: []const u8) void {
    put32(b, @intCast(s.len + 1));
    b.appendSlice(A, s) catch vh.oom();
    const zero = [4]u8{ 0, 0, 0, 0 };
    b.appendSlice(A, zero[0 .. 1 + (4 - (s.len + 1) % 4) % 4]) catch vh.oom();
}

fn message(out: *std.ArrayList(u8), obj: u32, op: u32, payload: []const u8) Perr {
    const size = 8 + payload.len;
    if (size > MAX_MSG) return "message too long";
    put32(out, obj);
    put32(out, @as(u32, @intCast(size << 16)) | op);
    out.appendSlice(A, payload) catch vh.oom();
    return null;
}

/// UTF-8 with errors replaced by U+FFFD (one replacement per maximal invalid part)
pub fn utf8Next(s: []const u8, cp: *u32) usize {
    const c = s[0];
    var lo: u8 = 0x80;
    var hi: u8 = 0xBF;
    var need: usize = undefined;
    var v: u32 = undefined;
    if (c < 0x80) {
        cp.* = c;
        return 1;
    }
    if (c >= 0xC2 and c <= 0xDF) {
        need = 1;
        v = c & 0x1F;
    } else if (c >= 0xE0 and c <= 0xEF) {
        need = 2;
        v = c & 0x0F;
        if (c == 0xE0) lo = 0xA0;
        if (c == 0xED) hi = 0x9F;
    } else if (c >= 0xF0 and c <= 0xF4) {
        need = 3;
        v = c & 0x07;
        if (c == 0xF0) lo = 0x90;
        if (c == 0xF4) hi = 0x8F;
    } else {
        cp.* = 0xFFFD;
        return 1;
    }
    var i: usize = 1;
    for (0..need) |_| {
        if (i >= s.len or s[i] < lo or s[i] > hi) {
            cp.* = 0xFFFD;
            return i;
        }
        lo = 0x80;
        hi = 0xBF;
        v = v << 6 | (s[i] & 0x3F);
        i += 1;
    }
    cp.* = v;
    return i;
}

fn utf8Put(b: *std.ArrayList(u8), cp: u32) void {
    var o: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(@intCast(cp), &o) catch {
        // surrogates are unreachable: utf8Next never produces them and printable() rejects them
        return;
    };
    b.appendSlice(A, o[0..n]) catch vh.oom();
}

/// Non-printable characters: controls, format characters (including bidi and zero-width),
/// separators other than space, private use and known unassigned, like isprintable().
pub fn printable(c: u32) bool {
    const bad = [_][2]u32{
        .{ 0x00, 0x1F },       .{ 0x7F, 0xA0 },       .{ 0xAD, 0xAD },       .{ 0x600, 0x605 },     .{ 0x61C, 0x61C },
        .{ 0x6DD, 0x6DD },     .{ 0x70F, 0x70F },     .{ 0x890, 0x891 },     .{ 0x8E2, 0x8E2 },     .{ 0x1680, 0x1680 },
        .{ 0x180E, 0x180E },   .{ 0x2000, 0x200F },   .{ 0x2028, 0x202F },   .{ 0x205F, 0x2064 },   .{ 0x2066, 0x206F },
        .{ 0x3000, 0x3000 },   .{ 0xD800, 0xF8FF },   .{ 0xFDD0, 0xFDEF },   .{ 0xFEFF, 0xFEFF },   .{ 0xFFF0, 0xFFFB },
        .{ 0x110BD, 0x110BD }, .{ 0x110CD, 0x110CD }, .{ 0x13430, 0x1343F }, .{ 0x1BCA0, 0x1BCA3 }, .{ 0x1D173, 0x1D17A },
        .{ 0x40000, 0xDFFFF }, .{ 0xE0000, 0xE00FF }, .{ 0xE01F0, 0x10FFFF },
    };
    if (c & 0xFFFE == 0xFFFE) return false; // U+xFFFE, U+xFFFF are noncharacters
    for (bad) |r| if (c >= r[0] and c <= r[1]) return false;
    return true;
}

/// Printable characters only, at most limit: the app_id and title must not break RefursWM's rules.
fn clean(out: *std.ArrayList(u8), s: []const u8, limit: usize) void {
    var i: usize = 0;
    var kept: usize = 0;
    while (i < s.len and kept < limit) {
        var cp: u32 = undefined;
        i += utf8Next(s[i..], &cp);
        if (!printable(cp)) continue;
        utf8Put(out, cp);
        kept += 1;
    }
}

fn put(set: *Set, k: u32) void {
    set.put(A, k, {}) catch vh.oom();
}

/// parsing the client's messages (requests)
fn request(k: *Conn, msg: []const u8, out: *std.ArrayList(u8)) Perr {
    const obj = get32(msg);
    const op = get32(msg[4..]) & 0xFFFF;
    const body = msg[8..];

    if (obj == 1 and op == WL_DISPLAY_GET_REGISTRY) {
        if (body.len < 4) return "short message";
        put(&k.registries, get32(body));
    } else if (k.registries.contains(obj) and op == WL_REGISTRY_BIND) {
        if (body.len < 4) return "short message";
        const name = get32(body);
        const iface = switch (getString(body, 4)) {
            .ok => |x| x,
            .err => |e| return e,
        };
        const o = iface.next;
        if (o > body.len or body.len - o < 8) return "short message";
        const new_id = get32(body[o + 4 ..]);
        const idx = k.names.get(name) orelse return "attempt to bind a hidden object";
        if (!vh.eql(allowed[idx], iface.s)) return "attempt to bind a hidden object";
        if (vh.eql(allowed[idx], "xdg_wm_base")) put(&k.wm_bases, new_id);
    } else if (k.wm_bases.contains(obj) and op == XDG_WM_BASE_GET_XDG_SURFACE) {
        if (body.len < 4) return "short message";
        put(&k.xdg_surfaces, get32(body));
    } else if (k.xdg_surfaces.contains(obj) and op == XDG_SURFACE_GET_TOPLEVEL) {
        if (body.len < 4) return "short message";
        const new_id = get32(body);
        put(&k.toplevels, new_id);
        // mark the window right away: even if the client never sets an app_id, the RefursWM rule applies
        out.appendSlice(A, msg) catch vh.oom();
        var p: std.ArrayList(u8) = .empty;
        defer p.deinit(A);
        putString(&p, APPID_PREFIX);
        return message(out, new_id, XDG_TOPLEVEL_SET_APP_ID, p.items);
    } else if (k.toplevels.contains(obj)) {
        if (op == XDG_TOPLEVEL_SET_FULLSCREEN) return null; // fullscreen only through the RefursWM key (docs/08)
        if (op == XDG_TOPLEVEL_SET_TITLE or op == XDG_TOPLEVEL_SET_APP_ID) {
            const s = switch (getString(body, 0)) {
                .ok => |x| x.s,
                .err => |e| return e,
            };
            var t: std.ArrayList(u8) = .empty;
            defer t.deinit(A);
            var p: std.ArrayList(u8) = .empty;
            defer p.deinit(A);
            if (op == XDG_TOPLEVEL_SET_TITLE) {
                t.appendSlice(A, TITLE_PREFIX) catch vh.oom();
                clean(&t, s, 200);
            } else {
                t.appendSlice(A, APPID_PREFIX ++ ".") catch vh.oom();
                clean(&t, s, 100);
            }
            putString(&p, t.items);
            return message(out, obj, op, p.items);
        }
    }
    out.appendSlice(A, msg) catch vh.oom();
    return null;
}

/// parsing the compositor's messages (events)
fn event(k: *Conn, msg: []const u8, out: *std.ArrayList(u8)) Perr {
    const obj = get32(msg);
    const op = get32(msg[4..]) & 0xFFFF;
    const body = msg[8..];

    if (k.registries.contains(obj)) {
        if (op == WL_REGISTRY_GLOBAL) {
            if (body.len < 4) return "short message";
            const name = get32(body);
            const iface = switch (getString(body, 4)) {
                .ok => |x| x.s,
                .err => |e| return e,
            };
            var idx: ?usize = null;
            for (allowed, 0..) |a, i| {
                if (vh.eql(a, iface)) idx = i;
            }
            k.names.put(A, name, idx orelse return null) catch vh.oom(); // a hidden global: the client never learns about it
        } else if (op == WL_REGISTRY_GLOBAL_REMOVE) {
            if (body.len < 4) return "short message";
            if (!k.names.remove(get32(body))) return null;
        }
    } else if (obj == 1 and op == WL_DISPLAY_DELETE_ID) {
        if (body.len < 4) return "short message";
        const oid = get32(body);
        _ = k.registries.remove(oid);
        _ = k.wm_bases.remove(oid);
        _ = k.xdg_surfaces.remove(oid);
        _ = k.toplevels.remove(oid);
    }
    out.appendSlice(A, msg) catch vh.oom();
    return null;
}

/// parse every complete message in `in`; the tail stays in `in`
fn filter(k: *Conn, from_client: bool, in: *std.ArrayList(u8), out: *std.ArrayList(u8)) Perr {
    var off: usize = 0;
    var e: Perr = null;
    while (in.items.len - off >= 8) {
        const m = in.items[off..];
        const size: usize = get32(m[4..]) >> 16;
        if (size < 8 or size % 4 != 0 or size > MAX_MSG) {
            e = if (from_client) "bad request size" else "bad event size";
            break;
        }
        if (m.len < size) break;
        e = if (from_client) request(k, m[0..size], out) else event(k, m[0..size], out);
        if (e != null) break;
        off += size;
    }
    in.replaceRangeAssumeCapacity(0, off, &.{});
    return e;
}

fn closeConn(k: *Conn) void {
    if (k.closed) return;
    k.closed = true;
    for ([_]*Side{ &k.c, &k.s }) |s| {
        for (s.fds.items) |fd| vh.close(fd);
        s.fds.clearRetainingCapacity();
        var c = s.head;
        while (c) |ch| {
            c = ch.next;
            for (ch.fds[0..ch.nfds]) |fd| vh.close(fd);
            chunkFree(ch);
        }
        s.head = null;
        s.tail = null;
        if (s.fd >= 0) vh.close(s.fd); // closing also removes the fd from epoll
        s.fd = -1;
    }
    k.next_dead = dead;
    dead = k;
}

fn freeConn(k: *Conn) void {
    k.c.in.deinit(A);
    k.s.in.deinit(A);
    k.c.fds.deinit(A);
    k.s.fds.deinit(A);
    k.registries.deinit(A);
    k.wm_bases.deinit(A);
    k.xdg_surfaces.deinit(A);
    k.toplevels.deinit(A);
    k.names.deinit(A);
    A.destroy(k);
}

/// event registration that respects the queues (back pressure)
fn update(k: *Conn) void {
    if (k.closed) return;
    const pairs = [2][2]*Side{ .{ &k.c, &k.s }, .{ &k.s, &k.c } };
    for (pairs) |pr| {
        const s = pr[0];
        const other = pr[1];
        var ev: u32 = 0;
        if (other.out_bytes < HIGH_WATER) ev |= linux.EPOLL.IN;
        if (s.head != null) ev |= linux.EPOLL.OUT;
        if (ev == s.ev) continue;
        var e: linux.epoll_event = .{ .events = ev, .data = .{ .ptr = @intFromPtr(s) } };
        const op: u32 = if (ev == 0) linux.EPOLL.CTL_DEL else if (s.ev == 0) linux.EPOLL.CTL_ADD else linux.EPOLL.CTL_MOD;
        _ = vh.sys(linux.epoll_ctl(epfd, op, s.fd, &e)) catch vh.die("epoll_ctl: {s}", .{vh.serr()});
        s.ev = ev;
    }
}

fn enqueue(dst: *Side, data: []const u8, fds: []const i32) void {
    const c = chunkNew(data.len);
    @memcpy(c.data, data);
    c.nfds = fds.len;
    @memcpy(c.fds[0..fds.len], fds);
    if (dst.tail) |t| t.next = c else dst.head = c;
    dst.tail = c;
    dst.out_bytes += data.len;
}

const CMSG_HDR = mem.alignForward(usize, @sizeOf(linux.cmsghdr), linux.cmsg_align);
fn cmsgSpace(n: usize) usize {
    return CMSG_HDR + mem.alignForward(usize, n, linux.cmsg_align);
}
const CTL_SIZE = cmsgSpace(MAX_FDS * @sizeOf(i32));

/// send the queue; false means the connection is gone
fn flush(dst: *Side) bool {
    while (dst.head) |c| {
        var iov = [1]std.posix.iovec_const{.{ .base = c.data[c.off..].ptr, .len = c.data.len - c.off }};
        var ctl: [CTL_SIZE]u8 align(@alignOf(linux.cmsghdr)) = @splat(0);
        var mh: linux.msghdr_const = .{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 1, .control = null, .controllen = 0, .flags = 0 };
        if (c.nfds > 0) {
            const cm: *linux.cmsghdr = @ptrCast(&ctl);
            cm.* = .{ .len = CMSG_HDR + c.nfds * @sizeOf(i32), .level = linux.SOL.SOCKET, .type = linux.SCM.RIGHTS };
            @memcpy(ctl[CMSG_HDR..][0 .. c.nfds * @sizeOf(i32)], mem.sliceAsBytes(c.fds[0..c.nfds]));
            mh.control = &ctl;
            mh.controllen = cmsgSpace(c.nfds * @sizeOf(i32));
        }
        const rc = linux.sendmsg(dst.fd, &mh, linux.MSG.NOSIGNAL | linux.MSG.DONTWAIT);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .AGAIN, .INTR => break,
            else => {
                closeConn(dst.conn);
                return false;
            },
        }
        for (c.fds[0..c.nfds]) |fd| vh.close(fd);
        c.nfds = 0; // the fds went out with the first part
        dst.out_bytes -= rc;
        c.off += rc;
        if (c.off == c.data.len) {
            dst.head = c.next;
            if (dst.head == null) dst.tail = null;
            chunkFree(c);
        }
    }
    update(dst.conn);
    return true;
}

var recv_data: [RECV_SIZE]u8 = undefined;
var out_buf: std.ArrayList(u8) = .empty;

fn readable(src: *Side) void {
    const k = src.conn;
    const from_client = src == &k.c;
    const dst = if (from_client) &k.s else &k.c;
    var ctl: [CTL_SIZE]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    var iov = [1]std.posix.iovec{.{ .base = &recv_data, .len = recv_data.len }};
    var mh: linux.msghdr = .{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 1, .control = &ctl, .controllen = ctl.len, .flags = 0 };
    const rc = linux.recvmsg(src.fd, &mh, linux.MSG.CMSG_CLOEXEC | linux.MSG.DONTWAIT);
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .AGAIN, .INTR => return,
        else => return closeConn(k),
    }
    var off: usize = 0;
    while (off + @sizeOf(linux.cmsghdr) <= mh.controllen) {
        const cm: *align(1) const linux.cmsghdr = @ptrCast(&ctl[off]);
        if (cm.len < @sizeOf(linux.cmsghdr) or off + cm.len > mh.controllen) break;
        if (cm.level == linux.SOL.SOCKET and cm.type == linux.SCM.RIGHTS) {
            const cnt = (cm.len - CMSG_HDR) / @sizeOf(i32);
            for (0..cnt) |j| {
                const fd = mem.readInt(i32, ctl[off + CMSG_HDR + j * 4 ..][0..4], .native);
                src.fds.append(A, fd) catch vh.oom();
            }
        }
        off += mem.alignForward(usize, cm.len, linux.cmsg_align);
    }
    if (mh.flags & linux.MSG.CTRUNC != 0) {
        vh.warn("client disconnected: more than {d} fds at once", .{MAX_FDS});
        return closeConn(k);
    }
    if (rc == 0) return closeConn(k);
    src.in.appendSlice(A, recv_data[0..rc]) catch vh.oom();
    // a shared parse buffer: the capacity is kept between messages
    const out = &out_buf;
    out.clearRetainingCapacity();
    if (filter(k, from_client, &src.in, out)) |e| {
        vh.warn("client disconnected: {s}", .{e});
        return closeConn(k);
    }
    if (out.items.len == 0) {
        if (src.fds.items.len > 4 * MAX_FDS) {
            vh.warn("client disconnected: too many fds without data", .{});
            closeConn(k);
        }
        return;
    }
    // fds leave no later than the message they belong to: everything accumulated goes now.
    // libwayland accepts at most 28 fds per recvmsg, so they are split into groups of 28, each
    // with at least one byte (a byte stream can be cut anywhere).
    var pos: usize = 0;
    var fpos: usize = 0;
    const fds = src.fds.items;
    while (fds.len - fpos > MAX_FDS and out.items.len - pos > 1) {
        enqueue(dst, out.items[pos .. pos + 1], fds[fpos .. fpos + MAX_FDS]);
        pos += 1;
        fpos += MAX_FDS;
    }
    enqueue(dst, out.items[pos..], fds[fpos..]);
    src.fds.clearRetainingCapacity();
    _ = flush(dst);
}

fn acceptClient() void {
    const crc = linux.accept4(lsock, null, null, linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK);
    if (linux.errno(crc) != .SUCCESS) return;
    const c: i32 = @intCast(crc);
    const up_rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    var sa: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = @splat(0) };
    @memcpy(sa.path[0..upstream_len], upstream[0..upstream_len]);
    var e = linux.errno(up_rc);
    const up: i32 = if (e == .SUCCESS) @intCast(up_rc) else -1;
    if (e == .SUCCESS) e = linux.errno(linux.connect(up, @ptrCast(&sa), @sizeOf(linux.sockaddr.un)));
    if (e == .SUCCESS) {
        const fl = linux.fcntl(up, linux.F.GETFL, 0);
        e = linux.errno(linux.fcntl(up, linux.F.SETFL, fl | @as(u32, @bitCast(linux.O{ .NONBLOCK = true }))));
    }
    if (e != .SUCCESS) {
        vh.warn("no connection to the compositor: {s}", .{vh.strerror(e)});
        if (up >= 0) vh.close(up);
        vh.close(c);
        return;
    }
    const k = A.create(Conn) catch vh.oom();
    k.* = .{ .c = .{ .conn = k, .fd = c }, .s = .{ .conn = k, .fd = up } };
    update(k);
}

fn onTerm(_: linux.SIG) callconv(.c) void {
    linux.exit_group(0);
}

pub fn main(init: std.process.Init.Minimal) void {
    _ = vh.init(init, "vh-wlfilter");
    var sa_term = mem.zeroes(linux.Sigaction);
    sa_term.handler = .{ .handler = onTerm };
    _ = linux.sigaction(.TERM, &sa_term, null);
    var sa_pipe = mem.zeroes(linux.Sigaction);
    sa_pipe.handler = .{ .handler = linux.SIG.IGN };
    _ = linux.sigaction(.PIPE, &sa_pipe, null);
    const rt = vh.getenv("XDG_RUNTIME_DIR") orelse "";
    if (rt.len == 0) vh.die("no XDG_RUNTIME_DIR", .{});
    var disp = vh.getenv("WAYLAND_DISPLAY") orelse "";
    if (disp.len == 0) disp = "wayland-0";
    // only RefursWM's sandbox socket: if it is missing, the main socket is not used instead
    const path = if (disp[0] == '/') vh.fmt("{s}-sandbox", .{disp}) else vh.fmt("{s}/{s}-sandbox", .{ rt, disp });
    if (path.len >= upstream.len) vh.die("compositor socket path too long", .{});
    const st = vh.stat(path, true) catch vh.die("{s}: {s}; a RefursWM with a sandbox socket is required", .{ path, vh.serr() });
    if (st.mode & linux.S.IFMT != linux.S.IFSOCK) vh.die("{s}: not a socket", .{path});
    @memcpy(upstream[0..path.len], path);
    upstream_len = path.len;

    vh.unlink(LISTEN) catch if (vh.errno != .NOENT) vh.die("{s}: {s}", .{ LISTEN, vh.serr() });
    lsock = @intCast(vh.sys(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0)) catch
        vh.die("{s}: {s}", .{ LISTEN, vh.serr() }));
    var sa: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = @splat(0) };
    @memcpy(sa.path[0..LISTEN.len], LISTEN);
    const old = linux.syscall1(.umask, 0o117);
    _ = vh.sys(linux.bind(lsock, @ptrCast(&sa), @sizeOf(linux.sockaddr.un))) catch vh.die("{s}: {s}", .{ LISTEN, vh.serr() });
    _ = linux.syscall1(.umask, old);
    _ = vh.sys(linux.chmod(LISTEN, 0o660)) catch vh.die("{s}: {s}", .{ LISTEN, vh.serr() });
    _ = vh.sys(linux.listen(lsock, 8)) catch vh.die("{s}: {s}", .{ LISTEN, vh.serr() });
    epfd = @intCast(vh.sys(linux.epoll_create1(linux.EPOLL.CLOEXEC)) catch vh.die("epoll: {s}", .{vh.serr()}));
    var le: linux.epoll_event = .{ .events = linux.EPOLL.IN, .data = .{ .ptr = 0 } };
    _ = vh.sys(linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, lsock, &le)) catch vh.die("epoll: {s}", .{vh.serr()});
    vh.warn("listening on {s} -> {s}", .{ LISTEN, path });

    while (true) {
        var evs: [64]linux.epoll_event = undefined;
        const ne = linux.epoll_wait(epfd, &evs, evs.len, -1);
        switch (linux.errno(ne)) {
            .SUCCESS => {},
            .INTR => continue,
            else => |e| {
                vh.errno = e;
                vh.die("epoll_wait: {s}", .{vh.serr()});
            },
        }
        for (evs[0..ne]) |e| {
            if (e.data.ptr == 0) {
                acceptClient();
                continue;
            }
            const s: *Side = @ptrFromInt(e.data.ptr);
            if (s.conn.closed) continue;
            const ev = e.events;
            if (ev & (linux.EPOLL.OUT | linux.EPOLL.ERR | linux.EPOLL.HUP) != 0 and s.head != null and !flush(s)) continue;
            if (ev & (linux.EPOLL.IN | linux.EPOLL.ERR | linux.EPOLL.HUP) != 0 and !s.conn.closed and s.ev & linux.EPOLL.IN != 0)
                readable(s);
        }
        // the memory of closed connections is freed after the batch: it may have held their events
        while (dead) |k| {
            dead = k.next_dead;
            freeConn(k);
        }
    }
}

test "utf8Next and printable" {
    var cp: u32 = undefined;
    try std.testing.expectEqual(@as(usize, 2), utf8Next("é", &cp));
    try std.testing.expectEqual(@as(u32, 0xE9), cp);
    try std.testing.expectEqual(@as(usize, 1), utf8Next("\xC0\x80", &cp));
    try std.testing.expectEqual(@as(u32, 0xFFFD), cp);
    try std.testing.expectEqual(@as(usize, 2), utf8Next("\xE2\x80", &cp)); // truncated
    try std.testing.expect(!printable(0x202E)); // RLO
    try std.testing.expect(!printable(0xFFFF));
    try std.testing.expect(printable('a'));
}
