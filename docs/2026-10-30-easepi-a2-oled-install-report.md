# EasePi A2 OLED 安装与打包优化报告

- 报告日期：2026-10-30
- 目标设备：`root@192.168.1.11`（主机名 `iNextOS-4BD4`，EasePi A2 / RK3568）
- 当前安装版本：`easepi-oled-daemon 1.5.0 (arm64)`
- 包文件：`dist/easepi-oled-daemon_1.5.0_arm64.deb`（999,990 B，SHA256 `4f66515ebab6514919cb588df9db67d0a5c466aa48bbe3f3c9a8e78c5c2edcf1`）

---

## 一、本版变更摘要

| 项目 | 1.4.0（旧） | 1.5.0（本版） |
|---|---|---|
| 架构 | arm64 + amd64 双包 | **仅 arm64**（EasePi-A2 专用；`amd64` 包已删除） |
| 运行时依赖 | `Depends: i2c-tools, fonts-dejavu-core` | **无任何 Deb 依赖**，可完全离线 `dpkg -i` |
| 字体 | 依赖系统 `fonts-dejavu-core` | **字体内置** `/usr/local/oled/DejaVuSansMono.ttf` |
| 屏幕自检 | 调用 `i2cdetect -y 3`（硬依赖 i2c-tools） | **直接 I2C 写探测**（`0xAE` 命令），无外部命令 |
| systemd 单元位置 | `/etc/systemd/system/oled.service` | `/usr/lib/systemd/system/oled.service`（vendor 单元） |
| 配置升级安全 | 单元在 `/etc` 且非 conffile，升级会被覆盖 | `/etc/.../oled.service.d/10-easepi-a2.conf` 为 **conffile**，升级保留本地修改 |
| 完整性校验 | 无 `md5sums` | **已生成 `md5sums`**，`dpkg -V` 可用 |
| 旧单元迁移 | — | `postinst` 自动删除旧 `/etc/systemd/system/oled.service` 并重建启用链 |
| 安装脚本 | 在线拉取 deb，缺失依赖靠 apt | **在线/离线双模式**，校验 SHA256，安装后自动验证并输出诊断 |
| CI 构建矩阵 | arm64 + amd64 | **仅 arm64** |
| 附带文档 | 无 | `copyright` + `README.md` 安装到 `/usr/share/doc/easepi-oled-daemon/` |

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
| 屏幕 | SSD1306 128x32，I2C-3 地址 `0x3C` |

代码常量与硬件一致：`I2C_BUS = 3`、`DEVICE_ADDR = 0x3c`、`WIDTH = 128`、`HEIGHT = 32`。`/dev/i2c-3` 由内核设备树直接提供，与安装包无关。

---

## 三、七项打包改进的落地情况

| # | 原改进建议 | 本版实现 | 实现方式 |
|---|---|---|---|
| 1 | 补 `md5sums` | ✅ | `build-deb.sh` 在打包前对暂存目录执行 `md5sum`，写入 `DEBIAN/md5sums` |
| 2 | 单元标为配置文件 | ✅（等价方案） | 单元下沉到 `/usr/lib/systemd/system`；`/etc/systemd/system/oled.service.d/10-easepi-a2.conf` 列为 `conffile`，本地覆盖在升级中保留 |
| 3 | 单元移至 `/lib` 或 `/usr/lib` | ✅ | 使用 `/usr/lib/systemd/system/oled.service`；`postinst` 清理旧的 `/etc` 单元并重建 `enable` 软链 |
| 4 | 解除 `i2cdetect` 硬依赖 | ✅ | `newSSD1306()` 打开 `I2C_SLAVE` 后直接写 `0xAE` 探测，设备不应答即报 `no OLED response at 0x3c on i2c-3` |
| 5 | 依赖版本细化 | ✅（更强） | 通过内置字体 + 无外部命令，把 `Depends` 降为空，彻底不依赖系统包版本 |
| 6 | 离线部署流程脚本化 | ✅ | `install.sh` 支持本地 `.deb`（参数 / `OLED_LOCAL_DEB` / 脚本同目录自动发现），安装后自检并打印诊断 |

