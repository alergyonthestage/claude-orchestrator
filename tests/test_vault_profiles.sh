#!/usr/bin/env bash
# tests/test_vault_profiles.sh — vault profile real isolation tests
#
# Verifies real git-level isolation behavior:
# - Profile create branches from main, inherits shared only
# - vault save commits + shared sync propagation
# - vault switch moves gitignored files, cleans ghost dirs
# - vault move/remove physically transfer/delete files via git
# - Profile delete rescues exclusive resources to main
# - Backward compatibility (no profiles = old sync behavior)

# ── Helper: set up vault with profiles infrastructure ─────────────────

_setup_vault_for_profiles() {
    local tmpdir="$1"
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    run_cco vault init
    # Set git identity for test commits
    git -C "$CCO_USER_CONFIG_DIR" config user.email "test@test.local"
    git -C "$CCO_USER_CONFIG_DIR" config user.name "Test"
    # Create a test project and save
    run_cco project create "test-proj"
    run_cco vault save "add test-proj" --yes
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

# ══════════════════════════════════════════════════════════════════════
# Profile Create (Design §6.7)
# ══════════════════════════════════════════════════════════════════════

test_profile_create_makes_branch() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    run_cco vault profile create "work"
    local branch
    branch=$(git -C "$CCO_USER_CONFIG_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)
    assert_equals "work" "$branch" "Expected to be on branch 'work'"
}

test_profile_create_writes_vault_profile_with_empty_lists() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    run_cco vault profile create "org-a"
    assert_file_exists "$CCO_USER_CONFIG_DIR/.vault-profile"
    assert_file_contains "$CCO_USER_CONFIG_DIR/.vault-profile" "profile: org-a"
    assert_file_contains "$CCO_USER_CONFIG_DIR/.vault-profile" "sync:"
    assert_file_contains "$CCO_USER_CONFIG_DIR/.vault-profile" "projects:"
    assert_file_contains "$CCO_USER_CONFIG_DIR/.vault-profile" "packs:"
}

test_profile_create_branches_from_main_not_current() {
    # Creating profile-B while on profile-A should branch from main, not profile-A
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)

    # Create profile-A and move test-proj to it (exclusive)
    run_cco vault profile create "profile-a"
    run_cco vault move project "test-proj" "$default_branch" --yes
    # test-proj is now ONLY on main, removed from profile-a
    # Now move it from main to profile-a
    run_cco vault switch "$default_branch"
    run_cco vault move project "test-proj" "profile-a" --yes
    # Now test-proj is exclusive to profile-a, not on main

    # While on main, create profile-B
    run_cco vault profile create "profile-b"

    # profile-B should NOT have test-proj (it was removed from main)
    [[ ! -d "$CCO_USER_CONFIG_DIR/projects/test-proj" ]] || \
        fail "profile-B should NOT have test-proj (exclusive to profile-a, not on main)"
}

test_profile_create_inherits_shared_resources() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"

    # Create profile — should inherit global/ and templates/
    run_cco vault profile create "work"

    [[ -d "$CCO_USER_CONFIG_DIR/global" ]] || fail "Expected global/ to be inherited"
}

test_profile_create_commits() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    run_cco vault profile create "work"
    local msg
    msg=$(git -C "$CCO_USER_CONFIG_DIR" log -1 --format=%s)
    [[ "$msg" == *"create profile"* ]] || fail "Expected commit message to contain 'create profile', got: $msg"
}

test_profile_create_shows_project_count_hint() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    run_cco vault profile create "work"
    # test-proj is still on main and inherited — hint should show it
    assert_output_contains "project(s)"
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

test_profile_create_rejects_duplicate() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    run_cco vault profile create "work"
    if run_cco vault profile create "work" 2>/dev/null; then
        fail "Expected duplicate name to be rejected"
    fi
}

# ══════════════════════════════════════════════════════════════════════
# Vault Save (Design §4.2-4.4)
# ══════════════════════════════════════════════════════════════════════

test_vault_save_commits_on_current_branch() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    run_cco vault profile create "work"

    echo "# Change" >> "$CCO_USER_CONFIG_DIR/global/.claude/CLAUDE.md"
    run_cco vault save "test change" --yes
    assert_output_contains "Saved on 'work'"

    local log
    log=$(git -C "$CCO_USER_CONFIG_DIR" log --oneline -1)
    echo "$log" | grep -qF "test change" || fail "Expected commit message in log"
}

