#!/usr/bin/env bash
# Build the official BambuStudio edition inside the UOS20E arm64 image.
# The source checkout is mounted read-only at /src; no OBN variant is built.
set -euo pipefail

SRC="${BAMBU_SOURCE_DIR:-/src}"
WORK="${BAMBU_WORK_DIR:-/work/BambuStudio}"
OUT="${BAMBU_OUTPUT_DIR:-/out}"
JOBS="${BAMBU_JOBS:-$(nproc)}"

[ "$(uname -m)" = aarch64 ] || { echo "native arm64 is required" >&2; exit 2; }
[ -f "$SRC/CMakeLists.txt" ] || { echo "missing source checkout: $SRC" >&2; exit 2; }
mkdir -p "$OUT" "$(dirname "$WORK")"
rm -rf "$WORK"
cp -a "$SRC/." "$WORK/"
cd "$WORK"

git config --global --add safe.directory "$WORK" >/dev/null 2>&1 || true
export BAMBU_TARGET_DISTRO=uos
export SKIP_RAM_CHECK=1
export DISABLE_PARALLEL_LIMIT=1
export CMAKE_BUILD_PARALLEL_LEVEL="$JOBS"

# src/slic3r/CMakeLists.txt prefers 4.1 when it is visible.  The UOS image
# contains only the target's 4.0 development ABI.
if ! pkg-config --exists webkit2gtk-4.0; then
    echo "UOS20E WebKitGTK 4.0 development package is missing" >&2
    exit 1
fi
if pkg-config --exists webkit2gtk-4.1; then
    echo "WebKitGTK 4.1 is present; refusing a non-UOS20E build" >&2
    exit 1
fi

# Build dependencies and the official/base BambuStudio binary natively.
./BuildLinux.sh -dsrf

# Build the portable package first. AppImage generation mutates build/package
# while adding AppImage metadata, so the Debian package must be staged first.
chmod 0755 build/src/BuildLinuxImage.sh
(
    cd build
    ./src/BuildLinuxImage.sh
)

VERSION=$(sed -n 's/^set(SLIC3R_VERSION "\([^" ]*\)").*/\1/p' version.inc)
ARCH=$(dpkg --print-architecture)
[ -n "$VERSION" ] || { echo "could not determine BambuStudio version" >&2; exit 1; }
BASE_NAME="BambuStudio_${VERSION}_uos20e_${ARCH}"

cp build/BambuStudio.tar "$OUT/${BASE_NAME}.tar"
tar -C build/package --numeric-owner --owner=0 --group=0 --sort=name \
    --mtime='UTC 1970-01-01' -czf \
    "$OUT/${BASE_NAME}.tar.gz" .
if command -v zstd >/dev/null 2>&1; then
    zstd -T0 -19 -f "$OUT/${BASE_NAME}.tar" \
        -o "$OUT/${BASE_NAME}.tar.zst"
fi

# Install the portable tree under /opt and expose its launcher through PATH.
# The wrapper uses readlink -f, so the absolute symlink resolves back into the
# bundled tree and keeps its private libraries in LD_LIBRARY_PATH.
DEB_ROOT="$WORK/deb-root"
rm -rf "$DEB_ROOT"
mkdir -p "$DEB_ROOT/DEBIAN" "$DEB_ROOT/opt/BambuStudio" "$DEB_ROOT/usr/bin"
cp -a build/package/. "$DEB_ROOT/opt/BambuStudio/"
ln -s /opt/BambuStudio/bambu-studio "$DEB_ROOT/usr/bin/bambu-studio"
install -D -m 0644 \
    build/package/resources/applications/BambuStudio.desktop \
    "$DEB_ROOT/usr/share/applications/BambuStudio.desktop"
for PNG_SIZE in 32 128 192; do
    install -D -m 0644 \
        "build/package/resources/images/BambuStudio_${PNG_SIZE}px.png" \
        "$DEB_ROOT/usr/share/icons/hicolor/${PNG_SIZE}x${PNG_SIZE}/apps/BambuStudio.png"
done
cat > "$DEB_ROOT/DEBIAN/control" <<EOF
Package: bambu-studio
Version: ${VERSION}
Section: graphics
Priority: optional
Architecture: ${ARCH}
Maintainer: BambuStudio maintainers <bambustudio@example.invalid>
Depends: libc6 (>= 2.28), libgcc1, libstdc++6, libgtk-3-0, libwebkit2gtk-4.0-37, libgstreamer1.0-0, libgstreamer-plugins-base1.0-0, libgl1, libglu1-mesa, libdbus-1-3, libsecret-1-0, libsoup2.4-1, libx11-6, libxkbcommon0, libwayland-client0
Description: BambuStudio 3D printing slicer
 BambuStudio desktop application for preparing 3D-printing projects.
EOF
dpkg-deb --build "$DEB_ROOT" "$OUT/${BASE_NAME}.deb"

# Build the AppImage from a fresh portable tree after Debian staging.
(
    cd build
    ./src/BuildLinuxImage.sh -i
)
cp "build/BambuStudio_ubu64.AppImage" "$OUT/${BASE_NAME}.AppImage"
[ -x "$OUT/${BASE_NAME}.AppImage" ] || {
    echo "AppImage was not generated" >&2
    exit 1
}

CHECKSUM_FILES=("${BASE_NAME}.tar.gz")
for SUFFIX in tar.zst AppImage deb; do
    if [[ -f "$OUT/${BASE_NAME}.${SUFFIX}" ]]; then
        CHECKSUM_FILES+=("${BASE_NAME}.${SUFFIX}")
    fi
done
(
    cd "$OUT"
    sha256sum "${CHECKSUM_FILES[@]}"
) > "$OUT/${BASE_NAME}.sha256"
printf 'official UOS20E arm64 build complete: %s\n' "$VERSION"
