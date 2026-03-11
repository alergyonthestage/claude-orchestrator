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
