BINARY := oled
WEB_BINARY := oled-web
MAIN := main.go
WEB_MAIN := ./cmd/oledweb
GOARCH := arm64
GOOS := linux
CGO := 0
LDFLAGS := -s -w
GOPROXY ?= https://goproxy.cn,direct
VERSION ?= $(shell git describe --tags --always 2>/dev/null | sed 's/^v//' || echo 1.0.0)

.PHONY: all build web deb app clean test help

all: build

# Standalone arm64 binary (EasePi-A2 only).
build:
	@echo "=> Building $(BINARY) for $(GOOS)/$(GOARCH)..."
	CGO_ENABLED=$(CGO) GOARCH=$(GOARCH) GOOS=$(GOOS) GOPROXY=$(GOPROXY) \
		go build -trimpath -ldflags="$(LDFLAGS)" -o $(BINARY) $(MAIN)
	@echo "=> Built: $(BINARY)"

# Web configuration UI (served on 127.0.0.1:8099 behind the iNextOS proxy).
web:
	@echo "=> Building $(WEB_BINARY) for $(GOOS)/$(GOARCH)..."
	CGO_ENABLED=$(CGO) GOARCH=$(GOARCH) GOOS=$(GOOS) GOPROXY=$(GOPROXY) \
		go build -trimpath -ldflags="$(LDFLAGS)" -o dist/$(WEB_BINARY) $(WEB_MAIN)
	@echo "=> Built: dist/$(WEB_BINARY)"

# Self-contained arm64 .deb (bundled font, no external dependencies).
deb:
	@echo "=> Building deb $(VERSION)..."
	VERSION=$(VERSION) packaging/build-deb.sh arm64

# iNextOS app bundle: web UI + installer + daemon package, ready to scp.
app: web deb
	@echo "=> Bundling iNextOS app $(VERSION)..."
	@rm -rf dist/app && mkdir -p dist/app
	install -m 0755 dist/$(WEB_BINARY) dist/app/
	install -m 0755 app/install.sh app/uninstall.sh dist/app/
	install -m 0755 app/register.py dist/app/register.py
	install -m 0644 packaging/oled-web.service dist/app/
	install -m 0644 cmd/oledweb/ui/icon.svg dist/app/
	cp dist/easepi-oled-daemon_$(VERSION)_arm64.deb dist/app/
	tar -C dist/app -czf dist/easepi-oled-app_$(VERSION)_arm64.tar.gz .
	@echo "    -> dist/easepi-oled-app_$(VERSION)_arm64.tar.gz"

clean:
	rm -f $(BINARY) oled-linux-*
	rm -rf dist

test:
	go vet ./...

help:
	@echo "make          - build arm64 binary ./$(BINARY)"
	@echo "make web      - build dist/$(WEB_BINARY) (web configuration UI)"
	@echo "make deb      - build dist/easepi-oled-daemon_<version>_arm64.deb (VERSION=$(VERSION))"
	@echo "make app      - build dist/easepi-oled-app_<version>_arm64.tar.gz (iNextOS app bundle)"
	@echo "make test     - run go vet"
	@echo "make clean    - remove binaries and dist/"
