#!/bin/sh
# vh-plan against the golden plans of every machine in kernel/hw (tests/adapt/golden), after
# its unit tests. Every machine is planned in strict mode, and in tiered mode when strict
# refuses it; each plan twice, and the two runs must be the same byte for byte.
#   sh tests/adapt/run.sh            # compare
#   sh tests/adapt/run.sh --update   # rewrite the golden plans: the git diff is the review
# Like tests/kernel/run.sh: Zig cross-builds for Linux of the host's architecture, a throwaway
# container runs the binaries, the inputs are streamed in with tar.
set -eu
# macOS tar: no AppleDouble ("._name") files for the extended attributes
export COPYFILE_DISABLE=1
repo=$(cd "$(dirname "$0")/../.." && pwd)
case $(uname -m) in arm64|aarch64) arch=aarch64 ;; *) arch=x86_64 ;; esac
out=$repo/build/at
rm -rf "$out"
mkdir -p "$out/plans"
echo "== building vh-plan and its tests ($arch-linux)"
(cd "$repo/adapt" && zig build install tests -Dtarget="$arch-linux" -Dcpu=baseline --prefix "$out")
echo "== unit tests and plans in a container"
tar -C "$repo" -cf - kernel/hw kernel/pins hwdb vh.conf.example build/at/bin build/at/test |
	docker run --rm -i alpine:3.20 sh -c '
	set -e
	mkdir -p /src && cd /src && tar -xf -
	./build/at/test/vh-plan 2>&1 | tail -1 >&2
	for hwf in kernel/hw/*.zon; do
		m=$(basename "$hwf" .zon)
		for mode in strict tiered; do
			for run in 1 2; do
				d=/tmp/p/$m/$mode.$run
				mkdir -p "$d"
				rc=0
				./build/at/bin/vh-plan plan --hw "$hwf" --hwdb hwdb --pins kernel/pins \
					--config vh.conf.example --security "$mode" --out "$d" > "$d/stdout" 2>&1 || rc=$?
				echo "$rc" > "$d/status"
			done
		done
	done
	cd /tmp/p && tar -cf - .
' > "$out/plans.tar"
tar -C "$out/plans" -xf "$out/plans.tar"

golden=$repo/tests/adapt/golden
rc=0
for d in "$out"/plans/*/; do
	m=$(basename "$d")
	modes=strict
	[ "$(cat "$d/strict.1/status")" = 3 ] && modes="strict tiered"
	for mode in $modes; do
		a=$d/$mode.1
		b=$d/$mode.2
		for f in plan.zon plan.env plan-report.txt status; do
			cmp -s "$a/$f" "$b/$f" || { echo "NOT DETERMINISTIC: $m $mode $f"; rc=1; }
		done
		g=$golden/$m/$mode
		if [ "${1:-}" = --update ]; then
			mkdir -p "$g"
			cp "$a/plan.zon" "$a/plan.env" "$a/plan-report.txt" "$a/status" "$g/"
			continue
		fi
		for f in plan.zon plan.env plan-report.txt status; do
			if ! cmp -s "$g/$f" "$a/$f"; then
				echo "DIFFERS: $m $mode $f"
				diff -u "$g/$f" "$a/$f" | head -40 || true
				rc=1
			fi
		done
		printf '%-22s %-7s tier %-8s status %s\n' "$m" "$mode" "$(sed -n "s/^VH_PLAN_TIER='\(.*\)'/\1/p" "$a/plan.env")" "$(cat "$a/status")"
	done
done
[ "${1:-}" = --update ] && { echo "golden plans rewritten: $golden"; exit 0; }
[ "$rc" = 0 ] && echo "every plan is deterministic and matches its golden plan"
exit "$rc"
