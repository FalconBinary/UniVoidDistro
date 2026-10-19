#!/usr/bin/env python3
"""Writes tests/kernel/fixtures/gf63: a sysfs/procfs snapshot with the shape `vh-kconf probe
--save` produces, synthesised for the MSI GF63 Thin 10SCXR of README.md (i5-10500H Comet
Lake-H, UHD 630, GTX 1650 Max-Q, AX201, RTL8111, NVMe, fTPM) under the stock Void 6.18.57_1.

    python3 tests/kernel/mkfixture.py          # rewrites the fixture tree (committed)

Every ID comes from the kernel's own tables (pinned modules.alias) or from public PCI/USB
ids; the bound drivers follow the Void-Hardened-Refurs setup (dGPU without a driver, mei
blacklisted, kvm off). [VERIFY] by `vh-kconf probe --save` on the laptop: the real snapshot
replaces this one, and kernel/hw/gf63.zon is regenerated from it.
"""
import os
import shutil
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "gf63")

# bus, name in /sys/bus/BUS/devices, real path under /sys/devices, modalias, driver, module
# (driver "" = unbound; module "" = the driver has no /sys/module link)
P = "pci0000:00"
U = P + "/0000:00:14.0/usb1"
DEVICES = [
    # the CPU side
    ("pci", "0000:00:00.0", P + "/0000:00:00.0", "pci:v00008086d00009B54sv00001462sd000012D5bc06sc00i00", "skl_uncore", "intel_uncore"),
    ("pci", "0000:00:01.0", P + "/0000:00:01.0", "pci:v00008086d00001901sv00001462sd000012D5bc06sc04i00", "pcieport", ""),
    ("pci", "0000:01:00.0", P + "/0000:00:01.0/0000:01:00.0", "pci:v000010DEd00001F99sv00001462sd000012D5bc03sc00i00", "", ""),
    ("pci", "0000:00:02.0", P + "/0000:00:02.0", "pci:v00008086d00009BC4sv00001462sd000012D5bc03sc00i00", "i915", "i915"),
    ("pci", "0000:00:04.0", P + "/0000:00:04.0", "pci:v00008086d00001903sv00001462sd000012D5bc11sc80i00", "proc_thermal_pci_legacy", "processor_thermal_device_pci_legacy"),
    ("pci", "0000:00:08.0", P + "/0000:00:08.0", "pci:v00008086d00001911sv00001462sd000012D5bc08sc80i00", "", ""),
    # the PCH (Comet Lake-H)
    ("pci", "0000:00:12.0", P + "/0000:00:12.0", "pci:v00008086d000006F9sv00001462sd000012D5bc11sc80i00", "intel_pch_thermal", "intel_pch_thermal"),
    ("pci", "0000:00:14.0", P + "/0000:00:14.0", "pci:v00008086d000006EDsv00001462sd000012D5bc0Csc03i30", "xhci_hcd", "xhci_pci"),
    ("pci", "0000:00:14.2", P + "/0000:00:14.2", "pci:v00008086d000006EFsv00001462sd000012D5bc05sc00i00", "", ""),
    ("pci", "0000:00:14.3", P + "/0000:00:14.3", "pci:v00008086d000006F0sv00008086sd00000034bc02sc80i00", "iwlwifi", "iwlwifi"),
    ("pci", "0000:00:15.0", P + "/0000:00:15.0", "pci:v00008086d000006E8sv00001462sd000012D5bc0Csc80i00", "intel-lpss", "intel_lpss_pci"),
    ("pci", "0000:00:16.0", P + "/0000:00:16.0", "pci:v00008086d000006E0sv00001462sd000012D5bc07sc80i00", "", ""),
    ("pci", "0000:00:17.0", P + "/0000:00:17.0", "pci:v00008086d000006D3sv00001462sd000012D5bc01sc06i01", "ahci", "ahci"),
    ("pci", "0000:00:1b.0", P + "/0000:00:1b.0", "pci:v00008086d000006C0sv00001462sd000012D5bc06sc04i00", "pcieport", ""),
    ("pci", "0000:02:00.0", P + "/0000:00:1b.0/0000:02:00.0", "pci:v0000144Dd0000A809sv0000144Dsd0000A801bc01sc08i02", "nvme", "nvme"),
    ("pci", "0000:00:1c.0", P + "/0000:00:1c.0", "pci:v00008086d000006B8sv00001462sd000012D5bc06sc04i00", "pcieport", ""),
    ("pci", "0000:03:00.0", P + "/0000:00:1c.0/0000:03:00.0", "pci:v000010ECd00008168sv00001462sd000012D5bc02sc00i00", "r8169", "r8169"),
    ("pci", "0000:00:1c.4", P + "/0000:00:1c.4", "pci:v00008086d000006BCsv00001462sd000012D5bc06sc04i00", "pcieport", ""),
    ("pci", "0000:04:00.0", P + "/0000:00:1c.4/0000:04:00.0", "pci:v000010ECd0000522Asv00001462sd000012D5bcFFsc00i00", "rtsx_pci", "rtsx_pci"),
    ("pci", "0000:00:1f.0", P + "/0000:00:1f.0", "pci:v00008086d00000687sv00001462sd000012D5bc06sc01i00", "lpc_ich", "lpc_ich"),
    ("pci", "0000:00:1f.3", P + "/0000:00:1f.3", "pci:v00008086d000006C8sv00001462sd000012D5bc04sc03i00", "snd_hda_intel", "snd_hda_intel"),
    ("pci", "0000:00:1f.4", P + "/0000:00:1f.4", "pci:v00008086d000006A3sv00001462sd000012D5bc0Csc05i00", "i801_smbus", "i2c_i801"),
    ("pci", "0000:00:1f.5", P + "/0000:00:1f.5", "pci:v00008086d000006A4sv00001462sd000012D5bc0Csc80i00", "", ""),
    # USB: the root hubs, the webcam, the keyboard controller, the AX201 Bluetooth
    ("usb", "usb1", U, "usb:v1D6Bp0002d0618dc09dsc00dp01ic09isc00ip00in00", "usb", "usbcore"),
    ("usb", "1-0:1.0", U + "/1-0:1.0", "usb:v1D6Bp0002d0618dc09dsc00dp01ic09isc00ip00in00", "hub", "usbcore"),
    ("usb", "1-7", U + "/1-7", "usb:v5986p211Cd0003dcEFdsc02dp01ic0Eisc01ip00in00", "usb", "usbcore"),
    ("usb", "1-7:1.0", U + "/1-7/1-7:1.0", "usb:v5986p211Cd0003dcEFdsc02dp01ic0Eisc01ip00in00", "uvcvideo", "uvcvideo"),
    ("usb", "1-7:1.1", U + "/1-7/1-7:1.1", "usb:v5986p211Cd0003dcEFdsc02dp01ic0Eisc02ip00in01", "uvcvideo", "uvcvideo"),
    ("usb", "1-13", U + "/1-13", "usb:v1770pFF00d0110dc00dsc00dp00ic03isc00ip00in00", "usb", "usbcore"),
    ("usb", "1-13:1.0", U + "/1-13/1-13:1.0", "usb:v1770pFF00d0110dc00dsc00dp00ic03isc00ip00in00", "usbhid", "usbhid"),
    ("usb", "1-14", U + "/1-14", "usb:v8087p0026d0002dcE0dsc01dp01icE0isc01ip01in00", "usb", "usbcore"),
    ("usb", "1-14:1.0", U + "/1-14/1-14:1.0", "usb:v8087p0026d0002dcE0dsc01dp01icE0isc01ip01in00", "btusb", "btusb"),
    ("usb", "1-14:1.1", U + "/1-14/1-14:1.1", "usb:v8087p0026d0002dcE0dsc01dp01icE0isc01ip01in01", "btusb", "btusb"),
    ("usb", "usb2", P + "/0000:00:14.0/usb2", "usb:v1D6Bp0003d0618dc09dsc00dp01ic09isc00ip00in00", "usb", "usbcore"),
    ("usb", "2-0:1.0", P + "/0000:00:14.0/usb2/2-0:1.0", "usb:v1D6Bp0003d0618dc09dsc00dp01ic09isc00ip00in00", "hub", "usbcore"),
    # HID: the keyboard LED controller over USB, the touchpad over I2C
    ("hid", "0003:1770:FF00.0001", U + "/1-13/1-13:1.0/0003:1770:FF00.0001", "hid:b0003g0001v00001770p0000FF00", "hid-generic", "hid_generic"),
    ("hid", "0018:06CB:CD41.0002", P + "/0000:00:15.0/i2c_designware.0/i2c-0/i2c-SYNA3602:00/0018:06CB:CD41.0002", "hid:b0018g0004v000006CBp0000CD41", "hid-multitouch", "hid_multitouch"),
    ("i2c", "i2c-SYNA3602:00", P + "/0000:00:15.0/i2c_designware.0/i2c-0/i2c-SYNA3602:00", "acpi:SYNA3602:PNP0C50:", "i2c_hid_acpi", "i2c_hid_acpi"),
    # platform devices
    ("platform", "i2c_designware.0", P + "/0000:00:15.0/i2c_designware.0", "platform:i2c_designware", "i2c_designware", "i2c_designware_platform"),
    ("platform", "coretemp.0", "platform/coretemp.0", "platform:coretemp", "coretemp", "coretemp"),
    ("platform", "intel_rapl_msr.0", "platform/intel_rapl_msr.0", "platform:intel_rapl_msr", "intel_rapl_msr", "intel_rapl_msr"),
    ("platform", "iTCO_wdt.1.auto", "platform/iTCO_wdt.1.auto", "platform:iTCO_wdt", "iTCO_wdt", "iTCO_wdt"),
    ("platform", "i8042", "platform/i8042", "platform:i8042", "i8042", "i8042"),
    ("platform", "pcspkr", "platform/pcspkr", "platform:pcspkr", "", ""),
    ("platform", "intel_pmc_core.0", "platform/intel_pmc_core.0", "platform:intel_pmc_core", "intel_pmc_core", "intel_pmc_core"),
    ("platform", "efi-framebuffer.0", "platform/efi-framebuffer.0", "platform:efi-framebuffer", "efi-framebuffer", ""),
    ("platform", "MSFT0101:00", "platform/MSFT0101:00", "acpi:MSFT0101:PNP0C31:", "tpm_crb", "tpm_crb"),
    ("platform", "INT3450:00", "platform/INT3450:00", "acpi:INT3450:", "cannonlake-pinctrl", "pinctrl_cannonlake"),
    ("platform", "INT33D5:00", "platform/INT33D5:00", "acpi:INT33D5:", "intel-hid", "intel_hid"),
    ("platform", "INT3400:00", "platform/INT3400:00", "acpi:INT3400:", "int3400 thermal", "int3400_thermal"),
    # ACPI objects (the drivers bind to the platform or pnp companions)
    ("acpi", "PNP0C0C:00", "LNXSYSTM:00/LNXSYBUS:00/PNP0C0C:00", "acpi:PNP0C0C:", "button", ""),
    ("acpi", "PNP0C09:00", "LNXSYSTM:00/LNXSYBUS:00/PNP0C09:00", "acpi:PNP0C09:", "ec", ""),
    ("acpi", "PNP0C0A:00", "LNXSYSTM:00/LNXSYBUS:00/PNP0C09:00/PNP0C0A:00", "acpi:PNP0C0A:", "battery", "battery"),
    ("acpi", "ACPI0003:00", "LNXSYSTM:00/LNXSYBUS:00/PNP0C09:00/ACPI0003:00", "acpi:ACPI0003:", "ac", "ac"),
    ("acpi", "PNP0B00:00", "LNXSYSTM:00/LNXSYBUS:00/PNP0B00:00", "acpi:PNP0B00:", "", ""),
    ("acpi", "PNP0303:00", "LNXSYSTM:00/LNXSYBUS:00/PNP0303:00", "acpi:PNP0303:", "", ""),
    ("acpi", "MSFT0101:00", "LNXSYSTM:00/LNXSYBUS:00/MSFT0101:00", "acpi:MSFT0101:PNP0C31:", "", ""),
    ("acpi", "INT3450:00", "LNXSYSTM:00/LNXSYBUS:00/INT3450:00", "acpi:INT3450:", "", ""),
    ("acpi", "LNXCPU:00", "LNXSYSTM:00/LNXCPU:00", "acpi:LNXCPU:", "", ""),
    # pnp
    ("pnp", "00:02", "pnp0/00:02", "pnp:dPNP0b00", "rtc_cmos", "rtc_cmos"),
    ("pnp", "00:03", "pnp0/00:03", "pnp:dPNP0303", "i8042 kbd", "i8042"),
    # the internal keyboard
    ("serio", "serio0", "platform/i8042/serio0", "serio:ty01pr00id00ex00", "atkbd", "atkbd"),
    # the HDA codecs
    ("hdaudio", "hdaudioC0D0", P + "/0000:00:1f.3/hdaudioC0D0", "hdaudio:v10EC0233r00100003a01", "snd_hda_codec_alc269", "snd_hda_codec_alc269"),
    ("hdaudio", "hdaudioC0D2", P + "/0000:00:1f.3/hdaudioC0D2", "hdaudio:v80862812r00100000a01", "snd_hda_codec_intelhdmi", "snd_hda_codec_intelhdmi"),
]

