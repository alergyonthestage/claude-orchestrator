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
    # New profiles are EMPTY — projects are git rm-ed at creation (§6.7)
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)

    # test-proj exists on main. Create profile "work".
    run_cco vault profile create "work"

    # work should NOT have test-proj (git rm-ed at profile creation)
    [[ ! -d "$CCO_USER_CONFIG_DIR/projects/test-proj" ]] || \
        fail "New profile should NOT have test-proj (empty profile model)"

    # main should still have test-proj
    local main_tree
    main_tree=$(git -C "$CCO_USER_CONFIG_DIR" show "$default_branch:projects/test-proj/project.yml" 2>/dev/null) || true
    [[ -n "$main_tree" ]] || fail "main should still have test-proj"
}

test_profile_create_inherits_shared_resources() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"

    # Create profile — should inherit global/ and templates/
    run_cco vault profile create "work"

    [[ -d "$CCO_USER_CONFIG_DIR/global" ]] || fail "Expected global/ to be inherited"
    # Projects should NOT be inherited (empty profile model)
    [[ ! -d "$CCO_USER_CONFIG_DIR/projects/test-proj" ]] || \
        fail "Projects should not be inherited by new profiles"
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
    # New profile is empty — hint should suggest vault move project
    assert_output_contains "vault move project"
}

test_profile_create_cleans_gitignored_remnants() {
    # Gitignored files (docker-compose.yml, managed/) must be cleaned from
    # projects removed during profile creation
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"

    # Simulate runtime artifacts (created by cco start, gitignored)
    mkdir -p "$CCO_USER_CONFIG_DIR/projects/test-proj/.cco/managed"
    echo '{}' > "$CCO_USER_CONFIG_DIR/projects/test-proj/.cco/docker-compose.yml"
    echo '{}' > "$CCO_USER_CONFIG_DIR/projects/test-proj/.cco/managed/policy.json"
    mkdir -p "$CCO_USER_CONFIG_DIR/projects/test-proj/.tmp"
    echo 'x' > "$CCO_USER_CONFIG_DIR/projects/test-proj/.tmp/scratch"

    run_cco vault profile create "work"

    # All project remnants should be gone
    [[ ! -d "$CCO_USER_CONFIG_DIR/projects/test-proj" ]] || \
        fail "Gitignored remnants should be cleaned after profile create"
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

    # Verify exclusive project is NOT on main
    git -C "$CCO_USER_CONFIG_DIR" show "$default_branch:projects/test-proj/project.yml" 2>/dev/null && \
        fail "Exclusive project should not be on main"
    true  # ensure last command doesn't cause set -e failure
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

    # Docker mock for switches
    local mock_bin="$tmpdir/mock_bin"
    _mock_docker_no_containers "$mock_bin"
    setup_mocks "$mock_bin"

    run_cco vault profile create "work"

    # First save with shared change
    echo "# First shared change" >> "$CCO_USER_CONFIG_DIR/global/.claude/CLAUDE.md"
    run_cco vault save "first shared" --yes

    # Second save with another shared change — should not conflict
    echo "# Second shared change" >> "$CCO_USER_CONFIG_DIR/global/.claude/CLAUDE.md"
    run_cco vault save "second shared" --yes
    assert_output_contains "Saved on 'work'"

    # Create a second profile and verify shared changes propagated correctly
    run_cco vault switch "$default_branch"
    run_cco vault profile create "personal"
    local personal_content
    personal_content=$(cat "$CCO_USER_CONFIG_DIR/global/.claude/CLAUDE.md")
    echo "$personal_content" | grep -qF "First shared change" || \
        fail "Expected first shared change to propagate to second profile"
    echo "$personal_content" | grep -qF "Second shared change" || \
        fail "Expected second shared change to propagate to second profile"
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

    # Verify no project directories on main (test-proj was moved to work)
    [[ ! -d "$CCO_USER_CONFIG_DIR/projects/test-proj" ]] || \
        fail "test-proj should not exist on main after being moved to work"
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

    # Docker mock for vault switch
    local mock_bin="$tmpdir/mock_bin"
    _mock_docker_no_containers "$mock_bin"
    setup_mocks "$mock_bin"

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

    # Verify pack was git rm-ed from source branch
    local source_tree
    source_tree=$(git -C "$CCO_USER_CONFIG_DIR" ls-tree "$default_branch" -- "packs/my-pack/" 2>/dev/null)
    [[ -z "$source_tree" ]] || fail "Expected pack to be git rm-ed from source branch"

    # Verify .vault-profile on target lists the pack
    local target_profile
    target_profile=$(git -C "$CCO_USER_CONFIG_DIR" show "work:.vault-profile" 2>/dev/null)
    echo "$target_profile" | grep -qF "my-pack" || \
        fail "Expected my-pack in target's .vault-profile"
}

