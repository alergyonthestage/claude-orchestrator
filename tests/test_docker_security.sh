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
    run_cco start "test-proj" --dry-run --dump
    extract_dry_run_dir
    assert_file_exists "$DRY_RUN_DIR/.cco/managed/policy.json"
}

test_policy_json_not_generated_when_socket_disabled() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    run_cco start "test-proj" --dry-run --dump
    extract_dry_run_dir
    assert_file_not_exists "$DRY_RUN_DIR/.cco/managed/policy.json"
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
    run_cco start "myapp" --dry-run --dump
    extract_dry_run_dir
    local policy="$DRY_RUN_DIR/.cco/managed/policy.json"
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
    run_cco start "test-proj" --dry-run --dump
    extract_dry_run_dir
    local policy="$DRY_RUN_DIR/.cco/managed/policy.json"

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
    run_cco start "test-proj" --dry-run --dump
    extract_dry_run_dir
    local policy="$DRY_RUN_DIR/.cco/managed/policy.json"

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
    run_cco start "test-proj" --dry-run --dump
    extract_dry_run_dir
    local policy="$DRY_RUN_DIR/.cco/managed/policy.json"

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
    run_cco start "test-proj" --dry-run --dump
    extract_dry_run_dir
    local policy="$DRY_RUN_DIR/.cco/managed/policy.json"

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
    run_cco start "test-proj" --dry-run --dump
    extract_dry_run_dir
    local policy="$DRY_RUN_DIR/.cco/managed/policy.json"

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
    run_cco start "test-proj" --dry-run --dump
    extract_dry_run_dir
    local policy="$DRY_RUN_DIR/.cco/managed/policy.json"

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
    run_cco start "test-proj" --dry-run --dump
    extract_dry_run_dir
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"

    assert_file_contains "$compose" "policy.json:/etc/cco/policy.json:ro"
}

test_compose_policy_not_mounted_when_socket_disabled() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    run_cco start "test-proj" --dry-run --dump
    extract_dry_run_dir
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"

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
    run_cco start "myapp" --dry-run --dump
    extract_dry_run_dir
    local policy="$DRY_RUN_DIR/.cco/managed/policy.json"

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
    run_cco start "myapp" --dry-run --dump
    extract_dry_run_dir
    local policy="$DRY_RUN_DIR/.cco/managed/policy.json"

    local prefix
    prefix=$(jq -r '.networks.allowed_prefixes[0]' "$policy")
    assert_equals "custom-net" "$prefix" "custom network prefix"
}

# ── Container denylist policy ─────────────────────────────────────────

test_policy_container_denylist() {
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
    policy: denylist
    deny:
      - "prod-*"
      - "staging-db"
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
YAML
)"
    run_cco start "test-proj" --dry-run --dump
    extract_dry_run_dir
    local policy="$DRY_RUN_DIR/.cco/managed/policy.json"

    local ct_policy
    ct_policy=$(jq -r '.containers.policy' "$policy")
    assert_equals "denylist" "$ct_policy" "containers.policy"

    local deny_count
    deny_count=$(jq '.containers.deny_patterns | length' "$policy")
    assert_equals "2" "$deny_count" "deny_patterns count"
}

# ── Fractional CPU values ─────────────────────────────────────────────

test_policy_fractional_cpus() {
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
    resources:
      cpus: "0.5"
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
YAML
)"
    run_cco start "test-proj" --dry-run --dump
    extract_dry_run_dir
    local policy="$DRY_RUN_DIR/.cco/managed/policy.json"

    local nano_cpus
    nano_cpus=$(jq -r '.security.max_nano_cpus' "$policy")
    assert_equals "500000000" "$nano_cpus" "max_nano_cpus (0.5 CPUs)"
}

# ── Force readonly mount policy ───────────────────────────────────────

test_policy_mount_force_readonly() {
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
    force_readonly: true
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
YAML
)"
    run_cco start "test-proj" --dry-run --dump
    extract_dry_run_dir
    local policy="$DRY_RUN_DIR/.cco/managed/policy.json"

    local force_ro
    force_ro=$(jq -r '.mounts.force_readonly' "$policy")
    assert_equals "true" "$force_ro" "mounts.force_readonly"
}

