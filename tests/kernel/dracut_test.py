#!/usr/bin/env python3
"""vh-kconf install against Void's real dracut, inside a throwaway Void container
(tests/kernel/dracut_test.sh starts it; dracut, dracut-uefi, systemd-boot-efistub, binutils and
cryptsetup are installed there from Void's mirror).

    python3 -I tests/kernel/dracut_test.py SRC     -- SRC: the repository files and build/kd

A system under /sys-root: this machine's probe and plan (the GF63's), a stock UKI whose
.cmdline is the stock command line, the stock kernel's modules.dep, modprobe.d, the firmware the
trim left; and the run's files of a synthesised machine kernel (a bzImage header that reports
6.18.57-vh). /sys-root/usr/bin/dracut is the container's dracut, which reads the container's
/etc/dracut.conf.d/10-vh.conf (rendered from rootfs/). vh-kconf install builds the UKI with it
and checks it itself (.linux is the bzImage, .cmdline the command line it computed); here
lsinitrd lists the initrd: the firmware at /usr/lib/firmware, the initrd's /lib a link to usr/lib
(the kernel's loader reads /lib/firmware), no kernel module, no microcode directory.
"""
import hashlib
import os
import struct
import subprocess
import sys

SRC = sys.argv[1]
ROOT = "/sys-root"
RUN = "/run-files"
KCONF = os.path.join(SRC, "build/kd/bin/vh-kconf")
failures = 0


def ok(name, cond, detail=""):
    global failures
    print(f"{'ok' if cond else 'FAIL'} {name}{'' if cond else ': ' + detail}", flush=True)
    if not cond:
        failures += 1


def put(path, data, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data.encode() if isinstance(data, str) else data)
    os.chmod(path, mode)


def pe(sections):
    """a PE image with these (name, bytes) sections, each at a 512-byte boundary"""
    hdr = bytearray(0x40 + 24 + 40 * len(sections))
    hdr[0:2] = b"MZ"
    struct.pack_into("<I", hdr, 0x3C, 0x40)
    hdr[0x40:0x44] = b"PE\0\0"
    struct.pack_into("<H", hdr, 0x46, len(sections))
    body = bytearray(hdr)
    for i, (name, data) in enumerate(sections):
        body += b"\0" * (-len(body) % 512)
        at = len(body)
        body += data + b"\0" * (-len(data) % 512)
        struct.pack_into("<8sIIII", body, 0x58 + i * 40, name.encode(), len(data), 0, len(body) - at, at)
    return bytes(body)


def bzimage(release):
    """the setup header of a bzImage as far as vh-kconf reads it: "HdrS", protocol 2.15, the
    kernel_version string at 0x400"""
    b = bytearray(0x400)
    b[0:2] = b"MZ"
    b[0x202:0x206] = b"HdrS"
    struct.pack_into("<H", b, 0x206, 0x020F)
    struct.pack_into("<H", b, 0x20E, 0x0200)
    return bytes(b) + f"{release} (vh@ci) #1 SMP PREEMPT_DYNAMIC\0".encode() + b"\x55" * 4096


STOCK = ("rd.luks.uuid=L root=UUID=R rootfstype=xfs rootflags=noatime,logbsize=256k ro rd.lvm=0 rd.md=0 rd.dm=0 "
         "rd.shell=0 rd.emergency=poweroff quiet loglevel=3 net.ifnames=0 panic=10 lockdown=confidentiality "
         "module.sig_enforce=1 lsm=landlock,lockdown,yama,apparmor iommu.strict=1 iommu.passthrough=0 init_on_alloc=1 "
         "init_on_free=1 slab_nomerge page_alloc.shuffle=1 debugfs=off bdev_allow_write_mounted=0 efi_pstore.pstore_disable=1 "
         "proc_mem.force_override=never cfg80211.ieee80211_regdom=SI preempt=full module_blacklist=sctp,nouveau,mei_me "
         "efi=disable_early_pci_dma ia32_emulation=0 intel_iommu=on")
FIRMWARE = ["i915/kbl_dmc_ver1_04.bin.zst", "i915/cml_huc_4.0.0.bin.zst", "iwlwifi-QuZ-a0-hr-b0-77.ucode.zst",
            "intel/ibt-19-0-4.sfi.zst", "rtl_nic/rtl8168h-2.fw.zst", "regulatory.db", "regulatory.db.p7s"]
LEFT_OUT = ["intel-ucode/06-a5-02", "nvidia/tu117/gsp-570.144.bin.zst", "brcm/brcmfmac43455-sdio.Raspberry Pi Foundation-Raspberry Pi 4 Model B.txt"]


