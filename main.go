package main

import (
	"flag"
	"fmt"
	"image"
	"image/color"
	"io"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"golang.org/x/image/font"
	"golang.org/x/image/font/opentype"
	"golang.org/x/image/math/fixed"
)

const (
	// I2C_BUS and DEVICE_ADDR are fixed for the EasePi-A2 hardware and are
	// deliberately not exposed to the config file or the web UI.
	I2C_BUS     = 3
	DEVICE_ADDR = 0x3c
	WIDTH       = 128
	HEIGHT      = 32

	// Display timing and smoothing are fixed tuning constants; the web UI
	// shows them read-only. Only the three load thresholds are tunable.
	EMA_ALPHA  = 0.3
	REFRESH_MS = 950
	HYSTERESIS = 3

	SSD1306_COMMAND = 0x00
	SSD1306_DATA    = 0x40
	I2C_SLAVE       = 0x0703
	I2C_RETRY       = 3

	MODE_1_LINE = 0
	MODE_2_CPU  = 1
	MODE_2_NET  = 2
	MODE_3_LINE = 3

	FONT_14 = 14.0
	FONT_12 = 12.0
	FONT_11 = 11.0

	LINE_SPACING_2H = 16
	LINE_SPACING_3H = 10
)

var logger *log.Logger

type SSD1306 struct {
	fd *os.File
}

func newSSD1306() (*SSD1306, error) {
	path := fmt.Sprintf("/dev/i2c-%d", I2C_BUS)
	fd, err := os.OpenFile(path, os.O_RDWR, 0600)
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", path, err)
	}
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd.Fd(), I2C_SLAVE, uintptr(DEVICE_ADDR))
	if errno != 0 {
		fd.Close()
		return nil, fmt.Errorf("ioctl I2C_SLAVE: %v", errno)
	}
	// Probe the panel directly with a display-off command; a missing device NAKs here.
	if _, err := fd.Write([]byte{SSD1306_COMMAND, 0xAE}); err != nil {
		fd.Close()
		return nil, fmt.Errorf("no OLED response at 0x%02x on i2c-%d: %w", DEVICE_ADDR, I2C_BUS, err)
	}
	return &SSD1306{fd: fd}, nil
}

func (o *SSD1306) Close() error {
	return o.fd.Close()
}

func (o *SSD1306) writeCmd(cmd byte) error {
	_, err := o.fd.Write([]byte{SSD1306_COMMAND, cmd})
	return err
}

func (o *SSD1306) writeCmds(cmds []byte) error {
	for _, c := range cmds {
		if err := o.writeCmd(c); err != nil {
			return err
		}
		time.Sleep(time.Microsecond)
	}
	return nil
}

func (o *SSD1306) writeData(data []byte) error {
	buf := make([]byte, 1+len(data))
	buf[0] = SSD1306_DATA
	copy(buf[1:], data)
	_, err := o.fd.Write(buf)
	return err
}

func retryI2C(fn func() error) error {
	var lastErr error
	for i := 0; i < I2C_RETRY; i++ {
		err := fn()
		if err == nil {
			return nil
		}
		lastErr = err
		if i < I2C_RETRY-1 {
			time.Sleep(100 * time.Millisecond)
		}
	}
	return fmt.Errorf("I2C operation failed after %d retries: %w", I2C_RETRY, lastErr)
}

func (o *SSD1306) Init() error {
	initCmds := []byte{
		0xAE, 0x20, 0x00, 0x00, 0x10, 0xB0,
		0xA1, 0xC8, 0xA6, 0xA8, 0x1F, 0xD3,
		0x00, 0xD5, 0x80, 0xD9, 0xF1, 0xDA,
		0x02, 0xDB, 0x40, 0x8D, 0x14, 0x40,
		0xA4, 0xAF,
	}
	return o.writeCmds(initCmds)
}

func (o *SSD1306) Clear() error {
	return retryI2C(func() error {
		for page := 0; page < 4; page++ {
			o.writeCmd(0xB0 + byte(page))
			o.writeCmd(0x00)
			o.writeCmd(0x10)
			for i := 0; i < 128; i += 32 {
				data := make([]byte, 32)
				if err := o.writeData(data); err != nil {
					return err
				}
			}
		}
		return nil
	})
}