test_vault_save_git_add_all_safe_with_real_isolation() {
    # With real isolation, git add -A is safe because other profiles' exclusive
    # files don't exist on this branch (§4.5)
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)

    # Create profile and move test-proj to it
    run_cco vault profile create "work"
    run_cco vault switch "$default_branch"
    run_cco vault move project "test-proj" "work" --yes

    # Switch to work profile and save — should only see work's files
    run_cco vault switch "work"
    echo "# Update" >> "$CCO_USER_CONFIG_DIR/projects/test-proj/.claude/CLAUDE.md"
    run_cco vault save "update proj" --yes
    assert_output_contains "Saved on 'work'"
}

test_vault_save_detects_shared_changes_and_propagates_to_main() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)

    # Create a profile
    run_cco vault profile create "work"

    # Modify a shared resource (global config) on the profile
    echo "# Shared change from work" >> "$CCO_USER_CONFIG_DIR/global/.claude/CLAUDE.md"
    run_cco vault save "update global" --yes

    # Verify the change was propagated to main
    local main_content
    main_content=$(git -C "$CCO_USER_CONFIG_DIR" show "$default_branch:global/.claude/CLAUDE.md" 2>/dev/null)
    echo "$main_content" | grep -qF "Shared change from work" || \
        fail "Expected shared change to be propagated to main"
}

test_vault_save_propagates_shared_to_other_profiles() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)

    # Create two profiles
    run_cco vault profile create "work"
    run_cco vault switch "$default_branch"
    run_cco vault profile create "personal"

    # Modify shared resource on personal
    echo "# Change from personal" >> "$CCO_USER_CONFIG_DIR/global/.claude/CLAUDE.md"
    run_cco vault save "shared update" --yes

    # Verify propagation to work profile
    local work_content
    work_content=$(git -C "$CCO_USER_CONFIG_DIR" show "work:global/.claude/CLAUDE.md" 2>/dev/null)
    echo "$work_content" | grep -qF "Change from personal" || \
        fail "Expected shared change to be propagated to 'work' profile"
}

test_vault_save_mergebase_prevents_false_conflicts() {
    # After syncing shared file, a second save should NOT produce conflicts (§8.5)
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)

    run_cco vault profile create "work"

    # First save with shared change
    echo "# First shared change" >> "$CCO_USER_CONFIG_DIR/global/.claude/CLAUDE.md"
    run_cco vault save "first shared" --yes

    # Second save with another shared change — should not conflict
    echo "# Second shared change" >> "$CCO_USER_CONFIG_DIR/global/.claude/CLAUDE.md"
    run_cco vault save "second shared" --yes
    assert_output_contains "Saved on 'work'"
}

test_vault_save_no_profiles_backward_compatible() {
    # Without profiles, save behaves identically to old vault sync (§4.4)
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"

    echo "# New file" > "$CCO_USER_CONFIG_DIR/global/.claude/test-file.md"
    run_cco vault save "add test file" --yes
    assert_output_contains "Saved"

    # Verify file was committed
    local committed
    committed=$(git -C "$CCO_USER_CONFIG_DIR" show HEAD --name-only --format= | grep "test-file.md" || true)
    [[ -n "$committed" ]] || fail "Expected test-file.md to be committed"
}

test_vault_save_no_changes() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    run_cco vault save "nothing" --yes
    assert_output_contains "up to date"
}

test_vault_sync_deprecated_alias_works() {
    # vault sync should still work as deprecated alias (§3.3)
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"

    echo "# Change" >> "$CCO_USER_CONFIG_DIR/global/.claude/CLAUDE.md"
    run_cco vault sync "via sync" --yes
    assert_output_contains "deprecated"
    assert_output_contains "Saved"
}

test_vault_save_dry_run() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"

    echo "# Change" > "$CCO_USER_CONFIG_DIR/global/.claude/rules/test.md"
    run_cco vault save --dry-run
    assert_output_contains "Dry run"

    # Should NOT be committed
    local status
    status=$(git -C "$CCO_USER_CONFIG_DIR" status --porcelain)
    [[ -n "$status" ]] || fail "File should still be uncommitted after dry run"
}

