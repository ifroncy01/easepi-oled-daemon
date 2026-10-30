# EasePi OLED Daemon

SSD1306 OLED display daemon for the EasePi-A2 (Rockchip RK3568) IoT gateway.  
Shows CPU usage, SoC temperature, network throughput and IP address on a 128×32 I2C OLED panel.

[简体中文](README.md) | English

> The current feature set (runtime configuration, iNextOS web app, `OLED_MODE`
> installer) lives on branch `oled-easepi-a2-inextos`. Script URLs below point at
> that branch; once merged into `main`, replace the branch name with `main`.

## Features

- **Multi-mode display**: single-line IP, two-line CPU, two-line network, three-line heavy load
- **Auto switching** driven by thresholds editable in the web UI (default CPU >30%, temp >60°C, network >100KB/s)
- **Even sampling**: CPU usage is averaged across the whole refresh interval, removing the 50ms-window quantisation noise (fixed in v1.6.3)
- **EMA smoothing** for network speed (α = 0.30, fixed in code)
- **Hysteresis**: a new mode needs 3 consecutive hits; when conditions clear it drops back immediately
- **Bundled font**: DejaVu Sans Mono ships inside the package
- **Self-contained runtime**: static binary, no `i2c-tools` dependency, panel probed directly over I2C
- **Hot reload**: `/etc/oled/config.json` is applied within about one second, no restart needed
- **Signal handling**: graceful shutdown on SIGTERM/SIGINT

## Hardware

- **Display**: SSD1306 128×32 OLED on I2C bus 3, address `0x3C`
- **Board**: EasePi-A2 (Rockchip RK3568) — arm64 only

## Display logic

The daemon samples CPU usage, SoC temperature and RX/TX rate every **950 ms**, then picks a layout:

| Condition | Layout |
|---|---|
| CPU or temperature above threshold | two lines: `CPU: xx% xx°C` + IP |
| RX or TX above network threshold | two lines: `NET: ↓xx ↑xx` + IP |
| both of the above | three lines: CPU/temp + network + IP |
| none of the above | one line: centred IP |

- **Hysteresis**: the new mode must be met for 3 consecutive samples; any cleared
  condition drops the display back immediately.
- **Smoothing**: network speed uses an EMA (α = 0.30); CPU is the mean over the refresh interval.
- **Redraw**: the IP line is repainted periodically; it follows service restarts and network changes.

