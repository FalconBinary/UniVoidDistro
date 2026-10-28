#!/bin/sh
# thor: build xbps with the void-hardperf-light patches and the Zig policy (docs/18).
#   ZIG=path/to/zig sh thor/build.sh XBPS_TARBALL BUILD_DIR DESTDIR
# XBPS_TARBALL is checked against thor/UPSTREAM. Needs the headers openssl-devel,
# libarchive-devel, zlib-devel, pkgconf, make, patch; gcc is not needed: the C code is
# built with "zig cc". The result is an install tree in DESTDIR (/usr, /etc).
set -eu
thor=$(cd "$(dirname "$0")" && pwd)
. "$thor/UPSTREAM"
tarball=${1:?"the xbps-$XBPS_VERSION.tar.gz archive"}
work=${2:?"build directory"}
dest=${3:?"DESTDIR"}
ZIG=${ZIG:?"path to zig (install/fetch-zig.sh)"}

echo "$XBPS_SHA256  $tarball" | sha256sum -c - >/dev/null || {
	echo "thor/build.sh: the checksum of $tarball does not match thor/UPSTREAM" >&2
	exit 1
}
rm -rf "$work"
mkdir -p "$work/bin" "$dest"
tar -xzf "$tarball" -C "$work"
src=$work/xbps-$XBPS_VERSION
for p in "$thor"/patches/*.patch; do
	patch -s -d "$src" -p1 < "$p"
done

# ar/ranlib from Zig (the live environment has no binutils)
printf '#!/bin/sh\nexec "%s" ar "$@"\n' "$ZIG" > "$work/bin/ar"
printf '#!/bin/sh\nexec "%s" ranlib "$@"\n' "$ZIG" > "$work/bin/ranlib"
chmod 0755 "$work/bin/ar" "$work/bin/ranlib"
PATH=$work/bin:$PATH
# the Zig cache goes into the build directory (the live environment's RAM), not $HOME and not next to the sources
ZIG_GLOBAL_CACHE_DIR=$work/zig-gcache ZIG_LOCAL_CACHE_DIR=$work/zig-cache
export PATH ZIG_GLOBAL_CACHE_DIR ZIG_LOCAL_CACHE_DIR

# Memory-safety hardening: the same set as for the tools (docs/17).
# -Wno-error: upstream builds with -Werror, and new glibc and clang warn about const
# (strchr in C23); those warnings are unrelated to security.
# Cross-build (the VM bench from a Mac): TARGET=x86_64-linux-gnu SYSROOT=DIR, with the
# headers and libraries of the target architecture from unpacked Void packages
# (tests/zig/build.sh). Without them: a build for this machine (the live environment).
TARGET=${TARGET:-}
SYSROOT=${SYSROOT:-}
tflag="" xcc=""
if [ -n "$TARGET" ]; then
	tflag="-target $TARGET"
	xcc="-idirafter $SYSROOT/usr/include -L$SYSROOT/usr/lib"
	export PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/pkgconfig" PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
fi
arch=${TARGET%%-*}
# the architecture's baseline CPU, never the build host's: the live image is built on GitHub's
# runners and runs on any machine of the architecture (an aarch64 thor built for the arm64
# runner's own cores died of SIGILL on an Apple M1, live-image run 40609186449); and the
# control-flow protection of each architecture: CET on x86_64, PAC and BTI on aarch64 (hint
# instructions, no-ops on a core without them)
cet=""
case ${arch:-$(uname -m)} in
	x86_64) cet="-fcf-protection=full -mcpu=baseline" ;;
	aarch64) cet="-mbranch-protection=standard -mcpu=baseline" ;;
esac
CFLAGS="-O2 -pipe -Wno-error -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=3 -fstack-protector-strong \
-fstack-clash-protection $cet -ftrivial-auto-var-init=zero"

echo "== policy (Zig) -> thor_policy.o"
"$ZIG" build-obj "$thor/policy/policy.zig" $tflag -OReleaseSafe -mcpu=baseline -fPIC -fno-omit-frame-pointer \
	-femit-bin="$src/lib/thor_policy.o"

echo "== xbps $XBPS_VERSION + patches (zig cc)"
(
	cd "$src"
	# libcrypto explicitly: lld, unlike ld.bfd, does not pull in the dependencies of libssl.
	# rpath $ORIGIN/../lib: the programs take libxbps (with the policy) from their own tree
	# rather than the live environment's stock /usr/lib/libxbps.so.6; in the system that is
	# the same /usr/lib.
	CC="$ZIG cc $tflag $xcc" CFLAGS="$CFLAGS" LDFLAGS="-lcrypto" \
		./configure --prefix=/usr --sysconfdir=/etc --enable-rpath > "$work/configure.log" 2>&1 \
		|| { tail -20 "$work/configure.log" >&2; exit 1; }
	make -j"$(nproc)" > "$work/make.log" 2>&1 || { grep -B2 -A8 -i 'error' "$work/make.log" | head -60 >&2; exit 1; }
	make DESTDIR="$dest" install > "$work/install.log" 2>&1
)
# not needed in the package: the static library, the headers, xbps-uchroot (the SUID
# helper of xbps-src; no packages are built here), xbps-uunshare, xbps-fbulk, xbps-dgraph
rm -f "$dest/usr/lib/libxbps.a" "$dest/usr/bin/xbps-uchroot" "$dest/usr/bin/xbps-uunshare" \
	"$dest/usr/bin/xbps-fbulk" "$dest/usr/bin/xbps-dgraph"
rm -rf "$dest/usr/include" "$dest/usr/lib/pkgconfig"

if [ -e "$thor/src/thor.zig" ]; then
	echo "== thor (Zig)"
	(
		cd "$thor"
		"$ZIG" build -Dcpu=baseline ${TARGET:+-Dtarget=$TARGET} ${SYSROOT:+--search-prefix $SYSROOT/usr} \
			-Dxbps-src="$src" --prefix "$dest/usr"
	)
fi
echo "== done: $dest"