# ══════════════════════════════════════════════════════════════════════
# Vault Switch (Design §5.2-5.4)
# ══════════════════════════════════════════════════════════════════════

test_vault_switch_refuses_dirty_working_tree() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)
    run_cco vault profile create "work"

    # Create uncommitted change
    echo "# Dirty" >> "$CCO_USER_CONFIG_DIR/global/.claude/CLAUDE.md"

    if run_cco vault switch "$default_branch" 2>/dev/null; then
        fail "Expected switch to refuse with dirty working tree"
    fi
}

test_vault_switch_refuses_active_docker_sessions() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)
    run_cco vault profile create "work"

    # Mock docker with running container
    local mock_bin="$tmpdir/mock_bin"
    _mock_docker_with_containers "$mock_bin" "cc-test-proj-abc123"
    setup_mocks "$mock_bin"

    if run_cco vault switch "$default_branch" 2>/dev/null; then
        fail "Expected switch to refuse with active Docker sessions"
    fi
}

test_vault_switch_exclusive_projects_disappear_appear() {
    # Exclusive projects should physically disappear/appear on switch (§5.3)
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)

    # Create two profiles
    run_cco vault profile create "work"
    run_cco vault switch "$default_branch"
    run_cco vault profile create "personal"

    # Move test-proj to work, create another project for personal
    run_cco vault switch "$default_branch"
    run_cco vault move project "test-proj" "work" --yes

    run_cco project create "side-proj"
    run_cco vault save "add side-proj" --yes
    run_cco vault move project "side-proj" "personal" --yes

    # On main: neither exclusive project should exist
    [[ ! -d "$CCO_USER_CONFIG_DIR/projects/test-proj" ]] || \
        fail "test-proj should not exist on main (exclusive to work)"
    [[ ! -d "$CCO_USER_CONFIG_DIR/projects/side-proj" ]] || \
        fail "side-proj should not exist on main (exclusive to personal)"

    # Mock docker with no containers (avoid session check block)
    local mock_bin="$tmpdir/mock_bin"
    _mock_docker_no_containers "$mock_bin"
    setup_mocks "$mock_bin"

    # Switch to work — test-proj should appear
    run_cco vault switch "work"
    [[ -d "$CCO_USER_CONFIG_DIR/projects/test-proj" ]] || \
        fail "test-proj should appear after switching to work"
    [[ ! -d "$CCO_USER_CONFIG_DIR/projects/side-proj" ]] || \
        fail "side-proj should NOT appear on work profile"

    # Switch to personal — side-proj should appear, test-proj disappear
    run_cco vault switch "personal"
    [[ -d "$CCO_USER_CONFIG_DIR/projects/side-proj" ]] || \
        fail "side-proj should appear after switching to personal"
    [[ ! -d "$CCO_USER_CONFIG_DIR/projects/test-proj" ]] || \
        fail "test-proj should NOT appear on personal profile"
}

test_vault_switch_shared_resources_remain() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)
    run_cco vault profile create "work"

    # Mock docker
    local mock_bin="$tmpdir/mock_bin"
    _mock_docker_no_containers "$mock_bin"
    setup_mocks "$mock_bin"

    # global/ should exist on profile
    [[ -d "$CCO_USER_CONFIG_DIR/global" ]] || fail "global/ should exist on work"

    # Switch to main — global/ should still exist
    run_cco vault switch "$default_branch"
    [[ -d "$CCO_USER_CONFIG_DIR/global" ]] || fail "global/ should exist on main"

    # Switch back — still there
    run_cco vault switch "work"
    [[ -d "$CCO_USER_CONFIG_DIR/global" ]] || fail "global/ should exist after switching back"
}

test_vault_switch_to_main_shared_only() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)

    # Move project to profile (so main has no exclusive projects)
    run_cco vault profile create "work"
    run_cco vault switch "$default_branch"
    run_cco vault move project "test-proj" "work" --yes

    local mock_bin="$tmpdir/mock_bin"
    _mock_docker_no_containers "$mock_bin"
    setup_mocks "$mock_bin"

    # Switch to main
    run_cco vault switch "$default_branch"
    assert_output_contains "shared resources only"
}