# ── Custom name prefix override ──────────────────────────────────────

test_policy_custom_name_prefix() {
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
    name_prefix: "custom-prefix-"
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
YAML
)"
    run_cco start "test-proj" --dry-run --dump
    extract_dry_run_dir
    local policy="$DRY_RUN_DIR/.cco/managed/policy.json"

    local prefix
    prefix=$(jq -r '.containers.name_prefix' "$policy")
    assert_equals "custom-prefix-" "$prefix" "custom name_prefix"
}

# ── Multiple repos produce multiple allowed_paths ─────────────────────

test_policy_multiple_repos_allowed_paths() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local repo1="$tmpdir/repo-one"
    local repo2="$tmpdir/repo-two"
    mkdir -p "$repo1" "$repo2"
    create_project "$tmpdir" "test-proj" "$(cat <<YAML
name: test-proj
auth:
  method: oauth
docker:
  mount_socket: true
  ports: []
  env: {}
repos:
  - path: $repo1
    name: repo-one
  - path: $repo2
    name: repo-two
YAML
)"
    run_cco start "test-proj" --dry-run --dump
    extract_dry_run_dir
    local policy="$DRY_RUN_DIR/.cco/managed/policy.json"

    local path_count
    path_count=$(jq '.mounts.allowed_paths | length' "$policy")
    assert_equals "2" "$path_count" "allowed_paths count for 2 repos"
}

# ── DOCKER_HOST in compose when socket enabled ────────────────────────

test_compose_docker_host_when_socket_enabled() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(socket_project_yml test-proj)"
    run_cco start "test-proj" --dry-run --dump
    extract_dry_run_dir
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"

    assert_file_contains "$compose" "DOCKER_HOST=unix:///var/run/docker-proxy.sock"
}

test_compose_no_docker_host_when_socket_disabled() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    run_cco start "test-proj" --dry-run --dump
    extract_dry_run_dir
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"

    assert_file_not_contains "$compose" "DOCKER_HOST"
}

# ── Policy field: all 4 container policies ─────────────────────────────

test_policy_container_unrestricted() {
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
    policy: unrestricted
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
YAML
)"
    run_cco start "test-proj" --dry-run --dump
    extract_dry_run_dir
    local policy="$DRY_RUN_DIR/.cco/managed/policy.json"

    local ct_policy
    ct_policy=$(jq -r '.containers.policy' "$policy")
    assert_equals "unrestricted" "$ct_policy" "containers.policy unrestricted"
}

test_policy_container_project_only_explicit() {
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
    policy: project_only
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
YAML
)"
    run_cco start "test-proj" --dry-run --dump
    extract_dry_run_dir
    local policy="$DRY_RUN_DIR/.cco/managed/policy.json"

    local ct_policy
    ct_policy=$(jq -r '.containers.policy' "$policy")
    assert_equals "project_only" "$ct_policy" "containers.policy project_only (explicit)"
}

# ── Mount policy: all 4 values ──────────────────────────────────────────

test_policy_mount_project_only_explicit() {
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
    policy: project_only
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
YAML
)"
    run_cco start "test-proj" --dry-run --dump
    extract_dry_run_dir
    local policy="$DRY_RUN_DIR/.cco/managed/policy.json"

    local mt_policy
    mt_policy=$(jq -r '.mounts.policy' "$policy")
    assert_equals "project_only" "$mt_policy" "mounts.policy project_only (explicit)"
}

test_policy_mount_allowlist() {
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
    policy: allowlist
    allow:
      - "/opt/data"
      - "/tmp/builds"
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
YAML
)"
    run_cco start "test-proj" --dry-run --dump
    extract_dry_run_dir
    local policy="$DRY_RUN_DIR/.cco/managed/policy.json"

    local mt_policy
    mt_policy=$(jq -r '.mounts.policy' "$policy")
    assert_equals "allowlist" "$mt_policy" "mounts.policy allowlist"

    local allow_count
    allow_count=$(jq '.mounts.allowed_paths | length' "$policy")
    assert_equals "2" "$allow_count" "allowlist allowed_paths count"

    local first_path
    first_path=$(jq -r '.mounts.allowed_paths[0]' "$policy")
    assert_equals "/opt/data" "$first_path" "allowlist allowed_paths[0]"
}

