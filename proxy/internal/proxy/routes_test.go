package proxy

import "testing"

func TestExtractContainerID(t *testing.T) {
	tests := []struct {
		path string
		want string
	}{
		{"/containers/abc123/start", "abc123"},
		{"/v1.44/containers/abc123/start", "abc123"},
		{"/v1.44/containers/abc123/json", "abc123"},
		{"/v1.44/containers/abc123", "abc123"},
		{"/containers/my-container/logs", "my-container"},
		{"/v1.44/containers/create", "create"}, // handled separately
	}

	for _, tt := range tests {
		t.Run(tt.path, func(t *testing.T) {
			got := extractContainerID(tt.path)
			if got != tt.want {
				t.Errorf("extractContainerID(%q) = %q, want %q", tt.path, got, tt.want)
			}
		})
	}
}

func TestIsAlwaysAllowed(t *testing.T) {
	tests := []struct {
		path    string
		allowed bool
	}{
		{"/_ping", true},
		{"/v1.44/_ping", true},
		{"/version", true},
		{"/v1.44/version", true},
		{"/info", true},
		{"/containers/json", false},
	}

	for _, tt := range tests {
		t.Run(tt.path, func(t *testing.T) {
			if got := isAlwaysAllowed(tt.path); got != tt.allowed {
				t.Errorf("isAlwaysAllowed(%q) = %v, want %v", tt.path, got, tt.allowed)
			}
		})
	}
}

func TestRouteMatching(t *testing.T) {
	tests := []struct {
		name   string
		method string
		path   string
		check  func(string, string) bool
		want   bool
	}{
		{"create container", "POST", "/v1.44/containers/create", isContainerCreate, true},
		{"list containers", "GET", "/v1.44/containers/json", isContainerList, true},
		{"start container", "POST", "/v1.44/containers/abc123/start", isContainerOp, true},
		{"delete container", "DELETE", "/v1.44/containers/abc123", isContainerDelete, true},
		{"create network", "POST", "/v1.44/networks/create", isNetworkCreate, true},
		{"connect network", "POST", "/v1.44/networks/abc123/connect", isNetworkConnect, true},
		{"list networks", "GET", "/v1.44/networks", isNetworkList, true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := tt.check(tt.method, tt.path); got != tt.want {
				t.Errorf("%s: check(%q, %q) = %v, want %v", tt.name, tt.method, tt.path, got, tt.want)
			}
		})
	}
}

func TestIsImageOp(t *testing.T) {
	if !isImageOp("/v1.44/images/json") {
		t.Error("expected /images/json to be image op")
	}
	if !isImageOp("/v1.44/build") {
		t.Error("expected /build to be image op")
	}
	if isImageOp("/v1.44/containers/json") {
		t.Error("expected /containers/json to NOT be image op")
	}
}