test_vault_switch_stashes_portable_gitignored_files() {
    # Portable gitignored files (claude-state, secrets) should be stashed (§5.3)
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)

    # Create profile and move project
    run_cco vault profile create "work"
    run_cco vault switch "$default_branch"
    run_cco vault move project "test-proj" "work" --yes

    local mock_bin="$tmpdir/mock_bin"
    _mock_docker_no_containers "$mock_bin"
    setup_mocks "$mock_bin"

    # Switch to work and create portable gitignored files
    run_cco vault switch "work"
    mkdir -p "$CCO_USER_CONFIG_DIR/projects/test-proj/.cco/claude-state"
    echo "session data" > "$CCO_USER_CONFIG_DIR/projects/test-proj/.cco/claude-state/transcript.json"

    # Switch away — files should be stashed in shadow dir
    run_cco vault switch "$default_branch"
    [[ -f "$CCO_USER_CONFIG_DIR/.cco/profile-state/work/projects/test-proj/.cco/claude-state/transcript.json" ]] || \
        fail "Expected portable files to be stashed in shadow directory"

    # Switch back — files should be restored
    run_cco vault switch "work"
    [[ -f "$CCO_USER_CONFIG_DIR/projects/test-proj/.cco/claude-state/transcript.json" ]] || \
        fail "Expected portable files to be restored after switching back"
}

test_vault_switch_cleans_ghost_directories() {
    # Empty dirs left after git checkout should be cleaned (§5.3 step 5)
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)

    run_cco vault profile create "work"
    run_cco vault switch "$default_branch"
    run_cco vault move project "test-proj" "work" --yes

    local mock_bin="$tmpdir/mock_bin"
    _mock_docker_no_containers "$mock_bin"
    setup_mocks "$mock_bin"

    # After moving, main should not have projects/test-proj dir
    # (the move already cleaned it, but verify no ghost dirs after switch)
    run_cco vault switch "work"
    run_cco vault switch "$default_branch"

    # projects/test-proj/ should not exist as empty ghost directory
    [[ ! -d "$CCO_USER_CONFIG_DIR/projects/test-proj" ]] || \
        fail "Expected ghost directory projects/test-proj to be cleaned after switch"
}

test_vault_switch_noop_same() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    run_cco vault profile create "work"
    run_cco vault switch "work"
    assert_output_contains "Already on"
}

test_vault_switch_nonexistent_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    if run_cco vault switch "nonexistent" 2>/dev/null; then
        fail "Expected switch to nonexistent profile to fail"
    fi
}

test_vault_switch_vault_profile_changes() {
    # .vault-profile is tracked per branch — switching should change file
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)
    run_cco vault profile create "work"
    assert_file_exists "$CCO_USER_CONFIG_DIR/.vault-profile"

    local mock_bin="$tmpdir/mock_bin"
    _mock_docker_no_containers "$mock_bin"
    setup_mocks "$mock_bin"

    run_cco vault switch "$default_branch"
    # On default branch, .vault-profile should NOT exist
    [[ ! -f "$CCO_USER_CONFIG_DIR/.vault-profile" ]] || \
        fail ".vault-profile should not exist on default branch"

    run_cco vault switch "work"
    assert_file_exists "$CCO_USER_CONFIG_DIR/.vault-profile"
    assert_file_contains "$CCO_USER_CONFIG_DIR/.vault-profile" "profile: work"
}

# ══════════════════════════════════════════════════════════════════════
# Vault Move (Design §6.1-6.2)
# ══════════════════════════════════════════════════════════════════════

test_vault_move_project_copies_to_target_branch() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)

    run_cco vault profile create "work"
    run_cco vault switch "$default_branch"

    # Move test-proj from main to work
    run_cco vault move project "test-proj" "work" --yes
    assert_output_contains "Moved"

    # Verify project exists on target branch
    local target_tree
    target_tree=$(git -C "$CCO_USER_CONFIG_DIR" ls-tree "work" -- "projects/test-proj/" 2>/dev/null)
    [[ -n "$target_tree" ]] || fail "Expected project to exist on target branch"
}

test_vault_move_project_removes_from_source() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)

    run_cco vault profile create "work"
    run_cco vault switch "$default_branch"

    run_cco vault move project "test-proj" "work" --yes

    # Project should be removed from source branch (main)
    [[ ! -d "$CCO_USER_CONFIG_DIR/projects/test-proj" ]] || \
        fail "Expected project to be removed from source branch"

    local source_tree
    source_tree=$(git -C "$CCO_USER_CONFIG_DIR" ls-tree HEAD -- "projects/test-proj/" 2>/dev/null)
    [[ -z "$source_tree" ]] || fail "Expected project to be git rm-ed from source"
}