---

## 四、1.5.0 包结构与内容

### 4.1 元数据（`dpkg-deb -I`）

```
Package: easepi-oled-daemon
Version: 1.5.0
Section: utils
Priority: optional
Architecture: arm64
Maintainer: ifroncy <ifroncy01@users.noreply.github.com>
Installed-Size: 2724
Homepage: https://github.com/ifroncy01/easepi-oled-daemon
Description: SSD1306 OLED display daemon for EasePi-A2 (RK3568)
 .  The package is self-contained: the static arm64 binary and the DejaVu Sans Mono
 .  font are bundled, so it can be installed offline with dpkg -i alone.
```

控制成员：`control`、`md5sums`、`conffiles`、`postinst`、`prerm`、`postrm`。

### 4.2 文件清单（`dpkg-deb -c`）

| 路径 | 权限 | 大小 | 说明 |
|---|---|---|---|
| `/usr/local/oled/oled` | 0755 | 2,424,994 B | 静态 arm64 主程序（`CGO_ENABLED=0`、`-trimpath`、`-s -w`） |
| `/usr/local/oled/DejaVuSansMono.ttf` | 0644 | 343,140 B | 内置字体，替代 `fonts-dejavu-core` |
| `/usr/lib/systemd/system/oled.service` | 0644 | 334 B | vendor 单元（`Documentation=` 指向仓库） |
| `/etc/systemd/system/oled.service.d/10-easepi-a2.conf` | 0644 | 354 B | **conffile**：本地覆盖 drop-in，升级保留 |
| `/usr/share/doc/easepi-oled-daemon/copyright` | 0644 | 608 B | 含字体授权说明 |
| `/usr/share/doc/easepi-oled-daemon/README.md` | 0644 | 1,875 B | 安装/验证说明 |

### 4.3 `conffiles`

```
/etc/systemd/system/oled.service.d/10-easepi-a2.conf
```

### 4.4 `md5sums`（`dpkg -V` 依据）

```
923e34de13f382134bfcb0786cdcd6f3  etc/systemd/system/oled.service.d/10-easepi-a2.conf
8f7e3706712d975a4635b33394182451  usr/lib/systemd/system/oled.service
2d545d95ed1ddb0f62273bee79ec7144  usr/local/oled/DejaVuSansMono.ttf
e9fe999ca6ed2eb51be4cdd2c4cc82e7  usr/local/oled/oled
4f3c185a672a8945e6fcd2a06a3b7e6d  usr/share/doc/easepi-oled-daemon/copyright
b03f36595365c5e493b1763c43755056  usr/share/doc/easepi-oled-daemon/README.md
```

设备上 `dpkg -V easepi-oled-daemon` 返回 **rc=0**（安装文件全部未改动）。

### 4.5 unit 内容（`/usr/lib/systemd/system/oled.service`）

