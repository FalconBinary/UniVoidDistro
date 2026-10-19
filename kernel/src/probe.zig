//! vh-kconf probe: sysfs, procfs and the device tree -> hw.zon. Reads only; never a serial
//! number, a MAC address or a UUID: not the DMI serials, not a network interface's address,
//! not the Uniq or Phys of an input device, not the device tree's serial-number. With
//! --save DIR every file and symlink it read is copied under DIR (a snapshot with the shape
//! of sysfs); with --from DIR it reads such a snapshot instead of the live system, so the
//! probe runs on a Mac and in unit tests (tests/kernel/fixtures).
//!
//! The probe records facts, not judgements: no vendor or model is named here. What a fact
//! means for the machine (a laptop, a hybrid GPU, an IOMMU) is decided by the rules of
//! hwdb/ in vh-plan.
const std = @import("std");
const vh = @import("vh");
const hw = @import("hw.zig");
const linux = std.os.linux;
const mem = std.mem;

/// Where the files come from: the live system (root "") or a snapshot directory. Every read
/// goes through here so that --save sees it.
pub const Src = struct {
    root: []const u8 = "",
    save: ?[]const u8 = null,

    fn abs(self: *const Src, rel: []const u8) []const u8 {
        return vh.fmt("{s}{s}", .{ self.root, rel });
    }

    /// a whole file, null when absent or unreadable
    pub fn read(self: *const Src, rel: []const u8) ?[]const u8 {
        const data = vh.readFile(self.abs(rel)) catch return null;
        if (self.save) |dir| self.saveFile(dir, rel, data);
        return data;
    }

    /// the first line of a sysfs/proc file without surrounding whitespace, "" when absent
    pub fn line(self: *const Src, rel: []const u8) []const u8 {
        const data = self.read(rel) orelse return "";
        const end = mem.indexOfScalar(u8, data, '\n') orelse data.len;
        return vh.dupe(vh.strip(data[0..end]));
    }

    /// directory entries, sorted; empty when absent. Names starting with a dot are skipped:
    /// sysfs and procfs have none, and a snapshot copied through macOS may carry AppleDouble
    /// ("._name") or .DS_Store files
    pub fn list(self: *const Src, rel: []const u8) []const []const u8 {
        const entries = vh.listDir(self.abs(rel)) catch return &.{};
        if (self.save) |dir| vh.mkdirs(vh.fmt("{s}{s}", .{ dir, self.resolve(dir, rel) }), 0o755);
        var kept: std.ArrayList([]const u8) = .empty;
        for (entries) |e| if (e.len > 0 and e[0] != '.') kept.append(vh.gpa, e) catch vh.oom();
        mem.sort([]const u8, kept.items, {}, vh.lessStr);
        return kept.items;
    }

    /// the target of a symlink, null when it is not one
    pub fn link(self: *const Src, rel: []const u8) ?[]const u8 {
        const target = vh.readlink(self.abs(rel)) catch return null;
        if (self.save) |dir| self.saveLink(dir, rel, target);
        return target;
    }

    /// Whether `rel` exists. In a snapshot a directory is recreated and a file is marked by
    /// an empty one, so that the replay answers the same; the content is not copied.
    pub fn exists(self: *const Src, rel: []const u8) bool {
        const ok = vh.pathExists(self.abs(rel));
        if (ok) {
            if (self.save) |dir| {
                const path = vh.fmt("{s}{s}", .{ dir, self.resolve(dir, rel) });
                if (vh.isDir(self.abs(rel))) vh.mkdirs(path, 0o755) else self.mark(path);
            }
        }
        return ok;
    }

    /// A file read through a filter: the snapshot gets the filtered text, never the original
    /// (cpuinfo without a board's Serial line, mounts without paths, input devices without
    /// addresses).
    pub fn readClean(self: *const Src, rel: []const u8, comptime clean: fn ([]const u8) []const u8) ?[]const u8 {
        const raw = vh.readFile(self.abs(rel)) catch return null;
        const data = clean(raw);
        if (self.save) |dir| self.saveFile(dir, rel, data);
        return data;
    }

    /// the names in a directory whose entries are facts by name alone (ACPI tables: the
    /// signature, never the content); a snapshot gets an empty file for each
    pub fn names(self: *const Src, rel: []const u8) []const []const u8 {
        const all = self.list(rel);
        if (self.save) |dir| {
            const resolved = self.resolve(dir, rel);
            for (all) |n| {
                if (vh.isDir(self.abs(vh.fmt("{s}/{s}", .{ rel, n })))) continue;
                self.mark(vh.fmt("{s}{s}/{s}", .{ dir, resolved, n }));
            }
        }
        return all;
    }

    fn mark(_: *const Src, path: []const u8) void {
        if (vh.pathExists(path)) return;
        vh.mkdirs(dirname(path), 0o755);
        vh.writeAtomic(path, "", 0o644);
    }

    /// `rel` with every symlink on the way resolved (the real path under /sys/devices of a
    /// /sys/class or /sys/block entry); with --save the symlinks are recreated in the snapshot
    pub fn real(self: *const Src, rel: []const u8) []const u8 {
        return self.walk(self.save, rel);
    }

    /// Walk `rel` component by component under the live root; every symlink on the way is
    /// recreated under `dir` with the same relative target, so that the snapshot resolves
    /// exactly as sysfs does. Returns the resolved path.
    fn resolve(self: *const Src, dir: []const u8, rel: []const u8) []const u8 {
        return self.walk(dir, rel);
    }

    fn walk(self: *const Src, save_dir: ?[]const u8, rel: []const u8) []const u8 {
        var cur: []const u8 = "";
        var it = mem.tokenizeScalar(u8, rel, '/');
        while (it.next()) |comp| {
            const next = vh.fmt("{s}/{s}", .{ cur, comp });
            const st = vh.stat(self.abs(next), false) catch {
                cur = next;
                continue;
            };
            if (vh.S.isLnk(st.mode)) {
                const target = vh.readlink(self.abs(next)) catch {
                    cur = next;
                    continue;
                };
                if (save_dir) |dir| writeLink(vh.fmt("{s}{s}", .{ dir, next }), target);
                cur = joinRel(next, target);
            } else {
                cur = next;
            }
        }
        return cur;
    }

    fn saveFile(self: *const Src, dir: []const u8, rel: []const u8, data: []const u8) void {
        const path = vh.fmt("{s}{s}", .{ dir, self.resolve(dir, rel) });
        vh.mkdirs(dirname(path), 0o755);
        vh.writeAtomic(path, data, 0o644);
    }

    fn saveLink(self: *const Src, dir: []const u8, rel: []const u8, target: []const u8) void {
        const parent = dirname(rel);
        const real_parent = self.resolve(dir, parent);
        writeLink(vh.fmt("{s}{s}/{s}", .{ dir, real_parent, basename(rel) }), target);
    }
};

fn writeLink(path: []const u8, target: []const u8) void {
    vh.mkdirs(dirname(path), 0o755);
    _ = vh.sys(linux.symlink(vh.z(target).ptr, vh.z(path).ptr)) catch {
        if (vh.errno != .EXIST) vh.die("{s}: {s}", .{ path, vh.serr() });
    };
}

pub fn basename(path: []const u8) []const u8 {
    const p = mem.trimEnd(u8, path, "/");
    return if (mem.lastIndexOfScalar(u8, p, '/')) |i| p[i + 1 ..] else p;
}

pub fn dirname(path: []const u8) []const u8 {
    const p = mem.trimEnd(u8, path, "/");
    return if (mem.lastIndexOfScalar(u8, p, '/')) |i| p[0..i] else "";
}

/// `target` relative to the directory of `base` (absolute targets stay), "." and ".." applied
pub fn joinRel(base: []const u8, target: []const u8) []const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    if (target.len == 0 or target[0] != '/') {
        var bit = mem.tokenizeScalar(u8, dirname(base), '/');
        while (bit.next()) |c| parts.append(vh.gpa, c) catch vh.oom();
    }
    var tit = mem.tokenizeScalar(u8, target, '/');
    while (tit.next()) |c| {
        if (vh.eql(c, ".")) continue;
        if (vh.eql(c, "..")) {
            if (parts.items.len > 0) _ = parts.pop();
            continue;
        }
        parts.append(vh.gpa, c) catch vh.oom();
    }
    return vh.fmt("/{s}", .{mem.join(vh.gpa, "/", parts.items) catch vh.oom()});
}

