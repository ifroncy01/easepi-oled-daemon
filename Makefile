BINARY := oled
MAIN := main.go
GOARCH ?= arm64
GOOS ?= linux
CGO := 0
LDFLAGS := -s -w
GOPROXY ?= https://goproxy.cn,direct

.PHONY: all build arm64 amd64 clean test

all: build

build:
	@echo "=> Building $(BINARY) for $(GOOS)/$(GOARCH)..."
	CGO_ENABLED=$(CGO) GOARCH=$(GOARCH) GOOS=$(GOOS) GOPROXY=$(GOPROXY) \
		go build -ldflags="$(LDFLAGS)" -o $(BINARY) $(MAIN)
	@echo "=> Built: $(BINARY)"

arm64:
	$(MAKE) build GOARCH=arm64
	@mv $(BINARY) $(BINARY)-linux-arm64

amd64:
	$(MAKE) build GOARCH=amd64
	@mv $(BINARY) $(BINARY)-linux-amd64

clean:
	rm -f $(BINARY) $(BINARY)-linux-*

test:
	go vet ./...