"""A thin laptop on Alder Lake-P: Dell XPS 13 9320 with an Intel Core i7-1260P (4 P-cores with
SMT and 8 E-cores in two clusters: 16 CPUs), Iris Xe graphics, Intel AX211 Wi-Fi (CNVi) with its
USB Bluetooth, audio through the SOF DSP, two Thunderbolt 4 ports, the NVMe behind Intel VMD
("RAID On", the factory setting), a PS/2 keyboard and an I2C-HID touchpad, a UVC camera, a
fingerprint reader without a driver, Intel PTT (fTPM), an IOMMU (DMAR), Secure Boot on, no
Ethernet. Booted on the stock Void 6.18.57_1 with everything in use loaded; the Thunderbolt and
ME drivers are bound (they are denied later, not by the live system).

[VERIFY] Synthesised from the public IDs of this hardware and the drivers of the stock Void
kernel (kernel/pins); the subsystem IDs, the frequencies and the connectors are plausible values.
"""
from mkfixture import pci, usb

NAME = "intel-hybrid-laptop"
OSRELEASE = "6.18.57_1"
P = "pci0000:00"
U = P + "/0000:00:14.0/usb3"
DELL = 0x1028
SUB = 0x0AF3
VMD = P + "/0000:00:0e.0/pci10000:e0/10000:e0:06.0"