func (o *SSD1306) SendImage(img *image.Gray) error {
	if img.Bounds().Dx() != WIDTH || img.Bounds().Dy() != HEIGHT {
		return fmt.Errorf("image size must be %dx%d", WIDTH, HEIGHT)
	}
	return retryI2C(func() error {
		for page := 0; page < 4; page++ {
			o.writeCmd(0xB0 + byte(page))
			o.writeCmd(0x00)
			o.writeCmd(0x10)
			pageData := make([]byte, 128)
			for x := 0; x < WIDTH; x++ {
				var b byte
				for bit := 0; bit < 8; bit++ {
					y := page<<3 + bit
					if y < HEIGHT && img.GrayAt(x, y).Y > 128 {
						b |= 1 << bit
					}
				}
				pageData[x] = b
			}
			for i := 0; i < 128; i += 32 {
				if err := o.writeData(pageData[i : i+32]); err != nil {
					return err
				}
			}
		}
		return nil
	})
}

type NetMon struct {
	prevRx         uint64
	prevTx         uint64
	prevTime       time.Time
	emaRx          float64
	emaTx          float64
	cachedIface    string
	ifaceCheckTime time.Time
}

func newNetMon() *NetMon {
	return &NetMon{prevTime: time.Now()}
}

func (n *NetMon) readBytes(iface string) (uint64, uint64) {
	data, err := os.ReadFile("/proc/net/dev")
	if err != nil {
		return 0, 0
	}
	lines := strings.Split(string(data), "\n")
	for _, line := range lines {
		if !strings.Contains(line, iface) {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 10 {
			continue
		}
		rx, _ := strconv.ParseUint(fields[1], 10, 64)
		tx, _ := strconv.ParseUint(fields[9], 10, 64)
		return rx, tx
	}
	return 0, 0
}

func (n *NetMon) detectIface() string {
	now := time.Now()
	if n.cachedIface != "" && now.Sub(n.ifaceCheckTime) < 30*time.Second {
		data, err := os.ReadFile("/proc/net/dev")
		if err == nil && strings.Contains(string(data), n.cachedIface) {
			return n.cachedIface
		}
	}
	n.cachedIface = ""
	n.ifaceCheckTime = now
	data, err := os.ReadFile("/proc/net/dev")
	if err != nil {
		return ""
	}
	lines := strings.Split(string(data), "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "Inter-") || strings.HasPrefix(line, "face") || strings.HasPrefix(line, "lo:") {
			continue
		}
		idx := strings.Index(line, ":")
		if idx < 0 {
			continue
		}
		iface := line[:idx+1]
		fields := strings.Fields(line[idx+1:])
		if len(fields) < 10 {
			continue
		}
		rx, _ := strconv.ParseUint(fields[0], 10, 64)
		if rx > 0 {
			n.cachedIface = iface
			return iface
		}
	}
	return ""
}

func (n *NetMon) GetSpeed() (string, string) {
	iface := n.detectIface()
	if iface == "" {
		return "\u21930B", "\u21910B"
	}
	rx, tx := n.readBytes(iface)
	now := time.Now()
	interval := now.Sub(n.prevTime).Seconds()
	if n.prevTime.IsZero() || interval < 0.05 || rx < n.prevRx || tx < n.prevTx {
		n.prevRx, n.prevTx, n.prevTime = rx, tx, now
		if n.prevTime.IsZero() {
			n.prevTime = now
		}
		return formatSpeed(max(n.emaRx, 0), '\u2193'), formatSpeed(max(n.emaTx, 0), '\u2191')
	}
	rxSpeed := float64(rx-n.prevRx) / interval / 1024.0
	txSpeed := float64(tx-n.prevTx) / interval / 1024.0
	if n.emaRx == 0.0 {
		n.emaRx, n.emaTx = rxSpeed, txSpeed
	} else {
		alpha := float64(EMA_ALPHA)
		n.emaRx = alpha*rxSpeed + (1-alpha)*n.emaRx
		n.emaTx = alpha*txSpeed + (1-alpha)*n.emaTx
	}
	n.prevRx, n.prevTx, n.prevTime = rx, tx, now
	return formatSpeed(max(n.emaRx, 0), '\u2193'), formatSpeed(max(n.emaTx, 0), '\u2191')
}

