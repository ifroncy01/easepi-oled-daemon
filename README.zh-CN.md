# EasePi OLED 守护进程

EasePi-A2（RK3568）物联网网关的 SSD1306 OLED 显示守护进程。  
在 128x32 的 I2C OLED 屏幕上展示系统状态（CPU、温度、网络、IP）。

[English](README.md) | 简体中文

## 功能特性

- **多模式显示**：空闲（单行 IP）、CPU（两行）、网络（两行）、高负载（三行）
- **自动切换**：依据 CPU 占用（>30%）、温度（>60°C）、网络流量（>100KB/s）自动切换模式
- **EMA 平滑**：对 CPU 与网速使用指数移动平均，显示更稳定
- **字体渲染**：DejaVu Sans Mono 字体随包内置
- **运行时自足**：不依赖 `i2c-tools` 与 `fonts-dejavu-core`，屏幕探测直接走 I2C
- **信号处理**：收到 SIGTERM/SIGINT 时优雅退出

## 硬件

- **屏幕**：SSD1306 128x32 OLED，I2C 总线 3，地址 `0x3C`
- **板卡**：EasePi-A2（Rockchip RK3568）—— 仅 arm64

## 安装

### 在线一键安装

```bash
ssh root@<设备IP>
curl -fsSL https://raw.githubusercontent.com/ifroncy01/easepi-oled-daemon/main/install.sh | sudo bash
```

脚本会解析最新 Release、下载 arm64 `.deb`、校验 SHA256、安装并启用启动
`oled.service`，最后报告屏幕是否已驱动。可用
`sudo OLED_VERSION=1.5.0 bash install.sh` 固定版本。

### 离线安装（无外网设备推荐）

```bash
scp dist/easepi-oled-daemon_1.5.0_arm64.deb root@<设备IP>:/tmp/
ssh root@<设备IP> 'dpkg -i /tmp/easepi-oled-daemon_1.5.0_arm64.deb'
```

仅用 `dpkg -i` 即可完成：二进制为静态编译、字体已内置，无需 APT 下载。
也可以把 `install.sh` 与 `.deb` 一起拷到设备，执行 `sudo bash install.sh`，
脚本会自动识别同目录下的本地包。

### Debian 包

```bash
sudo dpkg -i easepi-oled-daemon_1.5.0_arm64.deb   # 或：sudo apt-get install ./easepi-oled-daemon_1.5.0_arm64.deb
```

包内安装内容：

| 路径 | 用途 |
|---|---|
| `/usr/local/oled/oled` | 静态编译的 arm64 主程序 |
| `/usr/local/oled/DejaVuSansMono.ttf` | 内置字体（离线渲染） |
| `/usr/lib/systemd/system/oled.service` | 厂商 systemd 单元 |
| `/etc/systemd/system/oled.service.d/10-easepi-a2.conf` | 本地覆盖 drop-in（**conffile**，升级保留） |

对 drop-in 的本地修改在包升级与系统升级中均会被保留；`oled.service` 由包的
`postinst` 自动启用并（重新）启动。

### 本地构建 .deb 包

```bash
make deb                         # 仅 arm64，产物在 dist/（含 .sha256）
VERSION=1.5.0 make deb           # 指定版本
packaging/build-deb.sh           # 等价的直接调用方式
```

## 使用

```bash
# 前台运行
sudo /usr/local/oled/oled

# 管理已安装的服务
sudo systemctl status oled.service
sudo systemctl restart oled.service
```

## 验证

```bash
dpkg -V easepi-oled-daemon        # 文件完整性（包内已带 md5sums）
systemctl is-enabled oled.service # 是否开机自启
systemctl is-active oled.service  # 是否正在运行
journalctl -u oled.service -n 20  # 启动日志 / 模式切换记录
```

## 卸载

```bash
sudo apt-get remove easepi-oled-daemon   # 停止并禁用服务，保留 /usr/local/oled
sudo apt-get purge easepi-oled-daemon    # 额外删除 /usr/local/oled 与空 drop-in 目录
```
