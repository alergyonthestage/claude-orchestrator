#!/usr/bin/env bash
# tests/test_clean.sh — Tests for cco clean command

test_clean_removes_global_bak() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Create some .bak files
    echo "backup" > "$CCO_GLOBAL_DIR/.claude/settings.json.bak"
    echo "backup" > "$CCO_GLOBAL_DIR/.claude/rules/workflow.md.bak"

    run_cco clean
    assert_file_not_exists "$CCO_GLOBAL_DIR/.claude/settings.json.bak"
    assert_file_not_exists "$CCO_GLOBAL_DIR/.claude/rules/workflow.md.bak"
    assert_output_contains "Removed 2"
}

test_clean_dry_run() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    echo "backup" > "$CCO_GLOBAL_DIR/.claude/settings.json.bak"

    run_cco clean --dry-run
    # File should still exist
    assert_file_exists "$CCO_GLOBAL_DIR/.claude/settings.json.bak"
    assert_output_contains "Would remove 1"
}

test_clean_no_bak_files() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    run_cco clean
    assert_output_contains "No .bak files found"
}

test_clean_project_specific() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Create a project with .bak files
    local proj_dir="$CCO_PROJECTS_DIR/test-proj"
    mkdir -p "$proj_dir/.claude/rules"
    echo "backup" > "$proj_dir/.claude/settings.json.bak"
    echo "backup" > "$proj_dir/.claude/rules/test.md.bak"

    # Also create global .bak (should NOT be cleaned)
    echo "global-bak" > "$CCO_GLOBAL_DIR/.claude/settings.json.bak"

    run_cco clean --project test-proj
    assert_file_not_exists "$proj_dir/.claude/settings.json.bak"
    assert_file_not_exists "$proj_dir/.claude/rules/test.md.bak"
    # Global .bak should still exist
    assert_file_exists "$CCO_GLOBAL_DIR/.claude/settings.json.bak"
}

test_clean_all() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Create .bak in global
    echo "backup" > "$CCO_GLOBAL_DIR/.claude/settings.json.bak"

    # Create project with .bak
    local proj_dir="$CCO_PROJECTS_DIR/test-proj"
    mkdir -p "$proj_dir/.claude"
    echo "backup" > "$proj_dir/.claude/test.md.bak"

    run_cco clean --all
    assert_file_not_exists "$CCO_GLOBAL_DIR/.claude/settings.json.bak"
    assert_file_not_exists "$proj_dir/.claude/test.md.bak"
    assert_output_contains "Removed 2"
}

test_clean_nonexistent_project_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    run_cco clean --project nonexistent && {
        echo "ASSERTION FAILED: expected clean nonexistent project to fail"
        return 1
    }
    return 0
}

test_clean_help() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco clean --help
    assert_output_contains "Remove .bak files"
    assert_output_contains "--dry-run"
}
