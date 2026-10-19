"""A Raspberry Pi 5 Model B (8 GB): BCM2712 with four Cortex-A76 cores (with the ARMv8 Crypto
Extensions, unlike the Pi 4), the RP1 southbridge on PCIe (Gigabit Ethernet through the Cadence
MAC, the USB controllers), the CYW43455 Wi-Fi on SDIO and its Bluetooth on a UART, VideoCore VII
(v3d for rendering, vc4 for the display), an SD card, a USB keyboard. No UEFI, no ACPI, no TPM:
the Pi firmware boots the kernel from the FAT partition and passes the device tree. Booted on
Void's rpi kernel.

[VERIFY] Synthesised from the device tree of the BCM2712 and the drivers of the Raspberry Pi
kernel; Void's rpi-kernel version, the module names and the RP1 layout are assumptions until a
`vh-kconf probe --save` on a Pi 5 replaces them.
"""
from mkfixture import pci, usb

NAME = "rpi5"
ARCH = "aarch64"
OSRELEASE = "6.12.47_1"
AXI = "platform/axi"
RP1 = AXI + "/1000120000.pcie/pci0001:00/0001:00:00.0/0001:01:00.0"


def of(name, compat):
    return f"of:N{name}T(null)C{compat}"


DEVICES = [
    ("platform", "1000120000.pcie", AXI + "/1000120000.pcie", of("pcie", "brcm,bcm2712-pcie"), "brcm-pcie", "pcie_brcmstb"),
    ("pci", "0001:00:00.0", AXI + "/1000120000.pcie/pci0001:00/0001:00:00.0", pci(0x14E4, 0x2712, 0x0000, 0x0000, 0x060400), "pcieport", ""),
    ("pci", "0001:01:00.0", RP1, pci(0x1DE4, 0x0001, 0x0000, 0x0000, 0x020000), "rp1", "rp1"),
    ("platform", "1f00100000.ethernet", RP1 + "/1f00100000.ethernet", of("ethernet", "raspberrypi,rp1-gem"), "macb", "macb"),
    ("platform", "1f00200000.usb", RP1 + "/1f00200000.usb", of("usb", "snps,dwc3"), "dwc3", "dwc3"),
    ("platform", "xhci-hcd.0", RP1 + "/1f00200000.usb/xhci-hcd.0", "platform:xhci-hcd", "xhci-hcd", "xhci_plat_hcd"),
    ("usb", "usb1", RP1 + "/1f00200000.usb/xhci-hcd.0/usb1", usb(0x1D6B, 0x0002, 0x0612, 0x09, 0, 1, 9, 0, 0, 0), "usb", "usbcore"),
    ("usb", "1-1", RP1 + "/1f00200000.usb/xhci-hcd.0/usb1/1-1", usb(0x046D, 0xC31C, 0x6400, 0, 0, 0, 3, 1, 1, 0), "usb", "usbcore"),
    ("usb", "1-1:1.0", RP1 + "/1f00200000.usb/xhci-hcd.0/usb1/1-1/1-1:1.0", usb(0x046D, 0xC31C, 0x6400, 0, 0, 0, 3, 1, 1, 0), "usbhid", "usbhid"),
    ("hid", "0003:046D:C31C.0001", RP1 + "/1f00200000.usb/xhci-hcd.0/usb1/1-1/1-1:1.0/0003:046D:C31C.0001",
     "hid:b0003g0001v0000046Dp0000C31C", "hid-generic", "hid_generic"),
    ("platform", "1000fff000.mmc", AXI + "/1000fff000.mmc", of("mmc", "brcm,bcm2712-sdhci"), "sdhci-brcmstb", "sdhci_brcmstb"),
    ("mmc", "mmc0:aaaa", AXI + "/1000fff000.mmc/mmc_host/mmc0/mmc0:aaaa", "mmc:block", "mmcblk", "mmc_block"),
    ("platform", "1001100000.mmc", AXI + "/1001100000.mmc", of("mmc", "brcm,bcm2712-sdhci"), "sdhci-brcmstb", "sdhci_brcmstb"),
    ("sdio", "mmc1:0001:1", AXI + "/1001100000.mmc/mmc_host/mmc1/mmc1:0001/mmc1:0001:1", "sdio:c00v02D0d4345", "brcmfmac", "brcmfmac"),
    ("platform", "axi:gpu", AXI + "/axi:gpu", of("gpu", "brcm,bcm2712-vc6"), "vc4-drm", "vc4"),
    ("platform", "1002000000.v3d", AXI + "/1002000000.v3d", of("v3d", "brcm,2712-v3d"), "v3d", "v3d"),
    ("platform", "107c701400.hdmi", AXI + "/107c701400.hdmi", of("hdmi", "brcm,bcm2712-hdmi0"), "vc4_hdmi", "vc4"),
    ("platform", "107d004000.rtc", "platform/soc@107c000000/107d004000.rtc", of("rtc", "brcm,bcm2712-rpi-rtc"), "rpi-rtc", "rtc_rpi"),
    ("platform", "107d200000.watchdog", "platform/soc@107c000000/107d200000.watchdog", of("watchdog", "brcm,bcm2712-pm"), "bcm2835-wdt", "bcm2835_wdt"),
    ("serial", "serial0-0", "platform/soc@107c000000/107d50c000.serial/serial0/serial0-0", of("bluetooth", "brcm,bcm43455-bt"), "hci_uart_bcm", "hci_uart"),
]

