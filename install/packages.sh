# shellcheck shell=bash
# Package list of the target system. An explicit minimal set instead of base-system:
# base-system pulls in sudo, dhcpcd, wpa_supplicant, openssh, btrfs/f2fs-progs and so on.
# The list below is what every machine gets; the hardware's packages come from the plan.
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
		kmod eudev iproute2 iputils libcap-progs ethtool pciutils usbutils
		mdocml man-pages nvi
		# --- the kernel (firmware and microcode: the plan, below)
		"$VH_KERNEL"
		# --- boot: UKI, Secure Boot, encryption, file systems
		dracut dracut-uefi systemd-boot-efistub zstd lz4
		cryptsetup xfsprogs dosfstools efibootmgr limine sbctl
		# --- security and services
		opendoas dumb_runtime_dir apparmor bubblewrap acl-progs
		socklog-void dbus nftables unbound chrony
		# --- desktop
		# RefursWM (wlroots, libinput, libseat inside the binary): only its libraries
		seatd wayland libxkbcommon pixman libdrm libgbm libglvnd eudev-libudev libdisplay-info
		libevdev mtdev xkeyboard-config
		foot swaylock swayidle wl-clipboard
		mesa-dri
		pipewire wireplumber alsa-utils
		firefox libavcodec6 dejavu-fonts-ttf
	)
	# what this machine's hardware needs: microcode, firmware, VA-API and Vulkan drivers, iwd and
	# the regulatory database for Wi-Fi, dhcpcd for Ethernet, bluez, tpm2-tools (VH_PLAN_PACKAGES,
	# hwdb/; plan-report.txt says which rule asked for each)
	# shellcheck disable=SC2206 # the plan's list, one word per package
	p+=(${VH_PLAN_PACKAGES:-})
	printf '%s\n' "${p[@]}"
}
