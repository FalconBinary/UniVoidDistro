# Copyright (c) 2026 Denys (FalconBinary)
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Test image "refurs-dev3". Base "refurs-dev2" = Void glibc + Zig 0.17 + wlroots0.20-devel,
# wayland-protocols, foot, grim, wtype, wayland-utils, wlrctl, fuzzel, swaybg, swaylock, procps-ng.
# Added here: tracing, clipboard and idle tools for tests/*.sh, and the headers needed to build
# wlroots, libinput and libseat from source (deps/*.zig).
#   docker build -t refurs-dev3 tests/docker
FROM refurs-dev2
RUN xbps-install -Sy >/dev/null && xbps-install -y strace wl-clipboard swayidle hwids \
	libevdev-devel mtdev-devel >/dev/null
