#!/usr/bin/env bash
#
# Remove the OLED configuration app from iNextOS.
#
#   sudo bash uninstall.sh           # remove web UI, keep the panel daemon
#   sudo bash uninstall.sh --purge   # also remove the panel daemon and its config
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ID="oled"
NGINX_CONF="/etc/nginx/conf.d/roceos-apps/${APP_ID}.conf"
ROCEOS_DB="/opt/roceos/data/roceos.db"
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

log() { printf '[INFO] %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "请以 root 运行" >&2; exit 1; }

log "停止并移除 oled-web.service"
systemctl disable --now oled-web.service 2>/dev/null || true
rm -f /usr/lib/systemd/system/oled-web.service /usr/local/oled/oled-web
systemctl daemon-reload

if [ -f "$NGINX_CONF" ]; then
    log "移除遗留的 nginx 片段 ${NGINX_CONF}"
    rm -f "$NGINX_CONF"
    nginx -t >/dev/null 2>&1 && nginx -s reload || true
fi

if [ -f "$ROCEOS_DB" ] && [ -f "$HERE/register.py" ]; then
    log "从应用中心注销 ${APP_ID}"
    python3 "$HERE/register.py" --db "$ROCEOS_DB" --unregister || true
fi
rm -rf /opt/roceos/apps/${APP_ID} 2>/dev/null || true

if [ "$PURGE" -eq 1 ]; then
    log "彻底移除 OLED 守护进程"
    dpkg -P easepi-oled-daemon 2>/dev/null || true
    rm -rf /usr/local/oled /etc/oled
fi

echo
echo "==> ${APP_ID} 应用已卸载$([ "$PURGE" -eq 1 ] && echo "（含守护进程）")"
