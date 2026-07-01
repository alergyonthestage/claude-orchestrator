#!/usr/bin/env bash
# tests/test_tutorial.sh — Tests for the built-in tutorial (internal project)
#
# The tutorial is now a framework-internal resource at internal/tutorial/.
# It is NOT installed in user-config by cco init. It launches via
# cco start tutorial, which prepares a runtime dir in machine-local STATE at
# <state>/cco/internal/tutorial/ (_cco_internal_runtime_dir, ADR-0037 D5) — never
# inside the (possibly read-only) framework tree.

# ── cco init: tutorial NOT created ────────────────────────────────────

test_init_does_not_create_tutorial_project() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    init_global "$tmpdir" --lang "English"
    assert_dir_not_exists "$tmpdir/repos/tutorial"
}

# Removed in P3-3b: the clean `cco init` output focuses on the global-ensure +
# per-repo scaffold (ADR-0026 approved copy); it no longer advertises the tutorial.

# ── _setup_internal_tutorial ──────────────────────────────────────────

test_setup_internal_tutorial_creates_runtime_dir() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"

    export USER_CONFIG_DIR="$CCO_USER_CONFIG_DIR"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/cmd-start.sh"

    _setup_internal_tutorial

    local runtime_dir="$(_cco_internal_runtime_dir)/tutorial"
    assert_dir_exists "$runtime_dir"
    assert_dir_exists "$runtime_dir/.claude"
    # Session transcripts/memory live in machine-local STATE (ADR-0009), mounted via
    # _cco_project_session_*, NOT in the runtime dir. Setup must not create dead
    # claude-state/memory dirs here (C9, pre-e2e review).
    assert_dir_not_exists "$runtime_dir/.cco/claude-state"
    assert_dir_not_exists "$runtime_dir/memory"
}

test_setup_internal_tutorial_substitutes_placeholders() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"

    export USER_CONFIG_DIR="$CCO_USER_CONFIG_DIR"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/cmd-start.sh"

    _setup_internal_tutorial

    local runtime_yml="$(_cco_internal_runtime_dir)/tutorial/project.yml"
    assert_file_exists "$runtime_yml"
    assert_no_placeholder "$runtime_yml" "{{CCO_REPO_ROOT}}"
    assert_no_placeholder "$runtime_yml" "{{CCO_CONFIG_DIR}}"
    # The tutorial's mounts are now NAME-based (like config-editor): the yml carries
    # logical names + container targets, never host paths (AD3/G8), and the host
    # paths are published via the in-process override (ADR-0036 step 5, 5f).
    assert_file_contains "$runtime_yml" "name: cco-config"
    assert_file_contains "$runtime_yml" "name: cco-docs"
    assert_file_contains "$runtime_yml" "/workspace/cco-config"
    # Host paths live in _CCO_MOUNT_OVERRIDE, not the committed yml.
    assert_file_not_contains "$runtime_yml" "$(_cco_config_dir)"
    [[ "$_CCO_MOUNT_OVERRIDE" == *"cco-config"$'\t'"$(_cco_config_dir)"* ]] \
        || fail "tutorial override should publish cco-config → $(_cco_config_dir)"
    [[ "$_CCO_MOUNT_OVERRIDE" == *"cco-docs"$'\t'"$REPO_ROOT/docs"* ]] \
        || fail "tutorial override should publish cco-docs → $REPO_ROOT/docs"
}

test_setup_internal_tutorial_has_skills() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"

    export USER_CONFIG_DIR="$CCO_USER_CONFIG_DIR"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/cmd-start.sh"

    _setup_internal_tutorial

    local runtime_dir="$(_cco_internal_runtime_dir)/tutorial"
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
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/cmd-start.sh"

    _setup_internal_tutorial

    local runtime_dir="$(_cco_internal_runtime_dir)/tutorial"
    assert_file_exists "$runtime_dir/.claude/rules/tutorial-behavior.md"
    assert_file_contains "$runtime_dir/.claude/rules/tutorial-behavior.md" "teacher, not an autonomous agent"
}

test_setup_internal_tutorial_refreshes_on_rerun() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"

    export USER_CONFIG_DIR="$CCO_USER_CONFIG_DIR"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/cmd-start.sh"

    _setup_internal_tutorial

    local runtime_dir="$(_cco_internal_runtime_dir)/tutorial"

    # Add a marker to CLAUDE.md (simulating stale content)
    echo "STALE MARKER" >> "$runtime_dir/.claude/CLAUDE.md"

    # Re-run: should refresh .claude/ from the framework source.
    _setup_internal_tutorial

    # CLAUDE.md should be refreshed (no stale marker)
    assert_file_not_contains "$runtime_dir/.claude/CLAUDE.md" "STALE MARKER"
    # Session memory lives in STATE (ADR-0009), not the runtime dir — setup never
    # creates a runtime-dir memory/ to "preserve" (C9, pre-e2e review).
    assert_dir_not_exists "$runtime_dir/memory"
}

# ── Preset + wrapped-cco (ADR-0036 step 5) ────────────────────────────

# Tutorial resolves to the read/none preset → read-only wrapped cco (operator
# env at cco_access=read), .claude authoring locked (none).
test_start_tutorial_preset_read_none() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco start tutorial --dry-run
    assert_output_contains "claude=none cco=read"
    run_cco start tutorial --dry-run --dump
    assert_file_contains "$DRY_RUN_DIR/.cco/docker-compose.yml" "CCO_CCO_ACCESS=read"
}

# The personal store is mounted read-only in the tutorial and its real secrets
# are masked (the tutorial never sees secret values — ADR-0036 D4).
test_start_tutorial_masks_secrets_readonly_store() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    printf 'G=1\n' > "$HOME/.cco/secrets.env"
    run_cco start tutorial --dry-run --dump
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"
    assert_file_contains "$compose" "secret-mask:/workspace/cco-config/secrets.env:ro" || return 1
    # cco-config stays read-only in the tutorial.
    assert_file_contains "$compose" "$HOME/.cco:/workspace/cco-config:ro" || return 1
}

# ── cco start tutorial: reserved name conflict ────────────────────────

test_start_tutorial_blocks_on_name_conflict() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    # Create a user project named "tutorial" (decentralized host + index seed)
    create_project "$tmpdir" "tutorial" "$(minimal_project_yml tutorial)"

    # cco start tutorial should fail with reserved name error
    if run_cco start tutorial --dry-run 2>/dev/null; then
        fail "Expected cco start tutorial to fail when a 'tutorial' project exists"
    fi
    assert_output_contains "reserved name"
}

# ── cco init --name tutorial: blocked (reserved name) ─────────────────

test_init_tutorial_name_blocked() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local repo="$tmpdir/some-repo"; mkdir -p "$repo"

    # cd in the parent so run_cco's CCO_OUTPUT propagates to the assertion.
    cd "$repo"; run_cco init --name tutorial 2>/dev/null && \
        fail "Expected cco init --name tutorial to fail (reserved name)"
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