test_policy_mount_any_explicit() {
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
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
YAML
)"
    run_cco start "test-proj" --dry-run --dump
    extract_dry_run_dir
    local policy="$DRY_RUN_DIR/.cco/managed/policy.json"

    local mt_policy
    mt_policy=$(jq -r '.mounts.policy' "$policy")
    assert_equals "any" "$mt_policy" "mounts.policy any"
}

# ── Multiple repos → multiple allowed_paths with path verification ─────

test_policy_multiple_repos_paths_content() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local repo1="$tmpdir/alpha-repo"
    local repo2="$tmpdir/beta-repo"
    local repo3="$tmpdir/gamma-repo"
    mkdir -p "$repo1" "$repo2" "$repo3"
    create_project "$tmpdir" "test-proj" "$(cat <<YAML
name: test-proj
auth:
  method: oauth
docker:
  mount_socket: true
  ports: []
  env: {}
repos:
  - path: $repo1
    name: alpha-repo
  - path: $repo2
    name: beta-repo
  - path: $repo3
    name: gamma-repo
YAML
)"
    run_cco start "test-proj" --dry-run --dump
    extract_dry_run_dir
    local policy="$DRY_RUN_DIR/.cco/managed/policy.json"

    local path_count
    path_count=$(jq '.mounts.allowed_paths | length' "$policy")
    assert_equals "3" "$path_count" "allowed_paths count for 3 repos"

    # Verify each repo path is present
    assert_file_contains "$policy" "$repo1"
    assert_file_contains "$policy" "$repo2"
    assert_file_contains "$policy" "$repo3"
}

# ── Default values when docker.security section is missing ──────────────

test_policy_defaults_no_security_section() {
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
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
YAML
)"
    run_cco start "test-proj" --dry-run --dump
    extract_dry_run_dir
    local policy="$DRY_RUN_DIR/.cco/managed/policy.json"

    # Verify all security defaults
    local no_priv
    no_priv=$(jq -r '.security.no_privileged' "$policy")
    assert_equals "true" "$no_priv" "default no_privileged"

    local no_sens
    no_sens=$(jq -r '.security.no_sensitive_mounts' "$policy")
    assert_equals "true" "$no_sens" "default no_sensitive_mounts"

    local force_nonroot
    force_nonroot=$(jq -r '.security.force_non_root' "$policy")
    assert_equals "false" "$force_nonroot" "default force_non_root"

    # Default drop_capabilities: SYS_ADMIN, NET_ADMIN
    local cap_count
    cap_count=$(jq '.security.drop_capabilities | length' "$policy")
    assert_equals "2" "$cap_count" "default drop_capabilities count"

    # Default memory: 4g = 4294967296
    local mem
    mem=$(jq -r '.security.max_memory_bytes' "$policy")
    assert_equals "4294967296" "$mem" "default max_memory_bytes (4g)"

    # Default CPUs: 4 = 4000000000
    local cpus
    cpus=$(jq -r '.security.max_nano_cpus' "$policy")
    assert_equals "4000000000" "$cpus" "default max_nano_cpus (4 CPUs)"

    # Default max_containers: 10
    local max_ct
    max_ct=$(jq -r '.security.max_containers' "$policy")
    assert_equals "10" "$max_ct" "default max_containers"
}

# ── Default container and mount policies ────────────────────────────────

