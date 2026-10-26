#!/bin/sh
# selinux/build.sh: the binary policy and the file contexts from selinux/policy/*.cil.
#   sh selinux/build.sh OUT            -> OUT/policy.33, OUT/file_contexts, OUT/SHA256SUMS, OUT/BUILD
# secilc (libsepol) compiles the CIL and checks every neverallow; it is not in Void's
# repositories, so the compiler runs in a Fedora container (registry.fedoraproject.org/fedora:42,
# secilc from its repositories) unless one is installed here. The output is what the installer
# puts into /etc/vh/selinux and what stage 1 loads (init/src/vhsteps.zig, selinux()).
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
out=${1:?"output directory"}
ver=${VH_POLICY_VERSION:-33}
mkdir -p "$out"
rm -f "$out/policy.$ver" "$out/file_contexts"
if command -v secilc >/dev/null 2>&1; then
	secilc -c "$ver" -O -o "$out/policy.$ver" -f "$out/file_contexts" "$repo"/selinux/policy/*.cil
else
	img=${VH_SELINUX_IMAGE:-registry.fedoraproject.org/fedora:42}
	docker run --rm -v "$repo/selinux/policy:/p:ro" -v "$out:/out" "$img" sh -c "
		set -e
		dnf -q install -y secilc >/dev/null 2>&1 || dnf -q install -y secilc
		secilc -c $ver -O -o /out/policy.$ver -f /out/file_contexts /p/*.cil
		chown $(id -u):$(id -g) /out/policy.$ver /out/file_contexts"
fi
{
	echo "COMMIT=$(git -C "$repo" rev-parse HEAD 2>/dev/null || cat "$repo/.vh-commit" 2>/dev/null || echo unknown)"
	echo "POLICY_VERSION=$ver"
	echo "KERNEL_CLASSMAP=6.18"
	echo "BUILT=$(date -u +%Y-%m-%dT%H:%MZ)"
} > "$out/BUILD"
( cd "$out" && sha256sum "policy.$ver" file_contexts BUILD > SHA256SUMS )
echo "== $(stat -c %s "$out/policy.$ver" 2>/dev/null || stat -f %z "$out/policy.$ver") bytes of policy, $(grep -c . "$out/file_contexts") file contexts"
