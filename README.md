# EasePi OLED Daemon

SSD1306 OLED display daemon for EasePi-A2 (RK3568) IoT gateway.  
Displays system status (CPU, temperature, network, IP) on a 128x32 I2C OLED screen.

## Features

- **Multi-mode display**: idle (1-line IP), CPU (2-line), NET (2-line), heavy load (3-line)
- **Auto-switching**: toggles modes based on CPU usage (>30%), temperature (>60°C), network traffic (>100KB/s)
- **EMA smoothing**: exponential moving average for smooth CPU/network display
- **Font rendering**: uses DejaVu Sans (bundled in `golang.org/x/image`)
- **Signal handling**: graceful shutdown on SIGTERM/SIGINT

## Hardware

- **Display**: SSD1306 128x32 OLED on I2C bus 3 (address 0x3C)
- **Reset pin**: GPIO0_A3 (active low)
- **Board**: EasePi-A2 (Rockchip RK3568)

## Build

```bash
CGO_ENABLED=0 GOARCH=arm64 GOOS=linux go build -ldflags="-s -w" -o oled main.go
```

## Install

### One-line online install

```bash
curl -fsSL https://raw.githubusercontent.com/ifroncy01/easepi-oled-daemon/main/install.sh | sudo bash
```

The script detects the architecture, installs dependencies (`i2c-tools`,
`fonts-dejavu-core`), downloads the matching release artifact, installs it and
enables `oled.service`. It pins a version with `sudo OLED_VERSION=1.3.0 bash install.sh`.

### Debian package

```bash
# Download and install the .deb from GitHub Releases (arm64 / amd64)
sudo apt-get install ./easepi-oled-daemon_1.3.0_arm64.deb
```

The package installs the daemon to `/usr/local/oled/oled`, ships the
`oled.service` unit and enables it in `postinst`.

### Build the .deb locally

```bash
packaging/build-deb.sh all        # arm64 + amd64, output in dist/
packaging/build-deb.sh arm64      # single architecture
```

## Usage

```bash
# Run in foreground
sudo /usr/local/oled/oled

# Manage the installed service
sudo systemctl status oled.service
sudo systemctl restart oled.service
```