# the CPU: Comet Lake-H, family 6 model 165 (0xA5); the feature numbers that the pinned
# modules.alias patterns look at: 0081 pclmulqdq, 0083 mwait, 0099 aes, 01C0 dtherm,
# 01C6 pts; no 0085 (vmx): VT-x is off in the firmware (VH_VIRT=no)
CPU_FEATURES = ("0000,0001,0002,0003,0004,0005,0006,0007,0008,0009,000B,000C,000D,000E,000F,"
                "0010,0011,0013,0015,0016,0017,0018,0019,001A,001B,001C,001D,0020,0023,0027,"
                "002A,002B,002C,002D,002E,002F,0033,0036,0039,003A,003B,003C,0065,0066,0067,"
                "0068,0069,006B,006C,006D,006E,006F,0070,0072,0074,0075,0076,0078,0079,007A,"
                "007B,0080,0081,0082,0083,0084,0086,0087,0088,0089,008B,008C,008D,008E,008F,"
                "0091,0092,0093,0094,0095,0096,0097,0098,0099,009A,009B,009C,009D,009E,009F,"
                "00C0,00C5,00C8,00E1,00E3,00E7,00EB,00EC,00F0,00F1,00F3,00F5,00F6,00F9,00FA,"
                "00FB,00FD,00FE,0100,0101,0102,0103,0104,0111,0120,0121,0123,0125,0127,0128,"
                "0129,012A,012B,012C,012D,012F,0132,0133,0134,0135,0137,0138,0139,013C,013D,"
                "013E,013F,0140,0141,0142,0143,0160,0161,0162,0163,0164,0165,0166,016B,016C,"
                "016F,0170,0171,0172,017A,017B,017C,017D,017E,017F,0180,0181,0182,0184,0185,"
                "0186,0189,018A,01C0,01C1,01C2,01C4,01C5,01C6,01C7,01C8,01C9,01CA,01CD,01CF,"
                "01D0,01D1,01D5,0200,0201,0202,0203,0204,0205,0206,0207,0208,0209,020A,020B")
