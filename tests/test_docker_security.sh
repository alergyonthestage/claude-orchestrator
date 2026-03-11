#!/usr/bin/env bash
# Tests for Docker socket restriction (Sprint 6-Security Phase B)
# Validates: policy.json generation, compose integration, YAML parsing

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# ── Helper: project.yml with socket enabled ──────────────────────────

socket_project_yml() {
    local name="${1:-test-proj}"
    cat <<YAML
name: $name
description: "Test project with socket"
auth:
  method: oauth
docker:
  mount_socket: true
  ports: []
  env: {}
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
YAML
}

# ── Policy generation defaults ────────────────────────────────────────

test_policy_json_generated_when_socket_enabled() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(socket_project_yml test-proj)"
    run_cco start "test-proj" --dry-run
    assert_file_exists "$CCO_PROJECTS_DIR/test-proj/.managed/policy.json"
}

test_policy_json_not_generated_when_socket_disabled() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    run_cco start "test-proj" --dry-run
    assert_file_not_exists "$CCO_PROJECTS_DIR/test-proj/.managed/policy.json"
}

test_policy_defaults_project_only() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "myapp" "$(cat <<YAML
name: myapp
auth:
  method: oauth
docker:
  mount_socket: true
  ports: []
  env: {}
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
YAML
)"
    run_cco start "myapp" --dry-run
    local policy="$CCO_PROJECTS_DIR/myapp/.managed/policy.json"
    assert_file_exists "$policy"

    # Default container policy is project_only
    local ct_policy
    ct_policy=$(jq -r '.containers.policy' "$policy")
    assert_equals "project_only" "$ct_policy" "containers.policy default"

    # Default name prefix
    local ct_prefix
    ct_prefix=$(jq -r '.containers.name_prefix' "$policy")
    assert_equals "cc-myapp-" "$ct_prefix" "containers.name_prefix default"

    # Default mount policy is project_only
    local mt_policy
    mt_policy=$(jq -r '.mounts.policy' "$policy")
    assert_equals "project_only" "$mt_policy" "mounts.policy default"

    # Default security: no_privileged true
    local no_priv
    no_priv=$(jq -r '.security.no_privileged' "$policy")
    assert_equals "true" "$no_priv" "security.no_privileged default"

    # Required labels include project name
    local label_val
    label_val=$(jq -r '.containers.required_labels["cco.project"]' "$policy")
    assert_equals "myapp" "$label_val" "required_labels cco.project"
}

test_policy_mount_project_only_includes_repo_paths() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local fake_repo="$tmpdir/my-repo"
    mkdir -p "$fake_repo"
    create_project "$tmpdir" "test-proj" "$(cat <<YAML
name: test-proj
auth:
  method: oauth
docker:
  mount_socket: true
  ports: []
  env: {}
repos:
  - path: $fake_repo
    name: my-repo
YAML
)"
    run_cco start "test-proj" --dry-run
    local policy="$CCO_PROJECTS_DIR/test-proj/.managed/policy.json"

    # Allowed paths should include the repo path
    local path_count
    path_count=$(jq '.mounts.allowed_paths | length' "$policy")
    assert_equals "1" "$path_count" "allowed_paths count"

    local first_path
    first_path=$(jq -r '.mounts.allowed_paths[0]' "$policy")
    assert_equals "$fake_repo" "$first_path" "allowed_paths[0]"
}

test_policy_implicit_deny_always_present() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(socket_project_yml test-proj)"
    run_cco start "test-proj" --dry-run
    local policy="$CCO_PROJECTS_DIR/test-proj/.managed/policy.json"

    # Implicit deny should always include docker.sock
    assert_file_contains "$policy" "/var/run/docker.sock"
    assert_file_contains "$policy" "/etc/shadow"
}

# ── Custom container policy ──────────────────────────────────────────

test_policy_container_allowlist() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(cat <<YAML
name: test-proj
auth:
  method: oauth
docker:
  mount_socket: true
  ports: []
  env: {}
  containers:
    policy: allowlist
    allow:
      - "cc-test-*"
      - "redis-dev"
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
YAML
)"
    run_cco start "test-proj" --dry-run
    local policy="$CCO_PROJECTS_DIR/test-proj/.managed/policy.json"

    local ct_policy
    ct_policy=$(jq -r '.containers.policy' "$policy")
    assert_equals "allowlist" "$ct_policy" "containers.policy"

    local allow_count
    allow_count=$(jq '.containers.allow_patterns | length' "$policy")
    assert_equals "2" "$allow_count" "allow_patterns count"
}

