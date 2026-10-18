#!/bin/sh
# thor: the package from the build tree (thor/build.sh) and the local repository index (docs/18).
#   sh thor/package.sh DESTDIR ARCH REPO_DIR
# The package replaces xbps and libxbps (replaces) and provides them (provides): other
# packages' dependencies on xbps stay satisfied. xbps-create and xbps-rindex come from
# DESTDIR itself.
set -eu
thor=$(cd "$(dirname "$0")" && pwd)
. "$thor/UPSTREAM"
dest=${1:?DESTDIR}
arch=${2:?"architecture, for example x86_64"}
repo=${3:?"repository directory"}
pkgver=thor-$XBPS_VERSION.${THOR_REVISION}_1
# xbps-create and xbps-rindex from DESTDIR; in a cross-build, the build machine's programs
X=${XBPS_BIN:-$dest/usr/bin}
[ -n "${XBPS_BIN:-}" ] || export LD_LIBRARY_PATH="$dest/usr/lib"

# files the Void xbps package adds on top of upstream
install -d "$dest/usr/share/xbps.d"
echo "architecture=$arch" > "$dest/usr/share/xbps.d/xbps-arch.conf"
# the main repository for the architecture (as in the Void template; upstream writes only /current)
case $arch in
	x86_64) sub="" ;;
	*-musl) sub="/musl" ;;
	*) sub="/$arch" ;;
esac
echo "repository=https://repo-default.voidlinux.org/current$sub" > "$dest/usr/share/xbps.d/00-repository-main.conf"
: > "$dest/usr/share/xbps.d/void-virtualpkgs.conf"

mkdir -p "$repo"
repo=$(cd "$repo" && pwd)
rm -f "$repo"/thor-*.xbps "$repo"/*-repodata
cd "$repo"
"$X/xbps-create" -q -A "$arch" -n "$pkgver" \
	-s "xbps + the void-hardperf-light security policy, parallel downloads" \
	-H "https://github.com/FalconBinary/void-hardperf-light" \
	-l "BSD-2-Clause, GPL-3.0-or-later" -m "void-hardperf-light" \
	-D "ca-certificates>=0 xbps-triggers>=0 glibc>=2.41_1 libarchive>=3.5.1_2 libcrypto3>=3.0_1 libssl3>=3.0_1 zlib>=1.2.3_1" \
	-P "xbps-${XBPS_VERSION}_1 libxbps-${XBPS_VERSION}_1" \
	-R "xbps>=0 libxbps>=0" \
	--shlib-provides "libxbps.so.6" \
	--shlib-requires "libarchive.so.13 libcrypto.so.3 libssl.so.3 libz.so.1 libc.so.6" \
	"$dest"
XBPS_TARGET_ARCH=$arch "$X/xbps-rindex" -a "$repo/$pkgver.$arch.xbps" >/dev/null
echo "$repo/$pkgver.$arch.xbps"