CPU_MODALIAS = "cpu:type:x86,ven0000fam0006mod00A5:feature:," + CPU_FEATURES
CPU_FLAGS = ("fpu vme de pse tsc msr pae mce cx8 apic sep mtrr pge mca cmov pat pse36 clflush dts "
             "acpi mmx fxsr sse sse2 ss ht tm pbe syscall nx pdpe1gb rdtscp lm constant_tsc art "
             "arch_perfmon pebs bts rep_good nopl xtopology nonstop_tsc cpuid aperfmperf pni "
             "pclmulqdq dtes64 monitor ds_cpl est tm2 ssse3 sdbg fma cx16 xtpr pdcm pcid sse4_1 "
             "sse4_2 x2apic movbe popcnt tsc_deadline_timer aes xsave avx f16c rdrand lahf_lm abm "
             "3dnowprefetch cpuid_fault epb ssbd ibrs ibpb stibp ibrs_enhanced fsgsbase tsc_adjust "
             "bmi1 avx2 smep bmi2 erms invpcid mpx rdseed adx smap clflushopt intel_pt xsaveopt "
             "xsavec xgetbv1 xsaves dtherm ida arat pln pts hwp hwp_notify hwp_act_window hwp_epp "
             "pku ospke md_clear flush_l1d arch_capabilities")