# ── Custom mount policy ──────────────────────────────────────────────

test_policy_mount_none() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(cat <<YAML
name: test-proj
auth:
  method: oauth
docker:
  mount_socket: true
  ports: []
  env: {}
  mounts:
    policy: none
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
YAML
)"
    run_cco start "test-proj" --dry-run
    local policy="$CCO_PROJECTS_DIR/test-proj/.managed/policy.json"

    local mt_policy
    mt_policy=$(jq -r '.mounts.policy' "$policy")
    assert_equals "none" "$mt_policy" "mounts.policy"
}

test_policy_mount_explicit_deny() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(cat <<YAML
name: test-proj
auth:
  method: oauth
docker:
  mount_socket: true
  ports: []
  env: {}
  mounts:
    policy: any
    deny:
      - "/secrets"
      - "/home/user/.ssh"
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
YAML
)"
    run_cco start "test-proj" --dry-run
    local policy="$CCO_PROJECTS_DIR/test-proj/.managed/policy.json"

    local deny_count
    deny_count=$(jq '.mounts.denied_paths | length' "$policy")
    assert_equals "2" "$deny_count" "denied_paths count"
}

# ── Security constraints ─────────────────────────────────────────────

test_policy_security_custom_caps() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(cat <<YAML
name: test-proj
auth:
  method: oauth
docker:
  mount_socket: true
  ports: []
  env: {}
  security:
    no_privileged: true
    force_non_root: true
    drop_capabilities:
      - SYS_ADMIN
      - NET_RAW
      - SYS_PTRACE
    resources:
      memory: "2g"
      cpus: "2"
      max_containers: 5
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
YAML
)"
    run_cco start "test-proj" --dry-run
    local policy="$CCO_PROJECTS_DIR/test-proj/.managed/policy.json"

    local force_nonroot
    force_nonroot=$(jq -r '.security.force_non_root' "$policy")
    assert_equals "true" "$force_nonroot" "force_non_root"

    local cap_count
    cap_count=$(jq '.security.drop_capabilities | length' "$policy")
    assert_equals "3" "$cap_count" "drop_capabilities count"

    local max_mem
    max_mem=$(jq -r '.security.max_memory_bytes' "$policy")
    assert_equals "2147483648" "$max_mem" "max_memory_bytes (2g)"

    local max_ct
    max_ct=$(jq -r '.security.max_containers' "$policy")
    assert_equals "5" "$max_ct" "max_containers"
}

# ── Compose integration ──────────────────────────────────────────────

test_compose_policy_mounted_when_socket_enabled() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(socket_project_yml test-proj)"
    run_cco start "test-proj" --dry-run
    local compose="$CCO_PROJECTS_DIR/test-proj/docker-compose.yml"

    assert_file_contains "$compose" "policy.json:/etc/cco/policy.json:ro"
}

test_compose_policy_not_mounted_when_socket_disabled() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    run_cco start "test-proj" --dry-run
    local compose="$CCO_PROJECTS_DIR/test-proj/docker-compose.yml"

    assert_file_not_contains "$compose" "policy.json"
}

# ── Network prefixes ─────────────────────────────────────────────────

test_policy_network_prefixes_default() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "myapp" "$(cat <<YAML
name: myapp
auth:
  method: oauth
docker:
  mount_socket: true
  ports: []
  env: {}
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
YAML
)"
    run_cco start "myapp" --dry-run
    local policy="$CCO_PROJECTS_DIR/myapp/.managed/policy.json"

    local prefix
    prefix=$(jq -r '.networks.allowed_prefixes[0]' "$policy")
    assert_equals "cc-myapp" "$prefix" "network prefix"
}

test_policy_network_prefixes_custom() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "myapp" "$(cat <<YAML
name: myapp
auth:
  method: oauth
docker:
  mount_socket: true
  network: custom-net
  ports: []
  env: {}
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
YAML
)"
    run_cco start "myapp" --dry-run
    local policy="$CCO_PROJECTS_DIR/myapp/.managed/policy.json"

    local prefix
    prefix=$(jq -r '.networks.allowed_prefixes[0]' "$policy")
    assert_equals "custom-net" "$prefix" "custom network prefix"
}
