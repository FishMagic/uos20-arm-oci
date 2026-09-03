# syntax=docker/dockerfile:1.7
FROM scratch
ARG UOS_ROOTFS_SHA256=unknown
LABEL org.opencontainers.image.title="UOS20E arm64 build environment" \
      org.opencontainers.image.description="Native UOS20E arm64 build rootfs for BambuStudio" \
      org.opencontainers.image.source="https://github.com/FishMagic/uos20-arm-oci" \
      com.fishmagic.uos20e.apt-sources="apt_sources.txt" \
      com.fishmagic.uos20e.rootfs-sha256="$UOS_ROOTFS_SHA256"
ADD rootfs.tar /
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8
WORKDIR /work
ENTRYPOINT ["/bin/bash"]
