#!/usr/bin/env bash
#
# EasePi OLED Daemon - one-line online installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ifroncy01/easepi-oled-daemon/main/install.sh | sudo bash
#
# Environment overrides:
#   OLED_VERSION   release tag to install (default: latest)
#   OLED_MIRROR    alternative download base URL (default: GitHub releases)
#
set -euo pipefail

REPO="ifroncy01/easepi-oled-daemon"
PKG="easepi-oled-daemon"
INSTALL_DIR="/usr/local/oled"
SERVICE="oled.service"
GH_API="https://api.github.com/repos/${REPO}"

red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
info()  { printf '\033[0;36m[INFO]\033[0m %s\n' "$*"; }
die()   { red "[ERROR] $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "please run as root:  curl -fsSL ... | sudo bash"

# ------------------------------------------------------------------ detect arch
case "$(uname -m)" in
    aarch64|arm64) ARCH=arm64 ;;
    x86_64|amd64)  ARCH=amd64 ;;
    *) die "unsupported architecture: $(uname -m)" ;;
esac
info "architecture: ${ARCH}"

# --------------------------------------------------------------- resolve version
VERSION="${OLED_VERSION:-}"
if [ -z "$VERSION" ]; then
    info "resolving latest release ..."
    VERSION="$(curl -fsSL "${GH_API}/releases/latest" \
        | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | head -n1 | sed -E 's/.*"([^"]+)"$/\1/')" || true
    [ -n "$VERSION" ] || die "could not resolve latest version (set OLED_VERSION=1.3.0 to override)"
fi
VER_NUM="${VERSION#v}"
info "version: ${VERSION}"

# ------------------------------------------------------------- install deps
if command -v apt-get >/dev/null 2>&1; then
    info "installing dependencies (i2c-tools, fonts-dejavu-core) ..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq || true
    apt-get install -y --no-install-recommends i2c-tools fonts-dejavu-core || true
fi

# ------------------------------------------------------------- download base url
BASE="${OLED_MIRROR:-https://github.com/${REPO}/releases/download/${VERSION}}"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

install_from_deb() {
    local deb="${PKG}_${VER_NUM}_${ARCH}.deb"
    info "downloading ${deb} ..."
    curl -fL --retry 3 --connect-timeout 15 -o "${TMP}/${deb}" "${BASE}/${deb}" || return 1

    info "installing ${deb} ..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get install -y "${TMP}/${deb}" || dpkg -i "${TMP}/${deb}"
    else
        dpkg -i "${TMP}/${deb}"
    fi
}

install_from_binary() {
    local bin="oled-linux-${ARCH}"
    info "falling back to raw binary (${bin}) ..."
    curl -fL --retry 3 --connect-timeout 15 -o "${TMP}/${bin}" "${BASE}/${bin}" \
        || die "download failed: ${BASE}/${bin}"

    install -d -m 0755 "${INSTALL_DIR}"
    install -m 0755 "${TMP}/${bin}" "${INSTALL_DIR}/oled"
    cat > "/etc/systemd/system/${SERVICE}" <<'UNIT'
[Unit]
Description=EasePi A2 OLED Display (Go)
After=network.target systemd-modules-load.service
StartLimitIntervalSec=0
ConditionPathExists=/dev/i2c-3

[Service]
Type=simple
ExecStart=/usr/local/oled/oled
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
}

# ------------------------------------------------------------- install
if install_from_deb; then
    info "installed via .deb"
else
    install_from_binary
    info "installed via raw binary"
fi

# ------------------------------------------------------------- enable & verify
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
    systemctl enable "${SERVICE}" || true
    systemctl restart "${SERVICE}" || true
fi

sleep 1
echo
green "==> ${PKG} ${VERSION} installed successfully"
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "${SERVICE}"; then
    green "oled.service is active"
else
    info "oled.service is not active (expected when no panel is attached on i2c-3)"
    info "diagnose with: sudo i2cdetect -y 3  &&  systemctl status ${SERVICE}"
fi