test_vault_move_shared_pack_from_target_profile() {
    # Moving a shared pack while on the target profile should auto-detect main as source
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)

    local mock_bin="$tmpdir/mock_bin"
    _mock_docker_no_containers "$mock_bin"
    setup_mocks "$mock_bin"

    # Create a pack (shared on main) and save
    run_cco pack create "shared-pack"
    run_cco vault save "add pack" --yes

    # Create profile and stay on it
    run_cco vault profile create "work"

    # Move shared pack to work while ON work — should detect source=main
    run_cco vault move pack "shared-pack" "work" --yes
    assert_output_contains "Moved"

    # Pack should be exclusive to work now
    local vp
    vp=$(cat "$CCO_USER_CONFIG_DIR/.vault-profile" 2>/dev/null)
    echo "$vp" | grep -qF "shared-pack" || fail "Expected pack in work's .vault-profile"
}

test_vault_move_shared_pack_cleans_other_profiles() {
    # When a shared pack becomes exclusive, it must be removed from all other profiles
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)

    local mock_bin="$tmpdir/mock_bin"
    _mock_docker_no_containers "$mock_bin"
    setup_mocks "$mock_bin"

    # Create shared pack
    run_cco pack create "shared-pack"
    run_cco vault save "add pack" --yes

    # Create two profiles (shared pack syncs to both)
    run_cco vault profile create "work"
    run_cco vault switch "$default_branch"
    run_cco vault profile create "personal"
    run_cco vault switch "$default_branch"

    # Move pack from main to work (making it exclusive)
    run_cco vault move pack "shared-pack" "work" --yes

    # Pack should NOT exist on personal anymore
    local personal_tree
    personal_tree=$(git -C "$CCO_USER_CONFIG_DIR" ls-tree "personal" -- "packs/shared-pack/" 2>/dev/null)
    [[ -z "$personal_tree" ]] || fail "Shared pack should be removed from personal after move to work"

    # Pack should NOT exist on main anymore
    local main_tree
    main_tree=$(git -C "$CCO_USER_CONFIG_DIR" ls-tree "$default_branch" -- "packs/shared-pack/" 2>/dev/null)
    [[ -z "$main_tree" ]] || fail "Shared pack should be removed from main after move to work"
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
    # Packs are shared — they exist on all branches.
    # Removing a shared pack from one branch should NOT create a backup if
    # other branches still have it.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)

    # Create a pack and save (shared — on main)
    run_cco pack create "shared-pack"
    run_cco vault save "add pack" --yes

    # Create profile (pack is shared, exists on both branches)
    run_cco vault profile create "work"

    # Move pack to make it exclusive on work, then check removal from main
    # Actually: just verify pack exists on both branches (shared resource)
    local main_tree
    main_tree=$(git -C "$CCO_USER_CONFIG_DIR" ls-tree "$default_branch" -- "packs/shared-pack/" 2>/dev/null)
    [[ -n "$main_tree" ]] || fail "Pack should exist on main"

    # Remove from work — main still has it, so no backup needed
    run_cco vault remove pack "shared-pack" --yes
    assert_output_contains "Removed"
    assert_output_not_contains "Backup"
}

