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
    assert_output_contains "Nothing to clean"
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

test_clean_all_bak() {
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

test_clean_nonexistent_project_warns() {
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
    assert_output_contains "Remove files created by"
    assert_output_contains "--dry-run"
    assert_output_contains "--tmp"
    assert_output_contains "--generated"
    assert_output_contains "--all"
}

# ── --tmp category tests ────────────────────────────────────────────

test_clean_tmp_removes_dot_tmp_dirs() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Create a project with .tmp/ dir
    local proj_dir="$CCO_PROJECTS_DIR/test-proj"
    mkdir -p "$proj_dir/.tmp"
    echo "dry-run output" > "$proj_dir/.tmp/docker-compose.yml"

    run_cco clean --tmp
    assert_dir_not_exists "$proj_dir/.tmp"
    assert_output_contains "Removed 1 .tmp/"
}

test_clean_tmp_dry_run() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    local proj_dir="$CCO_PROJECTS_DIR/test-proj"
    mkdir -p "$proj_dir/.tmp"
    echo "content" > "$proj_dir/.tmp/file.txt"

    run_cco clean --tmp --dry-run
    # Dir should still exist
    assert_dir_exists "$proj_dir/.tmp"
    assert_output_contains "Would remove 1 .tmp/"
    assert_output_contains "[dry-run]"
}

test_clean_tmp_project_scoped() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Create two projects with .tmp/
    local proj1="$CCO_PROJECTS_DIR/proj1"
    local proj2="$CCO_PROJECTS_DIR/proj2"
    mkdir -p "$proj1/.tmp" "$proj2/.tmp"

    run_cco clean --tmp --project proj1
    assert_dir_not_exists "$proj1/.tmp"
    # proj2 should still have .tmp
    assert_dir_exists "$proj2/.tmp"
}

test_clean_tmp_no_dirs() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    run_cco clean --tmp
    assert_output_contains "Nothing to clean"
}

# ── --generated category tests ──────────────────────────────────────

test_clean_generated_removes_docker_compose() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    local proj_dir="$CCO_PROJECTS_DIR/test-proj"
    mkdir -p "$proj_dir"
    echo "generated" > "$proj_dir/docker-compose.yml"

    run_cco clean --generated
    assert_file_not_exists "$proj_dir/docker-compose.yml"
    assert_output_contains "Removed 1 docker-compose.yml"
}

test_clean_generated_dry_run() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    local proj_dir="$CCO_PROJECTS_DIR/test-proj"
    mkdir -p "$proj_dir"
    echo "generated" > "$proj_dir/docker-compose.yml"

    run_cco clean --generated --dry-run
    assert_file_exists "$proj_dir/docker-compose.yml"
    assert_output_contains "Would remove 1 docker-compose.yml"
    assert_output_contains "[dry-run]"
}

test_clean_generated_project_scoped() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    local proj1="$CCO_PROJECTS_DIR/proj1"
    local proj2="$CCO_PROJECTS_DIR/proj2"
    mkdir -p "$proj1" "$proj2"
    echo "gen" > "$proj1/docker-compose.yml"
    echo "gen" > "$proj2/docker-compose.yml"

    run_cco clean --generated --project proj1
    assert_file_not_exists "$proj1/docker-compose.yml"
    assert_file_exists "$proj2/docker-compose.yml"
}

test_clean_generated_no_files() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    run_cco clean --generated
    assert_output_contains "Nothing to clean"
}

# ── --all category tests ────────────────────────────────────────────

test_clean_all_categories() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    local proj_dir="$CCO_PROJECTS_DIR/test-proj"
    mkdir -p "$proj_dir/.claude" "$proj_dir/.tmp"

    # .bak files
    echo "backup" > "$proj_dir/.claude/test.md.bak"
    echo "backup" > "$CCO_GLOBAL_DIR/.claude/settings.json.bak"

    # .tmp directory
    echo "dry-run" > "$proj_dir/.tmp/compose.yml"

    # docker-compose.yml
    echo "generated" > "$proj_dir/docker-compose.yml"

    run_cco clean --all
    assert_file_not_exists "$proj_dir/.claude/test.md.bak"
    assert_file_not_exists "$CCO_GLOBAL_DIR/.claude/settings.json.bak"
    assert_dir_not_exists "$proj_dir/.tmp"
    assert_file_not_exists "$proj_dir/docker-compose.yml"

    assert_output_contains "Removed 2 .bak"
    assert_output_contains "Removed 1 .tmp/"
    assert_output_contains "Removed 1 docker-compose.yml"
}

