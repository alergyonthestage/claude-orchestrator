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
    # Set git identity to prevent CI failures on machines without global git config
    git -C "$CCO_USER_CONFIG_DIR" config user.email "test@test.local"
    git -C "$CCO_USER_CONFIG_DIR" config user.name "Test"
    # Create a test project
    run_cco project create "test-proj"
    run_cco vault sync "add test-proj" --yes
}

# Get the default branch name in the vault (main or master)
_vault_default_branch() {
    if git -C "$CCO_USER_CONFIG_DIR" rev-parse --verify main >/dev/null 2>&1; then
        echo "main"
    elif git -C "$CCO_USER_CONFIG_DIR" rev-parse --verify master >/dev/null 2>&1; then
        echo "master"
    else
        git -C "$CCO_USER_CONFIG_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null
    fi
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

# ── Phase 3: Selective sync ──────────────────────────────────────────

test_vault_sync_with_profile_stages_shared() {
    # With active profile, vault sync stages shared resources
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    run_cco vault profile create "work"

    # Modify a shared resource (global config)
    echo "# Updated" >> "$CCO_USER_CONFIG_DIR/global/.claude/CLAUDE.md"
    run_cco vault sync "update global" --yes
    assert_output_contains "Committed"
}

test_vault_sync_with_profile_stages_exclusive() {
    # Profile-exclusive projects are staged
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    run_cco vault profile create "work"

    # NOTE: Manual heredoc write intentionally bypasses `profile add` to test
    # the sync path in isolation (verifies staging logic, not the add command).
    cat > "$CCO_USER_CONFIG_DIR/.vault-profile" << 'YML'
profile: work
sync:
  projects:
    - test-proj
  packs:
    []
YML

    # Modify the project
    echo "# Updated" >> "$CCO_USER_CONFIG_DIR/projects/test-proj/.claude/CLAUDE.md"
    run_cco vault sync "update proj" --yes
    assert_output_contains "Committed"
}

test_vault_sync_without_profile_stages_all() {
    # Without profile, vault sync stages everything (backward compatible)
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"

    echo "# New file" > "$CCO_USER_CONFIG_DIR/global/.claude/test-file.md"
    run_cco vault sync "add test file" --yes
    assert_output_contains "Committed"

    # Verify file was committed
    local committed
    committed=$(git -C "$CCO_USER_CONFIG_DIR" show HEAD --name-only --format= | grep "test-file.md" || true)
    [[ -n "$committed" ]] || fail "Expected test-file.md to be committed"
}

test_vault_sync_profile_does_not_stage_other_projects() {
    # Projects not in profile sync list should NOT be staged
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"

    # Create second project
    run_cco project create "other-proj"
    run_cco vault sync "add other-proj" --yes

    # Create profile with only test-proj
    run_cco vault profile create "work"
    # NOTE: Manual heredoc write intentionally bypasses `profile add` to test
    # the sync path in isolation (verifies staging logic, not the add command).
    cat > "$CCO_USER_CONFIG_DIR/.vault-profile" << 'YML'
profile: work
sync:
  projects:
    - test-proj
  packs:
    []
YML

    # Modify both projects
    echo "# mod-test" >> "$CCO_USER_CONFIG_DIR/projects/test-proj/.claude/CLAUDE.md"
    echo "# mod-other" >> "$CCO_USER_CONFIG_DIR/projects/other-proj/.claude/CLAUDE.md"

    run_cco vault sync "selective" --yes

    # test-proj should be committed, other-proj should NOT
    local committed_files
    committed_files=$(git -C "$CCO_USER_CONFIG_DIR" show HEAD --name-only --format=)
    echo "$committed_files" | grep -q "test-proj" || fail "Expected test-proj changes to be committed"
    if echo "$committed_files" | grep -q "other-proj"; then
        fail "Expected other-proj changes NOT to be committed"
    fi
}

test_vault_sync_profile_stages_shared_packs() {
    # Packs not in exclusive list are shared and should be staged
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"

    # Create a pack
    run_cco pack create "shared-pack"
    run_cco vault sync "add pack" --yes

    # Create profile (pack NOT in exclusive list → shared)
    run_cco vault profile create "work"

    # Modify shared pack
    echo "# Updated" >> "$CCO_USER_CONFIG_DIR/packs/shared-pack/pack.yml"
    run_cco vault sync "update pack" --yes
    assert_output_contains "Committed"
}

# ── Phase 4: Resource movement ───────────────────────────────────────

test_profile_add_project() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    run_cco vault profile create "work"

    run_cco vault profile add project "test-proj"
    assert_file_contains "$CCO_USER_CONFIG_DIR/.vault-profile" "test-proj"
}

