BINARY := oled
MAIN := main.go
GOARCH := arm64
GOOS := linux
CGO := 0
LDFLAGS := -s -w
GOPROXY ?= https://goproxy.cn,direct
VERSION ?= $(shell git describe --tags --always 2>/dev/null | sed 's/^v//' || echo 1.0.0)

.PHONY: all build deb clean test help

all: build

# Standalone arm64 binary (EasePi-A2 only).
build:
	@echo "=> Building $(BINARY) for $(GOOS)/$(GOARCH)..."
	CGO_ENABLED=$(CGO) GOARCH=$(GOARCH) GOOS=$(GOOS) GOPROXY=$(GOPROXY) \
		go build -trimpath -ldflags="$(LDFLAGS)" -o $(BINARY) $(MAIN)
	@echo "=> Built: $(BINARY)"

# Self-contained arm64 .deb (bundled font, no external dependencies).
deb:
	@echo "=> Building deb $(VERSION)..."
	VERSION=$(VERSION) packaging/build-deb.sh arm64

clean:
	rm -f $(BINARY) oled-linux-*
	rm -rf dist

test:
	go vet ./...

help:
	@echo "make          - build arm64 binary ./$(BINARY)"
	@echo "make deb      - build dist/easepi-oled-daemon_<version>_arm64.deb (VERSION=$(VERSION))"
	@echo "make test     - run go vet"
	@echo "make clean    - remove binary and dist/"