DMI = {
    "sys_vendor": "Micro-Star International Co., Ltd.",
    "product_name": "GF63 Thin 10SCXR",
    "product_family": "GF",
    "product_version": "REV:1.0",
    "board_vendor": "Micro-Star International Co., Ltd.",
    "board_name": "MS-16R5",
    "bios_vendor": "American Megatrends Inc.",
    "bios_version": "E16R5IMS.10F",
    "bios_date": "09/14/2021",
    "chassis_type": "10",
    # the serial numbers of a real machine live in product_serial, board_serial,
    # chassis_serial and product_uuid: the probe never reads them, the fixture has none
    "modalias": ("dmi:bvnAmericanMegatrendsInc.:bvrE16R5IMS.10F:bd09/14/2021:br5.17:efr1.9:"
                 "svnMicro-StarInternationalCo.,Ltd.:pnGF63Thin10SCXR:pvrREV1.0:"
                 "rvnMicro-StarInternationalCo.,Ltd.:rnMS-16R5:rvrREV1.0:"
                 "cvnMicro-StarInternationalCo.,Ltd.:ct10:cvrN/A:sku16R5.1:"),
}

# /proc/modules of the stock system after the module lock (install/30-lock.sh); mei, kvm,
# nouveau and tiny_power_button are blacklisted there and absent here
MODULES = """iwlmvm iwlwifi mac80211 cfg80211 libarc4 rfkill
btusb btintel btrtl btbcm btmtk bluetooth ecdh_generic ecc
r8169 realtek mdio_devres libphy
i915 drm_buddy ttm drm_display_helper cec i2c_algo_bit video wmi
snd_hda_codec_alc269 snd_hda_codec_realtek_lib snd_hda_codec_generic snd_hda_codec_intelhdmi
snd_hda_intel snd_intel_dspcfg snd_intel_sdw_acpi snd_hda_codec snd_hda_core snd_hwdep snd_pcm snd_timer snd soundcore
intel_rapl_msr intel_rapl_common x86_pkg_temp_thermal intel_powerclamp coretemp
aesni_intel crypto_simd cryptd ghash_clmulni_intel polyval_clmulni polyval_generic
intel_cstate intel_uncore
processor_thermal_device_pci_legacy processor_thermal_device processor_thermal_rfim processor_thermal_rapl processor_thermal_wt_req int340x_thermal_zone intel_pch_thermal int3400_thermal acpi_thermal_rel
i2c_i801 i2c_smbus intel_lpss_pci intel_lpss idma64
i2c_hid_acpi i2c_hid hid_multitouch i2c_designware_platform i2c_designware_core
intel_pmc_core pinctrl_cannonlake iTCO_wdt iTCO_vendor_support intel_hid sparse_keymap msi_ec
rtsx_pci_sdmmc rtsx_pci mmc_core ahci libahci xhci_pci xhci_pci_renesas usbhid hid_generic
zram dm_crypt xts dm_mod xfs crc32c_intel
nf_tables nft_ct nft_log nf_log_syslog nft_limit nf_conntrack nf_defrag_ipv6 nf_defrag_ipv4 nfnetlink
tcp_bbr sch_fq vfat fat exfat nls_cp437 nls_iso8859_1 nls_utf8 usb_storage uas
tpm_crb tpm rng_core battery ac""".split()