test_vault_remove_updates_vault_profile() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)

    # Docker mock must be set up before any vault switch call
    local mock_bin="$tmpdir/mock_bin"
    _mock_docker_no_containers "$mock_bin"
    setup_mocks "$mock_bin"

    # Create profile (empty), switch to main, move test-proj to work
    run_cco vault profile create "work"
    run_cco vault switch "$default_branch"
    run_cco vault move project "test-proj" "work" --yes

    # Switch to work and verify it's in .vault-profile
    run_cco vault switch "work"
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

    # Delete without --force should fail (has resources)
    if run_cco vault profile delete "to-delete" --yes 2>/dev/null; then
        fail "Expected delete of non-empty profile to be rejected without --force"
    fi

    # Delete with --force should work
    run_cco vault profile delete "to-delete" --yes --force

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
# Empty Profile Model (Design §6.7)
# ══════════════════════════════════════════════════════════════════════

test_profile_create_empty_no_projects_from_main() {
    # New profiles are created EMPTY — no projects from main (§6.7)
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)

    # Create a second project on main
    run_cco project create "second-proj"
    run_cco vault save "add second-proj" --yes

    # Create profile — should have zero projects
    run_cco vault profile create "team"

    [[ ! -d "$CCO_USER_CONFIG_DIR/projects/test-proj" ]] || \
        fail "test-proj should not exist on new profile"
    [[ ! -d "$CCO_USER_CONFIG_DIR/projects/second-proj" ]] || \
        fail "second-proj should not exist on new profile"

    # Both projects should still be on main
    local main_proj1 main_proj2
    main_proj1=$(git -C "$CCO_USER_CONFIG_DIR" ls-tree "$default_branch" -- "projects/test-proj/" 2>/dev/null)
    main_proj2=$(git -C "$CCO_USER_CONFIG_DIR" ls-tree "$default_branch" -- "projects/second-proj/" 2>/dev/null)
    [[ -n "$main_proj1" ]] || fail "test-proj should still be on main"
    [[ -n "$main_proj2" ]] || fail "second-proj should still be on main"
}

# ══════════════════════════════════════════════════════════════════════
# Move — Extended Scenarios (Design §6.1-6.2)
# ══════════════════════════════════════════════════════════════════════

test_vault_move_project_to_main() {
    # Move project from profile back to main
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)

    local mock_bin="$tmpdir/mock_bin"
    _mock_docker_no_containers "$mock_bin"
    setup_mocks "$mock_bin"

    # Move test-proj from main to work
    run_cco vault profile create "work"
    run_cco vault switch "$default_branch"
    run_cco vault move project "test-proj" "work" --yes

    # Now move it back from work to main
    run_cco vault switch "work"
    run_cco vault move project "test-proj" "$default_branch" --yes
    assert_output_contains "Moved"

    # Verify project exists on main
    local main_tree
    main_tree=$(git -C "$CCO_USER_CONFIG_DIR" ls-tree "$default_branch" -- "projects/test-proj/" 2>/dev/null)
    [[ -n "$main_tree" ]] || fail "Expected test-proj on main after move back"

    # Verify project removed from work
    [[ ! -d "$CCO_USER_CONFIG_DIR/projects/test-proj" ]] || \
        fail "test-proj should be removed from work after move to main"
}

test_vault_move_project_profile_to_profile() {
    # Move project from one profile to another
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)

    local mock_bin="$tmpdir/mock_bin"
    _mock_docker_no_containers "$mock_bin"
    setup_mocks "$mock_bin"

    # Create two profiles
    run_cco vault profile create "work"
    run_cco vault switch "$default_branch"
    run_cco vault profile create "personal"
    run_cco vault switch "$default_branch"

    # Move test-proj from main to work
    run_cco vault move project "test-proj" "work" --yes

    # Now move from work to personal
    run_cco vault switch "work"
    run_cco vault move project "test-proj" "personal" --yes
    assert_output_contains "Moved"

    # Verify on personal
    local personal_tree
    personal_tree=$(git -C "$CCO_USER_CONFIG_DIR" ls-tree "personal" -- "projects/test-proj/" 2>/dev/null)
    [[ -n "$personal_tree" ]] || fail "Expected test-proj on personal"

    # Verify removed from work
    local work_tree
    work_tree=$(git -C "$CCO_USER_CONFIG_DIR" ls-tree "work" -- "projects/test-proj/" 2>/dev/null)
    [[ -z "$work_tree" ]] || fail "test-proj should be removed from work"
}

