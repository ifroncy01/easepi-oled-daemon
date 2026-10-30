# EasePi OLED 守护进程

EasePi-A2（Rockchip RK3568）物联网网关的 SSD1306 OLED 显示守护进程。  
在 128×32 的 I2C OLED 屏幕上展示 CPU 占用、SoC 温度、网络速率与 IP 地址。

简体中文 | [English](README.en.md)

> 当前功能（运行时配置、iNextOS 网页应用、`OLED_MODE` 一键安装）位于分支
> `oled-easepi-a2-inextos`。本文中的脚本地址均指向该分支；合并到 `main` 后
> 将 `oled-easepi-a2-inextos` 替换为 `main` 即可。

## 功能特性

- **多模式显示**：单行 IP、两行 CPU、两行网络、三行高负载
- **自动切换**：阈值可在网页端调整（默认 CPU >30%、温度 >60°C、网速 >100KB/s）
- **均匀采样**：CPU 占用按刷新周期跨 tick 采样，避免 50ms 窗口的量化噪声（v1.6.3 修复）
- **EMA 平滑**：网速使用指数移动平均（α = 0.30，固化）
- **防抖切换**：新模式需连续 3 次命中才切换，条件消失立即回落
- **字体内置**：DejaVu Sans Mono 随包安装，无需系统字体
- **运行时自足**：静态二进制，不依赖 `i2c-tools`，面板探测直接走 I2C
- **配置热加载**：`/etc/oled/config.json` 修改后约 1 秒生效，无需重启
- **信号处理**：SIGTERM / SIGINT 优雅退出

## 硬件

- **屏幕**：SSD1306 128×32 OLED，I2C 总线 3，地址 `0x3C`
- **板卡**：EasePi-A2（Rockchip RK3568）—— 仅 arm64

## 屏幕显示逻辑

守护进程每 **950 ms** 采样一次 CPU 占用、SoC 温度与 RX/TX 速率，按下列规则选择画面：

| 条件 | 画面 |
|---|---|
| CPU 或温度超过阈值 | 两行：`CPU: xx% xx°C` + IP |
| RX 或 TX 超过网速阈值 | 两行：`NET: ↓xx ↑xx` + IP |
| 以上两类同时成立 | 三行：CPU/温度 + 网速 + IP |
| 均未超过阈值 | 单行：居中显示 IP |

- **防抖**：新模式需连续 3 次采样都满足才切换；任一条件恢复，立即回落到对应模式。
- **平滑**：网速按 EMA（α = 0.30）平滑，CPU 为整个刷新周期的平均值。
- **刷新**：IP 文本按采样计数定期重绘；服务重启或网络变化后自动更新。

