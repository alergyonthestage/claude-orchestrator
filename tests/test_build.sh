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
    # --no-cache clears the native-install CONTENTS so the next start reinstalls
    # (the entrypoint installs when the binary is absent). It must PRESERVE the
    # bin/ and share/ directory NODES — they are Docker Desktop bind-mount sources,
    # and removing them triggers a macOS VirtioFS stale-share bug that breaks the
    # next `cco start` with "mount source path … no such file or directory".
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local mock_bin="$tmpdir/mockbin"
    setup_mocks "$mock_bin"
    _mock_docker_with_containers "$mock_bin"
    export DOCKER_CALL_LOG="$tmpdir/docker.log"; : > "$DOCKER_CALL_LOG"

    local install_dir="$CCO_CACHE_HOME/claude-install"
    mkdir -p "$install_dir/bin" "$install_dir/share/claude"
    printf 'fake-binary\n' > "$install_dir/bin/claude"
    printf 'state\n' > "$install_dir/share/claude/state.json"

    run_cco build --no-cache
    # The install is emptied (binary gone → fresh install next start)…
    assert_file_not_exists "$install_dir/bin/claude"
    assert_file_not_exists "$install_dir/share/claude/state.json"
    # …but the bind-mount source dirs survive (VirtioFS-safe).
    assert_dir_exists "$install_dir/bin"
    assert_dir_exists "$install_dir/share"
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

# ── V1-F3 ≡ V5-8: build provenance baked into the image ─────────────────────────
# The e2e §4 template has an "Image built from: <branch @ sha>" field that NO session
# could fill, because nothing in the image records what it was built from. That field
# exists precisely BECAUSE v2's cycle-0 was built from the wrong branch and the whole
# round's results had to be discarded. Launch rule 0 is only self-verifying if the
# answer lives in the image. `.git/` is excluded from the build context (.dockerignore),
# so this MUST arrive as a build arg — the Dockerfile cannot derive it.
# ⚠ FAILS on pre-fix: no CCO_BUILD_REF anywhere.

test_build_ref_is_branch_at_sha() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    local repo="$tmpdir/repo"; mkdir -p "$repo"
    ( cd "$repo" && git init -q -b trunk && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m x ) || { fail "fixture git repo failed"; return 1; }

    local out
    out=$( source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/utils.sh"
           source "$REPO_ROOT/lib/cmd-build.sh"; _cco_build_ref "$repo" )
    [[ "$out" == trunk@* ]] || fail "expected 'trunk@<sha>', got: $out" || return 1
    [[ "${out#trunk@}" =~ ^[0-9a-f]{7,}$ ]] \
        || fail "expected a short sha after '@', got: $out" || return 1
    return 0
}

# Fail-SAFE, never fail-closed: provenance is diagnostic, so a missing .git (an npm
# install, a tarball) must degrade to a legible marker and NEVER break `cco build`.
test_build_ref_unknown_outside_a_git_repo() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    mkdir -p "$tmpdir/plain"

    local out
    out=$( source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/utils.sh"
           source "$REPO_ROOT/lib/cmd-build.sh"; _cco_build_ref "$tmpdir/plain" )
    [[ "$out" == "unknown" ]] || fail "expected 'unknown' outside a git repo, got: $out" || return 1
    return 0
}

test_build_passes_build_ref_as_build_arg() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local mock_bin="$tmpdir/mockbin"
    setup_mocks "$mock_bin"
    _mock_docker_with_containers "$mock_bin"
    export DOCKER_CALL_LOG="$tmpdir/docker.log"; : > "$DOCKER_CALL_LOG"

    run_cco build
    assert_file_contains "$DOCKER_CALL_LOG" "CCO_BUILD_REF="
}

# The arg is only useful if the Dockerfile actually persists it. Static, because the
# real build cannot run hermetically — this is the half of V1-F3 that a suite CAN pin;
# the other half is the §6 gate (a live `cco build`, then read /opt/cco/BUILD).
test_dockerfile_persists_build_ref() {
    assert_file_contains "$REPO_ROOT/Dockerfile" "ARG CCO_BUILD_REF"
    assert_file_contains "$REPO_ROOT/Dockerfile" "/opt/cco/BUILD"
}
