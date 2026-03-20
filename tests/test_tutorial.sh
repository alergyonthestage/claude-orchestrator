#!/usr/bin/env bash
# tests/test_tutorial.sh — Tests for the built-in tutorial (internal project)
#
# The tutorial is now a framework-internal resource at internal/tutorial/.
# It is NOT installed in user-config by cco init. It launches via
# cco start tutorial, which prepares a runtime dir at
# user-config/.cco/internal/tutorial/.

# ── cco init: tutorial NOT created ────────────────────────────────────

test_init_does_not_create_tutorial_project() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    assert_dir_not_exists "$CCO_PROJECTS_DIR/tutorial"
}

test_init_output_mentions_tutorial_start() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    assert_output_contains "cco start tutorial"
}

# ── _setup_internal_tutorial ──────────────────────────────────────────

test_setup_internal_tutorial_creates_runtime_dir() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"

    export USER_CONFIG_DIR="$CCO_USER_CONFIG_DIR"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/cmd-start.sh"

    _setup_internal_tutorial

    local runtime_dir="$CCO_USER_CONFIG_DIR/.cco/internal/tutorial"
    assert_dir_exists "$runtime_dir"
    assert_dir_exists "$runtime_dir/.claude"
    assert_dir_exists "$runtime_dir/.cco/claude-state"
    assert_dir_exists "$runtime_dir/memory"
}

test_setup_internal_tutorial_substitutes_placeholders() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"

    export USER_CONFIG_DIR="$CCO_USER_CONFIG_DIR"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/cmd-start.sh"

    _setup_internal_tutorial

    local runtime_yml="$CCO_USER_CONFIG_DIR/.cco/internal/tutorial/project.yml"
    assert_file_exists "$runtime_yml"
    assert_no_placeholder "$runtime_yml" "{{CCO_REPO_ROOT}}"
    assert_no_placeholder "$runtime_yml" "{{CCO_USER_CONFIG_DIR}}"
    assert_file_contains "$runtime_yml" "$REPO_ROOT/docs"
    assert_file_contains "$runtime_yml" "$CCO_USER_CONFIG_DIR"
}

test_setup_internal_tutorial_has_skills() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"

    export USER_CONFIG_DIR="$CCO_USER_CONFIG_DIR"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/cmd-start.sh"

    _setup_internal_tutorial

    local runtime_dir="$CCO_USER_CONFIG_DIR/.cco/internal/tutorial"
    assert_file_exists "$runtime_dir/.claude/skills/tutorial/SKILL.md"
    assert_file_exists "$runtime_dir/.claude/skills/setup-project/SKILL.md"
    assert_file_exists "$runtime_dir/.claude/skills/setup-pack/SKILL.md"
}

test_setup_internal_tutorial_has_rules() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"

    export USER_CONFIG_DIR="$CCO_USER_CONFIG_DIR"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/cmd-start.sh"

    _setup_internal_tutorial

    local runtime_dir="$CCO_USER_CONFIG_DIR/.cco/internal/tutorial"
    assert_file_exists "$runtime_dir/.claude/rules/tutorial-behavior.md"
    assert_file_contains "$runtime_dir/.claude/rules/tutorial-behavior.md" "teacher, not an autonomous agent"
}

test_setup_internal_tutorial_refreshes_on_rerun() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"

    export USER_CONFIG_DIR="$CCO_USER_CONFIG_DIR"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/cmd-start.sh"

    _setup_internal_tutorial

    local runtime_dir="$CCO_USER_CONFIG_DIR/.cco/internal/tutorial"

    # Add a marker to CLAUDE.md (simulating stale content)
    echo "STALE MARKER" >> "$runtime_dir/.claude/CLAUDE.md"

    # Also add a file to memory/ (should survive refresh)
    echo "user memory" > "$runtime_dir/memory/MEMORY.md"

    # Re-run: should refresh .claude/ but preserve state dirs
    _setup_internal_tutorial

    # CLAUDE.md should be refreshed (no stale marker)
    assert_file_not_contains "$runtime_dir/.claude/CLAUDE.md" "STALE MARKER"
    # Memory should be preserved
    assert_file_exists "$runtime_dir/memory/MEMORY.md"
    assert_file_contains "$runtime_dir/memory/MEMORY.md" "user memory"
    # claude-state should be preserved
    assert_dir_exists "$runtime_dir/.cco/claude-state"
}

