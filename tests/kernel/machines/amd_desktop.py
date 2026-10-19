"""A desktop on an AM5 motherboard: ASUS TUF GAMING B650-PLUS WIFI, AMD Ryzen 9 7950X3D (Zen 4,
16 cores and 32 threads on two CCDs: the first with 96 MB of L3 (3D V-Cache), the second with
32 MB), the integrated Radeon (Raphael) and a Radeon RX 7600 (Navi 33) that drives the monitor,
Realtek RTL8125 2.5 GbE and MediaTek MT7922 Wi-Fi/Bluetooth on the B650 chipset (Promontory 21),
a Samsung 990 PRO NVMe on the CPU's lanes, a Seagate hard disk on the chipset's SATA, a USB
keyboard, the Realtek ALC897 codec, the AMD fTPM, an IOMMU (IVRS), Secure Boot on. The Super
I/O chip (Nuvoton) is not visible to a probe: no modalias, no driver. Booted on the stock Void
6.18.57_1 with everything in use loaded.

[VERIFY] Synthesised from the public IDs of this hardware and the drivers of the stock Void
kernel (kernel/pins); the maximum frequencies per CCD and the PCI layout of the chipset are
plausible values, not readings.
"""
from mkfixture import pci, usb

NAME = "amd-desktop"
OSRELEASE = "6.18.57_1"
P = "pci0000:00"
GPU = P + "/0000:00:01.1/0000:01:00.0/0000:02:00.0"  # the RX 7600 behind its PCIe switch
CHIP = P + "/0000:00:02.1/0000:04:00.0"               # the B650 chipset's upstream port
IGPU = P + "/0000:00:08.1"
ASUS = 0x1043

