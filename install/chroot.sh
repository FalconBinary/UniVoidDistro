#!/bin/bash
# Stage 1, the part that runs inside the chroot. Started by 10-install.sh; not meant to be
# run by hand. Every step has a guide section (docs/...) that explains it command by command.

. /root/vh/install/lib.sh
load_config /root/vh/vh.conf
load_plan /root/vh/plan.env
set -a
# shellcheck source=/dev/null
. /root/vh/ids
set +a

# ---------------------------------------------------------------- host (docs/02)
say "hostname, time zone, locale, keymap"
echo "$VH_HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1	localhost
127.0.1.1	$VH_HOSTNAME
EOF
ln -sf "/usr/share/zoneinfo/$VH_TIMEZONE" /etc/localtime
sed -i "s/^#\s*\($VH_LOCALE \)/\1/" /etc/default/libc-locales
xbps-reconfigure -f glibc-locales >/dev/null
echo "LANG=$VH_LOCALE" > /etc/locale.conf
sed -i -e "s/^#\?KEYMAP=.*/KEYMAP=\"$VH_KEYMAP\"/" -e 's/^#\?HARDWARECLOCK=.*/HARDWARECLOCK="UTC"/' /etc/rc.conf

# ---------------------------------------------------------------- PAM (docs/05)
say "PAM: yescrypt, no nullok; login.defs: umask 077"
# system-auth from pam-base: empty passwords are rejected, the hash is yescrypt (cost 7).
# passwd from shadow has its own /etc/pam.d/passwd (pam_unix sha512, no system-auth
# include): every file with pam_unix is edited, otherwise passwd writes $6$ hashes.
for f in $(grep -l 'pam_unix\.so' /etc/pam.d/*); do
	sed -i -e '/pam_unix\.so/s/\s*nullok//' -e '/pam_unix\.so/s/\bsha512\b/yescrypt rounds=7/' "$f"
done
grep -q 'yescrypt' /etc/pam.d/system-auth || die "system-auth: could not enable yescrypt"
! grep -l 'pam_unix\.so.*\(sha512\|nullok\)' /etc/pam.d/* || die "pam_unix with sha512/nullok is still present in the files above"
sed -i -e 's/^UMASK.*/UMASK		077/' /etc/login.defs
grep -q '^HOME_MODE' /etc/login.defs || echo 'HOME_MODE	0700' >> /etc/login.defs

# ---------------------------------------------------------------- groups and users (docs/05)
say "groups and users"
for g in render netdev netdiag backlight proc xfer; do
	getent group "$g" >/dev/null || groupadd -r "$g"
done
getent group _seatd >/dev/null || die "no _seatd group (is the seatd package installed?)"
if ! id "$VH_ADMIN" >/dev/null 2>&1; then
	useradd -m -s /bin/bash -G wheel,netdiag,proc,netdev "$VH_ADMIN"
fi
if ! id "$VH_USER" >/dev/null 2>&1; then
	useradd -m -s /bin/bash -G _seatd,audio,render,netdev,backlight,netdiag,xfer "$VH_USER"
fi
if ! id "$VH_BROWSER_USER" >/dev/null 2>&1; then
	useradd -r -m -d /var/lib/vh-browser -s /usr/bin/nologin -G render,xfer "$VH_BROWSER_USER"
fi
chmod 0700 /var/lib/vh-browser "/home/$VH_ADMIN" "/home/$VH_USER"
passwd -l "$VH_BROWSER_USER" >/dev/null
# root is locked: administration goes through doas from $VH_ADMIN only
passwd -l root >/dev/null

# ---------------------------------------------------------------- generated configs
say "sysctl (netdiag GID), module blacklist, fstab"
VH_NETDIAG_GID=$(getent group netdiag | cut -d: -f3)
export VH_NETDIAG_GID
render /root/vh/rootfs/etc/sysctl.d/40-vh-network.conf.cin /etc/sysctl.d/40-vh-network.conf

{
	echo "# void-hardperf-light: mirrors module_blacklist= from the cmdline (docs/03, docs/05)."
	echo "# install ... /bin/false also denies an explicit \"modprobe name\", not just autoloading."
	vh_module_blacklist | sed 's|.*|install & /bin/false|'
} > /etc/modprobe.d/vh-blacklist.conf

# rule files a hwdb rule selects (the dGPU that sleeps): only those the plan names stay
for f in ${VH_PLAN_UDEV_KNOWN:-}; do
	case " ${VH_PLAN_UDEV:-} " in *" $f "*) ;; *) rm -f "/etc/udev/rules.d/$f" ;; esac