test_vault_move_to_nonexistent_target() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"

    if run_cco vault move project "test-proj" "nonexistent-profile" --yes 2>/dev/null; then
        fail "Expected move to nonexistent target to fail"
    fi
}

test_vault_move_from_noncurrent_branch() {
    # User is on target profile, resource is on main — move should auto-detect source
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)

    run_cco vault profile create "cave"
    # We're now on profile "cave" — project is on main

    # Move project from main to cave (auto-detect source)
    run_cco vault move project "test-proj" "cave" --yes
    assert_output_contains "Moved"

    # Verify project exists on target branch
    local target_tree
    target_tree=$(git -C "$CCO_USER_CONFIG_DIR" ls-tree "cave" -- "projects/test-proj/" 2>/dev/null)
    [[ -n "$target_tree" ]] || fail "Expected project on cave branch"

    # Verify removed from main
    local main_tree
    main_tree=$(git -C "$CCO_USER_CONFIG_DIR" ls-tree "$default_branch" -- "projects/test-proj/" 2>/dev/null)
    [[ -z "$main_tree" ]] || fail "Expected project removed from main"

    # We should still be on cave
    local current
    current=$(git -C "$CCO_USER_CONFIG_DIR" rev-parse --abbrev-ref HEAD)
    [[ "$current" == "cave" ]] || fail "Expected to remain on cave, got $current"
}

test_vault_move_preserves_unaccounted_files() {
    # If stash misses a file (e.g., new file type), move must NOT delete it
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)

    # Create an unexpected file in the project (simulates future cco feature)
    echo "important" > "$CCO_USER_CONFIG_DIR/projects/test-proj/custom-data.txt"

    run_cco vault profile create "work"

    # Move project from main while on work
    run_cco vault move project "test-proj" "work" --yes
    assert_output_contains "Moved"

    # The unaccounted file should survive (not deleted by rm -rf)
    # Switch to work to see the project
    local mock_bin="$tmpdir/mock_bin"
    _mock_docker_no_containers "$mock_bin"
    setup_mocks "$mock_bin"
    run_cco vault switch "$default_branch"

    # On main: the unaccounted file should be preserved (safe_remove skipped it)
    [[ -f "$CCO_USER_CONFIG_DIR/projects/test-proj/custom-data.txt" ]] || \
        fail "Unaccounted file should be preserved — safe_remove must not delete unknown files"
}

test_vault_move_transfers_shadow_portable_files() {
    # When moving from main after profile create, portable files are in
    # main's shadow (stashed during create). Move must transfer them.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)

    # Create portable files for test-proj on main
    echo "SECRET=value" > "$CCO_USER_CONFIG_DIR/projects/test-proj/secrets.env"
    mkdir -p "$CCO_USER_CONFIG_DIR/projects/test-proj/.cco/claude-state"
    echo '{}' > "$CCO_USER_CONFIG_DIR/projects/test-proj/.cco/claude-state/data.json"

    # Create profile — stashes main's portable files to shadow
    run_cco vault profile create "work"

    # Move from main while on work — secrets are in main's shadow
    run_cco vault move project "test-proj" "work" --yes

    # Main's shadow should be cleaned
    [[ ! -d "$CCO_USER_CONFIG_DIR/.cco/profile-state/main/projects/test-proj" ]] || \
        fail "Expected main's shadow for test-proj to be cleaned after move"

    # Target shadow should have the portable files
    [[ -f "$CCO_USER_CONFIG_DIR/.cco/profile-state/work/projects/test-proj/secrets.env" ]] || \
        fail "Expected secrets.env in work's shadow"
    [[ -d "$CCO_USER_CONFIG_DIR/.cco/profile-state/work/projects/test-proj/.cco/claude-state" ]] || \
        fail "Expected claude-state in work's shadow"

    # Switch to main — test-proj should NOT reappear
    local mock_bin="$tmpdir/mock_bin"
    _mock_docker_no_containers "$mock_bin"
    setup_mocks "$mock_bin"
    run_cco vault switch "$default_branch"

    [[ ! -f "$CCO_USER_CONFIG_DIR/projects/test-proj/secrets.env" ]] || \
        fail "secrets.env should NOT be restored on main after move to work"
}