test_policy_defaults_no_containers_section() {
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
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
YAML
)"
    run_cco start "test-proj" --dry-run --dump
    extract_dry_run_dir
    local policy="$DRY_RUN_DIR/.cco/managed/policy.json"

    # Default container policy
    local ct_policy
    ct_policy=$(jq -r '.containers.policy' "$policy")
    assert_equals "project_only" "$ct_policy" "default containers.policy"

    # Default create_allowed
    local ct_create
    ct_create=$(jq -r '.containers.create_allowed' "$policy")
    assert_equals "true" "$ct_create" "default create_allowed"

    # Default name_prefix derived from project name
    local prefix
    prefix=$(jq -r '.containers.name_prefix' "$policy")
    assert_equals "cc-test-proj-" "$prefix" "default name_prefix"

    # Default mount policy
    local mt_policy
    mt_policy=$(jq -r '.mounts.policy' "$policy")
    assert_equals "project_only" "$mt_policy" "default mounts.policy"

    # Default force_readonly
    local force_ro
    force_ro=$(jq -r '.mounts.force_readonly' "$policy")
    assert_equals "false" "$force_ro" "default force_readonly"
}

# ── Edge case: mount_socket false → no policy.json ──────────────────────

test_policy_not_generated_mount_socket_false_explicit() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(cat <<YAML
name: test-proj
auth:
  method: oauth
docker:
  mount_socket: false
  ports: []
  env: {}
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
YAML
)"
    run_cco start "test-proj" --dry-run --dump
    extract_dry_run_dir
    assert_file_not_exists "$DRY_RUN_DIR/.cco/managed/policy.json"
}

# ── Edge case: empty allow/deny lists ───────────────────────────────────

test_policy_empty_allow_list() {
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
    allow: []
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
YAML
)"
    run_cco start "test-proj" --dry-run --dump
    extract_dry_run_dir
    local policy="$DRY_RUN_DIR/.cco/managed/policy.json"

    local ct_policy
    ct_policy=$(jq -r '.containers.policy' "$policy")
    assert_equals "allowlist" "$ct_policy" "containers.policy with empty allow"

    local allow_count
    allow_count=$(jq '.containers.allow_patterns | length' "$policy")
    assert_equals "0" "$allow_count" "empty allow_patterns produces empty array"
}

test_policy_empty_deny_list() {
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
    policy: denylist
    deny: []
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
YAML
)"
    run_cco start "test-proj" --dry-run --dump
    extract_dry_run_dir
    local policy="$DRY_RUN_DIR/.cco/managed/policy.json"

    local ct_policy
    ct_policy=$(jq -r '.containers.policy' "$policy")
    assert_equals "denylist" "$ct_policy" "containers.policy with empty deny"

    local deny_count
    deny_count=$(jq '.containers.deny_patterns | length' "$policy")
    assert_equals "0" "$deny_count" "empty deny_patterns produces empty array"
}

test_policy_empty_mount_deny_list() {
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
    deny: []
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
YAML
)"
    run_cco start "test-proj" --dry-run --dump
    extract_dry_run_dir
    local policy="$DRY_RUN_DIR/.cco/managed/policy.json"

    local deny_count
    deny_count=$(jq '.mounts.denied_paths | length' "$policy")
    assert_equals "0" "$deny_count" "empty mount denied_paths produces empty array"
}

# ── Security defaults: all expected values ──────────────────────────────

test_policy_security_defaults_complete() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(socket_project_yml test-proj)"
    run_cco start "test-proj" --dry-run --dump
    extract_dry_run_dir
    local policy="$DRY_RUN_DIR/.cco/managed/policy.json"

    # no_privileged defaults to true
    local no_priv
    no_priv=$(jq -r '.security.no_privileged' "$policy")
    assert_equals "true" "$no_priv" "security.no_privileged default"

    # no_sensitive_mounts defaults to true
    local no_sens
    no_sens=$(jq -r '.security.no_sensitive_mounts' "$policy")
    assert_equals "true" "$no_sens" "security.no_sensitive_mounts default"

    # force_non_root defaults to false
    local force_nonroot
    force_nonroot=$(jq -r '.security.force_non_root' "$policy")
    assert_equals "false" "$force_nonroot" "security.force_non_root default"

    # Default drop_capabilities includes SYS_ADMIN and NET_ADMIN
    local cap0 cap1
    cap0=$(jq -r '.security.drop_capabilities[0]' "$policy")
    cap1=$(jq -r '.security.drop_capabilities[1]' "$policy")
    assert_equals "SYS_ADMIN" "$cap0" "default drop_capabilities[0]"
    assert_equals "NET_ADMIN" "$cap1" "default drop_capabilities[1]"
}

