#!/usr/bin/env bash
# tests/test_paths.sh — path helper dual-read fallback tests
#
# Verifies that lib/paths.sh helpers correctly resolve new (.cco/) paths,
# fall back to old paths, and default to new paths for writes.

# ── Project Meta ─────────────────────────────────────────────────────

test_paths_project_meta_new_path() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    export USER_CONFIG_DIR="$tmpdir/uc"
    export GLOBAL_DIR="$tmpdir/uc/global"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"

    local proj="$tmpdir/project"
    mkdir -p "$proj/.cco"
    echo "test" > "$proj/.cco/meta"

    local result; result=$(_cco_project_meta "$proj")
    [[ "$result" == "$proj/.cco/meta" ]] || fail "Expected new path, got: $result"
}

test_paths_project_meta_old_fallback() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    export USER_CONFIG_DIR="$tmpdir/uc"
    export GLOBAL_DIR="$tmpdir/uc/global"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"

    local proj="$tmpdir/project"
    mkdir -p "$proj"
    echo "old" > "$proj/.cco-meta"

    local result; result=$(_cco_project_meta "$proj")
    [[ "$result" == "$proj/.cco-meta" ]] || fail "Expected old path fallback, got: $result"
}

test_paths_project_meta_default_new() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    export USER_CONFIG_DIR="$tmpdir/uc"
    export GLOBAL_DIR="$tmpdir/uc/global"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"

    local proj="$tmpdir/project"
    mkdir -p "$proj"

    local result; result=$(_cco_project_meta "$proj")
    [[ "$result" == "$proj/.cco/meta" ]] || fail "Expected new path default for writes, got: $result"
}

# ── Project Managed (directory type, uses -d) ────────────────────────

test_paths_project_managed_dir_new_path() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    export USER_CONFIG_DIR="$tmpdir/uc"
    export GLOBAL_DIR="$tmpdir/uc/global"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"

    local proj="$tmpdir/project"
    mkdir -p "$proj/.cco/managed"

    local result; result=$(_cco_project_managed "$proj")
    [[ "$result" == "$proj/.cco/managed" ]] || fail "Expected new managed dir, got: $result"
}

test_paths_project_managed_dir_old_fallback() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    export USER_CONFIG_DIR="$tmpdir/uc"
    export GLOBAL_DIR="$tmpdir/uc/global"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"

    local proj="$tmpdir/project"
    mkdir -p "$proj/.managed"

    local result; result=$(_cco_project_managed "$proj")
    [[ "$result" == "$proj/.managed" ]] || fail "Expected old .managed/ fallback, got: $result"
}

test_paths_project_managed_dir_default_new() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    export USER_CONFIG_DIR="$tmpdir/uc"
    export GLOBAL_DIR="$tmpdir/uc/global"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"

    local proj="$tmpdir/project"
    mkdir -p "$proj"

    local result; result=$(_cco_project_managed "$proj")
    [[ "$result" == "$proj/.cco/managed" ]] || fail "Expected new managed dir default, got: $result"
}

# ── Remotes File ─────────────────────────────────────────────────────

test_paths_remotes_file_new_path() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    export USER_CONFIG_DIR="$tmpdir/uc"
    export GLOBAL_DIR="$tmpdir/uc/global"
    mkdir -p "$USER_CONFIG_DIR/.cco"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"

    echo "remote=git@example.com:r.git" > "$USER_CONFIG_DIR/.cco/remotes"

    local result; result=$(_cco_remotes_file)
    [[ "$result" == "$USER_CONFIG_DIR/.cco/remotes" ]] || fail "Expected new remotes path, got: $result"
}

test_paths_remotes_file_old_fallback() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    export USER_CONFIG_DIR="$tmpdir/uc"
    export GLOBAL_DIR="$tmpdir/uc/global"
    mkdir -p "$USER_CONFIG_DIR"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"

    echo "remote=git@example.com:r.git" > "$USER_CONFIG_DIR/.cco-remotes"

    local result; result=$(_cco_remotes_file)
    [[ "$result" == "$USER_CONFIG_DIR/.cco-remotes" ]] || fail "Expected old .cco-remotes fallback, got: $result"
}

test_paths_remotes_file_default_new() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    export USER_CONFIG_DIR="$tmpdir/uc"
    export GLOBAL_DIR="$tmpdir/uc/global"
    mkdir -p "$USER_CONFIG_DIR"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"

    local result; result=$(_cco_remotes_file)
    [[ "$result" == "$USER_CONFIG_DIR/.cco/remotes" ]] || fail "Expected new remotes default, got: $result"
}

# ── Pack Source ──────────────────────────────────────────────────────

test_paths_pack_source_new_path() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    export USER_CONFIG_DIR="$tmpdir/uc"
    export GLOBAL_DIR="$tmpdir/uc/global"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"

    local pack="$tmpdir/pack-a"
    mkdir -p "$pack/.cco"
    echo "git@example.com:pack.git" > "$pack/.cco/source"

    local result; result=$(_cco_pack_source "$pack")
    [[ "$result" == "$pack/.cco/source" ]] || fail "Expected new pack source path, got: $result"
}

test_paths_pack_source_old_fallback() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    export USER_CONFIG_DIR="$tmpdir/uc"
    export GLOBAL_DIR="$tmpdir/uc/global"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"

    local pack="$tmpdir/pack-a"
    mkdir -p "$pack"
    echo "git@example.com:pack.git" > "$pack/.cco-source"

    local result; result=$(_cco_pack_source "$pack")
    [[ "$result" == "$pack/.cco-source" ]] || fail "Expected old .cco-source fallback, got: $result"
}

test_paths_pack_source_default_new() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    export USER_CONFIG_DIR="$tmpdir/uc"
    export GLOBAL_DIR="$tmpdir/uc/global"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"

    local pack="$tmpdir/pack-a"
    mkdir -p "$pack"

    local result; result=$(_cco_pack_source "$pack")
    [[ "$result" == "$pack/.cco/source" ]] || fail "Expected new pack source default, got: $result"
}

# ── Pack Install Tmp ─────────────────────────────────────────────────

test_paths_pack_install_tmp_new_path() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    export USER_CONFIG_DIR="$tmpdir/uc"
    export GLOBAL_DIR="$tmpdir/uc/global"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"

    local pack="$tmpdir/pack-a"
    mkdir -p "$pack/.cco/install-tmp"

    local result; result=$(_cco_pack_install_tmp "$pack")
    [[ "$result" == "$pack/.cco/install-tmp" ]] || fail "Expected new install-tmp path, got: $result"
}

test_paths_pack_install_tmp_old_fallback() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    export USER_CONFIG_DIR="$tmpdir/uc"
    export GLOBAL_DIR="$tmpdir/uc/global"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"

    local pack="$tmpdir/pack-a"
    mkdir -p "$pack/.cco-install-tmp"

    local result; result=$(_cco_pack_install_tmp "$pack")
    [[ "$result" == "$pack/.cco-install-tmp" ]] || fail "Expected old .cco-install-tmp fallback, got: $result"
}

test_paths_pack_install_tmp_default_new() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    export USER_CONFIG_DIR="$tmpdir/uc"
    export GLOBAL_DIR="$tmpdir/uc/global"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"

    local pack="$tmpdir/pack-a"
    mkdir -p "$pack"

    local result; result=$(_cco_pack_install_tmp "$pack")
    [[ "$result" == "$pack/.cco/install-tmp" ]] || fail "Expected new install-tmp default, got: $result"
}
