package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoad_ValidPolicy(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "policy.json")
	data := []byte(`{
		"project_name": "myapp",
		"containers": {"policy": "project_only"},
		"mounts": {"policy": "project_only"},
		"security": {},
		"networks": {}
	}`)
	if err := os.WriteFile(path, data, 0644); err != nil {
		t.Fatal(err)
	}

	p, err := Load(path)
	if err != nil {
		t.Fatalf("expected no error, got: %v", err)
	}
	if p.ProjectName != "myapp" {
		t.Errorf("expected project_name=myapp, got %q", p.ProjectName)
	}
	if p.Containers.Policy != "project_only" {
		t.Errorf("expected containers.policy=project_only, got %q", p.Containers.Policy)
	}
}

func TestLoad_MalformedJSON(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "policy.json")
	if err := os.WriteFile(path, []byte(`{invalid json`), 0644); err != nil {
		t.Fatal(err)
	}

	_, err := Load(path)
	if err == nil {
		t.Error("expected error for malformed JSON")
	}
}

func TestLoad_FileNotFound(t *testing.T) {
	_, err := Load("/nonexistent/policy.json")
	if err == nil {
		t.Error("expected error for missing file")
	}
}

func TestLoad_EmptyFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "policy.json")
	if err := os.WriteFile(path, []byte(""), 0644); err != nil {
		t.Fatal(err)
	}

	_, err := Load(path)
	if err == nil {
		t.Error("expected error for empty file")
	}
}

func TestLoad_MissingProjectName(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "policy.json")
	data := []byte(`{
		"containers": {"policy": "project_only"},
		"mounts": {"policy": "project_only"}
	}`)
	if err := os.WriteFile(path, data, 0644); err != nil {
		t.Fatal(err)
	}

	_, err := Load(path)
	if err == nil {
		t.Error("expected error for missing project_name")
	}
}

func TestLoad_InvalidContainerPolicy(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "policy.json")
	data := []byte(`{
		"project_name": "myapp",
		"containers": {"policy": "invalid_value"},
		"mounts": {"policy": "project_only"}
	}`)
	if err := os.WriteFile(path, data, 0644); err != nil {
		t.Fatal(err)
	}

	_, err := Load(path)
	if err == nil {
		t.Error("expected error for invalid container policy")
	}
}

func TestLoad_InvalidMountPolicy(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "policy.json")
	data := []byte(`{
		"project_name": "myapp",
		"containers": {"policy": "project_only"},
		"mounts": {"policy": "restricted"}
	}`)
	if err := os.WriteFile(path, data, 0644); err != nil {
		t.Fatal(err)
	}

	_, err := Load(path)
	if err == nil {
		t.Error("expected error for invalid mount policy")
	}
}

func TestLoad_AllValidContainerPolicies(t *testing.T) {
	policies := []string{"project_only", "allowlist", "denylist", "unrestricted"}
	for _, pol := range policies {
		t.Run(pol, func(t *testing.T) {
			dir := t.TempDir()
			path := filepath.Join(dir, "policy.json")
			data := []byte(`{
				"project_name": "myapp",
				"containers": {"policy": "` + pol + `"},
				"mounts": {"policy": "project_only"}
			}`)
			if err := os.WriteFile(path, data, 0644); err != nil {
				t.Fatal(err)
			}
			p, err := Load(path)
			if err != nil {
				t.Fatalf("expected valid policy %q, got error: %v", pol, err)
			}
			if p.Containers.Policy != pol {
				t.Errorf("expected %q, got %q", pol, p.Containers.Policy)
			}
		})
	}
}

func TestLoad_AllValidMountPolicies(t *testing.T) {
	policies := []string{"none", "project_only", "allowlist", "any"}
	for _, pol := range policies {
		t.Run(pol, func(t *testing.T) {
			dir := t.TempDir()
			path := filepath.Join(dir, "policy.json")
			data := []byte(`{
				"project_name": "myapp",
				"containers": {"policy": "project_only"},
				"mounts": {"policy": "` + pol + `"}
			}`)
			if err := os.WriteFile(path, data, 0644); err != nil {
				t.Fatal(err)
			}
			p, err := Load(path)
			if err != nil {
				t.Fatalf("expected valid policy %q, got error: %v", pol, err)
			}
			if p.Mounts.Policy != pol {
				t.Errorf("expected %q, got %q", pol, p.Mounts.Policy)
			}
		})
	}
}

