# EasePi OLED Daemon

SSD1306 OLED display daemon for EasePi-A2 (RK3568) IoT gateway.  
Displays system status (CPU, temperature, network, IP) on a 128x32 I2C OLED screen.

English | [简体中文](README.zh-CN.md)

## Features

- **Multi-mode display**: idle (1-line IP), CPU (2-line), NET (2-line), heavy load (3-line)
- **Auto-switching**: toggles modes based on CPU usage (>30%), temperature (>60°C), network traffic (>100KB/s)
- **EMA smoothing**: exponential moving average for smooth CPU/network display
- **Font rendering**: DejaVu Sans Mono is bundled inside the package
- **Self-contained runtime**: no `i2c-tools` or `fonts-dejavu-core` dependency, panel is probed directly over I2C
- **Signal handling**: graceful shutdown on SIGTERM/SIGINT

## Hardware

- **Display**: SSD1306 128x32 OLED on I2C bus 3 (address 0x3C)
- **Board**: EasePi-A2 (Rockchip RK3568) — arm64 only

## Install

### One-command online install

```bash
ssh root@<device-ip>
curl -fsSL https://raw.githubusercontent.com/ifroncy01/easepi-oled-daemon/main/install.sh | sudo bash
```

The script resolves the latest release and downloads either the app bundle or
the plain `.deb`:

- `OLED_MODE=auto` (default) — installs the **app bundle** (panel daemon + web
  UI on port 8099 + desktop icon) when iNextOS (`/opt/roceos`) is detected,
  otherwise the `.deb` alone.
- `OLED_MODE=app` — force the app bundle; `OLED_MODE=daemon` — force the deb only.

SHA256 is verified before installing, then `oled.service` (and `oled-web.service`
in app mode) is enabled, started, and checked. Pin a version with
`sudo OLED_VERSION=1.5.0 bash install.sh`.

### Offline install (recommended for air-gapped devices)

```bash
scp dist/easepi-oled-daemon_1.5.0_arm64.deb root@<device-ip>:/tmp/
ssh root@<device-ip> 'dpkg -i /tmp/easepi-oled-daemon_1.5.0_arm64.deb'
```

`dpkg -i` alone is enough: the binary is static and the font is bundled, so no
APT download is needed. Alternatively copy `install.sh` next to the `.deb` and
run `sudo bash install.sh` — it detects the local package automatically.

### Debian package

```bash
sudo dpkg -i easepi-oled-daemon_1.5.0_arm64.deb   # or: sudo apt-get install ./easepi-oled-daemon_1.5.0_arm64.deb
```

The package installs:

| Path | Purpose |
|---|---|
| `/usr/local/oled/oled` | static arm64 daemon binary |
| `/usr/local/oled/DejaVuSansMono.ttf` | bundled font (offline rendering) |
| `/usr/lib/systemd/system/oled.service` | vendor systemd unit |
| `/etc/systemd/system/oled.service.d/10-easepi-a2.conf` | local override drop-in (**conffile**, survives upgrades) |

Local edits to the drop-in are preserved across package and system upgrades;
`oled.service` is enabled and (re)started by the package's `postinst`.

### Build the .deb locally

```bash
make deb                         # arm64 only, output in dist/ (+ .sha256)
make app                         # daemon + web UI bundle for iNextOS
VERSION=1.5.0 packaging/build-deb.sh
```

## Usage

```bash
# Run in foreground
sudo /usr/local/oled/oled

# Manage the installed service
sudo systemctl status oled.service
sudo systemctl restart oled.service
```

## Runtime configuration

The daemon reads `/etc/oled/config.json` (a conffile, shipped with the package)
and hot-reloads it within one poll interval, so changes apply without a restart.
Defaults reproduce the historical behaviour:

| Key | Default | Meaning |
|---|---|---|
| `cpu_high_threshold` | `30` | CPU % above which the CPU mode is shown |
| `temp_high_threshold` | `60` | SoC °C above which the CPU mode is shown |
| `net_high_threshold` | `100` | KB/s above which the NET mode is shown |
| `silent` | `false` | Discard log output |

Fixed in code (shown read-only in the web UI, any value in the file is ignored):

| Constant | Value | Meaning |
|---|---|---|
| `I2C_BUS` | `3` | I2C bus of the panel |
| `DEVICE_ADDR` | `0x3c` | SSD1306 address |
| `WIDTH` / `HEIGHT` | `128` / `32` | Panel geometry |
| `EMA_ALPHA` | `0.3` | Smoothing factor for network speed |
| `REFRESH_MS` | `950` | Redraw interval in milliseconds |
| `HYSTERESIS` | `3` | Consecutive hits needed before switching mode |

## iNextOS app (web configuration UI)

`make app` builds `dist/easepi-oled-app_<version>_arm64.tar.gz`, a self-contained
bundle that installs the daemon (if missing), the `oled-web` configuration UI and
a desktop icon inside iNextOS.

```bash
scp dist/easepi-oled-app_1.6.0_arm64.tar.gz root@<device-ip>:/tmp/
ssh root@<device-ip> 'mkdir -p /tmp/oledapp && tar xzf /tmp/easepi-oled-app_1.6.0_arm64.tar.gz -C /tmp/oledapp && bash /tmp/oledapp/install.sh'
```

After install the app appears on the iNextOS desktop as **OLED 显示** and is
reachable at `http://<device-ip>:8099/` as well.

What the installer does:

1. `dpkg -i` of the bundled daemon package (upgrade-safe, conffile preserved)
2. installs `oled-web` (`/usr/local/oled/oled-web`) and `oled-web.service`
3. registers the app the same way iNextOS does for docker apps: an
   `installed_apps` row (`webapp_port=8099`) plus a `desktop_layouts` icon entry
4. removes the legacy nginx snippet, which iNextOS never included

The UI exposes a status dashboard, service start/stop/restart, the full config
form, a live `journalctl` view, and an HTTP API:

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/status` | service state, pid, panel presence |
| GET | `/api/config` | current configuration |
| POST | `/api/config` | save (`{"config":{...},"restart":false}`) |
| POST | `/api/service` | `{"action":"start\|stop\|restart\|enable\|disable"}` |
| GET | `/api/logs?tail=50` | daemon journal tail |

The UI is unauthenticated and restricted to private/link-local source addresses;
do not port-forward 8099 to the internet.

Uninstall (keeps the panel daemon; add `--purge` to remove it too):

```bash
ssh root@<device-ip> 'bash /tmp/oledapp/uninstall.sh'
```

## Verify

```bash
dpkg -V easepi-oled-daemon        # file integrity (md5sums shipped in the package)
systemctl is-enabled oled.service # enabled
systemctl is-active oled.service  # active
journalctl -u oled.service -n 20  # startup / mode switches
```
