#!/bin/bash
# The gaming kernel built as vh-game kernel build builds it on a machine (docs/uni/game.md, G3b),
# in a throwaway privileged Void container whose own root plays the installed system
# (.github/workflows/game-kernel.yml starts it):
#   1. the system as far as the build reads it: the machine's hw.zon and plan, the repository
#      copy in /root/vh, vh-kconf, sbctl's keys directory, /var/lib/vh root's alone;
#   2. vh-game key new with a passphrase of this run alone (the kernel trusts its certificate);
#   3. vh-game kernel build, thor's stand-in xbps-install for the build root;
#   4. the kernel's files checked (SHA256SUMS, BUILD, the release, the gaming invariants) and
#      copied to OUT, with the certificate; the build root and the work directory are gone.
#   bash tests/session/kbuild.sh REPO HW.ZON PLAN.ZON OUT
set -u
src=${1:?"the repository copy"} hw=${2:?"hw.zon"} plan=${3:?"plan.zon"} out=${4:?"the output directory"}
fails=0
ok() { echo "ok $1"; }
bad() { echo "FAIL $1${2:+: $2}"; fails=$((fails + 1)); }

case $(xbps-uhelper arch) in x86_64) repo=https://repo-default.voidlinux.org/current ;; *) echo "the gaming kernel is built on x86_64" >&2; exit 2 ;; esac
echo "== the system"
install -d -m 0755 /etc/vh /etc/xbps.d /usr/local/sbin /root/vh
install -d -m 0700 /var/lib/vh /var/lib/sbctl /var/lib/sbctl/keys
cp "$src/$hw" /etc/vh/hw.zon
cp "$plan" /etc/vh/plan.zon
cp -a "$src/hwdb" "$src/vh.conf.example" /root/vh/
install -d /root/vh/kernel && cp -a "$src/kernel/pins" "$src/kernel/profiles" /root/vh/kernel/
printf 'repository=%s\n' "$repo" > /etc/xbps.d/00-repository-main.conf
install -m 0755 "$src/build/st/bin/vh-game" "$src/build/st/bin/vh-root" /usr/local/sbin/
install -m 0755 "$src/build/kt/bin/vh-kconf" /usr/local/sbin/
command -v xbps-fetch >/dev/null || { echo "no xbps-fetch" >&2; exit 2; }
mkdir -p /tmp/stub
cat > /tmp/stub/thor <<'EOF'
#!/bin/sh
# thor's arguments (install|update -y -r ROOT [PKG...]) for xbps-install; the root's xbps.d applies
cmd=$1; shift
[ "$1" = -y ] && shift
[ "$1" = -r ] || exit 2
root=$2; shift 2
[ "$cmd" = update ] && exec xbps-install -Syu -r "$root"
exec xbps-install -Sy -r "$root" "$@"
EOF
chmod 0755 /tmp/stub/thor

echo "== vh-game key new"
pass=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
printf '%s\n' "$pass" | vh-game key new --password-stdin --thor /tmp/stub/thor > /tmp/key.out 2>&1 \
	&& ok "vh-game key new" || { bad "key new" "$(tail -5 /tmp/key.out | tr '\n' '|')"; exit 1; }

echo "== vh-game kernel build"
# the system's compilers before the build (this image may have some): the build adds none
tools_before=$(ls /usr/bin/clang* /usr/bin/make /usr/bin/perl 2>/dev/null)
start=$(date +%s)
vh-game kernel build --thor /tmp/stub/thor 2>&1 | tee /tmp/build.out | grep -E '^(vh-game|vh-root|VH_GAME|  CC|  LD|  BTF)' | grep -vE '^  CC' | tail -40
built=$(sed -n 's/^VH_GAME kernel built=//p' /tmp/build.out)
[ -n "$built" ] && ok "vh-game kernel build ($(( ($(date +%s) - start) / 60 )) min): $built" || { bad "kernel build" "$(grep -iE 'error|vh-game:|refus' /tmp/build.out | tail -20 | tr '\n' '|')"; exit 1; }
cd "$built" || exit 1
sha256sum -c --quiet SHA256SUMS && ok "SHA256SUMS" || bad "SHA256SUMS"
grep -q '^kernel-custom local: linux-[0-9.]*, features auto,game, commit vh-game' BUILD && ok "BUILD" || bad "BUILD" "$(head -2 BUILD)"
kver=$(sed -n 's/^kernel-custom local: linux-\([0-9.]*\),.*/\1/p' BUILD)
grep -aq "$kver-vh-game (" "bzImage-vh-$kver" && ok "the bzImage reports $kver-vh-game" || bad "the release" "$(grep -aoE '[0-9]+\.[0-9]+\.[0-9]+-vh[a-z-]* \(' "bzImage-vh-$kver" | head -1)"
for want in CONFIG_IA32_EMULATION=y CONFIG_MODULES=y CONFIG_MODULE_SIG_FORCE=y 'CONFIG_MODULE_SIG_KEY="certs/vh-game.pem"' 'CONFIG_LOCALVERSION="-vh-game"' \
	CONFIG_LOCK_DOWN_KERNEL_FORCE_CONFIDENTIALITY=y CONFIG_CFI=y CONFIG_NTSYNC=y '# CONFIG_MODULE_UNLOAD is not set'; do
	grep -qxF "$want" "config-vh-$kver" || bad "the configuration: $want"
done
ok "the gaming kernel's configuration"
[ -s "Module.symvers-vh-$kver" ] && ok "Module.symvers (for the NVIDIA modules)" || bad "no Module.symvers"
[ ! -e /var/lib/vh/roots/kbuild ] && [ ! -e /var/lib/vh/kbuild ] && [ ! -e /var/lib/vh/roots/keys ] && ok "no build root, no tree, no OpenSSL root after the build" || bad "something of the build stays" "$(ls /var/lib/vh /var/lib/vh/roots 2>&1 | tr '\n' ' ')"
[ "$(ls /usr/bin/clang* /usr/bin/make /usr/bin/perl 2>/dev/null)" = "$tools_before" ] && ok "no compiler came to the system" || bad "the system's tools changed" "$(ls /usr/bin/clang* /usr/bin/make /usr/bin/perl 2>/dev/null | tr '\n' ' ')"
mkdir -p "$out" && cp -a . "$out/" && cp /var/lib/sbctl/keys/vh-game/module.crt "$out/module.crt"
du -sh "$built" | sed 's/^/size of the kernel'"'"'s files: /'

[ "$fails" = 0 ] && echo "kbuild: all checks passed" || echo "kbuild: $fails check(s) failed"
exit $((fails > 0))
