#!/bin/sh
# Stable's manual step (docs/uni/rolling.md, "A stable release"): the draft release of a tag, signed
# by the offline key, then published. The packages stay byte for byte what CI built and the rig
# passed: each is checked against its build attestation; only the signatures and the index's change.
#   sh pkg/sign-stable.sh v0.3.0 /Volumes/KEY/stable.pem
# GitHub CLI and docker here; xbps-rindex in a throwaway Void container. The passphrase and the key
# come on stdin, so ps and docker inspect show neither, and colima need not share the key's media;
# the key lands in a tmpfs, so the VM's disk never holds it.
set -eu
tag=${1:?"the tag, for example v0.3.0"} key=${2:?"the offline key (pkg/keygen.sh stable DIR)"}
src=$(cd "$(dirname "$0")/.." && pwd)
GH_REPO=${GH_REPO:-FalconBinary/UniVoidDistro}
export GH_REPO COPYFILE_DISABLE=1
[ -r "$key" ] || { echo "no readable key at $key" >&2; exit 2; }
[ "$(gh release view "$tag" --json isDraft --jq .isDraft)" = true ] || { echo "$tag is not a draft release: nothing to sign" >&2; exit 2; }
[ "$(gh api "repos/$GH_REPO/releases" --jq "[.[] | select(.tag_name == \"$tag\")] | length")" = 1 ] || { echo "$tag has more than one release: leave one" >&2; exit 2; }

work=$(mktemp -d "${TMPDIR:-/tmp}/vh-stable.XXXXXX")
mkdir "$work/r" "$work/k" "$work/out"
gh release download "$tag" -D "$work/r" -p '*.xbps' -p '*-repodata' -p '*-contents'
echo "== every package against its attestation"
for p in "$work"/r/*.xbps; do
	gh attestation verify "$p" --repo "$GH_REPO" --signer-workflow "$GH_REPO/.github/workflows/packages.yml" >/dev/null \
		|| { echo "$(basename "$p"): no attestation of this repository's packages workflow" >&2; exit 1; }
done
stty -echo; printf 'The passphrase of the key: '; IFS= read -r pw; stty echo; echo
echo "== signing"
# a link, followed by tar: the key is not copied to this machine's disk either
ln -s "$(cd "$(dirname "$key")" && pwd)/$(basename "$key")" "$work/k/key.pem"
cp "$src/pkg/sign.sh" "$work/sign.sh"
{ printf '%s\n' "$pw"; tar -C "$work" -chf - k r sign.sh; } |
	docker run --rm -i --tmpfs /k:size=1m,mode=0700 ghcr.io/void-linux/void-glibc-full:latest sh -euc '
		exec 3>&1 1>&2
		IFS= read -r XBPS_PASSPHRASE
		export XBPS_PASSPHRASE
		tar --warning=no-unknown-keyword --no-same-owner -xf - -C /
		sh /sign.sh /r /k/key.pem "UniVoidDistro stable" --all
		cd /r && tar -cf - ./*-repodata ./*.sig2 >&3
	' | tar -xf - -C "$work/out"
# a pipeline's status is its last command's: a failed signature shows only here
for p in "$work"/r/*.xbps; do
	[ -s "$work/out/$(basename "$p").sig2" ] || { echo "$(basename "$p"): not signed, nothing was uploaded" >&2; exit 1; }
done
echo "== uploading the signatures and the index, the index last"
gh release upload "$tag" "$work"/out/*.sig2 --clobber
gh release upload "$tag" "$work"/out/*-repodata --clobber
gh release edit "$tag" --draft=false --latest
echo "$tag is published: the stable channel follows it"