func TestAllDeniedMountPaths(t *testing.T) {
	p := &Policy{
		Mounts: MountPolicy{
			ImplicitDeny: []string{"/var/run/docker.sock", "/etc/shadow"},
			DeniedPaths:  []string{"/secrets"},
		},
	}
	combined := p.AllDeniedMountPaths()
	if len(combined) != 3 {
		t.Fatalf("expected 3, got %d", len(combined))
	}
	// Implicit deny comes first
	if combined[0] != "/var/run/docker.sock" {
		t.Errorf("expected implicit deny first, got %q", combined[0])
	}
	if combined[2] != "/secrets" {
		t.Errorf("expected explicit deny last, got %q", combined[2])
	}
}

func TestAllDeniedMountPaths_Empty(t *testing.T) {
	p := &Policy{}
	combined := p.AllDeniedMountPaths()
	if len(combined) != 0 {
		t.Errorf("expected empty, got %d", len(combined))
	}
}

func TestLoad_FullPolicy_AllFields(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "policy.json")
	data := []byte(`{
		"project_name": "myapp",
		"containers": {
			"policy": "allowlist",
			"allow_patterns": ["cc-myapp-*"],
			"deny_patterns": [],
			"create_allowed": true,
			"name_prefix": "cc-myapp-",
			"required_labels": {"cco.project": "myapp"}
		},
		"mounts": {
			"policy": "project_only",
			"allowed_paths": ["/home/user/code"],
			"denied_paths": ["/secrets"],
			"implicit_deny": ["/var/run/docker.sock"],
			"force_readonly": true
		},
		"security": {
			"no_privileged": true,
			"no_sensitive_mounts": true,
			"force_non_root": false,
			"drop_capabilities": ["SYS_ADMIN"],
			"max_memory_bytes": 4294967296,
			"max_nano_cpus": 4000000000,
			"max_containers": 10
		},
		"networks": {
			"allowed_prefixes": ["cc-myapp"]
		}
	}`)
	if err := os.WriteFile(path, data, 0644); err != nil {
		t.Fatal(err)
	}

	p, err := Load(path)
	if err != nil {
		t.Fatalf("expected no error, got: %v", err)
	}

	// Verify deserialization of all fields
	if !p.Containers.CreateAllowed {
		t.Error("expected create_allowed=true")
	}
	if p.Containers.NamePrefix != "cc-myapp-" {
		t.Errorf("expected name_prefix=cc-myapp-, got %q", p.Containers.NamePrefix)
	}
	if len(p.Containers.AllowPatterns) != 1 {
		t.Errorf("expected 1 allow_pattern, got %d", len(p.Containers.AllowPatterns))
	}
	if p.Containers.RequiredLabels["cco.project"] != "myapp" {
		t.Error("expected required_labels[cco.project]=myapp")
	}
	if !p.Mounts.ForceReadonly {
		t.Error("expected force_readonly=true")
	}
	if len(p.Mounts.AllowedPaths) != 1 {
		t.Errorf("expected 1 allowed_path, got %d", len(p.Mounts.AllowedPaths))
	}
	if p.Security.MaxMemoryBytes != 4294967296 {
		t.Errorf("expected max_memory_bytes=4294967296, got %d", p.Security.MaxMemoryBytes)
	}
	if p.Security.MaxContainers != 10 {
		t.Errorf("expected max_containers=10, got %d", p.Security.MaxContainers)
	}
	if len(p.Networks.AllowedPrefixes) != 1 {
		t.Errorf("expected 1 allowed_prefix, got %d", len(p.Networks.AllowedPrefixes))
	}
}