# ── cco start tutorial: reserved name conflict ────────────────────────

test_start_tutorial_blocks_on_name_conflict() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    # Create a user project named "tutorial"
    mkdir -p "$CCO_PROJECTS_DIR/tutorial/.claude"
    echo "name: tutorial" > "$CCO_PROJECTS_DIR/tutorial/project.yml"

    # cco start tutorial should fail with reserved name error
    if run_cco start tutorial --dry-run 2>/dev/null; then
        fail "Expected cco start tutorial to fail when projects/tutorial exists"
    fi
    assert_output_contains "reserved name"
}

# ── cco project create tutorial: blocked ──────────────────────────────

test_project_create_tutorial_blocked() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    # cco project create tutorial should fail (reserved name)
    if run_cco project create tutorial 2>/dev/null; then
        fail "Expected cco project create tutorial to fail (reserved name)"
    fi
    assert_output_contains "reserved"
}

# ── Migration 010 ─────────────────────────────────────────────────────

test_migration_010_legacy_tutorial_non_interactive() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT

    # Create a legacy tutorial project with .cco/source
    local proj_dir="$tmpdir/tutorial"
    mkdir -p "$proj_dir/.cco" "$proj_dir/.claude/skills/tutorial" "$proj_dir/.claude/rules"
    echo "native:project/tutorial" > "$proj_dir/.cco/source"
    echo "name: tutorial" > "$proj_dir/project.yml"
    touch "$proj_dir/.claude/skills/tutorial/SKILL.md"
    touch "$proj_dir/.claude/rules/tutorial-behavior.md"

    # Run migration non-interactively (stdin from /dev/null)
    source "$REPO_ROOT/migrations/project/010_tutorial_to_internal.sh"
    migrate "$proj_dir" < /dev/null

    # Project should be kept (non-interactive doesn't remove)
    assert_dir_exists "$proj_dir"
}

test_migration_010_legacy_tutorial_heuristic() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT

    # Create a legacy tutorial WITHOUT .cco/source (old installation)
    local proj_dir="$tmpdir/tutorial"
    mkdir -p "$proj_dir/.claude/skills/tutorial" "$proj_dir/.claude/rules"
    echo "name: tutorial" > "$proj_dir/project.yml"
    touch "$proj_dir/.claude/skills/tutorial/SKILL.md"
    touch "$proj_dir/.claude/rules/tutorial-behavior.md"

    # Run migration — should detect as legacy via heuristic
    local output
    output=$(source "$REPO_ROOT/lib/colors.sh" && source "$REPO_ROOT/migrations/project/010_tutorial_to_internal.sh" && migrate "$proj_dir" < /dev/null 2>&1)

    # Should mention "built-in" (legacy path, not user-project path)
    echo "$output" | grep -qF "built-in" || \
        fail "Expected legacy detection via heuristic, got: $output"
}

test_migration_010_user_project_named_tutorial() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT

    # Create a user project named "tutorial" with different source
    local proj_dir="$tmpdir/tutorial"
    mkdir -p "$proj_dir/.cco" "$proj_dir/.claude"
    echo "local" > "$proj_dir/.cco/source"
    echo "name: tutorial" > "$proj_dir/project.yml"

    # Run migration
    local output
    output=$(source "$REPO_ROOT/migrations/project/010_tutorial_to_internal.sh" && migrate "$proj_dir" < /dev/null 2>&1)

    # Should warn about reserved name, not offer removal
    echo "$output" | grep -qF "reserved name" || \
        fail "Expected reserved name warning, got: $output"
    # Project should still exist
    assert_dir_exists "$proj_dir"
}

test_migration_010_other_project_noop() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT

    # Create a project with a different name
    local proj_dir="$tmpdir/my-app"
    mkdir -p "$proj_dir/.claude"
    echo "name: my-app" > "$proj_dir/project.yml"

    # Run migration — should be a no-op
    local output
    output=$(source "$REPO_ROOT/migrations/project/010_tutorial_to_internal.sh" && migrate "$proj_dir" 2>&1)

    # No output (immediate return 0)
    [[ -z "$output" ]] || fail "Expected no output for non-tutorial project, got: $output"
}
