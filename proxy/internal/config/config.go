// Package config handles policy.json parsing for the Docker socket proxy.
package config

import (
	"encoding/json"
	"fmt"
	"os"
)

// Policy represents the full proxy policy loaded from policy.json.
type Policy struct {
	ProjectName string           `json:"project_name"`
	Containers  ContainerPolicy  `json:"containers"`
	Mounts      MountPolicy      `json:"mounts"`
	Security    SecurityPolicy   `json:"security"`
	Networks    NetworkPolicy    `json:"networks"`
}

// ContainerPolicy controls which containers Claude can access and create.
type ContainerPolicy struct {
	Policy         string            `json:"policy"`          // project_only, allowlist, denylist, unrestricted
	AllowPatterns  []string          `json:"allow_patterns"`
	DenyPatterns   []string          `json:"deny_patterns"`
	CreateAllowed  bool              `json:"create_allowed"`
	NamePrefix     string            `json:"name_prefix"`
	RequiredLabels map[string]string `json:"required_labels"`
}

// MountPolicy controls which host paths can be mounted in created containers.
type MountPolicy struct {
	Policy       string   `json:"policy"`        // none, project_only, allowlist, any
	AllowedPaths []string `json:"allowed_paths"`
	DeniedPaths  []string `json:"denied_paths"`
	ImplicitDeny []string `json:"implicit_deny"`
	ForceReadonly bool    `json:"force_readonly"`
}

// SecurityPolicy controls security constraints on created containers.
type SecurityPolicy struct {
	NoPrivileged      bool     `json:"no_privileged"`
	NoSensitiveMounts bool     `json:"no_sensitive_mounts"`
	ForceNonRoot      bool     `json:"force_non_root"`
	DropCapabilities  []string `json:"drop_capabilities"`
	MaxMemoryBytes    int64    `json:"max_memory_bytes"`
	MaxNanoCPUs       int64    `json:"max_nano_cpus"`
	MaxContainers     int      `json:"max_containers"`
}

// NetworkPolicy controls which networks containers can join.
type NetworkPolicy struct {
	AllowedPrefixes []string `json:"allowed_prefixes"`
}

// Load reads and parses a policy.json file.
func Load(path string) (*Policy, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read policy file: %w", err)
	}

	var p Policy
	if err := json.Unmarshal(data, &p); err != nil {
		return nil, fmt.Errorf("parse policy JSON: %w", err)
	}

	if err := p.validate(); err != nil {
		return nil, fmt.Errorf("invalid policy: %w", err)
	}

	return &p, nil
}

func (p *Policy) validate() error {
	switch p.Containers.Policy {
	case "project_only", "allowlist", "denylist", "unrestricted":
	default:
		return fmt.Errorf("containers.policy: invalid value %q", p.Containers.Policy)
	}

	switch p.Mounts.Policy {
	case "none", "project_only", "allowlist", "any":
	default:
		return fmt.Errorf("mounts.policy: invalid value %q", p.Mounts.Policy)
	}

	if p.ProjectName == "" {
		return fmt.Errorf("project_name is required")
	}

	return nil
}

// AllDeniedMountPaths returns the combined list of explicit and implicit denied paths.
func (p *Policy) AllDeniedMountPaths() []string {
	combined := make([]string, 0, len(p.Mounts.DeniedPaths)+len(p.Mounts.ImplicitDeny))
	combined = append(combined, p.Mounts.ImplicitDeny...)
	combined = append(combined, p.Mounts.DeniedPaths...)
	return combined
}
