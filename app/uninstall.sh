#!/usr/bin/env bash
#
# Remove the OLED app from iNextOS.
#
#   sudo bash uninstall.sh           # unregister + disable the web UI, keep the daemon
#   sudo bash uninstall.sh --purge   # purge the package: every installed file is removed
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ID="oled"
NGINX_CONF="/etc/nginx/conf.d/roceos-apps/${APP_ID}.conf"
ROCEOS_DB="/opt/roceos/data/roceos.db"
DROPIN_DIR="/etc/systemd/system/oled-web.service.d"
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

log() { printf '[INFO] %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "请以 root 运行" >&2; exit 1; }

if [ "$PURGE" -eq 1 ]; then
    log "purge easepi-oled-daemon（守护进程 + 网页 + 配置）"
    dpkg -P easepi-oled-daemon 2>/dev/null || true
    # Safety net: drop anything the package could not remove (partial state).
    rm -rf /usr/local/oled /etc/oled "$DROPIN_DIR"
    rm -f /usr/lib/systemd/system/oled-web.service /usr/lib/systemd/system/oled.service
    systemctl daemon-reload
else
    log "停止并禁用 oled-web.service（保留守护进程）"
    systemctl disable --now oled-web.service 2>/dev/null || true
    rm -rf "$DROPIN_DIR"
    systemctl daemon-reload
fi

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

echo
echo "==> ${APP_ID} 应用已卸载$([ "$PURGE" -eq 1 ] && echo "（含守护进程与全部文件）" || echo "（网页已禁用，守护进程保留）")"
