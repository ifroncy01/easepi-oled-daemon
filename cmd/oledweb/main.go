package main

import (
	_ "embed"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

//go:embed ui/index.html
var indexHTML []byte

//go:embed ui/icon.svg
var iconSVG []byte

const (
	configPath = "/etc/oled/config.json"
	unitName   = "oled.service"
	appDir     = "/opt/roceos/apps/oled"

	// Fixed EasePi-A2 panel wiring; intentionally not configurable.
	i2cBus  = 3
	i2cAddr = 0x3c
)

// Config is the on-disk schema shared with the oled daemon (see config.go in
// the repository root). Keep the JSON tags in sync. The I2C bus/address and the
// timing constants are hardware/firmware values and are not part of this schema.
type Config struct {
	Width    int     `json:"width"`
	Height   int     `json:"height"`
	CPUHigh  float64 `json:"cpu_high_threshold"`
	TempHigh int     `json:"temp_high_threshold"`
	NetHigh  float64 `json:"net_high_threshold"`
	Silent   bool    `json:"silent"`
}

func defaultConfig() Config {
	return Config{
		Width:    128,
		Height:   32,
		CPUHigh:  30,
		TempHigh: 60,
		NetHigh:  100,
		Silent:   false,
	}
}

func loadConfig() (Config, error) {
	out := defaultConfig()
	data, err := os.ReadFile(configPath)
	if err != nil {
		return out, err
	}
	if err := json.Unmarshal(data, &out); err != nil {
		return defaultConfig(), fmt.Errorf("parse %s: %w", configPath, err)
	}
	return out, nil
}

func (c *Config) normalize() {
	if c.Width <= 0 {
		c.Width = 128
	}
	if c.Height <= 0 {
		c.Height = 32
	}
	if c.CPUHigh < 1 || c.CPUHigh > 100 {
		c.CPUHigh = 30
	}
	if c.TempHigh < 30 || c.TempHigh > 110 {
		c.TempHigh = 60
	}
	if c.NetHigh < 1 || c.NetHigh > 100000 {
		c.NetHigh = 100
	}
}

func (c Config) validate() []string {
	var errs []string
	if c.CPUHigh < 1 || c.CPUHigh > 100 {
		errs = append(errs, "cpu_high_threshold 必须在 1-100 之间")
	}
	if c.TempHigh < 30 || c.TempHigh > 110 {
		errs = append(errs, "temp_high_threshold 必须在 30-110 之间")
	}
	if c.NetHigh < 1 || c.NetHigh > 100000 {
		errs = append(errs, "net_high_threshold 必须在 1-100000 之间")
	}
	return errs
}

func saveConfig(c Config) error {
	data, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	if err := os.MkdirAll("/etc/oled", 0755); err != nil {
		return err
	}
	tmp := configPath + ".tmp"
	if err := os.WriteFile(tmp, data, 0644); err != nil {
		return err
	}
	return os.Rename(tmp, configPath)
}

// --- systemd helpers -------------------------------------------------------

func systemctl(args ...string) (string, error) {
	cmd := exec.Command("systemctl", args...)
	out, err := cmd.CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

func serviceState() map[string]any {
	active, _ := systemctl("is-active", unitName)
	enabled, _ := systemctl("is-enabled", unitName)
	pid, _ := systemctl("show", "-p", "MainPID", "--value", unitName)
	since, _ := systemctl("show", "-p", "ActiveEnterTimestamp", "--value", unitName)

	_, err := loadConfig()
	panel := false
	if _, statErr := os.Stat(fmt.Sprintf("/dev/i2c-%d", i2cBus)); statErr == nil {
		panel = true
	}
	return map[string]any{
		"service":      active,
		"enabled":      enabled,
		"pid":          pid,
		"active_since": since,
		"panel_device": panel,
		"bus":          i2cBus,
		"address":      i2cAddr,
		"config_ok":    err == nil,
	}
}

func logs(tail int) string {
	if tail < 1 || tail > 500 {
		tail = 50
	}
	out, _ := exec.Command("journalctl", "-u", unitName, "-n", strconv.Itoa(tail), "--no-pager", "-o", "short-iso").CombinedOutput()
	return strings.TrimSpace(string(out))
}

// --- HTTP -----------------------------------------------------------------

// isPrivateIP limits the unauthenticated config UI to the local network so an
// accidentally forwarded port cannot expose daemon control to the internet.
func isPrivateIP(host string) bool {
	ip := net.ParseIP(host)
	if ip == nil {
		return false
	}
	if ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() {
		return true
	}
	return false
}

func lanOnly(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host, _, err := net.SplitHostPort(r.RemoteAddr)
		if err != nil {
			host = r.RemoteAddr
		}
		if !isPrivateIP(host) {
			http.Error(w, "403 forbidden: OLED config UI is LAN-only", http.StatusForbidden)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func handleConfig(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		c, err := loadConfig()
		if err != nil {
			writeJSON(w, http.StatusOK, map[string]any{
				"config": c, "warning": fmt.Sprintf("读取 %s 失败，返回默认配置: %v", configPath, err),
			})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"config": c})
	case http.MethodPost, http.MethodPut:
		var req struct {
			Config  Config `json:"config"`
			Restart bool   `json:"restart"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": "请求体格式错误: " + err.Error()})
			return
		}
		if errs := req.Config.validate(); len(errs) > 0 {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": strings.Join(errs, "；")})
			return
		}
		req.Config.normalize()
		if err := saveConfig(req.Config); err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "写入配置失败: " + err.Error()})
			return
		}
		msg := "配置已保存，守护进程将在下次轮询时热加载"
		if req.Restart {
			if _, err := systemctl("restart", unitName); err != nil {
				writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "重启服务失败: " + err.Error()})
				return
			}
			msg = "配置已保存，服务已重启"
		}
		log.Printf("config updated (restart=%v): cpu=%.0f temp=%d net=%.0f",
			req.Restart, req.Config.CPUHigh, req.Config.TempHigh, req.Config.NetHigh)
		writeJSON(w, http.StatusOK, map[string]any{"message": msg, "config": req.Config})
	default:
		w.Header().Set("Allow", "GET, POST, PUT")
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "方法不允许"})
	}
}

func handleService(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "仅支持 POST"})
		return
	}
	var req struct {
		Action string `json:"action"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "请求体格式错误"})
		return
	}
	action := strings.TrimSpace(req.Action)
	allowed := map[string][]string{
		"start":   {"start", unitName},
		"stop":    {"stop", unitName},
		"restart": {"restart", unitName},
		"enable":  {"enable", unitName},
		"disable": {"disable", unitName},
	}
	args, ok := allowed[action]
	if !ok {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "不支持的操作: " + action})
		return
	}
	out, err := systemctl(args...)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": fmt.Sprintf("%v: %s", err, out)})
		return
	}
	time.Sleep(300 * time.Millisecond)
	writeJSON(w, http.StatusOK, map[string]any{"message": "已执行 " + action, "state": serviceState()})
}