test_vault_move_updates_vault_profile_on_target() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)

    run_cco vault profile create "work"
    run_cco vault switch "$default_branch"

    run_cco vault move project "test-proj" "work" --yes

    # Verify .vault-profile on target lists the project
    local target_profile
    target_profile=$(git -C "$CCO_USER_CONFIG_DIR" show "work:.vault-profile" 2>/dev/null)
    echo "$target_profile" | grep -qF "test-proj" || \
        fail "Expected test-proj in target's .vault-profile"
}

test_vault_move_portable_gitignored_to_shadow() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)

    # Create portable gitignored files
    mkdir -p "$CCO_USER_CONFIG_DIR/projects/test-proj/.cco/claude-state"
    echo "transcript" > "$CCO_USER_CONFIG_DIR/projects/test-proj/.cco/claude-state/data.json"

    run_cco vault profile create "work"
    run_cco vault switch "$default_branch"

    run_cco vault move project "test-proj" "work" --yes

    # Portable files should be in shadow directory for target
    [[ -f "$CCO_USER_CONFIG_DIR/.cco/profile-state/work/projects/test-proj/.cco/claude-state/data.json" ]] || \
        fail "Expected portable files to be moved to shadow directory"
}

test_vault_move_refuses_same_branch() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)

    if run_cco vault move project "test-proj" "$default_branch" --yes 2>/dev/null; then
        fail "Expected move to same branch to be rejected"
    fi
}

test_vault_move_refuses_nonexistent_project() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"

    run_cco vault profile create "work"
    if run_cco vault move project "nonexistent" "main" --yes 2>/dev/null; then
        fail "Expected move of non-existent project to fail"
    fi
}

test_vault_move_pack() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)

    # Create a pack and save
    run_cco pack create "my-pack"
    run_cco vault save "add pack" --yes

    run_cco vault profile create "work"
    run_cco vault switch "$default_branch"

    # Move pack to work
    run_cco vault move pack "my-pack" "work" --yes
    assert_output_contains "Moved"

    # Verify pack exists on target
    local target_tree
    target_tree=$(git -C "$CCO_USER_CONFIG_DIR" ls-tree "work" -- "packs/my-pack/" 2>/dev/null)
    [[ -n "$target_tree" ]] || fail "Expected pack to exist on target branch"
}

# ══════════════════════════════════════════════════════════════════════
# Vault Remove (Design §6.3-6.4)
# ══════════════════════════════════════════════════════════════════════

test_vault_remove_project_deletes_from_branch() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)

    # Create profile, move project to it
    run_cco vault profile create "work"
    run_cco vault switch "$default_branch"
    run_cco vault move project "test-proj" "work" --yes

    local mock_bin="$tmpdir/mock_bin"
    _mock_docker_no_containers "$mock_bin"
    setup_mocks "$mock_bin"

    run_cco vault switch "work"

    # Remove from profile
    run_cco vault remove project "test-proj" --yes
    assert_output_contains "Removed"

    # Project should be gone from this branch
    [[ ! -d "$CCO_USER_CONFIG_DIR/projects/test-proj" ]] || \
        fail "Expected project directory to be removed"
}

test_vault_remove_creates_backup_when_last_copy() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)

    # Move project to profile (so it's exclusive — only copy)
    run_cco vault profile create "work"
    run_cco vault switch "$default_branch"
    run_cco vault move project "test-proj" "work" --yes

    local mock_bin="$tmpdir/mock_bin"
    _mock_docker_no_containers "$mock_bin"
    setup_mocks "$mock_bin"

    run_cco vault switch "work"

    # Remove last copy — should create backup
    run_cco vault remove project "test-proj" --yes
    assert_output_contains "Backup saved"

    # Verify backup exists in .cco/backups/
    local backup_count
    backup_count=$(find "$CCO_USER_CONFIG_DIR/.cco/backups" -name "project-test-proj-*.tar.gz" 2>/dev/null | wc -l | tr -d ' ')
    [[ "$backup_count" -gt 0 ]] || fail "Expected backup file in .cco/backups/"
}

