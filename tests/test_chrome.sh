#!/usr/bin/env bash
# tests/test_chrome.sh — tests for 'cco chrome' port resolution and helpers
# Requires: helpers.sh, mocks.sh (sourced by bin/test)
#
# NOTE: _chrome_start and _chrome_stop involve OS process management and
# Chrome binary detection. They are covered by manual integration tests only.
# Unit tests focus on port resolution logic and help output.

# ── Port resolution ────────────────────────────────────────────────────

test_chrome_resolve_port_explicit() {
    # --port 9223 returns 9223 regardless of other flags
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    # Source the lib to get _chrome_resolve_port
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/yaml.sh"
    source "$REPO_ROOT/lib/cmd-chrome.sh"

    local result
    result=$(_chrome_resolve_port --port 9223)
    assert_equals "9223" "$result"
}

test_chrome_resolve_port_from_project() {
    # --project foo reads projects/foo/.cco/managed/.browser-port if present
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "foo" "$(minimal_project_yml foo)"

    # Create runtime .cco/managed/.browser-port file
    mkdir -p "$CCO_PROJECTS_DIR/foo/.cco/managed"
    echo "9224" > "$CCO_PROJECTS_DIR/foo/.cco/managed/.browser-port"

    # Mock docker so it doesn't fail on ps
    local mock_bin="$tmpdir/bin"
    _mock_docker_no_containers "$mock_bin"
    setup_mocks "$mock_bin"

    # Set PROJECTS_DIR (normally set by bin/cco)
    PROJECTS_DIR="$CCO_PROJECTS_DIR"

    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/yaml.sh"
    source "$REPO_ROOT/lib/cmd-chrome.sh"

    local result
    result=$(_chrome_resolve_port --project foo 2>/dev/null)
    assert_equals "9224" "$result"
}

test_chrome_resolve_port_fallback_yml() {
    # --project foo falls back to project.yml browser.cdp_port when .browser-port absent
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "bar" "$(cat <<YAML
name: bar
description: "Test"
auth:
  method: oauth
docker:
  ports: []
  env: {}
browser:
  enabled: true
  cdp_port: 9300
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
YAML
)"

    # Mock docker
    local mock_bin="$tmpdir/bin"
    _mock_docker_no_containers "$mock_bin"
    setup_mocks "$mock_bin"

    # Set PROJECTS_DIR (normally set by bin/cco)
    PROJECTS_DIR="$CCO_PROJECTS_DIR"

    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/yaml.sh"
    source "$REPO_ROOT/lib/cmd-chrome.sh"

    local result
    result=$(_chrome_resolve_port --project bar 2>/dev/null)
    assert_equals "9300" "$result"
}

test_chrome_resolve_port_default() {
    # No flags → returns 9222
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"

    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/yaml.sh"
    source "$REPO_ROOT/lib/cmd-chrome.sh"

    local result
    result=$(_chrome_resolve_port)
    assert_equals "9222" "$result"
}

test_chrome_resolve_port_explicit_overrides_project() {
    # --port takes priority over --project
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "foo" "$(minimal_project_yml foo)"
    mkdir -p "$CCO_PROJECTS_DIR/foo/.cco/managed"
    echo "9224" > "$CCO_PROJECTS_DIR/foo/.cco/managed/.browser-port"

    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/yaml.sh"
    source "$REPO_ROOT/lib/cmd-chrome.sh"

    local result
    result=$(_chrome_resolve_port --port 9999 --project foo)
    assert_equals "9999" "$result"
}

# ── Help output ──────────────────────────────────────────────────────

test_chrome_help() {
    # cco chrome --help shows usage text
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco chrome --help
    assert_output_contains "cco chrome"
    assert_output_contains "--project"
    assert_output_contains "--port"
}