func formatSpeed(kbs float64, prefix rune) string {
	if kbs < 0.95 {
		bps := kbs * 1024
		if bps < 99.5 {
			return fmt.Sprintf("%c%dB", prefix, int(bps))
		}
		return fmt.Sprintf("%c%.1fK", prefix, bps/1024)
	}
	if kbs < 999.5 {
		return fmt.Sprintf("%c%dK", prefix, int(kbs))
	}
	if kbs < 999500 {
		return fmt.Sprintf("%c%.1fM", prefix, kbs/1024)
	}
	return fmt.Sprintf("%c%.1fG", prefix, kbs/1048576)
}

func getIP() string {
	out, err := exec.Command("sh", "-c", "ip addr show eth0 | grep 'inet ' | awk '{print $2}' | cut -d/ -f1").Output()
	if err == nil && len(out) > 0 {
		ip := strings.TrimSpace(string(out))
		if ip != "" {
			return ip
		}
	}
	out, err = exec.Command("sh", "-c", "hostname -I | awk '{print $1}'").Output()
	if err == nil && len(out) > 0 {
		ip := strings.TrimSpace(string(out))
		if ip != "" {
			return ip
		}
	}
	return "No Network"
}

// cpuTicks returns the aggregate CPU counters from /proc/stat.
func cpuTicks() (total, idle int, ok bool) {
	data, err := os.ReadFile("/proc/stat")
	if err != nil {
		return 0, 0, false
	}
	fields := strings.Fields(strings.SplitN(string(data), "\n", 2)[0])
	if len(fields) < 8 {
		return 0, 0, false
	}
	idleTicks, err := strconv.Atoi(fields[4])
	if err != nil {
		return 0, 0, false
	}
	return sumFields(fields[1:8]), idleTicks, true
}

// cpuSampler averages utilisation over the interval between two refresh ticks.
// Measuring a 50 ms slice made the value flap between 0% and 30%, so the mode
// hysteresis never saw three consecutive samples above a low threshold and the
// panel stayed on the one-line view.
type cpuSampler struct {
	prevTotal int
	prevIdle  int
	primed    bool
}

func (s *cpuSampler) sample() string {
	total, idle, ok := cpuTicks()
	if !ok {
		return "0%"
	}
	if !s.primed {
		s.primed = true
		s.prevTotal, s.prevIdle = total, idle
		time.Sleep(200 * time.Millisecond)
		if total, idle, ok = cpuTicks(); !ok {
			return "0%"
		}
	}
	diffTotal := total - s.prevTotal
	diffIdle := idle - s.prevIdle
	s.prevTotal, s.prevIdle = total, idle
	if diffTotal <= 0 {
		return "0%"
	}
	return fmt.Sprintf("%.0f%%", float64(diffTotal-diffIdle)*100/float64(diffTotal))
}

func getCPUTemp() string {
	tempData, err := os.ReadFile("/sys/class/thermal/thermal_zone0/temp")
	if err == nil {
		t := strings.TrimSpace(string(tempData))
		if val, err := strconv.Atoi(t); err == nil {
			return fmt.Sprintf("%d\u00b0C", val/1000)
		}
	}
	return "N/A"
}

func sumFields(fields []string) int {
	sum := 0
	for _, f := range fields {
		v, _ := strconv.Atoi(f)
		sum += v
	}
	return sum
}

func loadFontFace(timeSize float64) font.Face {
	paths := []string{
		"/usr/local/oled/DejaVuSansMono.ttf",
		"/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
	}
	for _, p := range paths {
		data, err := os.ReadFile(p)
		if err != nil {
			continue
		}
		f, err := opentype.Parse(data)
		if err != nil {
			continue
		}
		face, err := opentype.NewFace(f, &opentype.FaceOptions{
			Size:    timeSize,
			DPI:     72,
			Hinting: font.HintingFull,
		})
		if err != nil {
			continue
		}
		logger.Printf("using font: %s (%.0fpx)", p, timeSize)
		return face
	}
	return nil
}

func drawText(img *image.Gray, face font.Face, text string, x, y int) {
	if face == nil {
		return
	}
	drawer := &font.Drawer{
		Dst:  img,
		Src:  image.NewUniform(color.White),
		Face: face,
		Dot:  fixed.P(x, y),
	}
	drawer.DrawString(text)
}

func textWidth(face font.Face, text string) int {
	if face == nil {
		return 0
	}
	return font.MeasureString(face, text).Ceil()
}

func textDescent(face font.Face) int {
	return face.Metrics().Descent.Ceil()
}