test_profile_add_pack() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"

    # Create a pack first
    run_cco pack create "my-pack"
    run_cco vault sync "add pack" --yes

    run_cco vault profile create "work"
    run_cco vault profile add pack "my-pack"
    assert_file_contains "$CCO_USER_CONFIG_DIR/.vault-profile" "my-pack"
}

test_profile_add_nonexistent_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    run_cco vault profile create "work"

    if run_cco vault profile add project "nonexistent" 2>/dev/null; then
        fail "Expected add of nonexistent project to fail"
    fi
}

test_profile_add_requires_active_profile() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"

    if run_cco vault profile add project "test-proj" 2>/dev/null; then
        fail "Expected add without active profile to fail"
    fi
}

test_profile_remove_project() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    run_cco vault profile create "work"
    run_cco vault profile add project "test-proj"

    # Verify it was added
    assert_file_contains "$CCO_USER_CONFIG_DIR/.vault-profile" "test-proj"

    run_cco vault profile remove project "test-proj"
    # Should no longer be in exclusive list
    assert_file_not_contains "$CCO_USER_CONFIG_DIR/.vault-profile" "test-proj"
}

test_profile_move_project_to_profile() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"

    # Create two profiles
    run_cco vault profile create "work"
    local default_branch
    default_branch=$(_vault_default_branch)
    run_cco vault profile switch "$default_branch"
    run_cco vault profile create "personal"

    # Move test-proj to work profile
    run_cco vault profile move project "test-proj" --to "work"
    assert_output_contains "Moved"
}

test_profile_move_missing_to_flag() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    run_cco vault profile create "work"

    if run_cco vault profile move project "test-proj" 2>/dev/null; then
        fail "Expected move without --to to fail"
    fi
}

test_profile_add_help() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco vault profile add --help
    assert_output_contains "project"
    assert_output_contains "pack"
}

test_profile_move_help() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco vault profile move --help
    assert_output_contains "project"
    assert_output_contains "pack"
}

# ── W9: Push/pull with active profile ────────────────────────────────

test_vault_push_with_profile_syncs_shared() {
    # vault push with active profile should sync shared resources to default branch
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"

    # Create a bare remote
    local bare="$tmpdir/remote.git"
    git init --bare -q "$bare"
    run_cco vault remote add origin "$bare"
    run_cco vault push

    # Create a profile
    run_cco vault profile create "work"

    # Modify a shared resource (global config)
    echo "# Profile update" >> "$CCO_USER_CONFIG_DIR/global/.claude/CLAUDE.md"
    run_cco vault sync "update shared" --yes

    # Push (should sync shared to default branch before pushing)
    run_cco vault push
    assert_output_contains "Pushed to"

    # Verify the shared resource change was synced to the default branch
    local default_branch
    default_branch=$(_vault_default_branch)
    local shared_content
    shared_content=$(git -C "$CCO_USER_CONFIG_DIR" show "$default_branch:global/.claude/CLAUDE.md" 2>/dev/null)
    if ! echo "$shared_content" | grep -qF "Profile update"; then
        fail "Expected shared resource to be synced to default branch after push"
    fi
}

test_vault_pull_with_profile_syncs_shared() {
    # vault pull with active profile should sync shared resources from default after pulling
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"

    # Create a bare remote and push
    local bare="$tmpdir/remote.git"
    git init --bare -q "$bare"
    run_cco vault remote add origin "$bare"
    run_cco vault push

    # Create a profile and push it too
    run_cco vault profile create "work"
    run_cco vault push

    # Simulate a change on the default branch via a second clone (as if another machine pushed)
    local default_branch
    default_branch=$(_vault_default_branch)
    local clone2="$tmpdir/clone2"
    git clone -q "$bare" "$clone2"
    git -C "$clone2" config user.email "test@test.local"
    git -C "$clone2" config user.name "Test"
    echo "# Remote change from clone2" >> "$clone2/global/.claude/CLAUDE.md"
    git -C "$clone2" add -A
    git -C "$clone2" commit -q -m "remote: update shared from another machine"
    git -C "$clone2" push origin "$default_branch" -q

    # Switch back to profile branch in our vault
    git -C "$CCO_USER_CONFIG_DIR" checkout "work" -q

    # Pull should fetch and sync shared resources from default
    run_cco vault pull

    # Verify the shared resource was synced onto the profile branch (from origin/default)
    local content
    content=$(cat "$CCO_USER_CONFIG_DIR/global/.claude/CLAUDE.md" 2>/dev/null)
    if ! echo "$content" | grep -qF "Remote change from clone2"; then
        fail "Expected shared resource to be synced from default onto profile branch"
    fi
}

