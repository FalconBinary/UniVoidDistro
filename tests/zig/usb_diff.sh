#!/bin/sh
# Differential test of vh-usb-udev: a reference build against the build under test.
#   sh tests/zig/usb_diff.sh "REFERENCE" CANDIDATE
# Only in a throwaway container with --privileged: in its own mount namespace it puts a
# fake USB tree on /sys/devices and tmpfs on /run/vh and /etc/vh.
set -eu
[ "${VH_IN_NS:-}" = 1 ] || exec env VH_IN_NS=1 unshare -m sh "$0" "$@"
ref=$1 new=$2
w=$(mktemp -d)
mount -t tmpfs tmpfs /sys/devices
mkdir -p /run/vh /etc/vh
mount -t tmpfs tmpfs /run/vh
mount -t tmpfs tmpfs /etc/vh
U=/sys/devices/pci0000:00/0000:00:14.0/usb1

# descriptors: configuration plus interfaces (class, subclass, protocol)
desc() {
	printf '\022\001\000\002\000\000\000\100\000\000\000\000\000\001\001\002\003\001'
	printf '\011\002\040\000\001\001\000\200\062'
	for i in "$@"; do
		set -- $(echo "$i" | tr , ' ')
		printf "\\011\\004\\000\\000\\001\\$(printf %03o "$1")\\$(printf %03o "$2")\\$(printf %03o "$3")\\000"
	done
}

mkdev() {   # mkdev PORT TYPE VID PID SERIAL INTERFACE...
	d=$U/$1 port=$1 ct=$2 vid=$3 pid=$4 ser=$5
	shift 5
	mkdir -p "$d/port"
	echo 0 > "$d/authorized"
	echo "$vid" > "$d/idVendor"
	echo "$pid" > "$d/idProduct"
	echo "$ser" > "$d/serial"
	echo "Maker" > "$d/manufacturer"
	echo "Thing $port" > "$d/product"
	echo "$ct" > "$d/port/connect_type"
	desc "$@" > "$d/descriptors"
	n=0
	for i in "$@"; do
		mkdir -p "$d/$port:1.$n"
		echo 0 > "$d/$port:1.$n/authorized"
		printf '%02x\n' "$(echo "$i" | cut -d, -f1)" > "$d/$port:1.$n/bInterfaceClass"
		n=$((n + 1))
	done
}

setup() {
	rm -rf "${U:?}"/* /run/vh/* /etc/vh/*
	mkdev 1-1 hotplug 0951 1666 AAA 8,6,80            # a USB stick, not attached
	mkdev 1-2 hardwired 5986 211b "" 14,1,0 14,2,0    # the internal camera
	mkdev 1-3 hardwired 8087 0026 "" 224,1,1 224,1,1  # the internal Bluetooth
	mkdev 1-4 hardwired 1038 1122 "" 3,1,1            # the internal keyboard
	mkdev 1-5 hotplug 1050 0407 KEY123 3,0,0          # our own FIDO key
	mkdev 1-6 hotplug 1050 0407 KEY999 3,0,0          # a foreign key of the same type
	mkdev 1-7 hotplug 1050 0407 KEY777 3,0,0 3,1,1    # a "key" with a keyboard interface
	mkdev 1-8 hotplug 0951 1666 BBB 8,6,80 3,1,1      # a USB stick plus keyboard (BadUSB)
	mkdev 1-9 hotplug 1050 0407 KEY777 3,0,0 3,1,1    # the same serial, another port
	mkdir -p /run/vh/usb-attach
	: > /run/vh/usb-attach/1-8
	printf '# port vid:pid serial\n1-5 1050:0407 KEY123\n1-7 1050:0407 KEY777\n' > /etc/vh/usb-keys.conf
	printf 'VH_CAMERA="%s"\nVH_BLUETOOTH="%s"\n' "$1" "$2" > /etc/vh/vh.env
}

state() {
	(cd /sys/devices && find . -name authorized | sort | while read -r f; do echo "$f=$(cat "$f")"; done)
	cat /run/vh/usb-blocked 2>/dev/null && echo
}

bad=0
for env in "no off" "yes optional" "no on"; do
	for impl in ref new; do
		# shellcheck disable=SC2086
		setup $env
		eval "cmd=\$$impl"
		for d in 1-1 1-2 1-3 1-4 1-5 1-6 1-7 1-8 1-9; do
			# shellcheck disable=SC2086
			$cmd device "${U#/sys}/$d" || true
			for i in "$U/$d"/"$d":1.*; do
				# shellcheck disable=SC2086
				$cmd interface "${i#/sys}" || true
			done
		done
		state > "$w/$impl"
	done
	if cmp -s "$w/ref" "$w/new"; then
		echo "ok VH_CAMERA/VH_BLUETOOTH = $env"
	else
		bad=$((bad + 1))
		echo "DIFFERENCE $env"
		diff "$w/ref" "$w/new" || true
	fi
done
cat "$w/new"
# the candidate alone: paths outside /sys/devices and non-existent ones must be refused
for p in "/devices/../../etc" "/class/net/lo" "/devices" "/devices/nope"; do
	if $new device "$p"; then
		bad=$((bad + 1))
		echo "FAIL: path $p was accepted"
	fi
done
echo "differences: $bad"
[ $bad = 0 ]