CPU = {
    "bogomips": "108.00", "features": "fp asimd evtstrm aes pmull sha1 sha2 crc32 atomics fphp asimdhp cpuid asimdrdm lrcpc dcpop asimddp",
    "implementer": "0x41", "variant": "0x4", "part": "0xd0b", "revision": "1",
    "board": [("Revision", "d04170"), ("Model", "Raspberry Pi 5 Model B Rev 1.0")],
}
CPU_MODALIAS = "cpu:type:aarch64:feature:,0000,0001,0003,0004,0005,0006,0007,0008,000B,000C,000D,000E,000F,0010,0011"
POSSIBLE = "0-3"
SMT = None
FREQ = ("cpufreq-dt", False)
TOPOLOGY = [
    {"cpu": i, "package": 0, "cluster": 0, "core": i, "siblings": f"{i}", "capacity": 1024,
     "caches": [(1, "Data", "64K", f"{i}"), (1, "Instruction", "64K", f"{i}"), (2, "Unified", "512K", f"{i}"),
                (3, "Unified", "2048K", "0-3")],
     "max_khz": 2400000}
    for i in range(4)
]
VULNS = {
    "meltdown": "Not affected",
    "spec_store_bypass": "Mitigation: Speculative Store Bypass disabled via prctl",
    "spectre_v1": "Mitigation: __user pointer sanitization",
    "spectre_v2": "Mitigation: CSV2, BHB",
}
MEMTOTAL_KB = 8_245_008
FILESYSTEMS = ["devtmpfs", "proc", "sysfs", "ext4", "tmpfs", "devpts", "vfat", "cgroup2"]
MODULES = """brcmfmac brcmutil cfg80211 rfkill hci_uart btbcm bluetooth ecdh_generic ecc
v3d vc4 gpu_sched drm_shmem_helper drm_dma_helper drm_display_helper cec drm_kms_helper snd_soc_hdmi_codec snd_soc_core snd_pcm snd_timer snd
macb rp1 dwc3 xhci_plat_hcd sdhci_brcmstb mmc_block bcm2835_wdt rtc_rpi pwm_fan
aes_ce_blk aes_ce_cipher ghash_ce sha2_ce sha256_arm64 sha1_ce
dm_crypt dm_mod zram nf_tables nfnetlink""".split()
DT = {"model": "Raspberry Pi 5 Model B Rev 1.0", "compatible": ["raspberrypi,5-model-b", "brcm,bcm2712"]}

BLOCKS = [{"name": "mmcblk0", "path": AXI + "/1000fff000.mmc/mmc_host/mmc0/mmc0:aaaa/block/mmcblk0",
           "device": AXI + "/1000fff000.mmc/mmc_host/mmc0/mmc0:aaaa",
           "sectors": 124735488, "discard_max": 4294966784, "model": "SN64G", "model_file": "name"}]
NETS = [
    {"name": "eth0", "device": RP1 + "/1f00100000.ethernet"},
    {"name": "wlan0", "device": AXI + "/1001100000.mmc/mmc_host/mmc1/mmc1:0001/mmc1:0001:1", "wireless": True},
]
DRM = [
    {"card": "card0", "device": AXI + "/1002000000.v3d"},
    {"card": "card1", "device": AXI + "/axi:gpu", "connectors": [("HDMI-A-1", "connected"), ("HDMI-A-2", "disconnected")]},
]
SOUND = [("card0", AXI + "/107c701400.hdmi")]
INPUT = """I: Bus=0003 Vendor=046d Product=c31c Version=0110
N: Name="Logitech USB Keyboard"
S: Sysfs=/devices/platform/axi/1000120000.pcie/pci0001:00/0001:00:00.0/0001:01:00.0/1f00200000.usb/xhci-hcd.0/usb1/1-1/1-1:1.0/0003:046D:C31C.0001/input/input0
H: Handlers=sysrq kbd leds event0
B: PROP=0
B: EV=120013
B: KEY=1000000000007 ff9f207ac14057ff febeffdfffefffff fffffffffffffffe
B: MSC=10
B: LED=7

"""
