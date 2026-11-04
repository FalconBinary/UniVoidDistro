#!/bin/sh
# The version of our packages at this commit: git describe, v0.2.0-15-gHASH -> 0.2.0.r15; it only
# grows along main and over the tags, so every channel compares (docs/uni/rolling.md). No git (a
# copy of the sources): 0.0.0.r0, below every published package.
d=$(git -C "$(dirname "$0")/.." describe --tags --match 'v[0-9]*' --long 2>/dev/null) || d=""
case $d in
	v*-*-g*) h=${d%-g*}; t=${h%-*}; echo "${t#v}.r${h##*-}" ;;
	*) echo "pkg/version.sh: no git describe here" >&2; echo 0.0.0.r0 ;;
esac
