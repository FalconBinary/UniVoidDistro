#!/bin/sh
# vh-kconf install against Void's real dracut (kernel/README.md, "install": dracut --no-kernel
# --kver A.B.C-vh --kernel-image bzImage --uefi): vh-kconf is cross-built for Linux of the host's
# architecture, a throwaway container of the vh-dev image (tests/docker/build.sh) installs dracut,
# dracut-uefi, systemd-boot-efistub, binutils and cryptsetup from Void's mirror (network), and
# tests/kernel/dracut_test.py builds a machine UKI of a synthesised kernel with them and lists
# its initrd. On Apple Silicon the UKI is an aarch64 one (dracut takes linuxaa64.efi.stub when
# the configured x64 stub is missing, and there is no early microcode): the same code of dracut
# otherwise. The inputs are streamed in with tar, as in tests/kernel/run.sh.
#   sh tests/kernel/dracut_test.sh
set -eu
export COPYFILE_DISABLE=1
repo=$(cd "$(dirname "$0")/../.." && pwd)
case $(uname -m) in arm64|aarch64) arch=aarch64 ;; *) arch=x86_64 ;; esac
out=$repo/build/kd
rm -rf "$out"
echo "== building vh-kconf ($arch-linux)"
(cd "$repo/kernel" && zig build install -Dtarget="$arch-linux" -Dcpu=baseline --prefix "$out")
img=$(sh "$repo/tests/docker/build.sh")
echo "== dracut from Void's mirror, then vh-kconf install with it ($img)"
# macOS tar: the extended attributes stay out of the archive (GNU tar would only warn about them)
noxattrs=""
[ "$(uname)" = Darwin ] && noxattrs=--no-xattrs
# shellcheck disable=SC2086 # empty or one option
tar $noxattrs -C "$repo" -cf - kernel/hw/gf63.zon tests/adapt/golden/gf63/strict/plan.zon rootfs/etc/dracut.conf.d \
	rootfs/etc/modprobe.d tests/kernel/dracut_test.py build/kd |
	docker run --rm -i "$img" sh -c '
	set -e
	mkdir -p /src && cd /src && tar -xf -
	xbps-install -Sy dracut dracut-uefi systemd-boot-efistub binutils cryptsetup >/tmp/xbps.log 2>&1 || { tail -20 /tmp/xbps.log; exit 1; }
	python3 -I /src/tests/kernel/dracut_test.py /src
'
