package filter

import (
	"testing"

	"github.com/claude-orchestrator/proxy/internal/cache"
	"github.com/claude-orchestrator/proxy/internal/config"
)

func TestContainerFilter_ProjectOnly(t *testing.T) {
	policy := &config.Policy{
		ProjectName: "myapp",
		Containers: config.ContainerPolicy{
			Policy:     "project_only",
			NamePrefix: "cc-myapp-",
			RequiredLabels: map[string]string{
				"cco.project": "myapp",
			},
		},
	}
	f := NewContainerFilter(policy)

	tests := []struct {
		name    string
		info    *cache.ContainerInfo
		allowed bool
	}{
		{
			name:    "matching prefix",
			info:    &cache.ContainerInfo{Name: "cc-myapp-postgres"},
			allowed: true,
		},
		{
			name:    "matching label",
			info:    &cache.ContainerInfo{Name: "custom-name", Labels: map[string]string{"cco.project": "myapp"}},
			allowed: true,
		},
		{
			name:    "wrong prefix",
			info:    &cache.ContainerInfo{Name: "cc-other-postgres"},
			allowed: false,
		},
		{
			name:    "no match",
			info:    &cache.ContainerInfo{Name: "random-container"},
			allowed: false,
		},
		{
			name:    "nil info",
			info:    nil,
			allowed: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := f.IsAllowed(tt.info); got != tt.allowed {
				t.Errorf("IsAllowed() = %v, want %v", got, tt.allowed)
			}
		})
	}
}

func TestContainerFilter_Allowlist(t *testing.T) {
	policy := &config.Policy{
		ProjectName: "myapp",
		Containers: config.ContainerPolicy{
			Policy:        "allowlist",
			AllowPatterns: []string{"cc-myapp-*", "redis-dev"},
		},
	}
	f := NewContainerFilter(policy)

	tests := []struct {
		name    string
		cName   string
		allowed bool
	}{
		{"matching glob", "cc-myapp-postgres", true},
		{"exact match", "redis-dev", true},
		{"no match", "cc-other-postgres", false},
		{"partial match", "redis-dev-2", false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := f.IsNameAllowed(tt.cName); got != tt.allowed {
				t.Errorf("IsNameAllowed(%q) = %v, want %v", tt.cName, got, tt.allowed)
			}
		})
	}
}

func TestContainerFilter_Denylist(t *testing.T) {
	policy := &config.Policy{
		ProjectName: "myapp",
		Containers: config.ContainerPolicy{
			Policy:       "denylist",
			DenyPatterns: []string{"cc-production-*", "vault-*"},
		},
	}
	f := NewContainerFilter(policy)

	tests := []struct {
		name    string
		cName   string
		allowed bool
	}{
		{"not denied", "cc-myapp-postgres", true},
		{"denied by glob", "cc-production-web", false},
		{"denied by glob 2", "vault-server", false},
		{"random allowed", "anything", true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := f.IsNameAllowed(tt.cName); got != tt.allowed {
				t.Errorf("IsNameAllowed(%q) = %v, want %v", tt.cName, got, tt.allowed)
			}
		})
	}
}

func TestContainerFilter_Unrestricted(t *testing.T) {
	policy := &config.Policy{
		ProjectName: "myapp",
		Containers:  config.ContainerPolicy{Policy: "unrestricted"},
	}
	f := NewContainerFilter(policy)

	if !f.IsNameAllowed("anything-goes") {
		t.Error("unrestricted should allow anything")
	}
}

func TestContainerFilter_ValidateCreateName(t *testing.T) {
	policy := &config.Policy{
		ProjectName: "myapp",
		Containers: config.ContainerPolicy{
			Policy:        "project_only",
			CreateAllowed: true,
			NamePrefix:    "cc-myapp-",
		},
	}
	f := NewContainerFilter(policy)

	// Valid name
	if _, err := f.ValidateCreateName("cc-myapp-postgres"); err != nil {
		t.Errorf("expected valid name, got error: %v", err)
	}

	// Invalid name
	if _, err := f.ValidateCreateName("postgres"); err == nil {
		t.Error("expected error for name without prefix")
	}

	// Empty name
	if _, err := f.ValidateCreateName(""); err == nil {
		t.Error("expected error for empty name")
	}

	// Create disabled
	policy.Containers.CreateAllowed = false
	f2 := NewContainerFilter(policy)
	if _, err := f2.ValidateCreateName("cc-myapp-anything"); err == nil {
		t.Error("expected error when creation is disabled")
	}
}