test_vault_remove_no_backup_when_other_copies_exist() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"

    # test-proj exists on main — removing from main is NOT the last copy
    # ...actually it is the only copy if no profiles. Let's create a profile
    # and keep on main too.
    run_cco vault profile create "work"
    # Profile create branches from main, so test-proj exists on both main and work

    # Remove from work profile (main still has it)
    run_cco vault remove project "test-proj" --yes
    assert_output_contains "Removed"
    assert_output_not_contains "Backup"
}

test_vault_remove_updates_vault_profile() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"

    run_cco vault profile create "work"
    # Move project to make it exclusive to work
    run_cco vault move project "test-proj" "main" --yes
    # Now move it back from main to work
    run_cco vault switch "main"
    run_cco vault move project "test-proj" "work" --yes

    local mock_bin="$tmpdir/mock_bin"
    _mock_docker_no_containers "$mock_bin"
    setup_mocks "$mock_bin"

    run_cco vault switch "work"
    # Verify it's in .vault-profile
    assert_file_contains "$CCO_USER_CONFIG_DIR/.vault-profile" "test-proj"

    run_cco vault remove project "test-proj" --yes

    # .vault-profile should no longer list it
    assert_file_not_contains "$CCO_USER_CONFIG_DIR/.vault-profile" "test-proj"
}

test_vault_remove_pack() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"

    run_cco pack create "my-pack"
    run_cco vault save "add pack" --yes

    run_cco vault remove pack "my-pack" --yes
    assert_output_contains "Removed"
    [[ ! -d "$CCO_USER_CONFIG_DIR/packs/my-pack" ]] || \
        fail "Expected pack directory to be removed"
}

# ══════════════════════════════════════════════════════════════════════
# Profile Delete (Design §6.6)
# ══════════════════════════════════════════════════════════════════════

test_profile_delete_moves_exclusive_to_main() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)

    # Create profile and move project to it
    run_cco vault profile create "to-delete"
    run_cco vault switch "$default_branch"
    run_cco vault move project "test-proj" "to-delete" --yes

    # Delete the profile
    run_cco vault profile delete "to-delete" --yes

    # Branch should be gone
    if git -C "$CCO_USER_CONFIG_DIR" rev-parse --verify "to-delete" >/dev/null 2>&1; then
        fail "Expected branch 'to-delete' to be deleted"
    fi

    # Project should be rescued to main
    local proj_files
    proj_files=$(git -C "$CCO_USER_CONFIG_DIR" ls-tree -r HEAD --name-only -- "projects/test-proj/" 2>/dev/null)
    [[ -n "$proj_files" ]] || \
        fail "Expected project 'test-proj' files to be rescued to main"

    [[ -d "$CCO_USER_CONFIG_DIR/projects/test-proj" ]] || \
        fail "Expected projects/test-proj directory to exist on main after delete"
}

test_profile_delete_cleans_shadow_directory() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)

    run_cco vault profile create "to-delete"

    # Create shadow directory content
    mkdir -p "$CCO_USER_CONFIG_DIR/.cco/profile-state/to-delete/projects/test-proj/.cco"
    echo "state" > "$CCO_USER_CONFIG_DIR/.cco/profile-state/to-delete/projects/test-proj/.cco/meta"

    run_cco vault switch "$default_branch"
    run_cco vault profile delete "to-delete" --yes

    # Shadow directory should be cleaned
    [[ ! -d "$CCO_USER_CONFIG_DIR/.cco/profile-state/to-delete" ]] || \
        fail "Expected shadow directory for deleted profile to be cleaned"
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

test_profile_delete_removes_branch() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)
    run_cco vault profile create "to-delete"
    run_cco vault switch "$default_branch"
    run_cco vault profile delete "to-delete" --yes

    if git -C "$CCO_USER_CONFIG_DIR" rev-parse --verify "to-delete" >/dev/null 2>&1; then
        fail "Expected branch 'to-delete' to be removed"
    fi
}

# ══════════════════════════════════════════════════════════════════════
# Shared Sync (Design §8)
# ══════════════════════════════════════════════════════════════════════

