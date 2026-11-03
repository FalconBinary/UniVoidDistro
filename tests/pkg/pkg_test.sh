#!/bin/bash
# The own packages (pkg/build.sh, docs/uni/rolling.md) in a throwaway Void container: stand-ins
# for the built programs, the packages of two versions, then an installation into an empty root
# over the files an installation of v0.2.0 left without an owner, an update, the switch of the
# desktop's build, and the split of rootfs/ between the packages and the installer.
#   bash tests/pkg/pkg_test.sh /src   (root, in the vh-dev container: tests/pkg/run.sh)
set -u
src=${1:?"the repository"}
fails=0
ok() { echo "ok $1"; }
bad() { echo "FAIL $1${2:+: $2}"; fails=$((fails + 1)); }
arch=$(xbps-uhelper arch)
export XBPS_BIN=/usr/bin SOURCE_DATE_EPOCH=1767225600
w=/tmp/pkgt
rm -rf "$w" && mkdir -p "$w"

# prebuilt N: a tree as live/prebuilt.sh lays it out, with stand-ins that print N
prebuilt() {
	local p=$w/pre$1 n v
	rm -rf "$p" && mkdir -p "$p/bin" "$p/thor/repo" "$p/selinux"
	for n in $(grep -v '^[[:space:]]*\(#\|$\)' "$src/pkg/tools.map" | awk '{print $2}' | sort -u); do
		printf '#!/bin/sh\necho %s %s\n' "$n" "$1" > "$p/bin/$n"; chmod 755 "$p/bin/$n"
	done
	echo "bpf $1" > "$p/bin/vh_sched.o"
	for v in x86-64-v1-plain x86-64-v3-btmenu; do
		mkdir -p "$p/desktop/$v/bin" "$p/desktop/$v/share/refurswm/libinput"
		for n in refurswm refursline; do printf '#!/bin/sh\necho %s %s %s\n' "$n" "$v" "$1" > "$p/desktop/$v/bin/$n"; chmod 755 "$p/desktop/$v/bin/$n"; done
		echo quirks > "$p/desktop/$v/share/refurswm/libinput/50-system.quirks"
	done
	for n in policy.35 file_contexts BUILD SHA256SUMS; do echo "$n $1" > "$p/selinux/$n"; done
	# thor: a stand-in package of the name thor/package.sh gives
	. "$src/thor/UPSTREAM"
	mkdir -p "$w/thor/usr/bin" && printf '#!/bin/sh\necho thor\n' > "$w/thor/usr/bin/thor" && chmod 755 "$w/thor/usr/bin/thor"
	( cd "$p/thor/repo" && xbps-create -q -A "$arch" -n "thor-$XBPS_VERSION.${THOR_REVISION}_1" -s thor "$w/thor" )
	echo "$p"
}

# the libraries RefursWM needs, as empty packages: the dependencies resolve inside the test repository
mkdir -p "$w/stub" "$w/repo"
for n in seatd wayland libxkbcommon pixman libdrm libgbm libglvnd eudev-libudev libdisplay-info libevdev mtdev xkeyboard-config; do
	( cd "$w/repo" && xbps-create -q -A "$arch" -n "$n-1.0_1" -s stub "$w/stub" )
