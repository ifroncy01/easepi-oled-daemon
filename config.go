package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// ConfigPath is the runtime configuration file shared with the web UI.
const ConfigPath = "/etc/oled/config.json"

// Config holds runtime tunables. Panel geometry stays fixed because the A2
// hardware ships a 128x32 SSD1306 panel; the fields are kept in the file so a
// future board variant can reuse the same schema.
type Config struct {
	I2CBus     int     `json:"i2c_bus"`
	Address    int     `json:"address"`
	Width      int     `json:"width"`
	Height     int     `json:"height"`
	CPUHigh    float64 `json:"cpu_high_threshold"`
	TempHigh   int     `json:"temp_high_threshold"`
	NetHigh    float64 `json:"net_high_threshold"`
	EmaAlpha   float64 `json:"ema_alpha"`
	RefreshMS  int     `json:"refresh_ms"`
	Hysteresis int     `json:"hysteresis"`
	Silent     bool    `json:"silent"`
}

var (
	cfgMu sync.RWMutex
	cfg   = defaultConfig()
)

// defaultConfig mirrors the values the daemon used before it became
// configurable, so an unconfigured device behaves exactly as before.
func defaultConfig() Config {
	return Config{
		I2CBus:     3,
		Address:    0x3c,
		Width:      128,
		Height:     32,
		CPUHigh:    30,
		TempHigh:   60,
		NetHigh:    100,
		EmaAlpha:   0.3,
		RefreshMS:  950,
		Hysteresis: 3,
		Silent:     false,
	}
}

func currentConfig() Config {
	cfgMu.RLock()
	defer cfgMu.RUnlock()
	return cfg
}

func applyConfig(c Config) {
	cfgMu.Lock()
	cfg = c
	cfgMu.Unlock()
}

// normalizeConfig clamps user input to sane ranges.
func normalizeConfig(c *Config) {
	if c.I2CBus < 0 || c.I2CBus > 9 {
		c.I2CBus = 3
	}
	if c.Address < 0x03 || c.Address > 0x77 {
		c.Address = 0x3c
	}
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
	if c.EmaAlpha <= 0 || c.EmaAlpha >= 1 {
		c.EmaAlpha = 0.3
	}
	if c.RefreshMS < 200 || c.RefreshMS > 5000 {
		c.RefreshMS = 950
	}
	if c.Hysteresis < 1 || c.Hysteresis > 20 {
		c.Hysteresis = 3
	}
}

// loadConfig merges the values found in path on top of the defaults.
func loadConfig(path string) (Config, error) {
	out := defaultConfig()
	data, err := os.ReadFile(path)
	if err != nil {
		return out, err
	}
	if err := json.Unmarshal(data, &out); err != nil {
		return defaultConfig(), fmt.Errorf("parse %s: %w", path, err)
	}
	normalizeConfig(&out)
	return out, nil
}

// ensureConfigFile writes the default configuration when the file is absent
// so operators and the web UI have something to edit.
func ensureConfigFile(path string) error {
	if _, err := os.Stat(path); err == nil {
		return nil
	}
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(defaultConfig(), "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	return os.WriteFile(path, data, 0644)
}

// fileModTime returns the current modification time of path.
func fileModTime(path string) time.Time {
	st, err := os.Stat(path)
	if err != nil {
		return time.Time{}
	}
	return st.ModTime()
}
