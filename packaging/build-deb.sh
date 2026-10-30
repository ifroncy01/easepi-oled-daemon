#!/usr/bin/env bash
#
# Build the .deb package for easepi-oled-daemon (EasePi-A2, arm64 only).
#
# Usage:
#   packaging/build-deb.sh
#
# Environment:
#   VERSION  override the package version (default: git describe, stripped of "v")
#   OUT      output directory (default: <repo>/dist)
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="easepi-oled-daemon"
ARCH="arm64"
OUT="${OUT:-$ROOT/dist}"

# Folders that must never be copied into the package root.
case "${1:-}" in
    ""|arm64|all) ;;
    *) echo "unsupported architecture: $1 (this package targets EasePi-A2 / arm64 only)" >&2; exit 1 ;;
esac

VERSION="${VERSION:-}"
if [ -z "$VERSION" ]; then
    VERSION="$(git -C "$ROOT" describe --tags --always 2>/dev/null)" || true
fi
VERSION="${VERSION:-1.0.0}"
VERSION="${VERSION#v}"

echo "==> building ${PKG} ${VERSION} for ${ARCH}"

FONT_SRC="$ROOT/packaging/assets/DejaVuSansMono.ttf"
[ -f "$FONT_SRC" ] || { echo "missing bundled font: $FONT_SRC" >&2; exit 1; }

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

mkdir -p "$stage/DEBIAN" \
         "$stage/usr/local/oled" \
         "$stage/usr/lib/systemd/system" \
         "$stage/etc/systemd/system/oled.service.d" \
         "$stage/etc/oled" \
         "$stage/usr/share/doc/${PKG}"

# 1. Static binaries: panel daemon and the web configuration UI
( cd "$ROOT" && CGO_ENABLED=0 GOOS=linux GOARCH="$ARCH" \
    go build -trimpath -ldflags="-s -w" -o "$stage/usr/local/oled/oled" . )
chmod 0755 "$stage/usr/local/oled/oled"
( cd "$ROOT" && CGO_ENABLED=0 GOOS=linux GOARCH="$ARCH" \
    go build -trimpath -ldflags="-s -w" -o "$stage/usr/local/oled/oled-web" ./cmd/oledweb )
chmod 0755 "$stage/usr/local/oled/oled-web"

# 2. Bundled font so the package works offline without fonts-dejavu-core
install -m 0644 "$FONT_SRC" "$stage/usr/local/oled/DejaVuSansMono.ttf"

# 3. Vendor systemd units plus an upgrade-safe local override drop-in
install -m 0644 "$ROOT/packaging/oled.service" \
    "$stage/usr/lib/systemd/system/oled.service"
install -m 0644 "$ROOT/packaging/oled-web.service" \
    "$stage/usr/lib/systemd/system/oled-web.service"
install -m 0644 "$ROOT/packaging/debian/oled-local.conf" \
    "$stage/etc/systemd/system/oled.service.d/10-easepi-a2.conf"

# 4. Default runtime configuration (conffile: edited values survive upgrades)
install -m 0644 "$ROOT/packaging/debian/config.json" "$stage/etc/oled/config.json"

# 5. Documentation
install -m 0644 "$ROOT/packaging/debian/copyright" \
    "$stage/usr/share/doc/${PKG}/copyright"
install -m 0644 "$ROOT/README.md" "$stage/usr/share/doc/${PKG}/README.md"

# 6. Control file, maintainer scripts and conffiles
size="$(du -sk "$stage/usr" "$stage/etc" | awk '{sum += $1} END {print sum}')"
sed -e "s/@VERSION@/${VERSION}/g" \
    -e "s/@SIZE@/${size}/g" \
    "$ROOT/packaging/debian/control" > "$stage/DEBIAN/control"

install -m 0755 "$ROOT/packaging/debian/postinst" "$stage/DEBIAN/postinst"
install -m 0755 "$ROOT/packaging/debian/prerm" "$stage/DEBIAN/prerm"
install -m 0755 "$ROOT/packaging/debian/postrm" "$stage/DEBIAN/postrm"

# Local override drop-in and runtime config are conffiles: local edits survive
# package and system upgrades.
printf '%s\n' "/etc/systemd/system/oled.service.d/10-easepi-a2.conf" \
    "/etc/oled/config.json" > "$stage/DEBIAN/conffiles"

# 7. Checksums so dpkg -V / dpkg --verify can validate installed files
( cd "$stage" && find . -type f ! -path './DEBIAN/*' -printf '%P\n' \
    | sort | xargs -r md5sum ) > "$stage/DEBIAN/md5sums"

# 8. File manifest: every path this package installs on the system, so a
#    store uninstaller (or any external tool) can remove them all.
mkdir -p "$OUT"
filelist="$OUT/${PKG}_${VERSION}_${ARCH}.filelist.txt"
( cd "$stage" && find . -type f ! -path './DEBIAN/*' -printf '/%P\n' | sort ) > "$filelist"

# 9. Assemble the package
out="$OUT/${PKG}_${VERSION}_${ARCH}.deb"
dpkg-deb --root-owner-group --build "$stage" "$out" >/dev/null
( cd "$OUT" && sha256sum "$(basename "$out")" > "$(basename "$out").sha256" )
echo "    -> $out"
echo "    -> ${out}.sha256"
echo "    -> $filelist"
echo "==> done"