func handleLogs(w http.ResponseWriter, r *http.Request) {
	tail := 50
	if v := r.URL.Query().Get("tail"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			tail = n
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"logs": logs(tail)})
}

// uninstallCommand returns the purge command. The app bundle installs an
// uninstaller into the iNextOS app directory (it also unregisters the desktop
// icon); standalone deb installs fall back to a plain dpkg purge.
func uninstallCommand() string {
	if _, err := os.Stat(appDir + "/uninstall.sh"); err == nil {
		return "bash " + appDir + "/uninstall.sh --purge"
	}
	return "dpkg -P easepi-oled-daemon; " +
		"rm -rf /usr/local/oled /etc/oled /etc/systemd/system/oled-web.service.d; " +
		"rm -f /usr/lib/systemd/system/oled.service /usr/lib/systemd/system/oled-web.service; " +
		"systemctl daemon-reload"
}

// handleUninstall runs the purge in a transient systemd unit. The handler
// cannot run it inline: dpkg removes the oled-web binary and stops its unit,
// which would kill the process before the response is flushed.
func handleUninstall(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "仅支持 POST"})
		return
	}

	cmd := exec.Command("systemd-run", "--unit=oled-uninstall", "--collect", "--no-block", "--quiet",
		"/bin/sh", "-c", uninstallCommand())
	if out, err := cmd.CombinedOutput(); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": fmt.Sprintf("%v: %s", err, strings.TrimSpace(string(out)))})
		return
	}
	log.Printf("uninstall requested from %s", r.RemoteAddr)
	writeJSON(w, http.StatusOK, map[string]any{
		"message": "卸载任务已启动，服务与网页将在数秒内消失，配置文件与桌面图标一并清除",
		"unit":    "oled-uninstall",
	})
}

func main() {
	port := flag.Int("port", 8099, "HTTP listen port")
	bind := flag.String("bind", "127.0.0.1", "HTTP listen address")
	flag.Parse()
	if v := os.Getenv("OLEDWEB_PORT"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			*port = n
		}
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" && r.URL.Path != "/index.html" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		_, _ = w.Write(indexHTML)
	})
	mux.HandleFunc("/icon.svg", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "image/svg+xml")
		w.Header().Set("Cache-Control", "public, max-age=86400")
		_, _ = w.Write(iconSVG)
	})
	mux.HandleFunc("/api/status", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, serviceState())
	})
	mux.HandleFunc("/api/config", handleConfig)
	mux.HandleFunc("/api/service", handleService)
	mux.HandleFunc("/api/logs", handleLogs)
	mux.HandleFunc("/api/uninstall", handleUninstall)
	mux.HandleFunc("/api/health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	})

	addr := fmt.Sprintf("%s:%d", *bind, *port)
	srv := &http.Server{
		Addr:              addr,
		Handler:           lanOnly(mux),
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Printf("oled-web listening on %s (config %s, unit %s)", addr, configPath, unitName)
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("listen: %v", err)
	}
}
