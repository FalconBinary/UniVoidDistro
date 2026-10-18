#!/bin/bash
# void-hardperf-light: the system tools written in Zig (zig/): build and install (docs/05, docs/17).
#   install/build-tools.sh ROOT                   -- build in the live environment's RAM, install into ROOT
#   install/build-tools.sh --prebuilt DIR ROOT    -- install an existing build (VM bench, tests/zig/build.sh)
#
# The installed system has neither a compiler nor interpreters such as python3, on purpose
# (docs/05): Zig is downloaded into the live environment (install/fetch-zig.sh, minisign
# signature), lives in RAM and vanishes on reboot. gcc is not needed. To update the
# programs after a git pull: boot from the USB stick, unlock and mount the root at /mnt and
# run this script again; the copies already installed by optional/ modules are replaced too.
set -euo pipefail
VH_ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$VH_ROOT/install/lib.sh"

# program -> place in the system [-> the copy installed by an enabled optional/ module]
MAP=(
	"vh-seccomp       /usr/local/libexec/vh/vh-seccomp"
	"vh-wlfilter      /usr/local/bin/vh-wlfilter"
	"vh-acpid         /usr/local/sbin/vh-acpid"
	"vh-limine-update /usr/local/sbin/vh-limine-update"
	"vh-pkg           /usr/local/sbin/vh-pkg"
	"vh-deep-clean    /usr/local/sbin/vh-deep-clean"
	"vh-hashpw        /root/vh/tools/vh-hashpw"
	"vh-deadman       /root/vh/optional/deadman/vh-deadman             /usr/local/sbin/vh-deadman"
	"vh-uki-verify    /root/vh/optional/sb-offline-keys/vh-uki-verify  /usr/local/sbin/vh-uki-verify"
	"vh-open          /root/vh/optional/viewers/vh-open                /usr/local/bin/vh-open"
	"vh-usb-udev      /root/vh/optional/usb-auth/vh-usb-udev           /usr/local/libexec/vh/vh-usb-udev"
	"pin-fetch        /root/vh/optional/dns-pin/pin-fetch              /usr/local/libexec/vh/pin-fetch"
)

need_root
if [ "${1:-}" = --prebuilt ]; then
	BUILD=${2:?"directory with the programs"} ROOT=${3:?"system root"}
else
	ROOT=${1:?"system root, for example /mnt"}
	BUILD=$(mktemp -d /tmp/vh-build.XXXXXX)
	trap 'rm -rf "$BUILD"' EXIT
	# headers for pin-fetch (OpenSSL) and vh-hashpw (libxcrypt): into the live environment's RAM
	xbps-install -Sy openssl-devel libxcrypt-devel >/dev/null || die "could not install the headers into the live environment"
	ZIG=$(bash "$VH_ROOT/install/fetch-zig.sh" "$(cat "$VH_ROOT/zig/ZIG_VERSION")" /tmp/vh-zig)
	say "building the Zig tools (zig/, ReleaseSafe)"
	cp -R "$VH_ROOT/zig" "$BUILD/src"
	( cd "$BUILD/src" && ZIG_GLOBAL_CACHE_DIR=$BUILD/gcache ZIG_LOCAL_CACHE_DIR=$BUILD/cache \
		"$ZIG" build -Dtarget=native -Dcpu=baseline -Dlibc-tools=true --prefix "$BUILD/out" )
	mv "$BUILD/out/bin"/* "$BUILD/"
	"$BUILD/vh-seccomp" --selftest >/dev/null || die "vh-seccomp --selftest failed"
fi
[ -d "$ROOT/usr/local" ] || die "$ROOT is not a system root"

say "installing into $ROOT"
for line in "${MAP[@]}"; do
	read -r name dst copy <<< "$line"
	# -f rather than -x: the build directory may be on a noexec mount (/tmp of the installed system)
	[ -f "$BUILD/$name" ] || die "no built program $name"
	install -D -m 0755 -o root -g root "$BUILD/$name" "$ROOT$dst"
	# the module is already enabled: its copy is replaced as well
	if [ -n "${copy:-}" ] && [ -e "$ROOT$copy" ]; then
		install -m 0755 -o root -g root "$BUILD/$name" "$ROOT$copy"
		ok "$name -> $dst, $copy"
	else
		ok "$name -> $dst"
	fi
done