```ini
[Unit]
Description=EasePi A2 OLED Display (Go)
Documentation=https://github.com/ifroncy01/easepi-oled-daemon
After=network.target systemd-modules-load.service
StartLimitIntervalSec=0
ConditionPathExists=/dev/i2c-3

[Service]
Type=simple
ExecStart=/usr/local/oled/oled
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

### 4.6 维护脚本

| 脚本 | 行为 |
|---|---|
| `postinst` | 若存在旧版 `/etc/systemd/system/oled.service`：先 `disable` 再删除；随后 `daemon-reload` → `unmask` → `enable` → `restart`（每步容错，无屏不会中断安装） |
| `prerm` | `stop oled.service`；参数为 `remove`/`purge` 时额外 `disable` |
| `postrm` | `daemon-reload`；`purge` 时删除 `/usr/local/oled` 与空的 drop-in 目录 |

---

## 五、关键机制说明

### 5.1 升级不覆盖配置

- 单元文件由包管理，放在 `/usr/lib/systemd/system`（vendor 目录），随版本更新是**期望行为**；
- 所有本地调整建议写入 `/etc/systemd/system/oled.service.d/10-easepi-a2.conf`。该文件是 `conffile`，`apt upgrade` / `dpkg -i` 遇到本地修改会保留（必要时交互确认），system 升级同样不会覆盖；
- `postinst` 会在升级时把旧版放在 `/etc/systemd/system/oled.service` 的单元删除并重建启用软链，避免旧单元遮蔽新 vendor 单元。

### 5.2 离线自足

- 二进制为 `CGO_ENABLED=0` 静态编译，不依赖系统 Go/glibc 版本差异；
- 字体随包内置，程序优先读取 `/usr/local/oled/DejaVuSansMono.ttf`（代码中仍是优先路径），系统字体仅作回退；
- 屏幕探测改为直接 I2C 写，不再需要 `i2c-tools`；
- `Depends` 为空，因此 `dpkg -i` 一条命令即可完成安装，无需联网、无需人工补依赖。

### 5.3 探测与容错

`newSSD1306()` 在 `ioctl(I2C_SLAVE, 0x3c)` 成功后立即写一帧 `0xAE`（Display OFF）。若总线上没有屏幕，写操作会因 NAK 报错，日志明确输出：

```
no OLED response at 0x3c on i2c-3: ...
```

随后 `Init()` 会重新下发完整 SSD1306 初始化序列并点亮屏幕，`0xAE` 探测无副作用。单元仍保留 `ConditionPathExists=/dev/i2c-3`，避免无屏机型反复重启失败。

---

## 六、安装与验证记录（设备实测）

| 序号 | 操作 | 结果 |
|---|---|---|
| 1 | 旧版 1.4.0 安装状态 | `ii easepi-oled-daemon 1.4.0`，单元在 `/etc/systemd/system/oled.service` |
| 2 | `dpkg -i easepi-oled-daemon_1.5.0_arm64.deb`（离线，无网络下载） | 升级成功；`postinst` 静默完成 |
| 3 | 旧单元清理 | `/etc/systemd/system/oled.service` 已不存在；`systemctl show -p FragmentPath` → `/usr/lib/systemd/system/oled.service` |
| 4 | 本地覆盖 drop-in | `/etc/systemd/system/oled.service.d/10-easepi-a2.conf` 已登记为 `Conffiles` |
| 5 | 完整性校验 | `dpkg -V easepi-oled-daemon` → `rc=0` |
| 6 | 字体来源 | 日志显示 `using font: /usr/local/oled/DejaVuSansMono.ttf (14px/12px/11px/16px)`，即使用内置字体 |
| 7 | **离线无依赖验证** | `apt-get remove -y i2c-tools` 后 `i2cdetect` 不存在，`systemctl restart oled.service` 仍 `active`，日志正常输出 `Main loop started` |
| 8 | **重启自启验证** | `systemctl reboot` 后约 100 s 恢复；`is-enabled=enabled`、`is-active=active`，进程 PID 926，日志出现 `Mode changed to: 1 (CPU:53.0% Temp:52°C)` 与 `Mode changed to: 0` |
| 9 | **离线一键脚本验证** | 将 `install.sh` 与 deb 放入 `/tmp/oledtest/`，执行 `bash install.sh`（无参数）：自动识别本地包 → 安装 → `oled.service is active` → 输出 `panel shows IP: 192.168.1.11` |

日志片段（升级后重启）：

```
OLED initialized
using font: /usr/local/oled/DejaVuSansMono.ttf (14px)
Main loop started
Mode changed to: 1 (CPU:53.0% Temp:52°C RX:7.0K TX:11.0K)
Mode changed to: 0 (CPU:25.0% Temp:49°C RX:2.0K TX:3.0K)
```

---

## 七、一键安装

### 7.1 在线（SSH 后一条命令）

```bash
ssh root@<device-ip>
curl -fsSL https://raw.githubusercontent.com/ifroncy01/easepi-oled-daemon/main/install.sh | sudo bash
```

流程：识别架构（非 arm64 直接报错）→ 解析最新 Release → 下载 `easepi-oled-daemon_<ver>_arm64.deb` 与 `.sha256` → 校验 → `dpkg -i` → `daemon-reload`/`unmask`/`enable`/`restart` → 可选安装 `i2c-tools`（仅诊断用，失败忽略）→ 打印包版本、`/dev/i2c-3` 状态、服务状态与屏幕显示的 IP。

### 7.2 离线（Air-gapped）

```bash
scp dist/easepi-oled-daemon_1.5.0_arm64.deb install.sh root@<device-ip>:/tmp/oled/
ssh root@<device-ip> 'cd /tmp/oled && sudo bash install.sh'
```

也可直接：`dpkg -i /tmp/oled/easepi-oled-daemon_1.5.0_arm64.deb`。

### 7.3 脚本环境变量

| 变量 | 作用 |
|---|---|
| `OLED_VERSION` | 指定版本（如 `OLED_VERSION=1.5.0`），默认取 latest release |
| `OLED_MIRROR` | 替换下载基址（镜像/私有源） |
| `OLED_LOCAL_DEB` | 指定本地 deb 路径（等价于第一个参数） |

### 7.4 `install.sh` 全文

```bash
#!/usr/bin/env bash
#
# EasePi OLED Daemon - one-command installer (EasePi-A2 / arm64 only)
#
# Online:
#   curl -fsSL https://raw.githubusercontent.com/ifroncy01/easepi-oled-daemon/main/install.sh | sudo bash
#
# Offline (deb already copied to the device):
#   sudo bash install.sh /path/to/easepi-oled-daemon_<version>_arm64.deb
#
# Environment overrides:
#   OLED_VERSION     release tag to install (default: latest release)
#   OLED_MIRROR      alternative download base URL (default: GitHub releases)
#   OLED_LOCAL_DEB   path to a local .deb (same as passing it as the first argument)
#
set -euo pipefail

