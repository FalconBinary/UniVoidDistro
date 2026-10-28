#!/bin/sh
# Build for the VM bench (glibc Void; x86_64, or aarch64 with VH_ARCH=aarch64: U5) into build/,
# with no compiler on the host except Zig.
#   sh tests/zig/build.sh   -> build/ (the tools, vh-kconf) and build/thor-repo (the thor package);
#                              then python3 tests/vm/check.py STEP --repo
#  * the static tools are cross-compiled by Zig right on the host;
#  * pin-fetch, vh-hashpw (OpenSSL, libxcrypt) and thor (libxbps, libarchive) are
#    cross-built in a Void container of the native architecture with an x86_64 sysroot.
set -eu
repo=$(cd "$(dirname "$0")/../.." && pwd)
b=$repo/build
# the VM's architecture (tests/vm/vhvm.py VH_ARCH): the static tools cross-compiled for it
VH_ARCH=${VH_ARCH:-x86_64}
case $VH_ARCH in x86_64|aarch64) ;; *) echo "VH_ARCH: x86_64 or aarch64" >&2; exit 1 ;; esac
. "$repo/thor/UPSTREAM"
mkdir -p "$b/xbps-dl"
[ -f "$b/xbps-dl/xbps-$XBPS_VERSION.tar.gz" ] || curl -fsSL -o "$b/xbps-dl/xbps-$XBPS_VERSION.tar.gz" "$XBPS_URL"

echo "== static tools ($VH_ARCH-linux, cross-compiled)"
rm -rf "$b/zx"
(cd "$repo/zig" && zig build -Dtarget="$VH_ARCH-linux" -Dcpu=baseline --prefix "$b/zx")
cp "$b"/zx/bin/* "$b/"
# vh-kconf of the working copy: the machine step installs a kernel-custom run's kernel with it
rm -rf "$b/kx"
(cd "$repo/kernel" && zig build -Dtarget="$VH_ARCH-linux" -Dcpu=baseline --prefix "$b/kx")
cp "$b/kx/bin/vh-kconf" "$b/"
# the gaming session (session/), PID 1 (init/) and the scheduler (sched/: the loader and the
# BPF object): build-tools.sh --prebuilt installs them with the tools
rm -rf "$b/sx" "$b/ix" "$b/scx"
(cd "$repo/session" && zig build -Dtarget="$VH_ARCH-linux" -Dcpu=baseline --prefix "$b/sx")
cp "$b"/sx/bin/* "$b/"
(cd "$repo/init" && zig build -Dtarget="$VH_ARCH-linux" -Dcpu=baseline --prefix "$b/ix")
cp "$b"/ix/bin/* "$b/"
(cd "$repo/sched" && zig build -Dtarget="$VH_ARCH-linux" -Dcpu=baseline --prefix "$b/scx")
cp "$b/scx/bin/vh-sched" "$b/scx/bpf/vh_sched.o" "$b/"

# pin-fetch, vh-hashpw and thor are cross-compiled in a native container: Zig under amd64
# emulation in docker on Apple Silicon crashes (SIGSEGV), while cross-building is its strength.
# The target's headers and libraries come from Void packages unpacked without scripts (a
# sysroot of VH_ARCH: the x86_64 repository, or current/aarch64).
img=$(sh "$repo/tests/docker/build.sh")
echo "== pin-fetch, vh-hashpw, thor ($VH_ARCH cross-build, sysroot from Void packages)"
rm -rf "$b/thor-repo"
case $VH_ARCH in x86_64) sub="" ;; aarch64) sub=/aarch64 ;; esac
docker run --rm -v "$repo:/src:ro" -v "$b:/out" "$img" sh -c "
	set -e
	mkdir -p /sx/var/db/xbps/keys && cp -a /var/db/xbps/keys/. /sx/var/db/xbps/keys/
	XBPS_ARCH=$VH_ARCH xbps-install -SyU -r /sx -R ${VH_MIRROR:-https://repo-default.voidlinux.org}/current$sub \
		glibc-devel openssl-devel libarchive-devel zlib-devel libxcrypt-devel >/dev/null
	cp -R /src/zig /tmp/zs && cd /tmp/zs && zig build -Dtarget=$VH_ARCH-linux-gnu.2.41 -Dcpu=baseline -Dlibc-tools=true \
		--search-prefix /sx/usr --prefix /tmp/zl >/dev/null
	cp /tmp/zl/bin/pin-fetch /tmp/zl/bin/vh-hashpw /out/
	TARGET=$VH_ARCH-linux-gnu.2.41 SYSROOT=/sx sh /src/thor/build.sh /out/xbps-dl/xbps-$XBPS_VERSION.tar.gz /tmp/w /tmp/thor-dest >/dev/null
	XBPS_BIN=/usr/bin sh /src/thor/package.sh /tmp/thor-dest $VH_ARCH /out/thor-repo"
ls "$b/thor-repo"
