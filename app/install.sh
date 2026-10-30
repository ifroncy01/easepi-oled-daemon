#!/usr/bin/env bash
#
# Install the OLED configuration app on iNextOS (EasePi-A2).
#
# The script does three things:
#   1. install (or upgrade) the OLED panel daemon package
#   2. install and start oled-web, the web configuration UI on port 8099
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
VERSION="${APP_VERSION:-1.6.0}"
ROCEOS_DB="/opt/roceos/data/roceos.db"
NGINX_CONF="/etc/nginx/conf.d/roceos-apps/${APP_ID}.conf"

log()  { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请以 root 运行：sudo bash install.sh"
case "$(uname -m)" in
    aarch64|arm64) ;;
    *) die "仅支持 arm64 设备（EasePi-A2），当前为 $(uname -m)" ;;
esac

command -v python3 >/dev/null 2>&1 || die "缺少 python3（iNextOS 自带，请检查系统）"
[ -x "$HERE/oled-web" ] || die "缺少 oled-web 二进制，请使用完整的应用包（dist/app/）"

HAS_ROCEOS=0
[ -d /opt/roceos ] && HAS_ROCEOS=1
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -n "$IP" ] || IP="127.0.0.1"

# --- 1. panel daemon -------------------------------------------------------
deb="$(find "$HERE" -maxdepth 1 -name 'easepi-oled-daemon_*_arm64.deb' | head -1 || true)"
if [ -n "$deb" ]; then
    log "安装/升级守护进程 $(basename "$deb")"
    dpkg -i "$deb" >/dev/null
elif ! dpkg -s easepi-oled-daemon >/dev/null 2>&1; then
    die "本机未安装 OLED 守护进程，且应用包内没有 .deb；请先执行项目根目录的 install.sh"
else
    log "守护进程已安装：$(dpkg-query -W -f='${Version}' easepi-oled-daemon)"
fi
systemctl enable --quiet oled.service || warn "无法启用 oled.service"
systemctl restart oled.service || warn "oled.service 启动失败，请检查 /dev/i2c-3 与面板连接"

# --- 2. web UI ------------------------------------------------------------
log "安装 oled-web 到 /usr/local/oled/oled-web"
install -m 0755 "$HERE/oled-web" /usr/local/oled/oled-web
install -m 0644 "$HERE/oled-web.service" /usr/lib/systemd/system/oled-web.service
sed -i "s/-port 8099/-port ${PORT}/" /usr/lib/systemd/system/oled-web.service

systemctl daemon-reload
systemctl enable --quiet oled-web.service
systemctl restart oled-web.service

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