MOUNTS = """devtmpfs /dev devtmpfs rw,nosuid,noexec,relatime,size=8000000k,nr_inodes=2000000,mode=755 0 0
proc /proc proc rw,nosuid,nodev,noexec,relatime 0 0
sysfs /sys sysfs rw,nosuid,nodev,noexec,relatime 0 0
/dev/mapper/luks-root / xfs rw,noatime,attr2,inode64,logbufs=8,logbsize=256k,noquota 0 0
securityfs /sys/kernel/security securityfs rw,nosuid,nodev,noexec,relatime 0 0
tmpfs /run tmpfs rw,nosuid,nodev,mode=755 0 0
devpts /dev/pts devpts rw,nosuid,noexec,relatime,gid=5,mode=620,ptmxmode=000 0 0
tmpfs /dev/shm tmpfs rw,nosuid,nodev,noexec,relatime,size=2097152k 0 0
cgroup2 /sys/fs/cgroup cgroup2 rw,nosuid,nodev,noexec,relatime,nsdelegate,memory_recursiveprot 0 0
efivarfs /sys/firmware/efi/efivars efivarfs rw,nosuid,nodev,noexec,relatime 0 0
/dev/nvme0n1p1 /boot/efi vfat ro,nosuid,nodev,noexec,relatime,fmask=0177,dmask=0077,codepage=437,iocharset=iso8859-1,shortname=mixed,errors=remount-ro 0 0
tmpfs /tmp tmpfs rw,nosuid,nodev,noexec,relatime,size=4194304k 0 0
"""


