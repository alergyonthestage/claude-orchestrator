.PHONY: build build-linux test clean

BINARY := cco-docker-proxy

# Default: build for current platform
build:
	go build -ldflags="-s -w" -o $(BINARY) ./cmd/cco-docker-proxy/

# Cross-compile for Linux (Docker image target)
build-linux:
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o $(BINARY)-linux-amd64 ./cmd/cco-docker-proxy/
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags="-s -w" -o $(BINARY)-linux-arm64 ./cmd/cco-docker-proxy/

test:
	go test ./...

clean:
	rm -f $(BINARY) $(BINARY)-linux-*
