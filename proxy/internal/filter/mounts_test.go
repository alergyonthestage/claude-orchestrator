package filter

import (
	"testing"

	"github.com/claude-orchestrator/proxy/internal/config"
)

func TestMountFilter_None(t *testing.T) {
	policy := &config.Policy{
		ProjectName: "myapp",
		Mounts: config.MountPolicy{
			Policy: "none",
		},
	}
	f := NewMountFilter(policy)

	if err := f.ValidateBind("/home/user/code:/app"); err == nil {
		t.Error("expected error for policy 'none'")
	}
}

func TestMountFilter_ProjectOnly(t *testing.T) {
	policy := &config.Policy{
		ProjectName: "myapp",
		Mounts: config.MountPolicy{
			Policy:       "project_only",
			AllowedPaths: []string{"/home/user/projects/backend", "/home/user/projects/frontend"},
		},
	}
	f := NewMountFilter(policy)

	tests := []struct {
		name    string
		bind    string
		allowed bool
	}{
		{"allowed path", "/home/user/projects/backend:/app", true},
		{"subdir of allowed", "/home/user/projects/backend/src:/app/src", true},
		{"other allowed", "/home/user/projects/frontend:/web", true},
		{"not allowed", "/home/user/secrets:/secrets", false},
		{"root mount", "/:/mnt", false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := f.ValidateBind(tt.bind)
			if tt.allowed && err != nil {
				t.Errorf("expected allowed, got error: %v", err)
			}
			if !tt.allowed && err == nil {
				t.Errorf("expected denied, got allowed")
			}
		})
	}
}

func TestMountFilter_ImplicitDeny(t *testing.T) {
	policy := &config.Policy{
		ProjectName: "myapp",
		Mounts: config.MountPolicy{
			Policy: "any",
			ImplicitDeny: []string{
				"/var/run/docker.sock",
				"/etc/shadow",
			},
		},
	}
	f := NewMountFilter(policy)

	tests := []struct {
		name    string
		bind    string
		allowed bool
	}{
		{"docker socket blocked", "/var/run/docker.sock:/var/run/docker.sock", false},
		{"shadow blocked", "/etc/shadow:/etc/shadow", false},
		{"other allowed", "/home/user/data:/data", true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := f.ValidateBind(tt.bind)
			if tt.allowed && err != nil {
				t.Errorf("expected allowed, got error: %v", err)
			}
			if !tt.allowed && err == nil {
				t.Errorf("expected denied, got allowed")
			}
		})
	}
}

func TestMountFilter_ExplicitDeny(t *testing.T) {
	policy := &config.Policy{
		ProjectName: "myapp",
		Mounts: config.MountPolicy{
			Policy:      "any",
			DeniedPaths: []string{"/secrets", "*.pem"},
		},
	}
	f := NewMountFilter(policy)

	tests := []struct {
		name    string
		bind    string
		allowed bool
	}{
		{"denied path", "/secrets:/app/secrets", false},
		{"denied subpath", "/secrets/key:/app/key", false},
		{"pem file", "/home/user/cert.pem:/cert.pem", false},
		{"allowed", "/home/user/code:/app", true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := f.ValidateBind(tt.bind)
			if tt.allowed && err != nil {
				t.Errorf("expected allowed, got error: %v", err)
			}
			if !tt.allowed && err == nil {
				t.Errorf("expected denied, got allowed")
			}
		})
	}
}

func TestMountFilter_Allowlist(t *testing.T) {
	policy := &config.Policy{
		ProjectName: "myapp",
		Mounts: config.MountPolicy{
			Policy:       "allowlist",
			AllowedPaths: []string{"/opt/data", "/tmp/builds"},
		},
	}
	f := NewMountFilter(policy)

	tests := []struct {
		name    string
		bind    string
		allowed bool
	}{
		{"allowed path", "/opt/data:/data", true},
		{"subdir of allowed", "/opt/data/subdir:/data/sub", true},
		{"other allowed", "/tmp/builds:/builds", true},
		{"not in allowlist", "/home/user/code:/app", false},
		{"root mount", "/:/mnt", false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := f.ValidateBind(tt.bind)
			if tt.allowed && err != nil {
				t.Errorf("expected allowed, got error: %v", err)
			}
			if !tt.allowed && err == nil {
				t.Errorf("expected denied, got allowed")
			}
		})
	}
}

func TestMountFilter_ForceReadonly(t *testing.T) {
	policy := &config.Policy{
		ProjectName: "myapp",
		Mounts: config.MountPolicy{
			Policy:        "any",
			ForceReadonly: true,
		},
	}
	f := NewMountFilter(policy)

	if !f.ShouldForceReadonly() {
		t.Error("expected ShouldForceReadonly() = true")
	}

	// When not set, should be false
	policy2 := &config.Policy{
		ProjectName: "myapp",
		Mounts: config.MountPolicy{
			Policy: "any",
		},
	}
	f2 := NewMountFilter(policy2)
	if f2.ShouldForceReadonly() {
		t.Error("expected ShouldForceReadonly() = false when not configured")
	}
}