def write(rel, content):
    path = os.path.join(ROOT, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    mode = "wb" if isinstance(content, bytes) else "w"
    with open(path, mode) as f:
        f.write(content)


def link(rel, target):
    path = os.path.join(ROOT, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    os.symlink(target, path)


def updots(rel):
    """the '../' chain from a directory under sys/ back to sys/"""
    return "../" * len(rel.split("/"))


def main():
    if os.path.isdir(ROOT):
        shutil.rmtree(ROOT)
    os.makedirs(ROOT)
    write("proc/sys/kernel/osrelease", "6.18.57_1\n")
    write("proc/modules", "".join(f"{m} 16384 0 - Live 0xffffffffc0000000\n" for m in MODULES))
    write("proc/mounts", MOUNTS)
    blocks = []
    for i in range(12):
        blocks.append(
            f"processor\t: {i}\nvendor_id\t: GenuineIntel\ncpu family\t: 6\nmodel\t\t: 165\n"
            f"model name\t: Intel(R) Core(TM) i5-10500H CPU @ 2.50GHz\nstepping\t: 2\nmicrocode\t: 0xf6\n"
            f"cpu MHz\t\t: 2500.000\ncache size\t: 12288 KB\nphysical id\t: 0\nsiblings\t: 12\n"
            f"core id\t\t: {i % 6}\ncpu cores\t: 6\napicid\t\t: {i}\nfpu\t\t: yes\ncpuid level\t: 22\nwp\t\t: yes\n"
            f"flags\t\t: {CPU_FLAGS}\nbugs\t\t: spectre_v1 spectre_v2 spec_store_bypass swapgs itlb_multihit srbds mmio_stale_data retbleed gds bhi\n"
            f"bogomips\t: 4999.90\nclflush size\t: 64\ncache_alignment\t: 64\naddress sizes\t: 39 bits physical, 48 bits virtual\n\n")
    write("proc/cpuinfo", "".join(blocks))

    # sysfs: the devices with their real paths, the bus symlinks, the driver and module links
    for bus, name, real, modalias, driver, module in DEVICES:
        devdir = "sys/devices/" + real
        write(devdir + "/modalias", modalias + "\n")
        link(f"sys/bus/{bus}/devices/{name}", "../../../devices/" + real)
        if driver:
            link(devdir + "/driver", updots("devices/" + real) + f"bus/{bus}/drivers/{driver}")
            drvdir = f"sys/bus/{bus}/drivers/{driver}"
            os.makedirs(os.path.join(ROOT, drvdir), exist_ok=True)
            if module and not os.path.lexists(os.path.join(ROOT, drvdir, "module")):
                link(drvdir + "/module", "../../../../module/" + module)
                os.makedirs(os.path.join(ROOT, "sys/module", module), exist_ok=True)
    # the CPUs: one bus entry each, the SMT and cache files of cpu0
    for i in range(12):
        write(f"sys/devices/system/cpu/cpu{i}/modalias", CPU_MODALIAS + "\n")
        link(f"sys/bus/cpu/devices/cpu{i}", f"../../../devices/system/cpu/cpu{i}")
        link(f"sys/devices/system/cpu/cpu{i}/driver", "../../../../bus/cpu/drivers/processor")
    os.makedirs(os.path.join(ROOT, "sys/bus/cpu/drivers/processor"), exist_ok=True)
    write("sys/devices/system/cpu/smt/active", "1\n")
    write("sys/devices/system/cpu/smt/control", "on\n")
    for idx, (level, kind, size, shared) in enumerate([(1, "Data", "32K", None), (1, "Instruction", "32K", None),
                                                       (2, "Unified", "256K", None), (3, "Unified", "12288K", "0-11")]):
        d = f"sys/devices/system/cpu/cpu0/cache/index{idx}/"
        write(d + "level", f"{level}\n")
        write(d + "type", f"{kind}\n")
        write(d + "size", f"{size}\n")
        write(d + "shared_cpu_list", (shared or "0,6") + "\n")
    # DMI
    for k, v in DMI.items():
        write("sys/devices/virtual/dmi/id/" + k, v + "\n")
    link("sys/class/dmi/id", "../../devices/virtual/dmi/id")
    # EFI and Secure Boot (4 bytes of attributes, then the value)
    write("sys/firmware/efi/fw_platform_size", "64\n")
    write("sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c", b"\x06\x00\x00\x00\x01")
    # the fTPM: the class device under the platform device that tpm_crb drives
    tpm = "sys/devices/platform/MSFT0101:00/tpm/tpm0"
    write(tpm + "/tpm_version_major", "2\n")
    link(tpm + "/device", "../../../MSFT0101:00")
    link("sys/class/tpm/tpm0", "../../devices/platform/MSFT0101:00/tpm/tpm0")
    n = sum(len(files) + len(dirs) for _, dirs, files in os.walk(ROOT))
    print(f"{ROOT}: {len(DEVICES) + 12} devices, {n} entries")
    return 0


if __name__ == "__main__":
    sys.exit(main())