DEVICES = [
    ("pci", "0000:00:00.0", P + "/0000:00:00.0", pci(0x8086, 0x4621, DELL, SUB, 0x060000), "", ""),
    ("pci", "0000:00:02.0", P + "/0000:00:02.0", pci(0x8086, 0x46A6, DELL, SUB, 0x030000), "i915", "i915"),
    ("pci", "0000:00:04.0", P + "/0000:00:04.0", pci(0x8086, 0x461D, DELL, SUB, 0x118000), "proc_thermal_pci", "processor_thermal_device_pci"),
    ("pci", "0000:00:07.0", P + "/0000:00:07.0", pci(0x8086, 0x466E, DELL, SUB, 0x060400), "pcieport", ""),
    ("pci", "0000:00:07.2", P + "/0000:00:07.2", pci(0x8086, 0x463F, DELL, SUB, 0x060400), "pcieport", ""),
    ("pci", "0000:00:08.0", P + "/0000:00:08.0", pci(0x8086, 0x464F, DELL, SUB, 0x088000), "", ""),
    ("pci", "0000:00:0a.0", P + "/0000:00:0a.0", pci(0x8086, 0x467D, DELL, SUB, 0x118000), "intel_vsec", "intel_vsec"),
    ("pci", "0000:00:0d.0", P + "/0000:00:0d.0", pci(0x8086, 0x461E, DELL, SUB, 0x0C0330), "xhci_hcd", "xhci_pci"),
    ("pci", "0000:00:0d.2", P + "/0000:00:0d.2", pci(0x8086, 0x463E, DELL, SUB, 0x0C0340), "thunderbolt", "thunderbolt"),
    ("pci", "0000:00:0d.3", P + "/0000:00:0d.3", pci(0x8086, 0x466D, DELL, SUB, 0x0C0340), "thunderbolt", "thunderbolt"),
    ("pci", "0000:00:0e.0", P + "/0000:00:0e.0", pci(0x8086, 0x467F, DELL, SUB, 0x010400), "vmd", "vmd"),
    ("pci", "10000:e0:06.0", VMD, pci(0x8086, 0x464D, DELL, SUB, 0x060400), "pcieport", ""),
    ("pci", "10000:e1:00.0", VMD + "/10000:e1:00.0", pci(0x144D, 0xA80A, 0x144D, 0xA801, 0x010802), "nvme", "nvme"),
    ("pci", "0000:00:12.0", P + "/0000:00:12.0", pci(0x8086, 0x51FC, DELL, SUB, 0x070000), "intel_ish_ipc", "intel_ish_ipc"),
    ("pci", "0000:00:14.0", P + "/0000:00:14.0", pci(0x8086, 0x51ED, DELL, SUB, 0x0C0330), "xhci_hcd", "xhci_pci"),
    ("pci", "0000:00:14.2", P + "/0000:00:14.2", pci(0x8086, 0x51EF, DELL, SUB, 0x050000), "", ""),
    ("pci", "0000:00:14.3", P + "/0000:00:14.3", pci(0x8086, 0x51F0, 0x8086, 0x0094, 0x028000), "iwlwifi", "iwlwifi"),
    ("pci", "0000:00:15.0", P + "/0000:00:15.0", pci(0x8086, 0x51E8, DELL, SUB, 0x0C8000), "intel-lpss", "intel_lpss_pci"),
    ("pci", "0000:00:15.1", P + "/0000:00:15.1", pci(0x8086, 0x51E9, DELL, SUB, 0x0C8000), "intel-lpss", "intel_lpss_pci"),
    ("pci", "0000:00:16.0", P + "/0000:00:16.0", pci(0x8086, 0x51E0, DELL, SUB, 0x078000), "mei_me", "mei_me"),
    ("pci", "0000:00:1f.0", P + "/0000:00:1f.0", pci(0x8086, 0x5182, DELL, SUB, 0x060100), "", ""),
    ("pci", "0000:00:1f.3", P + "/0000:00:1f.3", pci(0x8086, 0x51C8, DELL, SUB, 0x040100), "sof-audio-pci-intel-tgl", "snd_sof_pci_intel_tgl"),
    ("pci", "0000:00:1f.4", P + "/0000:00:1f.4", pci(0x8086, 0x51A3, DELL, SUB, 0x0C0500), "i801_smbus", "i2c_i801"),
    ("pci", "0000:00:1f.5", P + "/0000:00:1f.5", pci(0x8086, 0x51A4, DELL, SUB, 0x0C8000), "intel-spi", "spi_intel_pci"),
    # USB: the root hub, the AX211 Bluetooth, the camera, the fingerprint reader (no driver)
    ("usb", "usb3", U, usb(0x1D6B, 0x0002, 0x0618, 0x09, 0, 1, 9, 0, 0, 0), "usb", "usbcore"),
    ("usb", "3-10", U + "/3-10", usb(0x8087, 0x0033, 0x0000, 0xE0, 1, 1, 0xE0, 1, 1, 0), "usb", "usbcore"),
    ("usb", "3-10:1.0", U + "/3-10/3-10:1.0", usb(0x8087, 0x0033, 0x0000, 0xE0, 1, 1, 0xE0, 1, 1, 0), "btusb", "btusb"),
    ("usb", "3-5", U + "/3-5", usb(0x0BDA, 0x5532, 0x0003, 0xEF, 2, 1, 0x0E, 1, 0, 0), "usb", "usbcore"),
    ("usb", "3-5:1.0", U + "/3-5/3-5:1.0", usb(0x0BDA, 0x5532, 0x0003, 0xEF, 2, 1, 0x0E, 1, 0, 0), "uvcvideo", "uvcvideo"),
    ("usb", "3-9", U + "/3-9", usb(0x27C6, 0x63AC, 0x0100, 0xEF, 0, 0, 0xFF, 0, 0, 0), "usb", "usbcore"),
    ("usb", "3-9:1.0", U + "/3-9/3-9:1.0", usb(0x27C6, 0x63AC, 0x0100, 0xEF, 0, 0, 0xFF, 0, 0, 0), "", ""),
    # the touchpad over I2C-HID, behind the LPSS I2C controller
    ("platform", "i2c_designware.0", P + "/0000:00:15.0/i2c_designware.0", "platform:i2c_designware", "i2c_designware", "i2c_designware_platform"),
    ("i2c", "i2c-ELAN0670:00", P + "/0000:00:15.0/i2c_designware.0/i2c-0/i2c-ELAN0670:00", "acpi:ELAN0670:PNP0C50:", "i2c_hid_acpi", "i2c_hid_acpi"),
    ("hid", "0018:04F3:31C0.0001", P + "/0000:00:15.0/i2c_designware.0/i2c-0/i2c-ELAN0670:00/0018:04F3:31C0.0001",
     "hid:b0018g0004v000004F3p000031C0", "hid-multitouch", "hid_multitouch"),
    # platform and ACPI: the keyboard controller, the pin controller (Alder Lake-P uses the
    # Tiger Lake one), the TPM, buttons, the battery and AC, the HID events, thermal, UCSI
    ("platform", "i8042", "platform/i8042", "platform:i8042", "i8042", "i8042"),
    ("serio", "serio0", "platform/i8042/serio0", "serio:ty01pr00id00ex00", "atkbd", "atkbd"),
    ("platform", "INTC1055:00", "platform/INTC1055:00", "acpi:INTC1055:", "tigerlake-pinctrl", "pinctrl_tigerlake"),
    ("platform", "MSFT0101:00", "platform/MSFT0101:00", "acpi:MSFT0101:", "tpm_crb", "tpm_crb"),
    ("platform", "INTC1078:00", "platform/INTC1078:00", "acpi:INTC1078:", "intel-hid", "intel_hid"),
    ("platform", "INTC1041:00", "platform/INTC1041:00", "acpi:INTC1041:", "int3400 thermal", "int3400_thermal"),
    ("platform", "USBC000:00", "platform/USBC000:00", "acpi:USBC000:PNP0CA0:", "ucsi_acpi", "ucsi_acpi"),
    ("platform", "iTCO_wdt", "platform/iTCO_wdt", "platform:iTCO_wdt", "iTCO_wdt", "iTCO_wdt"),
    ("acpi", "PNP0C0C:00", "LNXSYSTM:00/LNXSYBUS:00/PNP0C0C:00", "acpi:PNP0C0C:", "button", ""),
    ("acpi", "PNP0C0D:00", "LNXSYSTM:00/LNXSYBUS:00/PNP0C0D:00", "acpi:PNP0C0D:", "button", ""),
    ("acpi", "PNP0C0A:00", "LNXSYSTM:00/LNXSYBUS:00/PNP0C09:00/PNP0C0A:00", "acpi:PNP0C0A:", "battery", "battery"),
    ("acpi", "ACPI0003:00", "LNXSYSTM:00/LNXSYBUS:00/PNP0C09:00/ACPI0003:00", "acpi:ACPI0003:", "ac", "ac"),
    ("wmi", "9DBB5994-A997-11DA-B012-B622A1EF5492", "platform/PNP0C14:00/wmi_bus/wmi_bus-PNP0C14:00/9DBB5994-A997-11DA-B012-B622A1EF5492",
     "wmi:9DBB5994-A997-11DA-B012-B622A1EF5492", "dell-wmi", "dell_wmi"),
    ("wmi", "A80593CE-A997-11DA-B012-B622A1EF5492", "platform/PNP0C14:00/wmi_bus/wmi_bus-PNP0C14:00/A80593CE-A997-11DA-B012-B622A1EF5492",
     "wmi:A80593CE-A997-11DA-B012-B622A1EF5492", "dell-smbios", "dell_smbios"),
    # the HDA codecs on the SOF controller's HDA link
    ("hdaudio", "ehdaudio0D0", P + "/0000:00:1f.3/ehdaudio0D0", "hdaudio:v10EC0711r00100002a01", "snd_hda_codec_alc269", "snd_hda_codec_alc269"),
    ("hdaudio", "ehdaudio0D2", P + "/0000:00:1f.3/ehdaudio0D2", "hdaudio:v8086281Cr00100000a01", "snd_hda_codec_intelhdmi", "snd_hda_codec_intelhdmi"),
]