// ---------------------------------------------------------------- the probe

pub fn run(src: *const Src) hw.Hw {
    var h: hw.Hw = .{};
    h.probe.kernel = src.line("/proc/sys/kernel/osrelease");
    h.probe.source = if (src.root.len == 0) "live" else vh.dupe(basename(src.root));
    h.machine = machine(src);
    h.cpu = cpu(src);
    h.arch = arch(src, h.cpu);
    h.memory = memory(src);
    h.firmware = firmware(src);
    h.virt = .{ .sys_type = src.line("/sys/hypervisor/type") };
    h.filesystems = filesystems(src);
    h.modules = modules(src);
    h.devices = devices(src);
    h.blocks = blocks(src);
    h.net = net(src);
    h.power = power(src);
    h.displays = displays(src, h.devices);
    h.keyboards = keyboards(src);
    h.sound = sound(src);
    return h;
}

/// uname -m of the probed kernel: /proc/sys/kernel/arch, uname(2) on the live system, else
/// what cpuinfo shows (a snapshot of a kernel without the sysctl)
fn arch(src: *const Src, c: hw.Cpu) []const u8 {
    const a = src.line("/proc/sys/kernel/arch");
    if (a.len > 0) return a;
    if (src.root.len == 0) {
        var uts: linux.utsname = undefined;
        if (linux.uname(&uts) == 0) return vh.dupe(mem.sliceTo(&uts.machine, 0));
    }
    if (c.implementer.len > 0) return "aarch64";
    if (c.vendor.len > 0) return "x86_64";
    return "";
}

fn memory(src: *const Src) hw.Memory {
    const info = src.read("/proc/meminfo") orelse return .{};
    var lines = mem.tokenizeScalar(u8, info, '\n');
    while (lines.next()) |l| {
        if (!vh.startsWith(l, "MemTotal:")) continue;
        var it = mem.tokenizeAny(u8, l["MemTotal:".len..], " \t");
        const n = it.next() orelse break;
        return .{ .total_kib = std.fmt.parseInt(u64, n, 10) catch 0 };
    }
    return .{};
}

fn machine(src: *const Src) hw.Machine {
    const d = "/sys/class/dmi/id/";
    return .{
        .sys_vendor = src.line(d ++ "sys_vendor"),
        .product_name = src.line(d ++ "product_name"),
        .product_family = src.line(d ++ "product_family"),
        .product_version = src.line(d ++ "product_version"),
        .board_vendor = src.line(d ++ "board_vendor"),
        .board_name = src.line(d ++ "board_name"),
        .bios_vendor = src.line(d ++ "bios_vendor"),
        .bios_version = src.line(d ++ "bios_version"),
        .bios_date = src.line(d ++ "bios_date"),
        .chassis_type = src.line(d ++ "chassis_type"),
    };
}

fn cpu(src: *const Src) hw.Cpu {
    var c: hw.Cpu = .{};
    const info = src.readClean("/proc/cpuinfo", cleanCpuinfo) orelse "";
    var lines = mem.tokenizeScalar(u8, info, '\n');
    var threads: u32 = 0;
    var first = true;
    var features: []const u8 = "";
    while (lines.next()) |raw| {
        const colon = mem.indexOfScalar(u8, raw, ':') orelse continue;
        const key = vh.strip(raw[0..colon]);
        const val = vh.dupe(vh.strip(raw[colon + 1 ..]));
        if (vh.eql(key, "processor")) {
            threads += 1;
            if (threads > 1) first = false;
            continue;
        }
        if (!first) continue;
        if (vh.eql(key, "vendor_id")) c.vendor = val else if (vh.eql(key, "cpu family")) c.family = num(val) else if (vh.eql(key, "model")) c.model = num(val) else if (vh.eql(key, "model name")) c.model_name = val else if (vh.eql(key, "stepping")) c.stepping = num(val) else if (vh.eql(key, "microcode")) c.microcode = val else if (vh.eql(key, "cpu cores")) c.cores = num(val) else if (vh.eql(key, "flags")) c.flags = val else if (vh.eql(key, "Features")) features = val else if (vh.eql(key, "CPU implementer")) c.implementer = val else if (vh.eql(key, "CPU part")) c.part = val;
    }
    // ARM names its feature flags "Features"; the rules read both as flags
    if (c.flags.len == 0) c.flags = features;
    // what sysfs says wins over the cpuinfo count: every present CPU, online or not
    var present: std.ArrayList(u32) = .empty;
    for (src.list("/sys/devices/system/cpu")) |n| {
        if (n.len > 3 and vh.startsWith(n, "cpu") and allDigits(n[3..])) present.append(vh.gpa, num(n[3..])) catch vh.oom();
    }
    mem.sort(u32, present.items, {}, std.sort.asc(u32));
    c.threads = if (present.items.len > 0) @intCast(present.items.len) else threads;
    c.possible = countList(src.line("/sys/devices/system/cpu/possible"));
    c.smt = vh.eql(src.line("/sys/devices/system/cpu/smt/active"), "1");
    for (src.list("/sys/devices/system/cpu/cpufreq")) |p| {
        if (!vh.startsWith(p, "policy")) continue;
        const pd = vh.fmt("/sys/devices/system/cpu/cpufreq/{s}/", .{p});
        c.freq_driver = src.line(vh.fmt("{s}scaling_driver", .{pd}));
        c.epp = src.exists(vh.fmt("{s}energy_performance_available_preferences", .{pd}));
        break;
    }
    c.topology = topology(src, present.items);
    if (c.cores == 0) c.cores = countCores(c.topology);
    c.numa = numa(src);
    var vulns: std.ArrayList(hw.Vulnerability) = .empty;
    for (src.list("/sys/devices/system/cpu/vulnerabilities")) |n| {
        vulns.append(vh.gpa, .{ .name = n, .state = src.line(vh.fmt("/sys/devices/system/cpu/vulnerabilities/{s}", .{n})) }) catch vh.oom();
    }
    c.vulnerabilities = vulns.items;
    var caches: std.ArrayList(hw.Cache) = .empty;
    const cdir = "/sys/devices/system/cpu/cpu0/cache";
    for (src.list(cdir)) |n| {
        if (!vh.startsWith(n, "index")) continue;
        const p = vh.fmt("{s}/{s}/", .{ cdir, n });
        caches.append(vh.gpa, .{
            .level = num(src.line(vh.fmt("{s}level", .{p}))),
            .kind = src.line(vh.fmt("{s}type", .{p})),
            .size_kb = sizeKb(src.line(vh.fmt("{s}size", .{p}))),
            .shared = src.line(vh.fmt("{s}shared_cpu_list", .{p})),
        }) catch vh.oom();
    }
    c.caches = caches.items;
    return c;
}

fn num(s: []const u8) u32 {
    return std.fmt.parseInt(u32, s, 0) catch 0;
}

/// "32K", "12288K", "1M" -> KiB
fn sizeKb(s: []const u8) u32 {
    if (s.len == 0) return 0;
    const unit = s[s.len - 1];
    const digits = if (std.ascii.isDigit(unit)) s else s[0 .. s.len - 1];
    const n = std.fmt.parseInt(u32, digits, 10) catch return 0;
    return switch (unit) {
        'M' => n * 1024,
        'G' => n * 1024 * 1024,
        else => n,
    };
}

