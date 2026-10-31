# EasePi A2 OLED 安装与打包报告

- 报告日期：2026-10-30（v1.6.6 更新）
- 目标设备：`root@192.168.1.11`（主机名 `iNextOS-4BD4`，EasePi A2 / RK3568）
- 当前版本：`easepi-oled-daemon 1.6.6 (arm64)`
- 分支：`oled-easepi-a2-inextos`
- 包文件：`dist/easepi-oled-daemon_1.6.6_arm64.deb`

---

## 一、版本演进摘要（1.5.0 → 1.6.6）

| 项目 | 1.5.0 | 1.6.6（当前） |
|---|---|---|
| 架构 | 仅 arm64 | 仅 arm64（EasePi-A2 专用） |
| 运行时依赖 | 无（静态二进制 + 内置字体） | 无（保持） |
| 守护进程 | 单 `oled` 二进制 | `oled` + `oled-web` 网页配置服务 |
| systemd 单元 | `oled.service` | `oled.service` + `oled-web.service` |
| 配置 | 编译期常量 | `/etc/oled/config.json` 热加载（阈值可改，硬件参数固化） |
| CPU 采样 | 50ms 窗口（低阈值不切换） | 跨刷新周期采样（v1.6.3 修复） |
| 模式切换 | 无防抖 | 连续 3 次命中切换，条件消失立即回落 |
| 网速平滑 | 无 | EMA（α = 0.30） |
| iNextOS 集成 | 无 | app bundle 安装：桌面图标 + 8099 网页 + DB 注册 |
| 安装方式 | deb 在线/离线 | `OLED_MODE=auto/app/daemon`，app 包含网页与图标 |
| 卸载 | `dpkg -r/-P` | `dpkg -P` + 应用目录脚本 + 网页「完整卸载」按钮 |
| 商店上架 | 无 | `make store` 生成 system 类型草案包 |
| 文件清单 | `md5sums` | `md5sums` + `filelist.txt`（供商店卸载） |

---

## 二、目标环境

| 项目 | 值 |
|---|---|
| 发行版 | iNextOSA 26.2.1（`Debian GNU/Linux 13 (trixie)`） |
| 内核 | `6.1.115-vendor-rk35xx`（`aarch64`） |
| 设备树 | model `EasePi A2`，compatible `easepi,a2` / `rockchip,rk3568` |
| CPU / 内存 | 4 核 / 3.8 GiB |
| 网络 | `eth0` = `192.168.1.11/24` |
| I2C | `/dev/i2c-0`、`/dev/i2c-3`、`/dev/i2c-5`、`/dev/i2c-6` |
| 屏幕 | SSD1306 128×32，I2C-3 地址 `0x3C` |

代码常量与硬件一致：`I2C_BUS = 3`、`DEVICE_ADDR = 0x3c`、`WIDTH = 128`、`HEIGHT = 32`。`/dev/i2c-3` 由内核设备树直接提供，与安装包无关。

---

## 三、运行时配置

守护进程读取 `/etc/oled/config.json`（conffile），约 1 秒内热加载，无需重启。

| 键 | 默认值 | 含义 | 范围 |
|---|---|---|---|
| `cpu_high_threshold` | `30` | CPU 占用超过该值（%）进入 CPU 模式 | 1–100 |
| `temp_high_threshold` | `60` | 温度超过该值（°C）进入 CPU 模式 | 30–110 |
| `net_high_threshold` | `100` | 网速超过该值（KB/s，RX 或 TX）进入 NET 模式 | 1–100000 |
| `silent` | `false` | 不输出日志 | bool |
| `width` / `height` | `128` / `32` | 兼容字段，实际已固化，修改不生效 | — |

以下参数**固化在代码中**，网页端只读展示，配置文件中写入也会被忽略：

| 常量 | 值 | 含义 |
|---|---|---|
| `I2C_BUS` | `3` | 面板所在 I2C 总线 |
| `DEVICE_ADDR` | `0x3c` | SSD1306 设备地址 |
| `WIDTH` / `HEIGHT` | `128` / `32` | 面板分辨率 |
| `EMA_ALPHA` | `0.3` | 网速平滑系数 |
| `REFRESH_MS` | `950` | 采样/刷新间隔（毫秒） |
| `HYSTERESIS` | `3` | 模式切换防抖次数 |