# ── W11: Profile delete with exclusive resources ─────────────────────

test_profile_delete_moves_exclusive_to_default() {
    # Deleting a profile should move exclusive project files to default branch
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"

    local default_branch
    default_branch=$(_vault_default_branch)

    # Create a profile
    run_cco vault profile create "temp-profile"

    # Add the project to the profile (making it exclusive)
    run_cco vault profile add project "test-proj"

    # Verify the project is in the profile's exclusive list
    assert_file_contains "$CCO_USER_CONFIG_DIR/.vault-profile" "test-proj"

    # Switch back to default to be able to delete
    run_cco vault profile switch "$default_branch"

    # Delete the profile
    run_cco vault profile delete "temp-profile" --yes

    # Verify the branch is gone
    if git -C "$CCO_USER_CONFIG_DIR" rev-parse --verify "temp-profile" >/dev/null 2>&1; then
        fail "Expected branch 'temp-profile' to be deleted"
    fi

    # Verify the project files are present on the default branch
    local proj_files
    proj_files=$(git -C "$CCO_USER_CONFIG_DIR" ls-tree -r HEAD --name-only -- "projects/test-proj/" 2>/dev/null)
    if [[ -z "$proj_files" ]]; then
        fail "Expected project 'test-proj' files to be present on default branch after profile delete"
    fi

    # Verify the project directory actually exists in the worktree
    [[ -d "$CCO_USER_CONFIG_DIR/projects/test-proj" ]] || \
        fail "Expected projects/test-proj directory to exist on default branch"
}

# ── S4: Profile move verifies git state ──────────────────────────────

test_profile_move_verifies_target_state() {
    # After moving a project to another profile, verify it appears in target's
    # .vault-profile and the project directory is present on the target branch.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"

    local default_branch
    default_branch=$(_vault_default_branch)

    # Create source profile and add project
    run_cco vault profile create "source"
    run_cco vault profile add project "test-proj"

    # Create target profile
    run_cco vault profile switch "$default_branch"
    run_cco vault profile create "target"

    # Switch back to source to perform the move
    run_cco vault profile switch "source"
    run_cco vault profile move project "test-proj" --to "target"
    assert_output_contains "Moved"

    # Verify: project appears in target profile's .vault-profile
    local target_profile_content
    target_profile_content=$(git -C "$CCO_USER_CONFIG_DIR" show "target:.vault-profile" 2>/dev/null)
    if ! echo "$target_profile_content" | grep -qF "test-proj"; then
        fail "Expected 'test-proj' to appear in target profile's .vault-profile"
    fi

    # Verify: project directory is present on the target branch
    local target_proj_tree
    target_proj_tree=$(git -C "$CCO_USER_CONFIG_DIR" ls-tree "target" -- "projects/test-proj/" 2>/dev/null)
    if [[ -z "$target_proj_tree" ]]; then
        fail "Expected project directory to be present on target branch"
    fi
}

# ── S5: Profile remove verifies main state ───────────────────────────

test_profile_remove_verifies_main_state() {
    # After removing a project from a profile, the project should still be
    # accessible and .vault-profile should no longer list it.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"

    # Create a profile and add the project
    run_cco vault profile create "work"
    run_cco vault profile add project "test-proj"

    # Verify the project is in the exclusive list
    assert_file_contains "$CCO_USER_CONFIG_DIR/.vault-profile" "test-proj"

    # Remove the project from the profile
    run_cco vault profile remove project "test-proj"

    # Verify .vault-profile no longer lists the project
    assert_file_not_contains "$CCO_USER_CONFIG_DIR/.vault-profile" "test-proj"

    # Verify the project directory still exists (it's now shared, on the branch)
    [[ -d "$CCO_USER_CONFIG_DIR/projects/test-proj" ]] || \
        fail "Expected project directory to still exist after removal from profile"

    # Verify the project is accessible from the default branch too
    local default_branch
    default_branch=$(_vault_default_branch)
    local proj_on_default
    proj_on_default=$(git -C "$CCO_USER_CONFIG_DIR" ls-tree "$default_branch" -- "projects/test-proj/" 2>/dev/null)
    # The project should exist on default since it was originally synced there
    [[ -n "$proj_on_default" ]] || \
        fail "Expected project to be accessible on default branch after removal from profile"
}

