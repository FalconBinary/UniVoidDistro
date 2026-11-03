#!/bin/sh
# The gate of an architecture the rig cannot boot on GitHub (aarch64: its runners have no /dev/kvm,
# docs/uni/rolling.md, "The gates"): this build's signed repository through a real system's package
# manager, in a throwaway Void container on a runner of that architecture.
#   sh tests/pkg/gate.sh REPO ARCH VARIANT   (REPO: the repository, with gate-key/key.plist and fingerprint)
# The new thor replaces xbps; our packages and their dependencies from Void install under its
# policy in enforce with every signature checked; the programs start and the libraries resolve.
# What it does not show: that the system boots after the update. That stays [VERIFY] here.
set -eu
repo=$(cd "${1:?"the repository"}" && pwd)
arch=${2:?"the architecture"} variant=${3:?"the desktop's build, for example aarch64-btmenu"}
export COPYFILE_DISABLE=1
sdir=$(cd "$(dirname "$0")/../.." && pwd)
[ "$(uname -m)" = "$arch" ] || { echo "tests/pkg/gate.sh: the runner is $(uname -m), not $arch" >&2; exit 2; }
tar -C "$repo" -cf - . | docker run --rm -i -e VARIANT="$variant" -e THORKEEP="$(cat "$sdir/pkg/thor-keep")" \
	ghcr.io/void-linux/void-glibc-full:latest sh -euc '
	mkdir -p /www && tar -xf - -C /www
	xbps-install -Syu xbps >/dev/null && xbps-install -Syu >/dev/null
	xbps-install -y python3 >/dev/null
	cp /www/gate-key/key.plist "/var/db/xbps/keys/$(cat /www/gate-key/fingerprint).plist"
	cd /www && python3 -m http.server 8321 --bind 127.0.0.1 >/dev/null 2>&1 &
	sleep 1
	# ahead of Void'"'"'s repository, as in the system: stdin closed, a signature of another key is refused
	echo "repository=http://127.0.0.1:8321" > /etc/xbps.d/00-a-vh-channel.conf
	echo "ignorepkg=xbps" > /etc/xbps.d/20-vh-ignorepkg.conf
	xbps-install -S </dev/null >/dev/null
	echo "== the new thor replaces xbps"
	xbps-install -y thor </dev/null | tail -1
	thor --version
	mkdir -p /etc/thor
	printf "mode=enforce\n" > /etc/thor/policy.conf
	printf "%s\n" "$THORKEEP" | grep "^/" > /etc/thor/keep.conf
	echo "== our packages under its policy (enforce)"
	thor install -y univoid "vh-desktop-$VARIANT" </dev/null | tail -2
	xbps-pkgdb univoid vh-tools vh-init vh-sched vh-session vh-data vh-installer vh-base vh-etc "vh-desktop-$VARIANT" thor
	echo "== the programs"
	/usr/local/libexec/vh/vh-seccomp --selftest >/dev/null
	/usr/local/sbin/vh-plan --help >/dev/null 2>&1 || [ $? -lt 126 ]
	/usr/local/sbin/vh-kconf --help >/dev/null 2>&1 || [ $? -lt 126 ]
	/usr/local/sbin/vh-init --help >/dev/null 2>&1 || [ $? -lt 126 ]
	for b in /usr/local/bin/refurswm /usr/local/bin/refursline /root/vh/tools/vh-hashpw /usr/local/libexec/vh/pin-fetch /root/vh/optional/dns-pin/pin-fetch; do
		[ -e "$b" ] || continue
		! ldd "$b" 2>&1 | grep "not found" || { echo "$b: a library is missing"; exit 1; }
	done
	[ -z "$(find /usr/local /root/vh -type f -perm /6000)" ]
	[ -e /etc/kernel.d/post-install/90-vh-uki ]
	echo "gate: every check passed"
'
