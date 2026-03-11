package filter

import (
	"testing"

	"github.com/claude-orchestrator/proxy/internal/config"
)

func TestSecurityFilter_Privileged(t *testing.T) {
	policy := &config.Policy{
		ProjectName: "myapp",
		Security:    config.SecurityPolicy{NoPrivileged: true},
	}
	f := NewSecurityFilter(policy)

	if err := f.ValidatePrivileged(true); err == nil {
		t.Error("expected error for privileged=true")
	}
	if err := f.ValidatePrivileged(false); err != nil {
		t.Errorf("expected no error for privileged=false, got: %v", err)
	}

	// With policy disabled
	policy.Security.NoPrivileged = false
	f2 := NewSecurityFilter(policy)
	if err := f2.ValidatePrivileged(true); err != nil {
		t.Errorf("expected no error when policy allows privileged, got: %v", err)
	}
}

func TestSecurityFilter_User(t *testing.T) {
	policy := &config.Policy{
		ProjectName: "myapp",
		Security:    config.SecurityPolicy{ForceNonRoot: true},
	}
	f := NewSecurityFilter(policy)

	tests := []struct {
		user    string
		allowed bool
	}{
		{"", false},
		{"0", false},
		{"root", false},
		{"1000", true},
		{"claude", true},
		{"1000:1000", true},
	}

	for _, tt := range tests {
		t.Run(tt.user, func(t *testing.T) {
			err := f.ValidateUser(tt.user)
			if tt.allowed && err != nil {
				t.Errorf("expected allowed for user %q, got: %v", tt.user, err)
			}
			if !tt.allowed && err == nil {
				t.Errorf("expected denied for user %q", tt.user)
			}
		})
	}
}

func TestSecurityFilter_Capabilities(t *testing.T) {
	policy := &config.Policy{
		ProjectName: "myapp",
		Security: config.SecurityPolicy{
			DropCapabilities: []string{"SYS_ADMIN", "NET_ADMIN"},
		},
	}
	f := NewSecurityFilter(policy)

	// Should deny SYS_ADMIN
	if _, err := f.ValidateCapabilities([]string{"SYS_ADMIN"}); err == nil {
		t.Error("expected error for SYS_ADMIN")
	}

	// Should allow NET_RAW (not in drop list)
	if _, err := f.ValidateCapabilities([]string{"NET_RAW"}); err != nil {
		t.Errorf("expected allowed for NET_RAW, got: %v", err)
	}

	// Empty caps should pass
	if _, err := f.ValidateCapabilities(nil); err != nil {
		t.Errorf("expected allowed for nil caps, got: %v", err)
	}

	// Case insensitive
	if _, err := f.ValidateCapabilities([]string{"sys_admin"}); err == nil {
		t.Error("expected error for sys_admin (lowercase)")
	}
}

func TestSecurityFilter_Memory(t *testing.T) {
	policy := &config.Policy{
		ProjectName: "myapp",
		Security:    config.SecurityPolicy{MaxMemoryBytes: 4 * 1024 * 1024 * 1024}, // 4GB
	}
	f := NewSecurityFilter(policy)

	// Within limit
	if err := f.ValidateMemory(2 * 1024 * 1024 * 1024); err != nil {
		t.Errorf("expected allowed, got: %v", err)
	}

	// Over limit
	if err := f.ValidateMemory(8 * 1024 * 1024 * 1024); err == nil {
		t.Error("expected error for memory over limit")
	}

	// Zero (no limit set by container)
	if err := f.ValidateMemory(0); err != nil {
		t.Errorf("expected allowed for 0 memory, got: %v", err)
	}
}

func TestSecurityFilter_CPU(t *testing.T) {
	policy := &config.Policy{
		ProjectName: "myapp",
		Security:    config.SecurityPolicy{MaxNanoCPUs: 4000000000}, // 4 CPUs
	}
	f := NewSecurityFilter(policy)

	// Within limit
	if err := f.ValidateCPU(2000000000); err != nil {
		t.Errorf("expected allowed for 2 CPUs, got: %v", err)
	}

	// Fractional within limit (0.5 CPU)
	if err := f.ValidateCPU(500000000); err != nil {
		t.Errorf("expected allowed for 0.5 CPU, got: %v", err)
	}

	// Over limit (8 CPUs)
	if err := f.ValidateCPU(8000000000); err == nil {
		t.Error("expected error for CPU over limit")
	}

	// Zero (no limit set by container) should pass
	if err := f.ValidateCPU(0); err != nil {
		t.Errorf("expected allowed for 0 nanoCPUs, got: %v", err)
	}

	// Zero policy (no limit enforced) should pass any value
	policy2 := &config.Policy{
		ProjectName: "myapp",
		Security:    config.SecurityPolicy{MaxNanoCPUs: 0},
	}
	f2 := NewSecurityFilter(policy2)
	if err := f2.ValidateCPU(99000000000); err != nil {
		t.Errorf("expected allowed when policy has no CPU limit, got: %v", err)
	}
}

func TestSecurityFilter_SensitiveMounts(t *testing.T) {
	policy := &config.Policy{
		ProjectName: "myapp",
		Security:    config.SecurityPolicy{NoSensitiveMounts: true},
	}
	f := NewSecurityFilter(policy)

	// /proc mount
	if err := f.ValidateSensitiveMounts([]string{"/proc:/host/proc"}); err == nil {
		t.Error("expected error for /proc mount")
	}

	// /sys mount
	if err := f.ValidateSensitiveMounts([]string{"/sys:/host/sys"}); err == nil {
		t.Error("expected error for /sys mount")
	}

	// Normal mount
	if err := f.ValidateSensitiveMounts([]string{"/home/user:/app"}); err != nil {
		t.Errorf("expected allowed, got: %v", err)
	}
}
