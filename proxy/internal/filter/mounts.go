package filter

import (
	"path/filepath"
	"strings"

	"github.com/claude-orchestrator/proxy/internal/config"
)

// MountFilter validates bind mounts against policy.
type MountFilter struct {
	policy *config.Policy
}

// NewMountFilter creates a filter for mount validation.
func NewMountFilter(policy *config.Policy) *MountFilter {
	return &MountFilter{policy: policy}
}

// TranslatePath rewrites a container-local path to its host equivalent using
// the path_map from policy.  In Docker-from-Docker, bind-mount paths reference
// the HOST filesystem, but shell expansion inside the container produces
// container-local paths (e.g. ~ → /home/claude).  The path_map lets the proxy
// translate them transparently so both validation and the forwarded request
// use the correct host path.  Returns the original path unchanged if no
// mapping matches.
func (f *MountFilter) TranslatePath(p string) string {
	if len(f.policy.Mounts.PathMap) == 0 {
		return p
	}
	clean := filepath.Clean(p)
	// Longest-prefix match: try each mapping; keep the one with the longest
	// matching prefix so that /workspace/repo wins over /workspace.
	bestPrefix := ""
	bestHost := ""
	for containerPrefix, hostPath := range f.policy.Mounts.PathMap {
		cp := filepath.Clean(containerPrefix)
		if clean == cp || strings.HasPrefix(clean, cp+"/") {
			if len(cp) > len(bestPrefix) {
				bestPrefix = cp
				bestHost = hostPath
			}
		}
	}
	if bestPrefix == "" {
		return p
	}
	// Replace the container prefix with the host path
	if clean == bestPrefix {
		return bestHost
	}
	return filepath.Join(bestHost, clean[len(bestPrefix):])
}

// TranslateBind rewrites the source part of a bind string (host:container[:ro])
// using TranslatePath.  Returns the rewritten bind string.
func (f *MountFilter) TranslateBind(bind string) string {
	parts := strings.SplitN(bind, ":", 3)
	translated := f.TranslatePath(parts[0])
	if translated == parts[0] {
		return bind
	}
	parts[0] = translated
	return strings.Join(parts, ":")
}

// ValidateBind checks if a bind mount string (host:container[:ro]) is allowed.
// Docker accepts both "source:target" and bare "source" formats.
// The source path is translated via path_map before validation.
func (f *MountFilter) ValidateBind(bind string) error {
	parts := strings.SplitN(bind, ":", 3)
	hostPath := f.TranslatePath(parts[0])
	if hostPath == "" {
		return nil // empty string, skip
	}
	return f.validatePath(hostPath)
}

// ValidateMount checks if a mount source path is allowed.
// The source path is translated via path_map before validation.
func (f *MountFilter) ValidateMount(source string, mountType string) error {
	// Only validate bind mounts, not volumes or tmpfs
	if mountType != "bind" && mountType != "" {
		return nil
	}
	return f.validatePath(f.TranslatePath(source))
}

func (f *MountFilter) validatePath(hostPath string) error {
	// Step 1: check implicit deny list (always enforced)
	for _, denied := range f.policy.Mounts.ImplicitDeny {
		if pathMatchesDeny(hostPath, denied) {
			return &DeniedError{
				Reason: "mount path is in the implicit deny list: " + hostPath,
			}
		}
	}

	// Step 2: check explicit deny list
	for _, denied := range f.policy.Mounts.DeniedPaths {
		if pathMatchesDeny(hostPath, denied) {
			return &DeniedError{
				Reason: "mount path is denied by policy: " + hostPath,
			}
		}
	}

	// Step 3: check policy
	switch f.policy.Mounts.Policy {
	case "none":
		return &DeniedError{
			Reason: "no host mounts allowed by policy",
		}

	case "project_only":
		for _, allowed := range f.policy.Mounts.AllowedPaths {
			if pathIsUnderOrEqual(hostPath, allowed) {
				return nil
			}
		}
		return &DeniedError{
			Reason: "mount path not in project paths: " + hostPath,
		}

	case "allowlist":
		for _, allowed := range f.policy.Mounts.AllowedPaths {
			if pathIsUnderOrEqual(hostPath, allowed) {
				return nil
			}
		}
		return &DeniedError{
			Reason: "mount path not in allowlist: " + hostPath,
		}

	case "any":
		return nil

	default:
		return &DeniedError{Reason: "unknown mount policy: " + f.policy.Mounts.Policy}
	}
}

// ShouldForceReadonly returns true if the policy requires read-only mounts.
func (f *MountFilter) ShouldForceReadonly() bool {
	return f.policy.Mounts.ForceReadonly
}

// pathMatchesDeny checks if a host path matches a deny pattern.
// Supports exact match, glob patterns, and prefix matching.
func pathMatchesDeny(hostPath, pattern string) bool {
	// Exact match
	if hostPath == pattern {
		return true
	}

	// Glob match (e.g., *.pem, *.key)
	if strings.Contains(pattern, "*") {
		base := filepath.Base(hostPath)
		if matched, _ := filepath.Match(pattern, base); matched {
			return true
		}
		if matched, _ := filepath.Match(pattern, hostPath); matched {
			return true
		}
	}

	// Path is under the denied directory (e.g., ~/.ssh/ denies ~/.ssh/id_rsa)
	if strings.HasSuffix(pattern, "/") {
		return strings.HasPrefix(hostPath, pattern)
	}

	// Also check without trailing slash
	return strings.HasPrefix(hostPath+"/", pattern+"/")
}

// pathIsUnderOrEqual checks if hostPath is equal to or a subdirectory of allowed.
func pathIsUnderOrEqual(hostPath, allowed string) bool {
	// Clean paths for comparison
	hostPath = filepath.Clean(hostPath)
	allowed = filepath.Clean(allowed)

	if hostPath == allowed {
		return true
	}

	return strings.HasPrefix(hostPath, allowed+"/")
}
