#!/usr/bin/env bash
#
# Install the OLED configuration app on iNextOS (EasePi-A2).
#
# The script does three things:
#   1. install (or upgrade) the OLED package: panel daemon + web UI (both
#      binaries and both systemd units ship inside the .deb)
#   2. apply an optional non-default web port through a systemd drop-in
#   3. register the app inside iNextOS: installed_apps row + desktop icon
#
# iNextOS exposes third-party apps on their own port (like ddns-go), so
# oled-web listens on the LAN and the desktop icon opens it in an iframe.
#
# Usage:
#   sudo bash install.sh
#   sudo OLEDWEB_PORT=8099 bash install.sh     # override the port
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ID="oled"
LABEL="OLED 显示"
PORT="${OLEDWEB_PORT:-8099}"
VERSION="${APP_VERSION:-}"
ROCEOS_DB="/opt/roceos/data/roceos.db"
NGINX_CONF="/etc/nginx/conf.d/roceos-apps/${APP_ID}.conf"
DROPIN_DIR="/etc/systemd/system/oled-web.service.d"
DROPIN="${DROPIN_DIR}/10-port.conf"

# The package may sit next to this script or in a debs/ sub-directory (store layout).
deb="$(find "$HERE" "$HERE/debs" -maxdepth 1 -name 'easepi-oled-daemon_*_arm64.deb' 2>/dev/null | head -1 || true)"
if [ -z "$VERSION" ] && [ -n "$deb" ]; then
    VERSION="$(basename "$deb" | sed -E 's/^easepi-oled-daemon_(.+)_arm64\.deb$/\1/')"
fi

log()  { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请以 root 运行：sudo bash install.sh"
case "$(uname -m)" in
    aarch64|arm64) ;;
    *) die "仅支持 arm64 设备（EasePi-A2），当前为 $(uname -m)" ;;
esac

command -v python3 >/dev/null 2>&1 || die "缺少 python3（iNextOS 自带，请检查系统）"

HAS_ROCEOS=0
[ -d /opt/roceos ] && HAS_ROCEOS=1
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -n "$IP" ] || IP="127.0.0.1"

# --- 1. package (daemon + web UI) ------------------------------------------
if [ -n "$deb" ]; then
    log "安装/升级 $(basename "$deb")"
    dpkg -i "$deb" >/dev/null
elif dpkg -s easepi-oled-daemon >/dev/null 2>&1; then
    log "软件包已安装：$(dpkg-query -W -f='${Version}' easepi-oled-daemon)"
else
    die "本机未安装 easepi-oled-daemon，且应用包内没有 .deb；请先执行项目根目录的 install.sh"
fi
[ -x /usr/local/oled/oled ] || die "缺少 /usr/local/oled/oled，安装可能失败"
[ -x /usr/local/oled/oled-web ] || die "缺少 /usr/local/oled/oled-web，安装可能失败"
[ -f /usr/lib/systemd/system/oled-web.service ] || die "缺少 oled-web.service 单元"

# --- 2. optional port override ---------------------------------------------
# The unit ships with -port 8099; any other port is applied through a drop-in
# so the packaged unit stays untouched (dpkg -V keeps passing).
if [ "$PORT" != "8099" ]; then
    log "配置网页端口 ${PORT}（drop-in ${DROPIN}）"
    mkdir -p "$DROPIN_DIR"
    cat > "$DROPIN" <<EOF
[Service]
ExecStart=
ExecStart=/usr/local/oled/oled-web -bind 0.0.0.0 -port ${PORT}
EOF
elif [ -f "$DROPIN" ]; then
    rm -f "$DROPIN"
    rmdir "$DROPIN_DIR" 2>/dev/null || true
fi

systemctl daemon-reload
systemctl enable --quiet oled.service || warn "无法启用 oled.service"
systemctl restart oled.service || warn "oled.service 启动失败，请检查 /dev/i2c-3 与面板连接"
systemctl enable --quiet oled-web.service || warn "无法启用 oled-web.service"
systemctl restart oled-web.service || warn "oled-web.service 启动失败"

for _ in $(seq 1 25); do
    if curl -fsS "http://127.0.0.1:${PORT}/api/health" >/dev/null 2>&1; then
        HEALTHY=1; break
    fi
    sleep 0.2
done
[ "${HEALTHY:-0}" -eq 1 ] || die "oled-web 启动失败：journalctl -u oled-web.service -n 30"

# --- 3. iNextOS registration ---------------------------------------------
# Older installs dropped a nginx snippet here; the platform never included it.
if [ -f "$NGINX_CONF" ]; then
    rm -f "$NGINX_CONF"
    nginx -t >/dev/null 2>&1 && nginx -s reload || true
fi

if [ "$HAS_ROCEOS" -eq 1 ]; then
    # Ship the uninstaller inside the app directory so a full purge can be run
    # from the install path without the release bundle (SSH or a platform hook).
    APP_DIR="/opt/roceos/apps/${APP_ID}"
    if [ -f "$HERE/uninstall.sh" ] && [ -f "$HERE/register.py" ]; then
        mkdir -p "$APP_DIR"
        install -m 0755 "$HERE/uninstall.sh" "$APP_DIR/uninstall.sh"
        install -m 0755 "$HERE/register.py" "$APP_DIR/register.py"
        log "卸载脚本已落地：${APP_DIR}/uninstall.sh --purge"
    else
        warn "安装包内缺少 uninstall.sh/register.py，跳过卸载脚本落地"
    fi

    log "注册到应用中心（installed_apps / desktop_layouts）"
    python3 "$HERE/register.py" --db "$ROCEOS_DB" --host "$IP" --port "$PORT" \
        --version "$VERSION" --icon-file "$HERE/icon.svg"
else
    warn "未检测到 iNextOS（/opt/roceos），跳过应用中心注册，可直接访问网页"
fi

# --- 4. summary ----------------------------------------------------------
echo
echo "==> ${LABEL} 应用安装完成"
echo "    守护进程: oled.service ($(systemctl is-active oled.service), 开机自启 $(systemctl is-enabled oled.service 2>/dev/null || echo unknown))"
echo "    配置服务: oled-web.service (${IP}:${PORT})"
echo "    配置文件: /etc/oled/config.json"
if [ "$HAS_ROCEOS" -eq 1 ]; then
    echo "    打开方式: iNextOS 桌面「${LABEL}」图标，或直接访问 http://${IP}:${PORT}/"
else
    echo "    打开方式: http://${IP}:${PORT}/"
fi