恢复出厂默认值：

```bash
sudo rm /etc/oled/config.json && sudo systemctl restart oled.service
```

---

## 四、屏幕显示逻辑

守护进程每 950 ms 采样一次 CPU 占用、SoC 温度与 RX/TX 速率，按下列规则选择画面：

| 条件 | 画面 |
|---|---|
| CPU 或温度超过阈值 | 两行：`CPU: xx% xx°C` + IP |
| RX 或 TX 超过网速阈值 | 两行：`NET: ↓xx ↑xx` + IP |
| 以上两类同时成立 | 三行：CPU/温度 + 网速 + IP |
| 均未超过阈值 | 单行：居中显示 IP |

- **防抖**：新模式需连续 3 次采样都满足才切换；任一条件恢复，立即回落到对应模式。
- **平滑**：网速按 EMA（α = 0.30）平滑，CPU 为整个刷新周期的平均值（跨 tick 采样，消除 50ms 窗口量化噪声）。
- **刷新**：IP 文本按采样计数定期重绘；服务重启或网络变化后自动更新。

---

## 五、包结构与内容

### 5.1 元数据

```
Package: easepi-oled-daemon
Version: 1.6.6
Section: utils
Priority: optional
Architecture: arm64
Maintainer: ifroncy <ifroncy01@users.noreply.github.com>
Homepage: https://github.com/ifroncy01/easepi-oled-daemon
Description: SSD1306 OLED display daemon for EasePi-A2 (RK3568)
 Displays system status (IP, CPU usage, temperature and network speed) on a
 128x32 I2C OLED panel. The daemon switches automatically between 1-line,
 2-line and 3-line layouts according to system load, and is managed by the
 oled.service systemd unit. The web UI (oled-web) provides runtime configuration
 without restarting the daemon.
 .
 The package is self-contained: the static arm64 binary and the DejaVu Sans Mono
 font are bundled, so it can be installed offline with dpkg -i alone.
```

控制成员：`control`、`md5sums`、`conffiles`、`postinst`、`prerm`、`postrm`。

### 5.2 文件清单（`dpkg-deb -c`）

| 路径 | 权限 | 说明 |
|---|---|---|
| `/usr/local/oled/oled` | 0755 | 静态 arm64 面板守护进程 |
| `/usr/local/oled/oled-web` | 0755 | 网页配置服务（8099） |
| `/usr/local/oled/DejaVuSansMono.ttf` | 0644 | 内置字体 |
| `/usr/lib/systemd/system/oled.service` | 0644 | 面板守护进程单元 |
| `/usr/lib/systemd/system/oled-web.service` | 0644 | 网页配置单元 |
| `/etc/oled/config.json` | 0644 | **conffile**：运行时配置，升级保留 |
| `/etc/systemd/system/oled.service.d/10-easepi-a2.conf` | 0644 | **conffile**：本地覆盖 drop-in，升级保留 |
| `/usr/share/doc/easepi-oled-daemon/copyright` | 0644 | 含字体授权说明 |
| `/usr/share/doc/easepi-oled-daemon/README.md` | 0644 | 安装/验证说明 |

构建时同时生成 `dist/<包名>.filelist.txt`，逐条列出包会落地的全部系统文件（9 个），供商店或其他卸载器完整清理。

### 5.3 conffiles

```
/etc/oled/config.json
/etc/systemd/system/oled.service.d/10-easepi-a2.conf
```

### 5.4 维护脚本

| 脚本 | 行为 |
|---|---|
| `postinst` | 升级时清理旧 `/etc/systemd/system/oled.service`；`daemon-reload` → `unmask` → `enable` → `restart` 两个服务（每步容错） |
| `prerm` | `stop oled.service` 与 `oled-web.service`；`remove`/`purge` 时 `disable` 两者 |
| `postrm` | `daemon-reload`；`purge` 时删除 `/usr/local/oled`、`/etc/oled`、drop-in 目录与两个 vendor 单元 |

---

## 六、关键机制说明

### 6.1 升级不覆盖配置

- 单元文件在 `/usr/lib/systemd/system`（vendor 目录），随版本更新是期望行为；
- `/etc/oled/config.json` 与 `/etc/systemd/system/oled.service.d/10-easepi-a2.conf` 均为 conffile，`apt upgrade` / `dpkg -i` 保留本地修改；
- `postinst` 在升级时删除旧版 `/etc/systemd/system/oled.service` 并重建启用软链。