/// every present CPU: its package, die, cluster, core, SMT siblings, last-level cache,
/// maximum frequency, capacity and, on a hybrid Intel CPU, its core type
fn topology(src: *const Src, present: []const u32) []const hw.CpuTopo {
    const p_cores = src.line("/sys/devices/cpu_core/cpus");
    const e_cores = src.line("/sys/devices/cpu_atom/cpus");
    var out: std.ArrayList(hw.CpuTopo) = .empty;
    for (present) |n| {
        const d = vh.fmt("/sys/devices/system/cpu/cpu{d}", .{n});
        var t: hw.CpuTopo = .{ .cpu = n };
        t.package = num(src.line(vh.fmt("{s}/topology/physical_package_id", .{d})));
        t.die = num(src.line(vh.fmt("{s}/topology/die_id", .{d})));
        t.cluster = num(src.line(vh.fmt("{s}/topology/cluster_id", .{d})));
        t.core = num(src.line(vh.fmt("{s}/topology/core_id", .{d})));
        t.siblings = src.line(vh.fmt("{s}/topology/core_cpus_list", .{d}));
        if (t.siblings.len == 0) t.siblings = src.line(vh.fmt("{s}/topology/thread_siblings_list", .{d}));
        // the last-level cache: the highest level this CPU has
        var level: u32 = 0;
        for (src.list(vh.fmt("{s}/cache", .{d}))) |ix| {
            if (!vh.startsWith(ix, "index")) continue;
            const p = vh.fmt("{s}/cache/{s}/", .{ d, ix });
            const l = num(src.line(vh.fmt("{s}level", .{p})));
            if (l <= level) continue;
            level = l;
            t.llc = src.line(vh.fmt("{s}shared_cpu_list", .{p}));
            t.llc_kb = sizeKb(src.line(vh.fmt("{s}size", .{p})));
        }
        t.max_khz = num(src.line(vh.fmt("{s}/cpufreq/cpuinfo_max_freq", .{d})));
        t.capacity = num(src.line(vh.fmt("{s}/cpu_capacity", .{d})));
        if (inList(p_cores, n)) t.kind = "core" else if (inList(e_cores, n)) t.kind = "atom";
        out.append(vh.gpa, t) catch vh.oom();
    }
    return out.items;
}

/// physical cores: the distinct (package, die, core) of the topology
fn countCores(topo: []const hw.CpuTopo) u32 {
    var seen: std.AutoHashMapUnmanaged([3]u32, void) = .empty;
    for (topo) |t| seen.put(vh.gpa, .{ t.package, t.die, t.core }, {}) catch vh.oom();
    return seen.count();
}

/// the CPU list of every NUMA node, in node order
fn numa(src: *const Src) []const []const u8 {
    var nodes: std.ArrayList(u32) = .empty;
    for (src.list("/sys/devices/system/node")) |n| {
        if (n.len > 4 and vh.startsWith(n, "node") and allDigits(n[4..])) nodes.append(vh.gpa, num(n[4..])) catch vh.oom();
    }
    mem.sort(u32, nodes.items, {}, std.sort.asc(u32));
    var out: std.ArrayList([]const u8) = .empty;
    for (nodes.items) |n| out.append(vh.gpa, src.line(vh.fmt("/sys/devices/system/node/node{d}/cpulist", .{n}))) catch vh.oom();
    return out.items;
}

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

/// the number of CPUs in a sysfs CPU list: "0-11" -> 12, "0,2-5,8" -> 6, "" -> 0
pub fn countList(s: []const u8) u32 {
    var n: u32 = 0;
    var it = mem.tokenizeScalar(u8, s, ',');
    while (it.next()) |part| {
        if (mem.indexOfScalar(u8, part, '-')) |dash| {
            const a = std.fmt.parseInt(u32, vh.strip(part[0..dash]), 10) catch continue;
            const b = std.fmt.parseInt(u32, vh.strip(part[dash + 1 ..]), 10) catch continue;
            if (b >= a) n += b - a + 1;
        } else if (std.fmt.parseInt(u32, vh.strip(part), 10)) |_| {
            n += 1;
        } else |_| {}
    }
    return n;
}

/// whether CPU `cpu` is in a sysfs CPU list
pub fn inList(s: []const u8, cpu_n: u32) bool {
    var it = mem.tokenizeScalar(u8, s, ',');
    while (it.next()) |part| {
        if (mem.indexOfScalar(u8, part, '-')) |dash| {
            const a = std.fmt.parseInt(u32, vh.strip(part[0..dash]), 10) catch continue;
            const b = std.fmt.parseInt(u32, vh.strip(part[dash + 1 ..]), 10) catch continue;
            if (cpu_n >= a and cpu_n <= b) return true;
        } else if (std.fmt.parseInt(u32, vh.strip(part), 10)) |x| {
            if (x == cpu_n) return true;
        } else |_| {}
    }
    return false;
}

/// cpuinfo without the lines that identify one board (the Raspberry Pi kernel prints Serial)
fn cleanCpuinfo(raw: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = mem.splitScalar(u8, raw, '\n');
    var first = true;
    while (lines.next()) |l| {
        const colon = mem.indexOfScalar(u8, l, ':');
        if (colon) |c| {
            const key = vh.strip(l[0..c]);
            if (vh.eql(key, "Serial")) continue;
        }
        if (!first) out.append(vh.gpa, '\n') catch vh.oom();
        first = false;
        out.appendSlice(vh.gpa, l) catch vh.oom();
    }
    return out.items;
}

/// mounts with only the file system type: no device names, no mount points
fn cleanMounts(raw: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = mem.tokenizeScalar(u8, raw, '\n');
    while (lines.next()) |l| {
        var it = mem.tokenizeAny(u8, l, " \t");
        _ = it.next();
        _ = it.next();
        const fstype = it.next() orelse continue;
        out.print(vh.gpa, "- - {s} - 0 0\n", .{fstype}) catch vh.oom();
    }
    return out.items;
}

/// the efivar value byte: four bytes of attributes, then the value
fn efiBool(src: *const Src, name: []const u8) ?bool {
    const data = src.read(vh.fmt("/sys/firmware/efi/efivars/{s}", .{name})) orelse return null;
    if (data.len <= 4) return null;
    return data[4] == 1;
}

fn firmware(src: *const Src) hw.Firmware {
    var f: hw.Firmware = .{};
    f.efi = src.exists("/sys/firmware/efi");
    if (f.efi) {
        f.efi_bits = num(src.line("/sys/firmware/efi/fw_platform_size"));
        // the UEFI global variables by name; no other variable is read
        for (src.list("/sys/firmware/efi/efivars")) |n| {
            if (vh.startsWith(n, "SecureBoot-")) {
                f.secure_boot = efiBool(src, n);
            } else if (vh.startsWith(n, "SetupMode-")) {
                f.setup_mode = efiBool(src, n);
            } else if (vh.startsWith(n, "MemoryOverwriteRequestControl-")) {
                f.mor = src.exists(vh.fmt("/sys/firmware/efi/efivars/{s}", .{n}));
            }
        }
    }
    f.tpm = src.exists("/sys/class/tpm/tpm0");
    if (f.tpm) {
        f.tpm_version = num(src.line("/sys/class/tpm/tpm0/tpm_version_major"));
        if (src.link("/sys/class/tpm/tpm0/device/driver")) |t| f.tpm_driver = vh.dupe(basename(t));
    }
    // the ACPI tables by signature only: their content is never read (MSDM holds a product key)
    var tables: vh.Strv = .{};
    for (src.names("/sys/firmware/acpi/tables")) |n| {
        if (vh.eql(n, "data") or vh.eql(n, "dynamic")) continue;
        const sig = n[0..@min(n.len, 4)];
        if (!tables.has(sig)) tables.add(sig);
    }
    tables.sort();
    f.acpi_tables = tables.slice();
    for (src.list("/sys/class/iommu")) |n| {
        if (src.link(vh.fmt("/sys/class/iommu/{s}", .{n})) != null) f.iommu_units += 1;
    }
    // the device tree of a board: the model and the compatible list, nothing else
    if (src.read("/sys/firmware/devicetree/base/model")) |m| f.dt_model = vh.dupe(mem.trimEnd(u8, m, "\x00\n"));
    if (src.read("/sys/firmware/devicetree/base/compatible")) |cpt| {
        var list: vh.Strv = .{};
        var it = mem.tokenizeScalar(u8, cpt, 0);
        while (it.next()) |x| list.add(x);
        f.dt_compatible = list.slice();
    }
    return f;
}

