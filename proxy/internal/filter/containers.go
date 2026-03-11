// Package filter implements Docker API request filtering based on policy.
package filter

import (
	"path/filepath"
	"strings"

	"github.com/claude-orchestrator/proxy/internal/cache"
	"github.com/claude-orchestrator/proxy/internal/config"
)

// ContainerFilter checks whether a container is accessible based on policy.
type ContainerFilter struct {
	policy *config.Policy
}

// NewContainerFilter creates a filter for container access checks.
func NewContainerFilter(policy *config.Policy) *ContainerFilter {
	return &ContainerFilter{policy: policy}
}

// IsAllowed checks if a container (by name and labels) is accessible.
func (f *ContainerFilter) IsAllowed(info *cache.ContainerInfo) bool {
	if info == nil {
		return false
	}
	return f.IsNameAllowed(info.Name) || f.AreLabelsAllowed(info.Labels)
}

// IsNameAllowed checks if a container name passes the policy filter.
func (f *ContainerFilter) IsNameAllowed(name string) bool {
	p := f.policy.Containers

	switch p.Policy {
	case "unrestricted":
		return true

	case "project_only":
		if p.NamePrefix != "" && strings.HasPrefix(name, p.NamePrefix) {
			return true
		}
		return false

	case "allowlist":
		for _, pattern := range p.AllowPatterns {
			if matchGlob(pattern, name) {
				return true
			}
		}
		return false

	case "denylist":
		for _, pattern := range p.DenyPatterns {
			if matchGlob(pattern, name) {
				return false
			}
		}
		return true

	default:
		return false
	}
}

// AreLabelsAllowed checks if container labels match the policy.
// All required labels must be present (AND logic).
func (f *ContainerFilter) AreLabelsAllowed(labels map[string]string) bool {
	p := f.policy.Containers

	if p.Policy == "unrestricted" {
		return true
	}

	if p.Policy == "project_only" {
		// All required labels must match
		if len(p.RequiredLabels) == 0 {
			return false
		}
		for k, v := range p.RequiredLabels {
			if labels[k] != v {
				return false
			}
		}
		return true
	}

	return false
}

// ValidateCreateName checks if a container name is valid for creation.
func (f *ContainerFilter) ValidateCreateName(name string) (string, error) {
	p := f.policy.Containers

	if !p.CreateAllowed {
		return "", &DeniedError{Reason: "container creation is disabled by policy"}
	}

	if p.Policy == "unrestricted" {
		return name, nil
	}

	// Enforce name prefix
	if p.NamePrefix != "" && !strings.HasPrefix(name, p.NamePrefix) {
		if name == "" {
			// Docker auto-generates a name; we force the prefix
			return "", &DeniedError{
				Reason: "container name is required — must start with " + p.NamePrefix,
			}
		}
		return "", &DeniedError{
			Reason: "container name must start with " + p.NamePrefix + ", got: " + name,
		}
	}

	return name, nil
}

// RequiredLabels returns the labels that must be injected on container creation.
func (f *ContainerFilter) RequiredLabels() map[string]string {
	return f.policy.Containers.RequiredLabels
}

// matchGlob checks if name matches a glob pattern (supports * wildcard).
func matchGlob(pattern, name string) bool {
	matched, _ := filepath.Match(pattern, name)
	if matched {
		return true
	}
	// Also try prefix match for patterns ending in *
	if strings.HasSuffix(pattern, "*") {
		prefix := strings.TrimSuffix(pattern, "*")
		return strings.HasPrefix(name, prefix)
	}
	return false
}
