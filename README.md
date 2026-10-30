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

The script resolves the latest release, downloads the arm64 `.deb`, verifies its
SHA256, installs it, enables and starts `oled.service`, then reports whether the
panel is driven. Pin a version with `sudo OLED_VERSION=1.5.0 bash install.sh`.

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
packaging/build-deb.sh            # arm64 only, output in dist/ (+ .sha256)
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

## Verify

```bash
dpkg -V easepi-oled-daemon        # file integrity (md5sums shipped in the package)
systemctl is-enabled oled.service # enabled
systemctl is-active oled.service  # active
journalctl -u oled.service -n 20  # startup / mode switches
```
