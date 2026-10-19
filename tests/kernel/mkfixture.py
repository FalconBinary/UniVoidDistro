#!/usr/bin/env python3
"""Writes the synthesised machines of tests/kernel/fixtures: sysfs/procfs snapshots with the
shape `vh-kconf probe --save` produces. One module in tests/kernel/machines/ per machine holds
its data; this file only writes them.

    python3 tests/kernel/mkfixture.py              # every synthesised machine
    python3 tests/kernel/mkfixture.py gf63 rpi5    # the named ones

A synthesised machine is marked [VERIFY] in its module: its IDs are public ones of that
hardware and its drivers those of the stock Void kernel, but nothing was read from the real
machine. `vh-kconf probe --save DIR` on the machine gives the real snapshot, which replaces the
generated one (and its module here). aarch64-virt is real from the start and is not generated.

A snapshot holds what the probe keeps: cpuinfo without a Serial line, mounts with the file
system types only, input devices without Phys and Uniq lines and without Bluetooth or virtual
devices, ACPI tables by name (empty files), efivars only SecureBoot, SetupMode and MOR.
"""
import importlib
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(HERE, "fixtures")
sys.path.insert(0, HERE)

MACHINES = ["gf63", "amd_desktop", "intel_hybrid_laptop", "qemu_q35", "rpi5"]
EFI_GLOBAL = "8be4df61-93ca-11d2-aa0d-00e098032b8c"
MOR_GUID = "e20939be-32d4-41be-a150-897f85d49829"


