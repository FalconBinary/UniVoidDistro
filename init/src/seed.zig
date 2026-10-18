//! vh-stage1: the boot half of seedrng natively. The algorithm is the one of seedrng.c
//! (Jason A. Donenfeld; runit-void ships the program and runs it in 05-misc.sh): the seed
//! files of /var/lib/seedrng are fed to the kernel (seed.credit through RNDADDENTROPY,
//! seed.no-credit by a plain write) and deleted, then a new seed, hashed from the old
//! ones and fresh random bytes, is written for the next boot. The shutdown hook
//! (30-seedrng.sh) keeps using the stock program; the files are compatible.
const std = @import("std");
const linux = std.os.linux;
const mem = std.mem;
const vh = @import("vh");
const sys = @import("sys.zig");
const Blake2s = std.crypto.hash.blake2.Blake2s256;

const dir = "/var/lib/seedrng";
const creditable_seed = "seed.credit";
const non_creditable_seed = "seed.no-credit";
const lock_file = "lock";
pub const min_len = 32;
pub const max_len = 512;
const RNDADDENTROPY: u32 = 0x40085203;
const GRND_NONBLOCK: u32 = 1;
const LOCK_EX: i32 = 2;

/// the seed length: the kernel pool size in bits / 8, between 32 and 512 bytes
pub fn optimalLen(poolsize: []const u8) usize {
    const bits = std.fmt.parseInt(usize, vh.strip(poolsize), 10) catch return min_len;
    return @min(@max(bits / 8, min_len), max_len);
}

/// seedrng at boot; skip_credit: SEEDRNG_SKIP_CREDIT=true in rc.conf
pub fn load(skip_credit: bool) void {
    _ = linux.syscall1(.umask, 0o077);
    defer _ = linux.syscall1(.umask, 0o022);
    const d = sys.p(dir);
    vh.mkdirs(d, 0o700);
    const dfd = vh.openFd(d, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0) catch {
        sys.fail("seedrng: {s}: {s}", .{ d, vh.serr() });
        return;
    };
    defer vh.close(dfd);
    const lfd = vh.sysRetry(linux.openat, .{ dfd, @as([*:0]const u8, lock_file), linux.O{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true }, @as(linux.mode_t, 0) }) catch {
        sys.fail("seedrng: lock: {s}", .{vh.serr()});
        return;
    };
    defer vh.close(@intCast(lfd));
    _ = vh.sysRetry(linux.flock, .{ @as(linux.fd_t, @intCast(lfd)), LOCK_EX }) catch {
        sys.fail("seedrng: flock: {s}", .{vh.serr()});
        return;
    };

    const new_len = optimalLen(vh.rd(sys.p("/proc/sys/kernel/random/poolsize")));
    var h = Blake2s.init(.{});
    h.update("SeedRNG v1 Old+New Prefix");
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    h.update(mem.asBytes(&ts));
    _ = linux.clock_gettime(.BOOTTIME, &ts);
    h.update(mem.asBytes(&ts));

    seedFromFile(dfd, non_creditable_seed, false, &h);
    seedFromFile(dfd, creditable_seed, !skip_credit, &h);

    var new_seed: [max_len]u8 = undefined;
    const is_creditable = readNewSeed(new_seed[0..new_len]);
    h.update(new_seed[0..new_len]);
    var digest: [Blake2s.digest_length]u8 = undefined;
    h.final(&digest);
    @memcpy(new_seed[0..digest.len], &digest);

    const name: [*:0]const u8 = if (is_creditable) creditable_seed else non_creditable_seed;
    const fd = vh.sysRetry(linux.openat, .{ dfd, name, linux.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(linux.mode_t, 0o400) }) catch {
        sys.fail("seedrng: {s}: {s}", .{ name, vh.serr() });
        return;
    };
    defer vh.close(@intCast(fd));
    vh.writeAllFd(@intCast(fd), new_seed[0..new_len]) catch {
        sys.fail("seedrng: writing the new seed: {s}", .{vh.serr()});
        return;
    };
    _ = linux.fsync(@intCast(fd));
    sys.detail("seedrng: {d} bytes {s}, new seed {s}", .{ new_len, if (skip_credit) "not credited" else "credited", name });
}

fn seedFromFile(dfd: linux.fd_t, name: [*:0]const u8, credit: bool, h: *Blake2s) void {
    const fd = vh.openAt(dfd, mem.span(name), .{ .ACCMODE = .RDONLY }) catch return;
    var seed: [max_len]u8 = undefined;
    var len: usize = 0;
    while (len < seed.len) {
        const r = vh.readFd(fd, seed[len..]) catch break;
        if (r == 0) break;
        len += r;
    }
    vh.close(fd);
    _ = vh.sysRetry(linux.unlinkat, .{ dfd, name, @as(u32, 0) }) catch {};
    if (len == 0) return;
    const rfd = vh.openFd(sys.p("/dev/urandom"), .{ .ACCMODE = .RDWR }, 0) catch {
        sys.fail("seedrng: /dev/urandom: {s}", .{vh.serr()});
        return;
    };
    defer vh.close(rfd);
    var done = false;
    if (credit) {
        // struct rand_pool_info { int entropy_count; int buf_size; __u32 buf[]; }
        const info = vh.gpa.alignedAlloc(u8, .@"4", 8 + len) catch vh.oom();
        mem.writeInt(i32, info[0..4], @intCast(len * 8), .little);
        mem.writeInt(i32, info[4..8], @intCast(len), .little);
        @memcpy(info[8..], seed[0..len]);
        if (vh.sys(linux.ioctl(rfd, RNDADDENTROPY, @intFromPtr(info.ptr)))) |_| {
            done = true;
        } else |_| sys.note("seedrng: RNDADDENTROPY: {s}; the seed is written without credit", .{vh.serr()});
    }
    if (!done) vh.writeAllFd(rfd, seed[0..len]) catch {};
    h.update(mem.asBytes(&len));
    h.update(seed[0..len]);
}

/// fresh bytes: creditable when getrandom gives them without blocking
fn readNewSeed(buf: []u8) bool {
    const r = linux.getrandom(buf.ptr, buf.len, GRND_NONBLOCK);
    if (linux.errno(r) == .SUCCESS and r == buf.len) return true;
    const fd = vh.openFd(sys.p("/dev/urandom"), .{ .ACCMODE = .RDONLY }, 0) catch return false;
    defer vh.close(fd);
    var got: usize = 0;
    while (got < buf.len) {
        const n = vh.readFd(fd, buf[got..]) catch break;
        if (n == 0) break;
        got += n;
    }
    return false;
}

const testing = std.testing;

test "seedrng: the seed length follows the pool size" {
    try testing.expectEqual(@as(usize, 32), optimalLen("256\n"));
    try testing.expectEqual(@as(usize, 32), optimalLen("64"));
    try testing.expectEqual(@as(usize, 512), optimalLen("8192"));
    try testing.expectEqual(@as(usize, 128), optimalLen("1024"));
    try testing.expectEqual(@as(usize, 32), optimalLen(""));
}
