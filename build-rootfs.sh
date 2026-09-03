#!/usr/bin/env bash
# Create a UOS20E arm64 rootfs from one source file and one package list.
# This runs inside the arm64 helper image on an arm64 GitHub runner.  The
# helper's Debian base is only a bootstrap for apt/dpkg; every package in the
# output rootfs comes from /src/apt_sources.txt.
set -euo pipefail

SOURCE_FILE="${UOS_APT_SOURCES_FILE:-/src/apt_sources.txt}"
PACKAGES_FILE="${UOS_PACKAGES_FILE:-/src/packages.txt}"
OUT_DIR="${UOS_ROOTFS_OUT:-/out}"
ROOTFS="$OUT_DIR/rootfs"
AUTH_FILE="${UOS_APT_AUTH_FILE:-/run/secrets/uos-apt-auth}"
CA_FILE="${UOS_APT_CA_FILE:-/run/secrets/uos-apt-ca}"

[ -s "$SOURCE_FILE" ] || { echo "missing apt source file: $SOURCE_FILE" >&2; exit 2; }
[ -s "$PACKAGES_FILE" ] || { echo "missing package list: $PACKAGES_FILE" >&2; exit 2; }
[ "$(dpkg --print-architecture)" = arm64 ] || {
    echo "rootfs helper must run as arm64; got $(dpkg --print-architecture)" >&2
    exit 2
}

rm -rf "$ROOTFS"
mkdir -p "$OUT_DIR" "$ROOTFS"
rm -f /var/cache/apt/archives/*.deb

# Delete every repository inherited from the bootstrap image.  Only active
# `deb` entries from the supplied apt_sources.txt are retained.  The supplied
# Wayland PPA currently redirects to an unavailable CDN index; it remains in
# apt_sources.txt for reproducibility but is opt-in, so a stale PPA cannot
# invalidate the base UOS20E repository indexes.
rm -f /etc/apt/sources.list
rm -rf /etc/apt/sources.list.d
mkdir -p /etc/apt/sources.list.d
awk -v include_ppa="${UOS_ENABLE_WAYLAND_PPA:-0}" '$1 == "deb" {
    if (!include_ppa && $2 ~ /professional-ppa\.chinauos\.com/) next
    if ($2 ~ /professional-ppa\.chinauos\.com/) {
        print "deb [arch=arm64 trusted=yes] " $2 " " $3 " main"
    } else {
        print "deb [arch=arm64 trusted=yes] " $2 " " $3 " " $4 " " $5 " " $6
    }
}' "$SOURCE_FILE" > /etc/apt/sources.list
[ -s /etc/apt/sources.list ] || { echo "apt_sources.txt has no usable active deb entries" >&2; exit 2; }

if [ -s "$AUTH_FILE" ]; then
    install -D -m 0600 "$AUTH_FILE" /etc/apt/auth.conf.d/90-uos.conf
    echo "UOS apt authentication configured"
else
    echo "UOS apt authentication file not present; continuing without it" >&2
fi

# Prefer a CA supplied by CI.  The insecure mode is explicit because some UOS
# endpoints use a private CA unavailable on GitHub runners.
if [ -s "$CA_FILE" ]; then
    install -D -m 0644 "$CA_FILE" /etc/ssl/certs/uos-apt-ca.pem
    cat > /etc/apt/apt.conf.d/90-uos-ca <<'CONF'
Acquire::https::CAInfo "/etc/ssl/certs/uos-apt-ca.pem";
CONF
elif [ "${UOS_INSECURE_TLS:-0}" = 1 ]; then
    cat > /etc/apt/apt.conf.d/91-uos-insecure-tls <<'CONF'
Acquire::https::Verify-Peer "false";
Acquire::https::Verify-Host "false";
CONF
    echo "WARNING: UOS apt TLS peer verification is disabled" >&2
fi

# The source file is the only source of URLs.  trusted=yes avoids requiring a
# UOS signing key inside the bootstrap image; the repository still uses the
# configured HTTPS endpoint and (when needed) its target auth file.
export DEBIAN_FRONTEND=noninteractive
apt-get update \
    -o Acquire::AllowInsecureRepositories=true \
    -o APT::Get::AllowUnauthenticated=true

mapfile -t PACKAGES < <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$PACKAGES_FILE")
[ "${#PACKAGES[@]}" -gt 0 ] || { echo "package list is empty" >&2; exit 2; }
printf 'Resolving %s UOS packages\n' "${#PACKAGES[@]}"
apt-get install -y --download-only --no-install-recommends \
    -o Acquire::AllowInsecureRepositories=true \
    -o APT::Get::AllowUnauthenticated=true \
    "${PACKAGES[@]}"

shopt -s nullglob
DEBS=(/var/cache/apt/archives/*.deb)
[ "${#DEBS[@]}" -gt 0 ] || { echo "apt downloaded no packages" >&2; exit 1; }
printf 'Extracting %s packages into UOS rootfs\n' "${#DEBS[@]}"
for deb in "${DEBS[@]}"; do
    dpkg-deb -x "$deb" "$ROOTFS"
done

# Populate a useful dpkg database without running services.  The extraction
# above is the source of truth; package post-install scripts that expect a
# booted OS are allowed to fail in this build-only rootfs.
mkdir -p "$ROOTFS/var/lib/dpkg" "$ROOTFS/usr/sbin"
cat > "$ROOTFS/usr/sbin/policy-rc.d" <<'POLICY'
#!/bin/sh
exit 101
POLICY
chmod 0755 "$ROOTFS/usr/sbin/policy-rc.d"
dpkg --root="$ROOTFS" --unpack "${DEBS[@]}" > "$OUT_DIR/dpkg-unpack.log" 2>&1 || {
    echo "warning: package status setup was partial; see dpkg-unpack.log" >&2
}

# The UOS apt list is retained for diagnostics, but the auth file and apt
# credentials are intentionally never copied into the output rootfs.
mkdir -p "$ROOTFS/etc/apt"
cp /etc/apt/sources.list "$ROOTFS/etc/apt/sources.list"
install -D -m 0755 /src/build-bambustudio-uos20e.sh \
    "$ROOTFS/usr/local/bin/build-bambustudio-uos20e.sh"
cat > "$ROOTFS/etc/uos20e-build-environment" <<'META'
NAME=UnionTech OS 20E
ID=uos
ID_LIKE=debian
VERSION_ID=20E
ARCHITECTURE=arm64
META

# Fail before exporting an image that cannot build the requested UOS ABI.
for required in \
    "$ROOTFS/usr/bin/cmake" \
    "$ROOTFS/usr/bin/ninja" \
    "$ROOTFS/usr/bin/g++" \
    "$ROOTFS/usr/include/webkitgtk-4.0/webkit2/webkit2.h" \
    "$ROOTFS/usr/lib/aarch64-linux-gnu/pkgconfig/webkit2gtk-4.0.pc"; do
    [ -e "$required" ] || { echo "rootfs missing required file: $required" >&2; exit 1; }
done

{
    echo "UOS20E arm64 rootfs"
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
} > "$OUT_DIR/uos20e-arm64-manifest.txt"

tar --numeric-owner --owner=0 --group=0 --sort=name \
    --mtime='UTC 1970-01-01' -C "$ROOTFS" -cf "$OUT_DIR/rootfs.tar" .
sha256sum "$OUT_DIR/rootfs.tar" > "$OUT_DIR/rootfs.tar.sha256"
printf 'UOS20E rootfs ready: %s\n' "$OUT_DIR/rootfs.tar"
