#!/bin/bash
# void-hardperf-light: the system tools written in Zig (zig/): build and install (docs/05, docs/17).
#   install/build-tools.sh ROOT                   -- build in the live environment's RAM, install into ROOT
#   install/build-tools.sh --prebuilt DIR ROOT    -- install an existing build (VM bench, tests/zig/build.sh)
#   install/build-tools.sh --out DIR              -- build only, into DIR (the installer, which packages
#                                                    the build: pkg/build.sh, docs/uni/rolling.md)
#
# The installed system has neither a compiler nor interpreters such as python3, on purpose
# (docs/05): Zig is downloaded into the live environment (install/fetch-zig.sh, minisign
# signature), lives in RAM and vanishes on reboot. gcc is not needed. To update the
# programs after a git pull: boot from the USB stick, unlock and mount the root at /mnt and
# run this script again; the copies already installed by optional/ modules are replaced too.
set -euo pipefail
VH_ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$VH_ROOT/install/lib.sh"

# package, program, place in the system [, the copy installed by an enabled optional/ module]:
# pkg/tools.map, which pkg/build.sh packages by (docs/uni/rolling.md)
mapfile -t MAP < <(grep -v '^[[:space:]]*\(#\|$\)' "$VH_ROOT/pkg/tools.map")

need_root
OUT=
if [ "${1:-}" = --prebuilt ]; then
	BUILD=${2:?"directory with the programs"} ROOT=${3:?"system root"}
else
	if [ "${1:-}" = --out ]; then
		OUT=${2:?"build directory"}
	else
		ROOT=${1:?"system root, for example /mnt"}
	fi
	BUILD=$(mktemp -d /tmp/vh-build.XXXXXX)
	trap 'rm -rf "$BUILD"' EXIT
	# headers for pin-fetch (OpenSSL) and vh-hashpw (libxcrypt): into the live environment's RAM
	xbps-install -Sy openssl-devel libxcrypt-devel >/dev/null || die "could not install the headers into the live environment"
	ZIG=$(bash "$VH_ROOT/install/fetch-zig.sh" "$(cat "$VH_ROOT/zig/ZIG_VERSION")" /tmp/vh-zig)
	say "building the Zig tools (zig/, ReleaseSafe)"
	cp -R "$VH_ROOT/zig" "$BUILD/src"
	( cd "$BUILD/src" && ZIG_GLOBAL_CACHE_DIR=$BUILD/gcache ZIG_LOCAL_CACHE_DIR=$BUILD/cache \
		"$ZIG" build -Dtarget=native -Dcpu=baseline -Dlibc-tools=true --prefix "$BUILD/out" )
	# session/, init/, sched/, kernel/ and adapt/ read ../zig/lib in place: the same layout; sched/
	# also builds the BPF programs (bpfel-freestanding) with the same Zig
	mkdir -p "$BUILD/s" && cp -R "$VH_ROOT/zig" "$VH_ROOT/session" "$VH_ROOT/init" "$VH_ROOT/sched" "$VH_ROOT/kernel" "$VH_ROOT/adapt" "$BUILD/s/"
	for c in session init sched kernel adapt; do
		( cd "$BUILD/s/$c" && ZIG_GLOBAL_CACHE_DIR=$BUILD/gcache ZIG_LOCAL_CACHE_DIR=$BUILD/cache \
			"$ZIG" build -Dtarget=native -Dcpu=baseline --prefix "$BUILD/out" )
	done
	mv "$BUILD/out/bin"/* "$BUILD/out/bpf/vh_sched.o" "$BUILD/"
	"$BUILD/vh-seccomp" --selftest >/dev/null || die "vh-seccomp --selftest failed"
	if [ -n "$OUT" ]; then
		mkdir -p "$OUT"
		for line in "${MAP[@]}"; do
			read -r _ name _ <<< "$line"
			[ -f "$BUILD/$name" ] || die "no built program $name"
			install -m 0755 "$BUILD/$name" "$OUT/$name"
		done
		install -m 0644 "$BUILD/vh_sched.o" "$OUT/vh_sched.o"
		ok "the Zig tools built: $OUT"
		exit 0
	fi
fi
[ -d "$ROOT/usr/local" ] || die "$ROOT is not a system root"

say "installing into $ROOT"
for line in "${MAP[@]}"; do
	read -r _ name dst copy <<< "$line"
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
# the scheduler's BPF object (sched/bpf/vh_sched.zig): data, not a program; vh-sched run loads it
[ -f "$BUILD/vh_sched.o" ] || die "no built vh_sched.o"
install -D -m 0644 -o root -g root "$BUILD/vh_sched.o" "$ROOT/usr/local/lib/vh/vh_sched.o"
ok "vh_sched.o -> /usr/local/lib/vh/vh_sched.o"
