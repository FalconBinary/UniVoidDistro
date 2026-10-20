#!/bin/sh
# The installer's functions against the plans. For every golden plan of tests/adapt (strict,
# or tiered where strict refuses the machine), the packages, the module blacklist, the firmware
# kept and the kernel command line that install/ writes are compared with
# tests/install/golden/MACHINE.txt; for the GF63 they must also equal what void-hardperf-light's
# installer writes (golden/gf63-upstream.txt, captured from upstream's install/ before the
# installer took the plan). Every script of install/ and optional/ passes bash -n. Then
# prebuilt_test.sh (the installer on our live image) and firmware_test.sh (the firmware trim
# through linux-firmware's links).
#   sh tests/install/run.sh            # compare
#   sh tests/install/run.sh --update   # rewrite golden/MACHINE.txt (not the upstream capture)
set -eu
# macOS tar: no AppleDouble ("._name") files for the extended attributes
export COPYFILE_DISABLE=1
repo=$(cd "$(dirname "$0")/../.." && pwd)
img=$(sh "$repo/tests/docker/build.sh")
out=$repo/build/it
rm -rf "$out"
mkdir -p "$out"
tar -C "$repo" -cf - install optional vh.conf.example tests/adapt/golden |
	docker run --rm -i "$img" bash -c '
	set -e
	mkdir -p /src && cd /src && tar -xf - 2>/dev/null
	for f in install/*.sh optional/*/enable optional/*/disable; do bash -n "$f" || { echo "bash -n failed: $f" >&2; exit 1; }; done
	for d in tests/adapt/golden/*/; do
		m=$(basename "$d")
		mode=strict
		[ "$(cat "$d/strict/status")" = 3 ] && mode=tiered
		(
			. install/lib.sh
			. install/packages.sh
			set +e
			load_config /nonexistent 2>/dev/null
			load_plan "$d/$mode/plan.env"
			export VH_LUKS_UUID=LUKS VH_ROOT_UUID=ROOT
			echo "## packages"; vh_packages | sort
			echo "## blacklist"; vh_module_blacklist | sort
			echo "## noextract"; vh_firmware_noextract | grep "^noextract" | sort
			echo "## cmdline"; vh_cmdline | tr " " "\n" | sort
		) > "/tmp/$m.txt" 2>&1
	done
	cd /tmp && tar -cf - ./*.txt
' > "$out/out.tar"
tar -C "$out" -xf "$out/out.tar"

# the order inside module_blacklist= follows the order of the lists it is made of: compare it as a set
norm() { awk '/^module_blacklist=/ { n = split(substr($0, 18), a, ","); asort_(a, n); s = a[1]; for (i = 2; i <= n; i++) s = s "," a[i]; print "module_blacklist=" s; next } { print }
	function asort_(a, n,   i, j, t) { for (i = 2; i <= n; i++) { t = a[i]; for (j = i - 1; j > 0 && a[j] > t; j--) a[j + 1] = a[j]; a[j + 1] = t } }' "$1"; }

golden=$repo/tests/install/golden
rc=0
for f in "$out"/*.txt; do
	m=$(basename "$f" .txt)
	if [ "${1:-}" = --update ]; then
		cp "$f" "$golden/$m.txt"
		continue
	fi
	if ! cmp -s "$golden/$m.txt" "$f"; then
		echo "DIFFERS: $m"
		diff -u "$golden/$m.txt" "$f" | head -40 || true
		rc=1
	fi
done
if [ "${1:-}" = --update ]; then echo "golden files rewritten: $golden"; exit 0; fi
norm "$golden/gf63-upstream.txt" > "$out/gf63-upstream.norm"
# the firmware below other directories (noextract=!/usr/lib/firmware/*/PATTERN) is ours alone: since
# 2025 linux-firmware keeps iwlwifi-*.ucode as links into intel/iwlwifi/, and upstream's trim, as
# captured, keeps the links without their targets (the GF63's Wi-Fi, linux-firmware 20260810)
norm "$out/gf63.txt" | grep -v '^noextract=!/usr/lib/firmware/\*/' > "$out/gf63.norm"
if cmp -s "$out/gf63-upstream.norm" "$out/gf63.norm"; then
	echo "the GF63's packages, blacklist, firmware and command line are void-hardperf-light's"
else
	echo "the GF63 differs from void-hardperf-light's installer:"
	diff -u "$out/gf63-upstream.norm" "$out/gf63.norm" || true
	rc=1
fi
[ "$rc" = 0 ] && echo "every machine's installer output matches its golden file"

# the installer on our live image: the prebuilt programs and their checks (prebuilt_test.sh)
tar -C "$repo" -cf - install thor zig/ZIG_VERSION vh.conf.example tests/install/prebuilt_test.sh |
	docker run --rm -i "$img" bash -c 'mkdir -p /src && cd /src && tar -xf - 2>/dev/null && bash /src/tests/install/prebuilt_test.sh /src' || rc=1
# the firmware trim through linux-firmware's links (firmware_test.sh)
tar -C "$repo" -cf - install tests/install/firmware_test.sh |
	docker run --rm -i "$img" bash -c 'mkdir -p /src && cd /src && tar -xf - 2>/dev/null && bash /src/tests/install/firmware_test.sh /src' || rc=1
exit "$rc"
