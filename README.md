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

```bash
# Download prebuilt binary from GitHub Releases
sudo curl -L -o /usr/local/oled/oled \
  https://github.com/ifroncy01/easepi-oled-daemon/releases/latest/download/oled-linux-arm64
sudo chmod +x /usr/local/oled/oled
```

## Usage

```bash
# Run in foreground
sudo /usr/local/oled/oled

# Install as systemd service (see companion systemd unit in Armbian build)
sudo systemctl enable oled.service --now
```