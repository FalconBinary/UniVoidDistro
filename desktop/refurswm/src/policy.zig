// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Security decisions as pure functions (no Wayland here, unit-tested on any host).
const std = @import("std");
const T = @import("types.zig");

/// How a global is offered.
pub const Class = union(enum) {
    /// everyone
    normal,
    /// not to sandboxed clients: layer-shell (could cover the screen with a fake dialog),
    /// session-lock (could fake a lock screen), idle-notify (reveals when the user is away)
    sandbox_hidden,
    /// only to clients RefursWM started with a grant for this capability
    privileged: T.Caps,
};

/// `caps`: what the client was granted; `sandboxed`: flatpak & co (security-context-v1) or a
/// client of the sandbox socket. `testing` builds hand privileged globals to every unsandboxed
/// client, so the test scripts can run grim, wtype and wlrctl from a shell.
pub fn allowGlobal(class: Class, caps: T.Caps, sandboxed: bool, testing: bool) bool {
    return switch (class) {
        .normal => true,
        .sandbox_hidden => !sandboxed,
        .privileged => |need| !sandboxed and (testing or caps.any(need)),
    };
}

/// The capabilities `path` was granted, null for programs without a grant. Only exact absolute
/// paths match: a program found through $PATH could be a look-alike in a user-writable directory.
pub fn grantOf(grants: []const T.Grant, path: []const u8) ?T.Caps {
    if (path.len == 0 or path[0] != '/') return null;
    for (grants) |g| if (std.mem.eql(u8, g.path, path)) return g.caps;
    return null;
}

/// Who may set the clipboard (and the primary selection): the client with the keyboard focus
/// (Ctrl+C, a menu entry), or a granted clipboard manager through data-control. A background app
/// may not, whatever serial it presents: it could swap a copied address or command for its own.
pub fn maySetSelection(requester: ?*const anyopaque, focused: ?*const anyopaque, via_data_control: bool) bool {
    const r = requester orelse return false;
    return via_data_control or r == focused;
}

