#!/usr/bin/env python3
"""kernel/pins/modules.firmware: the firmware files every module of the stock kernel names
(MODULE_FIRMWARE), the table vh-plan turns the modules of a machine into the firmware it keeps.
It is read from the pinned package itself: the .modinfo section of every module (the modules
are zstd-compressed ELF files) and the firmware records of modules.builtin.modinfo for the
drivers built into the kernel. Nothing from the package is loaded or run.

    python3 -I kernel/pins/mkfirmware.py PACKAGE.xbps kernel/pins/modules.builtin.modinfo > kernel/pins/modules.firmware
    python3 -I kernel/pins/mkfirmware.py PACKAGE.xbps kernel/pins/aarch64-modules.builtin.modinfo > kernel/pins/aarch64-modules.firmware

The package must be one kernel/pins/README.md pins, named as Void names it (its SHA-256 is
checked against PINNED, by file name); zstd is the only tool it needs.
"""
import hashlib
import struct
import subprocess
import sys
import tarfile

# the pinned packages, one per architecture (kernel/pins/README.md)
PINNED = {
    "linux6.18-6.18.57_1.x86_64.xbps": "5d4f1e5a600be214472b6ab80736d45078dd9cf0e31dd71f4be0ebf7d4ee22a5",
    "linux6.18-6.18.59_1.aarch64.xbps": "384f24feca187ed28af4f02b9807a3f7c6a42a7cd7f701dd40e0e0dbf51955b5",
}


def normalize(name):
    return name.replace("-", "_")


def modinfo(elf):
    """the NUL-separated records of the .modinfo section of a 64-bit little-endian ELF"""
    if elf[:4] != b"\x7fELF" or elf[4] != 2 or elf[5] != 1:
        raise ValueError("not a 64-bit little-endian ELF")
    shoff, = struct.unpack_from("<Q", elf, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", elf, 0x3A)

    def section(i):
        base = shoff + i * shentsize
        name, = struct.unpack_from("<I", elf, base)
        offset, size = struct.unpack_from("<QQ", elf, base + 0x18)
        return name, offset, size

    _, str_off, str_size = section(shstrndx)
    names = elf[str_off:str_off + str_size]
    for i in range(shnum):
        name, offset, size = section(i)
        end = names.index(b"\0", name)
        if names[name:end] == b".modinfo":
            return [r.decode("utf-8", "replace") for r in elf[offset:offset + size].split(b"\0") if r]
    return []


def main(package, builtin_modinfo):
    pkg = package.rsplit("/", 1)[-1]
    pinned = PINNED.get(pkg)
    if pinned is None:
        sys.exit(f"{package}: not a pinned package (one of {', '.join(sorted(PINNED))})")
    h = hashlib.sha256()
    with open(package, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    if h.hexdigest() != pinned:
        sys.exit(f"{package}: sha256 {h.hexdigest()}, the pin says {pinned}")
    pairs = set()
    unpack = subprocess.Popen(["zstd", "-dc", package], stdout=subprocess.PIPE)
    modules = 0
    with tarfile.open(fileobj=unpack.stdout, mode="r|") as tar:
        for m in tar:
            if not (m.isfile() and m.name.endswith(".ko.zst") and "/usr/lib/modules/" in "/" + m.name.lstrip("./")):
                continue
            data = tar.extractfile(m).read()
            elf = subprocess.run(["zstd", "-dc"], input=data, stdout=subprocess.PIPE, check=True).stdout
            records = modinfo(elf)
            name = next((r[5:] for r in records if r.startswith("name=")), m.name.rsplit("/", 1)[-1][:-len(".ko.zst")])
            modules += 1
            for r in records:
                if r.startswith("firmware="):
                    pairs.add((normalize(name), r[len("firmware="):]))
    unpack.wait()
    if unpack.returncode != 0:
        sys.exit("zstd failed")
    # the drivers built into the kernel: "module.firmware=FILE" records
    builtin = 0
    with open(builtin_modinfo, "rb") as f:
        for rec in f.read().split(b"\0"):
            r = rec.decode("utf-8", "replace")
            dot = r.find(".")
            if dot > 0 and r[dot + 1:].startswith("firmware="):
                pairs.add((normalize(r[:dot]), r[dot + 1 + len("firmware="):]))
                builtin += 1
    print("# kernel/pins/modules.firmware: MODULE FILE, one line per firmware file a module names")
    print(f"# (MODULE_FIRMWARE) in {pkg}: {modules} modules read, {builtin} built-in records;")
    print("# written by kernel/pins/mkfirmware.py, see kernel/pins/README.md. A FILE may hold a glob.")
    for mod, fw in sorted(pairs):
        print(f"{mod} {fw}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1], sys.argv[2]))
