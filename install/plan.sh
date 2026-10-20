#!/bin/bash
# The plan of this machine (docs/uni/ROADMAP.md, hwdb/README.md): builds vh-kconf and vh-plan
# with the live environment's Zig in RAM (as build-tools.sh does), probes the machine and plans
# it. Writes nothing to a disk: everything goes to /tmp/vh (RAM in the live environment).
#   install/plan.sh [--config FILE] [--security strict|tiered]
#
# /tmp/vh afterwards: hw.zon, snapshot/ (the probe's sysfs snapshot: no serial numbers, MAC
# addresses or UUIDs; a fixture for tests/kernel if you send it), plan.zon, plan.env,
# plan-report.txt, bin/vh-kconf, bin/vh-plan. The exit status is vh-plan's: 3 when the security
# gate refuses the machine (the plan is written all the same, so that the report says why).
. "$(dirname "$0")/lib.sh"

CFG=$VH_ROOT/vh.conf
SECURITY=""
while [ $# -gt 0 ]; do
	case $1 in
		--config) CFG=$2; shift ;;
		--security) SECURITY=$2; shift ;;
		-h|--help) sed -n '2,12p' "$0"; exit 0 ;;
		*) die "unknown argument: $1" ;;
	esac
	shift
done
need_root
load_config "$CFG"
OUT=${VH_PLAN_DIR:-/tmp/vh}
install -d -m 0700 "$OUT"

# on our live image, its builds (docs/uni/live-image.md); elsewhere they are built here
if [ ! -x "$OUT/bin/vh-plan" ] || [ ! -x "$OUT/bin/vh-kconf" ]; then
	rc=0
	PRE=$(vh_prebuilt) || rc=$?
	[ "$rc" != 2 ] || die "the live image's programs do not match its SHA256SUMS"
	if [ "$rc" = 0 ]; then
		say "vh-kconf and vh-plan: the live image's build ($PRE)"
		install -d "$OUT/bin"
		install -m 0755 "$PRE/bin/vh-kconf" "$PRE/bin/vh-plan" "$OUT/bin/"
	fi
fi
if [ ! -x "$OUT/bin/vh-plan" ] || [ ! -x "$OUT/bin/vh-kconf" ]; then
	ZIG=$(bash "$VH_ROOT/install/fetch-zig.sh" "$(cat "$VH_ROOT/zig/ZIG_VERSION")" /tmp/vh-zig)
	BUILD=$(mktemp -d /tmp/vh-plan-build.XXXXXX)
	trap 'rm -rf "$BUILD"' EXIT
	say "building vh-kconf and vh-plan (Zig, ReleaseSafe, in RAM)"
	mkdir -p "$BUILD/src"
	# kernel/ and adapt/ read ../zig/lib and ../kernel/src in place: the same layout
	cp -R "$VH_ROOT/zig" "$VH_ROOT/kernel" "$VH_ROOT/adapt" "$BUILD/src/"
	for c in kernel adapt; do
		( cd "$BUILD/src/$c" && ZIG_GLOBAL_CACHE_DIR=$BUILD/gcache ZIG_LOCAL_CACHE_DIR=$BUILD/cache \
			"$ZIG" build -Dtarget=native -Dcpu=baseline --prefix "$BUILD/out" ) || die "building $c failed"
	done
	install -d "$OUT/bin"
	install -m 0755 "$BUILD/out/bin/vh-kconf" "$BUILD/out/bin/vh-plan" "$OUT/bin/"
fi

say "probing the machine (sysfs, procfs, the device tree; no serial numbers)"
rm -rf "$OUT/snapshot"
"$OUT/bin/vh-kconf" probe --save "$OUT/snapshot" -o "$OUT/hw.zon"

say "planning it (hwdb/)"
args=(--hw "$OUT/hw.zon" --hwdb "$VH_ROOT/hwdb" --pins "$VH_ROOT/kernel/pins" --config "$VH_ROOT/vh.conf.example")
[ -f "$CFG" ] && args+=(--config "$CFG")
[ -n "$SECURITY" ] && args+=(--security "$SECURITY")
rc=0
"$OUT/bin/vh-plan" plan "${args[@]}" --out "$OUT" || rc=$?
[ "$rc" = 0 ] || [ "$rc" = 3 ] || die "vh-plan failed ($rc)"
sed -n '/^notes/,/^$/p' "$OUT/plan-report.txt"
echo "The whole plan, rule by rule: $OUT/plan-report.txt; why one item: $OUT/bin/vh-plan explain ITEM --plan $OUT/plan.zon --hwdb $VH_ROOT/hwdb"
exit "$rc"
