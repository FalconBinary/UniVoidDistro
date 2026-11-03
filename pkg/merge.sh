#!/bin/sh
# One architecture of a publication (docs/uni/rolling.md): the packages that changed against the
# published repository, added to its index, so an update replaces exactly what changed.
#   sh pkg/merge.sh NEW ARCH PREV STAGE
# NEW: pkg/build.sh's repository. PREV: the published ARCH-repodata and ARCH-contents (no such
# files: the first publication). STAGE gets the changed packages, the merged index and contents,
# and in STAGE/ARCH-kept the packages the index still needs from the published set.
# A package whose HASH in ARCH-contents is the published one is left out; univoid never is: its
# version carries the time of the build. Not signed yet: pkg/sign.sh.
set -eu
new=$(cd "${1:?"pkg/build.sh's repository"}" && pwd)
arch=${2:?"the architecture"}
prev=${3:?"the published ARCH-repodata and ARCH-contents"}
stage=${4:?"the output directory"}
mkdir -p "$stage"
stage=$(cd "$stage" && pwd)
X=${XBPS_BIN:-/usr/bin}
[ -s "$new/$arch-contents" ] || { echo "pkg/merge.sh: no $new/$arch-contents" >&2; exit 1; }
pc=$prev/$arch-contents
[ -s "$pc" ] && [ -s "$prev/$arch-repodata" ] || pc=/dev/null
[ "$pc" = /dev/null ] || cp "$prev/$arch-repodata" "$stage/"
: > "$stage/$arch-contents"
: > "$stage/$arch-kept"
changed=""
while read -r name pkgver hash; do
	old=$(awk -v n="$name" '$1 == n' "$pc")
	if [ -n "$old" ] && [ "$name" != univoid ] && [ "$(echo "$old" | cut -d' ' -f3)" = "$hash" ]; then
		echo "$old" >> "$stage/$arch-contents"
		echo "$(echo "$old" | cut -d' ' -f2).$arch.xbps" >> "$stage/$arch-kept"
		echo "  unchanged: $(echo "$old" | cut -d' ' -f2)"
		continue
	fi
	echo "$name $pkgver $hash" >> "$stage/$arch-contents"
	cp "$new/$pkgver.$arch.xbps" "$stage/"
	changed="$changed $pkgver.$arch.xbps"
	echo "  new: $pkgver"
done < "$new/$arch-contents"
# a package no build makes any more would stay in the index for ever: a person decides
if [ "$pc" != /dev/null ]; then
	gone=$(awk 'NR == FNR { n[$1] = 1; next } !($1 in n) { print $2 }' "$new/$arch-contents" "$pc")
	[ -z "$gone" ] || { echo "pkg/merge.sh: the published set has packages no build makes: $gone" >&2; exit 1; }
fi
cd "$stage"
# shellcheck disable=SC2086 # the file names have no spaces
[ -z "$changed" ] || XBPS_TARGET_ARCH=$arch "$X/xbps-rindex" -f -a $changed >/dev/null
# a change of a library's name that would break another package goes to a stage index xbps never reads
[ ! -e "$arch-stagedata" ] || { echo "pkg/merge.sh: xbps-rindex staged the index: a shared library changed" >&2; exit 1; }