FLAGS = ("fpu vme de pse tsc msr pae mce cx8 apic sep mtrr pge mca cmov pat pse36 clflush dts acpi mmx fxsr sse "
         "sse2 ss ht tm pbe syscall nx pdpe1gb rdtscp lm constant_tsc art arch_perfmon pebs bts rep_good nopl "
         "xtopology nonstop_tsc cpuid aperfmperf tsc_known_freq pni pclmulqdq dtes64 monitor ds_cpl vmx smx est "
         "tm2 ssse3 sdbg fma cx16 xtpr pdcm sse4_1 sse4_2 x2apic movbe popcnt tsc_deadline_timer aes xsave avx "
         "f16c rdrand lahf_lm abm 3dnowprefetch cpuid_fault epb ssbd ibrs ibpb stibp ibrs_enhanced tpr_shadow "
         "flexpriority ept vpid ept_ad fsgsbase tsc_adjust bmi1 avx2 smep bmi2 erms invpcid rdseed adx smap "
         "clflushopt clwb intel_pt sha_ni xsaveopt xsavec xgetbv1 xsaves split_lock_detect user_shstk avx_vnni "
         "dtherm ida arat pln pts hwp hwp_notify hwp_act_window hwp_epp hwp_pkg_req hfi vnmi umip pku ospke "
         "waitpkg gfni vaes vpclmulqdq tme rdpid movdiri movdir64b fsrm md_clear serialize pconfig arch_lbr ibt "
         "flush_l1d arch_capabilities")