# ── Resource limit: memory in megabytes ─────────────────────────────────

test_policy_memory_megabytes() {
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
    resources:
      memory: "512m"
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
YAML
)"
    run_cco start "test-proj" --dry-run --dump
    extract_dry_run_dir
    local policy="$DRY_RUN_DIR/.cco/managed/policy.json"

    local mem
    mem=$(jq -r '.security.max_memory_bytes' "$policy")
    assert_equals "536870912" "$mem" "max_memory_bytes (512m)"
}

# ── Resource limit: raw bytes (numeric) ─────────────────────────────────

test_policy_memory_raw_bytes() {
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
    resources:
      memory: "1073741824"
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
YAML
)"
    run_cco start "test-proj" --dry-run --dump
    extract_dry_run_dir
    local policy="$DRY_RUN_DIR/.cco/managed/policy.json"

    local mem
    mem=$(jq -r '.security.max_memory_bytes' "$policy")
    assert_equals "1073741824" "$mem" "max_memory_bytes (raw bytes)"
}

# ── Resource limit: integer CPUs ────────────────────────────────────────

test_policy_integer_cpus() {
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
    resources:
      cpus: "8"
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
YAML
)"
    run_cco start "test-proj" --dry-run --dump
    extract_dry_run_dir
    local policy="$DRY_RUN_DIR/.cco/managed/policy.json"

    local nano_cpus
    nano_cpus=$(jq -r '.security.max_nano_cpus' "$policy")
    assert_equals "8000000000" "$nano_cpus" "max_nano_cpus (8 CPUs)"
}

# ── Policy JSON is valid JSON ───────────────────────────────────────────

test_policy_json_valid_json() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(socket_project_yml test-proj)"
    run_cco start "test-proj" --dry-run --dump
    extract_dry_run_dir
    local policy="$DRY_RUN_DIR/.cco/managed/policy.json"

    # jq will fail on invalid JSON
    if ! jq . "$policy" >/dev/null 2>&1; then
        echo "ASSERTION FAILED: policy.json is not valid JSON"
        cat "$policy"
        return 1
    fi
}

# ── Implicit deny always contains critical paths ────────────────────────

test_policy_implicit_deny_all_critical_paths() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(socket_project_yml test-proj)"
    run_cco start "test-proj" --dry-run --dump
    extract_dry_run_dir
    local policy="$DRY_RUN_DIR/.cco/managed/policy.json"

    local deny_count
    deny_count=$(jq '.mounts.implicit_deny | length' "$policy")
    assert_equals "3" "$deny_count" "implicit_deny has 3 entries"

    # Verify all three critical paths
    local deny0 deny1 deny2
    deny0=$(jq -r '.mounts.implicit_deny[0]' "$policy")
    deny1=$(jq -r '.mounts.implicit_deny[1]' "$policy")
    deny2=$(jq -r '.mounts.implicit_deny[2]' "$policy")
    assert_equals "/var/run/docker.sock" "$deny0" "implicit_deny[0]"
    assert_equals "/etc/shadow" "$deny1" "implicit_deny[1]"
    assert_equals "/etc/sudoers" "$deny2" "implicit_deny[2]"
}

# ── Project name is set in policy ───────────────────────────────────────

test_policy_project_name_set() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "my-special-proj" "$(cat <<YAML
name: my-special-proj
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
    run_cco start "my-special-proj" --dry-run --dump
    extract_dry_run_dir
    local policy="$DRY_RUN_DIR/.cco/managed/policy.json"

    local pname
    pname=$(jq -r '.project_name' "$policy")
    assert_equals "my-special-proj" "$pname" "project_name in policy.json"
}