# ══════════════════════════════════════════════════════════════════════
# Remove — Shadow Directory Cleanup
# ══════════════════════════════════════════════════════════════════════

test_vault_remove_cleans_shadow_dir() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)

    local mock_bin="$tmpdir/mock_bin"
    _mock_docker_no_containers "$mock_bin"
    setup_mocks "$mock_bin"

    # Move test-proj to work
    run_cco vault profile create "work"
    run_cco vault switch "$default_branch"
    run_cco vault move project "test-proj" "work" --yes

    # Switch to work, create portable files, then switch away to populate shadow
    run_cco vault switch "work"
    mkdir -p "$CCO_USER_CONFIG_DIR/projects/test-proj/.cco/claude-state"
    echo "session" > "$CCO_USER_CONFIG_DIR/projects/test-proj/.cco/claude-state/transcript.json"
    run_cco vault switch "$default_branch"

    # Shadow dir should exist after stash
    [[ -d "$CCO_USER_CONFIG_DIR/.cco/profile-state/work/projects/test-proj" ]] || \
        fail "Expected shadow directory to exist after stash"

    # Switch back and remove the project
    run_cco vault switch "work"
    run_cco vault remove project "test-proj" --yes

    # Shadow dir entry should be cleaned
    [[ ! -d "$CCO_USER_CONFIG_DIR/.cco/profile-state/work/projects/test-proj" ]] || \
        fail "Expected shadow directory entry to be cleaned after remove"
}

# ══════════════════════════════════════════════════════════════════════
# Switch — Stash/Restore on Main
# ══════════════════════════════════════════════════════════════════════

test_vault_switch_stash_restore_on_main() {
    # Switch from main (with projects) to profile and back — portable files preserved
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)

    local mock_bin="$tmpdir/mock_bin"
    _mock_docker_no_containers "$mock_bin"
    setup_mocks "$mock_bin"

    # Create portable files on main's test-proj
    mkdir -p "$CCO_USER_CONFIG_DIR/projects/test-proj/.cco/claude-state"
    echo "main-session" > "$CCO_USER_CONFIG_DIR/projects/test-proj/.cco/claude-state/data.json"

    # Create profile and switch to it (stashes main's portable files)
    run_cco vault profile create "work"

    # Portable files should be stashed
    [[ -f "$CCO_USER_CONFIG_DIR/.cco/profile-state/main/projects/test-proj/.cco/claude-state/data.json" ]] || \
        fail "Expected main's portable files to be stashed"

    # Switch back to main — portable files should be restored
    run_cco vault switch "$default_branch"
    [[ -f "$CCO_USER_CONFIG_DIR/projects/test-proj/.cco/claude-state/data.json" ]] || \
        fail "Expected main's portable files to be restored after switch back"

    local content
    content=$(cat "$CCO_USER_CONFIG_DIR/projects/test-proj/.cco/claude-state/data.json")
    [[ "$content" == "main-session" ]] || \
        fail "Expected portable file content to be preserved, got: $content"
}

# ══════════════════════════════════════════════════════════════════════
# Auto-Register on Profile (Design §6.8)
# ══════════════════════════════════════════════════════════════════════

test_profile_create_on_project_auto_registers() {
    # Creating a project while on a profile auto-registers it in .vault-profile
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"

    run_cco vault profile create "work"

    # Create a new project while on the work profile
    run_cco project create "profile-proj"

    # .vault-profile should list it
    assert_file_contains "$CCO_USER_CONFIG_DIR/.vault-profile" "profile-proj"

    # Output should confirm auto-registration
    assert_output_contains "Added to profile"
}

test_project_create_rejects_duplicate_name_cross_branch() {
    # project names must be unique across all branches
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"

    # test-proj already exists on main
    run_cco vault profile create "work"
    # On profile "work" — try to create project with same name as main
    if run_cco project create "test-proj" 2>/dev/null; then
        fail "Expected duplicate project name across branches to be rejected"
    fi
}

