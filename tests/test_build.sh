#!/usr/bin/env bash
# tests/test_build.sh — cco build command tests
#
# Regression for the writer/reader path mismatch (2026-06-26): `cco init` /
# `cco init --migrate` write the global extension files (setup.sh,
# setup-build.sh, mcp-packages.txt) to the ~/.cco TOP LEVEL (design §2.3),
# but `cco build` used to read them from ~/.cco/global (a legacy-vault remnant),
# so global build-time customization was silently inert. These tests pin the
# reader to the top-level location and prove the legacy global/ path is NOT used.
#
# The docker build is exercised against the mock docker (mocks.sh), which logs
# every invocation (incl. --build-arg values) to $DOCKER_CALL_LOG.

test_build_reads_global_extensions_from_cco_toplevel() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local mock_bin="$tmpdir/mockbin"
    setup_mocks "$mock_bin"
    _mock_docker_with_containers "$mock_bin"
    export DOCKER_CALL_LOG="$tmpdir/docker.log"; : > "$DOCKER_CALL_LOG"

    # Correct (shipped/design) location: ~/.cco top level.
    printf 'echo TOPLEVEL_BUILD_MARKER\n' > "$HOME/.cco/setup-build.sh"
    printf '@test/mcp-toplevel\n'         > "$HOME/.cco/mcp-packages.txt"
    # Legacy decoy under the defunct ~/.cco/global/ — must NOT be read by the build
    # (it reads the flat ~/.cco top level; ADR-0028 removed the global/ wrapper).
    mkdir -p "$HOME/.cco/global"
    printf 'echo GLOBAL_DECOY_MARKER\n'   > "$HOME/.cco/global/setup-build.sh"
    printf '@test/mcp-global-decoy\n'      > "$HOME/.cco/global/mcp-packages.txt"

    run_cco build

    assert_file_contains     "$DOCKER_CALL_LOG" "TOPLEVEL_BUILD_MARKER"
    assert_file_contains     "$DOCKER_CALL_LOG" "@test/mcp-toplevel"
    assert_file_not_contains "$DOCKER_CALL_LOG" "GLOBAL_DECOY_MARKER"
    assert_file_not_contains "$DOCKER_CALL_LOG" "@test/mcp-global-decoy"
}

test_build_setup_build_preferred_over_runtime_setup() {
    # setup-build.sh (build-time) wins over setup.sh (runtime) when both exist,
    # and both are read from the ~/.cco top level.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local mock_bin="$tmpdir/mockbin"
    setup_mocks "$mock_bin"
    _mock_docker_with_containers "$mock_bin"
    export DOCKER_CALL_LOG="$tmpdir/docker.log"; : > "$DOCKER_CALL_LOG"

    printf 'echo BUILD_TIME_MARKER\n'   > "$HOME/.cco/setup-build.sh"
    printf 'echo RUNTIME_ONLY_MARKER\n' > "$HOME/.cco/setup.sh"

    run_cco build

    assert_file_contains     "$DOCKER_CALL_LOG" "BUILD_TIME_MARKER"
    assert_file_not_contains "$DOCKER_CALL_LOG" "RUNTIME_ONLY_MARKER"
}

test_build_no_global_extensions_is_clean() {
    # With no global setup/mcp files, build still runs (no SETUP_BUILD/ MCP args).
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local mock_bin="$tmpdir/mockbin"
    setup_mocks "$mock_bin"
    _mock_docker_with_containers "$mock_bin"
    export DOCKER_CALL_LOG="$tmpdir/docker.log"; : > "$DOCKER_CALL_LOG"

    run_cco build

    assert_file_contains     "$DOCKER_CALL_LOG" "build"
    assert_file_not_contains "$DOCKER_CALL_LOG" "SETUP_BUILD_SCRIPT_CONTENT"
}

# ── Claude Code native install: build-arg + cache reset (ADR-0039) ──

test_build_bakes_claude_version_latest_by_default() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local mock_bin="$tmpdir/mockbin"
    setup_mocks "$mock_bin"
    _mock_docker_with_containers "$mock_bin"
    export DOCKER_CALL_LOG="$tmpdir/docker.log"; : > "$DOCKER_CALL_LOG"

    run_cco build
    assert_file_contains "$DOCKER_CALL_LOG" "CLAUDE_CODE_VERSION=latest"
}

test_build_bakes_claude_version_from_config_knob() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local mock_bin="$tmpdir/mockbin"
    setup_mocks "$mock_bin"
    _mock_docker_with_containers "$mock_bin"
    export DOCKER_CALL_LOG="$tmpdir/docker.log"; : > "$DOCKER_CALL_LOG"

    printf 'stable\n' > "$HOME/.cco/claude-version"
    run_cco build
    assert_file_contains "$DOCKER_CALL_LOG" "CLAUDE_CODE_VERSION=stable"
}

test_build_claude_version_flag_overrides_knob() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local mock_bin="$tmpdir/mockbin"
    setup_mocks "$mock_bin"
    _mock_docker_with_containers "$mock_bin"
    export DOCKER_CALL_LOG="$tmpdir/docker.log"; : > "$DOCKER_CALL_LOG"

    printf 'stable\n' > "$HOME/.cco/claude-version"
    run_cco build --claude-version 1.2.3
    assert_file_contains     "$DOCKER_CALL_LOG" "CLAUDE_CODE_VERSION=1.2.3"
    assert_file_not_contains "$DOCKER_CALL_LOG" "CLAUDE_CODE_VERSION=stable"
}

test_build_no_cache_resets_install_cache() {
    # --no-cache wipes the native-install cache so the next start reinstalls.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local mock_bin="$tmpdir/mockbin"
    setup_mocks "$mock_bin"
    _mock_docker_with_containers "$mock_bin"
    export DOCKER_CALL_LOG="$tmpdir/docker.log"; : > "$DOCKER_CALL_LOG"

    local install_dir="$CCO_CACHE_HOME/claude-install"
    mkdir -p "$install_dir/bin"
    printf 'fake-binary\n' > "$install_dir/bin/claude"

    run_cco build --no-cache
    assert_dir_not_exists "$install_dir"
}

test_build_without_no_cache_keeps_install_cache() {
    # A plain build must NOT touch an existing install cache.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local mock_bin="$tmpdir/mockbin"
    setup_mocks "$mock_bin"
    _mock_docker_with_containers "$mock_bin"
    export DOCKER_CALL_LOG="$tmpdir/docker.log"; : > "$DOCKER_CALL_LOG"

    local install_dir="$CCO_CACHE_HOME/claude-install"
    mkdir -p "$install_dir/bin"
    printf 'fake-binary\n' > "$install_dir/bin/claude"

    run_cco build
    assert_file_exists "$install_dir/bin/claude"
}
