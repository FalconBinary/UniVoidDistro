#!/bin/bash
# /etc/runit/ctrlaltdel on both sysfs paths of tiny_power_button: a platform driver since kernel
# 6.18.60, an ACPI driver before it. With a device under either, SIGINT is the power button and
# goes to vh-acpid; with the driver's directory empty of devices, or no driver, it is Void's reboot;
# with vh-acpid down, POWER_KEY decides. The script runs with its absolute paths under a
# directory of the test and a stub sv. vh-audit and the rig must look in the same two places.
#   bash tests/install/ctrlaltdel_test.sh /src   (in the vh-dev image: tests/install/run.sh)
set -u
src=${1:?"the repository"}
script=$src/rootfs/etc/runit/ctrlaltdel
new=sys/bus/platform/drivers/acpi-tiny-power-button
old=sys/bus/acpi/drivers/tiny-power-button
fails=0
ok() { echo "ok $1"; }
bad() { echo "FAIL $1${2:+: $2}"; fails=$((fails + 1)); }

sh -n "$script" && ok "ctrlaltdel parses" || bad "ctrlaltdel does not parse"

w=$(mktemp -d)
mkdir -p "$w/bin"
printf '#!/bin/sh\necho "$*" >> "%s/sv.log"\nexit "${SV_RC:-0}"\n' "$w" > "$w/bin/sv"
printf '#!/bin/sh\ncat >/dev/null\n' > "$w/bin/wall"
chmod +x "$w/bin/sv" "$w/bin/wall"

# NAME EXPECT_SV EXPECT_STOPIT EXPECT_REBOOT; the caller prepares $root
run_case() {
	sed -e "s#/sys/bus#$root/sys/bus#g" -e "s#/run/runit#$root/run/runit#g" \
		-e "s#/etc/vh/acpi.conf#$root/etc/vh/acpi.conf#g" -e "s#^PATH=.*#PATH=$w/bin:/usr/bin:/usr/sbin#" \
		"$script" > "$root/ctrlaltdel"
	: > "$w/sv.log"
	sh "$root/ctrlaltdel" >/dev/null 2>&1
	got="sv=[$(cat "$w/sv.log")] stopit=$(stat -c %a "$root/run/runit/stopit") reboot=$(stat -c %a "$root/run/runit/reboot")"
	want="sv=[$2] stopit=$3 reboot=$4"
	[ "$got" = "$want" ] && ok "$1" || bad "$1" "$got, expected $want"
}
fresh() {
	root=$(mktemp -d)
	mkdir -p "$root/run/runit" "$root/etc/vh"
	: > "$root/run/runit/stopit"
	: > "$root/run/runit/reboot"
	chmod 000 "$root/run/runit/stopit" "$root/run/runit/reboot"
}
driver() { # the driver's directory as sysfs shows it; with a second argument, the bound device
	mkdir -p "$root/$1"
	: > "$root/$1/bind"; : > "$root/$1/uevent"; : > "$root/$1/unbind"; mkdir -p "$root/$1/module"
	[ $# -lt 2 ] || mkdir -p "$root/$1/$2"
}

echo "== the button: hands SIGINT to vh-acpid"
fresh; driver "$new" LNXPWRBN:00
run_case "the platform driver (6.18.60 and later) with its device" "1 vh-acpid" 0 0
fresh; driver "$old" LNXPWRBN:00
run_case "the ACPI driver (before 6.18.60) with its device" "1 vh-acpid" 0 0

echo "== no button: Void's reboot"
fresh; driver "$new"
run_case "the platform driver without a device" "" 100 100
fresh; driver "$old"
run_case "the ACPI driver without a device" "" 100 100
fresh
run_case "no driver at all" "" 100 100

echo "== vh-acpid down: POWER_KEY decides"
export SV_RC=1
fresh; driver "$new" LNXPWRBN:00; echo 'POWER_KEY="poweroff"' > "$root/etc/vh/acpi.conf"
run_case "POWER_KEY=poweroff: stage 3 without a reboot" "1 vh-acpid" 100 0
fresh; driver "$new" LNXPWRBN:00; echo 'POWER_KEY="ignore"' > "$root/etc/vh/acpi.conf"
run_case "POWER_KEY=ignore: nothing" "1 vh-acpid" 0 0
fresh; driver "$old" LNXPWRBN:00
run_case "no acpi.conf: poweroff by default" "1 vh-acpid" 100 0
unset SV_RC

echo "== every reader looks in both places"
for f in rootfs/etc/runit/ctrlaltdel rootfs/usr/local/libexec/vh/vh-audit.d/70-network.sh tests/vm/steps/core.py; do
	for p in "/$new" "/$old"; do
		grep -qF "$p" "$src/$f" && ok "$f: $p" || bad "$f does not read $p"
	done
done

[ "$fails" = 0 ] && echo "ok all ctrlaltdel checks" || { echo "$fails FAILED"; exit 1; }