# ══════════════════════════════════════════════════════════════════════
# Operation Logging
# ══════════════════════════════════════════════════════════════════════

test_vault_operation_log_written() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)

    local mock_bin="$tmpdir/mock_bin"
    _mock_docker_no_containers "$mock_bin"
    setup_mocks "$mock_bin"

    # Move project to trigger a logged operation
    run_cco vault profile create "work"
    run_cco vault switch "$default_branch"
    run_cco vault move project "test-proj" "work" --yes

    # Verify profile-ops.log contains the move entry
    local log_file="$CCO_USER_CONFIG_DIR/.cco/profile-ops.log"
    [[ -f "$log_file" ]] || fail "Expected profile-ops.log to exist"
    grep -qF "MOVE project test-proj" "$log_file" || \
        fail "Expected MOVE entry in profile-ops.log"
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

# ══════════════════════════════════════════════════════════════════════
# Regression Tests — Session 2026-03-26 Fixes
# ══════════════════════════════════════════════════════════════════════

test_die_does_not_show_crash_message() {
    # die() must set _cco_completed=true to suppress the EXIT trap CRASH message
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local output
    output=$(CCO_USER_CONFIG_DIR="$CCO_USER_CONFIG_DIR" bash "$REPO_ROOT/bin/cco" vault init --nonexistent-flag 2>&1 || true)
    # Should NOT contain CRASH
    if echo "$output" | grep -qF "CRASH"; then
        fail "die() should suppress CRASH message, got: $output"
    fi
}

test_gitignore_auto_update_for_old_vaults() {
    # _check_vault adds missing profile entries to .gitignore
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    run_cco vault init
    git -C "$CCO_USER_CONFIG_DIR" config user.email "test@test.local"
    git -C "$CCO_USER_CONFIG_DIR" config user.name "Test"

    # Simulate old vault: remove profile entries from .gitignore
    local gi="$CCO_USER_CONFIG_DIR/.gitignore"
    grep -v "profile-ops.log\|profile-state\|backups" "$gi" > "$gi.tmp"
    mv "$gi.tmp" "$gi"
    git -C "$CCO_USER_CONFIG_DIR" add .gitignore
    git -C "$CCO_USER_CONFIG_DIR" commit -q -m "simulate old vault"

    # Any vault command triggers _check_vault which should add entries
    run_cco vault diff

    grep -qF ".cco/profile-ops.log" "$gi" || fail "Expected .gitignore to have profile-ops.log"
    grep -qF ".cco/profile-state/" "$gi" || fail "Expected .gitignore to have profile-state/"
    grep -qF ".cco/backups/" "$gi" || fail "Expected .gitignore to have backups/"
}

test_profile_list_shows_main_project_count() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"

    run_cco vault profile list
    # Main line should show project count (test-proj is on main)
    assert_output_contains "1 project(s)"
}

test_profile_delete_rejects_nonempty_without_force() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)

    run_cco vault profile create "work"
    run_cco vault switch "$default_branch"
    run_cco vault move project "test-proj" "work" --yes

    # Delete without --force should fail
    if run_cco vault profile delete "work" --yes 2>/dev/null; then
        fail "Expected delete of non-empty profile to be rejected without --force"
    fi

    # Branch should still exist
    git -C "$CCO_USER_CONFIG_DIR" rev-parse --verify "work" >/dev/null 2>&1 || \
        fail "Expected 'work' branch to still exist after rejected delete"
}

test_pack_create_rejects_duplicate_name_cross_branch() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)

    local mock_bin="$tmpdir/mock_bin"
    _mock_docker_no_containers "$mock_bin"
    setup_mocks "$mock_bin"

    # Create pack and move to profile
    run_cco pack create "my-pack"
    run_cco vault save "add pack" --yes
    run_cco vault profile create "work"
    run_cco vault switch "$default_branch"
    run_cco vault move pack "my-pack" "work" --yes

    # Try to create same name on main — should fail
    if run_cco pack create "my-pack" 2>/dev/null; then
        fail "Expected duplicate pack name across branches to be rejected"
    fi
}