REPO="ifroncy01/easepi-oled-daemon"
PKG="easepi-oled-daemon"
INSTALL_DIR="/usr/local/oled"
SERVICE="oled.service"
GH_API="https://api.github.com/repos/${REPO}"

red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
info()  { printf '\033[0;36m[INFO]\033[0m %s\n' "$*"; }
warn()  { printf '\033[0;33m[WARN]\033[0m %s\n' "$*"; }
die()   { red "[ERROR] $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "please run as root:  curl -fsSL ... | sudo bash"

# --------------------------------------------------------------- architecture
case "$(uname -m)" in
    aarch64|arm64) ARCH=arm64 ;;
    *) die "unsupported architecture: $(uname -m) (this package targets EasePi-A2 / arm64 only)" ;;
esac
info "architecture: ${ARCH}"

# ------------------------------------------------------------------ local deb
LOCAL_DEB="${OLED_LOCAL_DEB:-${1:-}}"
if [ -z "${LOCAL_DEB}" ]; then
    SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
    LOCAL_DEB="$(ls -1 "${SELF_DIR}"/*_arm64.deb 2>/dev/null | head -n1 || true)"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# --------------------------------------------------------------------- resolve
if [ -n "${LOCAL_DEB}" ]; then
    [ -f "${LOCAL_DEB}" ] || die "local package not found: ${LOCAL_DEB}"
    DEB="${LOCAL_DEB}"
    info "using local package: ${DEB}"