DEVICES = [
    ("pci", "0000:00:00.0", P + "/0000:00:00.0", pci(0x1022, 0x14D8, 0x1022, 0x14D8, 0x060000), "", ""),
    ("pci", "0000:00:00.2", P + "/0000:00:00.2", pci(0x1022, 0x14D9, 0x1022, 0x14D9, 0x080600), "", ""),
    ("pci", "0000:00:01.1", P + "/0000:00:01.1", pci(0x1022, 0x14DB, 0x1022, 0x1453, 0x060400), "pcieport", ""),
    ("pci", "0000:01:00.0", P + "/0000:00:01.1/0000:01:00.0", pci(0x1002, 0x1478, 0x0000, 0x0000, 0x060400), "pcieport", ""),
    ("pci", "0000:02:00.0", GPU, pci(0x1002, 0x1479, 0x1002, 0x1479, 0x060400), "pcieport", ""),
    ("pci", "0000:03:00.0", GPU + "/0000:03:00.0", pci(0x1002, 0x7480, ASUS, 0x05F4, 0x030000), "amdgpu", "amdgpu"),
    ("pci", "0000:03:00.1", GPU + "/0000:03:00.1", pci(0x1002, 0xAB30, ASUS, 0x05F4, 0x040300), "snd_hda_intel", "snd_hda_intel"),
    ("pci", "0000:00:02.1", P + "/0000:00:02.1", pci(0x1022, 0x14DB, 0x1022, 0x1453, 0x060400), "pcieport", ""),
    ("pci", "0000:04:00.0", CHIP, pci(0x1022, 0x43F4, ASUS, 0x8877, 0x060400), "pcieport", ""),
    ("pci", "0000:05:08.0", CHIP + "/0000:05:08.0", pci(0x1022, 0x43F5, ASUS, 0x8877, 0x060400), "pcieport", ""),
    ("pci", "0000:06:00.0", CHIP + "/0000:05:08.0/0000:06:00.0", pci(0x10EC, 0x8125, ASUS, 0x87D7, 0x020000), "r8169", "r8169"),
    ("pci", "0000:05:09.0", CHIP + "/0000:05:09.0", pci(0x1022, 0x43F5, ASUS, 0x8877, 0x060400), "pcieport", ""),
    ("pci", "0000:07:00.0", CHIP + "/0000:05:09.0/0000:07:00.0", pci(0x14C3, 0x0616, 0x1A3B, 0x5300, 0x028000), "mt7921e", "mt7921e"),
    ("pci", "0000:05:0c.0", CHIP + "/0000:05:0c.0", pci(0x1022, 0x43F5, ASUS, 0x8877, 0x060400), "pcieport", ""),
    ("pci", "0000:08:00.0", CHIP + "/0000:05:0c.0/0000:08:00.0", pci(0x1022, 0x43F7, ASUS, 0x11F1, 0x0C0330), "xhci_hcd", "xhci_pci"),
    ("pci", "0000:05:0d.0", CHIP + "/0000:05:0d.0", pci(0x1022, 0x43F5, ASUS, 0x8877, 0x060400), "pcieport", ""),
    ("pci", "0000:09:00.0", CHIP + "/0000:05:0d.0/0000:09:00.0", pci(0x1022, 0x43F6, ASUS, 0x1062, 0x010601), "ahci", "ahci"),
    ("scsi", "0:0:0:0", CHIP + "/0000:05:0d.0/0000:09:00.0/ata1/host0/target0:0:0/0:0:0:0", "scsi:t-0x00", "sd", "sd_mod"),
    ("pci", "0000:00:02.2", P + "/0000:00:02.2", pci(0x1022, 0x14DB, 0x1022, 0x1453, 0x060400), "pcieport", ""),
    ("pci", "0000:0a:00.0", P + "/0000:00:02.2/0000:0a:00.0", pci(0x144D, 0xA80C, 0x144D, 0xA801, 0x010802), "nvme", "nvme"),
    ("pci", "0000:00:08.1", IGPU, pci(0x1022, 0x14DD, 0x1022, 0x1453, 0x060400), "pcieport", ""),
    ("pci", "0000:0b:00.0", IGPU + "/0000:0b:00.0", pci(0x1002, 0x164E, ASUS, 0x8877, 0x030000), "amdgpu", "amdgpu"),
    ("pci", "0000:0b:00.1", IGPU + "/0000:0b:00.1", pci(0x1002, 0x1640, ASUS, 0x8877, 0x040300), "snd_hda_intel", "snd_hda_intel"),
    ("pci", "0000:0b:00.2", IGPU + "/0000:0b:00.2", pci(0x1022, 0x1649, ASUS, 0x8877, 0x108000), "ccp", "ccp"),
    ("pci", "0000:0b:00.3", IGPU + "/0000:0b:00.3", pci(0x1022, 0x15B6, ASUS, 0x8877, 0x0C0330), "xhci_hcd", "xhci_pci"),
    ("pci", "0000:0b:00.6", IGPU + "/0000:0b:00.6", pci(0x1022, 0x15E3, ASUS, 0x87FB, 0x040300), "snd_hda_intel", "snd_hda_intel"),
    ("pci", "0000:00:14.0", P + "/0000:00:14.0", pci(0x1022, 0x790B, ASUS, 0x8877, 0x0C0500), "piix4_smbus", "i2c_piix4"),
    ("pci", "0000:00:14.3", P + "/0000:00:14.3", pci(0x1022, 0x790E, ASUS, 0x8877, 0x060100), "", ""),
    ("pci", "0000:00:18.3", P + "/0000:00:18.3", pci(0x1022, 0x14E3, 0x0000, 0x0000, 0x060000), "k10temp", "k10temp"),
    # USB: the keyboard on the CPU's controller, the MT7922's Bluetooth on the chipset's
    ("usb", "usb1", IGPU + "/0000:0b:00.3/usb1", usb(0x1D6B, 0x0002, 0x0618, 0x09, 0, 1, 9, 0, 0, 0), "usb", "usbcore"),
    ("usb", "1-1", IGPU + "/0000:0b:00.3/usb1/1-1", usb(0x046D, 0xC31C, 0x6400, 0, 0, 0, 3, 1, 1, 0), "usb", "usbcore"),
    ("usb", "1-1:1.0", IGPU + "/0000:0b:00.3/usb1/1-1/1-1:1.0", usb(0x046D, 0xC31C, 0x6400, 0, 0, 0, 3, 1, 1, 0), "usbhid", "usbhid"),
    ("hid", "0003:046D:C31C.0001", IGPU + "/0000:0b:00.3/usb1/1-1/1-1:1.0/0003:046D:C31C.0001", "hid:b0003g0001v0000046Dp0000C31C", "hid-generic", "hid_generic"),
    ("usb", "usb3", CHIP + "/0000:05:0c.0/0000:08:00.0/usb3", usb(0x1D6B, 0x0002, 0x0618, 0x09, 0, 1, 9, 0, 0, 0), "usb", "usbcore"),
    ("usb", "3-5", CHIP + "/0000:05:0c.0/0000:08:00.0/usb3/3-5", usb(0x13D3, 0x3585, 0x0100, 0xEF, 2, 1, 0xE0, 1, 1, 0), "usb", "usbcore"),
    ("usb", "3-5:1.0", CHIP + "/0000:05:0c.0/0000:08:00.0/usb3/3-5/3-5:1.0", usb(0x13D3, 0x3585, 0x0100, 0xEF, 2, 1, 0xE0, 1, 1, 0), "btusb", "btusb"),
    # ACPI and platform: the power button, the GPIO controller, the fTPM, the RTC, the WMI
    # interface of the board (no driver)
    ("acpi", "PNP0C0C:00", "LNXSYSTM:00/LNXSYBUS:00/PNP0C0C:00", "acpi:PNP0C0C:", "button", ""),
    ("platform", "AMDI0030:00", "platform/AMDI0030:00", "acpi:AMDI0030:", "amd_gpio", "pinctrl_amd"),
    ("platform", "MSFT0101:00", "platform/MSFT0101:00", "acpi:MSFT0101:", "tpm_crb", "tpm_crb"),
    ("pnp", "00:01", "pnp0/00:01", "pnp:dPNP0b00", "rtc_cmos", "rtc_cmos"),
    ("wmi", "466747A0-70EC-11DE-8A39-0800200C9A66", "platform/PNP0C14:00/wmi_bus/wmi_bus-PNP0C14:00/466747A0-70EC-11DE-8A39-0800200C9A66",
     "wmi:466747A0-70EC-11DE-8A39-0800200C9A66", "", ""),
    # the HDA codecs: the dGPU's and the iGPU's HDMI, the board's Realtek ALC897
    ("hdaudio", "hdaudioC0D0", GPU + "/0000:03:00.1/hdaudioC0D0", "hdaudio:v1002AA01r00100800a01", "snd_hda_codec_atihdmi", "snd_hda_codec_atihdmi"),
    ("hdaudio", "hdaudioC1D0", IGPU + "/0000:0b:00.1/hdaudioC1D0", "hdaudio:v1002AA01r00100800a01", "snd_hda_codec_atihdmi", "snd_hda_codec_atihdmi"),
    ("hdaudio", "hdaudioC2D0", IGPU + "/0000:0b:00.6/hdaudioC2D0", "hdaudio:v10EC0897r00100402a01", "snd_hda_codec_alc662", "snd_hda_codec_alc662"),
]

