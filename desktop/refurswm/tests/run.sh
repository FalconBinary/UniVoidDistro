#!/bin/sh
# Copyright (c) 2026 Denys (FalconBinary)
# SPDX-License-Identifier: GPL-3.0-or-later
# Host side: builds RefursWM in the test image and runs the test scripts in it.
# The repo is mounted read-only; Zig caches and builds live in the docker volume "refurs-cache",
# results go to $OUT (default ~/refurs-ref/out/run; it must be under $HOME for Colima to share it).
#   docker build -t refurs-dev3 tests/docker      (once)
#   tests/run.sh [build] [headless] [security] [bench] ...   (no arguments = all of them)
set -eu
REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$HOME/refurs-ref/out/vhr-run}
IMG=${IMG:-refurs-dev3}
# своя копия для Void-Hardened-Refurs: кэш отдельно от исходного RefursWM
CACHE=${CACHE:-vhr-cache}
mkdir -p "$OUT"

dock() { docker run --rm --cap-add SYS_PTRACE -v "$REPO":/src:ro -v "$CACHE":/cache -v "$OUT":/out -w /src "$IMG" sh -c "$1"; }
zbuild() { dock "ZIG_GLOBAL_CACHE_DIR=/cache/global ZIG_LOCAL_PKG_DIR=/cache/pkg zig build --cache-dir /cache/local --prefix /cache/$1 $2"; }

TESTING=/cache/testing/bin/refurswm
EVIL=/cache/tools/bin/evil
[ $# -gt 0 ] || set -- build headless security bench
for step in "$@"; do
	echo "== $step"
	case $step in
	build)
		zbuild testing -Dtesting=true
		zbuild normal ""
		zbuild system "-Dsystem-libs=true -Dtesting=true"
		zbuild tools "evil sandbox-test"
		;;
	headless)
		dock "tests/headless.sh $TESTING /out/headless1; tests/headless2.sh $TESTING /out/headless2; tests/headless3.sh $TESTING /out/headless3"
		;;
	security) dock "tests/security.sh $TESTING /cache/normal/bin/refurswm $EVIL /cache/tools/bin/refurs-sandbox-test /out/security" || true ;;
	bench) dock "tests/bench.sh $TESTING $EVIL /out/bench" ;;
	*) echo "unknown step $step" >&2; exit 2 ;;
	esac
done
