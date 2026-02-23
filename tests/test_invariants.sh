#!/usr/bin/env bash
# tests/test_invariants.sh — design invariant tests
#
# These tests directly encode the design invariants from docs/maintainer/spec.md
# and docs/maintainer/architecture.md. They MUST pass; failure means the
# implementation does not respect the architectural design.

# ── Invariant 1: Tool vs User Config Separation ───────────────────────
# defaults/ is tracked in git (tool code) and MUST NOT be modified by cco commands.

test_invariant_1_defaults_not_modified_by_init() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"

    # Hash all files in defaults/ before init
    local before_hash after_hash
    before_hash=$(find "$REPO_ROOT/defaults" -type f | LC_ALL=C sort | xargs sha1sum 2>/dev/null || \
                  find "$REPO_ROOT/defaults" -type f | LC_ALL=C sort | xargs md5 2>/dev/null)

    run_cco init --lang "English"

    # Hash after init — must be identical
    after_hash=$(find "$REPO_ROOT/defaults" -type f | LC_ALL=C sort | xargs sha1sum 2>/dev/null || \
                 find "$REPO_ROOT/defaults" -type f | LC_ALL=C sort | xargs md5 2>/dev/null)

    assert_equals "$before_hash" "$after_hash" \
        "defaults/ was modified by cco init (design invariant: defaults/ is read-only tool code)"
}

test_invariant_1_init_creates_in_global_not_defaults() {
    # cco init writes to global/, never to defaults/
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    # global/.claude must exist (user copy)
    assert_dir_exists "$CCO_GLOBAL_DIR/.claude"
    # defaults/ must not have been touched (no new timestamp marker)
    assert_dir_exists "$REPO_ROOT/defaults/global/.claude"
}

# ── Invariant 2: Context Hierarchy ───────────────────────────────────
# Global config → ~/.claude/ (user-scope, ro in container)
# Project config → /workspace/.claude (project-scope, rw in container)

test_invariant_2_global_config_at_home_claude_in_container() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    run_cco start "test-proj" --dry-run
    local compose="$CCO_PROJECTS_DIR/test-proj/docker-compose.yml"
    assert_file_contains "$compose" "/home/claude/.claude/settings.json"
    assert_file_contains "$compose" "/home/claude/.claude/CLAUDE.md"
    assert_file_contains "$compose" "/home/claude/.claude/rules"
}

test_invariant_2_project_config_at_workspace_claude_readwrite() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    run_cco start "test-proj" --dry-run
    local compose="$CCO_PROJECTS_DIR/test-proj/docker-compose.yml"
    assert_file_contains "$compose" "./.claude:/workspace/.claude"
    # MUST be read-write
    if grep -qF "./.claude:/workspace/.claude:ro" "$compose"; then
        echo "ASSERTION FAILED: project .claude must be mounted rw, not :ro"
        echo "  (Design Invariant 2: project config is read-write so Claude can update it)"
        return 1
    fi
}

# ── Invariant 3: Auto Memory Path ────────────────────────────────────
# Claude state (memory + transcripts) is mounted as claude-state/ on the host.
# Container path is /home/claude/.claude/projects/-workspace
# (-workspace = WORKDIR /workspace with root slash replaced by dash)

test_invariant_3_auto_memory_exact_container_path() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    run_cco start "test-proj" --dry-run
    local compose="$CCO_PROJECTS_DIR/test-proj/docker-compose.yml"
    assert_file_contains "$compose" "/home/claude/.claude/projects/-workspace"
}

test_invariant_3_memory_is_project_specific_host_path() {
    # Each project's state directory is isolated via mount
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "proj-a" "$(minimal_project_yml proj-a)"
    create_project "$tmpdir" "proj-b" "$(minimal_project_yml proj-b)"

    run_cco start "proj-a" --dry-run
    run_cco start "proj-b" --dry-run

    local compose_a="$CCO_PROJECTS_DIR/proj-a/docker-compose.yml"
    local compose_b="$CCO_PROJECTS_DIR/proj-b/docker-compose.yml"

    # Each project's compose should reference its own claude-state directory
    assert_file_contains "$compose_a" "proj-a/claude-state"
    assert_file_contains "$compose_b" "proj-b/claude-state"
    assert_file_not_contains "$compose_a" "proj-b/claude-state"
    assert_file_not_contains "$compose_b" "proj-a/claude-state"
}

# ── Invariant 4: Container/Network Naming ────────────────────────────