func TestMountFilter_ValidateMount(t *testing.T) {
	policy := &config.Policy{
		ProjectName: "myapp",
		Mounts: config.MountPolicy{
			Policy:       "project_only",
			AllowedPaths: []string{"/home/user/code"},
		},
	}
	f := NewMountFilter(policy)

	// Bind mount: validated
	if err := f.ValidateMount("/home/user/code", "bind"); err != nil {
		t.Errorf("expected allowed bind mount, got: %v", err)
	}

	// Volume mount: skipped (not a bind mount)
	if err := f.ValidateMount("myvolume", "volume"); err != nil {
		t.Errorf("expected volume to be skipped, got: %v", err)
	}

	// tmpfs mount: skipped
	if err := f.ValidateMount("", "tmpfs"); err != nil {
		t.Errorf("expected tmpfs to be skipped, got: %v", err)
	}

	// Denied bind mount
	if err := f.ValidateMount("/etc/secrets", "bind"); err == nil {
		t.Error("expected denied for path not in allowed list")
	}
}

func TestMountFilter_ImplicitDenyOverridesAllowlist(t *testing.T) {
	// Even if a path is in allowed_paths, implicit_deny takes precedence
	policy := &config.Policy{
		ProjectName: "myapp",
		Mounts: config.MountPolicy{
			Policy:       "allowlist",
			AllowedPaths: []string{"/var/run"},
			ImplicitDeny: []string{"/var/run/docker.sock"},
		},
	}
	f := NewMountFilter(policy)

	// Subdir is allowed
	if err := f.ValidateBind("/var/run/myapp.sock:/myapp.sock"); err != nil {
		t.Errorf("expected allowed, got: %v", err)
	}

	// Docker socket is blocked by implicit deny even though /var/run is allowed
	if err := f.ValidateBind("/var/run/docker.sock:/docker.sock"); err == nil {
		t.Error("expected docker socket to be blocked by implicit deny")
	}
}

func TestMountFilter_EmptyAllowedPaths(t *testing.T) {
	policy := &config.Policy{
		ProjectName: "myapp",
		Mounts: config.MountPolicy{
			Policy:       "project_only",
			AllowedPaths: []string{},
		},
	}
	f := NewMountFilter(policy)

	// With empty allowed paths, everything should be denied
	if err := f.ValidateBind("/any/path:/app"); err == nil {
		t.Error("expected denied with empty allowed_paths")
	}
}

func TestMountFilter_ValidateBind_NotABind(t *testing.T) {
	policy := &config.Policy{
		ProjectName: "myapp",
		Mounts: config.MountPolicy{
			Policy: "none",
		},
	}
	f := NewMountFilter(policy)

	// A string without ":" is not a bind mount, should pass
	if err := f.ValidateBind("not-a-bind"); err != nil {
		t.Errorf("expected non-bind string to pass, got: %v", err)
	}
}

func TestPathMatchesDeny(t *testing.T) {
	tests := []struct {
		path    string
		pattern string
		matches bool
	}{
		{"/var/run/docker.sock", "/var/run/docker.sock", true},
		{"/etc/shadow", "/etc/shadow", true},
		{"/home/user/.ssh/id_rsa", "/home/user/.ssh/", true},
		{"/home/user/.ssh/id_rsa", "/home/user/.ssh", true},
		{"/home/user/cert.pem", "*.pem", true},
		{"/home/user/data", "/home/user/.ssh", false},
		{"/home/user/data", "*.pem", false},
	}

	for _, tt := range tests {
		t.Run(tt.path+"_"+tt.pattern, func(t *testing.T) {
			if got := pathMatchesDeny(tt.path, tt.pattern); got != tt.matches {
				t.Errorf("pathMatchesDeny(%q, %q) = %v, want %v", tt.path, tt.pattern, got, tt.matches)
			}
		})
	}
}

func TestPathIsUnderOrEqual(t *testing.T) {
	tests := []struct {
		hostPath string
		allowed  string
		result   bool
	}{
		{"/home/user/code", "/home/user/code", true},
		{"/home/user/code/src", "/home/user/code", true},
		{"/home/user/code-extra", "/home/user/code", false},
		{"/home/user", "/home/user/code", false},
		{"/", "/home", false},
		{"/home", "/home", true},
	}

	for _, tt := range tests {
		t.Run(tt.hostPath+"_"+tt.allowed, func(t *testing.T) {
			if got := pathIsUnderOrEqual(tt.hostPath, tt.allowed); got != tt.result {
				t.Errorf("pathIsUnderOrEqual(%q, %q) = %v, want %v", tt.hostPath, tt.allowed, got, tt.result)
			}
		})
	}
}
