package filter

import (
	"fmt"
	"strings"

	"github.com/claude-orchestrator/proxy/internal/config"
)

// SecurityFilter validates container security constraints.
type SecurityFilter struct {
	policy *config.Policy
}

// NewSecurityFilter creates a filter for security constraints.
func NewSecurityFilter(policy *config.Policy) *SecurityFilter {
	return &SecurityFilter{policy: policy}
}

// ValidatePrivileged checks if privileged mode is allowed.
func (f *SecurityFilter) ValidatePrivileged(privileged bool) error {
	if privileged && f.policy.Security.NoPrivileged {
		return &DeniedError{Reason: "privileged containers are blocked by policy"}
	}
	return nil
}

// ValidateUser checks if the container user is allowed.
func (f *SecurityFilter) ValidateUser(user string) error {
	if !f.policy.Security.ForceNonRoot {
		return nil
	}
	if user == "" || user == "0" || user == "root" {
		return &DeniedError{
			Reason: "root user is blocked by policy — set a non-root USER in your Dockerfile",
		}
	}
	return nil
}

// ValidateCapabilities checks and filters Linux capabilities.
// Returns the filtered list of capabilities (with denied ones removed).
func (f *SecurityFilter) ValidateCapabilities(capAdd []string) ([]string, error) {
	if len(f.policy.Security.DropCapabilities) == 0 {
		return capAdd, nil
	}

	dropSet := make(map[string]bool, len(f.policy.Security.DropCapabilities))
	for _, cap := range f.policy.Security.DropCapabilities {
		dropSet[strings.ToUpper(cap)] = true
	}

	var denied []string
	var allowed []string
	for _, cap := range capAdd {
		if dropSet[strings.ToUpper(cap)] {
			denied = append(denied, cap)
		} else {
			allowed = append(allowed, cap)
		}
	}

	if len(denied) > 0 {
		return nil, &DeniedError{
			Reason: fmt.Sprintf("capabilities blocked by policy: %s", strings.Join(denied, ", ")),
		}
	}

	return allowed, nil
}

// ValidateMemory checks if the memory limit is within policy bounds.
func (f *SecurityFilter) ValidateMemory(memoryBytes int64) error {
	max := f.policy.Security.MaxMemoryBytes
	if max <= 0 || memoryBytes <= 0 {
		return nil
	}
	if memoryBytes > max {
		return &DeniedError{
			Reason: fmt.Sprintf("memory limit %d exceeds policy max %d bytes", memoryBytes, max),
		}
	}
	return nil
}

// ValidateCPU checks if the CPU limit is within policy bounds.
func (f *SecurityFilter) ValidateCPU(nanoCPUs int64) error {
	max := f.policy.Security.MaxNanoCPUs
	if max <= 0 || nanoCPUs <= 0 {
		return nil
	}
	if nanoCPUs > max {
		return &DeniedError{
			Reason: fmt.Sprintf("CPU limit %d exceeds policy max %d nanoCPUs", nanoCPUs, max),
		}
	}
	return nil
}

// ValidateSensitiveMounts checks for /proc and /sys bind mounts.
func (f *SecurityFilter) ValidateSensitiveMounts(binds []string) error {
	if !f.policy.Security.NoSensitiveMounts {
		return nil
	}

	for _, bind := range binds {
		parts := strings.SplitN(bind, ":", 3)
		if len(parts) < 2 {
			continue
		}
		src := parts[0]
		if strings.HasPrefix(src, "/proc") || strings.HasPrefix(src, "/sys") {
			return &DeniedError{
				Reason: "mounting /proc or /sys is blocked by policy",
			}
		}
	}
	return nil
}

// MaxContainers returns the max container limit from policy.
func (f *SecurityFilter) MaxContainers() int {
	return f.policy.Security.MaxContainers
}