func chooseMode(cpuUsagePct float64, cpuTempVal int, netRxKbps, netTxKbps float64) int {
	c := currentConfig()
	cpuHigh := cpuUsagePct > c.CPUHigh || cpuTempVal > c.TempHigh
	netHigh := netRxKbps > c.NetHigh || netTxKbps > c.NetHigh

	switch {
	case cpuHigh && netHigh:
		return MODE_3_LINE
	case cpuHigh && !netHigh:
		return MODE_2_CPU
	case !cpuHigh && netHigh:
		return MODE_2_NET
	default:
		return MODE_1_LINE
	}
}

func main() {
	silentFlag := flag.Bool("s", false, "silent mode")
	flag.BoolVar(silentFlag, "silent", false, "silent mode")
	flag.Parse()

	// Load the shared configuration before any output so silent mode from the
	// file takes effect immediately.
	if err := ensureConfigFile(ConfigPath); err != nil {
		fmt.Fprintf(os.Stderr, "config %s: %v\n", ConfigPath, err)
	}
	if c, err := loadConfig(ConfigPath); err != nil {
		fmt.Fprintf(os.Stderr, "config %s: %v (using defaults)\n", ConfigPath, err)
	} else {
		applyConfig(c)
	}

	cfgNow := currentConfig()
	silentNow := *silentFlag || cfgNow.Silent
	var writer io.Writer = os.Stdout
	if silentNow {
		// 静默模式，丢弃所有输出
		writer = io.Discard
	}
	logger = log.New(writer, "", log.LstdFlags)

	logger.Println("=== EasePi A2 OLED Go Auto Mode ===")
	logger.Printf("config: i2c-%d addr=0x%02x refresh=%dms alpha=%.2f cpu=%.0f%% temp=%dC net=%.0fK hysteresis=%d",
		I2C_BUS, DEVICE_ADDR, REFRESH_MS, EMA_ALPHA,
		cfgNow.CPUHigh, cfgNow.TempHigh, cfgNow.NetHigh, HYSTERESIS)

	if os.Geteuid() != 0 {
		logger.Fatal("must run as root")
	}

	bus := I2C_BUS
	if _, err := os.Stat(fmt.Sprintf("/dev/i2c-%d", bus)); err != nil {
		exec.Command("modprobe", "i2c-dev").Run()
		if _, err := os.Stat(fmt.Sprintf("/dev/i2c-%d", bus)); err != nil {
			logger.Fatalf("i2c-%d device not found", bus)
		}
	}

	oled, err := newSSD1306()
	if err != nil {
		logger.Fatal(err)
	}
	defer oled.Close()

	if err := oled.Init(); err != nil {
		logger.Fatalf("OLED init failed: %v", err)
	}
	if err := oled.Clear(); err != nil {
		logger.Fatalf("OLED clear failed: %v", err)
	}
	logger.Println("OLED initialized")

	face14 := loadFontFace(FONT_14)
	if face14 != nil {
		defer face14.Close()
	}
	face12 := loadFontFace(FONT_12)
	if face12 != nil {
		defer face12.Close()
	}
	face11 := loadFontFace(FONT_11)
	if face11 != nil {
		defer face11.Close()
	}

	showBrandAnimation(oled, face11, face12, face14)

	netmon := newNetMon()
	cachedIP := getIP()
	ipUpdateCount := 0
	cpuTracker := &cpuSampler{}

	currentMode := MODE_1_LINE
	modeChangeCounter := 0
	targetMode := MODE_1_LINE

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	ticker := time.NewTicker(time.Duration(REFRESH_MS) * time.Millisecond)
	defer ticker.Stop()

	cfgModTime := fileModTime(ConfigPath)

	logger.Println("Main loop started")

	for {
		select {
		case <-sigCh:
			logger.Println("Received shutdown signal")
			oled.Clear()
			return
		case <-ticker.C:
		}

		// Hot-reload /etc/oled/config.json so the web UI can retune the panel
		// without restarting the service.
		if mt := fileModTime(ConfigPath); mt.After(cfgModTime) {
			cfgModTime = mt
			if c, err := loadConfig(ConfigPath); err != nil {
				logger.Printf("config reload failed: %v", err)
			} else {
				applyConfig(c)
				logger.Printf("config reloaded: cpu=%.0f%% temp=%dC net=%.0fK",
					c.CPUHigh, c.TempHigh, c.NetHigh)
				if want := c.Silent || *silentFlag; want != silentNow {
					silentNow = want
					if want {
						logger.SetOutput(io.Discard)
					} else {
						logger.SetOutput(os.Stdout)
					}
				}
				cfgNow = c
			}
		}

		ipUpdateCount++
		if ipUpdateCount%5 == 0 {
			cachedIP = getIP()
			ipUpdateCount = 0
		}

		cpuUsage := cpuTracker.sample()
		cpuTemp := getCPUTemp()
		rxSpeed, txSpeed := netmon.GetSpeed()

		cpuPct := parseCPUPercent(cpuUsage)
		tempVal := parseTempValue(cpuTemp)
		rxKbps := parseSpeedKbps(rxSpeed)
		txKbps := parseSpeedKbps(txSpeed)

		newTarget := chooseMode(cpuPct, tempVal, rxKbps, txKbps)

		if newTarget != currentMode {
			if newTarget == targetMode {
				modeChangeCounter++
				if modeChangeCounter >= HYSTERESIS {
					currentMode = targetMode
					modeChangeCounter = 0
					logger.Printf("Mode changed to: %d (CPU:%.1f%% Temp:%d\u00b0C RX:%.1fK TX:%.1fK)",
						currentMode, cpuPct, tempVal, rxKbps, txKbps)
				}
			} else {
				targetMode = newTarget
				modeChangeCounter = 0
			}
		} else {
			targetMode = currentMode
			modeChangeCounter = 0
		}

		img := image.NewGray(image.Rect(0, 0, WIDTH, HEIGHT))

		switch currentMode {
		case MODE_1_LINE:
			render1Line(img, face14, cachedIP)
		case MODE_2_CPU:
			render2CPU(img, face12, cachedIP, cpuUsage, cpuTemp)
		case MODE_2_NET:
			render2Net(img, face12, cachedIP, rxSpeed, txSpeed)
		case MODE_3_LINE:
			render3Line(img, face11, cachedIP, cpuUsage, cpuTemp, rxSpeed, txSpeed)
		}

		oled.SendImage(img)
	}
}