fn filesystems(src: *const Src) []const []const u8 {
    var set: vh.Strv = .{};
    const mounts = src.readClean("/proc/mounts", cleanMounts) orelse "";
    var lines = mem.tokenizeScalar(u8, mounts, '\n');
    while (lines.next()) |l| {
        var it = mem.tokenizeAny(u8, l, " \t");
        _ = it.next();
        _ = it.next();
        const fstype = it.next() orelse continue;
        if (!set.has(fstype)) set.add(fstype);
    }
    set.sort();
    return set.slice();
}

fn modules(src: *const Src) []const []const u8 {
    var set: vh.Strv = .{};
    const text = src.read("/proc/modules") orelse "";
    var lines = mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |l| {
        var it = mem.tokenizeAny(u8, l, " \t");
        const name = it.next() orelse continue;
        if (!set.has(name)) set.add(name);
    }
    set.sort();
    return set.slice();
}

fn devices(src: *const Src) []const hw.Device {
    var devs: std.ArrayList(hw.Device) = .empty;
    for (src.list("/sys/bus")) |bus| {
        const ddir = vh.fmt("/sys/bus/{s}/devices", .{bus});
        for (src.list(ddir)) |name| {
            const base = vh.fmt("{s}/{s}", .{ ddir, name });
            const modalias = src.line(vh.fmt("{s}/modalias", .{base}));
            if (modalias.len == 0) continue;
            var d: hw.Device = .{ .bus = vh.dupe(bus), .name = vh.dupe(name), .modalias = modalias };
            if (src.link(vh.fmt("{s}/driver", .{base}))) |t| {
                d.driver = vh.dupe(basename(t));
                if (src.link(vh.fmt("{s}/driver/module", .{base}))) |m| d.module = vh.dupe(basename(m));
            }
            devs.append(vh.gpa, d) catch vh.oom();
        }
    }
    // the DMI alias (dmi: patterns of platform drivers), not on a bus
    const dmi = src.line("/sys/class/dmi/id/modalias");
    if (dmi.len > 0) devs.append(vh.gpa, .{ .bus = "dmi", .name = "id", .modalias = dmi }) catch vh.oom();
    mem.sort(hw.Device, devs.items, {}, lessDevice);
    return devs.items;
}

fn lessDevice(_: void, a: hw.Device, b: hw.Device) bool {
    const o = mem.order(u8, a.bus, b.bus);
    if (o != .eq) return o == .lt;
    return mem.order(u8, a.name, b.name) == .lt;
}

// ---------------------------------------------------------------- what hangs off the buses

/// the driver bound to a device directory, with its module ("" when built in)
fn linkOf(src: *const Src, dev: []const u8) ?hw.Link {
    const t = src.link(vh.fmt("{s}/driver", .{dev})) orelse return null;
    var l: hw.Link = .{ .driver = vh.dupe(basename(t)) };
    if (src.link(vh.fmt("{s}/driver/module", .{dev}))) |m| l.module = vh.dupe(basename(m));
    return l;
}

/// the drivers from a device directory up to the top of /sys/devices, nearest first
pub fn driverChain(src: *const Src, path: []const u8) []const hw.Link {
    var out: std.ArrayList(hw.Link) = .empty;
    var cur = path;
    while (vh.startsWith(cur, "/sys/devices/")) : (cur = dirname(cur)) {
        if (linkOf(src, cur)) |l| out.append(vh.gpa, l) catch vh.oom();
    }
    return out.items;
}

/// how a device is attached, from its real path under /sys/devices: usb, virtio, mmc, nvme,
/// ata, scsi, pci, platform, other (a USB disk is "usb" even though SCSI carries it)
pub fn busOf(path: []const u8) []const u8 {
    const has = struct {
        fn f(p: []const u8, s: []const u8) bool {
            return mem.indexOf(u8, p, s) != null;
        }
    }.f;
    if (has(path, "/usb")) return "usb";
    if (has(path, "/virtio")) return "virtio";
    if (has(path, "/mmc_host/")) return "mmc";
    if (has(path, "/nvme")) return "nvme";
    if (has(path, "/ata")) return "ata";
    if (has(path, "/host") and has(path, "/target")) return "scsi";
    if (vh.startsWith(path, "/sys/devices/pci")) return "pci";
    if (vh.startsWith(path, "/sys/devices/platform/")) return "platform";
    return "other";
}

/// a name that carries a hardware address (a MAC in "wlx001122334455" or
/// "hid-00:11:22:33:44:55-battery") is never written
fn addressLike(name: []const u8) bool {
    var colons: usize = 0;
    var hex_run: usize = 0;
    for (name) |ch| {
        if (ch == ':') colons += 1;
        hex_run = if (std.ascii.isHex(ch)) hex_run + 1 else 0;
        if (hex_run >= 12) return true;
    }
    return colons >= 5;
}

/// disks that are not hardware: loop devices, RAM disks, zram, device mapper, RAID, optical
fn virtualDisk(name: []const u8) bool {
    const skip = [_][]const u8{ "loop", "ram", "zram", "dm-", "md", "sr", "fd", "nbd", "zd" };
    for (skip) |s| if (vh.startsWith(name, s)) return true;
    // the boot and RPMB partitions of an eMMC are separate block devices
    if (vh.startsWith(name, "mmcblk") and (mem.indexOf(u8, name, "boot") != null or mem.indexOf(u8, name, "rpmb") != null)) return true;
    return false;
}

fn blocks(src: *const Src) []const hw.Block {
    var out: std.ArrayList(hw.Block) = .empty;
    for (src.list("/sys/block")) |name| {
        if (virtualDisk(name)) continue;
        const base = vh.fmt("/sys/block/{s}", .{name});
        const real = src.real(base);
        var b: hw.Block = .{ .name = vh.dupe(name) };
        // the kernel's own names settle the bus where the path does not (NVMe multipath
        // namespaces live under /sys/devices/virtual)
        b.bus = if (vh.startsWith(name, "nvme")) "nvme" else if (vh.startsWith(name, "mmcblk")) "mmc" else if (vh.startsWith(name, "vd")) "virtio" else busOf(real);
        b.rotational = vh.eql(src.line(vh.fmt("{s}/queue/rotational", .{base})), "1");
        b.removable = vh.eql(src.line(vh.fmt("{s}/removable", .{base})), "1");
        b.logical_block = num(src.line(vh.fmt("{s}/queue/logical_block_size", .{base})));
        b.physical_block = num(src.line(vh.fmt("{s}/queue/physical_block_size", .{base})));
        b.discard = (std.fmt.parseInt(u64, src.line(vh.fmt("{s}/queue/discard_max_bytes", .{base})), 10) catch 0) > 0;
        b.size_mib = (std.fmt.parseInt(u64, src.line(vh.fmt("{s}/size", .{base})), 10) catch 0) / 2048;
        b.model = src.line(vh.fmt("{s}/device/model", .{base}));
        if (b.model.len == 0) b.model = src.line(vh.fmt("{s}/device/name", .{base}));
        b.drivers = driverChain(src, real);
        if (b.drivers.len == 0) {
            // an NVMe namespace under native multipath hangs off its subsystem, a virtual
            // device: the drivers are those of the subsystem's controllers (the nvmeN links)
            const dev = vh.fmt("{s}/device", .{base});
            for (src.list(dev)) |e| {
                if (!vh.startsWith(e, "nvme") or !allDigits(e[4..])) continue;
                if (src.link(vh.fmt("{s}/{s}", .{ dev, e })) == null) continue;
                b.drivers = driverChain(src, src.real(vh.fmt("{s}/{s}", .{ dev, e })));
                if (b.drivers.len > 0) break;
            }
        }
        out.append(vh.gpa, b) catch vh.oom();
    }
    return out.items;
}

fn net(src: *const Src) []const hw.Net {
    var out: std.ArrayList(hw.Net) = .empty;
    for (src.list("/sys/class/net")) |name| {
        const base = vh.fmt("/sys/class/net/{s}", .{name});
        // an interface without a device is virtual: lo, bridges, tunnels
        if (src.link(vh.fmt("{s}/device", .{base})) == null) continue;
        const real = src.real(vh.fmt("{s}/device", .{base}));
        var n: hw.Net = .{
            .name = if (addressLike(name)) "(named by its address)" else vh.dupe(name),
            .wireless = src.exists(vh.fmt("{s}/phy80211", .{base})) or src.exists(vh.fmt("{s}/wireless", .{base})),
            .bus = busOf(real),
            .path = if (vh.startsWith(real, "/sys/devices/")) real["/sys/devices/".len..] else real,
        };
        if (linkOf(src, real)) |l| {
            n.driver = l.driver;
            n.module = l.module;
        }
        out.append(vh.gpa, n) catch vh.oom();
    }
    return out.items;
}

