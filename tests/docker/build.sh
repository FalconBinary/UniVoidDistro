#!/bin/sh
# The vh-dev test image: Zig for Linux of the native architecture (minisign signature plus
# the file name in the signed comment, as in install/fetch-zig.sh) and the Void headers.
#   sh tests/docker/build.sh [x86_64|aarch64]   -> prints the image name
# Default: the native architecture (no emulation); x86_64 on a Mac is for builds for the VM bench.
set -eu
repo=$(cd "$(dirname "$0")/../.." && pwd)
ver=$(cat "$repo/zig/ZIG_VERSION")
case ${1:-$(uname -m)} in arm64|aarch64) a=aarch64 plat=linux/arm64 ;; *) a=x86_64 plat=linux/amd64 ;; esac
img=vh-dev:$a-$ver
if docker image inspect "$img" >/dev/null 2>&1; then echo "$img"; exit 0; fi
key=RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U
ctx=$repo/build/docker-ctx
mkdir -p "$ctx"
t=zig-$a-linux-$ver.tar.xz
[ -f "$ctx/$t" ] || curl -fsSL -o "$ctx/$t" "https://ziglang.org/download/$ver/$t"
curl -fsSL -o "$ctx/$t.minisig" "https://ziglang.org/download/$ver/$t.minisig"
minisign -Vm "$ctx/$t" -P "$key" >&2
grep -q "^trusted comment: .*file:$t[[:space:]]" "$ctx/$t.minisig"
cp "$repo/tests/docker/Dockerfile" "$ctx/"
# the base image of the wanted architecture (an old docker builder would otherwise reuse the one already pulled)
docker pull -q --platform "$plat" ghcr.io/void-linux/void-glibc-full:latest >&2
docker build -q --platform "$plat" --build-arg ZIG_TARBALL="$t" -t "$img" "$ctx" >&2
echo "$img"
