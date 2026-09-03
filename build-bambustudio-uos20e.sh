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

chmod 0755 build/src/BuildLinuxImage.sh
(
    cd build
    ./src/BuildLinuxImage.sh
)

VERSION=$(sed -n 's/^set(SLIC3R_VERSION "\([^"]*\)").*/\1/p' version.inc)
ARCH=$(dpkg --print-architecture)
[ -n "$VERSION" ] || { echo "could not determine BambuStudio version" >&2; exit 1; }

cp build/BambuStudio.tar "$OUT/BambuStudio_${VERSION}_uos20e_${ARCH}.tar"
tar -C build/package --numeric-owner --owner=0 --group=0 --sort=name \
    --mtime='UTC 1970-01-01' -czf \
    "$OUT/BambuStudio_${VERSION}_uos20e_${ARCH}.tar.gz" .
if command -v zstd >/dev/null 2>&1; then
    zstd -T0 -19 -f "$OUT/BambuStudio_${VERSION}_uos20e_${ARCH}.tar" \
        -o "$OUT/BambuStudio_${VERSION}_uos20e_${ARCH}.tar.zst"
fi
sha256sum "$OUT"/BambuStudio_*_uos20e_${ARCH}.tar* \
    > "$OUT/BambuStudio_${VERSION}_uos20e_${ARCH}.sha256"
printf 'official UOS20E arm64 build complete: %s\n' "$VERSION"
