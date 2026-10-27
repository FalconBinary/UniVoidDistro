#!/bin/sh
# The programs of the live image, built (docs/uni/live-image.md), into OUT:
#   OUT/bin                       vh-kconf, vh-plan, the Zig tools, the gaming session's programs,
#                                 vh-stage1, vh-init, vh-ctl, vh-sched and its BPF object vh_sched.o
#                                 (install/build-tools.sh's list)
#   OUT/thor/{dest,repo}          thor and its package (install/build-thor.sh --out)
#   OUT/desktop/x86-64-LEVEL-BT   RefursWM and RefursLine for x86-64-v1 and -v3, without and with
#                                 the bar's Bluetooth menu (install/build-desktop.sh --out)
#   OUT/selinux                   the SELinux policy and its file contexts (selinux/build.sh, secilc
#                                 in a Fedora container)
#   OUT/BUILD, OUT/SHA256SUMS     the commit and the run; every file's sha256
#   sh live/prebuilt.sh OUT       (x86_64 Linux with docker and zig: the live-image workflow)
# The static programs are built by zig on the host (-Dcpu=baseline, as the installer builds them);
# those linked with the C library (pin-fetch, vh-hashpw, thor, the desktop) in the vh-dev image
# (tests/docker/build.sh): Void, the Zig of zig/ZIG_VERSION.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
out=${1:?"output directory"}
[ "$(uname -m)" = x86_64 ] || { echo "live/prebuilt.sh: the desktop is built natively, on an x86_64 host" >&2; exit 2; }
rm -rf "$out"
mkdir -p "$out/bin"

echo "== static programs (x86_64, baseline)"
for c in zig kernel adapt session init sched; do
	(cd "$repo/$c" && zig build -Dtarget=x86_64-linux -Dcpu=baseline --prefix "$out/.z-$c")
done
cp "$out"/.z-zig/bin/* "$out"/.z-session/bin/* "$out"/.z-init/bin/* "$out"/.z-sched/bin/* "$out/.z-sched/bpf/vh_sched.o" "$out/bin/"
cp "$out/.z-kernel/bin/vh-kconf" "$out/.z-adapt/bin/vh-plan" "$out/bin/"
rm -rf "$out"/.z-*

img=$(sh "$repo/tests/docker/build.sh" x86_64)
echo "== pin-fetch, vh-hashpw, thor and the desktop ($img)"
docker run --rm -v "$repo:/src:ro" -v "$out:/out" "$img" bash -c '
	set -euo pipefail
	cp -R /src/zig /tmp/zs
	( cd /tmp/zs && zig build -Dtarget=native -Dcpu=baseline -Dlibc-tools=true --prefix /tmp/zl >/dev/null )
	cp /tmp/zl/bin/pin-fetch /tmp/zl/bin/vh-hashpw /out/bin/
	bash /src/install/build-thor.sh --out /out/thor
	for lvl in v1 v3; do
		cpu=x86_64; [ "$lvl" = v1 ] || cpu=x86_64_$lvl
		bash /src/install/build-desktop.sh --out /out/desktop/x86-64-$lvl-plain "$cpu" off
		bash /src/install/build-desktop.sh --out /out/desktop/x86-64-$lvl-btmenu "$cpu" optional
		# the Bluetooth menu is compiled in (the bar starts vh-bluetooth itself) in btmenu only
		grep -q -a /usr/local/sbin/vh-bluetooth /out/desktop/x86-64-$lvl-btmenu/bin/refursline \
			|| { echo "x86-64-$lvl-btmenu: RefursLine without the Bluetooth menu" >&2; exit 1; }
		! grep -q -a /usr/local/sbin/vh-bluetooth /out/desktop/x86-64-$lvl-plain/bin/refursline \
			|| { echo "x86-64-$lvl-plain: RefursLine with the Bluetooth menu" >&2; exit 1; }
	done
	chown -R '"$(id -u):$(id -g)"' /out'

echo "== the SELinux policy (selinux/build.sh)"
sh "$repo/selinux/build.sh" "$out/selinux"

{
	echo "COMMIT=$(git -C "$repo" rev-parse HEAD)"
	echo "RUN=${GITHUB_RUN_ID:-local}"
	echo "ZIG=$(cat "$repo/zig/ZIG_VERSION")"
	echo "BUILT=$(date -u +%Y-%m-%dT%H:%MZ)"
} > "$out/BUILD"
( cd "$out" && find . -type f ! -name SHA256SUMS | sed 's|^\./||' | LC_ALL=C sort | xargs sha256sum > SHA256SUMS )
echo "== $(wc -l < "$out/SHA256SUMS") files, $(du -sh "$out" | cut -f1)"
cat "$out/BUILD"