test_invariant_4_container_name_is_cc_project() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "my-project" "$(minimal_project_yml my-project)"
    run_cco start "my-project" --dry-run
    assert_file_contains "$CCO_PROJECTS_DIR/my-project/docker-compose.yml" \
        "container_name: cc-my-project"
}

test_invariant_4_network_name_is_cc_project() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "my-project" "$(minimal_project_yml my-project)"
    run_cco start "my-project" --dry-run
    assert_file_contains "$CCO_PROJECTS_DIR/my-project/docker-compose.yml" \
        "name: cc-my-project"
}

test_invariant_4_two_projects_have_distinct_names() {
    # Two projects must have distinct container/network names
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "proj-one" "$(minimal_project_yml proj-one)"
    create_project "$tmpdir" "proj-two" "$(minimal_project_yml proj-two)"

    run_cco start "proj-one" --dry-run
    run_cco start "proj-two" --dry-run

    assert_file_contains "$CCO_PROJECTS_DIR/proj-one/docker-compose.yml" "cc-proj-one"
    assert_file_contains "$CCO_PROJECTS_DIR/proj-two/docker-compose.yml" "cc-proj-two"
    assert_file_not_contains "$CCO_PROJECTS_DIR/proj-one/docker-compose.yml" "cc-proj-two"
    assert_file_not_contains "$CCO_PROJECTS_DIR/proj-two/docker-compose.yml" "cc-proj-one"
}

# ── Invariant 5: Read-Only Mounts ─────────────────────────────────────
# Global config, git, packs must always be :ro

test_invariant_5_all_global_config_mounts_are_readonly() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    run_cco start "test-proj" --dry-run
    local compose="$CCO_PROJECTS_DIR/test-proj/docker-compose.yml"

    # Every line mounting from the global config dir must end with :ro
    local global_path="$CCO_GLOBAL_DIR/.claude"
    local violations
    violations=$(grep -F "$global_path" "$compose" | grep -v ":ro" || true)
    if [[ -n "$violations" ]]; then
        echo "ASSERTION FAILED: global config mount(s) without :ro (Design Invariant 5)"
        echo "$violations" | sed 's/^/  /'
        return 1
    fi
}

# ── Invariant 8: Placeholder Substitution ────────────────────────────

test_invariant_8_no_placeholders_after_project_create() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco project create "test-project" --description "A real description"
    local project_dir="$CCO_PROJECTS_DIR/test-project"
    local found
    found=$(grep -rE '\{\{[^}]+\}\}' "$project_dir" 2>/dev/null || true)
    if [[ -n "$found" ]]; then
        echo "ASSERTION FAILED: unreplaced placeholders found after project create"
        echo "$found" | sed 's/^/  /'
        return 1
    fi
}

# ── Invariant 9: Secrets Never in Compose ─────────────────────────────
# global/secrets.env values must NEVER appear in docker-compose.yml

test_invariant_9_secrets_not_written_to_compose() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    # Plant a recognizable secret value
    printf 'MY_SECRET=hunter2\nDATABASE_PASSWORD=s3cr3t!\n' > "$CCO_GLOBAL_DIR/secrets.env"

    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    run_cco start "test-proj" --dry-run
    local compose="$CCO_PROJECTS_DIR/test-proj/docker-compose.yml"

    assert_file_not_contains "$compose" "hunter2"
    assert_file_not_contains "$compose" "s3cr3t!"
    assert_file_not_contains "$compose" "MY_SECRET"
    assert_file_not_contains "$compose" "DATABASE_PASSWORD"
}

# ── Invariant 10: Project Name Validation ─────────────────────────────
# Names must match ^[a-z0-9][a-z0-9-]*$

test_invariant_10_rejects_name_with_spaces() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    if run_cco project create "my project" 2>/dev/null; then
        echo "ASSERTION FAILED: should reject name with spaces (Design Invariant 10)"
        return 1
    fi
}

test_invariant_10_rejects_name_with_uppercase() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    if run_cco project create "MyProject" 2>/dev/null; then
        echo "ASSERTION FAILED: should reject uppercase name (Design Invariant 10)"
        return 1
    fi
}

test_invariant_10_rejects_name_with_underscore() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    if run_cco project create "my_project" 2>/dev/null; then
        echo "ASSERTION FAILED: should reject underscore in name (Design Invariant 10)"
        return 1
    fi
}

test_invariant_10_accepts_lowercase_hyphens_numbers() {
    # Valid name: lowercase letters, hyphens, digits
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco project create "valid-proj-123"
    assert_dir_exists "$CCO_PROJECTS_DIR/valid-proj-123"
}
