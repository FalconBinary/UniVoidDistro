"""The test rig's machine (tests/vm/vhvm.py): QEMU q35 with SMM, OVMF with Secure Boot (Setup
Mode at installation time: the keys are enrolled after the first boot), swtpm through tpm-crb,
an emulated Intel IOMMU (intel-iommu, so that the rig has the full protection), the TCG "max"
CPU (QEMU presents it as AuthenticAMD family 6 model 6), 4 vCPUs, 3 GiB, an NVMe disk, an e1000
NIC, virtio-vga, the PS/2 keyboard of the ICH9. As the live installer sees it, under the stock
Void 6.18.57_1.

[VERIFY] Synthesised from QEMU's device IDs; the kvm-smoke workflow saves the real snapshot
(`vh-kconf probe --save`) of the installed rig as an artifact, which replaces this one.
"""
from mkfixture import pci

NAME = "qemu-q35"
OSRELEASE = "6.18.57_1"
P = "pci0000:00"
QEMU_SUB = (0x1AF4, 0x1100)

DEVICES = [
    ("pci", "0000:00:00.0", P + "/0000:00:00.0", pci(0x8086, 0x29C0, *QEMU_SUB, 0x060000), "", ""),
    ("pci", "0000:00:01.0", P + "/0000:00:01.0", pci(0x1B36, 0x0010, *QEMU_SUB, 0x010802), "nvme", "nvme"),
    ("pci", "0000:00:02.0", P + "/0000:00:02.0", pci(0x8086, 0x100E, *QEMU_SUB, 0x020000), "e1000", "e1000"),
    ("pci", "0000:00:03.0", P + "/0000:00:03.0", pci(0x1AF4, 0x1050, 0x1AF4, 0x1100, 0x030000), "virtio-pci", "virtio_pci"),
    ("virtio", "virtio0", P + "/0000:00:03.0/virtio0", "virtio:d00000010v00001AF4", "virtio_gpu", "virtio_gpu"),
    ("pci", "0000:00:1f.0", P + "/0000:00:1f.0", pci(0x8086, 0x2918, *QEMU_SUB, 0x060100), "lpc_ich", "lpc_ich"),
    ("pci", "0000:00:1f.2", P + "/0000:00:1f.2", pci(0x8086, 0x2922, *QEMU_SUB, 0x010601), "ahci", "ahci"),
    ("pci", "0000:00:1f.3", P + "/0000:00:1f.3", pci(0x8086, 0x2930, *QEMU_SUB, 0x0C0500), "i801_smbus", "i2c_i801"),
    ("platform", "i8042", "platform/i8042", "platform:i8042", "i8042", "i8042"),
    ("serio", "serio0", "platform/i8042/serio0", "serio:ty01pr00id00ex00", "atkbd", "atkbd"),
    ("serio", "serio1", "platform/i8042/serio1", "serio:ty01pr00id00ex00", "psmouse", "psmouse"),
    ("platform", "MSFT0101:00", "platform/MSFT0101:00", "acpi:MSFT0101:", "tpm_crb", "tpm_crb"),
    ("platform", "QEMU0002:00", "platform/QEMU0002:00", "acpi:QEMU0002:", "fw_cfg", "qemu_fw_cfg"),
    ("acpi", "LNXPWRBN:00", "LNXSYSTM:00/LNXPWRBN:00", "acpi:LNXPWRBN:", "button", ""),
    ("pnp", "00:00", "pnp0/00:00", "pnp:dPNP0b00", "rtc_cmos", "rtc_cmos"),
    ("pnp", "00:01", "pnp0/00:01", "pnp:dPNP0303", "i8042 kbd", "i8042"),
]

FLAGS = ("fpu de pse tsc msr pae mce cx8 apic sep mtrr pge mca cmov pat pse36 clflush acpi mmx fxsr sse sse2 ss "
         "syscall nx pdpe1gb rdtscp lm 3dnowext 3dnow rep_good nopl cpuid extd_apicid pni pclmulqdq monitor ssse3 "
         "fma cx16 sse4_1 sse4_2 movbe popcnt aes xsave avx f16c rdrand hypervisor lahf_lm svm cr8_legacy abm "
         "sse4a 3dnowprefetch vmmcall fsgsbase bmi1 avx2 smep bmi2 erms adx smap clflushopt clwb sha_ni xsaveopt "
         "xgetbv1 arat npt vgif umip pku ospke vaes vpclmulqdq rdpid fsrm")
