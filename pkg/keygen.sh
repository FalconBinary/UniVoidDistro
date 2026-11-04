#!/bin/sh
# A new key for a channel (docs/uni/rolling.md), in a throwaway Void container. The private key is
# made in a tmpfs, so the VM's disk never holds it, and leaves only by the tar stream to DIR. The
# passphrase comes on stdin, so neither ps nor docker inspect shows it. The public key's file is
# named by the fingerprint xbps gives it: it goes into pkg/keys/CHANNEL/ and is committed.
#   sh pkg/keygen.sh stable|rolling DIR
# stable: keep DIR on the offline media, with a passphrase (asked here); rolling: the key goes into
# GitHub's secret, then it is deleted:
#   gh secret set VH_REPO_KEY_ROLLING --env rolling < DIR/rolling.pem
# DIR outside ~/Documents and ~/Desktop: those may sync to iCloud.
set -eu
ch=${1:?"the channel: stable or rolling"} dir=${2:?"the directory for the key"}
case $ch in stable|rolling) ;; *) echo "the channel: stable or rolling" >&2; exit 2 ;; esac
mkdir -p "$dir"
pw=""
if [ "$ch" = stable ]; then
	stty -echo; printf 'A passphrase for the key: '; IFS= read -r pw; stty echo; echo
	[ -n "$pw" ] || { echo "stable's key needs a passphrase" >&2; exit 2; }
fi
printf '%s\n' "$pw" | docker run --rm -i --tmpfs /o:size=1m,mode=0700 -e CH="$ch" ghcr.io/void-linux/void-glibc-full:latest sh -euc '
	exec 3>&1 1>&2
	IFS= read -r XBPS_PASSPHRASE
	crypt=""
	if [ -n "$XBPS_PASSPHRASE" ]; then
		export XBPS_PASSPHRASE
		crypt="-aes256 -passout env:XBPS_PASSPHRASE"
	fi
	for p in openssl python3; do xbps-query "$p" >/dev/null || xbps-install -Sy "$p" >/dev/null; done
	mkdir -p /e /r /c/var/db/xbps/keys
	cd /r
	# shellcheck disable=SC2086
	openssl genrsa $crypt -out /o/$CH.pem 4096
	chmod 0600 /o/$CH.pem
	a=$(xbps-uhelper arch)
	xbps-create -q -A "$a" -n empty-1_1 -s empty /e
	xbps-rindex -a empty-1_1.$a.xbps >/dev/null
	xbps-rindex --sign --signedby "UniVoidDistro $CH" --privkey /o/$CH.pem /r >/dev/null
	# xbps itself names the public key: it imports it from a remote index, at a yes
	python3 -m http.server 8321 --bind 127.0.0.1 >/dev/null 2>&1 &
	sleep 1
	yes | xbps-install -r /c -R http://127.0.0.1:8321 -S >/dev/null 2>&1 || true
	kill $!
	[ -n "$(ls /c/var/db/xbps/keys/)" ] || { echo "no key imported"; exit 1; }
	cp /c/var/db/xbps/keys/*.plist /o/
	cd /o && tar -cf - . >&3
' | tar -xf - -C "$dir"
# a pipeline's status is its last command's: a failure in the container shows only here
[ -s "$dir/$ch.pem" ] && ls "$dir"/*.plist >/dev/null 2>&1 || { echo "no key was made" >&2; exit 1; }
echo "the private key: $dir/$ch.pem"
echo "the public key:  $(ls "$dir"/*.plist); commit it in pkg/keys/$ch/"
