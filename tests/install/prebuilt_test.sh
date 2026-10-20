#!/bin/bash
# The installer on our live image (docs/uni/live-image.md), in a throwaway Void container:
# vh_prebuilt takes the image's programs only when the image is of this commit and every file
# matches SHA256SUMS (1: build here; 2: a file was changed, stop), vh_desktop_variant picks the
# build for the plan's x86-64 level and VH_BLUETOOTH, and build-thor.sh and build-desktop.sh
# --prebuilt install those builds.
#   bash tests/install/prebuilt_test.sh /src   (root, in the vh-dev container: tests/install/run.sh)
set -u
src=${1:?"the repository"}
fails=0
ok() { echo "ok $1"; }
bad() { echo "FAIL $1${2:+: $2}"; fails=$((fails + 1)); }

repo=/tmp/repo
rm -rf "$repo" && cp -a "$src" "$repo" && rm -rf "$repo/.git"
commit=0123456789abcdef0123456789abcdef01234567
echo "$commit" > "$repo/.vh-commit"
. "$repo/thor/UPSTREAM"
arch=$(xbps-uhelper arch)
pkg=thor-$XBPS_VERSION.${THOR_REVISION}_1.$arch.xbps

# a prebuilt tree as live/prebuilt.sh lays it out, with stand-ins for the programs
pre=/usr/local/lib/vh/prebuilt
rm -rf "$pre" && mkdir -p "$pre/bin" "$pre/thor/dest/usr/bin" "$pre/thor/repo"
for p in vh-kconf vh-plan vh-seccomp; do printf '#!/bin/sh\necho %s\n' "$p" > "$pre/bin/$p"; chmod 755 "$pre/bin/$p"; done
printf '#!/bin/sh\necho thor 0.60.7\n' > "$pre/thor/dest/usr/bin/thor"; chmod 755 "$pre/thor/dest/usr/bin/thor"
echo package > "$pre/thor/repo/$pkg"; echo index > "$pre/thor/repo/$arch-repodata"
for v in x86-64-v1-plain x86-64-v1-btmenu x86-64-v3-plain x86-64-v3-btmenu; do
	mkdir -p "$pre/desktop/$v/bin" "$pre/desktop/$v/share/refurswm/libinput"
	for b in refurswm refursline; do printf '#!/bin/sh\necho %s %s\n' "$b" "$v" > "$pre/desktop/$v/bin/$b"; chmod 755 "$pre/desktop/$v/bin/$b"; done
	echo quirks > "$pre/desktop/$v/share/refurswm/libinput/50-system.quirks"
done
echo "COMMIT=$commit" > "$pre/BUILD"
( cd "$pre" && find . -type f ! -name SHA256SUMS | sed 's|^\./||' | sort | xargs sha256sum > SHA256SUMS )
printf 'COMMIT=%s\nKERNEL=linux6.18\n' "$commit" > /etc/vh-live

pb() { ( . "$repo/install/lib.sh"; set +e; d=$(vh_prebuilt 2>/dev/null); echo "$?:$d" ); }

echo "== vh_prebuilt"
r=$(pb); [ "$r" = "0:$pre" ] && ok "our image of this commit: its programs ($r)" || bad "our image of this commit" "$r"
echo fedcba9876543210fedcba9876543210fedcba98 > "$repo/.vh-commit"
r=$(pb); [ "$r" = "1:" ] && ok "another commit: built here (1)" || bad "another commit" "$r"
echo "$commit" > "$repo/.vh-commit"
cp "$pre/bin/vh-plan" /tmp/vh-plan.orig && echo tampered >> "$pre/bin/vh-plan"
r=$(pb); [ "$r" = "2:" ] && ok "a changed file: stop (2)" || bad "a changed file" "$r"
cp /tmp/vh-plan.orig "$pre/bin/vh-plan"
mv /etc/vh-live /tmp/vh-live.away
r=$(pb); [ "$r" = "1:" ] && ok "Void's own image (no /etc/vh-live): built here (1)" || bad "Void's own image" "$r"
mv /tmp/vh-live.away /etc/vh-live

