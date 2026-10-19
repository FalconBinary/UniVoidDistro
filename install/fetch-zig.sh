#!/bin/bash
# The Zig compiler for building in the live environment's RAM (RefursWM and RefursLine,
# thor, the zig/ tools).
#   ZIG=$(install/fetch-zig.sh VERSION DIR)   -- path to zig on stdout, messages on stderr
#
# The Zig in the Void repository is old, and the installed system must not contain a
# compiler (docs/05). The archive is downloaded from ziglang.org into DIR (the live
# environment's tmpfs) and checked twice: with the minisign signature of the Zig key
# (including the file name in the signed comment, otherwise any other signed archive, say
# an old version, would pass) and with the checksum stored here.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
VER=${1:?"Zig version, for example 0.17.0"}
DIR=${2:?"directory for the compiler (in RAM)"}

# Zig release signing key, published at https://ziglang.org/download/.
# Verify it through a second independent channel (docs/08) before trusting it.
ZIG_PUBKEY="RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U"
# Checksums (from https://ziglang.org/download/index.json, verified against the minisign
# signature). aarch64 is only for the container tests on Apple Silicon.
declare -A ZIG_SHA256=(
	[0.16.0-x86_64]=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00
	[0.17.0-x86_64]=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026
	[0.17.0-aarch64]=9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8
)
ARCH=$(uname -m)

# the live image has neither xz (the Zig archive is .tar.xz) nor minisign: installed into RAM.
# Its xbps is older than the repositories', and xbps refuses every other package until it
# has updated itself: so xbps first, as 10-install.sh does
missing=
for t in minisign xz; do
	command -v "$t" >/dev/null || missing="$missing $t"
done
if [ -n "$missing" ]; then
	xbps-install -Syu xbps >/dev/null || die "could not update xbps in the live environment"
	xbps-install -Sy $missing >/dev/null || die "could not install$missing into the live environment"
fi

tarball=zig-$ARCH-linux-$VER.tar.xz
zig=$DIR/zig-$ARCH-linux-$VER/zig
if [ -x "$zig" ]; then
	echo "$zig"
	exit 0
fi
mkdir -p "$DIR"
cd "$DIR"
url=https://ziglang.org/download/$VER/$tarball
say "Zig $VER: downloading and checking the signature" >&2
xbps-fetch -o "$tarball" "$url" >&2
xbps-fetch -o "$tarball.minisig" "$url.minisig" >&2
minisign -Vm "$tarball" -x "$tarball.minisig" -P "$ZIG_PUBKEY" >&2 || die "the Zig signature does not verify"
grep -q "^trusted comment: .*file:$tarball[[:space:]]" "$tarball.minisig" \
	|| die "the Zig signature was issued for another file, not $tarball"
if [ -n "${ZIG_SHA256[$VER-$ARCH]:-}" ]; then
	echo "${ZIG_SHA256[$VER-$ARCH]}  $tarball" | sha256sum -c - >&2 || die "the Zig checksum does not match"
else
	warn "no stored checksum for Zig $VER: only the signature was checked"
fi
tar -xJf "$tarball"
rm -f "$tarball"
"$zig" version >/dev/null || die "zig $VER does not run"
echo "$zig"