func render1Line(img *image.Gray, face font.Face, ip string) {
	if face == nil {
		return
	}
	y := HEIGHT - textDescent(face) - 2
	w := textWidth(face, ip)
	drawText(img, face, ip, (WIDTH-w)/2, y)
}

func render2CPU(img *image.Gray, face font.Face, ip, cpuUsage, cpuTemp string) {
	if face == nil {
		return
	}
	descent := textDescent(face)
	startY := HEIGHT - descent - LINE_SPACING_2H - 2

	cpuLine := fmt.Sprintf("CPU: %s %s", cpuUsage, cpuTemp)
	w := textWidth(face, cpuLine)
	drawText(img, face, cpuLine, (WIDTH-w)/2, startY)

	w = textWidth(face, ip)
	drawText(img, face, ip, (WIDTH-w)/2, startY+LINE_SPACING_2H)
}

func render2Net(img *image.Gray, face font.Face, ip, rxSpeed, txSpeed string) {
	if face == nil {
		return
	}
	descent := textDescent(face)
	startY := HEIGHT - descent - LINE_SPACING_2H - 2

	netLabel := "NET:"
	labelW := textWidth(face, netLabel)

	rxValOnly := rxSpeed
	if len(rxSpeed) >= 3 {
		rxValOnly = rxSpeed[3:]
	}
	txValOnly := txSpeed
	if len(txSpeed) >= 3 {
		txValOnly = txSpeed[3:]
	}

	arrowW := textWidth(face, "\u2193")
	rxW := textWidth(face, rxValOnly)
	txW := textWidth(face, txValOnly)

	totalW := labelW + arrowW + rxW + 6 + arrowW + txW
	x := (WIDTH - totalW) / 2

	drawText(img, face, netLabel, x, startY)
	drawText(img, face, "\u2193"+rxValOnly, x+labelW, startY)
	drawText(img, face, "\u2191"+txValOnly, x+labelW+arrowW+rxW+6, startY)

	w := textWidth(face, ip)
	drawText(img, face, ip, (WIDTH-w)/2, startY+LINE_SPACING_2H)
}

