#!/usr/bin/env bash
# tests/test_project_list.sh — tests for 'cco project list'
# Requires: helpers.sh, mocks.sh (sourced by bin/test)

# ── Project listing ───────────────────────────────────────────────────

test_project_list_shows_project_names() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    local mock_bin="$tmpdir/bin"
    _mock_docker_no_containers "$mock_bin"
    setup_mocks "$mock_bin"
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "alpha" "$(minimal_project_yml alpha)"
    create_project "$tmpdir" "beta"  "$(minimal_project_yml beta)"
    run_cco project list
    assert_output_contains "alpha"
    assert_output_contains "beta"
}

test_project_list_skips_template_dir() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    local mock_bin="$tmpdir/bin"
    _mock_docker_no_containers "$mock_bin"
    setup_mocks "$mock_bin"
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    mkdir -p "$CCO_PROJECTS_DIR/_template"
    create_project "$tmpdir" "real-proj" "$(minimal_project_yml real-proj)"
    run_cco project list
    assert_output_contains "real-proj"
    if echo "${CCO_OUTPUT:-}" | grep -qF "_template"; then
        echo "ASSERTION FAILED: _template should not appear in project list"
        return 1
    fi
}

test_project_list_shows_repo_count() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    local mock_bin="$tmpdir/bin"
    _mock_docker_no_containers "$mock_bin"
    setup_mocks "$mock_bin"
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "multi-repo" "$(cat <<YAML
name: multi-repo
description: "Test"
auth:
  method: oauth
docker:
  ports: []
  env: {}
repos:
  - path: /some/repo-a
    name: repo-a
  - path: /some/repo-b
    name: repo-b
YAML
)"
    run_cco project list
    # Output line should show repo count of 2
    assert_output_contains "2"
}

test_project_list_empty_repos_shows_zero() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    local mock_bin="$tmpdir/bin"
    _mock_docker_no_containers "$mock_bin"
    setup_mocks "$mock_bin"
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "no-repos" "$(minimal_project_yml no-repos)"
    run_cco project list
    assert_output_contains "0"
}

test_project_list_stopped_status() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    local mock_bin="$tmpdir/bin"
    _mock_docker_no_containers "$mock_bin"
    setup_mocks "$mock_bin"
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "my-proj" "$(minimal_project_yml my-proj)"
    run_cco project list
    assert_output_contains "stopped"
}

test_project_list_running_status() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    local mock_bin="$tmpdir/bin"
    _mock_docker_with_containers "$mock_bin" "cc-my-proj"
    setup_mocks "$mock_bin"
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "my-proj" "$(minimal_project_yml my-proj)"
    run_cco project list
    assert_output_contains "running"
}

test_project_list_header_always_present() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    local mock_bin="$tmpdir/bin"
    _mock_docker_no_containers "$mock_bin"
    setup_mocks "$mock_bin"
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    # No projects — header should still appear
    run_cco project list
    assert_output_contains "NAME"
}
