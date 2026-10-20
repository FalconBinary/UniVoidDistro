#!/bin/bash
# void-hardperf-light: thor, the xbps-based package manager (docs/18): build in the live
# environment's RAM, the thor package and a local repository in the target system.
#   install/build-thor.sh ROOT                  -- build here and install into ROOT
#   install/build-thor.sh --prebuilt DIR ROOT   -- install an existing build (DIR/dest, DIR/repo):
#                                                  our live image's (docs/uni/live-image.md)
#   install/build-thor.sh --out DIR             -- build only, into DIR/dest and DIR/repo (live/prebuilt.sh)
# Result:
#   ROOT/var/lib/thor/repo       -- repository holding the thor package (replaces xbps and libxbps);
#   ROOT/etc/xbps.d/01-thor.conf -- that repository in the xbps list;
#   /tmp/vh-thor/dest/usr/bin    -- thor and xbps-* for installing the system from the live
#                                   environment (10-install.sh installs through them, policy included).
# In the live environment /var/lib/thor/repo is a symlink to ROOT/var/lib/thor/repo: the
# path in 01-thor.conf is the same during installation and in the installed system.
#
# Updating thor (a new upstream xbps or a new patch revision): boot from the USB stick,
# unlock and mount the root at /mnt and run this script again, then in the system run
# doas xbps-install -Su thor. The local repository needs no signature: xbps checks the
# package against the sha256 in the index, and only root can write to /var/lib/thor.
set -euo pipefail
VH_ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$VH_ROOT/install/lib.sh"
. "$VH_ROOT/thor/UPSTREAM"
need_root
ARCH=$(xbps-uhelper arch)    # x86_64 on the laptop; anything else only in tests (tests/thor/live_test.sh)
WORK=/tmp/vh-thor            # the live environment's tmpfs
ZIG_VERSION=$(cat "$VH_ROOT/zig/ZIG_VERSION")
PKGVER=thor-$XBPS_VERSION.${THOR_REVISION}_1

# build DEST REPO: thor's install tree, and the repository with its package
build() {
	local dest=$1 repo=$2 tarball
	say "thor: headers and build tools into the live environment's RAM (no gcc needed)"
	xbps-install -Sy openssl-devel libarchive-devel zlib-devel pkgconf make patch >/dev/null \
		|| die "could not install the headers into the live environment"
	# the same directory as build-tools.sh: Zig is downloaded once (ZIG, when set, is one
	# already checked: the vh-dev image of CI)
	[ -n "${ZIG:-}" ] || ZIG=$(bash "$VH_ROOT/install/fetch-zig.sh" "$ZIG_VERSION" /tmp/vh-zig)
	export ZIG

	say "xbps $XBPS_VERSION: sources (checked against thor/UPSTREAM)"
	mkdir -p "$WORK"
	tarball=$WORK/xbps-$XBPS_VERSION.tar.gz
	[ -f "$tarball" ] || xbps-fetch -o "$tarball" "$XBPS_URL"
	echo "$XBPS_SHA256  $tarball" | sha256sum -c - >/dev/null || die "the xbps checksum does not match thor/UPSTREAM"
	ok "sha256 matches (the same archive as in the Void template)"

	say "building thor: xbps + patches + policy (Zig)"
	rm -rf "$dest"
	sh "$VH_ROOT/thor/build.sh" "$tarball" "$WORK/build" "$dest"
	"$dest/usr/bin/thor" --version >/dev/null || die "the built thor does not run"

	say "package $PKGVER"
	install -d -m 0755 "$repo"
	sh "$VH_ROOT/thor/package.sh" "$dest" "$ARCH" "$repo" >/dev/null
	ok "$repo/$PKGVER.$ARCH.xbps"
}

case ${1:-} in
--out)
	dir=${2:?"build directory"}
	build "$dir/dest" "$dir/repo"
	ok "thor built: $dir/dest, $dir/repo"
	exit 0
	;;
--prebuilt)
	dir=${2:?"build directory (DIR/dest, DIR/repo)"} ROOT=${3:?"system root, for example /mnt"}
	[ -x "$dir/dest/usr/bin/thor" ] && [ -f "$dir/repo/$PKGVER.$ARCH.xbps" ] \
		|| die "$dir: no $PKGVER.$ARCH build (dest/usr/bin/thor, repo/$PKGVER.$ARCH.xbps)"
	say "thor: $PKGVER as the live image brings it ($dir)"
	mkdir -p "$WORK"
	rm -rf "$WORK/dest"
	cp -a "$dir/dest" "$WORK/dest"
	"$WORK/dest/usr/bin/thor" --version >/dev/null || die "the prebuilt thor does not run"
	install -d -m 0755 "$ROOT/var/lib/thor/repo"
	cp -a "$dir/repo/." "$ROOT/var/lib/thor/repo/"
	ok "$ROOT/var/lib/thor/repo/$PKGVER.$ARCH.xbps"
	;;
*)
	ROOT=${1:?"system root, for example /mnt"}
	build "$WORK/dest" "$ROOT/var/lib/thor/repo"
	;;
esac
dest=$WORK/dest
repo=$ROOT/var/lib/thor/repo

install -d -m 0755 "$ROOT/etc/xbps.d" "$ROOT/etc/thor"
cat > "$ROOT/etc/xbps.d/01-thor.conf" <<'EOF'
# thor (docs/18): local repository with the thor package, which replaces xbps.
repository=/var/lib/thor/repo
EOF
# the path from 01-thor.conf also works in the live environment (ROOT is installed from here)
if [ "$ROOT" != / ]; then
	install -d /var/lib/thor
	ln -sfn "$repo" /var/lib/thor/repo
fi
ok "thor ready: $dest/usr/bin"
