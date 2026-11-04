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

echo "== no path of vh-etc or vh-base belongs to a package of Void (xbps refuses two owners)"
void=https://repo-default.voidlinux.org/current
case $arch in aarch64*) void=$void/aarch64 ;; esac
names=$(. "$src/install/lib.sh"; . "$src/install/packages.sh"; VH_KERNEL=linux6.18; vh_packages 2>/dev/null | grep -vE '^(thor|univoid|vh-.*)$'; echo dhcpcd iwd bluez tpm2-tools)
cat "$w/etc.list" "$w/base.list" | LC_ALL=C sort > "$w/ours.list"
seen=0 clash=0
for n in $names; do
	xbps-query -i --repository="$void" -f "$n" 2>/dev/null | sed 's/ -> .*//' | LC_ALL=C sort > "$w/void.list"
	[ -s "$w/void.list" ] && seen=$((seen + 1))
	c=$(comm -12 "$w/void.list" "$w/ours.list")
	[ -z "$c" ] || { clash=$((clash + 1)); bad "$n owns $(echo "$c" | tr '\n' ' ')"; }
done
[ "$seen" -gt 40 ] && [ "$clash" = 0 ] && ok "$seen packages of Void read, no path in common" || bad "only $seen packages of Void read, $clash with a path of ours"

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

echo "== the installer's part of rootfs/ (install_tree ... installer), the identical .new files"
ir=$w/iroot
( . "$src/install/lib.sh"; DRY_RUN=0 VH_TEST=1; set -a; . "$src/vh.conf.example"; VH_EFI_ARCH=x VH_REPO_SUB= VH_CMDLINE=c VH_DOT_IPS=d VH_UNBOUND_FORWARDS=f VH_CHRONY_SERVERS=s VH_SHM_SIZE=1 VH_UNBOUND_AAAA= VH_DRACUT_DRIVERS=d VH_LUKS_UUID=l VH_ROOT_UUID=r VH_ESP_UUID=e; set +a; install_tree "$src/rootfs" "$ir" installer ) > "$w/tree.log" 2>&1 || bad "install_tree installer" "$(tail -3 "$w/tree.log")"
( cd "$ir" && find . \( -type f -o -type l \) | sed 's|^\.||' | LC_ALL=C sort ) > "$w/tree.list"
{ grep -E '\.in$' "$w/rootfs.list" | sed 's/\.in$//'; cat "$w/owned.list"; } | LC_ALL=C sort > "$w/tree.want"
cmp -s "$w/tree.list" "$w/tree.want" && ok "install_tree installer: the templates and pkg/installer-owned, $(wc -l < "$w/tree.list") files" \
	|| bad "install_tree installer" "$(diff "$w/tree.want" "$w/tree.list" | head -5 | tr '\n' ' ')"
mkdir -p "$w/nr/etc/a"; echo same > "$w/nr/etc/a/f"; echo same > "$w/nr/etc/a/f.new-1_1"; echo other > "$w/nr/etc/a/f.new-2_1"
( . "$src/install/lib.sh"; new_identical "$w/nr" ) >/dev/null 2>&1
[ ! -e "$w/nr/etc/a/f.new-1_1" ] && [ -e "$w/nr/etc/a/f.new-2_1" ] && ok "new_identical: the same copy goes, another stays" || bad "new_identical"

