#!/bin/sh
# The machine kernel of every machine in kernel/hw, x86_64 and aarch64, without a kernel tree
# (docs/uni/kernel.md, "The CI matrix"). Each machine is planned in tiered mode (a kernel can be
# built for a machine the strict gate would refuse to install on) and resolved with its plan
# against the pins of its architecture (kernel/pins/README.md), twice; then the checks that need
# no kernel source:
#   - the two runs give the same bytes;
#   - every symbol a class of the plan sets to a value is known to the pinned config of that
#     architecture (a symbol the kernel does not have would be lost by olddefconfig, and a lost
#     class symbol fails the build);
#   - no fragment conflict involves a class or the machine fragment;
#   - the invariants of the kernel-custom build hold in the requested .config already;
#   - NR_CPUS is the plan's and within the range the architecture allows (x86_64: the pinned
#     config's CONFIG_NR_CPUS_RANGE_*; arm64: 2..4096, arch/arm64/Kconfig);
#   - kcflags carries the plan's -march (aarch64: -mcpu for a core, -march for armv8-a), and
#     clang accepts it for that target (skipped without clang).
# The rest, which needs the kernel source (localyesconfig, olddefconfig, vh-kconf diff, the
# image), is the kernel-custom workflow with hw=all.
#   sh tests/kernel/matrix.sh
# Like run.sh: Zig cross-builds for Linux of the host's architecture, a throwaway container runs
# the binaries, the inputs are streamed in with tar. The results stay in build/km/MACHINE.
set -eu
# macOS tar: no AppleDouble ("._name") files for the extended attributes
export COPYFILE_DISABLE=1
repo=$(cd "$(dirname "$0")/../.." && pwd)
case $(uname -m) in arm64|aarch64) arch=aarch64 ;; *) arch=x86_64 ;; esac
out=$repo/build/km
rm -rf "$out"
mkdir -p "$out"
echo "== building vh-kconf and vh-plan ($arch-linux)"
(cd "$repo/kernel" && zig build install -Dtarget="$arch-linux" -Dcpu=baseline --prefix "$out")
(cd "$repo/adapt" && zig build install -Dtarget="$arch-linux" -Dcpu=baseline --prefix "$out")
echo "== plan (tiered) and resolve every machine of kernel/hw, twice, in a container"
tar -C "$repo" -cf - kernel/pins kernel/profiles kernel/hw hwdb vh.conf.example build/km/bin | docker run --rm -i alpine:3.20 sh -c '
	set -e
	mkdir -p /src && cd /src && tar -xf -
	for hwf in kernel/hw/*.zon; do
		m=$(basename "$hwf" .zon)
		a=$(sed -n "s/^    \.arch = \"\(.*\)\",\$/\1/p" "$hwf")
		mkdir -p "/tmp/m/$m"
		echo "$a" > "/tmp/m/$m/arch"
		for run in 1 2; do
			# both runs in the same directory: the reports name the paths they read
			d=/tmp/w
			rm -rf "$d" && mkdir -p "$d"
			rc=0
			./build/km/bin/vh-plan plan --hw "$hwf" --hwdb hwdb --pins kernel/pins --config vh.conf.example \
				--security tiered --out "$d/plan" > "$d/plan.out" 2>&1 || rc=$?
			echo "$rc" > "$d/plan.status"
			rc=0
			./build/km/bin/vh-kconf resolve --hw "$hwf" --plan "$d/plan/plan.zon" --repo /src --out "$d/resolve" \
				> "$d/resolve.out" 2>&1 || rc=$?
			echo "$rc" > "$d/resolve.status"
			cp -a "$d" "/tmp/m/$m/$run"
		done
	done
	cd /tmp/m && tar -cf - .
' | tar -C "$out" -xf -

clang_ok=0
if command -v clang >/dev/null 2>&1; then
	clang_ok=1
	echo "== -march checked with $(clang --version | head -1)"
else
	echo "== SKIP the -march check: no clang on this host (CI has it)"
fi
# a value of plan.env: VH_PLAN_KEY='value'
penv() { sed -n "s/^VH_PLAN_$2='\(.*\)'\$/\1/p" "$1/plan/plan.env"; }
rc=0
machines=0
for dir in "$out"/*/; do
	m=$(basename "$dir")
	[ -f "$dir/arch" ] || continue
	a=$(cat "$dir/arch")
	# the pins and the limits of this architecture (kernel/pins/README.md, kernel/src/alias.zig)
	case $a in
		x86_64)
			pinned=$repo/kernel/pins/x86_64-dotconfig
			range_begin=$(sed -n 's/^CONFIG_NR_CPUS_RANGE_BEGIN=//p' "$pinned")
			range_end=$(sed -n 's/^CONFIG_NR_CPUS_RANGE_END=//p' "$pinned")
			target=x86_64-linux-gnu ;;
		aarch64)
			pinned=$repo/kernel/pins/aarch64-dotconfig
			# arch/arm64/Kconfig: NR_CPUS "range 2 4096" (no CONFIG_NR_CPUS_RANGE_* symbols there)
			range_begin=2 range_end=4096
			target=aarch64-linux-gnu ;;
		*) echo "FAIL $m: no pins for the architecture $a"; rc=1; continue ;;
	esac
	machines=$((machines + 1))
	bad=""
	fail() { bad="$bad
  $1"; }
	d=$dir/1
	if [ "$(cat "$d/plan.status")" != 0 ]; then
		fail "vh-plan plan --security tiered exited $(cat "$d/plan.status"): $(tail -3 "$d/plan.out")"
	elif [ "$(cat "$d/resolve.status")" != 0 ]; then
		fail "vh-kconf resolve --plan exited $(cat "$d/resolve.status"): $(tail -3 "$d/resolve.out")"
	else
		for f in plan/plan.zon plan/plan.env plan/plan-report.txt resolve/lsmod resolve/fragment.config \
			resolve/.config resolve/resolve-report.txt resolve/kcflags; do
			cmp -s "$d/$f" "$dir/2/$f" || fail "not deterministic: $f differs between two runs"
		done
		classes=$(penv "$d" KCONFIG)
		features=$(penv "$d" FEATURES)
		march=$(penv "$d" MARCH)
		nr=$(penv "$d" NR_CPUS)
		# every symbol a class sets to a value is one the pinned config knows
		for c in $classes; do
			# shellcheck disable=SC2013 # one symbol name per line: words are lines
			for sym in $(sed -n 's/^\(CONFIG_[A-Za-z0-9_]*\)=.*/\1/p' "$repo/kernel/profiles/class/$c"); do
				grep -q -e "^$sym=" -e "^# $sym is not set\$" "$pinned" \
					|| fail "class/$c: $sym is not a symbol of the pinned config: olddefconfig would drop it"
			done
		done
		# a conflict between fragments: the later wins, which must never silently change a class
		conflicts=$(sed -n '/^Fragment conflicts/,/^$/p' "$d/resolve/resolve-report.txt" | grep -e ' class/' -e ' machine=' || true)
		[ -z "$conflicts" ] || fail "fragment conflicts with a class or the machine: $conflicts"
		cfg=$d/resolve/.config
		need() { grep -qx -e "$1" "$cfg" || fail "requested .config lacks: $1"; }
		case " $features " in
			*" game "*) need 'CONFIG_MODULES=y'; need 'CONFIG_MODULE_SIG_FORCE=y' ;;
			*) need '# CONFIG_MODULES is not set' ;;
		esac
		# the 802.11 stack only with a wireless interface (features/wifi): built in without one,
		# cfg80211 asks at every boot for a regulatory.db the plan does not keep, even when the
		# probe saw it loaded (the live system's dhcpcd loads it)
		case " $features " in
			*" wifi "*) need 'CONFIG_CFG80211=y'; need 'CONFIG_MAC80211=y' ;;
			*) ! grep -qx 'CONFIG_CFG80211=y' "$cfg" || fail "CONFIG_CFG80211=y without the feature wifi"
				! grep -qx -e cfg80211 -e mac80211 "$d/resolve/lsmod" || fail "the 802.11 stack in LSMOD without the feature wifi" ;;
		esac
		need 'CONFIG_SCHED_CLASS_EXT=y'
		need 'CONFIG_DEBUG_INFO_BTF=y'
		need 'CONFIG_LOCALVERSION="-vh"'
		need 'CONFIG_LOCK_DOWN_KERNEL_FORCE_CONFIDENTIALITY=y'
		need '# CONFIG_IO_URING is not set'
		got_nr=$(sed -n 's/^CONFIG_NR_CPUS=//p' "$cfg")
		want_nr=$nr
		[ "$want_nr" -ge 2 ] || want_nr=2
		[ "$got_nr" = "$want_nr" ] || fail "NR_CPUS: the .config has $got_nr, the plan $nr"
		if [ "$got_nr" -lt "$range_begin" ] || [ "$got_nr" -gt "$range_end" ]; then
			fail "NR_CPUS=$got_nr is outside the pinned config's range $range_begin..$range_end: olddefconfig would reset it"
		fi
		got_flags=$(cat "$d/resolve/kcflags")
		# the plan's march as the compiler takes it: -march on x86_64; on aarch64 a core is -mcpu,
		# the armv8-a of a virtual machine -march (docs/uni/kernel.md, "-march")
		want_flags="-march=$march"
		case $a:$march in aarch64:armv*) ;; aarch64:*) want_flags="-mcpu=$march" ;; esac
		[ -n "$march" ] && [ "$got_flags" = "$want_flags" ] || fail "kcflags \"$got_flags\", the plan's march \"$march\" ($want_flags)"
		if [ "$clang_ok" = 1 ] && [ -n "$march" ]; then
			printf 'int x;\n' | clang --target="$target" "$want_flags" -x c -fsyntax-only - 2> "$d/clang.err" \
				|| fail "clang does not know $want_flags for $target: $(head -1 "$d/clang.err")"
		fi
	fi
	if [ -n "$bad" ]; then
		echo "FAIL $m:$bad"
		rc=1
	else
		printf '%-22s %-8s tier %s; %s; %s LSMOD modules, %s fragment symbols; NR_CPUS %s; %s\n' "$m" "$a" \
			"$(penv "$d" TIER)" "$(echo "$classes" | wc -w | tr -d ' ') classes" \
			"$(grep -c . "$d/resolve/lsmod")" "$(grep -c -e '^CONFIG_' -e '^# CONFIG_.* is not set$' "$d/resolve/fragment.config")" \
			"$got_nr" "$got_flags"
	fi
done
[ "$machines" -gt 0 ] || { echo "no machine in kernel/hw"; exit 1; }
[ "$rc" = 0 ] && echo "every machine of kernel/hw plans and resolves ($machines, x86_64 and aarch64): deterministic, the class symbols known to the pinned config of its architecture, no conflict with a class, the invariants, NR_CPUS and the compiler's -march or -mcpu"
exit "$rc"