### 6.2 离线自足

- 二进制为 `CGO_ENABLED=0` 静态编译，不依赖系统 Go/glibc；
- 字体随包内置，程序优先读取 `/usr/local/oled/DejaVuSansMono.ttf`；
- 屏幕探测直接 I2C 写 `0xAE`，无需 `i2c-tools`；
- `Depends` 为空，`dpkg -i` 一条命令完成安装。

### 6.3 探测与容错

`newSSD1306()` 在 `ioctl(I2C_SLAVE, 0x3c)` 成功后写一帧 `0xAE`，无屏时 NAK 报错并记录日志。单元保留 `ConditionPathExists=/dev/i2c-3`，避免无屏机型反复重启失败。`retryI2C` 提供 3 次写重试。

### 6.4 配置热加载

主循环每 950 ms 轮询 `/etc/oled/config.json` 的 mtime，变化时重新解析并应用，异常值回落到默认值。守护进程不中断。

---

## 七、iNextOS 网页应用

`make app` 生成 `dist/easepi-oled-app_<版本>_arm64.tar.gz`，安装守护进程、网页配置界面，并在 iNextOS 桌面生成「OLED 显示」图标。

安装脚本依次：

1. `dpkg -i` 安装随包的 deb（含守护进程、`oled-web` 与两个 systemd 单元）
2. 非默认端口时写入 `oled-web` 的 systemd drop-in
3. 把 `uninstall.sh` 与 `register.py` 复制到 `/opt/roceos/apps/oled`，供后续完整卸载
4. 注册应用：写入 `installed_apps`（`webapp_port=8099`）与 `desktop_layouts` 桌面图标
5. 清理历史上无效的 nginx 片段

安装完成后点桌面图标或访问 `http://<设备IP>:8099/`。网页提供状态面板、服务启停/重启/自启、阈值配置、固化参数只读展示、屏幕显示逻辑说明、实时日志，以及页面底部的「完整卸载」按钮。

HTTP API：

| 方法 | 路径 | 用途 |
|---|---|---|
| GET | `/api/status` | 服务状态、PID、面板节点 |
| GET | `/api/config` | 读取当前配置 |
| POST | `/api/config` | 保存配置 |
| POST | `/api/service` | `start`/`stop`/`restart`/`enable`/`disable` |
| GET | `/api/logs?tail=50` | 守护进程日志尾部 |
| POST | `/api/uninstall` | 完整卸载（`dpkg -P` + 清理配置与图标），仅 POST |
| GET | `/api/health` | 健康检查 |

界面无登录鉴权，仅允许内网/链路本地来源访问；请勿将 8099 端口映射到公网。

---

## 八、安装方式

### 8.1 在线一键安装（SSH 后一条命令）

```bash
ssh root@<设备IP>
curl -fsSL https://raw.githubusercontent.com/ifroncy01/easepi-oled-daemon/oled-easepi-a2-inextos/install.sh | sudo bash
```

脚本解析最新 Release、校验 SHA256，按 `OLED_MODE` 安装：

| `OLED_MODE` | 行为 |
|---|---|
| `auto`（默认） | 检测到 iNextOS → 装 app 包；否则只装 `.deb` |
| `app` | 强制装 app 包 |
| `daemon` | 强制只装 `.deb` |

| 变量 | 说明 |
|---|---|
| `OLED_VERSION` | 固定版本，如 `OLED_VERSION=1.6.6` |
| `OLED_MODE` | `auto` / `app` / `daemon` |
| `OLED_MIRROR` | 备用下载基址 |
| `OLED_LOCAL_DEB` | 指定本地 `.deb` |

### 8.2 离线安装

```bash
scp dist/easepi-oled-daemon_1.6.6_arm64.deb root@<设备IP>:/tmp/
ssh root@<设备IP> 'dpkg -i /tmp/easepi-oled-daemon_1.6.6_arm64.deb'
```

### 8.3 应用包安装

```bash
scp dist/easepi-oled-app_1.6.6_arm64.tar.gz root@<设备IP>:/tmp/
ssh root@<设备IP> 'mkdir -p /tmp/oledapp && tar xzf /tmp/easepi-oled-app_1.6.6_arm64.tar.gz -C /tmp/oledapp && bash /tmp/oledapp/install.sh'
```