test_clean_all_categories_dry_run() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    local proj_dir="$CCO_PROJECTS_DIR/test-proj"
    mkdir -p "$proj_dir/.claude" "$proj_dir/.tmp"

    echo "backup" > "$proj_dir/.claude/test.md.bak"
    echo "dry-run" > "$proj_dir/.tmp/compose.yml"
    echo "generated" > "$proj_dir/docker-compose.yml"

    run_cco clean --all --dry-run
    # Everything should still exist
    assert_file_exists "$proj_dir/.claude/test.md.bak"
    assert_dir_exists "$proj_dir/.tmp"
    assert_file_exists "$proj_dir/docker-compose.yml"

    assert_output_contains "[dry-run]"
    assert_output_contains "Run without --dry-run"
}

# ── Explicit --bak flag ─────────────────────────────────────────────

test_clean_explicit_bak_flag() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    echo "backup" > "$CCO_GLOBAL_DIR/.claude/settings.json.bak"

    run_cco clean --bak
    assert_file_not_exists "$CCO_GLOBAL_DIR/.claude/settings.json.bak"
    assert_output_contains "Removed 1 .bak"
}

# ── Default behavior: global + all projects ─────────────────────────

test_clean_default_cleans_global_and_projects() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Create .bak in global
    echo "backup" > "$CCO_GLOBAL_DIR/.claude/settings.json.bak"

    # Create .bak in a project
    local proj_dir="$CCO_PROJECTS_DIR/test-proj"
    mkdir -p "$proj_dir/.claude"
    echo "backup" > "$proj_dir/.claude/test.md.bak"

    run_cco clean
    assert_file_not_exists "$CCO_GLOBAL_DIR/.claude/settings.json.bak"
    assert_file_not_exists "$proj_dir/.claude/test.md.bak"
    assert_output_contains "Removed 2 .bak"
}

# ── Combined Category & Dry-Run Tests ────────────────────────────────

test_clean_all_categories_combined() {
    # All three artifact types (.bak, .tmp/, docker-compose.yml) are removed together
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    local proj_dir="$CCO_PROJECTS_DIR/test-proj"
    mkdir -p "$proj_dir/.claude" "$proj_dir/.tmp"

    # .bak files
    echo "backup" > "$proj_dir/.claude/test.md.bak"
    # .tmp/ directory
    echo "dry-run artifact" > "$proj_dir/.tmp/compose.yml"
    # docker-compose.yml
    echo "generated" > "$proj_dir/docker-compose.yml"

    run_cco clean --all
    assert_file_not_exists "$proj_dir/.claude/test.md.bak"
    assert_dir_not_exists "$proj_dir/.tmp"
    assert_file_not_exists "$proj_dir/docker-compose.yml"
}

test_clean_dry_run_no_deletion() {
    # --dry-run reports but does NOT delete any files
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Create .bak files
    echo "backup1" > "$CCO_GLOBAL_DIR/.claude/settings.json.bak"
    echo "backup2" > "$CCO_GLOBAL_DIR/.claude/rules/workflow.md.bak"

    run_cco clean --dry-run
    assert_output_contains "[dry-run]"
    # Files must still exist after dry-run
    assert_file_exists "$CCO_GLOBAL_DIR/.claude/settings.json.bak"
    assert_file_exists "$CCO_GLOBAL_DIR/.claude/rules/workflow.md.bak"
}

test_clean_nonexistent_project_error() {
    # Cleaning a non-existent project should fail with an error message
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    run_cco clean --project nonexistent && {
        fail "Expected clean --project nonexistent to fail"
        return 1
    }
    return 0
}