done
xbps-rindex -a "$w"/repo/*.xbps >/dev/null

echo "== pkg/build.sh"
p1=$(prebuilt 1)
if VH_PKG_VERSION=0.2.0.r1 sh "$src/pkg/build.sh" "$p1" "$arch" "$w/repo" > "$w/made1" 2> "$w/err1"; then
	ok "packages of 0.2.0.r1: $(wc -l < "$w/made1")"
else
	bad "pkg/build.sh" "$(tail -5 "$w/err1")"
fi
for n in thor vh-tools vh-init vh-sched vh-session vh-desktop-x86-64-v1-plain vh-desktop-x86-64-v3-btmenu vh-selinux-policy vh-data vh-installer vh-base vh-etc univoid; do
	xbps-query -i --repository="$w/repo" "$n" >/dev/null 2>&1 && ok "in the index: $n" || bad "not in the index: $n"
done
# the same sources make the same packages (the times are SOURCE_DATE_EPOCH's)
mkdir -p "$w/again"
VH_PKG_VERSION=0.2.0.r1 sh "$src/pkg/build.sh" "$p1" "$arch" "$w/again" >/dev/null 2>&1
for f in "$w"/again/vh-*.xbps "$w"/again/univoid-*.xbps; do
	cmp -s "$f" "$w/repo/$(basename "$f")" || bad "not reproducible: $(basename "$f")"
done
ok "a second build of the same tree: byte for byte the same packages"

echo "== rootfs/: every file is a package's or the installer's, never both"
files() { xbps-query -i --repository="$w/repo" -f "$1" | sed 's/ -> .*//'; }
files vh-etc > "$w/etc.list"; files vh-base > "$w/base.list"
( cd "$src/rootfs" && find . \( -type f -o -type l \) | sed 's|^\.||' | LC_ALL=C sort ) > "$w/rootfs.list"
grep -v '^[[:space:]]*\(#\|$\)' "$src/pkg/installer-owned" > "$w/owned.list"
while read -r f; do
	n=0
	grep -qxF "$f" "$w/etc.list" && n=$((n + 1))
	grep -qxF "$f" "$w/base.list" && n=$((n + 1))
	case $f in *.in|*.cin) n=$((n + 1)) ;; esac
	grep -qxF "$f" "$w/owned.list" && n=$((n + 1))
	[ "$n" = 1 ] || bad "rootfs$f: in $n places (vh-etc, vh-base, a template, installer-owned)"
done < "$w/rootfs.list"
while read -r f; do grep -qxF "$f" "$w/rootfs.list" || bad "pkg/installer-owned: $f is not in rootfs/"; done < "$w/owned.list"
ok "the split of $(wc -l < "$w/rootfs.list") files of rootfs/"
# the entry points thor's policy would not extract are exactly pkg/thor-keep
grep -E '^/etc/(kernel\.d/|bash/bashrc\.d/|profile\.d/.*\.sh$)' "$w/etc.list" | LC_ALL=C sort > "$w/entry.list"
grep -v '^[[:space:]]*\(#\|$\)' "$src/pkg/thor-keep" | LC_ALL=C sort > "$w/keep.list"
cmp -s "$w/entry.list" "$w/keep.list" && ok "pkg/thor-keep is vh-etc's entry points" || bad "pkg/thor-keep" "$(diff "$w/keep.list" "$w/entry.list" | tr '\n' ' ')"
# conf_files: what is not a program
xbps-query -i --repository="$w/repo" -p conf_files vh-etc | LC_ALL=C sort > "$w/conf.list"
grep -qxF /etc/vh/firefox/policies-trusted.json "$w/conf.list" && ! grep -q '^/etc/kernel.d/' "$w/conf.list" \
	&& ok "conf_files: $(wc -l < "$w/conf.list") files, the programs (hooks, run scripts) not among them" || bad "conf_files" "$(head -3 "$w/conf.list" | tr '\n' ' ')"

echo "== installation over the files of an installation of v0.2.0 (no owner)"
r=$w/root
mkdir -p "$r/var/db/xbps" "$r/usr/local/sbin" "$r/etc/vh/firefox"
echo old > "$r/usr/local/sbin/vh-init"
cp "$src/rootfs/etc/vh/firefox/policies-trusted.json" "$r/etc/vh/firefox/"
if xbps-install -r "$r" -R "$w/repo" -Sy univoid vh-desktop-x86-64-v1-plain > "$w/inst.log" 2>&1; then
	ok "xbps-install univoid vh-desktop-x86-64-v1-plain"
else
	bad "xbps-install" "$(tail -5 "$w/inst.log")"
