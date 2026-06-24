#!/usr/bin/env bash
# tests/test_stop.sh — tests for 'cco stop'
# Requires: helpers.sh, mocks.sh (sourced by bin/test)

# ── Stop named project ────────────────────────────────────────────────

test_stop_named_running_project_stops_container() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    local mock_bin="$tmpdir/bin"
    _mock_docker_with_containers "$mock_bin" "cc-my-proj"
    setup_mocks "$mock_bin"
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "my-proj" "$(minimal_project_yml my-proj)"
    export DOCKER_CALL_LOG="$tmpdir/docker.log"
    run_cco stop "my-proj"
    assert_file_contains "$DOCKER_CALL_LOG" "stop cc-my-proj"
}

test_stop_named_not_running_warns() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    local mock_bin="$tmpdir/bin"
    _mock_docker_no_containers "$mock_bin"
    setup_mocks "$mock_bin"
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "my-proj" "$(minimal_project_yml my-proj)"
    run_cco stop "my-proj"
    assert_output_contains "No running session"
}

test_stop_named_uses_yml_name_for_container() {
    # Container name is derived from project.yml 'name' field, not directory name
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    local mock_bin="$tmpdir/bin"
    _mock_docker_with_containers "$mock_bin" "cc-custom-name"
    setup_mocks "$mock_bin"
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "dir-name" "$(cat <<YAML
name: custom-name
description: "Test"
auth:
  method: oauth
docker:
  ports: []
  env: {}
repos: []
YAML
)"
    export DOCKER_CALL_LOG="$tmpdir/docker.log"
    run_cco stop "dir-name"
    assert_file_contains "$DOCKER_CALL_LOG" "stop cc-custom-name"
}

# ── Stop all sessions ─────────────────────────────────────────────────

test_stop_all_stops_each_cc_container() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    local mock_bin="$tmpdir/bin"
    _mock_docker_with_containers "$mock_bin" "cc-proj-a" "cc-proj-b"
    setup_mocks "$mock_bin"
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    export DOCKER_CALL_LOG="$tmpdir/docker.log"
    run_cco stop
    assert_file_contains "$DOCKER_CALL_LOG" "stop cc-proj-a"
    assert_file_contains "$DOCKER_CALL_LOG" "stop cc-proj-b"
}

test_stop_all_removes_managed_files_for_all_projects() {
    # cco stop (no args) cleans .cco/managed/ files for all projects
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    local mock_bin="$tmpdir/bin"
    _mock_docker_with_containers "$mock_bin" "cc-proj-a" "cc-proj-b"
    setup_mocks "$mock_bin"
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "proj-a" "$(minimal_project_yml proj-a)"
    create_project "$tmpdir" "proj-b" "$(minimal_project_yml proj-b)"

    # Plant stale managed files in both projects
    mkdir -p "$(cache_project_managed proj-a)" "$(cache_project_managed proj-b)"
    echo '{}' > "$(cache_project_managed proj-a)/browser.json"
    echo "9222" > "$(cache_project_managed proj-a)/.browser-port"
    echo '{}' > "$(cache_project_managed proj-b)/browser.json"
    echo "9223" > "$(cache_project_managed proj-b)/.browser-port"

    run_cco stop

    assert_file_not_exists "$(cache_project_managed proj-a)/browser.json"
    assert_file_not_exists "$(cache_project_managed proj-a)/.browser-port"
    assert_file_not_exists "$(cache_project_managed proj-b)/browser.json"
    assert_file_not_exists "$(cache_project_managed proj-b)/.browser-port"
}

test_stop_all_no_containers_reports_none() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    local mock_bin="$tmpdir/bin"
    _mock_docker_no_containers "$mock_bin"
    setup_mocks "$mock_bin"
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco stop
    assert_output_contains "No running sessions"
}

# ── Managed state cleanup ─────────────────────────────────────────────

test_browser_stop_removes_managed_files() {
    # cco stop <project> removes .cco/managed/browser.json and .cco/managed/.browser-port
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    local mock_bin="$tmpdir/bin"
    _mock_docker_with_containers "$mock_bin" "cc-my-proj"
    setup_mocks "$mock_bin"
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "my-proj" "$(minimal_project_yml my-proj)"

    # Create stale managed files as if a browser session ended without cleanup
    mkdir -p "$(cache_project_managed my-proj)"
    echo '{"mcpServers":{}}' > "$(cache_project_managed my-proj)/browser.json"
    echo "9222" > "$(cache_project_managed my-proj)/.browser-port"

    run_cco stop "my-proj"

    assert_file_not_exists "$(cache_project_managed my-proj)/browser.json"
    assert_file_not_exists "$(cache_project_managed my-proj)/.browser-port"
}

test_github_stop_removes_managed_json() {
    # cco stop <project> removes .cco/managed/github.json
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    local mock_bin="$tmpdir/bin"
    _mock_docker_with_containers "$mock_bin" "cc-my-proj"
    setup_mocks "$mock_bin"
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "my-proj" "$(minimal_project_yml my-proj)"

    mkdir -p "$(cache_project_managed my-proj)"
    echo '{"mcpServers":{}}' > "$(cache_project_managed my-proj)/github.json"

    run_cco stop "my-proj"

    assert_file_not_exists "$(cache_project_managed my-proj)/github.json"
}

test_stop_all_removes_github_managed_files() {
    # cco stop (no args) removes .cco/managed/github.json for all projects
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    local mock_bin="$tmpdir/bin"
    _mock_docker_with_containers "$mock_bin" "cc-proj-a" "cc-proj-b"
    setup_mocks "$mock_bin"
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "proj-a" "$(minimal_project_yml proj-a)"
    create_project "$tmpdir" "proj-b" "$(minimal_project_yml proj-b)"

    mkdir -p "$(cache_project_managed proj-a)" "$(cache_project_managed proj-b)"
    echo '{"mcpServers":{}}' > "$(cache_project_managed proj-a)/github.json"
    echo '{"mcpServers":{}}' > "$(cache_project_managed proj-b)/github.json"

    run_cco stop

    assert_file_not_exists "$(cache_project_managed proj-a)/github.json"
    assert_file_not_exists "$(cache_project_managed proj-b)/github.json"
}