func render3Line(img *image.Gray, face font.Face, ip, cpuUsage, cpuTemp, rxSpeed, txSpeed string) {
	if face == nil {
		return
	}
	lineSpacing := LINE_SPACING_3H
	startY := 0

	cpuLine := fmt.Sprintf("CPU: %s %s", cpuUsage, cpuTemp)
	w := textWidth(face, cpuLine)
	drawText(img, face, cpuLine, (WIDTH-w)/2, startY+8)

	netLabel := "NET:"
	labelW := textWidth(face, netLabel)

	rxValOnly := rxSpeed
	if len(rxSpeed) >= 3 {
		rxValOnly = rxSpeed[3:]
	}
	txValOnly := txSpeed
	if len(txSpeed) >= 3 {
		txValOnly = txSpeed[3:]
	}

	arrowW := textWidth(face, "\u2193")
	rxW := textWidth(face, rxValOnly)
	txW := textWidth(face, txValOnly)

	totalW := labelW + arrowW + rxW + 6 + arrowW + txW
	x := (WIDTH - totalW) / 2
	netY := startY + lineSpacing + 8

	drawText(img, face, netLabel, x, netY)
	drawText(img, face, "\u2193"+rxValOnly, x+labelW, netY)
	drawText(img, face, "\u2191"+txValOnly, x+labelW+arrowW+rxW+6, netY)

	w = textWidth(face, ip)
	drawText(img, face, ip, (WIDTH-w)/2, startY+2*lineSpacing+8)
}

func parseCPUPercent(s string) float64 {
	s = strings.TrimSuffix(s, "%")
	v, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return 0
	}
	return v
}

func parseTempValue(s string) int {
	s = strings.TrimSuffix(s, "\u00b0C")
	s = strings.TrimSuffix(s, "°C")
	if strings.TrimSpace(s) == "N/A" {
		return 0
	}
	v, err := strconv.Atoi(s)
	if err != nil {
		return 0
	}
	return v
}

func parseSpeedKbps(s string) float64 {
	if len(s) < 2 {
		return 0
	}
	s = s[3:]
	if len(s) == 0 {
		return 0
	}
	unit := s[len(s)-1]
	numStr := s[:len(s)-1]
	val, err := strconv.ParseFloat(numStr, 64)
	if err != nil {
		return 0
	}
	switch unit {
	case 'G':
		return val * 1048576
	case 'M':
		return val * 1024
	case 'K':
		return val
	case 'B':
		return val / 1024
	}
	return 0
}

func showBrandAnimation(oled *SSD1306, face11, face12, face14 font.Face) {
	brand := "LinkEase"

	steps := []struct {
		face  font.Face
		y     int
		sleep time.Duration
	}{}

	if face11 != nil {
		steps = append(steps, struct {
			face  font.Face
			y     int
			sleep time.Duration
		}{face11, (HEIGHT+(11-textDescent(face11)))/2 + 4, 150 * time.Millisecond})
	}

	if face12 != nil {
		steps = append(steps, struct {
			face  font.Face
			y     int
			sleep time.Duration
		}{face12, (HEIGHT+(12-textDescent(face12)))/2 + 4, 150 * time.Millisecond})
	}

	if face14 != nil {
		steps = append(steps, struct {
			face  font.Face
			y     int
			sleep time.Duration
		}{face14, (HEIGHT+(14-textDescent(face14)))/2 + 4, 150 * time.Millisecond})
	}

	// 动态加载 16px 字体用于最后停留
	face16 := loadFontFace(16.0)

	if face14 != nil && face16 != nil {
		steps = append(steps, struct {
			face  font.Face
			y     int
			sleep time.Duration
		}{face16, (HEIGHT+(16-textDescent(face16)))/2 + 4, 3000 * time.Millisecond})
	} else if face14 != nil {
		// 回退到 14px
		steps = append(steps, struct {
			face  font.Face
			y     int
			sleep time.Duration
		}{face14, (HEIGHT+(14-textDescent(face14)))/2 + 4, 3000 * time.Millisecond})
	}

	for _, step := range steps {
		img := image.NewGray(image.Rect(0, 0, WIDTH, HEIGHT))
		w := textWidth(step.face, brand)
		drawText(img, step.face, brand, (WIDTH-w)/2, step.y)
		oled.SendImage(img)
		time.Sleep(step.sleep)
	}

	oled.Clear()

	// 清理动态加载的字体
	if fc, ok := face16.(interface{ Close() error }); ok {
		fc.Close()
	}
}