test_shared_sync_profile_to_main_to_others() {
    # Full hub-and-spoke sync: profile→main→other profiles (§8.1)
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)

    # Create two profiles
    run_cco vault profile create "work"
    run_cco vault switch "$default_branch"
    run_cco vault profile create "personal"

    # Modify shared resource on personal
    echo "# From personal" >> "$CCO_USER_CONFIG_DIR/global/.claude/CLAUDE.md"
    run_cco vault save "shared edit" --yes

    # Check main has the change
    local main_content
    main_content=$(git -C "$CCO_USER_CONFIG_DIR" show "$default_branch:global/.claude/CLAUDE.md" 2>/dev/null)
    echo "$main_content" | grep -qF "From personal" || \
        fail "Expected shared change on main"

    # Check work profile also got the change
    local work_content
    work_content=$(git -C "$CCO_USER_CONFIG_DIR" show "work:global/.claude/CLAUDE.md" 2>/dev/null)
    echo "$work_content" | grep -qF "From personal" || \
        fail "Expected shared change propagated to work profile"
}

test_shared_sync_main_to_profiles_on_save() {
    # Changes on main propagate to all profiles (§4.3)
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)

    run_cco vault profile create "work"
    run_cco vault switch "$default_branch"

    # Modify shared resource on main
    echo "# Main change" >> "$CCO_USER_CONFIG_DIR/global/.claude/CLAUDE.md"
    run_cco vault save "update from main" --yes

    # Verify propagation to work profile
    local work_content
    work_content=$(git -C "$CCO_USER_CONFIG_DIR" show "work:global/.claude/CLAUDE.md" 2>/dev/null)
    echo "$work_content" | grep -qF "Main change" || \
        fail "Expected main change to propagate to work profile"
}

test_shared_sync_exclusive_files_not_propagated() {
    # Exclusive project changes should NOT be synced to main or other profiles
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)

    # Move project to work (exclusive)
    run_cco vault profile create "work"
    run_cco vault switch "$default_branch"
    run_cco vault move project "test-proj" "work" --yes

    local mock_bin="$tmpdir/mock_bin"
    _mock_docker_no_containers "$mock_bin"
    setup_mocks "$mock_bin"

    run_cco vault switch "work"

    # Modify the exclusive project
    echo "# Exclusive change" >> "$CCO_USER_CONFIG_DIR/projects/test-proj/.claude/CLAUDE.md"
    run_cco vault save "update exclusive" --yes

    # main should NOT have test-proj
    local main_tree
    main_tree=$(git -C "$CCO_USER_CONFIG_DIR" ls-tree "$default_branch" -- "projects/test-proj/" 2>/dev/null)
    [[ -z "$main_tree" ]] || \
        fail "Expected exclusive project NOT to be synced to main"
}

test_shared_sync_mergebase_prevents_false_conflicts_across_saves() {
    # Same file modified on same profile across two saves doesn't conflict (§8.5)
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)

    run_cco vault profile create "work"

    # Save 1: modify shared file
    echo "# Edit 1" >> "$CCO_USER_CONFIG_DIR/global/.claude/CLAUDE.md"
    run_cco vault save "edit 1" --yes

    # Save 2: modify same shared file again
    echo "# Edit 2" >> "$CCO_USER_CONFIG_DIR/global/.claude/CLAUDE.md"
    run_cco vault save "edit 2" --yes
    assert_output_contains "Saved"

    # Both edits should be on main
    local main_content
    main_content=$(git -C "$CCO_USER_CONFIG_DIR" show "$default_branch:global/.claude/CLAUDE.md" 2>/dev/null)
    echo "$main_content" | grep -qF "Edit 1" || fail "Expected Edit 1 on main"
    echo "$main_content" | grep -qF "Edit 2" || fail "Expected Edit 2 on main"
}

# ══════════════════════════════════════════════════════════════════════
# Profile List, Show, Rename
# ══════════════════════════════════════════════════════════════════════

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

# ══════════════════════════════════════════════════════════════════════
# Vault Status with Profiles
# ══════════════════════════════════════════════════════════════════════

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

# ══════════════════════════════════════════════════════════════════════
# Backward Compatibility
# ══════════════════════════════════════════════════════════════════════

