#!/bin/sh
# UniVoidDistro's own packages (docs/uni/rolling.md): xbps packages of the programs a build
# laid out and of this repository's files, added to a repository directory with its index.
#   sh pkg/build.sh PREBUILT ARCH REPO
# PREBUILT is the tree live/prebuilt.sh makes (the installer's build in RAM makes the same one):
# bin/, thor/{dest,repo}, desktop/VARIANT/{bin,share}, selinux/ (only with VH_MAC=selinux's policy).
# The packages:
#   thor               the package thor/package.sh made (copied when REPO is another directory)
#   vh-tools, vh-init, vh-sched, vh-session
#                      the programs, by pkg/tools.map
#   vh-desktop-VARIANT RefursWM and RefursLine, one package per build; each replaces the others
#   vh-selinux-policy  the policy and its file contexts in /etc/vh/selinux
#   vh-data            /root/vh: hwdb/, adapt/, kernel/ (pins, profiles, sources), zig/, thor/
#   vh-installer       /root/vh: install/, tools/, rootfs/, optional/, pkg/, vh.conf.example
#   vh-base            rootfs/usr: the programs in /usr/local (vh-update, vh-audit, ...)
#   vh-etc             rootfs/etc: the configuration; its files that are not programs are
#                      conf_files, so an edited file stays and the new one goes next to it
#   univoid            depends on every package each installation has
# What no package owns: the templates (*.in, *.cin) and pkg/installer-owned.
# The version: VH_PKG_VERSION, else git describe of this repository (v0.2.0-15-gHASH: 0.2.0.r15;
# no git: 0.0.0.r0, below every published package); the revision: VH_PKG_REVISION (1).
# xbps-create and xbps-rindex: thor's own (PREBUILT/thor/dest), or XBPS_BIN's.
set -eu
pkg=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$pkg/.." && pwd)
pre=$(cd "${1:?"the build (live/prebuilt.sh's tree)"}" && pwd)
arch=${2:?"the architecture: x86_64 or aarch64"}
out=${3:?"the repository directory"}
mkdir -p "$out"
out=$(cd "$out" && pwd)
X=${XBPS_BIN:-$pre/thor/dest/usr/bin}
[ -n "${XBPS_BIN:-}" ] || { LD_LIBRARY_PATH="$pre/thor/dest/usr/lib"; export LD_LIBRARY_PATH; }
die() { echo "pkg/build.sh: $*" >&2; exit 1; }
[ -x "$X/xbps-create" ] && [ -x "$X/xbps-rindex" ] || die "no xbps-create and xbps-rindex in $X"

ver=${VH_PKG_VERSION:-$(sh "$pkg/version.sh")}
case $ver in *[!0-9A-Za-z._]*|"") die "version $ver: letters, digits, dots and underscores only" ;; esac
rev=${VH_PKG_REVISION:-1}
# the files' times: the commit's, so that the same sources make the same archive
epoch=${SOURCE_DATE_EPOCH:-$(git -C "$src" log -1 --format=%ct 2>/dev/null || echo 0)}
export SOURCE_DATE_EPOCH=$epoch
home=https://github.com/FalconBinary/UniVoidDistro

work=$(mktemp -d "${TMPDIR:-/tmp}/vh-pkg.XXXXXX")
trap 'rm -rf "$work"' EXIT INT TERM
: > "$work/made"

# the libraries the ELF files of a tree need (readelf: binutils); none without readelf
shlibs() {
	command -v readelf >/dev/null || return 0
	find "$1" -type f -exec readelf -d {} + 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | LC_ALL=C sort -u | tr '\n' ' '
}

# mkpkg NAME DESCRIPTION [xbps-create options]: the package of the tree $work/NAME
mkpkg() {
	n=$1 desc=$2
	shift 2
	t=$work/$n
	mkdir -p "$t"
	find "$t" -exec touch -h -d "@$epoch" {} +
	s=$(shlibs "$t")
	( cd "$out" && "$X/xbps-create" -q -A "$arch" -n "$n-${ver}_$rev" -s "$desc" -H "$home" \
		-l "GPL-3.0-or-later" -m "UniVoidDistro <$home>" ${s:+--shlib-requires "$s"} "$@" "$t" )
	echo "$n-${ver}_$rev.$arch.xbps" >> "$work/made"
}

# put NAME FILE PLACE: FILE into package NAME at PLACE, 0755 when executable, 0644 otherwise
put() {
	m=0644
	[ -x "$2" ] && m=0755
	install -D -m "$m" "$2" "$work/$1$3"
}

# ---------------------------------------------------------------- thor
thor=$(ls "$pre"/thor/repo/thor-*."$arch".xbps 2>/dev/null) || die "no thor package in $pre/thor/repo (install/build-thor.sh --out)"
[ "$(dirname "$thor")" = "$out" ] || cp "$thor" "$out/"
echo "$(basename "$thor")" >> "$work/made"

# ---------------------------------------------------------------- the programs (pkg/tools.map)
grep -v '^[[:space:]]*\(#\|$\)' "$pkg/tools.map" | while read -r p name place copy; do
	[ -f "$pre/bin/$name" ] || die "no built program $pre/bin/$name"
	install -D -m 0755 "$pre/bin/$name" "$work/$p$place"
	[ -z "${copy:-}" ] || echo "[ ! -e \".$copy\" ] || install -m 0755 \".$place\" \".$copy\"" >> "$work/$p.copies"
done
[ -f "$pre/bin/vh_sched.o" ] || die "no built $pre/bin/vh_sched.o"
install -D -m 0644 "$pre/bin/vh_sched.o" "$work/vh-sched/usr/local/lib/vh/vh_sched.o"
for p in vh-tools vh-init vh-sched vh-session; do
	[ -s "$work/$p.copies" ] || continue
	{
		echo '#!/bin/sh'
		echo '# the copies an enabled optional/ module installed are replaced with the program (pkg/tools.map)'
		echo 'case "$1" in post) ;; *) exit 0 ;; esac'
		cat "$work/$p.copies"
		echo 'exit 0'
	} > "$work/$p/INSTALL"
	chmod 0755 "$work/$p/INSTALL"
done
mkpkg vh-tools "UniVoidDistro's system tools in Zig"
mkpkg vh-init "vh-init: PID 1, its first stage and vh-ctl"
mkpkg vh-sched "vh-sched: the sched_ext scheduler and its loader"
mkpkg vh-session "vh-root and vh-game: the gaming session"

# ---------------------------------------------------------------- the desktop, one package per build
variants="x86-64-v1-plain x86-64-v1-btmenu x86-64-v3-plain x86-64-v3-btmenu aarch64-plain aarch64-btmenu"
zigv=$(cat "$src/zig/ZIG_VERSION")
for d in "$pre"/desktop/*/; do
	[ -d "$d" ] || continue
	v=$(basename "$d") n=vh-desktop-$(basename "$d")
	case " $variants " in *" $v "*) ;; *) die "desktop build $v: not one of $variants" ;; esac
	for b in refurswm refursline; do install -D -m 0755 "$d/bin/$b" "$work/$n/usr/local/bin/$b"; done
	[ -d "$d/share/refurswm/libinput" ] || die "no $d/share/refurswm/libinput (libinput quirks)"
	mkdir -p "$work/$n/usr/local/share/refurswm"
	cp -R "$d/share/refurswm/libinput" "$work/$n/usr/local/share/refurswm/"
	chmod -R u=rwX,go=rX "$work/$n/usr/local/share/refurswm"
	install -d -m 0755 "$work/$n/etc/vh"
	{
		echo "# RefursWM + RefursLine: $n-${ver}_$rev, zig $zigv"
		( cd "$work/$n/usr/local/bin" && sha256sum refurswm refursline )
	} > "$work/$n/etc/vh/desktop.sha256"
	r=""
	for o in $variants; do [ "$o" = "$v" ] || r="$r vh-desktop-$o>=0"; done
	mkpkg "$n" "RefursWM and RefursLine ($v)" --provides "vh-desktop-1_1" --replaces "${r# }" \
		-D "seatd>=0 wayland>=0 libxkbcommon>=0 pixman>=0 libdrm>=0 libgbm>=0 libglvnd>=0 eudev-libudev>=0 libdisplay-info>=0 libevdev>=0 mtdev>=0 xkeyboard-config>=0"
done

# ---------------------------------------------------------------- the SELinux policy
if [ -s "$pre/selinux/file_contexts" ]; then
	for f in "$pre"/selinux/policy.* "$pre/selinux/file_contexts" "$pre/selinux/BUILD" "$pre/selinux/SHA256SUMS"; do
		install -D -m 0644 "$f" "$work/vh-selinux-policy/etc/vh/selinux/$(basename "$f")"
	done
	mkpkg vh-selinux-policy "UniVoidDistro's SELinux policy (VH_MAC=selinux)"
fi

# ---------------------------------------------------------------- /root/vh: the data and the installer
# copy PACKAGE PATH...: the repository's files at PATH into PACKAGE's /root/vh (0700, as the installer makes it)
copy() {
	p=$1
	shift
	install -d -m 0700 "$work/$p/root/vh"
	( cd "$src" && tar -cf - --exclude=.zig-cache --exclude=zig-out --exclude=zig-pkg "$@" ) | ( cd "$work/$p/root/vh" && tar -xf - )
	chmod -R u+rwX,go-w "$work/$p/root/vh"
}
# xbps unpacks the directories 0755: the INSTALL script makes them the installer's 0700
# mode0700 PACKAGE DIR...: the INSTALL script that does it
mode0700() {
	p=$1
	shift
	printf '#!/bin/sh\n# /root/vh is 0700, as the installer makes it (pkg/build.sh)\ncase "$1" in post) ;; *) exit 0 ;; esac\nchmod 0700 %s\nexit 0\n' "$*" > "$work/$p/INSTALL"
	chmod 0755 "$work/$p/INSTALL"
}
copy vh-data hwdb adapt zig thor kernel/pins kernel/profiles kernel/src kernel/build.zig kernel/build.zig.zon
mode0700 vh-data ./root/vh ./root/vh/kernel
mkpkg vh-data "UniVoidDistro's data: the hwdb rules, the kernel's profiles and pins, the sources the tools re-plan with"
copy vh-installer install tools rootfs optional vh.conf.example pkg
mode0700 vh-installer ./root/vh
mkpkg vh-installer "UniVoidDistro's installer and optional modules (/root/vh)"

# ---------------------------------------------------------------- rootfs/: vh-base and vh-etc
# a file of rootfs/ is the installer's when it is a template or in pkg/installer-owned
owned=$(grep -v '^[[:space:]]*\(#\|$\)' "$pkg/installer-owned")
: > "$work/conf"
( cd "$src/rootfs" && find . \( -type f -o -type l \) | sed 's|^\.||' | LC_ALL=C sort ) | while read -r f; do
	case $f in *.in|*.cin) continue ;; esac
	if printf '%s\n' "$owned" | grep -qxF "$f"; then continue; fi
	case $f in /etc/*) p=vh-etc ;; *) p=vh-base ;; esac
	if [ -L "$src/rootfs$f" ]; then
		mkdir -p "$(dirname "$work/$p$f")"
		ln -s "$(readlink "$src/rootfs$f")" "$work/$p$f"
		continue
	fi
	put "$p" "$src/rootfs$f" "$f"
	if [ "$p" = vh-etc ] && [ ! -x "$src/rootfs$f" ]; then echo "$f" >> "$work/conf"; fi
done
install -D -m 0644 "$pkg/thor-keep" "$work/vh-base/usr/local/lib/vh/thor-keep"
mkpkg vh-base "UniVoidDistro's programs in /usr/local: vh-update, vh-audit and the rest"
mkpkg vh-etc "UniVoidDistro's configuration in /etc" --config-files "$(tr '\n' ' ' < "$work/conf")"

# ---------------------------------------------------------------- univoid
mkpkg univoid "UniVoidDistro: every package of an installation" \
	-D "thor>=0 vh-tools>=0 vh-init>=0 vh-sched>=0 vh-session>=0 vh-desktop>=0 vh-data>=0 vh-installer>=0 vh-base>=0 vh-etc>=0"

# ---------------------------------------------------------------- the index
( cd "$out" && XBPS_TARGET_ARCH=$arch "$X/xbps-rindex" -a $(cat "$work/made") >/dev/null )
sed "s|^|$out/|" "$work/made"