echo "== need_build_ram: building in RAM needs 3 GiB, our image installs in 1.5"
nb() { printf 'MemTotal:       %s kB\n' "$1" > /tmp/meminfo; ( . "$repo/install/lib.sh"; VH_MEMINFO=/tmp/meminfo need_build_ram ) 2>&1; }
r=$(nb 2940928) && ok "2872 MiB (the rig with 3 GiB): builds" || bad "2872 MiB" "$r"
if r=$(nb 1462272); then bad "1428 MiB is refused" "it was not"; else
	case $r in *"1428 MiB"*"needs 3 GiB"*"live image of this commit"*) ok "1428 MiB (the rig with 1.5 GiB): refused, pointing to our image" ;;
	*) bad "1428 MiB: the message" "$r" ;; esac
fi
r=$(VH_MEMINFO=/nonexistent bash -c '. "$1/install/lib.sh"; need_build_ram' _ "$repo" 2>&1) && ok "no meminfo: not refused" || bad "no meminfo" "$r"

echo "== vh_desktop_variant"
dv() { ( . "$repo/install/lib.sh"; VH_PLAN_TAGS=$1 VH_BLUETOOTH=$2 vh_desktop_variant ); }
[ "$(dv 'efi x86-64-v2 x86-64-v3 vm' optional)" = x86-64-v3-btmenu ] && ok "v3, optional: x86-64-v3-btmenu" || bad "v3, optional" "$(dv 'efi x86-64-v2 x86-64-v3 vm' optional)"
[ "$(dv 'efi x86-64-v2' off)" = x86-64-v1-plain ] && ok "v2 CPU, off: x86-64-v1-plain" || bad "v2, off" "$(dv 'efi x86-64-v2' off)"
[ "$(dv 'x86-64-v3 x86-64-v4' on)" = x86-64-v3-plain ] && ok "v4 CPU, on: x86-64-v3-plain" || bad "v4, on" "$(dv 'x86-64-v3 x86-64-v4' on)"

echo "== build-thor.sh --prebuilt"
root=/tmp/root && rm -rf "$root" /tmp/vh-thor /var/lib/thor && mkdir -p "$root"
if out=$(bash "$repo/install/build-thor.sh" --prebuilt "$pre/thor" "$root" 2>&1); then
	[ -f "$root/var/lib/thor/repo/$pkg" ] && [ -x /tmp/vh-thor/dest/usr/bin/thor ] && grep -q '^repository=/var/lib/thor/repo$' "$root/etc/xbps.d/01-thor.conf" \
		&& [ "$(readlink /var/lib/thor/repo)" = "$root/var/lib/thor/repo" ] \
		&& ok "the package in the target's repository, thor for the installation, 01-thor.conf, the live symlink" \
		|| bad "build-thor.sh --prebuilt left" "$(ls -R "$root/var/lib/thor" /tmp/vh-thor 2>&1 | tr '\n' ' ')"
else bad "build-thor.sh --prebuilt" "$out"; fi
r=$(bash "$repo/install/build-thor.sh" --prebuilt /nonexistent "$root" 2>&1) && bad "a missing build is refused" || ok "a missing build is refused"

echo "== build-desktop.sh --prebuilt"
rm -rf "$root" && mkdir -p "$root"
if out=$(VH_CONFIG=/nonexistent bash "$repo/install/build-desktop.sh" --prebuilt "$pre/desktop/x86-64-v3-btmenu" "$root" 2>&1); then
	[ "$("$root/usr/local/bin/refursline")" = "refursline x86-64-v3-btmenu" ] && [ -f "$root/usr/local/share/refurswm/libinput/50-system.quirks" ] \
		&& grep -q "prebuilt $pre/desktop/x86-64-v3-btmenu" "$root/etc/vh/desktop.sha256" \
		&& ok "that variant's RefursWM and RefursLine, the quirks, desktop.sha256" \
		|| bad "build-desktop.sh --prebuilt left" "$(ls -R "$root" | tr '\n' ' ')"
else bad "build-desktop.sh --prebuilt" "$out"; fi

echo
[ "$fails" = 0 ] && echo "prebuilt_test: all checks passed" || echo "prebuilt_test: $fails FAILED"
exit $(( fails > 0 ))
