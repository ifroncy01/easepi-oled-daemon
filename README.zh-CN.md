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
make app                         # 守护进程 + 网页配置界面的 iNextOS 应用包
VERSION=1.5.0 make deb           # 指定版本
```

## 使用

```bash
# 前台运行
sudo /usr/local/oled/oled

# 管理已安装的服务
sudo systemctl status oled.service
sudo systemctl restart oled.service
```

## 运行时配置

守护进程读取 `/etc/oled/config.json`（随包安装，登记为 conffile），并在一个轮询
周期内热加载，修改无需重启。默认值与历史行为完全一致：

| 键 | 默认值 | 含义 |
|---|---|---|
| `cpu_high_threshold` | `30` | CPU 占用超过该值（%）时进入 CPU 模式 |
| `temp_high_threshold` | `60` | 温度超过该值（°C）时进入 CPU 模式 |
| `net_high_threshold` | `100` | 网速超过该值（KB/s）时进入 NET 模式 |
| `silent` | `false` | 不输出日志 |

以下参数固化在代码中（网页端只读展示，配置文件中即使写入也会被忽略）：

| 常量 | 值 | 含义 |
|---|---|---|
| `I2C_BUS` | `3` | 面板所在 I2C 总线 |
| `DEVICE_ADDR` | `0x3c` | SSD1306 设备地址 |
| `WIDTH` / `HEIGHT` | `128` / `32` | 面板分辨率 |
| `EMA_ALPHA` | `0.3` | 网速平滑系数 |
| `REFRESH_MS` | `950` | 刷新间隔（毫秒） |
| `HYSTERESIS` | `3` | 模式切换防抖次数 |

## iNextOS 应用（网页配置界面）

`make app` 生成 `dist/easepi-oled-app_<version>_arm64.tar.gz`，这是一个自包含
应用包：安装（或升级）守护进程、安装 `oled-web` 配置界面，并在 iNextOS 桌面
生成应用图标。

```bash
scp dist/easepi-oled-app_1.6.0_arm64.tar.gz root@<设备IP>:/tmp/
ssh root@<设备IP> 'mkdir -p /tmp/oledapp && tar xzf /tmp/easepi-oled-app_1.6.0_arm64.tar.gz -C /tmp/oledapp && bash /tmp/oledapp/install.sh'
```

安装完成后，iNextOS 桌面出现 **OLED 显示** 图标，也可直接访问
`http://<设备IP>:8099/`。

安装脚本做的事：

1. `dpkg -i` 安装随包的守护进程 deb（可升级，conffile 保留本地修改）
2. 安装 `oled-web`（`/usr/local/oled/oled-web`）与 `oled-web.service`
3. 按 iNextOS 对 docker 应用的方式注册：写入 `installed_apps`（`webapp_port=8099`）
   与 `desktop_layouts` 桌面图标
4. 清理历史上无效的 nginx 片段（平台并不 include 该目录）

网页端提供状态面板、服务启停/重启、完整参数配置、实时 `journalctl` 日志，以及
HTTP API：

| 方法 | 路径 | 用途 |
|---|---|---|
| GET | `/api/status` | 服务状态、PID、面板是否在位 |
| GET | `/api/config` | 读取当前配置 |
| POST | `/api/config` | 保存配置（`{"config":{...},"restart":false}`） |
| POST | `/api/service` | `{"action":"start\|stop\|restart\|enable\|disable"}` |
| GET | `/api/logs?tail=50` | 守护进程日志尾部 |

界面无登录鉴权，仅允许内网/链路本地源地址访问；请勿将 8099 端口映射到公网。

卸载（保留守护进程，加 `--purge` 一并移除）：

```bash
ssh root@<设备IP> 'bash /tmp/oledapp/uninstall.sh'
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