fn power(src: *const Src) hw.Power {
    var p: hw.Power = .{};
    var supplies: std.ArrayList(hw.PowerSupply) = .empty;
    for (src.list("/sys/class/power_supply")) |name| {
        const base = vh.fmt("/sys/class/power_supply/{s}", .{name});
        const scope = src.line(vh.fmt("{s}/scope", .{base}));
        // a peripheral's battery (a mouse, a headset) says nothing about the machine, and
        // Bluetooth ones are named by their address
        if (vh.eql(scope, "Device") or addressLike(name)) continue;
        supplies.append(vh.gpa, .{ .name = vh.dupe(name), .kind = src.line(vh.fmt("{s}/type", .{base})), .scope = scope }) catch vh.oom();
    }
    p.supplies = supplies.items;
    var lights: std.ArrayList(hw.Backlight) = .empty;
    for (src.list("/sys/class/backlight")) |name| {
        lights.append(vh.gpa, .{ .name = vh.dupe(name), .kind = src.line(vh.fmt("/sys/class/backlight/{s}/type", .{name})) }) catch vh.oom();
    }
    p.backlights = lights.items;
    var profiles: vh.Strv = .{};
    var it = mem.tokenizeAny(u8, src.line("/sys/firmware/acpi/platform_profile_choices"), " \t");
    while (it.next()) |x| profiles.add(x);
    p.profiles = profiles.slice();
    return p;
}

/// the PCI class of a modalias ("pci:...bc03sc00i00" -> "03"), "" when it is not PCI
pub fn pciClass(modalias: []const u8) []const u8 {
    if (!vh.startsWith(modalias, "pci:")) return "";
    const i = mem.indexOf(u8, modalias, "bc") orelse return "";
    if (i + 4 > modalias.len) return "";
    return modalias[i + 2 .. i + 4];
}

fn displays(src: *const Src, devices_: []const hw.Device) []const hw.Display {
    var out: std.ArrayList(hw.Display) = .empty;
    // PCI display controllers (class 03), with or without a driver
    for (devices_) |d| {
        if (!vh.eql(d.bus, "pci") or !vh.eql(pciClass(d.modalias), "03")) continue;
        out.append(vh.gpa, .{
            .name = d.name,
            .bus = "pci",
            .boot_vga = vh.eql(src.line(vh.fmt("/sys/bus/pci/devices/{s}/boot_vga", .{d.name})), "1"),
            .driver = d.driver,
            .module = d.module,
        }) catch vh.oom();
    }
    // DRM cards: their connectors, and the GPU of a board that is not on PCI
    const cards = src.list("/sys/class/drm");
    for (cards) |card| {
        if (!vh.startsWith(card, "card") or !allDigits(card[4..])) continue;
        const dev = vh.fmt("/sys/class/drm/{s}/device", .{card});
        if (src.link(dev) == null and !src.exists(dev)) continue;
        const real = src.real(dev);
        const name = basename(real);
        // the display this card belongs to: its own device, or a PCI display it sits on (a
        // virtio GPU is a virtio device under the PCI function)
        var idx: ?usize = null;
        var up = real;
        while (idx == null and vh.startsWith(up, "/sys/devices/")) : (up = dirname(up)) {
            for (out.items, 0..) |x, i| if (vh.eql(x.name, basename(up))) {
                idx = i;
            };
        }
        if (idx == null) {
            var x: hw.Display = .{ .name = vh.dupe(name), .bus = busOf(real) };
            if (linkOf(src, real)) |l| {
                x.driver = l.driver;
                x.module = l.module;
            }
            out.append(vh.gpa, x) catch vh.oom();
            idx = out.items.len - 1;
        }
        var conns: vh.Strv = .{};
        const prefix = vh.fmt("{s}-", .{card});
        for (cards) |c| {
            if (!vh.startsWith(c, prefix)) continue;
            const status = src.line(vh.fmt("/sys/class/drm/{s}/status", .{c}));
            conns.add(vh.fmt("{s} {s}", .{ c[prefix.len..], if (status.len > 0) status else "unknown" }));
        }
        if (conns.len() > 0) out.items[idx.?].connectors = conns.slice();
    }
    mem.sort(hw.Display, out.items, {}, struct {
        fn less(_: void, a: hw.Display, b: hw.Display) bool {
            return mem.order(u8, a.name, b.name) == .lt;
        }
    }.less);
    return out.items;
}

/// /proc/bus/input/devices with what a snapshot may keep: no Phys and no Uniq lines (they
/// carry Bluetooth addresses and serial numbers), and no Bluetooth or virtual device at all
pub fn cleanInput(raw: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var blocks_it = mem.splitSequence(u8, raw, "\n\n");
    while (blocks_it.next()) |blk| {
        if (vh.strip(blk).len == 0) continue;
        const bus = inputBus(blk);
        if (bus == 0x05 or bus == 0x06) continue;
        var lines = mem.tokenizeScalar(u8, blk, '\n');
        while (lines.next()) |l| {
            if (vh.startsWith(l, "P:") or vh.startsWith(l, "U:")) continue;
            out.appendSlice(vh.gpa, l) catch vh.oom();
            out.append(vh.gpa, '\n') catch vh.oom();
        }
        out.append(vh.gpa, '\n') catch vh.oom();
    }
    return out.items;
}

/// the input bus number of a /proc/bus/input/devices block ("I: Bus=0011 ...")
fn inputBus(blk: []const u8) u32 {
    const i = mem.indexOf(u8, blk, "Bus=") orelse return 0;
    const end = mem.indexOfAnyPos(u8, blk, i + 4, " \n") orelse blk.len;
    return std.fmt.parseInt(u32, blk[i + 4 .. end], 16) catch 0;
}

/// the value after "KEY=" or "EV=" in a block, as the bitmap's lowest 64 bits
fn inputBits(blk: []const u8, key: []const u8) u64 {
    var lines = mem.tokenizeScalar(u8, blk, '\n');
    while (lines.next()) |l| {
        const at = mem.indexOf(u8, l, key) orelse continue;
        if (!vh.startsWith(l, "B:")) continue;
        const words = vh.strip(l[at + key.len ..]);
        // the kernel prints the bitmap as longs, most significant first: the last word holds bits 0-63
        const last = if (mem.lastIndexOfScalar(u8, words, ' ')) |s| words[s + 1 ..] else words;
        return std.fmt.parseInt(u64, last, 16) catch 0;
    }
    return 0;
}

/// a keyboard: it reports keys, among them A, Z and Enter (a power button reports keys too)
pub fn isKeyboard(blk: []const u8) bool {
    const ev = inputBits(blk, "EV=");
    if ((ev & (1 << 1)) == 0) return false;
    const keys = inputBits(blk, "KEY=");
    const want: u64 = (1 << 28) | (1 << 30) | (1 << 44);
    return (keys & want) == want;
}

fn keyboards(src: *const Src) []const hw.Keyboard {
    const text = src.readClean("/proc/bus/input/devices", cleanInput) orelse return &.{};
    var out: std.ArrayList(hw.Keyboard) = .empty;
    var blocks_it = mem.splitSequence(u8, text, "\n\n");
    while (blocks_it.next()) |blk| {
        if (!isKeyboard(blk)) continue;
        var k: hw.Keyboard = .{};
        k.bus = switch (inputBus(blk)) {
            0x03 => "usb",
            0x11 => "i8042",
            0x18 => "i2c",
            0x19 => "host",
            0x1C => "spi",
            else => "other",
        };
        var lines = mem.tokenizeScalar(u8, blk, '\n');
        var sysfs: []const u8 = "";
        while (lines.next()) |l| {
            if (vh.startsWith(l, "N: Name=")) k.name = vh.dupe(mem.trim(u8, l["N: Name=".len..], "\""));
            if (vh.startsWith(l, "S: Sysfs=")) sysfs = l["S: Sysfs=".len..];
        }
        if (sysfs.len > 0) k.drivers = driverChain(src, src.real(vh.fmt("/sys{s}", .{sysfs})));
        out.append(vh.gpa, k) catch vh.oom();
    }
    return out.items;
}