/// The display name the launcher puts into WAYLAND_DISPLAY: what wl_display_add_socket_auto makes.
pub fn validDisplayName(n: []const u8) bool {
    if (!std.mem.startsWith(u8, n, "wayland-") or n.len == 8 or n.len > 12) return false;
    for (n[8..]) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

/// xdg-activation tokens as wlroots makes them (hex); anything else never reaches an environment.
pub fn validToken(t: []const u8) bool {
    if (t.len == 0 or t.len > 64) return false;
    for (t) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-') return false;
    return true;
}

/// A string a client controls (window title, app id) made safe for another client to draw:
/// valid UTF-8 only, no control characters (C0, DEL, C1), cut at a character boundary to fit
/// `out`. Returns the length written.
pub fn cleanText(out: []u8, src: []const u8) usize {
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

/// Does window rule `r` apply to a window with this app_id and title? Unset fields match anything.
pub fn ruleMatches(r: T.Rule, app_id: []const u8, title: []const u8) bool {
    if (r.app_id) |id| if (!std.mem.eql(u8, id, app_id)) return false;
    if (r.app_id_prefix) |p| if (!std.mem.startsWith(u8, app_id, p)) return false;
    if (r.title) |t| if (!std.mem.eql(u8, t, title)) return false;
    return true;
}

/// May a client put its window into fullscreen by itself? Not a sandboxed one: a fullscreen
/// window could pose as the lock screen and collect the password. The user still can (bind).
pub fn mayRequestFullscreen(sandboxed: bool) bool {
    return !sandboxed;
}

const tt = std.testing;

test "client strings for the bar: valid UTF-8, no control characters, bounded" {
    var buf: [255]u8 = undefined;
    var n = cleanText(&buf, "a\x1b[31mb\xffc\xc2\x85d\xc3\xa9\xed\xa0\x80");
    try tt.expectEqualStrings("a[31mbcd\xc3\xa9", buf[0..n]);
    var long: [600]u8 = @splat('x');
    long[254] = 0xc3;
    long[255] = 0xa9;
    n = cleanText(&buf, &long);
    try tt.expectEqual(@as(usize, 254), n);
    try tt.expect(std.unicode.utf8ValidateSlice(buf[0..n]));
    try tt.expectEqual(@as(usize, 0), cleanText(&buf, ""));
}

test "display names and tokens are validated before they reach an environment" {
    try tt.expect(validDisplayName("wayland-0"));
    try tt.expect(validDisplayName("wayland-32"));
    try tt.expect(!validDisplayName("wayland-"));
    try tt.expect(!validDisplayName("wayland-../x"));
    try tt.expect(!validDisplayName("/tmp/wayland-0"));
    try tt.expect(validToken("0123456789abcdef0123456789abcdef"));
    try tt.expect(!validToken(""));
    try tt.expect(!validToken("a b"));
    try tt.expect(!validToken("a\nLD_PRELOAD=x"));
}

test "privileged globals only with a matching grant, never for sandboxes" {
    const shot: T.Caps = .{ .screencopy = true };
    const clip: T.Caps = .{ .data_control = true };
    try tt.expect(allowGlobal(.normal, .{}, true, false));
    try tt.expect(allowGlobal(.sandbox_hidden, .{}, false, false));
    try tt.expect(!allowGlobal(.sandbox_hidden, .{}, true, false));
    try tt.expect(!allowGlobal(.{ .privileged = shot }, .{}, false, false));
    try tt.expect(!allowGlobal(.{ .privileged = shot }, clip, false, false));
    try tt.expect(allowGlobal(.{ .privileged = shot }, shot, false, false));
    try tt.expect(!allowGlobal(.{ .privileged = shot }, shot, true, false));
    try tt.expect(allowGlobal(.{ .privileged = shot }, .{}, false, true));
    try tt.expect(!allowGlobal(.{ .privileged = shot }, .{}, true, true));
}

test "grants match exact absolute paths only" {
    const g = [_]T.Grant{.{ .path = "/usr/bin/grim", .caps = .{ .screencopy = true } }};
    try tt.expect(grantOf(&g, "/usr/bin/grim") != null);
    try tt.expect(grantOf(&g, "grim") == null);
    try tt.expect(grantOf(&g, "/usr/bin/grim2") == null);
    try tt.expect(grantOf(&g, "/home/u/.local/bin/grim") == null);
    try tt.expect(grantOf(&g, "") == null);
}

test "only the focused client or data-control may set the clipboard" {
    var a: u8 = 0;
    var b: u8 = 0;
    try tt.expect(maySetSelection(&a, &a, false));
    try tt.expect(!maySetSelection(&a, &b, false));
    try tt.expect(!maySetSelection(&a, null, false));
    try tt.expect(maySetSelection(&a, &b, true));
    try tt.expect(!maySetSelection(null, &a, true));
}

test "window rules: exact app_id, app_id prefix, title" {
    const sb = T.Rule{ .app_id_prefix = "vh-sandbox", .workspace = 9 };
    try tt.expect(ruleMatches(sb, "vh-sandbox", ""));
    try tt.expect(ruleMatches(sb, "vh-sandbox.firefox", "[песочница] x"));
    try tt.expect(!ruleMatches(sb, "firefox", ""));
    try tt.expect(!ruleMatches(sb, "", ""));
    const ex = T.Rule{ .app_id = "foot", .title = "htop" };
    try tt.expect(ruleMatches(ex, "foot", "htop"));
    try tt.expect(!ruleMatches(ex, "foot", "vim"));
    try tt.expect(!ruleMatches(ex, "footclient", "htop"));
    try tt.expect(ruleMatches(T.Rule{}, "anything", "at all"));
}

test "sandboxed clients never fullscreen themselves" {
    try tt.expect(!mayRequestFullscreen(true));
    try tt.expect(mayRequestFullscreen(false));
}
