#!/bin/sh
# The GF63 oracle (docs/uni/principles.md, rule 9): vh-kconf resolve on kernel/hw/gf63.zon must
# give the LSMOD list, the merged fragment and the .config that void-hardperf-light gives for
# its laptop. tests/kernel/golden/gf63 holds them, written by upstream's resolve and profiles
# (before the profiles were split into classes); a difference fails, and is either a bug or a
# change that is explained in the commit and accepted with --update.
#   sh tests/kernel/oracle.sh            # compare
#   sh tests/kernel/oracle.sh --update   # rewrite the golden files
# Like run.sh, the binary runs in a throwaway container and the inputs are streamed in with tar.
set -eu
repo=$(cd "$(dirname "$0")/../.." && pwd)
case $(uname -m) in arm64|aarch64) arch=aarch64 ;; *) arch=x86_64 ;; esac
out=$repo/build/ko
rm -rf "$out"
(cd "$repo/kernel" && zig build install -Dtarget="$arch-linux" -Dcpu=baseline --prefix "$out")
golden=$repo/tests/kernel/golden/gf63
features=${VH_ORACLE_FEATURES:-usb-common,bluetooth}
plan_arg=""
[ -f "$repo/tests/adapt/golden/gf63/plan.zon" ] && plan_arg="--plan /src/tests/adapt/golden/gf63/plan.zon"
tar -C "$repo" -cf - kernel/pins kernel/profiles kernel/hw tests/adapt build/ko 2>/dev/null |
	docker run --rm -i alpine:3.20 sh -c "
	set -e
	mkdir -p /src && cd /src && tar -xf -
	/src/build/ko/bin/vh-kconf resolve --hw /src/kernel/hw/gf63.zon --repo /src --features $features $plan_arg --out /tmp/r >/dev/null
	cd /tmp/r && tar -cf - lsmod fragment.config .config
" > "$out/result.tar"
mkdir -p "$out/result"
tar -C "$out/result" -xf "$out/result.tar"
# the fragment's "# from:" lines name the file a symbol came from: after the split the same
# symbol may come from a class fragment, so only the symbols and values are compared
strip_from() { grep -v '^# from: ' "$1" | grep -v '^# merged by' | sort; }
if [ "${1:-}" = --update ]; then
	mkdir -p "$golden"
	cp "$out/result/lsmod" "$golden/"
	sort "$out/result/.config" > "$golden/config.sorted"
	strip_from "$out/result/fragment.config" > "$golden/fragment.symbols"
	echo "golden files rewritten: $golden"
	exit 0
fi
rc=0
cmp -s "$golden/lsmod" "$out/result/lsmod" || { echo "LSMOD differs:"; diff "$golden/lsmod" "$out/result/lsmod" || true; rc=1; }
strip_from "$out/result/fragment.config" > "$out/result/fragment.symbols"
cmp -s "$golden/fragment.symbols" "$out/result/fragment.symbols" || { echo "fragment differs:"; diff "$golden/fragment.symbols" "$out/result/fragment.symbols" || true; rc=1; }
# the order of .config lines follows the order of the fragments; the kernel reads the values
sort "$out/result/.config" > "$out/result/config.sorted"
cmp -s "$golden/config.sorted" "$out/result/config.sorted" || { echo ".config differs:"; diff "$golden/config.sorted" "$out/result/config.sorted" | head -60 || true; rc=1; }
[ "$rc" = 0 ] && echo "the GF63 oracle holds: lsmod, fragment symbols and .config are those of void-hardperf-light"
exit "$rc"
