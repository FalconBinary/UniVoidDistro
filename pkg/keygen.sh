#!/bin/sh
# A new key for a channel (docs/uni/rolling.md), in a throwaway Void container: the private key
# never touches a mount, only the tar stream to DIR. The public key's file is named by the
# fingerprint xbps gives it: it goes into pkg/keys/CHANNEL/ and is committed.
#   sh pkg/keygen.sh stable|rolling DIR
# stable: keep DIR on the offline media, with a passphrase (asked here); rolling: the key goes into
# GitHub's secret, then it is deleted:
#   gh secret set VH_REPO_KEY_ROLLING --env rolling < DIR/rolling.pem
set -eu
ch=${1:?"the channel: stable or rolling"} dir=${2:?"the directory for the key"}
case $ch in stable|rolling) ;; *) echo "the channel: stable or rolling" >&2; exit 2 ;; esac
mkdir -p "$dir"
crypt=""
pw=""
if [ "$ch" = stable ]; then
	stty -echo; printf 'A passphrase for the key: '; read -r pw; stty echo; echo
	[ -n "$pw" ] || { echo "stable's key needs a passphrase" >&2; exit 2; }
	crypt="-aes256 -passout env:XBPS_PASSPHRASE"
fi
docker run --rm -i -e XBPS_PASSPHRASE="$pw" -e CH="$ch" -e CRYPT="$crypt" ghcr.io/void-linux/void-glibc-full:latest sh -euc '
	exec 3>&1 1>&2
	xbps-install -Sy openssl >/dev/null
	mkdir -p /o /e /r /c/var/db/xbps/keys
	cd /r
	# shellcheck disable=SC2086
	openssl genrsa $CRYPT -out /o/$CH.pem 4096
	chmod 0600 /o/$CH.pem
	a=$(xbps-uhelper arch)
	xbps-create -q -A "$a" -n empty-1_1 -s empty /e
	xbps-rindex -a empty-1_1.$a.xbps >/dev/null
	xbps-rindex --sign --signedby "UniVoidDistro $CH" --privkey /o/$CH.pem /r >/dev/null
	# xbps itself names the public key: it imports it from the index, at a yes
	yes | xbps-install -r /c -R /r -S >/dev/null 2>&1 || true
	[ -n "$(ls /c/var/db/xbps/keys/)" ] || { echo "no key imported"; exit 1; }
	cp /c/var/db/xbps/keys/*.plist /o/
	cd /o && tar -cf - . >&3
' | tar -xf - -C "$dir"
echo "the private key: $dir/$ch.pem"
echo "the public key:  $(ls "$dir"/*.plist); commit it in pkg/keys/$ch/"