FLAGS = ("fpu vme de pse tsc msr pae mce cx8 apic sep mtrr pge mca cmov pat pse36 clflush mmx fxsr sse sse2 ht "
         "syscall nx mmxext fxsr_opt pdpe1gb rdtscp lm constant_tsc rep_good amd_lbr_v2 nopl nonstop_tsc cpuid "
         "extd_apicid aperfmperf rapl pni pclmulqdq monitor ssse3 fma cx16 sse4_1 sse4_2 x2apic movbe popcnt aes "
         "xsave avx f16c rdrand lahf_lm cmp_legacy svm extapic cr8_legacy abm sse4a misalignsse 3dnowprefetch osvw "
         "ibs skinit wdt tce topoext perfctr_core perfctr_nb bpext perfctr_llc mwaitx cpb cat_l3 cdp_l3 hw_pstate "
         "ssbd mba perfmon_v2 ibrs ibpb stibp ibrs_enhanced vmmcall fsgsbase bmi1 avx2 smep bmi2 erms invpcid cqm "
         "rdt_a avx512f avx512dq rdseed adx smap avx512ifma clflushopt clwb avx512cd sha_ni avx512bw avx512vl "
         "xsaveopt xsavec xgetbv1 xsaves cqm_llc cqm_occup_llc cqm_mbm_total cqm_mbm_local user_shstk avx512_bf16 "
         "clzero irperf xsaveerptr rdpru wbnoinvd cppc arat npt lbrv svm_lock nrip_save tsc_scale vmcb_clean "
         "flushbyasid decodeassists pausefilter pfthreshold avic v_vmsave_vmload vgif x2avic v_spec_ctrl vnmi "
         "avx512vbmi umip pku ospke avx512_vbmi2 gfni vaes vpclmulqdq avx512_vnni avx512_bitalg avx512_vpopcntdq "
         "rdpid overflow_recov succor smca fsrm flush_l1d amd_lbr_pmc_freeze")
