#!/usr/bin/env bash
# tests/test_tutorial.sh — Tests for tutorial project creation and structure

test_init_creates_tutorial_project() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    assert_dir_exists "$CCO_PROJECTS_DIR/tutorial"
}

test_init_creates_tutorial_claude_md() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    assert_file_exists "$CCO_PROJECTS_DIR/tutorial/.claude/CLAUDE.md"
    assert_file_contains "$CCO_PROJECTS_DIR/tutorial/.claude/CLAUDE.md" "# Project: tutorial"
}

test_init_creates_tutorial_project_yml() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    assert_file_exists "$CCO_PROJECTS_DIR/tutorial/project.yml"
    assert_file_contains "$CCO_PROJECTS_DIR/tutorial/project.yml" "name: tutorial"
}

test_init_substitutes_repo_root_placeholder() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    assert_no_placeholder "$CCO_PROJECTS_DIR/tutorial/project.yml" "{{CCO_REPO_ROOT}}"
    assert_file_contains "$CCO_PROJECTS_DIR/tutorial/project.yml" "$REPO_ROOT/docs"
}

test_init_substitutes_user_config_placeholder() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    assert_no_placeholder "$CCO_PROJECTS_DIR/tutorial/project.yml" "{{CCO_USER_CONFIG_DIR}}"
    assert_file_contains "$CCO_PROJECTS_DIR/tutorial/project.yml" "$CCO_USER_CONFIG_DIR"
}

test_init_tutorial_has_no_remaining_placeholders() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    assert_no_placeholders "$CCO_PROJECTS_DIR/tutorial/project.yml"
}

test_init_tutorial_has_skills() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    assert_file_exists "$CCO_PROJECTS_DIR/tutorial/.claude/skills/tutorial/SKILL.md"
    assert_file_exists "$CCO_PROJECTS_DIR/tutorial/.claude/skills/setup-project/SKILL.md"
    assert_file_exists "$CCO_PROJECTS_DIR/tutorial/.claude/skills/setup-pack/SKILL.md"
}

test_init_tutorial_has_rules() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    assert_file_exists "$CCO_PROJECTS_DIR/tutorial/.claude/rules/tutorial-behavior.md"
    assert_file_contains "$CCO_PROJECTS_DIR/tutorial/.claude/rules/tutorial-behavior.md" "teacher, not an autonomous agent"
}

test_init_tutorial_has_empty_repos() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    assert_file_contains "$CCO_PROJECTS_DIR/tutorial/project.yml" "repos: []"
}

test_init_tutorial_socket_disabled() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    assert_file_contains "$CCO_PROJECTS_DIR/tutorial/project.yml" "mount_socket: false"
}

test_init_tutorial_has_settings_json() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    assert_file_exists "$CCO_PROJECTS_DIR/tutorial/.claude/settings.json"
}

test_init_tutorial_has_memory_dir() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    assert_dir_exists "$CCO_PROJECTS_DIR/tutorial/claude-state"
    assert_dir_exists "$CCO_PROJECTS_DIR/tutorial/memory"
}

test_init_skips_existing_tutorial() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"

    # First init creates the tutorial
    run_cco init --lang "English"
    assert_dir_exists "$CCO_PROJECTS_DIR/tutorial"

    # Add a marker file to detect overwrite
    echo "user-customization" > "$CCO_PROJECTS_DIR/tutorial/.claude/CLAUDE.md"

    # Second init should NOT overwrite
    run_cco init --lang "English"
    assert_file_contains "$CCO_PROJECTS_DIR/tutorial/.claude/CLAUDE.md" "user-customization"
}

test_init_tutorial_output_message() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    assert_output_contains "Tutorial project ready"
}

test_tutorial_dry_run_generates_compose() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco init --lang "English"

    # Create the source dirs that extra_mounts reference
    mkdir -p "$REPO_ROOT/docs"

    run_cco start "tutorial" --dry-run
    local compose="$DRY_RUN_DIR/docker-compose.yml"
    assert_file_exists "$compose"
    # Verify extra_mounts for docs (read-only)
    assert_file_contains "$compose" "$REPO_ROOT/docs:/workspace/cco-docs:ro"
    # Verify extra_mounts for user-config (read-only)
    assert_file_contains "$compose" "$CCO_USER_CONFIG_DIR:/workspace/user-config:ro"
    # Verify docker socket is NOT mounted
    assert_file_not_contains "$compose" "/var/run/docker.sock"
}

test_tutorial_dry_run_warns_no_repos() {
    # repos: [] is valid but should emit a warning (not an error)
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco init --lang "English"
    mkdir -p "$REPO_ROOT/docs"

    run_cco start "tutorial" --dry-run
    assert_output_contains "No repositories defined"
}

test_init_skips_tutorial_with_force() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"

    # First init creates the tutorial
    run_cco init --lang "English"
    assert_dir_exists "$CCO_PROJECTS_DIR/tutorial"

    # Add a marker to detect overwrite
    echo "user-customization" > "$CCO_PROJECTS_DIR/tutorial/.claude/CLAUDE.md"

    # Force init should NOT overwrite existing tutorial (tutorial is user data)
    run_cco init --force --lang "English"
    assert_file_contains "$CCO_PROJECTS_DIR/tutorial/.claude/CLAUDE.md" "user-customization"
}

test_tutorial_has_setup_sh() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    assert_file_exists "$CCO_PROJECTS_DIR/tutorial/setup.sh"
}