fn sound(src: *const Src) []const hw.Sound {
    var out: std.ArrayList(hw.Sound) = .empty;
    for (src.list("/sys/class/sound")) |card| {
        if (!vh.startsWith(card, "card") or !allDigits(card[4..])) continue;
        const dev = vh.fmt("/sys/class/sound/{s}/device", .{card});
        if (src.link(dev) == null) continue;
        const real = src.real(dev);
        var s: hw.Sound = .{ .card = vh.dupe(card), .bus = busOf(real) };
        if (linkOf(src, real)) |l| {
            s.driver = l.driver;
            s.module = l.module;
        }
        out.append(vh.gpa, s) catch vh.oom();
    }
    return out.items;
}

// ---------------------------------------------------------------- tests

/// the repository root for the tests: $VH_REPO, or ".", ".." or "../.." (the tests run from
/// the repository root, from kernel/, or from a build directory); null when not found
pub fn repoRoot() ?[]const u8 {
    if (vh.getenv("VH_REPO")) |r| {
        if (vh.pathExists(vh.fmt("{s}/kernel/profiles", .{r}))) return r;
    }
    const roots = [_][]const u8{ ".", "..", "../.." };
    for (roots) |r| {
        if (vh.pathExists(vh.fmt("{s}/kernel/profiles", .{r}))) return r;
    }
    return null;
}

/// a repository file for the tests, or null
pub fn repoPath(rel: []const u8) ?[]const u8 {
    const root = repoRoot() orelse return null;
    const p = vh.fmt("{s}/{s}", .{ root, rel });
    return if (vh.pathExists(p)) p else null;
}

test "paths" {
    try std.testing.expectEqualStrings("r8169", basename("../../../bus/pci/drivers/r8169"));
    try std.testing.expectEqualStrings("/sys/bus/pci", dirname("/sys/bus/pci/devices"));
    try std.testing.expectEqualStrings("/sys/devices/pci0000:00/0000:00:1f.6", joinRel("/sys/bus/pci/devices/0000:00:1f.6", "../../../devices/pci0000:00/0000:00:1f.6"));
    try std.testing.expectEqualStrings("/abs", joinRel("/sys/bus/x", "/abs"));
    try std.testing.expectEqualStrings("/sys/bus/pci/drivers/r8169", joinRel("/sys/devices/pci0000:00/0000:00:1f.6/driver", "../../../bus/pci/drivers/r8169"));
    try std.testing.expectEqual(@as(u32, 32), sizeKb("32K"));
    try std.testing.expectEqual(@as(u32, 12288), sizeKb("12288K"));
    try std.testing.expectEqual(@as(u32, 1024), sizeKb("1M"));
    try std.testing.expectEqual(@as(u32, 0), sizeKb(""));
}

test "cpu lists" {
    try std.testing.expectEqual(@as(u32, 12), countList("0-11"));
    try std.testing.expectEqual(@as(u32, 6), countList("0,2-5,8"));
    try std.testing.expectEqual(@as(u32, 0), countList(""));
    try std.testing.expectEqual(@as(u32, 1), countList("7"));
    try std.testing.expect(inList("0-3,8-11", 9));
    try std.testing.expect(!inList("0-3,8-11", 5));
    try std.testing.expect(inList("4", 4));
    try std.testing.expect(!inList("", 0));
}

test "buses, classes and addresses" {
    try std.testing.expectEqualStrings("nvme", busOf("/sys/devices/pci0000:00/0000:00:1b.0/0000:02:00.0/nvme/nvme0/nvme0n1"));
    try std.testing.expectEqualStrings("ata", busOf("/sys/devices/pci0000:00/0000:00:17.0/ata1/host0/target0:0:0/0:0:0:0/block/sda"));
    try std.testing.expectEqualStrings("usb", busOf("/sys/devices/pci0000:00/0000:00:14.0/usb2/2-1/2-1:1.0/host6/target6:0:0/6:0:0:0/block/sdb"));
    try std.testing.expectEqualStrings("virtio", busOf("/sys/devices/pci0000:00/0000:00:04.0/virtio1/block/vda"));
    try std.testing.expectEqualStrings("mmc", busOf("/sys/devices/platform/soc/fe300000.mmcnr/mmc_host/mmc1/mmc1:0001/mmc1:0001:1/net/wlan0"));
    try std.testing.expectEqualStrings("pci", busOf("/sys/devices/pci0000:00/0000:00:1c.0/0000:03:00.0"));
    try std.testing.expectEqualStrings("platform", busOf("/sys/devices/platform/i8042/serio0"));
    try std.testing.expectEqualStrings("03", pciClass("pci:v00008086d00009BC4sv00001462sd000012D5bc03sc00i00"));
    try std.testing.expectEqualStrings("02", pciClass("pci:v000010ECd00008168sv0000ABC0sd000012D5bc02sc00i00"));
    try std.testing.expectEqualStrings("", pciClass("usb:v8087p0026d0002dcE0dsc01dp01icE0isc01ip01in00"));
    try std.testing.expect(addressLike("wlx001122334455"));
    try std.testing.expect(addressLike("hid-00:11:22:33:44:55-battery"));
    try std.testing.expect(!addressLike("wlp0s20f3"));
    try std.testing.expect(!addressLike("enp3s0"));
    try std.testing.expect(!addressLike("BAT0"));
    try std.testing.expect(virtualDisk("loop0") and virtualDisk("zram0") and virtualDisk("dm-0") and virtualDisk("mmcblk0boot1"));
    try std.testing.expect(!virtualDisk("nvme0n1") and !virtualDisk("sda") and !virtualDisk("mmcblk0") and !virtualDisk("vda"));
}

test "input devices: keyboards, and what a snapshot keeps" {
    const text =
        \\I: Bus=0011 Vendor=0001 Product=0001 Version=ab41
        \\N: Name="AT Translated Set 2 keyboard"
        \\P: Phys=isa0060/serio0/input0
        \\S: Sysfs=/devices/platform/i8042/serio0/input/input0
        \\U: Uniq=
        \\H: Handlers=sysrq kbd event0 leds
        \\B: PROP=0
        \\B: EV=120013
        \\B: KEY=402000000 3803078f800d001 feffffdfffefffff fffffffffffffffe
        \\B: MSC=10
        \\B: LED=7
        \\
        \\I: Bus=0019 Vendor=0000 Product=0001 Version=0000
        \\N: Name="Power Button"
        \\P: Phys=LNXPWRBN/button/input0
        \\S: Sysfs=/devices/LNXSYSTM:00/LNXPWRBN:00/input/input1
        \\U: Uniq=
        \\H: Handlers=kbd event1
        \\B: PROP=0
        \\B: EV=3
        \\B: KEY=10000000000000 0
        \\
        \\I: Bus=0005 Vendor=046d Product=b35b Version=0011
        \\N: Name="Somebody's keyboard"
        \\P: Phys=00:11:22:33:44:55
        \\S: Sysfs=/devices/virtual/misc/uhid/0005:046D:B35B.0003/input/input9
        \\U: Uniq=66:77:88:99:aa:bb
        \\H: Handlers=sysrq kbd event9
        \\B: PROP=0
        \\B: EV=12001f
        \\B: KEY=3f000303ff 0 0 483ffff17aff32d bfd4444600000000 1 130ff38b17d000 677bfad9415fed 9ed68000004400 10000002
        \\
    ;
    const clean = cleanInput(text);
    try std.testing.expect(mem.indexOf(u8, clean, "Phys=") == null);
    try std.testing.expect(mem.indexOf(u8, clean, "Uniq=") == null);
    try std.testing.expect(mem.indexOf(u8, clean, "Somebody") == null);
    try std.testing.expect(mem.indexOf(u8, clean, "AT Translated Set 2 keyboard") != null);
    var it = mem.splitSequence(u8, clean, "\n\n");
    const kbd = it.next().?;
    const button = it.next().?;
    try std.testing.expect(isKeyboard(kbd));
    try std.testing.expect(!isKeyboard(button));
    try std.testing.expectEqual(@as(u32, 0x11), inputBus(kbd));
}