fi
[ "$(sh "$r/usr/local/sbin/vh-init" 2>&1)" = "vh-init 1" ] && ok "vh-init replaced" || bad "vh-init" "$(cat "$r/usr/local/sbin/vh-init")"
xbps-query -r "$r" -o /usr/local/sbin/vh-init | grep -q '^vh-init-0.2.0.r1_1:' && ok "vh-init owned by vh-init" || bad "owner of vh-init" "$(xbps-query -r "$r" -o /usr/local/sbin/vh-init)"
[ -e "$r/etc/vh/firefox/policies-trusted.json.new-0.2.0.r1_1" ] && ok "an unowned conf file stays, the package's goes next to it (vh-update --adopt removes identical ones)" || bad "conf over an unowned file"
st=$(stat -c '%U:%G %a' "$r/root/vh" "$r/root/vh/kernel" "$r/usr/local/sbin/vh-update" | tr '\n' ' ')
[ "$st" = "root:root 700 root:root 700 root:root 755 " ] && ok "owners and modes: $st" || bad "owners and modes" "$st"
for f in /usr/local/lib/vh/vh_sched.o /root/vh/hwdb/gpu.zon /root/vh/install/10-install.sh /etc/vh/desktop.sha256 /etc/vh/selinux/file_contexts; do
	[ -e "$r$f" ] || { [ "$f" = /etc/vh/selinux/file_contexts ] && continue; bad "missing $f"; }
done
[ -e "$r/etc/vh/selinux/file_contexts" ] && bad "vh-selinux-policy came without asking" || ok "vh-selinux-policy only on request"
for f in /etc/vh/vh.env /etc/doas.conf /etc/vh/acpi.conf /etc/pam.d/system-login; do
	[ -e "$r$f" ] && bad "a package brought $f (the installer's)"
done
ok "no template and no installer-owned file in the packages"

echo "== update to 0.2.0.r2"
echo edited > "$r/etc/vh/services/README"
install -D -m 0755 /dev/null "$r/usr/local/sbin/vh-deadman"    # optional/deadman enabled
p2=$(prebuilt 2)
echo "# changed in 0.2.0.r2" >> "$src/rootfs/etc/vh/services/README"
VH_PKG_VERSION=0.2.0.r2 sh "$src/pkg/build.sh" "$p2" "$arch" "$w/repo" > /dev/null 2> "$w/err2" || bad "pkg/build.sh 0.2.0.r2" "$(tail -3 "$w/err2")"
if xbps-install -r "$r" -R "$w/repo" -Syu > "$w/up.log" 2>&1; then ok "xbps-install -u"; else bad "xbps-install -u" "$(tail -5 "$w/up.log")"; fi
[ "$(sh "$r/usr/local/sbin/vh-init")" = "vh-init 2" ] && ok "vh-init updated" || bad "vh-init not updated"
[ "$(sh "$r/usr/local/sbin/vh-deadman")" = "vh-deadman 2" ] && ok "the enabled module's copy updated (INSTALL)" || bad "module copy" "$(cat "$r/usr/local/sbin/vh-deadman")"
[ ! -e "$r/usr/local/sbin/vh-uki-verify" ] && ok "a module not enabled gets no copy" || bad "copy of a module not enabled"
[ "$(cat "$r/etc/vh/services/README")" = edited ] && [ -e "$r/etc/vh/services/README.new-0.2.0.r2_1" ] && ok "an edited conf file stays, the new one next to it" || bad "edited conf"
grep -q 'x86-64-v1-plain 2' "$r/usr/local/bin/refurswm" && ok "the desktop updated" || bad "desktop" "$(cat "$r/usr/local/bin/refurswm")"

echo "== the desktop's build: another plan, another package"
if xbps-install -r "$r" -R "$w/repo" -y vh-desktop-x86-64-v3-btmenu > "$w/sw.log" 2>&1; then ok "install vh-desktop-x86-64-v3-btmenu"; else bad "switch" "$(tail -5 "$w/sw.log")"; fi
xbps-query -r "$r" vh-desktop-x86-64-v1-plain >/dev/null 2>&1 && bad "v1-plain still installed" || ok "it replaced vh-desktop-x86-64-v1-plain"
grep -q 'x86-64-v3-btmenu 2' "$r/usr/local/bin/refurswm" && ok "refurswm is v3-btmenu's" || bad "refurswm" "$(cat "$r/usr/local/bin/refurswm")"

echo
[ "$fails" = 0 ] && echo "pkg: every check passed" || echo "pkg: $fails checks failed"
exit "$fails"
