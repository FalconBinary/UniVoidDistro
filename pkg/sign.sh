#!/bin/sh
# Signs a repository directory, every architecture's index and every package that has no
# signature yet (docs/uni/rolling.md).
#   sh pkg/sign.sh DIR KEY.pem "SIGNED BY" [--all]
# --all signs every package again (the offline key, over what another key signed).
# With XBPS_PASSPHRASE the key's passphrase comes from it; otherwise xbps-rindex asks.
set -eu
dir=${1:?"the repository directory"} key=${2:?"the private key"} by=${3:?"who signs"} all=${4:-}
X=${XBPS_BIN:-/usr/bin}
cd "$dir"
found=0
for r in *-repodata; do
	[ -e "$r" ] || continue
	found=1
	XBPS_TARGET_ARCH=${r%-repodata} "$X/xbps-rindex" --sign --signedby "$by" --privkey "$key" . >/dev/null
done
[ "$found" = 1 ] || { echo "pkg/sign.sh: no index in $dir" >&2; exit 1; }
for p in *.xbps; do
	[ -e "$p" ] || continue
	if [ ! -e "$p.sig2" ]; then
		"$X/xbps-rindex" --sign-pkg --privkey "$key" "$p" >/dev/null
	elif [ "$all" = --all ]; then
		# -f: xbps-rindex otherwise leaves a signature that is already there; with none there, -f fails
		"$X/xbps-rindex" -f --sign-pkg --privkey "$key" "$p" >/dev/null
	fi
done
echo "signed: $(ls ./*-repodata | wc -l) indexes, $(ls ./*.sig2 2>/dev/null | wc -l) packages"