test "cpuinfo and mounts keep nothing that names one machine" {
    const c = cleanCpuinfo("processor\t: 0\nFeatures\t: fp asimd aes\nCPU implementer\t: 0x41\n\nHardware\t: BCM2835\nRevision\t: d04170\nSerial\t\t: 1000000012345678\nModel\t\t: Raspberry Pi 5 Model B Rev 1.0\n");
    try std.testing.expect(mem.indexOf(u8, c, "Serial") == null);
    try std.testing.expect(mem.indexOf(u8, c, "12345678") == null);
    try std.testing.expect(mem.indexOf(u8, c, "Features\t: fp asimd aes") != null);
    const m = cleanMounts("/dev/mapper/luks-root / xfs rw,noatime 0 0\n/dev/sdb1 /run/media/someone/Photos vfat rw 0 0\n");
    try std.testing.expectEqualStrings("- - xfs - 0 0\n- - vfat - 0 0\n", m);
}

test "probe: the GF63 fixture" {
    const dir = repoPath("tests/kernel/fixtures/gf63") orelse return error.SkipZigTest;
    const src: Src = .{ .root = dir };
    const h = run(&src);
    try std.testing.expectEqualStrings("6.18.57_1", h.probe.kernel);
    try std.testing.expectEqualStrings("gf63", h.probe.source);
    try std.testing.expectEqualStrings("GF63 Thin 10SCXR", h.machine.product_name);
    try std.testing.expectEqualStrings("MS-16R5", h.machine.board_name);
    try std.testing.expectEqualStrings("GenuineIntel", h.cpu.vendor);
    try std.testing.expectEqual(@as(u32, 6), h.cpu.family);
    try std.testing.expectEqual(@as(u32, 165), h.cpu.model);
    try std.testing.expectEqual(@as(u32, 6), h.cpu.cores);
    try std.testing.expectEqual(@as(u32, 12), h.cpu.threads);
    try std.testing.expect(h.cpu.smt);
    try std.testing.expectEqual(@as(usize, 4), h.cpu.caches.len);
    try std.testing.expectEqual(@as(u32, 12288), h.cpu.caches[3].size_kb);
    try std.testing.expect(mem.indexOf(u8, h.cpu.flags, " aes ") != null);
    try std.testing.expect(h.firmware.efi);
    try std.testing.expectEqual(@as(u32, 64), h.firmware.efi_bits);
    try std.testing.expectEqual(@as(?bool, true), h.firmware.secure_boot);
    try std.testing.expect(h.firmware.tpm);
    try std.testing.expectEqual(@as(u32, 2), h.firmware.tpm_version);
    try std.testing.expectEqualStrings("tpm_crb", h.firmware.tpm_driver);
    try std.testing.expect(h.hasModule("iwlmvm"));
    try std.testing.expect(h.hasModule("dm_crypt"));
    var has_xfs = false;
    for (h.filesystems) |f| if (vh.eql(f, "xfs")) {
        has_xfs = true;
    };
    try std.testing.expect(has_xfs);
    var wifi: ?hw.Device = null;
    var gpu: ?hw.Device = null;
    var nvme: ?hw.Device = null;
    var dmi: ?hw.Device = null;
    for (h.devices) |d| {
        if (vh.eql(d.name, "0000:00:14.3")) wifi = d;
        if (vh.eql(d.name, "0000:01:00.0")) gpu = d;
        if (vh.eql(d.name, "0000:02:00.0")) nvme = d;
        if (vh.eql(d.bus, "dmi")) dmi = d;
    }
    try std.testing.expectEqualStrings("pci:v00008086d000006F0sv00008086sd00000034bc02sc80i00", wifi.?.modalias);
    try std.testing.expectEqualStrings("iwlwifi", wifi.?.driver);
    try std.testing.expectEqualStrings("iwlwifi", wifi.?.module);
    try std.testing.expectEqualStrings("", gpu.?.driver);
    try std.testing.expectEqualStrings("nvme", nvme.?.driver);
    try std.testing.expectEqualStrings("nvme", nvme.?.module);
    try std.testing.expect(vh.startsWith(dmi.?.modalias, "dmi:bvn"));
    // sorted by bus then name, and no serial numbers anywhere
    for (h.devices[1..], 0..) |d, i| try std.testing.expect(!lessDevice({}, d, h.devices[i]));
    const text = hw.render(h);
    try std.testing.expect(mem.indexOf(u8, text, "serial") == null);
    try std.testing.expect(mem.indexOf(u8, text, "product_uuid") == null);
    // the snapshot round trip: --save of a snapshot reproduces it
    const copy = vh.fmt("/tmp/vh-kconf-test-{d}", .{linux.getpid()});
    _ = vh.runOpts(&.{ "rm", "-rf", copy }, .{});
    const saving: Src = .{ .root = dir, .save = copy };
    _ = run(&saving);
    const again: Src = .{ .root = copy };
    const h2 = run(&again);
    try std.testing.expectEqual(h.devices.len, h2.devices.len);
    try std.testing.expectEqualStrings(hw.render(h), mem.replaceOwned(u8, vh.gpa, hw.render(h2), basename(copy), "gf63") catch vh.oom());
    _ = vh.runOpts(&.{ "rm", "-rf", copy }, .{});
}

/// a fixture of tests/kernel/fixtures through the probe, null when the repository is not found
fn fixture(name: []const u8) ?hw.Hw {
    const dir = repoPath(vh.fmt("tests/kernel/fixtures/{s}", .{name})) orelse return null;
    const src: Src = .{ .root = dir };
    return run(&src);
}

/// --save of a fixture, then --from of the copy: the same hw.zon (but the source name)
fn roundTrip(name: []const u8) !void {
    const dir = repoPath(vh.fmt("tests/kernel/fixtures/{s}", .{name})) orelse return error.SkipZigTest;
    const first: Src = .{ .root = dir };
    const h = run(&first);
    const copy = vh.fmt("/tmp/vh-kconf-test-{s}-{d}", .{ name, linux.getpid() });
    _ = vh.runOpts(&.{ "rm", "-rf", copy }, .{});
    const saving: Src = .{ .root = dir, .save = copy };
    _ = run(&saving);
    const again: Src = .{ .root = copy };
    const h2 = run(&again);
    try std.testing.expectEqualStrings(hw.render(h), mem.replaceOwned(u8, vh.gpa, hw.render(h2), basename(copy), name) catch vh.oom());
    _ = vh.runOpts(&.{ "rm", "-rf", copy }, .{});
}

fn hasTable(h: hw.Hw, sig: []const u8) bool {
    for (h.firmware.acpi_tables) |t| if (vh.eql(t, sig)) return true;
    return false;
}