else
    VERSION="${OLED_VERSION:-}"
    if [ -z "${VERSION}" ]; then
        info "resolving latest release ..."
        VERSION="$(curl -fsSL --connect-timeout 15 "${GH_API}/releases/latest" \
            | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' \
            | head -n1 | sed -E 's/.*"([^"]+)"$/\1/')" || true
        [ -n "${VERSION}" ] || die "could not resolve latest release (set OLED_VERSION=1.5.0 or pass a local .deb)"
    fi
    VER_NUM="${VERSION#v}"
    info "version: ${VERSION}"

    BASE="${OLED_MIRROR:-https://github.com/${REPO}/releases/download/${VERSION}}"
    DEB="${TMP}/${PKG}_${VER_NUM}_${ARCH}.deb"

    info "downloading $(basename "${DEB}") ..."
    curl -fL --retry 3 --connect-timeout 15 -o "${DEB}" "${BASE}/$(basename "${DEB}")" \
        || die "download failed: ${BASE}/$(basename "${DEB}")"

    if curl -fsL --retry 2 --connect-timeout 15 -o "${DEB}.sha256" "${BASE}/$(basename "${DEB}").sha256" 2>/dev/null; then
        ( cd "${TMP}" && sha256sum -c "$(basename "${DEB}").sha256" ) || die "checksum mismatch"
        info "checksum verified"
    else
        warn "no .sha256 published for this release, skipping verification"
    fi
fi

# ------------------------------------------------------------------- install
info "installing $(basename "${DEB}") ..."
if ! dpkg -i "${DEB}" >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${DEB}" || die "dpkg/apt install failed"
    else
        die "dpkg install failed"
    fi
fi

# ------------------------------------------------------- enable and restart
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
    systemctl unmask "${SERVICE}" >/dev/null 2>&1 || true
    systemctl enable "${SERVICE}" || true
    systemctl restart "${SERVICE}" || true
fi

# --------------------------------------------------------------- diagnostics
if command -v apt-get >/dev/null 2>&1 && ! command -v i2cdetect >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends i2c-tools >/dev/null 2>&1 || true
fi

# ------------------------------------------------------------------- verify
sleep 3
echo
green "==> ${PKG} installed"
dpkg-query -W -f='    package: ${Package} ${Version} (${Architecture})\n' "${PKG}" 2>/dev/null || true
printf '    install dir: %s\n' "${INSTALL_DIR}"
if [ -e /dev/i2c-3 ]; then
    printf '    i2c bus: /dev/i2c-3 present\n'
else
    printf '    i2c bus: /dev/i2c-3 missing (check device tree / kernel)\n'
fi

if systemctl is-active --quiet "${SERVICE}"; then
    green "==> ${SERVICE} is active (OLED panel driven on i2c-3 / 0x3C)"
    IP="$(ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
    [ -n "${IP}" ] && printf '    panel shows IP: %s\n' "${IP}"
else
    warn "${SERVICE} is not active - see diagnostics below"
    printf '\n'
    systemctl status "${SERVICE}" --no-pager -n 10 || true
    journalctl -u "${SERVICE}" -n 15 --no-pager || true
    printf '\n'
    info "troubleshoot:"
    printf '    sudo i2cdetect -y 3                    # expect 3c at address 0x3c\n'
    printf '    sudo /usr/local/oled/oled              # run in foreground to see errors\n'
fi

echo
info "manage with: systemctl status|restart ${SERVICE}, journalctl -u ${SERVICE} -f"
```

---

## 八、构建与发布

```bash
packaging/build-deb.sh                 # 仅 arm64，输出 dist/*.deb 与 .deb.sha256
VERSION=1.5.0 packaging/build-deb.sh   # 指定版本（CI 用 tag 作为 VERSION）
```

- 构建脚本拒绝非 arm64 参数（本项目为 EasePi-A2 专用）；
- GitHub Actions（`.github/workflows/release.yml`）已改为**仅 arm64**，tag `v*` 触发后产出 `oled-linux-arm64`、`easepi-oled-daemon_<ver>_arm64.deb` 及其 `.sha256`，并自动创建 Release。

---

## 九、卸载与回滚

```bash
sudo apt-get remove easepi-oled-daemon     # 停止并禁用服务，保留 /usr/local/oled
sudo apt-get purge easepi-oled-daemon      # 额外删除 /usr/local/oled 与空 drop-in 目录
```

回退到旧版：`dpkg -i easepi-oled-daemon_1.4.0_arm64.deb`（旧版会把单元写回 `/etc/systemd/system`，`postinst` 会重新启用；如需彻底清理再执行一次 `dpkg --purge`）。

---

## 十、剩余可选优化（不影响当前交付）

1. 若后续支持多机型，可引入 `EnvironmentFile=/etc/default/oled` 让 `I2C_BUS`/地址可配置（当前为编译期常量，符合 A2 专用定位）。
2. 可为单元增加 `WatchdogSec=` 与 `sd_notify`，在总线异常时更快自愈。
3. 发布流水线可增加 `lintian` 检查，持续保证包质量（`conffile-not-in-etc` 类告警已通过 drop-in 方案规避）。
