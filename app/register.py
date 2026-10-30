#!/usr/bin/env python3
"""Register the OLED web UI as an iNextOS application.

iNextOS (RoceOS) recognises third-party apps by two artefacts only:
  * a row in installed_apps (drives the AppStore list and the "open" URL)
  * an entry in desktop_layouts.icon_positions (drives the desktop icon)
This script writes both, mirroring what the official installer does for
docker apps such as ddns-go (which also exposes its UI on a dedicated port).
Idempotent: re-running replaces the previous entries.
"""

import argparse
import base64
import json
import os
import sqlite3
import sys
import time

APP_ID = "oled"
LABEL = "OLED 显示"
DB_PATH = "/opt/roceos/data/roceos.db"

COMPOSE_STUB = (
    "# The OLED stack runs as host systemd services (oled.service / oled-web.service).\n"
    "# This file only exists so that iNextOS uninstall can run docker compose down.\n"
    "services: {}\n"
)

CREDENTIALS = {
    "note": "打开应用即可调整阈值、刷新间隔与平滑系数，保存后 1 秒内生效"
}


def connect(path: str) -> sqlite3.Connection:
    if not os.path.exists(path):
        sys.exit(f"database not found: {path} (iNextOS 未安装？)")
    con = sqlite3.connect(path, timeout=10)
    con.execute("PRAGMA busy_timeout=10000")
    return con


def table_columns(con: sqlite3.Connection, table: str) -> list:
    return [row[1] for row in con.execute("select * from pragma_table_info(?)", (table,))]


def now_utc() -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S+00:00", time.gmtime())


def icon_data_uri(path: str) -> str:
    """Return an inline data URI so the icon never depends on a reachable host."""
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
    except OSError:
        raw = (
            b'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">'
            b'<rect x="4" y="18" width="56" height="28" rx="5" fill="#4c8dff"/>'
            b'</svg>'
        )
    return "data:image/svg+xml;base64," + base64.b64encode(raw).decode("ascii")


def icon_entry(next_y: int, shortcut: str, port: int, icon_url: str) -> dict:
    return {
        "id": f"installed-{APP_ID}-managed",
        "x": 216,
        "y": next_y,
        "label": LABEL,
        "iconType": "dynamic",
        "dynamicIconUrl": icon_url,
        "component": "WebAppWindow",
        "windowTitle": LABEL,
        "shortcutUrl": shortcut,
        "webappPort": port,
        "openMode": "iframe",
    }


def register(con: sqlite3.Connection, host: str, port: int, version: str, icon_url: str) -> None:
    cols = table_columns(con, "installed_apps")
    ts = now_utc()
    shortcut = f"http://{host}:{port}"
    row = {
        "user_id": 1,
        "app_id": APP_ID,
        "app_type": "docker",
        "name": LABEL,
        "icon_url": icon_url,
        "version": version,
        "status": "running",
        "config": json.dumps({"WEB_PORT": port}),
        "compose_file": COMPOSE_STUB,
        "install_path": "/opt/roceos/apps/oled",
        "window_type": "webapp",
        "webapp_port": port,
        "webapp_url": "/",
        "web_path": "",
        "credentials": json.dumps(CREDENTIALS, ensure_ascii=False),
        "error_msg": "",
        "created_at": ts,
        "updated_at": ts,
    }
    payload = {k: v for k, v in row.items() if k in cols}
    con.execute("delete from installed_apps where app_id = ?", (APP_ID,))
    names = ", ".join(f'"{k}"' for k in payload)
    marks = ", ".join("?" for _ in payload)
    con.execute(f"insert into installed_apps ({names}) values ({marks})", tuple(payload.values()))
    print(f"==> installed_apps: {APP_ID} {version} (webapp_port={port})")

    os.makedirs("/opt/roceos/apps/oled", exist_ok=True)
    with open("/opt/roceos/apps/oled/docker-compose.yml", "w", encoding="utf-8") as fh:
        fh.write(COMPOSE_STUB)

    updated = 0
    for layout_id, positions in con.execute(
        "select id, icon_positions from desktop_layouts"
    ).fetchall():
        try:
            items = json.loads(positions) if positions else []
        except ValueError:
            items = []
        items = [i for i in items if not str(i.get("id", "")).startswith(f"installed-{APP_ID}")]
        ys = [i.get("y", 0) for i in items if isinstance(i, dict)]
        next_y = (max(ys) + 110) if ys else 110
        items.append(icon_entry(next_y, shortcut, port, icon_url))
        con.execute(
            "update desktop_layouts set icon_positions = ?, updated_at = ? where id = ?",
            (json.dumps(items, ensure_ascii=False), now_utc(), layout_id),
        )
        updated += 1
        print(f"==> desktop_layouts: icon added at x=216 y={next_y} (layout {layout_id})")
    if updated == 0:
        print("warning: no desktop_layouts row found, icon not added", file=sys.stderr)


def unregister(con: sqlite3.Connection) -> None:
    con.execute("delete from installed_apps where app_id = ?", (APP_ID,))
    for layout_id, positions in con.execute(
        "select id, icon_positions from desktop_layouts"
    ).fetchall():
        if not positions:
            continue
        try:
            items = json.loads(positions)
        except ValueError:
            continue
        kept = [i for i in items if not str(i.get("id", "")).startswith(f"installed-{APP_ID}")]
        con.execute(
            "update desktop_layouts set icon_positions = ?, updated_at = ? where id = ?",
            (json.dumps(kept, ensure_ascii=False), now_utc(), layout_id),
        )
    print(f"==> removed {APP_ID} from installed_apps and desktop layout")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default=DB_PATH)
    ap.add_argument("--host", required=False, default="")
    ap.add_argument("--port", type=int, default=8099)
    ap.add_argument("--version", default="0.0.0")
    ap.add_argument("--icon-file", default="")
    ap.add_argument("--unregister", action="store_true")
    args = ap.parse_args()

    con = connect(args.db)
    try:
        with con:
            if args.unregister:
                unregister(con)
            else:
                icon_url = icon_data_uri(args.icon_file) if args.icon_file else ""
                register(con, args.host, args.port, args.version, icon_url)
    finally:
        con.close()


if __name__ == "__main__":
    main()
