# Image for the zig/ and thor/ tests (tests/zig/run.sh, tests/thor/run.sh): Void with the
# headers for building xbps, gcc for the C check programs, and Zig (the archive is verified
# by tests/docker/build.sh).
FROM ghcr.io/void-linux/void-glibc-full:latest
# the package mirror (tests/docker/build.sh: VH_MIRROR; the default one was down for hours on 2026-10-26)
ARG VH_MIRROR=https://repo-default.voidlinux.org
# the repository of the image's architecture: current for x86_64, current/aarch64 for aarch64
RUN mkdir -p /etc/xbps.d && case "$(xbps-uhelper arch)" in aarch64*) sub=/aarch64 ;; *) sub= ;; esac \
	&& echo "repository=${VH_MIRROR}/current$sub" > /etc/xbps.d/00-repository-main.conf
RUN xbps-install -Syu xbps && xbps-install -Syu && xbps-install -Sy openssl-devel libarchive-devel \
	zlib-devel pkgconf make xz patch libcap-progs gcc libxcrypt-devel python3 zstd lz4 bash openssl
ARG ZIG_TARBALL
COPY ${ZIG_TARBALL} /tmp/
RUN mkdir -p /opt && tar -xJf /tmp/${ZIG_TARBALL} -C /opt && rm /tmp/${ZIG_TARBALL} \
	&& ln -s /opt/${ZIG_TARBALL%.tar.xz}/zig /usr/local/bin/zig
ENV ZIG=/usr/local/bin/zig