阈值含义与默认值见[运行时配置](#运行时配置)。

## 安装

### 在线一键安装

```bash
ssh root@<设备IP>
curl -fsSL https://raw.githubusercontent.com/ifroncy01/easepi-oled-daemon/oled-easepi-a2-inextos/install.sh | sudo bash
```

脚本解析最新 Release、校验 SHA256，然后按模式安装：

| `OLED_MODE` | 行为 |
|---|---|
| `auto`（默认） | 检测到 iNextOS（`/opt/roceos`）→ 装 **app 包**（守护进程 + 8099 网页配置 + 桌面图标）；否则只装 `.deb` |
| `app` | 强制装 app 包 |
| `daemon` | 强制只装 `.deb` |

支持的环境变量：

| 变量 | 说明 |
|---|---|
| `OLED_VERSION` | 固定版本，如 `OLED_VERSION=1.6.6`；默认取最新 Release |
| `OLED_MODE` | `auto` / `app` / `daemon` |
| `OLED_MIRROR` | 备用下载基地址（如内网镜像 `file://`、`http://`） |
| `OLED_LOCAL_DEB` | 指定本地 `.deb` 路径（也可作为第一个位置参数传入） |

示例：

```bash
# 固定版本
curl -fsSL .../oled-easepi-a2-inextos/install.sh | sudo OLED_VERSION=1.6.6 bash

# 只装守护进程
curl -fsSL .../oled-easepi-a2-inextos/install.sh | sudo OLED_MODE=daemon bash

# 用本地 deb（离线或内网镜像）
curl -fsSL .../oled-easepi-a2-inextos/install.sh | sudo OLED_LOCAL_DEB=/tmp/easepi-oled-daemon_1.6.6_arm64.deb bash
```

### 离线安装（无外网设备推荐）

```bash
scp dist/easepi-oled-daemon_1.6.6_arm64.deb root@<设备IP>:/tmp/
ssh root@<设备IP> 'dpkg -i /tmp/easepi-oled-daemon_1.6.6_arm64.deb'
```

仅 `dpkg -i` 即可完成：二进制静态编译、字体内置，无需 APT 依赖。也可把
`install.sh` 与 `.deb` 放在同一目录执行 `sudo bash install.sh`，脚本会自动识别本地包。

### Debian 包内容

| 路径 | 用途 |
|---|---|
| `/usr/local/oled/oled` | 静态编译的 arm64 守护进程 |
| `/usr/local/oled/oled-web` | 网页配置服务（8099） |
| `/usr/local/oled/DejaVuSansMono.ttf` | 内置字体 |
| `/usr/lib/systemd/system/oled.service` | 面板守护进程单元 |
| `/usr/lib/systemd/system/oled-web.service` | 网页配置单元 |
| `/etc/oled/config.json` | 运行时配置（**conffile**，升级保留） |
| `/etc/systemd/system/oled.service.d/10-easepi-a2.conf` | 本地覆盖 drop-in（**conffile**，升级保留） |
| `/usr/share/doc/easepi-oled-daemon/` | README 与版权说明 |

包的 `postinst` 会自动 `daemon-reload`、`enable` 并启动两个服务；包内附 `md5sums`，
可用 `dpkg -V` 校验完整性。构建时同时生成 `dist/<包名>.filelist.txt`，逐条列出
包会落地的全部系统文件，便于商店或其他卸载器完整清理。

### 本地构建

```bash
make deb                 # 仅 arm64，产物在 dist/（含 .sha256 与 .filelist.txt）
make app                 # 守护进程 + 网页配置的 iNextOS 应用包
make store               # 商店上架草案包（manifest.json + filelist.txt + debs/）
VERSION=1.6.6 make deb   # 指定版本
```

## 运行与使用

```bash
# 前台运行（排障）
sudo /usr/local/oled/oled

# 服务管理
sudo systemctl status oled.service
sudo systemctl restart oled.service
journalctl -u oled.service -f
```

## 运行时配置

守护进程读取 `/etc/oled/config.json`（conffile），并在约 1 秒内热加载：

| 键 | 默认值 | 含义 |
|---|---|---|
| `cpu_high_threshold` | `30` | CPU 占用超过该值（%）进入 CPU 模式 |
| `temp_high_threshold` | `60` | 温度超过该值（°C）进入 CPU 模式 |
| `net_high_threshold` | `100` | 网速超过该值（KB/s，RX 或 TX）进入 NET 模式 |
| `silent` | `false` | 不输出日志 |
| `width` / `height` | `128` / `32` | 兼容字段；实际分辨率已固化，修改不生效 |

非法值会回落到默认（CPU 1–100、温度 30–110、网速 1–100000）。

以下参数**固化在代码中**，网页端只读展示，配置文件中写入也会被忽略：

| 常量 | 值 | 含义 |
|---|---|---|
| `I2C_BUS` | `3` | 面板所在 I2C 总线 |
| `DEVICE_ADDR` | `0x3c` | SSD1306 设备地址 |
| `WIDTH` / `HEIGHT` | `128` / `32` | 面板分辨率 |
| `EMA_ALPHA` | `0.3` | 网速平滑系数 |
| `REFRESH_MS` | `950` | 采样/刷新间隔（毫秒） |
| `HYSTERESIS` | `3` | 模式切换防抖次数 |

恢复到出厂默认值：

```bash
sudo rm /etc/oled/config.json && sudo systemctl restart oled.service
```

## iNextOS 网页应用

`make app` 生成 `dist/easepi-oled-app_<版本>_arm64.tar.gz`：自包含应用包，安装守护
进程、`oled-web` 配置界面，并在 iNextOS 桌面生成「OLED 显示」图标。

```bash
scp dist/easepi-oled-app_1.6.6_arm64.tar.gz root@<设备IP>:/tmp/
ssh root@<设备IP> 'mkdir -p /tmp/oledapp && tar xzf /tmp/easepi-oled-app_1.6.6_arm64.tar.gz -C /tmp/oledapp && bash /tmp/oledapp/install.sh'
```

安装脚本依次：

1. `dpkg -i` 安装随包的 deb（其中同时包含守护进程、`oled-web` 与两个 systemd 单元）
2. 非默认端口时写入 `oled-web` 的 systemd drop-in（不改动包内单元）
3. 把 `uninstall.sh` 与 `register.py` 复制到 `/opt/roceos/apps/oled`，供后续完整卸载
4. 按 iNextOS 的方式注册应用：写入 `installed_apps`（`webapp_port=8099`）与 `desktop_layouts` 桌面图标
5. 清理历史上无效的 nginx 片段

安装完成后可点桌面图标，或直接访问 `http://<设备IP>:8099/`。网页端提供状态面板、
服务启停/重启/自启、阈值配置、固化参数只读展示、屏幕显示逻辑说明、实时日志，以及
页面底部的「完整卸载」按钮。

HTTP API：

| 方法 | 路径 | 用途 |
|---|---|---|
| GET | `/api/status` | 服务状态、PID、面板节点 |
| GET | `/api/config` | 读取当前配置 |
| POST | `/api/config` | 保存配置（`{"config":{...},"restart":false}`） |
| POST | `/api/service` | `{"action":"start\|stop\|restart\|enable\|disable"}` |
| GET | `/api/logs?tail=50` | 守护进程日志尾部 |
| POST | `/api/uninstall` | 完整卸载（`dpkg -P` + 清理配置与图标），仅接受 POST |
| GET | `/api/health` | 健康检查（安装脚本使用） |

界面无登录鉴权，仅允许内网/链路本地来源访问；请勿将 8099 端口映射到公网。

卸载有三种方式：

1. **网页端**：打开「OLED 显示」→ 页面底部「完整卸载」→ 确认一次即可。后台通过
   独立 systemd 任务执行 `dpkg -P`、清理配置与单元，并注销应用中心图标。
2. **应用目录脚本**（app 包安装后自动落地）：
   ```bash
   sudo bash /opt/roceos/apps/oled/uninstall.sh           # 停用网页、保留守护进程
   sudo bash /opt/roceos/apps/oled/uninstall.sh --purge   # 完整卸载，零残留
   ```
3. **发行包内脚本**（设备上还没安装时使用）：
   ```bash
   bash /tmp/oledapp/uninstall.sh           # 停用网页、保留守护进程
   bash /tmp/oledapp/uninstall.sh --purge   # 完整卸载，零残留
   ```

## 商店上架草案包

`make store` 生成 `dist/easepi-oled-store_<版本>_arm64.tar.gz`，结构对齐平台
`SystemBundleInstaller` 的约定：

| 文件 | 用途 |
|---|---|
| `manifest.json` | 商店目录条目（id/type=system/version/组件/端口等），URL 与 sha256 留占位 |
| `required-packages.json` | 系统依赖声明（当前为空，静态二进制无依赖） |
| `filelist.txt` | 包会安装的全部系统路径，供卸载完整清理 |
| `debs/<deb>` | 离线安装包 |

其中 `components` 已写好 `oled`、`oled-web` 的 `probe` 与 `service`，平台按 system
类型卸载时会停用对应服务。`manifest.json` 的 `__BUNDLE_URL__`、`__BUNDLE_SHA256__`、
`__ICON_URL__` 需在托管后按生成的 `.sha256` 填写。

## 验证

```bash
dpkg -V easepi-oled-daemon        # 文件完整性（包内已带 md5sums）
systemctl is-enabled oled.service # 是否开机自启
systemctl is-active oled.service  # 是否运行中
journalctl -u oled.service -n 20  # 启动日志与模式切换
```

## 卸载

```bash
sudo apt-get remove easepi-oled-daemon   # 停止并禁用服务，保留 /usr/local/oled
sudo apt-get purge easepi-oled-daemon    # 额外删除 /usr/local/oled 与空 drop-in 目录
```