See [Runtime configuration](#runtime-configuration) for thresholds and defaults.

## Install

### One-command online install

```bash
ssh root@<device-ip>
curl -fsSL https://raw.githubusercontent.com/ifroncy01/easepi-oled-daemon/oled-easepi-a2-inextos/install.sh | sudo bash
```

The script resolves the latest release, verifies SHA256, then installs according to `OLED_MODE`:

| `OLED_MODE` | Behaviour |
|---|---|
| `auto` (default) | installs the **app bundle** (daemon + web UI on 8099 + desktop icon) when iNextOS (`/opt/roceos`) is present, otherwise the plain `.deb` |
| `app` | always install the app bundle |
| `daemon` | always install the `.deb` only |

Environment variables:

| Variable | Meaning |
|---|---|
| `OLED_VERSION` | pin a release, e.g. `OLED_VERSION=1.6.3`; defaults to the latest |
| `OLED_MODE` | `auto` / `app` / `daemon` |
| `OLED_MIRROR` | alternate download base URL (internal mirror, `file://`, …) |
| `OLED_LOCAL_DEB` | path to a local `.deb` (also accepted as the first positional argument) |

```bash
# Pin a version
curl -fsSL .../oled-easepi-a2-inextos/install.sh | sudo OLED_VERSION=1.6.3 bash

# Daemon only
curl -fsSL .../oled-easepi-a2-inextos/install.sh | sudo OLED_MODE=daemon bash

# Local deb (offline or mirrored)
curl -fsSL .../oled-easepi-a2-inextos/install.sh | sudo OLED_LOCAL_DEB=/tmp/easepi-oled-daemon_1.6.3_arm64.deb bash
```

### Offline install (recommended for air-gapped devices)

```bash
scp dist/easepi-oled-daemon_1.6.3_arm64.deb root@<device-ip>:/tmp/
ssh root@<device-ip> 'dpkg -i /tmp/easepi-oled-daemon_1.6.3_arm64.deb'
```

`dpkg -i` alone is enough: the binary is static and the font is bundled, so no
APT download is required. You can also copy `install.sh` next to the `.deb` and
run `sudo bash install.sh`; it picks up the local package automatically.

### Debian package contents

| Path | Purpose |
|---|---|
| `/usr/local/oled/oled` | static arm64 panel daemon |
| `/usr/local/oled/oled-web` | web configuration UI (port 8099) |
| `/usr/local/oled/DejaVuSansMono.ttf` | bundled font |
| `/usr/lib/systemd/system/oled.service` | panel daemon unit |
| `/usr/lib/systemd/system/oled-web.service` | web UI unit |
| `/etc/oled/config.json` | runtime configuration (**conffile**, survives upgrades) |
| `/etc/systemd/system/oled.service.d/10-easepi-a2.conf` | local override drop-in (**conffile**, survives upgrades) |
| `/usr/share/doc/easepi-oled-daemon/` | README and copyright notice |

`postinst` runs `daemon-reload`, enables and starts both services. The package
ships `md5sums`, so `dpkg -V` can verify file integrity. The build also emits
`dist/<package>.filelist.txt`, listing every system path the package installs so
a store (or any other uninstaller) can remove them all.

### Build locally

```bash
make deb                 # arm64 only, output in dist/ (+ .sha256 and .filelist.txt)
make app                 # daemon + web UI bundle for iNextOS
make store               # store submission draft (manifest + filelist + debs/)
VERSION=1.6.4 make deb   # pin the version
```

## Usage

```bash
# Foreground run (troubleshooting)
sudo /usr/local/oled/oled

# Service management
sudo systemctl status oled.service
sudo systemctl restart oled.service
journalctl -u oled.service -f
```

## Runtime configuration

The daemon reads `/etc/oled/config.json` (a conffile) and hot-reloads it within about one second:

| Key | Default | Meaning |
|---|---|---|
| `cpu_high_threshold` | `30` | CPU % above which the CPU mode is shown |
| `temp_high_threshold` | `60` | SoC °C above which the CPU mode is shown |
| `net_high_threshold` | `100` | KB/s (RX or TX) above which the NET mode is shown |
| `silent` | `false` | Discard log output |
| `width` / `height` | `128` / `32` | compatibility fields; geometry is fixed in code and these are ignored |

Out-of-range values fall back to defaults (CPU 1–100, temperature 30–110, network 1–100000).

The following values are **fixed in code**; the web UI shows them read-only and
any value in the config file is ignored:

| Constant | Value | Meaning |
|---|---|---|
| `I2C_BUS` | `3` | I2C bus of the panel |
| `DEVICE_ADDR` | `0x3c` | SSD1306 address |
| `WIDTH` / `HEIGHT` | `128` / `32` | Panel geometry |
| `EMA_ALPHA` | `0.3` | Smoothing factor for network speed |
| `REFRESH_MS` | `950` | Sample/redraw interval in milliseconds |
| `HYSTERESIS` | `3` | Consecutive hits needed before switching mode |

Reset to factory defaults:

```bash
sudo rm /etc/oled/config.json && sudo systemctl restart oled.service
```

## iNextOS web app

`make app` builds `dist/easepi-oled-app_<version>_arm64.tar.gz`, a self-contained
bundle that installs the daemon, the `oled-web` UI and a desktop icon inside iNextOS.

```bash
scp dist/easepi-oled-app_1.6.3_arm64.tar.gz root@<device-ip>:/tmp/
ssh root@<device-ip> 'mkdir -p /tmp/oledapp && tar xzf /tmp/easepi-oled-app_1.6.3_arm64.tar.gz -C /tmp/oledapp && bash /tmp/oledapp/install.sh'
```

The installer:

1. `dpkg -i` of the bundled package (it already contains the daemon, `oled-web`
   and both systemd units)
2. writes an `oled-web` drop-in when a non-default port is requested
3. registers the app the way iNextOS does for docker apps: an `installed_apps`
   row (`webapp_port=8099`) plus a `desktop_layouts` icon entry
4. removes the legacy nginx snippet that iNextOS never included

After install, open the desktop icon or `http://<device-ip>:8099/`. The UI provides
a status dashboard, service start/stop/restart/enable, threshold settings, a
read-only view of fixed constants, an explanation of the display logic and a live log.

HTTP API:

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/status` | service state, pid, panel device |
| GET | `/api/config` | current configuration |
| POST | `/api/config` | save (`{"config":{...},"restart":false}`) |
| POST | `/api/service` | `{"action":"start\|stop\|restart\|enable\|disable"}` |
| GET | `/api/logs?tail=50` | daemon journal tail |
| GET | `/api/health` | health check (used by the installer) |

The UI is unauthenticated and restricted to private/link-local source addresses;
do not port-forward 8099 to the internet.

Uninstall (defaults to unregistering the icon and disabling the web UI while the
panel daemon keeps running; `--purge` removes every file):

```bash
ssh root@<device-ip> 'bash /tmp/oledapp/uninstall.sh'
ssh root@<device-ip> 'bash /tmp/oledapp/uninstall.sh --purge'
```

## Store submission draft

`make store` produces `dist/easepi-oled-store_<version>_arm64.tar.gz` matching the
platform `SystemBundleInstaller` layout:

| File | Purpose |
|---|---|
| `manifest.json` | catalog entry (id, type=system, version, components, port); URLs and sha256 are placeholders |
| `required-packages.json` | system dependency declaration (empty: the binary is static) |
| `filelist.txt` | every system path installed, for complete removal |
| `debs/<deb>` | offline package |

`components` already declares the `oled` and `oled-web` probes and services, so a
system-type uninstall stops both services. Fill `__BUNDLE_URL__`,
`__BUNDLE_SHA256__` and `__ICON_URL__` after hosting the bundle, using the emitted
`.sha256`.

## Verify

```bash
dpkg -V easepi-oled-daemon        # file integrity (md5sums shipped in the package)
systemctl is-enabled oled.service # enabled
systemctl is-active oled.service  # active
journalctl -u oled.service -n 20  # startup / mode switches
```

## Uninstall

```bash
sudo apt-get remove easepi-oled-daemon   # stop and disable the service, keep /usr/local/oled
sudo apt-get purge easepi-oled-daemon    # also remove /usr/local/oled and the empty drop-in dir
```
