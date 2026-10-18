# shellcheck shell=bash
# Package list of the target system. An explicit minimal set instead of base-system:
# base-system pulls in sudo, dhcpcd, wpa_supplicant, openssh, btrfs/f2fs-progs and so on.
# The rationale for every package is in docs/02-bootstrap.md.
# thor is xbps with the void-hardperf-light security policy (docs/18); it is built by
# install/build-thor.sh and installed from the local repository /var/lib/thor/repo,
# replacing xbps and libxbps.

vh_packages() {
	local p=(
		# --- base: what every Void system needs
		base-files thor runit-void removed-packages
		coreutils findutils diffutils dash bash grep gzip sed gawk less which tar
		util-linux shadow procps-ng iana-etc tzdata glibc-locales ncurses kbd
		kmod eudev iproute2 iputils libcap-progs ethtool iw pciutils usbutils
		mdocml man-pages nvi
		# --- kernel, firmware, microcode
		"$VH_KERNEL" linux-firmware-intel linux-firmware-network wireless-regdb intel-ucode
		# --- boot: UKI, Secure Boot, encryption, file systems
		dracut dracut-uefi systemd-boot-efistub zstd lz4
		cryptsetup xfsprogs dosfstools efibootmgr limine sbctl tpm2-tools
		# --- security and services
		opendoas dumb_runtime_dir apparmor bubblewrap acl-progs
		socklog-void dbus iwd nftables unbound chrony
		# --- desktop
		# RefursWM (wlroots, libinput, libseat inside the binary): only its libraries
		seatd wayland libxkbcommon pixman libdrm libgbm libglvnd eudev-libudev libdisplay-info
		libevdev mtdev xkeyboard-config
		foot swaylock swayidle wl-clipboard
		mesa-dri intel-media-driver
		pipewire wireplumber alsa-utils
		firefox libavcodec6 dejavu-fonts-ttf
	)
	[ "$VH_ETH" = dhcp ] && p+=(dhcpcd)
	[ "$VH_BLUETOOTH" != off ] && p+=(bluez)
	[ "$VH_GPU" = nouveau ] && p+=(linux-firmware-nvidia mesa-vulkan-nouveau)
	printf '%s\n' "${p[@]}"
}
