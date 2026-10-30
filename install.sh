#!/usr/bin/env bash
#
# EasePi OLED Daemon - one-command installer (EasePi-A2 / arm64 only)
#
# Online:
#   curl -fsSL https://raw.githubusercontent.com/ifroncy01/easepi-oled-daemon/main/install.sh | sudo bash
#
# Offline (deb already copied to the device):
#   sudo bash install.sh /path/to/easepi-oled-daemon_<version>_arm64.deb
#
# Environment overrides:
#   OLED_MODE        auto (default) | app | daemon
#                    auto: install the app bundle (panel + web UI + desktop
#                    icon) when iNextOS is detected, otherwise the deb only
#   OLED_VERSION     release tag to install (default: latest release)
#   OLED_MIRROR      alternative download base URL (default: GitHub releases)
#   OLED_LOCAL_DEB   path to a local .deb (same as passing it as the first argument)
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
warn()  { printf '\033[0;33m[WARN]\033[0m %s\n' "$*"; }
die()   { red "[ERROR] $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "please run as root:  curl -fsSL ... | sudo bash"

# --------------------------------------------------------------- architecture
case "$(uname -m)" in
    aarch64|arm64) ARCH=arm64 ;;
    *) die "unsupported architecture: $(uname -m) (this package targets EasePi-A2 / arm64 only)" ;;
esac
info "architecture: ${ARCH}"

# ----------------------------------------------------------------------- mode
MODE="${OLED_MODE:-auto}"
if [ "${MODE}" = "auto" ]; then
    if [ -d /opt/roceos ]; then MODE="app"; else MODE="daemon"; fi
fi
case "${MODE}" in
    app|daemon) ;;
    *) die "invalid OLED_MODE: ${MODE} (expected auto, app or daemon)" ;;
esac
info "mode: ${MODE}"

# ------------------------------------------------------------------ local deb
LOCAL_DEB="${OLED_LOCAL_DEB:-${1:-}}"
if [ -z "${LOCAL_DEB}" ]; then
    # Fall back to a .deb sitting next to this script (offline hand-off).
    SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
    LOCAL_DEB="$(ls -1 "${SELF_DIR}"/*_arm64.deb 2>/dev/null | head -n1 || true)"
fi
if [ -n "${LOCAL_DEB}" ] && [ "${MODE}" = "app" ]; then
    warn "a local .deb was given, falling back to daemon-only install"
    MODE="daemon"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# --------------------------------------------------------------------- resolve
if [ -n "${LOCAL_DEB}" ]; then
    [ -f "${LOCAL_DEB}" ] || die "local package not found: ${LOCAL_DEB}"
    DEB="${LOCAL_DEB}"
    info "using local package: ${DEB}"
else
    VERSION="${OLED_VERSION:-}"
    if [ -z "${VERSION}" ]; then
        info "resolving latest release ..."
        VERSION="$(curl -fsSL --connect-timeout 15 "${GH_API}/releases/latest" \
            | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' \
            | head -n1 | sed -E 's/.*"([^"]+)"$/\1/')" || true
        [ -n "${VERSION}" ] || die "could not resolve latest release (set OLED_VERSION=1.5.0 or pass a local .deb)"
    fi
    VER_NUM="${VERSION#v}"
    # Accept both "1.6.4" and "v1.6.4"; release tags always carry the v prefix.
    case "${VERSION}" in
        v*) TAG="${VERSION}" ;;
        *) TAG="v${VERSION}" ;;
    esac
    info "version: ${TAG}"

    BASE="${OLED_MIRROR:-https://github.com/${REPO}/releases/download/${TAG}}"

    if [ "${MODE}" = "app" ]; then
        APP="easepi-oled-app_${VER_NUM}_${ARCH}.tar.gz"
        info "downloading ${APP} ..."
        curl -fL --retry 3 --connect-timeout 15 -o "${TMP}/${APP}" "${BASE}/${APP}" \
            || die "download failed: ${BASE}/${APP}"
        if curl -fsL --retry 2 --connect-timeout 15 -o "${TMP}/${APP}.sha256" "${BASE}/${APP}.sha256" 2>/dev/null; then
            ( cd "${TMP}" && sha256sum -c "${APP}.sha256" ) || die "checksum mismatch"
            info "checksum verified"
        else
            warn "no .sha256 published for this release, skipping verification"
        fi

        mkdir -p "${TMP}/oledapp"
        tar -xzf "${TMP}/${APP}" -C "${TMP}/oledapp"
        info "installing app bundle (daemon + web UI + desktop icon) ..."
        bash "${TMP}/oledapp/install.sh"
        INSTALLED_APP=1
    else
        DEB="${TMP}/${PKG}_${VER_NUM}_${ARCH}.deb"

        info "downloading $(basename "${DEB}") ..."
        curl -fL --retry 3 --connect-timeout 15 -o "${DEB}" "${BASE}/$(basename "${DEB}")" \
            || die "download failed: ${BASE}/$(basename "${DEB}")"

        if curl -fsL --retry 2 --connect-timeout 15 -o "${DEB}.sha256" "${BASE}/$(basename "${DEB}").sha256" 2>/dev/null; then
            ( cd "${TMP}" && sha256sum -c "$(basename "${DEB}").sha256" ) || die "checksum mismatch"
            info "checksum verified"
        else
            warn "no .sha256 published for this release, skipping verification"
        fi
    fi
