#!/usr/bin/env bash
# tests/test_vault_profiles.sh — cco vault profile command tests
#
# Verifies profile CRUD: create, list, show, switch, rename, delete.

# ── Helper: set up vault with initial commit ─────────────────────────

_setup_vault_for_profiles() {
    local tmpdir="$1"
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    run_cco vault init
    # Create a test project
    run_cco project create "test-proj"
    run_cco vault sync "add test-proj" --yes
}

# Get the default branch name in the vault (main or master)
_vault_default_branch() {
    git -C "$CCO_USER_CONFIG_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null
}

# ── profile create ───────────────────────────────────────────────────

test_profile_create_makes_branch() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    run_cco vault profile create "work"

    local branch
    branch=$(git -C "$CCO_USER_CONFIG_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)
    assert_equals "work" "$branch" "Expected to be on branch 'work'"
}

test_profile_create_writes_vault_profile() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    run_cco vault profile create "personal"
    assert_file_exists "$CCO_USER_CONFIG_DIR/.vault-profile"
    assert_file_contains "$CCO_USER_CONFIG_DIR/.vault-profile" "profile: personal"
}

test_profile_create_vault_profile_has_sync_section() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    run_cco vault profile create "org-a"
    assert_file_contains "$CCO_USER_CONFIG_DIR/.vault-profile" "sync:"
    assert_file_contains "$CCO_USER_CONFIG_DIR/.vault-profile" "projects:"
    assert_file_contains "$CCO_USER_CONFIG_DIR/.vault-profile" "packs:"
}

test_profile_create_commits() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    run_cco vault profile create "work"
    local msg
    msg=$(git -C "$CCO_USER_CONFIG_DIR" log -1 --format=%s)
    [[ "$msg" == *"create profile"* ]] || fail "Expected commit message to contain 'create profile', got: $msg"
}

test_profile_create_rejects_invalid_name() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    if run_cco vault profile create "My Profile" 2>/dev/null; then
        fail "Expected invalid name to be rejected"
    fi
}

test_profile_create_rejects_main() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    if run_cco vault profile create "main" 2>/dev/null; then
        fail "Expected 'main' to be rejected as profile name"
    fi
}

test_profile_create_rejects_master() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    if run_cco vault profile create "master" 2>/dev/null; then
        fail "Expected 'master' to be rejected as profile name"
    fi
}

test_profile_create_rejects_duplicate() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    run_cco vault profile create "work"
    if run_cco vault profile create "work" 2>/dev/null; then
        fail "Expected duplicate name to be rejected"
    fi
}

# ── profile list ─────────────────────────────────────────────────────

test_profile_list_no_profiles() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    run_cco vault profile list
    assert_output_contains "no profiles"
}

test_profile_list_shows_profile() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    run_cco vault profile create "work"
    run_cco vault profile list
    assert_output_contains "work"
}

test_profile_list_marks_active() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    run_cco vault profile create "work"
    run_cco vault profile list
    assert_output_contains "(active)"
}

# ── profile show ─────────────────────────────────────────────────────

test_profile_show_no_profile() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    run_cco vault profile show
    assert_output_contains "none"
}

test_profile_show_active_profile() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    run_cco vault profile create "work"
    run_cco vault profile show
    assert_output_contains "Profile: work"
    assert_output_contains "Branch: work"
}

test_profile_show_shared_resources() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    run_cco vault profile create "work"
    run_cco vault profile show
    assert_output_contains "global/"
    assert_output_contains "templates/"
}

# ── profile switch ───────────────────────────────────────────────────

test_profile_switch_to_default_branch() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)
    run_cco vault profile create "work"
    run_cco vault profile switch "$default_branch"
    local branch
    branch=$(git -C "$CCO_USER_CONFIG_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)
    assert_equals "$default_branch" "$branch" "Expected to be on default branch"
}

test_profile_switch_to_profile() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)
    run_cco vault profile create "work"
    run_cco vault profile switch "$default_branch"
    run_cco vault profile switch "work"
    local branch
    branch=$(git -C "$CCO_USER_CONFIG_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)
    assert_equals "work" "$branch" "Expected to be on branch 'work'"
}

test_profile_switch_noop_same() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    run_cco vault profile create "work"
    run_cco vault profile switch "work"
    assert_output_contains "Already on"
}

test_profile_switch_nonexistent_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    if run_cco vault profile switch "nonexistent" 2>/dev/null; then
        fail "Expected switch to nonexistent profile to fail"
    fi
}

test_profile_switch_vault_profile_changes() {
    # .vault-profile is tracked per branch — switching should change file
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)
    run_cco vault profile create "work"
    assert_file_exists "$CCO_USER_CONFIG_DIR/.vault-profile"

    run_cco vault profile switch "$default_branch"
    # On default branch, .vault-profile should NOT exist
    [[ ! -f "$CCO_USER_CONFIG_DIR/.vault-profile" ]] || \
        fail ".vault-profile should not exist on default branch"

    run_cco vault profile switch "work"
    assert_file_exists "$CCO_USER_CONFIG_DIR/.vault-profile"
    assert_file_contains "$CCO_USER_CONFIG_DIR/.vault-profile" "profile: work"
}

# ── profile rename ───────────────────────────────────────────────────

test_profile_rename_changes_branch() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    run_cco vault profile create "old-name"
    run_cco vault profile rename "new-name"
    local branch
    branch=$(git -C "$CCO_USER_CONFIG_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)
    assert_equals "new-name" "$branch" "Expected branch to be 'new-name'"
}

test_profile_rename_updates_profile_file() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    run_cco vault profile create "old-name"
    run_cco vault profile rename "new-name"
    assert_file_contains "$CCO_USER_CONFIG_DIR/.vault-profile" "profile: new-name"
}

test_profile_rename_rejects_invalid() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    run_cco vault profile create "test-profile"
    if run_cco vault profile rename "Bad Name" 2>/dev/null; then
        fail "Expected invalid name to be rejected"
    fi
}

test_profile_rename_requires_active_profile() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    if run_cco vault profile rename "new-name" 2>/dev/null; then
        fail "Expected rename on main to fail"
    fi
}

# ── profile delete ───────────────────────────────────────────────────

test_profile_delete_removes_branch() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)
    run_cco vault profile create "to-delete"
    run_cco vault profile switch "$default_branch"
    run_cco vault profile delete "to-delete" --yes

    if git -C "$CCO_USER_CONFIG_DIR" rev-parse --verify "to-delete" >/dev/null 2>&1; then
        fail "Expected branch 'to-delete' to be removed"
    fi
}

test_profile_delete_active_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    run_cco vault profile create "active-profile"
    if run_cco vault profile delete "active-profile" 2>/dev/null; then
        fail "Expected delete of active profile to fail"
    fi
}

test_profile_delete_nonexistent_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    if run_cco vault profile delete "ghost" 2>/dev/null; then
        fail "Expected delete of nonexistent profile to fail"
    fi
}

# ── vault status with profile ────────────────────────────────────────

test_vault_status_shows_profile() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    run_cco vault profile create "work"
    run_cco vault status
    assert_output_contains "Profile: work"
}

test_vault_status_no_profile_shows_branch() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    run_cco vault status
    assert_output_contains "Branch:"
}

# ── help commands ────────────────────────────────────────────────────

test_vault_profile_help() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco vault profile --help
    assert_output_contains "create"
    assert_output_contains "list"
    assert_output_contains "switch"
}

test_vault_help_includes_profile() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco vault --help
    assert_output_contains "profile"
}
