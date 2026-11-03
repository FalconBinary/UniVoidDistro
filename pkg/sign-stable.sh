#!/bin/sh
# Stable's manual step (docs/uni/rolling.md, "A stable release"): the draft release of a tag, signed
# by the offline key, then published. The packages stay byte for byte what CI built and the rig
# passed: each is checked against its build attestation; only the signatures and the index's change.
#   sh pkg/sign-stable.sh v0.3.0 /Volumes/KEY/stable.pem
# GitHub CLI and docker here; xbps-rindex in a throwaway Void container, the key on a read-only mount.
set -eu
tag=${1:?"the tag, for example v0.3.0"} key=${2:?"the offline key (pkg/keygen.sh stable DIR)"}
src=$(cd "$(dirname "$0")/.." && pwd)
GH_REPO=${GH_REPO:-FalconBinary/UniVoidDistro}
export GH_REPO COPYFILE_DISABLE=1
[ -r "$key" ] || { echo "no readable key at $key" >&2; exit 2; }
[ "$(gh release view "$tag" --json isDraft --jq .isDraft)" = true ] || { echo "$tag is not a draft release: nothing to sign" >&2; exit 2; }
[ "$(gh api "repos/$GH_REPO/releases" --jq "[.[] | select(.tag_name == \"$tag\")] | length")" = 1 ] || { echo "$tag has more than one release: leave one" >&2; exit 2; }

work=$(mktemp -d "${TMPDIR:-/tmp}/vh-stable.XXXXXX")
mkdir "$work/in" "$work/out"
gh release download "$tag" -D "$work/in" -p '*.xbps' -p '*-repodata' -p '*-contents'
echo "== every package against its attestation"
for p in "$work"/in/*.xbps; do
	gh attestation verify "$p" --repo "$GH_REPO" --signer-workflow "$GH_REPO/.github/workflows/packages.yml" >/dev/null \
		|| { echo "$(basename "$p"): no attestation of this repository's packages workflow" >&2; exit 1; }
done
stty -echo; printf 'The passphrase of the key: '; read -r pw; stty echo; echo
echo "== signing"
tar -C "$work/in" -cf - . | docker run --rm -i -e XBPS_PASSPHRASE="$pw" -e COPYFILE_DISABLE=1 \
	-v "$(cd "$(dirname "$key")" && pwd):/key:ro" -v "$src/pkg/sign.sh:/sign.sh:ro" \
	ghcr.io/void-linux/void-glibc-full:latest sh -euc "
		mkdir /r && tar -xf - -C /r
		sh /sign.sh /r /key/$(basename "$key") 'UniVoidDistro stable' --all >&2
		cd /r && tar -cf - ./*-repodata ./*.sig2
	" | tar -xf - -C "$work/out"
echo "== uploading the signatures and the index, the index last"
gh release upload "$tag" "$work"/out/*.sig2 --clobber
gh release upload "$tag" "$work"/out/*-repodata --clobber
gh release edit "$tag" --draft=false --latest
echo "$tag is published: the stable channel follows it"
