#!/bin/bash
# Builds the desktop (RefursWM + RefursLine from desktop/) in the live environment's RAM
# and installs the resulting binaries into the target root (docs/08, docs/09).
#   install/build-desktop.sh ROOT                      -- build for this CPU and install into ROOT
#   install/build-desktop.sh --prebuilt DIR ROOT       -- install an existing build (DIR/bin, DIR/share)
#   install/build-desktop.sh --out DIR CPU BLUETOOTH   -- build only, into DIR: for Zig's CPU model
#                                                         CPU (x86_64, x86_64_v3) and VH_BLUETOOTH
#                                                         BLUETOOTH (the live image, live/prebuilt.sh)
#
# Why: the installed system must not contain a compiler (docs/05). Zig 0.17 is downloaded
# into the live environment (install/fetch-zig.sh: minisign signature and checksum), the
# library headers are installed there too; everything lives in /tmp (RAM) and vanishes on
# reboot. The RefursWM and RefursLine sources live in this repository (desktop/, origin in
# desktop/UPSTREAM); wlroots, libinput and seatd are fetched by zig itself and checked
# against the hashes in desktop/refurswm/build.zig.zon. Both configs are compiled into the
# binaries: desktop/*/src/config.zig.

. "$(dirname "$0")/lib.sh"
need_root
ZIG_VERSION=$(cat "$VH_ROOT/zig/ZIG_VERSION")

# build OUT CPU BLUETOOTH: RefursWM and RefursLine into OUT/bin and OUT/share (OUT empty: into the
# work directory, which goes at exit); CPU empty is this machine's own CPU (Zig's default). Sets OUT.
build() {
	local cpu=$2 bt=$3 p cfg
	WORK=$(mktemp -d /tmp/vh-desktop.XXXXXX)
	trap 'rm -rf "$WORK"' EXIT
	OUT=${1:-$WORK/out}
	# wlroots/libinput/libseat headers and wayland-scanner: only in the live environment's RAM
	xbps-install -Sy pkg-config wayland-devel wayland-protocols libxkbcommon-devel pixman-devel \
		libdrm-devel libgbm-devel libglvnd-devel eudev-libudev-devel libdisplay-info-devel \
		libevdev-devel mtdev-devel hwids >/dev/null || die "could not install the headers into the live environment"
	# the same Zig and the same directory as build-tools.sh and build-thor.sh: one compiler for
	# everything (ZIG, when set, is one already checked: the vh-dev image of CI)
	[ -n "${ZIG:-}" ] || ZIG=$(bash "$VH_ROOT/install/fetch-zig.sh" "$ZIG_VERSION" /tmp/vh-zig)
	"$ZIG" version

	cp -a "$VH_ROOT/desktop/refurswm" "$VH_ROOT/desktop/refursline" "$WORK/"
	rm -rf "$WORK"/*/.zig-cache "$WORK"/*/zig-out "$WORK"/*/zig-pkg

	# Bluetooth on demand: the bar menu starts and stops the service itself through doas
	if [ "$bt" = optional ]; then
		cfg=$WORK/refursline/src/config.zig
		sed -i \
			-e 's|^pub const bt_service_on_cmd: ?\[\*:0\]const u8 = null;|pub const bt_service_on_cmd: ?[*:0]const u8 = "doas -n /usr/local/sbin/vh-bluetooth on";|' \
			-e 's|^pub const bt_service_off_cmd: ?\[\*:0\]const u8 = null;|pub const bt_service_off_cmd: ?[*:0]const u8 = "doas -n /usr/local/sbin/vh-bluetooth off";|' \
			"$cfg"
		[ "$(grep -c '^pub const bt_service_o[nf]*_cmd: .*"doas -n /usr/local/sbin/vh-bluetooth o[nf]*";$' "$cfg")" = 2 ] || die "RefursLine: could not set bt_service_on/off_cmd in config.zig"
	fi

	export ZIG_GLOBAL_CACHE_DIR=$WORK/gcache ZIG_LOCAL_PKG_DIR=$WORK/pkg
	for p in refurswm refursline; do
		say "$p: building (ReleaseSafe${cpu:+, CPU $cpu})"
		( cd "$WORK/$p" && "$ZIG" build -Doptimize=ReleaseSafe ${cpu:+-Dcpu=$cpu} --cache-dir "$WORK/cache-$p" --prefix "$OUT" ) \
			|| die "$p: build failed"
	done
	for p in refurswm refursline; do [ -x "$OUT/bin/$p" ] || die "no $OUT/bin/$p"; done
	[ -d "$OUT/share/refurswm/libinput" ] || die "no $OUT/share/refurswm/libinput (libinput quirks)"
}

case ${1:-} in
--out)
	dir=${2:?"build directory"} CPU=${3:?"Zig's CPU model, for example x86_64_v3"} BT=${4:?"VH_BLUETOOTH: off, optional or on"}
	case $BT in off|optional|on) ;; *) die "VH_BLUETOOTH: off, optional or on" ;; esac
	build "$dir" "$CPU" "$BT"
	ok "RefursWM and RefursLine for $CPU, VH_BLUETOOTH=$BT: $OUT"
	exit 0
	;;
--prebuilt)
	load_config "${VH_CONFIG:-$VH_ROOT/vh.conf}"
	OUT=${2:?"build directory"} TARGET=${3:?"system root"}
	for b in refurswm refursline; do [ -x "$OUT/bin/$b" ] || die "no $OUT/bin/$b"; done
	[ -d "$OUT/share/refurswm/libinput" ] || die "no $OUT/share/refurswm/libinput (libinput quirks)"
	origin="prebuilt $OUT"
	;;
*)
	load_config "${VH_CONFIG:-$VH_ROOT/vh.conf}"
	TARGET=${1:?"target root, for example /mnt"}
	build "" "" "$VH_BLUETOOTH"
	origin="desktop/ $(git -C "$VH_ROOT" rev-parse --short HEAD 2>/dev/null || echo "(not git)")"
	;;
esac

say "installing into $TARGET/usr/local"
install -d -m 0755 "$TARGET/usr/local/bin" "$TARGET/usr/local/share/refurswm" "$TARGET/etc/vh"
for b in refurswm refursline; do
	install -m 0755 -o root -g root "$OUT/bin/$b" "$TARGET/usr/local/bin/"
done
rm -rf "$TARGET/usr/local/share/refurswm/libinput"
cp -R "$OUT/share/refurswm/libinput" "$TARGET/usr/local/share/refurswm/"
chown -R root:root "$TARGET/usr/local/share/refurswm"
chmod -R u=rwX,go=rX "$TARGET/usr/local/share/refurswm"
{
	echo "# RefursWM + RefursLine: $origin, zig $ZIG_VERSION, installed $(date -u +%Y-%m-%dT%H:%MZ)"
	( cd "$TARGET/usr/local/bin" && sha256sum refurswm refursline )
} > "$TARGET/etc/vh/desktop.sha256"
ok "refurswm $(stat -c %s "$TARGET/usr/local/bin/refurswm") B, refursline $(stat -c %s "$TARGET/usr/local/bin/refursline") B"