def main():
    # dracut's configuration, as the installer renders it (VH_INITRD_COMPRESS=zstd, the GF63's keyboard)
    conf = open(os.path.join(SRC, "rootfs/etc/dracut.conf.d/10-vh.conf.in")).read()
    conf = conf.replace("@VH_INITRD_COMPRESS@", "zstd").replace("@VH_DRACUT_DRIVERS@", "xhci_pci usbhid hid_generic atkbd i8042")
    put("/etc/dracut.conf.d/10-vh.conf", conf)
    put(f"{ROOT}/etc/dracut.conf.d/10-vh.conf", conf)
    hw = open(os.path.join(SRC, "kernel/hw/gf63.zon"), "rb").read()
    plan = open(os.path.join(SRC, "tests/adapt/golden/gf63/strict/plan.zon"), "rb").read()
    put(f"{ROOT}/etc/vh/hw.zon", hw)
    put(f"{ROOT}/etc/vh/plan.zon", plan)
    put(f"{ROOT}/etc/vh/vh.env", 'VH_KERNEL="linux6.18"\n')
    for f in os.listdir(os.path.join(SRC, "rootfs/etc/modprobe.d")):
        put(f"{ROOT}/etc/modprobe.d/{f}", open(os.path.join(SRC, "rootfs/etc/modprobe.d", f), "rb").read())
    put(f"{ROOT}/etc/modprobe.d/vh-watchdog.conf", "options iTCO_wdt nowayout=1\n")
    put(f"{ROOT}/etc/modprobe.d/vh-blacklist.conf", "install sctp /bin/false\ninstall nouveau /bin/false\n")
    put(f"{ROOT}/usr/lib/modules/6.18.57_1/modules.dep",
        "kernel/drivers/net/wireless/intel/iwlwifi/iwlwifi.ko.zst: kernel/net/wireless/cfg80211.ko.zst\n"
        "kernel/drivers/net/wireless/intel/iwlwifi/mvm/iwlmvm.ko.zst: kernel/drivers/net/wireless/intel/iwlwifi/iwlwifi.ko.zst\n"
        "kernel/net/wireless/cfg80211.ko.zst:\nkernel/drivers/watchdog/iTCO_wdt.ko.zst:\nkernel/drivers/gpu/drm/i915/i915.ko.zst:\n")
    put(f"{ROOT}/usr/lib/modules/6.18.57_1/modules.builtin", "kernel/drivers/firmware/efi/efi-pstore.ko\nkernel/net/ipv6/ipv6.ko\n")
    for f in FIRMWARE + LEFT_OUT:
        put(f"{ROOT}/usr/lib/firmware/{f}", hashlib.sha256(f.encode()).digest() * 64)
    put(f"{ROOT}/boot/efi/EFI/void/linux-6.18.57_1.efi", pe([(".cmdline", f" {STOCK} \0".encode()), (".linux", b"stock kernel")]))
    os.makedirs(f"{ROOT}/usr/bin", exist_ok=True)
    os.symlink("/usr/bin/dracut", f"{ROOT}/usr/bin/dracut")
    put(f"{ROOT}/usr/local/sbin/vh-limine-update", "#!/bin/sh\necho \"$@\" > /tmp/limine.args\n", 0o755)

    # the run's files: a machine kernel of the GF63 with Wi-Fi, i915 and the watchdog built in
    files = {
        "BUILD": f"kernel-custom gf63: linux-6.18.57, features usb-common,bluetooth, commit 0123abc, run 1\n"
                 f"hw.zon: kernel/hw/gf63.zon sha256 {hashlib.sha256(hw).hexdigest()}\n",
        "bzImage-vh-6.18.57": bzimage("6.18.57-vh"),
        "config-vh-6.18.57": "CONFIG_LOCALVERSION=\"-vh\"\n# CONFIG_MODULES is not set\nCONFIG_EFI_STUB=y\nCONFIG_BLK_DEV_INITRD=y\n"
                             "CONFIG_RD_ZSTD=y\nCONFIG_FW_LOADER=y\nCONFIG_FW_LOADER_COMPRESS=y\nCONFIG_FW_LOADER_COMPRESS_ZSTD=y\n"
                             "CONFIG_MICROCODE=y\nCONFIG_CFG80211=y\n# CONFIG_EFI_VARS_PSTORE is not set\n",
        "modules.builtin-vh-6.18.57": "kernel/net/wireless/cfg80211.ko\nkernel/drivers/net/wireless/intel/iwlwifi/iwlwifi.ko\n"
                                      "kernel/drivers/net/wireless/intel/iwlwifi/mvm/iwlmvm.ko\nkernel/drivers/watchdog/iTCO_wdt.ko\n"
                                      "kernel/drivers/gpu/drm/i915/i915.ko\nkernel/net/ipv6/ipv6.ko\n",
        "modules.builtin.modinfo-vh-6.18.57": b"iwlwifi.parmtype=power_save:bool\0iTCO_wdt.parmtype=nowayout:bool\0",
        "lsmod": "i915\niwlmvm\niwlwifi\nr8169\n",
        "resolve-report.txt": "vh-kconf resolve report\n\nDrivers already built into the stock kernel (2): nvme i8042\n",
        "plan.zon": plan,
        "gf63.zon": hw,
    }
    sums = ""
    for name, data in files.items():
        put(f"{RUN}/{name}", data)
        sums += f"{hashlib.sha256(data if isinstance(data, bytes) else data.encode()).hexdigest()}  {name}\n"
    put(f"{RUN}/SHA256SUMS", sums)

    ver = subprocess.run(["dracut", "--version"], capture_output=True, text=True).stdout.strip()
    print(f"== {ver}; vh-kconf install --root {ROOT} {RUN}", flush=True)
    r = subprocess.run([KCONF, "install", "--root", ROOT, "--repo", SRC, RUN], capture_output=True, text=True)
    out = r.stdout + r.stderr
    tail = " | ".join(out.strip().splitlines()[-12:])
    ok("vh-kconf install builds the UKI with dracut --no-kernel --kver --kernel-image --uefi, and its own check passes",
       r.returncode == 0 and ".linux is the verified bzImage" in out, tail)
    uki = f"{ROOT}/boot/efi/EFI/void/linux-6.18.57-vh_1.efi"
    ok("the UKI is on the ESP as linux-6.18.57-vh_1.efi", os.path.isfile(uki), tail)
    ok("vh-limine-update --new 6.18.57-vh_1", os.path.isfile("/tmp/limine.args") and open("/tmp/limine.args").read().strip() == "--new 6.18.57-vh_1")
    if not os.path.isfile(uki):
        print(out)
        return
    cmd = open(f"{ROOT}/var/lib/vh/kernels/6.18.57-vh_1/cmdline").read().strip()
    for gone in ("module.sig_enforce=1", "module_blacklist=", "efi_pstore.pstore_disable=1"):
        ok(f"the command line has no {gone}", gone not in cmd, cmd)
    for kept in ("lockdown=confidentiality", "cfg80211.ieee80211_regdom=SI", "page_alloc.shuffle=1", "rd.luks.uuid=L", "intel_iommu=on"):
        ok(f"the command line keeps {kept}", kept in cmd, cmd)
    for added in ("iwlwifi.power_save=0", "iwlwifi.uapsd_disable=3", "iwlmvm.power_scheme=1", "iTCO_wdt.nowayout=1"):
        ok(f"the command line carries the modprobe.d option {added}", f" {added}" in f" {cmd}", cmd)
    lst = subprocess.run(["lsinitrd", uki], capture_output=True, text=True).stdout
    # cpio -tv lines: mode, links, owner, group, size, month, day, time, then the name (" -> target")
    entries = {}
    for line in lst.splitlines():
        f = line.split(None, 8)
        if len(f) == 9 and line[:1] in "-dl":
            name, _, target = f[8].partition(" -> ")
            entries[name] = target
    names = list(entries)
    for f in FIRMWARE:
        ok(f"the initrd carries usr/lib/firmware/{f}", f"usr/lib/firmware/{f}" in entries, f"{len(names)} names")
    for f in LEFT_OUT:
        ok(f"the initrd leaves out {f}", not any(n.endswith(f.split("/")[-1]) for n in names))
    ok("the initrd's lib is a link to usr/lib: the loader's /lib/firmware is there", entries.get("lib") == "usr/lib",
       f"lib -> {entries.get('lib')!r}")
    ok("no kernel module in the initrd (--no-kernel)", not any(n.endswith((".ko", ".ko.zst", ".ko.xz")) for n in names))
    ok("the crypt module of dracut is in (LUKS)", any(n.endswith("/cryptsetup") for n in names), "no cryptsetup")
    print(f"== the UKI: {os.path.getsize(uki) >> 10} KiB, {len(names)} names in its initrd")


main()
print(f"dracut_test: {'all checks passed' if failures == 0 else f'{failures} FAILED'}")
sys.exit(1 if failures else 0)