done

ESP_DEV="UUID=$VH_ESP_UUID"
HOME_OPTS="bind,nosuid,nodev"
[ "$VH_HOME_NOEXEC" = yes ] && HOME_OPTS="$HOME_OPTS,noexec"
cat > /etc/fstab <<EOF
# void-hardperf-light: file systems (docs/01, docs/05).
# /proc, /dev, /dev/shm and /run are mounted by runit before fstab; their options are
# set in /etc/runit/core-services/04-vh-mounts.sh.
#
# root: XFS inside LUKS2. logbsize is set on the cmdline (rootflags=): a remount cannot change it
UUID=$VH_ROOT_UUID	/		xfs	rw,noatime	0 0
# the ESP is mounted only while the kernel is being updated (the /etc/kernel.d hooks)
$ESP_DEV	/boot/efi	vfat	noauto,nosuid,nodev,noexec,fmask=0177,dmask=0077	0 0
# temporary directories in RAM: no execution, limited size
tmpfs		/tmp		tmpfs	nosuid,nodev,noexec,mode=1777,size=25%	0 0
tmpfs		/var/tmp	tmpfs	nosuid,nodev,noexec,mode=1777,size=10%	0 0
# options applied through bind mounts (these are not separate file systems)
/home		/home		none	$HOME_OPTS	0 0
/home/xfer	/home/xfer	none	bind,nosuid,nodev,noexec,nosymfollow	0 0
/var/lib/vh-browser	/var/lib/vh-browser	none	bind,nosuid,nodev,noexec	0 0
EOF
if [ -n "$VH_DEV_DIR" ]; then
	install -d -m 0700 -o "$VH_USER" -g "$VH_USER" "/home/$VH_USER/$VH_DEV_DIR"
	printf '%s\t%s\tnone\tbind,nosuid,nodev\t0 0\n' "/home/$VH_USER/$VH_DEV_DIR" "/home/$VH_USER/$VH_DEV_DIR" >> /etc/fstab
fi

# ---------------------------------------------------------------- network (docs/06, docs/07)
say "unbound, chrony, iwd, resolv.conf"
# var/ is the only thing _unbound writes (RFC 5011 key updates). 0755 and root.key 0644:
# the DNSSEC root key is public, and root reads it before dropping privileges, without dac_override
install -d -m 0755 -o _unbound -g _unbound /etc/unbound/var
anchor=""
for f in /etc/dns/root.key /usr/share/dnssec-anchors/root.key /etc/unbound/root.key; do
	[ -s "$f" ] && { anchor=$f; break; }
done
[ -n "$anchor" ] || die "no DNSSEC root key (dnssec-anchors package)"
install -m 0644 -o _unbound -g _unbound "$anchor" /etc/unbound/var/root.key
install -m 0644 /etc/ssl/certs/ca-certificates.crt /etc/unbound/ca-bundle.pem
unbound-checkconf /etc/unbound/unbound.conf >/dev/null || die "unbound.conf has errors"
install -d -m 0750 -o chrony -g chrony /var/lib/chrony
install -d -m 0700 /var/lib/iwd
nft -c -f /etc/nftables.conf || die "nftables.conf has errors"

# ---------------------------------------------------------------- runit services (docs/05)
say "runit services"
SVDIR=/etc/runit/runsvdir/default
for t in 3 4 5 6; do rm -f "$SVDIR/agetty-tty$t"; done
enable_sv() { [ -d "/etc/sv/$1" ] || die "no service $1"; ln -sfn "/etc/sv/$1" "$SVDIR/$1"; }
for s in agetty-tty1 agetty-tty2 udevd dbus unbound chronyd seatd socklog-unix nanoklogd; do
	enable_sv "$s"
done
# what the hardware needs: iwd with Wi-Fi, dhcpcd on a wired interface, vh-acpid with a lid or a
# power button, vh-fstrim with a disk that accepts discard, bluetoothd (VH_PLAN_SERVICES, hwdb/)
for s in ${VH_PLAN_SERVICES:-}; do
	enable_sv "$s"
