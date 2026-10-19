#!/bin/sh
# The GF63 oracle (docs/uni/principles.md, rule 9): vh-kconf resolve on kernel/hw/gf63.zon must
# give the LSMOD list, the merged fragment and the .config that void-hardperf-light gives for
# its laptop. tests/kernel/golden/gf63 holds them, written by upstream's resolve and profiles
# (before the profiles were split into classes); golden/gf63/differences lists the differences
# accepted since, each with its reason. Any other difference fails.
#   sh tests/kernel/oracle.sh            # compare
#   sh tests/kernel/oracle.sh --update   # rewrite the golden files (only from upstream's code)
# Like run.sh, the binary runs in a throwaway container and the inputs are streamed in with tar.
set -eu
# macOS tar: no AppleDouble ("._name") files for the extended attributes
export COPYFILE_DISABLE=1
repo=$(cd "$(dirname "$0")/../.." && pwd)
case $(uname -m) in arm64|aarch64) arch=aarch64 ;; *) arch=x86_64 ;; esac
out=$repo/build/ko
rm -rf "$out"
(cd "$repo/kernel" && zig build install -Dtarget="$arch-linux" -Dcpu=baseline --prefix "$out")
golden=$repo/tests/kernel/golden/gf63
features=${VH_ORACLE_FEATURES:-usb-common,bluetooth}
plan_arg=""
[ -f "$repo/tests/adapt/golden/gf63/strict/plan.zon" ] && plan_arg="--plan /src/tests/adapt/golden/gf63/strict/plan.zon"
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
# upstream's output with the accepted differences applied (golden/gf63/differences)
expect=$out/expected
mkdir -p "$expect"
for f in lsmod fragment.symbols config.sorted; do
	cp "$golden/$f" "$expect/$f"
done
accepted=0
while read -r file change _; do
	case $file in ''|'#'*) continue ;; esac
	line=${change#?}
	case $change in
		-*) grep -v -x -F -- "$line" "$expect/$file" > "$expect/$file.new" || true ;;
		+*) { cat "$expect/$file"; printf '%s\n' "$line"; } > "$expect/$file.new" ;;
		*) echo "differences: $file $change: the change starts with - or +"; exit 2 ;;
	esac
	sort "$expect/$file.new" > "$expect/$file"
	rm -f "$expect/$file.new"
	accepted=$((accepted + 1))
done < "$golden/differences"
sort "$expect/lsmod" > "$expect/lsmod.sorted"
sort "$out/result/lsmod" > "$out/result/lsmod.sorted"
rc=0
cmp -s "$expect/lsmod.sorted" "$out/result/lsmod.sorted" || { echo "LSMOD differs:"; diff "$expect/lsmod.sorted" "$out/result/lsmod.sorted" || true; rc=1; }
strip_from "$out/result/fragment.config" > "$out/result/fragment.symbols"
cmp -s "$expect/fragment.symbols" "$out/result/fragment.symbols" || { echo "fragment differs:"; diff "$expect/fragment.symbols" "$out/result/fragment.symbols" || true; rc=1; }
# the order of .config lines follows the order of the fragments; the kernel reads the values
sort "$out/result/.config" > "$out/result/config.sorted"
cmp -s "$expect/config.sorted" "$out/result/config.sorted" || { echo ".config differs:"; diff "$expect/config.sorted" "$out/result/config.sorted" | head -60 || true; rc=1; }
[ "$rc" = 0 ] && echo "the GF63 oracle holds: lsmod, fragment symbols and .config are those of void-hardperf-light ($accepted accepted differences, each explained in tests/kernel/golden/gf63/differences)"
exit "$rc"
