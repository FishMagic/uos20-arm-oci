#!/usr/bin/env bash
# Turn a generated rootfs into a runnable arm64 image and an OCI archive.
# This script is intended for the native arm64 runner used by the workflow.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
ROOTFS_TAR="${1:-${UOS_ROOTFS_TAR:-$ROOT/rootfs.tar}}"
IMAGE="${2:-${UOS_IMAGE:-local/uos20e-arm64:latest}}"
OUT_DIR="${3:-${UOS_IMAGE_OUT:-$(dirname "$ROOTFS_TAR")}}"

[ "$(uname -m)" = aarch64 ] || { echo "native arm64 is required" >&2; exit 2; }
[ -f "$ROOTFS_TAR" ] || { echo "rootfs tar not found: $ROOTFS_TAR" >&2; exit 2; }
mkdir -p "$OUT_DIR"
CTX=$(mktemp -d)
trap 'rm -rf "$CTX"' EXIT
ln "$ROOTFS_TAR" "$CTX/rootfs.tar" 2>/dev/null || cp "$ROOTFS_TAR" "$CTX/rootfs.tar"
cp "$ROOT/Dockerfile" "$CTX/Dockerfile"
ROOTFS_SHA=$(sha256sum "$ROOTFS_TAR" | cut -d' ' -f1)

# Export a real OCI archive for registry/import tooling.
docker buildx build \
    --platform linux/arm64 \
    --build-arg UOS_ROOTFS_SHA256="$ROOTFS_SHA" \
    --output "type=oci,dest=$OUT_DIR/uos20e-arm64.oci.tar" \
    "$CTX"

# Also load a local image so the BambuStudio repository can run the exact same
# rootfs immediately, then save the Docker-compatible archive for CI caches.
docker import --platform linux/arm64 \
    --change 'ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
    --change 'WORKDIR /work' \
    --change 'ENTRYPOINT ["/bin/bash"]' \
    "$ROOTFS_TAR" "$IMAGE"
ARCH=$(docker image inspect "$IMAGE" --format '{{.Architecture}}')
[ "$ARCH" = arm64 ] || { echo "wrong image architecture: $ARCH" >&2; exit 1; }
docker save "$IMAGE" -o "$OUT_DIR/uos20e-arm64-image.tar"
if command -v zstd >/dev/null 2>&1; then
    zstd -T0 -19 -f "$OUT_DIR/uos20e-arm64.oci.tar" \
        -o "$OUT_DIR/uos20e-arm64.oci.tar.zst"
    zstd -T0 -19 -f "$OUT_DIR/uos20e-arm64-image.tar" \
        -o "$OUT_DIR/uos20e-arm64-image.tar.zst"
fi
printf 'UOS20E arm64 image exported: %s\n' "$IMAGE"
