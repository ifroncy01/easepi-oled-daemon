#!/usr/bin/env bash
#
# Build .deb packages for easepi-oled-daemon.
#
# Usage:
#   packaging/build-deb.sh [arm64|amd64|all]
#
# Environment:
#   VERSION  override the package version (default: git describe, stripped of "v")
#   OUT      output directory (default: <repo>/dist)
#
set -euo pipefail

ARCH_ARG="${1:-all}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="easepi-oled-daemon"
OUT="${OUT:-$ROOT/dist}"

VERSION="${VERSION:-}"
if [ -z "$VERSION" ]; then
    VERSION="$(git -C "$ROOT" describe --tags --always 2>/dev/null)" || true
fi
VERSION="${VERSION:-1.0.0}"
VERSION="${VERSION#v}"

build_one() {
    local arch="$1"
    echo "==> building ${PKG} ${VERSION} for ${arch}"

    local stage
    stage="$(mktemp -d)"
    trap 'rm -rf "$stage"' RETURN

    mkdir -p "$stage/DEBIAN" \
             "$stage/usr/local/oled" \
             "$stage/etc/systemd/system"

    # 1. Static binary
    ( cd "$ROOT" && CGO_ENABLED=0 GOOS=linux GOARCH="$arch" \
        go build -trimpath -ldflags="-s -w" -o "$stage/usr/local/oled/oled" main.go )
    chmod 0755 "$stage/usr/local/oled/oled"

    # 2. systemd unit
    install -m 0644 "$ROOT/packaging/oled.service" \
        "$stage/etc/systemd/system/oled.service"

    # 3. control file + maintainer scripts
    local size
    size="$(du -sk "$stage" | awk '{print $1}')"
    sed -e "s/@VERSION@/${VERSION}/g" \
        -e "s/@ARCH@/${arch}/g" \
        -e "s/@SIZE@/${size}/g" \
        "$ROOT/packaging/debian/control" > "$stage/DEBIAN/control"

    local script
    for script in postinst prerm postrm; do
        install -m 0755 "$ROOT/packaging/debian/$script" "$stage/DEBIAN/$script"
    done

    # 4. Assemble the package
    mkdir -p "$OUT"
    local out="$OUT/${PKG}_${VERSION}_${arch}.deb"
    dpkg-deb --root-owner-group --build "$stage" "$out" >/dev/null
    echo "    -> $out"
}

case "$ARCH_ARG" in
    all)         build_one arm64; build_one amd64 ;;
    arm64|amd64) build_one "$ARCH_ARG" ;;
    *)           echo "unknown architecture: $ARCH_ARG (use arm64|amd64|all)" >&2; exit 1 ;;
esac

echo "==> done"
