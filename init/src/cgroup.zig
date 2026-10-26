//! vh-init: cgroup2 for the services. Every service runs in /sys/fs/cgroup/vh/NAME: the
//! manager kills the whole tree of a service (cgroup.kill), finds the processes of a service
//! it did not start itself (a new manager after a crash picks them up), and applies the limits
//! of the .svc file (memory.max, cpu.weight). Stage 1 mounts cgroup2 with nsdelegate; in a
//! container without a writable cgroup tree every call here fails quietly and the manager
//! works without cgroups (it says so once).
const std = @import("std");
const linux = std.os.linux;
const mem = std.mem;
const vh = @import("vh");

pub const root = "/sys/fs/cgroup";
pub const slice = root ++ "/vh";

pub var available = false;

/// the vh slice with the cpu, memory and pids controllers; true when services can be put there
pub fn setup() bool {
    if (!vh.isDir(root)) return false;
    _ = linux.mkdir(slice, 0o755);
    if (!vh.isDir(slice)) return false;
    // the controllers the limits need; a kernel or container without them: the limits are skipped
    _ = vh.writeStr(root ++ "/cgroup.subtree_control", "+cpu +memory +pids");
    _ = vh.writeStr(slice ++ "/cgroup.subtree_control", "+cpu +memory +pids");
    available = vh.writeStr(slice ++ "/cgroup.procs", "");
    // an empty write tests nothing; the test is whether a child directory can be made
    _ = linux.mkdir(slice ++ "/.probe", 0o755);
    available = vh.isDir(slice ++ "/.probe");
    _ = linux.rmdir(slice ++ "/.probe");
    return available;
}

pub fn path(name: []const u8) []u8 {
    return vh.fmt("{s}/{s}", .{ slice, name });
}

/// the service's cgroup, made if missing; the limits applied
pub fn create(name: []const u8, memory_max: ?u64, cpu_weight: ?u32) bool {
    if (!available) return false;
    const p = path(name);
    _ = linux.mkdir(vh.z(p).ptr, 0o755);
    if (!vh.isDir(p)) return false;
    if (memory_max) |m| _ = vh.writeStr(vh.fmt("{s}/memory.max", .{p}), vh.fmt("{d}", .{m}));
    if (cpu_weight) |w| _ = vh.writeStr(vh.fmt("{s}/cpu.weight", .{p}), vh.fmt("{d}", .{w}));
    return true;
}

/// kill every process of the service's cgroup (cgroup.kill, Linux 5.14+); false when it is not there
pub fn kill(name: []const u8) bool {
    if (!available) return false;
    return vh.writeStr(vh.fmt("{s}/cgroup.kill", .{path(name)}), "1");
}

/// the processes in the service's cgroup
pub fn procs(name: []const u8) []const linux.pid_t {
    var out: std.ArrayList(linux.pid_t) = .empty;
    if (!available) return out.items;
    const text = vh.readFile(vh.fmt("{s}/cgroup.procs", .{path(name)})) catch return out.items;
    var it = mem.tokenizeAny(u8, text, "\n ");
    while (it.next()) |w| out.append(vh.gpa, std.fmt.parseInt(linux.pid_t, w, 10) catch continue) catch vh.oom();
    return out.items;
}

/// remove an empty cgroup
pub fn remove(name: []const u8) void {
    if (!available) return;
    _ = linux.rmdir(vh.z(path(name)).ptr);
}

/// the names of the cgroups under the slice (services a previous manager left running)
pub fn list() []const []const u8 {
    if (!available) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (vh.listDir(slice) catch &.{}) |n| {
        if (n.len == 0 or n[0] == '.' or vh.startsWith(n, "cgroup.") or vh.startsWith(n, "cpu.") or vh.startsWith(n, "memory.") or vh.startsWith(n, "pids.") or vh.startsWith(n, "io.")) continue;
        if (vh.isDir(vh.fmt("{s}/{s}", .{ slice, n }))) out.append(vh.gpa, n) catch vh.oom();
    }
    return out.items;
}