---

## 九、卸载方式

1. **网页端**：打开「OLED 显示」→ 页面底部「完整卸载」→ 确认一次即可。后台通过独立 systemd 任务执行 `dpkg -P`、清理配置与单元，并注销应用中心图标。
2. **应用目录脚本**（app 包安装后自动落地）：
   ```bash
   sudo bash /opt/roceos/apps/oled/uninstall.sh           # 停用网页、保留守护进程
   sudo bash /opt/roceos/apps/oled/uninstall.sh --purge   # 完整卸载，零残留
   ```
3. **发行包内脚本**：
   ```bash
   bash /tmp/oledapp/uninstall.sh --purge
   ```
4. **包管理命令**：
   ```bash
   sudo apt-get remove easepi-oled-daemon   # 停止服务，保留文件
   sudo apt-get purge easepi-oled-daemon    # 停止服务并删除全部文件
   ```

---

## 十、商店上架草案包

`make store` 生成 `dist/easepi-oled-store_<版本>_arm64.tar.gz`，结构对齐平台 `SystemBundleInstaller`：

| 文件 | 用途 |
|---|---|
| `manifest.json` | 目录条目（id/type=system/version/components/port），URL 与 sha256 留占位 |
| `required-packages.json` | 系统依赖声明（当前为空） |
| `filelist.txt` | 包会安装的全部系统路径，供卸载完整清理 |
| `debs/<deb>` | 离线安装包 |

`components` 已声明 `oled`、`oled-web` 的 `probe` 与 `service`。`__BUNDLE_URL__`、`__BUNDLE_SHA256__`、`__ICON_URL__` 需在托管后按生成的 `.sha256` 填写。

---

## 十一、验证记录（设备实测）

| 序号 | 操作 | 结果 |
|---|---|---|
| 1 | 在线安装 v1.6.4（首次） | `OLED_VERSION` 缺 `v` 前缀 404，修复 `install.sh` TAG 归一化后成功 |
| 2 | 安装后服务状态 | `oled.service` 与 `oled-web.service` 均 enabled + active |
| 3 | 网页配置服务 | `http://127.0.0.1:8099/` 返回 HTTP 200 |
| 4 | `dpkg -V` | 返回 0，全部文件未改动 |
| 5 | 重启自启验证 | `reboot` 后两服务自动启动，面板重新显示 IP |
| 6 | CPU 阈值生效 | 设为 1% 后切换到 CPU 模式（跨 tick 采样修复） |
| 7 | 配置热加载 | 修改 `config.json` 后约 1 秒生效，服务不中断 |
| 8 | 完整卸载（脚本 `--purge`） | `dpkg -P` 成功，包内 9 个文件全删，DB 记录与桌面图标清除，零残留 |
| 9 | 网页卸载按钮（v1.6.6） | `POST /api/uninstall` 空 body 返回 200，10 秒后零残留 |

---

## 十二、构建与发布

```bash
make deb                 # 仅 arm64，产物在 dist/（含 .sha256 与 .filelist.txt）
make app                 # 守护进程 + 网页配置的 iNextOS 应用包
make store               # 商店上架草案包
VERSION=1.6.6 make deb   # 指定版本
```

GitHub Actions（`.github/workflows/release.yml`）在 tag `v*` 时触发，产出二进制、deb、app 包、store 草案包及各自 `.sha256`，并自动创建 Release。

---

## 十三、已知限制与待确认事项

1. **iNextOS 应用中心的卸载按钮**只删除 `installed_apps` 记录与 `install_path` 目录，不会执行 `dpkg -P`，无法完整卸载。完整卸载需使用网页按钮、应用目录脚本或以 system 类型上架商店。
2. **system 类型上架**需向厂商确认：aarch64 架构是否支持、卸载是否执行 `dpkg -P`、`runInitScript` 的脚本约定。这是官方前端完整卸载的唯一正路。
3. 网页界面无鉴权，仅靠内网来源限制，请勿将 8099 端口暴露到公网。
4. `raw.githubusercontent.com` 有 5 分钟 CDN 缓存，推送 `install.sh` 后在线安装需等待缓存刷新。