# ── T1: vault diff with profile scoping ───────────────────────────────

test_vault_diff_with_profile_shows_only_scoped_projects() {
    # vault diff should only show changes for profile-scoped projects
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"

    # Create second project and sync it
    run_cco project create "other-proj"
    run_cco vault sync "add other-proj" --yes

    # Create profile with only test-proj
    run_cco vault profile create "work"
    run_cco vault profile add project "test-proj"

    # Modify both projects (unstaged changes)
    echo "# mod-test" >> "$CCO_USER_CONFIG_DIR/projects/test-proj/.claude/CLAUDE.md"
    echo "# mod-other" >> "$CCO_USER_CONFIG_DIR/projects/other-proj/.claude/CLAUDE.md"

    # vault diff should only show test-proj, not other-proj
    run_cco vault diff
    assert_output_contains "test-proj" "Expected diff to show profile-scoped project"
    assert_output_not_contains "other-proj" "Expected diff NOT to show out-of-scope project"
}

# ── T3: auto-commit secret-filtering ─────────────────────────────────

test_vault_auto_commit_skips_secret_files() {
    # _vault_auto_commit (triggered by profile switch) should skip secret files
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    run_cco vault profile create "work"

    # Create a secret file (matches _VAULT_SECRET_PATTERNS: *.env)
    echo "SECRET=value" > "$CCO_USER_CONFIG_DIR/projects/test-proj/local.env"
    # Create a normal file
    echo "# Normal change" >> "$CCO_USER_CONFIG_DIR/projects/test-proj/.claude/CLAUDE.md"

    local default_branch
    default_branch=$(_vault_default_branch)

    # Switch profile triggers _vault_auto_commit
    run_cco vault profile switch "$default_branch"

    # Switch back and check commit history on the work branch
    run_cco vault profile switch "work"
    local committed_files
    committed_files=$(git -C "$CCO_USER_CONFIG_DIR" show "work" --name-only --format= 2>/dev/null)

    # The normal file should have been auto-committed
    echo "$committed_files" | grep -q "CLAUDE.md" || \
        fail "Expected normal file to be auto-committed"

    # The secret file should NOT have been committed
    if echo "$committed_files" | grep -q "local.env"; then
        fail "Expected secret file (local.env) NOT to be auto-committed"
    fi
}

# ── T4: profile create always branches from main ─────────────────────

test_profile_create_branches_from_main() {
    # Creating profile-B while on profile-A should branch from main, not profile-A
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"

    local default_branch
    default_branch=$(_vault_default_branch)

    # Create profile-A and add a project to it (exclusive)
    run_cco vault profile create "profile-a"
    run_cco vault profile add project "test-proj"

    # While on profile-A, create profile-B
    run_cco vault profile create "profile-b"

    # profile-B should NOT contain test-proj in its exclusive list
    # (it was branched from main, not from profile-A)
    assert_file_not_contains "$CCO_USER_CONFIG_DIR/.vault-profile" "test-proj" \
        "profile-B should not inherit profile-A's exclusive resources"

    # Verify by checking git: profile-B's .vault-profile should have empty lists
    local profile_b_content
    profile_b_content=$(git -C "$CCO_USER_CONFIG_DIR" show "profile-b:.vault-profile" 2>/dev/null)
    if echo "$profile_b_content" | grep -qF "test-proj"; then
        fail "profile-B should not contain test-proj (should branch from main)"
    fi
}

# ── T5: profile move pack and profile remove pack ────────────────────

test_profile_move_pack_to_profile() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"

    # Create a pack and sync
    run_cco pack create "my-pack"
    run_cco vault sync "add pack" --yes

    local default_branch
    default_branch=$(_vault_default_branch)

    # Create two profiles
    run_cco vault profile create "work"
    run_cco vault profile switch "$default_branch"
    run_cco vault profile create "personal"

    # Move pack to work profile
    run_cco vault profile move pack "my-pack" --to "work"
    assert_output_contains "Moved"

    # Verify the pack appears in the target profile's .vault-profile
    local target_profile_content
    target_profile_content=$(git -C "$CCO_USER_CONFIG_DIR" show "work:.vault-profile" 2>/dev/null)
    if ! echo "$target_profile_content" | grep -qF "my-pack"; then
        fail "Expected 'my-pack' to appear in work profile's .vault-profile"
    fi
}

