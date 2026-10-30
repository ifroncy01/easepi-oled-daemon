#!/usr/bin/env bash
#
# Build the store submission draft bundle for iNextOS (EasePi-A2, arm64).
#
# Layout expected by the platform's SystemBundleInstaller:
#   manifest.json            app catalog entry (draft, placeholders for URLs)
#   required-packages.json   system dependency declaration
#   filelist.txt             every system path the package installs
#   debs/<deb>               offline package(s)
#
# Usage:
#   packaging/build-store.sh            # uses dist/<deb> built by build-deb.sh
#   VERSION=1.6.4 packaging/build-store.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="easepi-oled-daemon"
ARCH="arm64"
OUT="${OUT:-$ROOT/dist}"

VERSION="${VERSION:-}"
if [ -z "$VERSION" ]; then
    VERSION="$(git -C "$ROOT" describe --tags --always 2>/dev/null)" || true
fi
VERSION="${VERSION:-1.0.0}"
VERSION="${VERSION#v}"

DEB="$OUT/${PKG}_${VERSION}_${ARCH}.deb"
FILELIST="$OUT/${PKG}_${VERSION}_${ARCH}.filelist.txt"
[ -f "$DEB" ] || { echo "missing $DEB (run packaging/build-deb.sh first)" >&2; exit 1; }
[ -f "$FILELIST" ] || { echo "missing $FILELIST" >&2; exit 1; }

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

mkdir -p "$stage/debs"
install -m 0644 "$DEB" "$stage/debs/"
install -m 0644 "$FILELIST" "$stage/filelist.txt"
install -m 0644 "$ROOT/packaging/store/required-packages.json" "$stage/required-packages.json"

# Bundle size is known once the deb is copied; the manifest records it.
size=$(stat -c %s "$DEB")
sed -e "s/__VERSION__/${VERSION}/g" \
    -e "s/__BUNDLE_SIZE__/${size}/g" \
    "$ROOT/packaging/store/manifest.json" > "$stage/manifest.json"

bundle="$OUT/easepi-oled-store_${VERSION}_${ARCH}.tar.gz"
tar -C "$stage" -czf "$bundle" .
( cd "$OUT" && sha256sum "$(basename "$bundle")" > "$(basename "$bundle").sha256" )

echo "    -> $bundle"
echo "    -> ${bundle}.sha256"
echo "    -> draft contents:"
tar -tzf "$bundle" | sed 's/^/       /'
echo
echo "note: manifest.json keeps __BUNDLE_URL__ / __BUNDLE_SHA256__ / __ICON_URL__"
echo "      placeholders; fill them with the URL and the .sha256 printed above"
echo "      once the bundle is hosted, then re-upload if the store recomputes it."
