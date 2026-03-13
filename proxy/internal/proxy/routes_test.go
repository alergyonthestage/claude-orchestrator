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

func TestIsVolumeOp(t *testing.T) {
	tests := []struct {
		path string
		want bool
	}{
		{"/v1.44/volumes", true},
		{"/v1.44/volumes/create", true},
		{"/volumes/myvolume", true},
		{"/v1.44/containers/json", false},
		{"/v1.44/images/json", false},
	}

	for _, tt := range tests {
		t.Run(tt.path, func(t *testing.T) {
			if got := isVolumeOp(tt.path); got != tt.want {
				t.Errorf("isVolumeOp(%q) = %v, want %v", tt.path, got, tt.want)
			}
		})
	}
}

func TestExtractNetworkID(t *testing.T) {
	tests := []struct {
		path string
		want string
	}{
		{"/v1.44/networks/abc123/connect", "abc123"},
		{"/networks/mynet/connect", "mynet"},
		{"/v1.44/networks/create", ""},             // create has no ID
		{"/v1.44/containers/abc123/start", ""},      // not a network path
	}

	for _, tt := range tests {
		t.Run(tt.path, func(t *testing.T) {
			got := extractNetworkID(tt.path)
			if got != tt.want {
				t.Errorf("extractNetworkID(%q) = %q, want %q", tt.path, got, tt.want)
			}
		})
	}
}

func TestRouteMatching_NegativeCases(t *testing.T) {
	tests := []struct {
		name   string
		method string
		path   string
		check  func(string, string) bool
		want   bool
	}{
		{"GET is not container create", "GET", "/v1.44/containers/create", isContainerCreate, false},
		{"POST is not container list", "POST", "/v1.44/containers/json", isContainerList, false},
		{"GET is not container delete", "GET", "/v1.44/containers/abc123", isContainerDelete, false},
		{"GET is not network create", "GET", "/v1.44/networks/create", isNetworkCreate, false},
		{"DELETE is not network connect", "DELETE", "/v1.44/networks/abc123/connect", isNetworkConnect, false},
		{"POST is not network list", "POST", "/v1.44/networks", isNetworkList, false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := tt.check(tt.method, tt.path); got != tt.want {
				t.Errorf("%s: check(%q, %q) = %v, want %v", tt.name, tt.method, tt.path, got, tt.want)
			}
		})
	}
}

func TestIsAlwaysAllowed_AllPaths(t *testing.T) {
	// Verify all three always-allowed paths both with and without version prefix
	paths := []string{"/_ping", "/version", "/info"}
	for _, p := range paths {
		if !isAlwaysAllowed(p) {
			t.Errorf("expected %q to be always allowed", p)
		}
		versioned := "/v1.44" + p
		if !isAlwaysAllowed(versioned) {
			t.Errorf("expected %q to be always allowed", versioned)
		}
	}

	// Non-allowed paths
	notAllowed := []string{"/containers/json", "/v1.44/networks/create", "/images/json"}
	for _, p := range notAllowed {
		if isAlwaysAllowed(p) {
			t.Errorf("expected %q to NOT be always allowed", p)
		}
	}
}

func TestExtractContainerID_EdgeCases(t *testing.T) {
	tests := []struct {
		path string
		want string
	}{
		// Container with long hash ID
		{"/v1.44/containers/sha256abcdef1234567890/start", "sha256abcdef1234567890"},
		// No version prefix
		{"/containers/mycontainer/logs", "mycontainer"},
		// Container with dots in name
		{"/v1.44/containers/my.container.name/json", "my.container.name"},
		// Empty path segments should not match
		{"/v1.44/containers/", ""},
		// Non-container path
		{"/v1.44/images/json", ""},
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