CPU = {
    "vendor_id": "AuthenticAMD", "family": 6, "model": 6, "stepping": 3, "microcode": "0x1000065",
    "model_name": "QEMU TCG CPU version 2.5+", "cores": 4, "cache_kb": 512,
    "core_ids": [0, 1, 2, 3], "flags": FLAGS, "bugs": "fxsave_leak sysret_ss_attrs null_seg spectre_v1 spectre_v2",
    "address_sizes": "40 bits physical, 48 bits virtual", "cpuid_level": 13, "bogomips": "5000.00",
}
CPU_MODALIAS = "cpu:type:x86,ven0002fam0006mod0006:feature:,0000,0001,0002,0003,0004,0081,0094,0099,00C2"
POSSIBLE = "0-3"
SMT = "0"
FREQ = None
TOPOLOGY = [
    {"cpu": i, "package": 0, "die": 0, "cluster": 0, "core": i, "siblings": f"{i}",
     "caches": [(1, "Data", "64K", f"{i}"), (1, "Instruction", "64K", f"{i}"), (2, "Unified", "512K", f"{i}"),
                (3, "Unified", "16384K", "0-3")]}
    for i in range(4)
]
NUMA = ["0-3"]
VULNS = {
    "meltdown": "Not affected",
    "spec_store_bypass": "Vulnerable",
    "spectre_v1": "Mitigation: usercopy/swapgs barriers and __user pointer sanitization",
    "spectre_v2": "Mitigation: Retpolines; STIBP: disabled; RSB filling; PBRSB-eIBRS: Not affected; BHI: Not affected",
}
MEMTOTAL_KB = 2_998_176
FILESYSTEMS = ["devtmpfs", "proc", "sysfs", "iso9660", "squashfs", "overlay", "tmpfs", "devpts", "efivarfs"]
MODULES = """e1000 virtio_gpu virtio_dma_buf virtio_pci virtio_pci_legacy_dev virtio_pci_modern_dev
ahci libahci lpc_ich i2c_i801 i2c_smbus psmouse tpm_crb qemu_fw_cfg
aesni_intel crypto_simd cryptd ghash_clmulni_intel kvm_amd kvm
squashfs overlay isofs loop""".split()
DMI = {
    "sys_vendor": "QEMU",
    "product_name": "Standard PC (Q35 + ICH9, 2009)",
    "product_family": "",
    "product_version": "pc-q35-11.1",
    "board_vendor": "",
    "board_name": "",
    "bios_vendor": "EDK II",
    "bios_version": "unknown",
    "bios_date": "02/02/2022",
    "chassis_type": "1",
    "modalias": "dmi:bvnEDKII:bvrunknown:bd02/02/2022:br0.0:svnQEMU:pnStandardPC(Q35+ICH9,2009):pvrpc-q35-11.1:cvnQEMU:ct1:cvrpc-q35-11.1:sku:",
}
EFI = {"bits": 64, "secure_boot": 0, "setup_mode": 1, "mor": True}
TPM = {"device": "platform/MSFT0101:00", "version": 2}
ACPI_TABLES = ["APIC", "BGRT", "DMAR", "DSDT", "FACP", "FACS", "HPET", "MCFG", "TPM2", "WAET"]
IOMMU = [("dmar0", "virtual/iommu/dmar0")]
BLOCKS = [{
    "name": "nvme0n1", "path": "virtual/nvme-subsystem/nvme-subsys0/nvme0n1",
    "device": "virtual/nvme-subsystem/nvme-subsys0",
    "controllers": [("nvme0", P + "/0000:00:01.0/nvme/nvme0")],
    "sectors": 67108864, "discard_max": 2199023255040, "model": "QEMU NVMe Ctrl",
}]
NETS = [{"name": "eth0", "device": P + "/0000:00:02.0"}]
BOOT_VGA = {P + "/0000:00:03.0": 1}
DRM = [{"card": "card0", "device": P + "/0000:00:03.0/virtio0", "connectors": [("Virtual-1", "connected")]}]
INPUT = """I: Bus=0011 Vendor=0001 Product=0001 Version=ab41
N: Name="AT Translated Set 2 keyboard"
S: Sysfs=/devices/platform/i8042/serio0/input/input1
H: Handlers=sysrq kbd event1 leds
B: PROP=0
B: EV=120013
B: KEY=402000000 3803078f800d001 feffffdfffefffff fffffffffffffffe
B: MSC=10
B: LED=7

I: Bus=0019 Vendor=0000 Product=0001 Version=0000
N: Name="Power Button"
S: Sysfs=/devices/LNXSYSTM:00/LNXPWRBN:00/input/input0
H: Handlers=kbd event0
B: PROP=0
B: EV=3
B: KEY=10000000000000 0

"""