fi

# ------------------------------------------------------------------- install
if [ "${INSTALLED_APP:-0}" -ne 1 ]; then
    info "installing $(basename "${DEB}") ..."
    # The package is self-contained (static binary + bundled font), so dpkg alone
    # is enough and no network access is required.
    if ! dpkg -i "${DEB}" >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y "${DEB}" || die "dpkg/apt install failed"
        else
            die "dpkg install failed"
        fi
    fi
fi

# ------------------------------------------------------- enable and restart
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
    systemctl unmask "${SERVICE}" >/dev/null 2>&1 || true
    systemctl enable "${SERVICE}" || true
    systemctl restart "${SERVICE}" || true
    if [ "${MODE}" = "app" ]; then
        systemctl enable oled-web.service >/dev/null 2>&1 || true
        systemctl restart oled-web.service >/dev/null 2>&1 || true
    fi
fi

# --------------------------------------------------------------- diagnostics
# i2c-tools is optional (only used for troubleshooting), never required.
if command -v apt-get >/dev/null 2>&1 && ! command -v i2cdetect >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends i2c-tools >/dev/null 2>&1 || true
fi

# ------------------------------------------------------------------- verify
sleep 3
echo
green "==> ${PKG} installed"
dpkg-query -W -f='    package: ${Package} ${Version} (${Architecture})\n' "${PKG}" 2>/dev/null || true
printf '    install dir: %s\n' "${INSTALL_DIR}"
if [ -e /dev/i2c-3 ]; then
    printf '    i2c bus: /dev/i2c-3 present\n'
else
    printf '    i2c bus: /dev/i2c-3 missing (check device tree / kernel)\n'
fi
IP="$(ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
[ -n "${IP}" ] || IP="$(hostname -I 2>/dev/null | awk '{print $1}')"

if systemctl is-active --quiet "${SERVICE}"; then
    green "==> ${SERVICE} is active (OLED panel driven on i2c-3 / 0x3C)"
    [ -n "${IP}" ] && printf '    panel shows IP: %s\n' "${IP}"
else
    warn "${SERVICE} is not active - see diagnostics below"
    printf '\n'
    systemctl status "${SERVICE}" --no-pager -n 10 || true
    journalctl -u "${SERVICE}" -n 15 --no-pager || true
    printf '\n'
    info "troubleshoot:"
    printf '    sudo i2cdetect -y 3                    # expect 3c at address 0x3c\n'
    printf '    sudo /usr/local/oled/oled              # run in foreground to see errors\n'
fi

if [ "${MODE}" = "app" ]; then
    if systemctl is-active --quiet oled-web.service; then
        green "==> oled-web.service is active (web configuration UI)"
        [ -n "${IP}" ] && printf '    open: http://%s:8099/  (or the iNextOS desktop icon)\n' "${IP}"
    else
        warn "oled-web.service is not active - check: journalctl -u oled-web.service -n 30"
    fi
fi

echo
info "manage with: systemctl status|restart ${SERVICE}, journalctl -u ${SERVICE} -f"
