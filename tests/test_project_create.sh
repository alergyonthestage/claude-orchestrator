#!/usr/bin/env bash
# tests/test_project_create.sh — cco project create command tests
#
# Verifies project scaffolding: directory structure, placeholder substitution,
# name validation, and error handling.

test_project_create_makes_project_directory() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco project create "my-project"
    assert_dir_exists "$CCO_PROJECTS_DIR/my-project"
}

test_project_create_makes_project_yml() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco project create "my-project"
    assert_file_exists "$CCO_PROJECTS_DIR/my-project/project.yml"
}

test_project_create_makes_claude_md() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco project create "my-project"
    assert_file_exists "$CCO_PROJECTS_DIR/my-project/.claude/CLAUDE.md"
}

test_project_create_makes_settings_json() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco project create "my-project"
    assert_file_exists "$CCO_PROJECTS_DIR/my-project/.claude/settings.json"
}

test_project_create_makes_memory_dir() {
    # Memory separated from .cco/claude-state: standalone memory/ directory (vault-tracked)
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco project create "my-project"
    assert_dir_exists "$CCO_PROJECTS_DIR/my-project/memory"
}

test_project_create_makes_claude_state_dir() {
    # .cco/claude-state holds session transcripts only (gitignored)
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco project create "my-project"
    assert_dir_exists "$CCO_PROJECTS_DIR/my-project/.cco/claude-state"
}

test_project_create_memory_separate_from_claude_state() {
    # memory/ is NOT inside .cco/claude-state/ — they are sibling directories
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco project create "my-project"
    assert_dir_exists "$CCO_PROJECTS_DIR/my-project/memory"
    assert_dir_exists "$CCO_PROJECTS_DIR/my-project/.cco/claude-state"
    # memory/ should NOT exist inside .cco/claude-state/
    [[ ! -d "$CCO_PROJECTS_DIR/my-project/.cco/claude-state/memory" ]] || \
        fail "memory/ should not be inside .cco/claude-state/"
}

test_project_create_substitutes_project_name_in_yml() {
    # Design Invariant 8: {{PROJECT_NAME}} always replaced
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco project create "my-project"
    local yml="$CCO_PROJECTS_DIR/my-project/project.yml"
    assert_file_contains "$yml" "name: my-project"
    assert_no_placeholder "$yml" "{{PROJECT_NAME}}"
}

test_project_create_substitutes_project_name_in_claude_md() {
    # Design Invariant 8: {{PROJECT_NAME}} replaced in CLAUDE.md too
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco project create "my-project"
    local md="$CCO_PROJECTS_DIR/my-project/.claude/CLAUDE.md"
    assert_no_placeholder "$md" "{{PROJECT_NAME}}"
}

test_project_create_substitutes_description_with_flag() {
    # --description flag populates {{DESCRIPTION}} placeholder
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco project create "my-project" --description "My custom description"
    local yml="$CCO_PROJECTS_DIR/my-project/project.yml"
    assert_file_contains "$yml" "My custom description"
    assert_no_placeholder "$yml" "{{DESCRIPTION}}"
}

test_project_create_default_description_when_no_flag() {
    # Without --description, placeholder is replaced with a default (not left as-is)
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco project create "my-project"
    local yml="$CCO_PROJECTS_DIR/my-project/project.yml"
    assert_no_placeholder "$yml" "{{DESCRIPTION}}"
    # Default is "TODO: Add project description"
    assert_file_contains "$yml" "TODO"
}

test_project_create_no_remaining_placeholders() {
    # Design Invariant 8: ZERO {{...}} placeholders in any generated file
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco project create "my-project" --description "A real project"
    local project_dir="$CCO_PROJECTS_DIR/my-project"
    # Check all files recursively for unreplaced {{...}} patterns
    local found
    found=$(grep -rE '\{\{[^}]+\}\}' "$project_dir" 2>/dev/null || true)
    if [[ -n "$found" ]]; then
        echo "ASSERTION FAILED: unreplaced placeholders found in project files"
        echo "$found" | sed 's/^/  /'
        return 1
    fi
}

test_project_create_rejects_uppercase_name() {
    # Design Invariant 10: name must match ^[a-z0-9][a-z0-9-]*$
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    if run_cco project create "MyProject" 2>/dev/null; then
        echo "ASSERTION FAILED: should have rejected uppercase project name"
        return 1
    fi
}

test_project_create_rejects_name_starting_with_hyphen() {
    # Design Invariant 10: name cannot start with hyphen
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    if run_cco project create "-bad-name" 2>/dev/null; then
        echo "ASSERTION FAILED: should have rejected name starting with hyphen"
        return 1
    fi
}

test_project_create_rejects_name_with_underscore() {
    # Design Invariant 10: underscores not allowed (only lowercase, digits, hyphens)
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    if run_cco project create "my_project" 2>/dev/null; then
        echo "ASSERTION FAILED: should have rejected name with underscore"
        return 1
    fi
}

test_project_create_accepts_valid_name_with_hyphens() {
    # Design Invariant 10: lowercase, digits, hyphens are valid
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco project create "my-valid-project-123"
    assert_dir_exists "$CCO_PROJECTS_DIR/my-valid-project-123"
}

test_project_create_fails_if_already_exists() {
    # Creating the same project twice must fail the second time
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco project create "my-project"
    if run_cco project create "my-project" 2>/dev/null; then
        echo "ASSERTION FAILED: second create should have failed (project already exists)"
        return 1
    fi
}

# ── Template files from Sprint 1+2 ──────────────────────────────────

test_project_create_includes_secrets_env() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco project create "my-project"
    assert_file_exists "$CCO_PROJECTS_DIR/my-project/secrets.env"
}

test_project_create_includes_setup_sh() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco project create "my-project"
    assert_file_exists "$CCO_PROJECTS_DIR/my-project/setup.sh"
}

test_project_create_includes_mcp_packages_txt() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco project create "my-project"
    assert_file_exists "$CCO_PROJECTS_DIR/my-project/mcp-packages.txt"
}
