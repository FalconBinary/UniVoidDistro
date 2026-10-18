#!/bin/sh
# Tests of the Zig tools (zig/) in a throwaway Void container of the native architecture.
#   sh tests/zig/run.sh                       -- unit tests, self-tests, kernel-struct checks, vh-deep-clean
#   VH_REF_BIN=DIR sh tests/zig/run.sh        -- plus the differential tests against another build
#                                                of the same tools in DIR (for example the previous release)
#
# Zig builds everything on the host (cross-compilation for Linux); the container only runs
# it: no emulation, the tests are quick even on a Mac with 8 GB.
#  1. unit tests of zig/lib and of the programs (zig build tests);
#  2. vh-seccomp self-test, the device-mapper constants (dm_check.c), vh-hashpw against libcrypt;
#  3. vh-deep-clean and vh-pkg on a real xbps (clean_test.sh);
#  4. with VH_REF_BIN: the *_diff scripts compare the two builds byte for byte (protocols,
#     outputs, exit codes). In the predecessor project the reference was the C version
#     (Void-Hardened-Refurs @ 39cf905); the scripts are implementation-agnostic.
set -eu
repo=$(cd "$(dirname "$0")/../.." && pwd)
img=$(sh "$repo/tests/docker/build.sh")
case $(uname -m) in arm64|aarch64) arch=aarch64 ;; *) arch=x86_64 ;; esac
out=$repo/build/zig-test       # inside the repository: macOS docker does not see temporary directories
rm -rf "$out"
mkdir -p "$out"
ref_mount=""
if [ -n "${VH_REF_BIN:-}" ]; then
	[ -x "$VH_REF_BIN/vh-seccomp" ] || { echo "VH_REF_BIN=$VH_REF_BIN has no vh-seccomp" >&2; exit 1; }
	ref_mount="-v $VH_REF_BIN:/ref:ro"
fi

echo "== building the programs and unit tests ($arch-linux)"
(cd "$repo/zig" && zig build install tests -Dtarget="$arch-linux" --prefix "$out")

# shellcheck disable=SC2086
docker run --rm --privileged -v "$repo:/src:ro" -v "$out:/t:ro" $ref_mount -e "FUZZ=${FUZZ:-200}" "$img" sh -c '
	set -e
	for t in /t/test/*; do printf "%s: " "$(basename "$t")"; "$t" 2>&1 | tail -1; done
	Z=/t/bin
	echo "== vh-seccomp"
	$Z/vh-seccomp --selftest | tail -1 | grep -q "selftest: OK" && echo "ok selftest" || { echo "FAIL selftest"; exit 1; }
	for k in browser viewer; do
		n=$($Z/vh-seccomp $k | wc -c)
		[ "$n" -gt 0 ] && [ $((n % 8)) = 0 ] && echo "ok filter $k: $n bytes" || { echo "FAIL filter $k: $n bytes"; exit 1; }
	done
	echo "== vh-deadman: kernel structures and the test mode"
	gcc -o /tmp/dm /src/tests/zig/dm_check.c && [ "$(/tmp/dm)" = "312 0xc138fd06 0xc138fd0e 3074" ] \
		&& echo "ok dm_ioctl: size, DM_DEV_SUSPEND, DM_TARGET_MSG, flags" || { echo "FAIL dm_ioctl: $(/tmp/dm)"; exit 1; }
	$Z/vh-deadman test >/dev/null 2>&1 || true
	echo "== pin-fetch, vh-hashpw (the system OpenSSL and libxcrypt: built here)"
	cp -R /src/zig /tmp/zs && (cd /tmp/zs && zig build -Dtarget=native -Dlibc-tools=true --prefix /tmp/zl >/dev/null)
	gcc -o /tmp/cc /src/tests/zig/crypt_check.c -lcrypt
	h=$(printf "password 1" | /tmp/zl/bin/vh-hashpw 5)
	case $h in "\$y\$"*) /tmp/cc "password 1" "$h" && echo "ok vh-hashpw: yescrypt, confirmed by libcrypt" || { echo "FAIL vh-hashpw: does not verify"; exit 1; } ;; *) echo "FAIL vh-hashpw: $h"; exit 1 ;; esac
	a=$(/tmp/zl/bin/pin-fetch 1.1.1.1 853 cloudflare-dns.com 2>/tmp/a2) && [ -n "$a" ] && echo "ok pin-fetch: PEM chain ($(cut -d: -f1-3 /tmp/a2 | head -c 60)...)" \
		|| echo "SKIP pin-fetch: no network ($(head -c 200 /tmp/a2))"
	if /tmp/zl/bin/pin-fetch 1.1.1.1 853 example.com >/dev/null 2>/tmp/a3; then echo "FAIL pin-fetch: a foreign name was accepted"; exit 1; else echo "ok pin-fetch: a foreign name is refused"; fi
	if [ -d /ref ]; then
		echo "== differential tests against /ref"
		for k in browser viewer; do
			[ "$($Z/vh-seccomp $k | sha256sum)" = "$(/ref/vh-seccomp $k | sha256sum)" ] \
				&& echo "ok filter $k is byte-identical" || { echo "DIFFERENCE in filter $k"; exit 1; }
		done
		python3 /src/tests/zig/wlfilter_diff.py /ref/vh-wlfilter $Z/vh-wlfilter --fuzz "$FUZZ" > /tmp/wl.log 2>&1 \
			|| { grep -v "^ok " /tmp/wl.log | tail -30; exit 1; }
		tail -1 /tmp/wl.log
		sh /src/tests/zig/limine_diff.sh /ref/vh-limine-update $Z/vh-limine-update
		python3 /src/tests/zig/uki_diff.py /ref/vh-uki-verify $Z/vh-uki-verify
		[ "$($Z/vh-deadman test 2>&1)" = "$(/ref/vh-deadman test 2>&1)" ] && echo "ok vh-deadman test matches" || { echo "DIFFERENCE in vh-deadman test"; exit 1; }
		sh /src/tests/zig/usb_diff.sh /ref/vh-usb-udev $Z/vh-usb-udev
		sh /src/tests/zig/open_diff.sh /ref/vh-open $Z/vh-open /ref/vh-seccomp
	fi
	echo "== vh-deep-clean, vh-pkg rm (last: removes packages, creates users)"
	sh /src/tests/zig/clean_test.sh $Z
'