done
[ "$VH_ETH" = static ] && enable_sv vh-eth-static
if [ "${VH_TEST_SERIAL:-no}" = yes ]; then
	# tests/vm bench: admin login on ttyS0 (never enable on real hardware)
	enable_sv agetty-ttyS0
	sed -i "/^- : ALL : ALL/i + : $VH_ADMIN : ttyS0" /etc/security/access.conf
fi
for s in sshd dhcpcd wpa_supplicant acpid; do rm -f "$SVDIR/$s"; done

# ---------------------------------------------------------------- desktop (docs/08)
say "PipeWire, home directories, shared downloads directory"
install -d /etc/pipewire/pipewire.conf.d
ln -sf /usr/share/examples/wireplumber/10-wireplumber.conf /etc/pipewire/pipewire.conf.d/
ln -sf /usr/share/examples/pipewire/20-pipewire-pulse.conf /etc/pipewire/pipewire.conf.d/

# Exchange directory with the browser: group xfer (the user and the browser), setgid,
# default ACL, so a file downloaded with umask 077 is readable by both.
install -d -m 2770 -o "$VH_BROWSER_USER" -g xfer /home/xfer
setfacl -m "d:u:$VH_USER:rwX,d:u:$VH_BROWSER_USER:rwX,d:g:xfer:rwX,d:m::rwX" /home/xfer

uh=/home/$VH_USER
# RefursWM and RefursLine keep no settings in $HOME: they are compiled into the binaries (docs/08)
install -d -m 0700 -o "$VH_USER" -g "$VH_USER" "$uh/.config" \
	"$uh/.config/foot" "$uh/Pictures" "$uh/Pictures/wallpapers"
install -m 0600 -o "$VH_USER" -g "$VH_USER" /etc/vh/skel/foot.ini "$uh/.config/foot/foot.ini"
ln -sfn /home/xfer "$uh/Downloads"
chown -h "$VH_USER:$VH_USER" "$uh/Downloads"

# ---------------------------------------------------------------- boot (docs/03)
say "dracut-uefi as the initramfs provider; Secure Boot keys"
xbps-alternatives -s dracut-uefi >/dev/null
install -d -m 0700 /var/cache/apparmor
if [ ! -e /var/lib/sbctl/keys/db/db.key ]; then
	sbctl create-keys
fi
chmod -R go-rwx /var/lib/sbctl

# ---------------------------------------------------------------- SUID (docs/05)
say "SUID and capabilities"
/usr/local/sbin/vh-suid-strip

# ---------------------------------------------------------------- shared caches (docs/08)
# The MIME database is built by the mimedb trigger of shared-mime-info. When installing
# with thor -r /mnt the trigger fails ("Failed to write XML file"), and with -n it does
# not rebuild the database afterwards. Without it gdk-pixbuf does not recognise SVG and
# GTK (Firefox) crashes on the first icon. Here we have a full chroot and umask 022 from
# lib.sh: the database is readable by everyone.
say "MIME database (shared-mime-info)"
update-mime-database /usr/share/mime
for f in /usr/share/mime/mime.cache /usr/share/mime/globs2; do
	[ -s "$f" ] && [ "$(stat -c %a "$f")" = 644 ] || die "$f: missing or not 0644; GTK will not load SVG icons"
done

# ---------------------------------------------------------------- passwords (docs/01, docs/05)
say "passwords"
if [ -n "${VH_TEST_PASSWORD:-}" ]; then
	# automated VM tests: the same password for both accounts
	h=$(printf '%s' "$VH_TEST_PASSWORD" | /root/vh/tools/vh-hashpw 7)
	usermod -p "$h" "$VH_ADMIN"
	usermod -p "$h" "$VH_USER"
else
	echo "The admin and user passwords must differ from each other and from the LUKS passphrase (docs/01)."
	until passwd "$VH_ADMIN"; do echo "try again"; done
	until passwd "$VH_USER"; do echo "try again"; done
fi
for u in "$VH_ADMIN" "$VH_USER"; do
	case $(getent shadow "$u" | cut -d: -f2) in
		'$y$'*) ;;
		*) die "the password of $u is not a yescrypt hash" ;;
	esac
done

ok "chroot: configuration finished"