CPU = {
    "vendor_id": "AuthenticAMD", "family": 25, "model": 97, "stepping": 2, "microcode": "0xa601209",
    "model_name": "AMD Ryzen 9 7950X3D 16-Core Processor", "cores": 16, "cache_kb": 1024,
    "core_ids": [i % 16 for i in range(32)], "flags": FLAGS,
    "bugs": "sysret_ss_attrs spectre_v1 spectre_v2 spec_store_bypass srso",
    "address_sizes": "48 bits physical, 48 bits virtual", "cpuid_level": 16, "bogomips": "8384.48",
}
# the feature numbers the pinned modules.alias looks at: 007D rapl, 0081 pclmulqdq, 0099 aes, 00C2 svm
CPU_MODALIAS = "cpu:type:x86,ven0002fam0019mod0061:feature:,0000,0001,0002,0003,0004,007D,0081,0094,0099,00C2"
POSSIBLE = "0-31"
SMT = "1"
FREQ = ("amd-pstate-epp", True)


def _cpu(i):
    core = i % 16
    ccd0 = core < 8
    sib = f"{core},{core + 16}"
    l3 = ("98304K", "0-7,16-23") if ccd0 else ("32768K", "8-15,24-31")
    return {"cpu": i, "package": 0, "die": 0, "cluster": 0 if ccd0 else 1, "core": core, "siblings": sib,
            "caches": [(1, "Data", "32K", sib), (1, "Instruction", "32K", sib), (2, "Unified", "1024K", sib),
                       (3, "Unified", l3[0], l3[1])],
            "max_khz": 5250000 if ccd0 else 5759000}


TOPOLOGY = [_cpu(i) for i in range(32)]
NUMA = ["0-31"]
VULNS = {
    "gather_data_sampling": "Not affected",
    "itlb_multihit": "Not affected",
    "l1tf": "Not affected",
    "mds": "Not affected",
    "meltdown": "Not affected",
    "mmio_stale_data": "Not affected",
    "reg_file_data_sampling": "Not affected",
    "retbleed": "Not affected",
    "spec_rstack_overflow": "Mitigation: Safe RET",
    "spec_store_bypass": "Mitigation: Speculative Store Bypass disabled via prctl",
    "spectre_v1": "Mitigation: usercopy/swapgs barriers and __user pointer sanitization",
    "spectre_v2": "Mitigation: Enhanced / Automatic IBRS; IBPB: conditional; STIBP: always-on; RSB filling; PBRSB-eIBRS: Not affected; BHI: Not affected",
    "srbds": "Not affected",
    "tsx_async_abort": "Not affected",
}
MEMTOTAL_KB = 65_234_872
FILESYSTEMS = ["devtmpfs", "proc", "sysfs", "xfs", "securityfs", "tmpfs", "devpts", "tmpfs", "cgroup2",
               "efivarfs", "vfat", "tmpfs"]
MODULES = """amdgpu amdxcp drm_exec gpu_sched drm_buddy drm_suballoc_helper drm_ttm_helper ttm drm_display_helper cec video wmi
snd_hda_intel snd_intel_dspcfg snd_hda_codec_atihdmi snd_hda_codec_hdmi snd_hda_codec_alc662 snd_hda_codec_realtek_lib snd_hda_codec_generic snd_hda_codec snd_hda_core snd_hwdep snd_pcm snd_timer snd soundcore
r8169 realtek mdio_devres libphy
mt7921e mt7921_common mt792x_lib mt76_connac_lib mt76 mac80211 cfg80211 libarc4 rfkill
btusb btintel btrtl btbcm btmtk bluetooth ecdh_generic ecc
xhci_pci ahci libahci usbhid hid_generic
k10temp i2c_piix4 sp5100_tco ccp kvm_amd kvm
aesni_intel crypto_simd cryptd ghash_clmulni_intel polyval_clmulni polyval_generic sha512_ssse3
tpm_crb zram dm_crypt xts dm_mod xfs
nf_tables nft_ct nft_log nf_log_syslog nft_limit nf_conntrack nf_defrag_ipv6 nf_defrag_ipv4 nfnetlink
tcp_bbr sch_fq vfat fat nls_cp437 nls_iso8859_1 nls_utf8""".split()