echo "== a publication: what changed against the published set, signed, served over HTTP"
pub=$w/pub
mkdir -p "$pub" "$w/keys"
openssl genrsa -out "$w/keys/a.pem" 4096 2>/dev/null; openssl genrsa -out "$w/keys/b.pem" 4096 2>/dev/null
# the first publication: everything
p3=$w/pre3; cp -a "$p2" "$p3"
n3=$w/n3
VH_PKG_VERSION=0.2.0.r3 VH_PKG_REVISION=10 VH_PKG_STAMP=202611010000 sh "$src/pkg/build.sh" "$p3" "$arch" "$n3" >/dev/null 2>"$w/err3" || bad "pkg/build.sh r3" "$(tail -3 "$w/err3")"
XBPS_BIN=/usr/bin sh "$src/pkg/merge.sh" "$n3" "$arch" /nonexistent "$pub" > "$w/m3.log" 2>&1 || bad "merge, the first" "$(tail -3 "$w/m3.log")"
[ -s "$pub/$arch-repodata" ] && [ ! -s "$pub/$arch-kept" ] && ok "the first publication: every package, nothing kept" || bad "the first publication" "$(wc -l < "$pub/$arch-kept") kept"
for f in "$w"/repo/seatd-*.xbps "$w"/repo/wayland-*.xbps "$w"/repo/lib*.xbps "$w"/repo/pixman-*.xbps "$w"/repo/eudev-*.xbps "$w"/repo/mtdev-*.xbps "$w"/repo/xkeyboard-*.xbps; do cp "$f" "$pub/"; done
( cd "$pub" && xbps-rindex -a seatd-*.xbps wayland-*.xbps lib*.xbps pixman-*.xbps eudev-*.xbps mtdev-*.xbps xkeyboard-*.xbps >/dev/null )
sh "$src/pkg/sign.sh" "$pub" "$w/keys/a.pem" "CI" > "$w/s3.log" 2>&1 && ok "signed: $(cat "$w/s3.log")" || bad "pkg/sign.sh" "$(tail -3 "$w/s3.log")"
# a build of the same programs with one changed: only that one, and univoid, get new versions
p4=$w/pre4; cp -a "$p3" "$p4"; printf '#!/bin/sh\necho vh-init 4\n' > "$p4/bin/vh-init"
n4=$w/n4; st4=$w/st4
VH_PKG_VERSION=0.2.0.r4 VH_PKG_REVISION=11 VH_PKG_STAMP=202001020300 sh "$src/pkg/build.sh" "$p4" "$arch" "$n4" >/dev/null 2>"$w/err4" || bad "pkg/build.sh r4" "$(tail -3 "$w/err4")"
XBPS_BIN=/usr/bin sh "$src/pkg/merge.sh" "$n4" "$arch" "$pub" "$st4" > "$w/m4.log" 2>&1 || bad "merge" "$(tail -3 "$w/m4.log")"
got=$(cd "$st4" && ls *.xbps | sed 's/-[^-]*$//' | LC_ALL=C sort | tr '\n' ' ')
[ "$got" = "univoid vh-init " ] && ok "the second publication: only vh-init and univoid are new" || bad "the second publication" "$got"
grep -q "^vh-tools-0.2.0.r3_10.$arch.xbps$" "$st4/$arch-kept" && ok "vh-tools stays at its published version" || bad "kept" "$(head -3 "$st4/$arch-kept" | tr '\n' ' ')"
sh "$src/pkg/sign.sh" "$st4" "$w/keys/a.pem" "CI" >/dev/null 2>&1 || bad "pkg/sign.sh second"
cp "$st4"/*.xbps "$st4"/*.sig2 "$st4/$arch-repodata" "$st4/$arch-contents" "$pub/"
( cd "$pub" && exec python3 -m http.server 8321 --bind 127.0.0.1 >/dev/null 2>&1 ) &
srv=$!
sleep 1
U=http://127.0.0.1:8321
# the public key as xbps names it, taken at a yes
kr=$w/kroot; mkdir -p "$kr/var/db/xbps/keys"
yes | xbps-install -r "$kr" -R "$U" -S >/dev/null 2>&1
ls "$kr"/var/db/xbps/keys/*.plist >/dev/null 2>&1 && ok "the key's file: $(basename "$kr"/var/db/xbps/keys/*.plist)" || bad "no key imported"
c=$w/client; mkdir -p "$c/var/db/xbps/keys"
if xbps-install -r "$c" -R "$U" -Sy univoid vh-desktop-x86-64-v3-btmenu </dev/null > "$w/c0.log" 2>&1; then
	bad "a repository of an unknown key was used with stdin closed"
else
	grep -q 'Failed to import pubkey' "$w/c0.log" && ok "an unknown key, stdin closed: refused" || bad "unknown key" "$(tail -3 "$w/c0.log")"
fi
cp "$kr"/var/db/xbps/keys/*.plist "$c/var/db/xbps/keys/"
xbps-install -r "$c" -R "$U" -Sy univoid vh-desktop-x86-64-v3-btmenu </dev/null > "$w/c1.log" 2>&1 && ok "the known key: installed, every signature checked" || bad "signed install" "$(tail -5 "$w/c1.log")"
[ "$(sh "$c/usr/local/sbin/vh-init")" = "vh-init 4" ] && ok "vh-init is the second publication's" || bad "vh-init" "$(cat "$c/usr/local/sbin/vh-init")"
xbps-query -r "$c" -p pkgver vh-tools | grep -q 'r3_10' && ok "vh-tools the first's" || bad "vh-tools version"
# a package changed on the server: its signature no longer matches
vt=$(ls "$pub"/vh-sched-*.xbps | head -1)
cp "$vt" "$w/vt.good"; printf x >> "$vt"
c2=$w/client2; mkdir -p "$c2/var/db/xbps/keys"; cp "$kr"/var/db/xbps/keys/*.plist "$c2/var/db/xbps/keys/"
if xbps-install -r "$c2" -R "$U" -Sy vh-sched </dev/null > "$w/c2.log" 2>&1; then bad "a changed package was installed"; else ok "a changed package: refused"; fi
cp "$w/vt.good" "$vt"
# stable: the same files, every signature the other key's; a system that trusts only that key
sh "$src/pkg/sign.sh" "$pub" "$w/keys/b.pem" "stable" --all > "$w/s5.log" 2>&1 || bad "sign --all" "$(tail -3 "$w/s5.log")"
c3=$w/client3; mkdir -p "$c3/var/db/xbps/keys"
cp "$kr"/var/db/xbps/keys/*.plist "$c3/var/db/xbps/keys/"
if xbps-install -r "$c3" -R "$U" -Sy vh-sched </dev/null > "$w/c3.log" 2>&1; then bad "the rolling key's system took the stable key's index"; else ok "a system of the other key refuses the index"; fi
rm -f "$c3"/var/db/xbps/keys/*.plist
kr2=$w/kroot2; mkdir -p "$kr2/var/db/xbps/keys"; yes | xbps-install -r "$kr2" -R "$U" -S >/dev/null 2>&1
cp "$kr2"/var/db/xbps/keys/*.plist "$c3/var/db/xbps/keys/"
xbps-install -r "$c3" -R "$U" -Sy vh-sched </dev/null > "$w/c4.log" 2>&1 && ok "signed again by the stable key: its system installs" || bad "stable install" "$(tail -5 "$w/c4.log")"
kill "$srv" 2>/dev/null

echo "== thor's policy on our packages (a real thor, enforce)"
if bash "$src/install/build-thor.sh" --out "$w/realthor" > "$w/thor.log" 2>&1; then
	T=$w/realthor/dest/usr/bin
	ok "thor built"
	# inst ROOT KEEP: univoid and a desktop into an empty root, enforce, with or without the keep list
	inst() {
		mkdir -p "$1/var/db/xbps" "$1/etc/thor"
		printf 'mode=enforce\n' > "$1/etc/thor/policy.conf"
		[ "$2" = no ] || grep -v '^[[:space:]]*\(#\|$\)' "$src/pkg/thor-keep" > "$1/etc/thor/keep.conf"
		"$T/xbps-install" -r "$1" -R "$w/repo" -Sy univoid vh-desktop-x86-64-v3-btmenu > "$1.log" 2>&1
	}
	inst "$w/tk" yes && ok "installed in enforce, pkg/thor-keep in keep.conf" || bad "thor install with keep" "$(tail -5 "$w/tk.log")"
	miss=0
	while read -r f; do [ -e "$w/tk$f" ] || miss=$((miss + 1)); done < "$w/keep.list"
	[ "$miss" = 0 ] && ok "every hook and the login script extracted" || bad "$miss entry points not extracted" "$(grep -m3 'not extracted' "$w/tk.log" | tr '\n' ' ')"
	[ -z "$(find "$w/tk" -type f -perm /6000)" ] && ok "no SUID or SGID file" || bad "SUID" "$(find "$w/tk" -type f -perm /6000 | head -3)"
	inst "$w/tn" no && ok "installed in enforce without the list" || bad "thor install without keep" "$(tail -5 "$w/tn.log")"
	[ ! -e "$w/tn/etc/kernel.d/post-install/90-vh-uki" ] && grep -q 'not extracted' "$w/tn.log" && ok "without the list the policy holds the hooks back" || bad "the policy let a hook through" "$(grep -c 'not extracted' "$w/tn.log")"
else
	bad "build-thor.sh --out" "$(tail -5 "$w/thor.log")"
fi

echo "== vh-update: the channel, this container as the system"
if [ -x "${T:-}/thor" ]; then
	# the real thor as the system's, of a revision above the stand-in in the published set
	VH_PKG_REVISION=999 bash "$src/install/build-thor.sh" --out "$w/rt2" > "$w/thor2.log" 2>&1 || bad "thor revision 999" "$(tail -3 "$w/thor2.log")"
	yes | xbps-install -R "$w/rt2/repo" -Sy thor > "$w/thor3.log" 2>&1 || bad "the real thor" "$(tail -3 "$w/thor3.log")"
	( cd "$pub" && exec python3 -m http.server 8321 --bind 127.0.0.1 >/dev/null 2>&1 ) &
	srv=$!
	sleep 1
	# this container's system: only the published set as a repository, the key dirs vh-keyring brings
	find /etc/xbps.d /usr/share/xbps.d -name '*repository*' -delete
	mkdir -p /etc/vh /etc/thor /usr/local/sbin /usr/local/libexec/vh /usr/local/share/vh/keys/stable /usr/local/share/vh/keys/rolling
	printf 'mode=enforce\n' > /etc/thor/policy.conf
	printf 'stable=%s\nrolling=%s\n' "$U" "$U" > /etc/vh/channels.conf
	printf 'VH_KERNEL=linux6.18\n' > /etc/vh/vh.env
	cp "$kr"/var/db/xbps/keys/*.plist /usr/local/share/vh/keys/rolling/
	cp "$kr2"/var/db/xbps/keys/*.plist /usr/local/share/vh/keys/stable/
	printf '#!/bin/sh\nexit 0\n' > /usr/local/libexec/vh/vh-sv-runstate
	printf '#!/bin/sh\nexit 0\n' > /usr/local/sbin/vh-suid-strip
	chmod 755 /usr/local/libexec/vh/vh-sv-runstate /usr/local/sbin/vh-suid-strip
	install -m 0755 "$src/rootfs/usr/local/sbin/vh-update" /usr/local/sbin/vh-update
	yes | xbps-install -Sy >/dev/null 2>&1   # no channel yet: nothing to fetch
	# the published set is signed by the stable key now
	/usr/local/sbin/vh-update --channel stable -y > "$w/u1.log" 2>&1; rc=$?
	[ "$rc" = 0 ] && grep -qx "repository=$U" /etc/xbps.d/00-vh-channel.conf && ok "--channel stable: its repository in xbps.d" || bad "--channel stable, rc $rc" "$(tail -5 "$w/u1.log")"
	[ -e "/var/db/xbps/keys/$(basename "$kr2"/var/db/xbps/keys/*.plist)" ] && [ ! -e "/var/db/xbps/keys/$(basename "$kr"/var/db/xbps/keys/*.plist)" ] && ok "only the stable key of ours is trusted" || bad "keys after --channel stable" "$(ls /var/db/xbps/keys | tr '\n' ' ')"
	/usr/local/sbin/vh-update --channel rolling -y > "$w/u2.log" 2>&1; rc=$?
	[ "$rc" != 0 ] && grep -q 'does not trust' "$w/u2.log" && ok "--channel rolling while the index is the stable key's: refused, with the reason" || bad "--channel rolling, rc $rc" "$(tail -5 "$w/u2.log")"
	sh "$src/pkg/sign.sh" "$pub" "$w/keys/a.pem" "CI" --all >/dev/null 2>&1
	/usr/local/sbin/vh-update --channel rolling -y > "$w/u3.log" 2>&1; rc=$?
	[ "$rc" = 0 ] && ok "--channel rolling: signed by its key" || bad "--channel rolling signed, rc $rc" "$(tail -5 "$w/u3.log")"
	grep -q 'the rolling index is .* days old' "$w/u3.log" && ok "the rolling index of 2020: reported as stale" || bad "stale index" "$(tail -5 "$w/u3.log")"
	echo "== vh-update: a new thor goes first, and the list is the whole update"
	xbps-install -y vh-sched </dev/null >/dev/null 2>&1 || bad "vh-sched from the channel"
	# xbps compares the index's time in seconds: the next one must not fall in the second of the last
	sleep 2
	# the real thor's tree, without its shlib-requires: the test's repository has none of those libraries,
	# and xbps-rindex would keep the package in a stage index that xbps never reads
	# and without Void's repository in its xbps.d: this update stays inside the published set
	. "$src/thor/UPSTREAM"
	cp -a "$w/rt2/dest" "$w/rt3"; rm -f "$w/rt3/usr/share/xbps.d/00-repository-main.conf"
	( cd "$pub" && xbps-create -q -A "$arch" -n "thor-$XBPS_VERSION.${THOR_REVISION}_1000" -s thor -P "xbps-${XBPS_VERSION}_1 libxbps-${XBPS_VERSION}_1" -R "xbps>=0 libxbps>=0" --shlib-provides "libxbps.so.6" "$w/rt3" )
	mkdir -p "$w/vs/usr/local/sbin"; printf '#!/bin/sh\necho vh-sched 5\n' > "$w/vs/usr/local/sbin/vh-sched"; chmod 755 "$w/vs/usr/local/sbin/vh-sched"
	( cd "$pub" && xbps-create -q -A "$arch" -n vh-sched-0.2.0.r5_12 -s "a newer vh-sched" "$w/vs" && xbps-rindex -a thor-*_1000."$arch".xbps vh-sched-0.2.0.r5_12."$arch".xbps >/dev/null )
	[ ! -e "$pub/$arch-stagedata" ] || bad "the new thor went to the stage index"
	sh "$src/pkg/sign.sh" "$pub" "$w/keys/a.pem" "CI" >/dev/null 2>&1 || bad "sign the new thor"
	xbps-install -S </dev/null >/dev/null 2>&1
	xbps-query -R -p pkgver thor | grep -q '_1000$' || bad "the new thor is not in the index xbps read" "$(ls -l --time-style=full-iso "$pub/$arch-repodata" /var/db/xbps/http*/"$arch-repodata" | tr '\n' ' ') $(xbps-query -R -p pkgver thor)"
	xbps-install -y vh-init </dev/null > "$w/u4a.log" 2>&1; rc=$?
	[ "$rc" = 16 ] && ok "a pending thor holds every other package back (exit 16)" || bad "a pending thor, rc $rc" "$(tail -3 "$w/u4a.log")"
	before=$(xbps-query -l | awk '{print $2}' | LC_ALL=C sort | tr '\n' ' ')
	printf 'n\n' | /usr/local/sbin/vh-update > "$w/u4n.log" 2>&1; rc=$?
	[ "$rc" = 1 ] && grep -q 'Install it now' "$w/u4n.log" && [ "$before" = "$(xbps-query -l | awk '{print $2}' | LC_ALL=C sort | tr '\n' ' ')" ] && ok "no to the question about thor: nothing installed" || bad "no to thor, rc $rc" "$(tail -3 "$w/u4n.log")"
	/usr/local/sbin/vh-update > "$w/u4c.log" 2>&1 </dev/null; rc=$?
	[ "$rc" = 1 ] && [ "$before" = "$(xbps-query -l | awk '{print $2}' | LC_ALL=C sort | tr '\n' ' ')" ] && ok "nobody to answer it: nothing installed" || bad "stdin closed, rc $rc" "$(tail -3 "$w/u4c.log")"
	/usr/local/sbin/vh-update -y > "$w/u4.log" 2>&1 </dev/null; rc=$?
	! grep -q 'Install it now' "$w/u4.log" && ok "-y asks nothing" || bad "-y asked about thor"
	[ "$rc" = 0 ] && ok "vh-update with a pending thor" || bad "vh-update with a pending thor, rc $rc" "$(tail -12 "$w/u4.log")"
	xbps-query -p pkgver thor | grep -q '_1000$' && ok "thor is the new one" || bad "thor" "$(xbps-query -p pkgver thor)"
	xbps-query -p pkgver vh-sched | grep -q 'r5_12$' && ok "the other package came with it" || bad "vh-sched" "$(xbps-query -p pkgver vh-sched)"
	grep -q '^  vh-sched-0.2.0.r5_12' "$w/u4.log" && ok "the list names the other package" || bad "the list" "$(grep -n '^  ' "$w/u4.log" | head -5 | tr '\n' ' ')"
	# Void's xbps in a repository: vh-update does not ask for it on a current thor. This stand-in has
	# no shlib to stop it, so a -u xbps would show here (the real package: tests/thor/package_test.sh)
	mkdir -p "$w/vx/usr/share/vh-test"; echo x > "$w/vx/usr/share/vh-test/x"
	( cd "$pub" && xbps-create -q -A "$arch" -n xbps-999_1 -s "Void's xbps" "$w/vx" && xbps-rindex -a xbps-999_1."$arch".xbps >/dev/null )
	sh "$src/pkg/sign.sh" "$pub" "$w/keys/a.pem" "CI" >/dev/null 2>&1 || bad "sign xbps"
	/usr/local/sbin/vh-update -y > "$w/u5.log" 2>&1 </dev/null; rc=$?
	[ "$rc" = 0 ] && xbps-query -p pkgver thor | grep -q '_1000$' && ! xbps-query -p pkgver xbps 2>/dev/null | grep -q '^xbps-' && ok "a current thor: vh-update leaves xbps alone" || bad "thor and Void's xbps, rc $rc" "$(tail -5 "$w/u5.log")"
	kill "$srv" 2>/dev/null
else
	bad "no real thor for vh-update"
fi

echo
[ "$fails" = 0 ] && echo "pkg: every check passed" || echo "pkg: $fails checks failed"
exit "$fails"