test_pack_create_when_packs_dir_missing() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)

    local mock_bin="$tmpdir/mock_bin"
    _mock_docker_no_containers "$mock_bin"
    setup_mocks "$mock_bin"

    # Create pack, move it away (removes packs/ dir), then create new pack
    run_cco pack create "only-pack"
    run_cco vault save "add pack" --yes
    run_cco vault profile create "work"
    run_cco vault switch "$default_branch"
    run_cco vault move pack "only-pack" "work" --yes

    # packs/ may not exist — create should still work
    run_cco pack create "new-pack"
    [[ -d "$CCO_USER_CONFIG_DIR/packs/new-pack" ]] || \
        fail "Expected pack to be created even when packs/ was missing"
}

test_vault_remove_shared_pack_from_profile_blocked() {
    # Removing a shared pack from a profile branch is blocked (would be re-synced)
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)

    local mock_bin="$tmpdir/mock_bin"
    _mock_docker_no_containers "$mock_bin"
    setup_mocks "$mock_bin"

    # Create shared pack
    run_cco pack create "shared-pack"
    run_cco vault save "add pack" --yes

    # Create profile and switch to it
    run_cco vault profile create "work"

    # Try to remove shared pack from profile — should be blocked
    if run_cco vault remove pack "shared-pack" --yes 2>/dev/null; then
        fail "Expected removing shared pack from profile to be blocked"
    fi
}

test_vault_remove_shared_pack_from_main_cleans_profiles() {
    # Removing a shared pack from main should clean all profile copies
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)

    local mock_bin="$tmpdir/mock_bin"
    _mock_docker_no_containers "$mock_bin"
    setup_mocks "$mock_bin"

    # Create shared pack
    run_cco pack create "shared-pack"
    run_cco vault save "add pack" --yes

    # Create profile (shared pack syncs to it)
    run_cco vault profile create "work"
    run_cco vault switch "$default_branch"

    # Remove shared pack from main
    run_cco vault remove pack "shared-pack" --yes
    assert_output_contains "Removed"

    # Pack should be gone from work profile too
    local work_tree
    work_tree=$(git -C "$CCO_USER_CONFIG_DIR" ls-tree "work" -- "packs/shared-pack/" 2>/dev/null)
    [[ -z "$work_tree" ]] || fail "Expected shared pack removed from profile after delete from main"
}

test_self_healing_restores_shadow_after_direct_checkout() {
    # _check_vault should restore portable files stuck in shadow
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"
    local default_branch
    default_branch=$(_vault_default_branch)

    local mock_bin="$tmpdir/mock_bin"
    _mock_docker_no_containers "$mock_bin"
    setup_mocks "$mock_bin"

    # Create secrets on main
    echo "SECRET=val" > "$CCO_USER_CONFIG_DIR/projects/test-proj/secrets.env"

    # Create profile — stashes main's secrets
    run_cco vault profile create "work"

    # Simulate direct git checkout back to main (bypassing cco)
    git -C "$CCO_USER_CONFIG_DIR" checkout "$default_branch" -q

    # secrets.env is in shadow, not on disk
    [[ ! -f "$CCO_USER_CONFIG_DIR/projects/test-proj/secrets.env" ]] || \
        fail "After direct checkout, secrets should be in shadow not on disk"

    # Any vault command triggers self-healing
    run_cco vault diff
    assert_output_contains "Restored portable files"

    # secrets.env should now be on disk
    [[ -f "$CCO_USER_CONFIG_DIR/projects/test-proj/secrets.env" ]] || \
        fail "Self-healing should have restored secrets.env from shadow"
}

test_profile_create_preserves_unaccounted_files() {
    # verify-before-delete: unknown files should NOT be deleted during profile create
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault_for_profiles "$tmpdir"

    # Add unexpected file to project (simulates future feature)
    echo "important data" > "$CCO_USER_CONFIG_DIR/projects/test-proj/custom-report.txt"

    run_cco vault profile create "work"
    assert_output_contains "Unaccounted files"

    # File should survive on disk (safe_remove skipped)
    [[ -f "$CCO_USER_CONFIG_DIR/projects/test-proj/custom-report.txt" ]] || \
        fail "Unaccounted file must survive profile create"
}
