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