class Writer:
    def __init__(self, root):
        self.root = root
        self.entries = 0

    def path(self, rel):
        return os.path.join(self.root, rel)

    def write(self, rel, content):
        p = self.path(rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb" if isinstance(content, bytes) else "w") as f:
            f.write(content)

    def mkdir(self, rel):
        os.makedirs(self.path(rel), exist_ok=True)

    def link(self, rel, target_rel):
        """a symlink at rel pointing to target_rel (both relative to the snapshot root),
        written relative, as sysfs does"""
        p = self.path(rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        if os.path.lexists(p):
            return
        os.symlink(os.path.relpath(self.path(target_rel), os.path.dirname(p)), p)


def pci(vid, did, svid, sdid, cls):
    """the modalias of a PCI function: class as 0xCCSSPP"""
    return (f"pci:v0000{vid:04X}d0000{did:04X}sv0000{svid:04X}sd0000{sdid:04X}"
            f"bc{cls >> 16:02X}sc{(cls >> 8) & 0xFF:02X}i{cls & 0xFF:02X}")


def usb(vid, pid, bcd, dc, dsc, dp, ic, isc, ip, inum):
    return (f"usb:v{vid:04X}p{pid:04X}d{bcd:04X}dc{dc:02X}dsc{dsc:02X}dp{dp:02X}"
            f"ic{ic:02X}isc{isc:02X}ip{ip:02X}in{inum:02X}")


def cpuinfo_x86(cpu, n):
    blocks = []
    for i in range(n):
        blocks.append(
            f"processor\t: {i}\nvendor_id\t: {cpu['vendor_id']}\ncpu family\t: {cpu['family']}\n"
            f"model\t\t: {cpu['model']}\nmodel name\t: {cpu['model_name']}\nstepping\t: {cpu['stepping']}\n"
            f"microcode\t: {cpu['microcode']}\ncpu MHz\t\t: {cpu.get('mhz', '2500.000')}\n"
            f"cache size\t: {cpu['cache_kb']} KB\nphysical id\t: 0\nsiblings\t: {n}\n"
            f"core id\t\t: {cpu['core_ids'][i]}\ncpu cores\t: {cpu['cores']}\napicid\t\t: {i}\n"
            f"fpu\t\t: yes\ncpuid level\t: {cpu.get('cpuid_level', 22)}\nwp\t\t: yes\n"
            f"flags\t\t: {cpu['flags']}\nbugs\t\t: {cpu.get('bugs', '')}\n"
            f"bogomips\t: {cpu.get('bogomips', '4999.90')}\nclflush size\t: 64\ncache_alignment\t: 64\n"
            f"address sizes\t: {cpu.get('address_sizes', '39 bits physical, 48 bits virtual')}\n\n")
    return "".join(blocks)


def cpuinfo_arm(cpu, n):
    blocks = []
    for i in range(n):
        blocks.append(
            f"processor\t: {i}\nBogoMIPS\t: {cpu['bogomips']}\nFeatures\t: {cpu['features']}\n"
            f"CPU implementer\t: {cpu['implementer']}\nCPU architecture: 8\nCPU variant\t: {cpu['variant']}\n"
            f"CPU part\t: {cpu['part']}\nCPU revision\t: {cpu['revision']}\n\n")
    # the board lines a Raspberry Pi kernel appends; the snapshot drops Serial
    for k, v in cpu.get("board", []):
        blocks.append(f"{k}\t\t: {v}\n")
    return "".join(blocks)


def build(m):
    root = os.path.join(FIXTURES, m.NAME)
    if os.path.isdir(root):
        shutil.rmtree(root)
    os.makedirs(root)
    w = Writer(root)
    arch = getattr(m, "ARCH", "x86_64")

    # proc
    w.write("proc/sys/kernel/osrelease", m.OSRELEASE + "\n")
    w.write("proc/sys/kernel/arch", arch + "\n")
    w.write("proc/modules", "".join(f"{x} 16384 0 - Live 0xffffffffc0000000\n" for x in m.MODULES))
    w.write("proc/mounts", "".join(f"- - {fs} - 0 0\n" for fs in m.FILESYSTEMS))
    w.write("proc/meminfo", f"MemTotal:       {m.MEMTOTAL_KB} kB\nMemFree:        {m.MEMTOTAL_KB // 2} kB\n")
    n = len(m.TOPOLOGY)
    w.write("proc/cpuinfo", cpuinfo_arm(m.CPU, n) if arch == "aarch64" else cpuinfo_x86(m.CPU, n))
    w.write("proc/bus/input/devices", m.INPUT)

    # devices: the real directories, the bus links, the driver and module links
    for bus, name, real, modalias, driver, module in m.DEVICES:
        devdir = "sys/devices/" + real
        w.write(devdir + "/modalias", modalias + "\n")
        w.link(f"sys/bus/{bus}/devices/{name}", devdir)
        if driver:
            drvdir = f"sys/bus/{bus}/drivers/{driver}"
            w.mkdir(drvdir)
            w.link(devdir + "/driver", drvdir)
            if module:
                w.mkdir("sys/module/" + module)
                w.link(drvdir + "/module", "sys/module/" + module)

    # the CPUs
    cpu = "sys/devices/system/cpu"
    w.write(cpu + "/possible", m.POSSIBLE + "\n")
    w.write(cpu + "/present", m.POSSIBLE + "\n")
    if getattr(m, "SMT", None) is not None:
        w.write(cpu + "/smt/active", m.SMT + "\n")
        w.write(cpu + "/smt/control", "on\n" if m.SMT == "1" else "notsupported\n")
    freq = getattr(m, "FREQ", None)
    for t in m.TOPOLOGY:
        c = t["cpu"]
        d = f"{cpu}/cpu{c}"
        w.write(d + "/modalias", m.CPU_MODALIAS + "\n")
        w.link(f"sys/bus/cpu/devices/cpu{c}", d)
        w.mkdir("sys/bus/cpu/drivers/processor")
        w.link(d + "/driver", "sys/bus/cpu/drivers/processor")
        for k in ("package", "die", "cluster", "core"):
            key = {"package": "physical_package_id", "die": "die_id", "cluster": "cluster_id", "core": "core_id"}[k]
            if k in t:
                w.write(f"{d}/topology/{key}", f"{t[k]}\n")
        w.write(d + "/topology/core_cpus_list", t["siblings"] + "\n")
        w.write(d + "/topology/thread_siblings_list", t["siblings"] + "\n")
        for idx, (level, kind, size, shared) in enumerate(t["caches"]):
            cd = f"{d}/cache/index{idx}/"
            w.write(cd + "level", f"{level}\n")
            w.write(cd + "type", f"{kind}\n")
            w.write(cd + "size", f"{size}\n")
            w.write(cd + "shared_cpu_list", shared + "\n")
        if "capacity" in t:
            w.write(d + "/cpu_capacity", f"{t['capacity']}\n")
        if freq:
            pol = f"{cpu}/cpufreq/policy{c}"
            w.write(pol + "/cpuinfo_max_freq", f"{t['max_khz']}\n")
            w.write(pol + "/scaling_driver", freq[0] + "\n")
            if freq[1]:
                w.write(pol + "/energy_performance_available_preferences",
                        "default performance balance_performance balance_power power\n")
            w.link(d + "/cpufreq", pol)
    hybrid = getattr(m, "HYBRID", None)
    if hybrid:
        w.write("sys/devices/cpu_core/cpus", hybrid[0] + "\n")
        w.write("sys/devices/cpu_atom/cpus", hybrid[1] + "\n")
    for i, cl in enumerate(getattr(m, "NUMA", [])):
        w.write(f"sys/devices/system/node/node{i}/cpulist", cl + "\n")
    for k, v in getattr(m, "VULNS", {}).items():
        w.write(f"{cpu}/vulnerabilities/{k}", v + "\n")

    # DMI (never the serial numbers or the UUID)
    dmi = getattr(m, "DMI", None)
    if dmi:
        for k, v in dmi.items():
            w.write("sys/devices/virtual/dmi/id/" + k, v + "\n")
        w.link("sys/class/dmi/id", "sys/devices/virtual/dmi/id")

    # EFI: the platform size and the three global variables the probe reads
    efi = getattr(m, "EFI", None)
    if efi:
        w.write("sys/firmware/efi/fw_platform_size", f"{efi['bits']}\n")
        ev = "sys/firmware/efi/efivars/"
        if efi.get("secure_boot") is not None:
            w.write(ev + f"SecureBoot-{EFI_GLOBAL}", b"\x06\x00\x00\x00" + bytes([efi["secure_boot"]]))
        if efi.get("setup_mode") is not None:
            w.write(ev + f"SetupMode-{EFI_GLOBAL}", b"\x06\x00\x00\x00" + bytes([efi["setup_mode"]]))
        if efi.get("mor"):
            w.write(ev + f"MemoryOverwriteRequestControl-{MOR_GUID}", "")

    # the TPM: a class device under the device its driver binds
    tpm = getattr(m, "TPM", None)
    if tpm:
        t = "sys/devices/" + tpm["device"] + "/tpm/tpm0"
        w.write(t + "/tpm_version_major", f"{tpm['version']}\n")
        w.link(t + "/device", "sys/devices/" + tpm["device"])
        w.link("sys/class/tpm/tpm0", t)

    # ACPI tables by name, the IOMMU units, the device tree, the hypervisor
    for sig in getattr(m, "ACPI_TABLES", []):
        w.write("sys/firmware/acpi/tables/" + sig, "")
    for name, path in getattr(m, "IOMMU", []):
        w.mkdir("sys/devices/" + path)
        w.link("sys/class/iommu/" + name, "sys/devices/" + path)
    dt = getattr(m, "DT", None)
    if dt:
        w.write("sys/firmware/devicetree/base/model", (dt["model"] + "\0").encode())
        w.write("sys/firmware/devicetree/base/compatible", "".join(c + "\0" for c in dt["compatible"]).encode())
    if getattr(m, "HYPERVISOR_TYPE", None):
        w.write("sys/hypervisor/type", m.HYPERVISOR_TYPE + "\n")
    if getattr(m, "PROFILES", None):
        w.write("sys/firmware/acpi/platform_profile_choices", m.PROFILES + "\n")

    # disks
    for b in getattr(m, "BLOCKS", []):
        bd = "sys/devices/" + b["path"]
        w.link("sys/block/" + b["name"], bd)
        q = bd + "/queue/"
        w.write(q + "rotational", "1\n" if b.get("rotational") else "0\n")
        w.write(q + "logical_block_size", f"{b.get('lbs', 512)}\n")
        w.write(q + "physical_block_size", f"{b.get('pbs', 512)}\n")
        w.write(q + "discard_max_bytes", f"{b.get('discard_max', 0)}\n")
        w.write(bd + "/removable", "1\n" if b.get("removable") else "0\n")
        w.write(bd + "/size", f"{b['sectors']}\n")
        dev = "sys/devices/" + b["device"]
        w.link(bd + "/device", dev)
        w.write(dev + ("/name" if b.get("model_file") == "name" else "/model"), b["model"] + "\n")
        for lname, cpath in b.get("controllers", []):
            w.link(dev + "/" + lname, "sys/devices/" + cpath)

    # network interfaces backed by a device
    for nt in getattr(m, "NETS", []):
        dev = "sys/devices/" + nt["device"]
        nd = dev + "/net/" + nt["name"]
        w.mkdir(nd)
        w.link("sys/class/net/" + nt["name"], nd)
        w.link(nd + "/device", dev)
        if nt.get("wireless"):
            w.mkdir(dev + "/ieee80211/phy0")
            w.link(nd + "/phy80211", dev + "/ieee80211/phy0")

    # power supplies, backlights
    for name, kind, scope, parent in getattr(m, "SUPPLIES", []):
        d = f"sys/devices/{parent}/power_supply/{name}"
        w.write(d + "/type", kind + "\n")
        if scope:
            w.write(d + "/scope", scope + "\n")
        w.link("sys/class/power_supply/" + name, d)
    for name, kind, parent in getattr(m, "BACKLIGHTS", []):
        d = f"sys/devices/{parent}/backlight/{name}"
        w.write(d + "/type", kind + "\n")
        w.link("sys/class/backlight/" + name, d)

    # displays: boot_vga, the DRM cards and their connectors
    for path, v in getattr(m, "BOOT_VGA", {}).items():
        w.write(f"sys/devices/{path}/boot_vga", f"{v}\n")
    for card in getattr(m, "DRM", []):
        dev = "sys/devices/" + card["device"]
        cd = f"{dev}/drm/{card['card']}"
        w.mkdir(cd)
        w.link("sys/class/drm/" + card["card"], cd)
        w.link(cd + "/device", dev)
        for conn, status in card.get("connectors", []):
            cc = f"{cd}/{card['card']}-{conn}"
            w.write(cc + "/status", status + "\n")
            w.link(f"sys/class/drm/{card['card']}-{conn}", cc)

    # attributes no table above covers (a USB device's removable), as plain files
    for rel, content in getattr(m, "FILES", {}).items():
        w.write(rel, content + "\n")

    # sound cards
    for card, path in getattr(m, "SOUND", []):
        dev = "sys/devices/" + path
        sd = f"{dev}/sound/{card}"
        w.mkdir(sd)
        w.link("sys/class/sound/" + card, sd)
        w.link(sd + "/device", dev)

    entries = sum(len(f) + len(d) for _, d, f in os.walk(root))
    print(f"{root}: {len(m.DEVICES) + n} devices, {entries} entries")


def main(argv):
    names = argv or MACHINES
    for name in names:
        build(importlib.import_module("machines." + name.replace("-", "_")))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