test_vault_save_without_profiles_is_old_sync() {
    # vault save with no profiles: identical to old vault sync (§4.4)
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"

    echo "# Change A" > "$CCO_USER_CONFIG_DIR/global/.claude/rules/a.md"
    mkdir -p "$CCO_USER_CONFIG_DIR/packs/test-pack"
    echo "name: test-pack" > "$CCO_USER_CONFIG_DIR/packs/test-pack/pack.yml"

    run_cco vault save "mixed changes" --yes
    assert_output_contains "Saved"

    # All changes should be committed on the same branch
    local committed
    committed=$(git -C "$CCO_USER_CONFIG_DIR" show HEAD --name-only --format=)
    echo "$committed" | grep -qF "rules/a.md" || fail "Expected rules/a.md committed"
    echo "$committed" | grep -qF "test-pack" || fail "Expected test-pack committed"
}

test_vault_operations_work_without_profiles() {
    # All base vault operations should work without any profiles
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"

    # diff
    run_cco vault diff
    assert_output_contains "No uncommitted"

    # status
    run_cco vault status
    assert_output_contains "initialized"

    # log
    run_cco vault log
    # Should have at least the initial commit
    local commit_count
    commit_count=$(git -C "$CCO_USER_CONFIG_DIR" rev-list --count HEAD 2>/dev/null)
    [[ "$commit_count" -ge 1 ]] || fail "Expected at least 1 commit"
}

# ══════════════════════════════════════════════════════════════════════
# Help Commands
# ══════════════════════════════════════════════════════════════════════

test_vault_profile_help() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco vault profile --help
    assert_output_contains "create"
    assert_output_contains "list"
    assert_output_contains "switch"
}

test_vault_help_includes_save() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco vault --help
    assert_output_contains "save"
    assert_output_contains "profile"
}

test_vault_save_help() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco vault save --help
    assert_output_contains "save"
}

test_vault_move_help() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco vault move --help
    assert_output_contains "project"
    assert_output_contains "pack"
}

test_vault_remove_help() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco vault remove --help
    assert_output_contains "project"
    assert_output_contains "pack"
}

# ══════════════════════════════════════════════════════════════════════
# Push/Pull with Profiles
# ══════════════════════════════════════════════════════════════════════

test_vault_push_with_profile_syncs_shared() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"

    # Create a bare remote
    local bare="$tmpdir/remote.git"
    git init --bare -q "$bare"
    run_cco vault remote add origin "$bare"
    run_cco vault push

    # Create a profile
    run_cco vault profile create "work"

    # Modify shared resource
    echo "# Profile update" >> "$CCO_USER_CONFIG_DIR/global/.claude/CLAUDE.md"
    run_cco vault save "update shared" --yes

    # Push (should sync shared to default branch)
    run_cco vault push
    assert_output_contains "Pushed to"

    # Verify shared change on default branch
    local default_branch
    default_branch=$(_vault_default_branch)
    local shared_content
    shared_content=$(git -C "$CCO_USER_CONFIG_DIR" show "$default_branch:global/.claude/CLAUDE.md" 2>/dev/null)
    echo "$shared_content" | grep -qF "Profile update" || \
        fail "Expected shared resource synced to default branch after push"
}

test_vault_pull_with_profile_syncs_shared() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"

    # Create bare remote and push
    local bare="$tmpdir/remote.git"
    git init --bare -q "$bare"
    run_cco vault remote add origin "$bare"
    run_cco vault push

    # Create profile and push
    run_cco vault profile create "work"
    run_cco vault push

    # Simulate remote change via second clone
    local default_branch
    default_branch=$(_vault_default_branch)
    local clone2="$tmpdir/clone2"
    git clone -q "$bare" "$clone2"
    git -C "$clone2" config user.email "test@test.local"
    git -C "$clone2" config user.name "Test"
    echo "# Remote change" >> "$clone2/global/.claude/CLAUDE.md"
    git -C "$clone2" add -A
    git -C "$clone2" commit -q -m "remote: update shared"
    git -C "$clone2" push origin "$default_branch" -q

    # Switch to profile and pull
    git -C "$CCO_USER_CONFIG_DIR" checkout "work" -q

    run_cco vault pull

    # Verify shared resource synced
    local content
    content=$(cat "$CCO_USER_CONFIG_DIR/global/.claude/CLAUDE.md" 2>/dev/null)
    echo "$content" | grep -qF "Remote change" || \
        fail "Expected shared resource synced from default onto profile branch"
}