CPU = {
    "vendor_id": "GenuineIntel", "family": 6, "model": 154, "stepping": 3, "microcode": "0x435",
    "model_name": "12th Gen Intel(R) Core(TM) i7-1260P", "cores": 12, "cache_kb": 18432,
    "core_ids": [0, 0, 4, 4, 8, 8, 12, 12, 16, 17, 18, 19, 20, 21, 22, 23], "flags": FLAGS,
    "bugs": "spectre_v1 spectre_v2 spec_store_bypass swapgs eibrs_pbrsb rfds bhi",
    "address_sizes": "39 bits physical, 48 bits virtual", "cpuid_level": 32, "bogomips": "4992.00",
}
# 0081 pclmulqdq, 0083 monitor, 0085 vmx, 0099 aes, 01C0 dtherm, 01C6 pts
CPU_MODALIAS = "cpu:type:x86,ven0000fam0006mod009A:feature:,0000,0001,0002,0003,0004,0081,0083,0085,0094,0099,01C0,01C6"
POSSIBLE = "0-15"
SMT = "1"
FREQ = ("intel_pstate", True)
HYBRID = ("0-7", "8-15")


def _cpu(i):
    if i < 8:  # a P-core thread: SMT pairs (0,1) (2,3) ...
        core = (i // 2) * 4
        sib = f"{i - i % 2}-{i - i % 2 + 1}"
        l2 = ("1280K", sib)
        return {"cpu": i, "package": 0, "die": 0, "cluster": i // 2, "core": core, "siblings": sib,
                "caches": [(1, "Data", "48K", sib), (1, "Instruction", "32K", sib), (2, "Unified", l2[0], l2[1]),
                           (3, "Unified", "18432K", "0-15")],
                "max_khz": 4700000}
    # an E-core: four share one L2
    cluster_cpus = "8-11" if i < 12 else "12-15"
    return {"cpu": i, "package": 0, "die": 0, "cluster": 4 if i < 12 else 5, "core": 8 + i, "siblings": f"{i}",
            "caches": [(1, "Data", "32K", f"{i}"), (1, "Instruction", "64K", f"{i}"), (2, "Unified", "2048K", cluster_cpus),
                       (3, "Unified", "18432K", "0-15")],
            "max_khz": 3400000}


TOPOLOGY = [_cpu(i) for i in range(16)]
NUMA = ["0-15"]
VULNS = {
    "gather_data_sampling": "Not affected",
    "itlb_multihit": "Not affected",
    "l1tf": "Not affected",
    "mds": "Not affected",
    "meltdown": "Not affected",
    "mmio_stale_data": "Not affected",
    "reg_file_data_sampling": "Mitigation: Clear Register File",
    "retbleed": "Not affected",
    "spec_rstack_overflow": "Not affected",
    "spec_store_bypass": "Mitigation: Speculative Store Bypass disabled via prctl",
    "spectre_v1": "Mitigation: usercopy/swapgs barriers and __user pointer sanitization",
    "spectre_v2": "Mitigation: Enhanced / Automatic IBRS; IBPB: conditional; RSB filling; PBRSB-eIBRS: SW sequence; BHI: BHI_DIS_S",
    "srbds": "Not affected",
    "tsx_async_abort": "Not affected",
}
MEMTOTAL_KB = 15_653_384
FILESYSTEMS = ["devtmpfs", "proc", "sysfs", "xfs", "securityfs", "tmpfs", "devpts", "tmpfs", "cgroup2",
               "efivarfs", "vfat", "tmpfs"]
MODULES = """i915 drm_buddy ttm drm_display_helper cec i2c_algo_bit video wmi
iwlmvm iwlwifi mac80211 cfg80211 libarc4 rfkill
btusb btintel btrtl btbcm btmtk bluetooth ecdh_generic ecc
snd_sof_pci_intel_tgl snd_sof_intel_hda_generic snd_sof_intel_hda_common snd_sof_intel_hda snd_sof_pci snd_sof snd_sof_utils snd_soc_hdac_hda snd_hda_ext_core snd_soc_core snd_compress snd_hda_codec_alc269 snd_hda_codec_realtek_lib snd_hda_codec_generic snd_hda_codec_intelhdmi snd_hda_intel snd_intel_dspcfg snd_intel_sdw_acpi snd_hda_codec snd_hda_core snd_hwdep snd_pcm snd_timer snd soundcore
thunderbolt vmd xhci_pci uvcvideo videobuf2_vmalloc videobuf2_memops videobuf2_v4l2 videobuf2_common videodev mc
intel_lpss_pci intel_lpss idma64 i2c_designware_platform i2c_designware_core i2c_hid_acpi i2c_hid hid_multitouch pinctrl_tigerlake
mei_me mei intel_ish_ipc intel_vsec processor_thermal_device_pci processor_thermal_device processor_thermal_rapl intel_rapl_common int3400_thermal acpi_thermal_rel
i2c_i801 i2c_smbus spi_intel_pci spi_intel iTCO_wdt iTCO_vendor_support intel_pmc_core intel_hid sparse_keymap
dell_wmi dell_smbios dell_wmi_descriptor dcdbas dell_laptop ledtrig_audio ucsi_acpi typec_ucsi typec
coretemp x86_pkg_temp_thermal intel_powerclamp intel_cstate intel_uncore kvm_intel kvm
aesni_intel crypto_simd cryptd ghash_clmulni_intel polyval_clmulni polyval_generic
tpm_crb battery ac zram dm_crypt xts dm_mod xfs
nf_tables nft_ct nft_log nf_log_syslog nft_limit nf_conntrack nf_defrag_ipv6 nf_defrag_ipv4 nfnetlink
tcp_bbr sch_fq vfat fat nls_cp437 nls_iso8859_1 nls_utf8""".split()

DMI = {
    "sys_vendor": "Dell Inc.",
    "product_name": "XPS 13 9320",
    "product_family": "XPS",
    "product_version": "",
    "board_vendor": "Dell Inc.",
    "board_name": "0CW9KM",
    "bios_vendor": "Dell Inc.",
    "bios_version": "2.14.0",
    "bios_date": "06/18/2024",
    "chassis_type": "10",
    "modalias": ("dmi:bvnDellInc.:bvr2.14.0:bd06/18/2024:br2.14:svnDellInc.:pnXPS139320:pvr:rvnDellInc.:"
                 "rn0CW9KM:rvrA00:cvnDellInc.:ct10:cvr:sku0AF3:"),
}
EFI = {"bits": 64, "secure_boot": 1, "setup_mode": 0, "mor": True}
TPM = {"device": "platform/MSFT0101:00", "version": 2}
ACPI_TABLES = ["APIC", "BGRT", "DBG2", "DBGP", "DMAR", "DSDT", "FACP", "FACS", "FPDT", "HPET", "LPIT", "MCFG",
               "NHLT", "PHAT", "SDEV", "SSDT", "TPM2", "USBC", "WSMT"]
IOMMU = [("dmar0", "virtual/iommu/dmar0"), ("dmar1", "virtual/iommu/dmar1")]

BLOCKS = [{
    "name": "nvme0n1", "path": "virtual/nvme-subsystem/nvme-subsys0/nvme0n1",
    "device": "virtual/nvme-subsystem/nvme-subsys0",
    "controllers": [("nvme0", VMD + "/10000:e1:00.0/nvme/nvme0")],
    "sectors": 2000409264, "discard_max": 2199023255040, "model": "PM9A1 NVMe Samsung 1024GB",
}]
NETS = [{"name": "wlan0", "device": P + "/0000:00:14.3", "wireless": True}]
SUPPLIES = [("AC", "Mains", None, "LNXSYSTM:00/LNXSYBUS:00/PNP0C09:00/ACPI0003:00"),
            ("BAT0", "Battery", None, "LNXSYSTM:00/LNXSYBUS:00/PNP0C09:00/PNP0C0A:00"),
            ("ucsi-source-psy-USBC000:001", "USB", None, "platform/USBC000:00/typec/port0"),
            ("ucsi-source-psy-USBC000:002", "USB", None, "platform/USBC000:00/typec/port1")]
BACKLIGHTS = [("intel_backlight", "raw", P + "/0000:00:02.0/drm/card1/card1-eDP-1")]
PROFILES = "quiet balanced performance"
BOOT_VGA = {P + "/0000:00:02.0": 1}
DRM = [{"card": "card1", "device": P + "/0000:00:02.0",
        "connectors": [("eDP-1", "connected"), ("DP-1", "disconnected"), ("DP-2", "disconnected"),
                       ("DP-3", "disconnected"), ("DP-4", "disconnected")]}]
SOUND = [("card0", P + "/0000:00:1f.3")]
INPUT = """I: Bus=0011 Vendor=0001 Product=0001 Version=ab83
N: Name="AT Translated Set 2 keyboard"
S: Sysfs=/devices/platform/i8042/serio0/input/input2
H: Handlers=sysrq kbd event2 leds
B: PROP=0
B: EV=120013
B: KEY=402000000 3803078f800d001 feffffdfffefffff fffffffffffffffe
B: MSC=10
B: LED=7

I: Bus=0019 Vendor=0000 Product=0005 Version=0000
N: Name="Lid Switch"
S: Sysfs=/devices/LNXSYSTM:00/LNXSYBUS:00/PNP0C0D:00/input/input0
H: Handlers=event0
B: PROP=0
B: EV=21
B: SW=1

I: Bus=0019 Vendor=0000 Product=0001 Version=0000
N: Name="Power Button"
S: Sysfs=/devices/LNXSYSTM:00/LNXSYBUS:00/PNP0C0C:00/input/input1
H: Handlers=kbd event1
B: PROP=0
B: EV=3
B: KEY=10000000000000 0

I: Bus=0018 Vendor=04f3 Product=31c0 Version=0100
N: Name="ELAN0670:00 04F3:31C0 Touchpad"
S: Sysfs=/devices/pci0000:00/0000:00:15.0/i2c_designware.0/i2c-0/i2c-ELAN0670:00/0018:04F3:31C0.0001/input/input8
H: Handlers=mouse0 event8
B: PROP=5
B: EV=1b
B: KEY=e520 10000 0 0 0 0

"""
