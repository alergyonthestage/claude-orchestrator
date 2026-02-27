#!/usr/bin/env bash
# tests/test_project_show.sh — cco project show and validate command tests
#
# Verifies project show and validate commands.

# ── show ──────────────────────────────────────────────────────────────

test_project_show_displays_name() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "my-proj" "$(cat <<YAML
name: my-proj
description: "A test project"
repos: []
YAML
)"
    run_cco project show "my-proj"
    assert_output_contains "my-proj"
}

test_project_show_lists_repos() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local repo_dir="$tmpdir/my-repo"
    mkdir -p "$repo_dir"
    create_project "$tmpdir" "my-proj" "$(cat <<YAML
name: my-proj
repos:
  - path: $repo_dir
    name: my-repo
YAML
)"
    run_cco project show "my-proj"
    assert_output_contains "my-repo"
}

test_project_show_lists_packs() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_pack "$tmpdir" "test-pack" "$(cat <<YAML
name: test-pack
YAML
)"
    create_project "$tmpdir" "my-proj" "$(cat <<YAML
name: my-proj
repos: []
packs:
  - test-pack
YAML
)"
    run_cco project show "my-proj"
    assert_output_contains "test-pack"
}

test_project_show_docker_config() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "my-proj" "$(cat <<YAML
name: my-proj
auth:
  method: api_key
docker:
  ports:
    - "3000:3000"
  env: {}
repos: []
YAML
)"
    run_cco project show "my-proj"
    assert_output_contains "api_key"
    assert_output_contains "3000:3000"
}

test_project_show_fails_if_not_found() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    if run_cco project show "nonexistent" 2>/dev/null; then
        echo "ASSERTION FAILED: should have failed for missing project"
        return 1
    fi
}

# ── validate ──────────────────────────────────────────────────────────

test_project_validate_ok_for_valid_project() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "my-proj" "$(cat <<YAML
name: my-proj
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
YAML
)"
    run_cco project validate "my-proj"
    assert_output_contains "valid"
}

test_project_validate_error_without_project_yml() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    mkdir -p "$CCO_PROJECTS_DIR/broken-proj"
    if run_cco project validate "broken-proj" 2>/dev/null; then
        echo "ASSERTION FAILED: should fail without project.yml"
        return 1
    fi
}

test_project_validate_error_for_missing_repo_path() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "my-proj" "$(cat <<YAML
name: my-proj
repos:
  - path: /nonexistent/repo
    name: ghost-repo
YAML
)"
    if run_cco project validate "my-proj" 2>/dev/null; then
        echo "ASSERTION FAILED: should fail for missing repo path"
        return 1
    fi
}

test_project_validate_error_for_missing_pack() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "my-proj" "$(cat <<YAML
name: my-proj
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
packs:
  - nonexistent-pack
YAML
)"
    if run_cco project validate "my-proj" 2>/dev/null; then
        echo "ASSERTION FAILED: should fail for missing pack"
        return 1
    fi
}

test_project_validate_warns_no_repos() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "my-proj" "$(cat <<YAML
name: my-proj
repos: []
YAML
)"
    run_cco project validate "my-proj"
    assert_output_contains "no repos"
}