test "probe: format 2 on the GF63" {
    const h = fixture("gf63") orelse return error.SkipZigTest;
    try std.testing.expectEqualStrings("x86_64", h.arch);
    try std.testing.expectEqual(@as(u32, 12), h.cpu.possible);
    try std.testing.expectEqual(@as(u64, 7_942_384), h.memory.total_kib);
    try std.testing.expectEqualStrings("intel_pstate", h.cpu.freq_driver);
    try std.testing.expect(h.cpu.epp);
    try std.testing.expectEqual(@as(usize, 12), h.cpu.topology.len);
    try std.testing.expectEqualStrings("0,6", h.cpu.topology[0].siblings);
    try std.testing.expectEqualStrings("0-11", h.cpu.topology[11].llc);
    try std.testing.expectEqual(@as(u32, 12288), h.cpu.topology[11].llc_kb);
    try std.testing.expectEqual(@as(u32, 4500000), h.cpu.topology[3].max_khz);
    try std.testing.expectEqual(@as(usize, 1), h.cpu.numa.len);
    try std.testing.expect(h.cpu.vulnerabilities.len > 10);
    try std.testing.expect(hasTable(h, "DMAR") and hasTable(h, "TPM2") and !hasTable(h, "IVRS"));
    try std.testing.expectEqual(@as(u32, 2), h.firmware.iommu_units);
    try std.testing.expectEqual(@as(?bool, false), h.firmware.setup_mode);
    try std.testing.expect(h.firmware.mor);
    // the NVMe namespace under multipath: the drivers come from the subsystem's controller
    try std.testing.expectEqual(@as(usize, 1), h.blocks.len);
    try std.testing.expectEqualStrings("nvme", h.blocks[0].bus);
    try std.testing.expect(h.blocks[0].discard and !h.blocks[0].rotational);
    try std.testing.expectEqualStrings("nvme", h.blocks[0].drivers[0].driver);
    try std.testing.expectEqual(@as(usize, 2), h.net.len);
    try std.testing.expect(!h.net[0].wireless and vh.eql(h.net[0].driver, "r8169"));
    try std.testing.expect(h.net[1].wireless and vh.eql(h.net[1].driver, "iwlwifi"));
    try std.testing.expectEqual(@as(usize, 2), h.power.supplies.len);
    try std.testing.expectEqualStrings("raw", h.power.backlights[0].kind);
    // the iGPU that brought the console up and its panel (00:02.0 sorts first), the dGPU without a driver
    try std.testing.expectEqual(@as(usize, 2), h.displays.len);
    try std.testing.expect(h.displays[0].boot_vga and vh.eql(h.displays[0].driver, "i915"));
    try std.testing.expectEqualStrings("eDP-1 connected", h.displays[0].connectors[0]);
    try std.testing.expect(!h.displays[1].boot_vga and h.displays[1].driver.len == 0);
    // the keyboard backlight controller on USB is not a keyboard
    try std.testing.expectEqual(@as(usize, 1), h.keyboards.len);
    try std.testing.expectEqualStrings("i8042", h.keyboards[0].bus);
    try std.testing.expectEqualStrings("atkbd", h.keyboards[0].drivers[0].driver);
    try std.testing.expectEqualStrings("i8042", h.keyboards[0].drivers[1].driver);
    try std.testing.expectEqualStrings("snd_hda_intel", h.sound[0].driver);
    try roundTrip("gf63");
}

test "probe: an AMD desktop with two CCDs and two GPUs" {
    const h = fixture("amd-desktop") orelse return error.SkipZigTest;
    try std.testing.expectEqual(@as(u32, 16), h.cpu.cores);
    try std.testing.expectEqual(@as(u32, 32), h.cpu.threads);
    try std.testing.expectEqualStrings("amd-pstate-epp", h.cpu.freq_driver);
    // the V-Cache CCD and the other one: two last-level caches of different sizes
    try std.testing.expectEqual(@as(u32, 98304), h.cpu.topology[0].llc_kb);
    try std.testing.expectEqual(@as(u32, 32768), h.cpu.topology[8].llc_kb);
    try std.testing.expectEqualStrings("8-15,24-31", h.cpu.topology[24].llc);
    try std.testing.expect(hasTable(h, "IVRS") and !hasTable(h, "DMAR"));
    try std.testing.expectEqual(@as(usize, 2), h.blocks.len);
    try std.testing.expect(vh.eql(h.blocks[1].bus, "ata") and h.blocks[1].rotational and h.blocks[1].physical_block == 4096);
    // the SCSI disk driver, then the SATA controller
    try std.testing.expectEqualStrings("sd", h.blocks[1].drivers[0].driver);
    try std.testing.expectEqualStrings("ahci", h.blocks[1].drivers[1].driver);
    try std.testing.expectEqual(@as(usize, 2), h.displays.len);
    try std.testing.expect(h.displays[0].boot_vga and h.displays[0].connectors.len == 3);
    try std.testing.expect(!h.displays[1].boot_vga);
    try std.testing.expectEqualStrings("usb", h.keyboards[0].bus);
    try std.testing.expectEqualStrings("xhci_pci", h.keyboards[0].drivers[4].module);
    try std.testing.expectEqual(@as(usize, 0), h.power.supplies.len);
    try std.testing.expectEqual(@as(usize, 3), h.sound.len);
}

test "probe: a hybrid Intel laptop with its disk behind VMD" {
    const h = fixture("intel-hybrid-laptop") orelse return error.SkipZigTest;
    var p_cores: usize = 0;
    var e_cores: usize = 0;
    for (h.cpu.topology) |t| {
        if (vh.eql(t.kind, "core")) p_cores += 1;
        if (vh.eql(t.kind, "atom")) e_cores += 1;
    }
    try std.testing.expectEqual(@as(usize, 8), p_cores);
    try std.testing.expectEqual(@as(usize, 8), e_cores);
    try std.testing.expectEqual(@as(u32, 12), h.cpu.cores);
    try std.testing.expectEqual(@as(u32, 3400000), h.cpu.topology[9].max_khz);
    // VMD: the controller the NVMe disk hangs off
    const chain = h.blocks[0].drivers;
    try std.testing.expectEqualStrings("vmd", chain[chain.len - 1].driver);
    try std.testing.expectEqualStrings("sof-audio-pci-intel-tgl", h.sound[0].driver);
    try std.testing.expectEqual(@as(usize, 4), h.power.supplies.len);
    try std.testing.expectEqual(@as(usize, 3), h.power.profiles.len);
    try std.testing.expectEqual(@as(usize, 1), h.net.len);
    try roundTrip("intel-hybrid-laptop");
}

test "probe: the rig's virtual machine at installation time" {
    const h = fixture("qemu-q35") orelse return error.SkipZigTest;
    try std.testing.expect(mem.indexOf(u8, h.cpu.flags, " hypervisor ") != null);
    try std.testing.expectEqual(@as(?bool, false), h.firmware.secure_boot);
    try std.testing.expectEqual(@as(?bool, true), h.firmware.setup_mode);
    try std.testing.expect(hasTable(h, "DMAR"));
    // virtio-gpu: the DRM card sits on the virtio device under the PCI function
    try std.testing.expectEqual(@as(usize, 1), h.displays.len);
    try std.testing.expectEqualStrings("Virtual-1 connected", h.displays[0].connectors[0]);
    try std.testing.expectEqualStrings("e1000", h.net[0].driver);
    try std.testing.expectEqual(@as(usize, 0), h.sound.len);
}

test "probe: a real ARM64 virtual machine" {
    const h = fixture("aarch64-virt") orelse return error.SkipZigTest;
    try std.testing.expectEqualStrings("aarch64", h.arch);
    try std.testing.expect(h.cpu.implementer.len > 0);
    try std.testing.expect(mem.indexOf(u8, h.cpu.flags, "aes") != null);
    try std.testing.expect(h.firmware.efi and h.firmware.secure_boot == null and !h.firmware.tpm);
    try std.testing.expect(h.blocks.len > 0 and vh.eql(h.blocks[0].bus, "virtio"));
    try std.testing.expectEqualStrings("virtio", h.net[0].bus);
    try std.testing.expect(h.keyboards.len > 0);
}

test "probe: a Raspberry Pi 5" {
    const h = fixture("rpi5") orelse return error.SkipZigTest;
    try std.testing.expectEqualStrings("aarch64", h.arch);
    try std.testing.expectEqualStrings("0xd0b", h.cpu.part);
    try std.testing.expect(!h.firmware.efi and !h.firmware.tpm and h.firmware.acpi_tables.len == 0);
    try std.testing.expectEqualStrings("brcm,bcm2712", h.firmware.dt_compatible[1]);
    try std.testing.expectEqualStrings("mmc", h.blocks[0].bus);
    try std.testing.expectEqualStrings("mmc", h.net[1].bus);
    try std.testing.expectEqual(@as(usize, 2), h.displays.len);
    try std.testing.expectEqual(@as(u32, 1024), h.cpu.topology[0].capacity);
    // the snapshot holds no Serial line: the board's serial number is never copied
    const dir = repoPath("tests/kernel/fixtures/rpi5") orelse return error.SkipZigTest;
    const info = vh.readFile(vh.fmt("{s}/proc/cpuinfo", .{dir})) catch return error.SkipZigTest;
    try std.testing.expect(mem.indexOf(u8, info, "Serial") == null);
    try roundTrip("rpi5");
}
