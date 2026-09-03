#!/usr/bin/env bash
# Create a Debian buster arm64 build rootfs from the official Debian archive.
# The package names were selected from the exported UOS20E development-package
# inventory; Debian resolves the available central versions and dependencies.
set -euo pipefail

SOURCE_FILE="${CENTRAL_APT_SOURCES_FILE:-/src/debian.sources}"
PACKAGES_FILE="${CENTRAL_PACKAGES_FILE:-/src/packages-central-buster.txt}"
OUT_DIR="${CENTRAL_ROOTFS_OUT:-/out}"
ROOTFS="$OUT_DIR/rootfs"

[ -s "$SOURCE_FILE" ] || { echo "missing central apt source file: $SOURCE_FILE" >&2; exit 2; }
[ -s "$PACKAGES_FILE" ] || { echo "missing central package list: $PACKAGES_FILE" >&2; exit 2; }
[ "$(dpkg --print-architecture)" = arm64 ] || {
    echo "central rootfs must be built by an arm64 helper" >&2
    exit 2
}

rm -rf "$ROOTFS"
mkdir -p "$OUT_DIR" "$ROOTFS"
rm -f /var/cache/apt/archives/*.deb

# The helper image already contains the pinned Debian buster base system.  Keep
# it in the output so packages that apt considers pre-installed are not lost;
# the selected package list then adds the build toolchain and headers.
tar -C / --create --file=- \
    --exclude=./proc \
    --exclude=./sys \
    --exclude=./dev \
    --exclude=./run \
    --exclude=./src \
    --exclude=./out \
    --exclude=./tmp \
    --exclude=./var/cache/apt/archives \
    --exclude=./var/lib/apt/lists \
    . | tar -C "$ROOTFS" --extract --file=-
mkdir -p "$ROOTFS"/{proc,sys,dev,run,tmp,var/cache/apt/archives,var/lib/apt/lists}
rm -rf "$ROOTFS"/tmp/* "$ROOTFS"/var/cache/apt/archives/*

# Debian buster is archived.  The URLs are the official Debian archive; its
# Release metadata is expired by design, so disable only Valid-Until checking.
rm -f /etc/apt/sources.list
rm -rf /etc/apt/sources.list.d
mkdir -p /etc/apt/sources.list.d
cp "$SOURCE_FILE" /etc/apt/sources.list

export DEBIAN_FRONTEND=noninteractive
APT_OPTIONS=(
    -o Acquire::Check-Valid-Until=false
    -o Acquire::AllowInsecureRepositories=true
    -o APT::Get::AllowUnauthenticated=true
)
apt-get update "${APT_OPTIONS[@]}"

# The minimal bootstrap image may mark ca-certificates installed without the
# generated bundle. Reinstall it before copying the base filesystem so git and
# CMake ExternalProject can verify HTTPS sources.
apt-get install -y --reinstall --no-install-recommends \
    "${APT_OPTIONS[@]}" ca-certificates
update-ca-certificates
mkdir -p "$ROOTFS/etc/ssl/certs"
cp -a /etc/ssl/certs/. "$ROOTFS/etc/ssl/certs/"

mapfile -t PACKAGES < <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$PACKAGES_FILE")
[ "${#PACKAGES[@]}" -gt 0 ] || { echo "central package list is empty" >&2; exit 2; }
printf 'Resolving %s Debian buster packages\n' "${#PACKAGES[@]}"
apt-get install -y --download-only --no-install-recommends \
    "${APT_OPTIONS[@]}" "${PACKAGES[@]}"

shopt -s nullglob
DEBS=(/var/cache/apt/archives/*.deb)
[ "${#DEBS[@]}" -gt 0 ] || { echo "apt downloaded no central packages" >&2; exit 1; }
printf 'Extracting %s packages into Debian buster rootfs\n' "${#DEBS[@]}"
for deb in "${DEBS[@]}"; do
    dpkg-deb -x "$deb" "$ROOTFS"
done

# Keep package state useful for diagnostics without running maintainer scripts.
mkdir -p "$ROOTFS/var/lib/dpkg" "$ROOTFS/usr/sbin"
cat > "$ROOTFS/usr/sbin/policy-rc.d" <<'POLICY'
#!/bin/sh
exit 101
POLICY
chmod 0755 "$ROOTFS/usr/sbin/policy-rc.d"
dpkg --root="$ROOTFS" --unpack "${DEBS[@]}" > "$OUT_DIR/dpkg-unpack.log" 2>&1 || {
    echo "warning: package status setup was partial; see dpkg-unpack.log" >&2
}

mkdir -p "$ROOTFS/etc/apt"
cp /etc/apt/sources.list "$ROOTFS/etc/apt/sources.list"
install -D -m 0755 /src/build-bambustudio-uos20e.sh \
    "$ROOTFS/usr/local/bin/build-bambustudio-uos20e.sh"
cat > "$ROOTFS/etc/uos20e-build-environment" <<'META'
NAME=Debian buster central bootstrap for UOS20E
ID=debian
ID_LIKE=debian
VERSION_ID=10
TARGET_ABI=uos20e
ARCHITECTURE=arm64
META

# Fail before exporting an image that cannot run the selected build path.
for required in \
    "$ROOTFS/bin/bash" \
    "$ROOTFS/usr/bin/cmake" \
    "$ROOTFS/usr/bin/ninja" \
    "$ROOTFS/usr/bin/g++" \
    "$ROOTFS/usr/bin/git" \
    "$ROOTFS/bin/tar" \
    "$ROOTFS/etc/ssl/certs/ca-certificates.crt" \
    "$ROOTFS/usr/include/webkitgtk-4.0/webkit2/webkit2.h" \
    "$ROOTFS/usr/lib/aarch64-linux-gnu/pkgconfig/webkit2gtk-4.0.pc"; do
    [ -e "$required" ] || { echo "central rootfs missing required file: $required" >&2; exit 1; }
done

{
    echo "Debian buster central arm64 rootfs for UOS20E"
    printf 'sources-sha256='; sha256sum "$SOURCE_FILE" | cut -d' ' -f1
    printf 'packages-sha256='; sha256sum "$PACKAGES_FILE" | cut -d' ' -f1
    echo "package-count=${#DEBS[@]}"
    for deb in "${DEBS[@]}"; do
        printf '%s\t%s\t%s\t%s\n' \
            "$(dpkg-deb -f "$deb" Package)" \
            "$(dpkg-deb -f "$deb" Version)" \
            "$(dpkg-deb -f "$deb" Architecture)" \
            "$(basename "$deb")"
    done
} > "$OUT_DIR/debian-buster-arm64-manifest.txt"

tar --numeric-owner --owner=0 --group=0 --sort=name \
    --mtime='UTC 1970-01-01' -C "$ROOTFS" -cf "$OUT_DIR/rootfs.tar" .
sha256sum "$OUT_DIR/rootfs.tar" > "$OUT_DIR/rootfs.tar.sha256"
printf 'Debian buster central rootfs ready: %s\n' "$OUT_DIR/rootfs.tar"
