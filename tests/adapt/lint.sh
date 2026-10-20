#!/bin/sh
# Hardware is detected, never assumed (docs/uni/principles.md, rule 1): no vendor or model
# name, no PCI or USB id of a vendor, no vendor-specific Kconfig symbol in the code, the
# installer, the system's files or the universal kernel profiles. Their place is hwdb/,
# kernel/profiles/class/, the fixtures and the pins. tests/adapt/lint.allow lists what is still
# there and why; any other hit fails.
#   sh tests/adapt/lint.sh
set -eu
repo=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo"
code="install rootfs kernel/src adapt/src init/src sched/src sched/bpf zig/tools zig/lib optional tools session/src session/profiles"
names='(0x|v0000)(8086|1002|1022|10de|10DE|10ec|10EC|14c3|14C3|14e4|14E4)\b|usb:v(8087|0BDA)|\b(8086|8087|1002|1022|10de|10ec|0bda|14c3|14e4|046d|27c6|06cb|0489|13d3):[0-9a-fA-F]{4}\b|GF63|MS-16R5|10500H|AX20[01]|AX21[01]|RTL81(11|68|25)|GTX ?1650|TU11[67]|Comet ?Lake|Alder ?Lake|Raptor ?Lake|Ryzen|Raphael|Navi ?3|Micro-Star|msi[-_]ec|BCM27|Snapdragon'
symbols='^(# )?CONFIG_(DRM_(I915|XE|AMDGPU|RADEON|NOUVEAU)|PINCTRL_[A-Z]*LAKE|PINCTRL_AMD|BT_(INTEL|RTL|MTK|BCM)\b|KVM_(INTEL|AMD)|ITCO_WDT|SP5100_TCO|CRYPTO_AES_NI_INTEL|X86_(INTEL|AMD)_PSTATE|SENSORS_(CORETEMP|K10TEMP|NCT6775)|PERF_EVENTS_(INTEL|AMD)_|INTEL_(IOMMU|IDLE|RAPL|MEI)|AMD_(IOMMU|3D_VCACHE))'
hits=$(mktemp)
trap 'rm -f "$hits"' EXIT
# shellcheck disable=SC2086 # the scope is a list of paths
git grep -n -P "$names" -- $code > "$hits" || true
git grep -n -P "$symbols" -- kernel/profiles ':!kernel/profiles/class' >> "$hits" || true
python3 -I - "$hits" tests/adapt/lint.allow <<'PY'
import re, sys
allow = []
for line in open(sys.argv[2]):
    if not line.strip() or line.startswith("#"):
        continue
    path, regex, reason = line.rstrip("\n").split("\t", 2)
    allow.append((path, re.compile(regex), reason))
bad = 0
for hit in open(sys.argv[1]):
    path, num, text = hit.rstrip("\n").split(":", 2)
    if any(p == path and r.search(text) for p, r, _ in allow):
        continue
    print(f"hardware constant outside hwdb/: {path}:{num}: {text.strip()[:120]}")
    bad += 1
print(f"lint: {bad} unexplained hardware constant(s)" if bad else "lint: every hardware constant is in hwdb/, a class fragment, a fixture, or explained in tests/adapt/lint.allow")
sys.exit(1 if bad else 0)
PY