test_profile_remove_pack() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"

    # Create a pack and sync
    run_cco pack create "my-pack"
    run_cco vault sync "add pack" --yes

    # Create profile and add the pack
    run_cco vault profile create "work"
    run_cco vault profile add pack "my-pack"

    # Verify it was added
    assert_file_contains "$CCO_USER_CONFIG_DIR/.vault-profile" "my-pack"

    # Remove the pack from the profile
    run_cco vault profile remove pack "my-pack"

    # Should no longer be in exclusive list
    assert_file_not_contains "$CCO_USER_CONFIG_DIR/.vault-profile" "my-pack"

    # Pack directory should still exist
    [[ -d "$CCO_USER_CONFIG_DIR/packs/my-pack" ]] || \
        fail "Expected pack directory to still exist after removal from profile"
}

# ── T6: profile add creates a commit ─────────────────────────────────

test_profile_add_project_creates_commit() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    run_cco vault profile create "work"

    # Record commit count before add
    local before_count
    before_count=$(git -C "$CCO_USER_CONFIG_DIR" rev-list --count HEAD)

    run_cco vault profile add project "test-proj"

    # Verify a new commit was created
    local after_count
    after_count=$(git -C "$CCO_USER_CONFIG_DIR" rev-list --count HEAD)
    [[ "$after_count" -gt "$before_count" ]] || \
        fail "Expected a new commit after profile add (before=$before_count, after=$after_count)"

    # Verify the commit message relates to profile/add
    local msg
    msg=$(git -C "$CCO_USER_CONFIG_DIR" log -1 --format=%s)
    [[ "$msg" == *"add"* ]] || [[ "$msg" == *"profile"* ]] || \
        fail "Expected commit message to reference add or profile, got: $msg"
}

# ── T7: profile list resource counts ─────────────────────────────────

test_profile_list_shows_resource_counts() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    run_cco vault profile create "work"
    run_cco vault profile add project "test-proj"

    run_cco vault profile list
    assert_output_contains "1 project(s)" \
        "Expected profile list to show '1 project(s)' after adding a project"
}

# ── T8: vault status exclusive resource counts ────────────────────────

test_vault_status_shows_exclusive_counts() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    run_cco vault profile create "work"
    run_cco vault profile add project "test-proj"

    run_cco vault status
    assert_output_contains "1 project(s)" \
        "Expected vault status to show exclusive project count"
    assert_output_contains "0 pack(s)" \
        "Expected vault status to show exclusive pack count"
}

# ── W10: Conflict resolution (non-interactive fallback) ──────────────
# The _resolve_shared_conflict function checks [[ ! -t 0 ]] and if stdin
# is not a TTY, it warns and skips the conflict (returns 0).
# Full interactive conflict resolution (L/R/M/D choices) requires a TTY,
# which is not available in automated tests. This test documents the gap.

test_conflict_resolution_non_interactive_skips() {
    # NOTE: Full conflict resolution requires interactive TTY input (L/R/M/D).
    # In non-interactive mode (piped stdin), conflicts are skipped with a warning.
    # This test verifies that the non-interactive fallback works without error.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"

    # Create a bare remote and push
    local bare="$tmpdir/remote.git"
    git init --bare -q "$bare"
    run_cco vault remote add origin "$bare"
    run_cco vault push

    # Create a profile and push
    run_cco vault profile create "work"
    run_cco vault push

    # Modify shared resource on default branch (simulating remote change)
    local default_branch
    default_branch=$(_vault_default_branch)
    git -C "$CCO_USER_CONFIG_DIR" checkout "$default_branch" -q
    echo "# Default branch change" >> "$CCO_USER_CONFIG_DIR/global/.claude/CLAUDE.md"
    git -C "$CCO_USER_CONFIG_DIR" add -A
    git -C "$CCO_USER_CONFIG_DIR" commit -q -m "change on default"
    git -C "$CCO_USER_CONFIG_DIR" push origin "$default_branch" -q

    # Switch to profile and modify the same shared resource (creating a conflict)
    git -C "$CCO_USER_CONFIG_DIR" checkout "work" -q
    echo "# Profile branch change" >> "$CCO_USER_CONFIG_DIR/global/.claude/CLAUDE.md"
    git -C "$CCO_USER_CONFIG_DIR" add -A
    git -C "$CCO_USER_CONFIG_DIR" commit -q -m "change on profile"

    # Push from non-interactive context — conflict should be skipped with warning
    # (piping stdin makes it non-TTY)
    echo "" | run_cco vault push 2>/dev/null || true
    # The command may fail or succeed depending on remote push state,
    # but it should NOT hang waiting for input.
    # GAP: Interactive conflict resolution (L/R/M/D) cannot be tested in CI.
    # To test it, run manually: cco vault push (with conflicting shared resources).
}