DMI = {
    "sys_vendor": "ASUS",
    "product_name": "System Product Name",
    "product_family": "To be filled by O.E.M.",
    "product_version": "System Version",
    "board_vendor": "ASUSTeK COMPUTER INC.",
    "board_name": "TUF GAMING B650-PLUS WIFI",
    "bios_vendor": "American Megatrends Inc.",
    "bios_version": "3024",
    "bios_date": "08/02/2024",
    "chassis_type": "3",
    "modalias": ("dmi:bvnAmericanMegatrendsInc.:bvr3024:bd08/02/2024:br5.27:svnASUS:pnSystemProductName:"
                 "pvrSystemVersion:rvnASUSTeKCOMPUTERINC.:rnTUFGAMINGB650-PLUSWIFI:rvrRev1.xx:"
                 "cvnDefaultstring:ct3:cvrDefaultstring:skuSKU:"),
}
EFI = {"bits": 64, "secure_boot": 1, "setup_mode": 0, "mor": True}
TPM = {"device": "platform/MSFT0101:00", "version": 2}
ACPI_TABLES = ["APIC", "BGRT", "CDIT", "CRAT", "DSDT", "FACP", "FACS", "FPDT", "HPET", "IVRS", "MCFG", "SSDT",
               "TPM2", "VFCT", "WSMT"]
IOMMU = [("ivhd0", P + "/0000:00:00.2/iommu/ivhd0")]

BLOCKS = [
    {"name": "nvme0n1", "path": "virtual/nvme-subsystem/nvme-subsys0/nvme0n1",
     "device": "virtual/nvme-subsystem/nvme-subsys0",
     "controllers": [("nvme0", P + "/0000:00:02.2/0000:0a:00.0/nvme/nvme0")],
     "sectors": 3907029168, "discard_max": 2199023255040, "model": "Samsung SSD 990 PRO 2TB"},
    {"name": "sda", "path": CHIP + "/0000:05:0d.0/0000:09:00.0/ata1/host0/target0:0:0/0:0:0:0/block/sda",
     "device": CHIP + "/0000:05:0d.0/0000:09:00.0/ata1/host0/target0:0:0/0:0:0:0",
     "rotational": True, "pbs": 4096, "sectors": 7814037168, "model": "ST4000DM004-2U91"},
]
NETS = [
    {"name": "eth0", "device": CHIP + "/0000:05:08.0/0000:06:00.0"},
    {"name": "wlan0", "device": CHIP + "/0000:05:09.0/0000:07:00.0", "wireless": True},
]
BOOT_VGA = {GPU + "/0000:03:00.0": 1, IGPU + "/0000:0b:00.0": 0}
DRM = [
    {"card": "card0", "device": GPU + "/0000:03:00.0",
     "connectors": [("DP-1", "connected"), ("DP-2", "disconnected"), ("HDMI-A-1", "disconnected")]},
    {"card": "card1", "device": IGPU + "/0000:0b:00.0",
     "connectors": [("DP-3", "disconnected"), ("HDMI-A-2", "disconnected")]},
]
SOUND = [("card0", GPU + "/0000:03:00.1"), ("card1", IGPU + "/0000:0b:00.1"), ("card2", IGPU + "/0000:0b:00.6")]
INPUT = """I: Bus=0003 Vendor=046d Product=c31c Version=0110
N: Name="Logitech USB Keyboard"
S: Sysfs=/devices/pci0000:00/0000:00:08.1/0000:0b:00.3/usb1/1-1/1-1:1.0/0003:046D:C31C.0001/input/input3
H: Handlers=sysrq kbd leds event3
B: PROP=0
B: EV=120013
B: KEY=1000000000007 ff9f207ac14057ff febeffdfffefffff fffffffffffffffe
B: MSC=10
B: LED=7

I: Bus=0019 Vendor=0000 Product=0001 Version=0000
N: Name="Power Button"
S: Sysfs=/devices/LNXSYSTM:00/LNXSYBUS:00/PNP0C0C:00/input/input0
H: Handlers=kbd event0
B: PROP=0
B: EV=3
B: KEY=10000000000000 0

"""
