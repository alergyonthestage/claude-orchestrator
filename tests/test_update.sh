#!/usr/bin/env bash
# tests/test_update.sh — cco update command tests
#
# Verifies the update system: file change detection, conflict resolution,
# migrations, .cco-meta generation, and dry-run mode.

# ── Helper: init a global dir with .cco-meta ─────────────────────────

# Run cco init and return tmpdir. Sets up CCO env vars.
_setup_initialized() {
    local tmpdir; tmpdir=$(mktemp -d)
    setup_cco_env "$tmpdir"
    run_cco init --lang "Italian:Italian:English"
    echo "$tmpdir"
}

# ── Tests ─────────────────────────────────────────────────────────────

test_update_first_run_no_meta() {
    # First update on an install that has no .cco-meta should create it
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    # Simulate pre-update install (no .cco-meta)
    setup_global_from_defaults "$tmpdir"
    # Substitute language placeholders manually (as old init would)
    sed -i "s/{{COMM_LANG}}/English/g" "$CCO_GLOBAL_DIR/.claude/rules/language.md"
    sed -i "s/{{DOCS_LANG}}/English/g" "$CCO_GLOBAL_DIR/.claude/rules/language.md"
    sed -i "s/{{CODE_LANG}}/English/g" "$CCO_GLOBAL_DIR/.claude/rules/language.md"

    run_cco update
    assert_file_exists "$CCO_GLOBAL_DIR/.claude/.cco-meta" \
        "update should generate .cco-meta"
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/.cco-meta" "schema_version:"
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/.cco-meta" "manifest:"
}

test_update_no_changes() {
    # When everything is up to date, update reports no changes
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Run update — should say "up to date"
    run_cco update
    assert_output_contains "up to date"
}

test_update_framework_changed() {
    # When a default file changes but user hasn't modified it → safe update
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Simulate framework update: modify a default file
    printf '# Updated workflow rules\n- New rule added\n' >> "$REPO_ROOT/defaults/global/.claude/rules/workflow.md"

    run_cco update
    # The installed file should now contain the new content
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/rules/workflow.md" "New rule added"

    # Restore the default file
    cd "$REPO_ROOT" && git checkout -- defaults/global/.claude/rules/workflow.md
}

test_update_user_modified() {
    # When user modified a file but framework hasn't changed → preserve user version
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # User modifies a managed file
    printf '\n# My custom rule\n' >> "$CCO_GLOBAL_DIR/.claude/rules/workflow.md"

    run_cco update
    # User modification should be preserved
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/rules/workflow.md" "My custom rule"
}

test_update_force_overwrites() {
    # --force overwrites even user-modified files when there's a framework change
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # User modifies, then framework also changes (simulate conflict)
    printf '\n# My custom rule\n' >> "$CCO_GLOBAL_DIR/.claude/rules/workflow.md"
    printf '\n# Framework update\n' >> "$REPO_ROOT/defaults/global/.claude/rules/workflow.md"

    run_cco update --force
    # User modification should be gone, framework update present
    assert_file_not_contains "$CCO_GLOBAL_DIR/.claude/rules/workflow.md" "My custom rule"
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/rules/workflow.md" "Framework update"

    # Restore
    cd "$REPO_ROOT" && git checkout -- defaults/global/.claude/rules/workflow.md
}

test_update_keep_preserves() {
    # --keep preserves user version on conflicts
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Create conflict
    printf '\n# My custom rule\n' >> "$CCO_GLOBAL_DIR/.claude/rules/workflow.md"
    printf '\n# Framework update\n' >> "$REPO_ROOT/defaults/global/.claude/rules/workflow.md"

    run_cco update --keep
    # User version should be preserved
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/rules/workflow.md" "My custom rule"

    # Restore
    cd "$REPO_ROOT" && git checkout -- defaults/global/.claude/rules/workflow.md
}

test_update_backup_creates_bak() {
    # --backup creates .bak file and overwrites
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Create conflict
    printf '\n# My custom rule\n' >> "$CCO_GLOBAL_DIR/.claude/rules/workflow.md"
    printf '\n# Framework update\n' >> "$REPO_ROOT/defaults/global/.claude/rules/workflow.md"

    run_cco update --backup
    # Backup should exist
    assert_file_exists "$CCO_GLOBAL_DIR/.claude/rules/workflow.md.bak"
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/rules/workflow.md.bak" "My custom rule"
    # Updated file should have framework changes
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/rules/workflow.md" "Framework update"

    # Restore
    cd "$REPO_ROOT" && git checkout -- defaults/global/.claude/rules/workflow.md
}

test_update_new_file_added() {
    # New file in defaults is copied to installed dir
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Add a new file to defaults
    printf '# New Rule\nSome new convention.\n' > "$REPO_ROOT/defaults/global/.claude/rules/new-rule.md"

    run_cco update
    assert_file_exists "$CCO_GLOBAL_DIR/.claude/rules/new-rule.md"
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/rules/new-rule.md" "New Rule"

    # Cleanup
    rm -f "$REPO_ROOT/defaults/global/.claude/rules/new-rule.md"
}

test_update_dry_run() {
    # --dry-run shows what would change without modifying anything
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Add a new file to defaults
    printf '# Dry Run Test\n' > "$REPO_ROOT/defaults/global/.claude/rules/dry-test.md"

    run_cco update --dry-run
    assert_output_contains "Dry run complete"
    assert_output_contains "dry-test.md"
    # File should NOT actually exist
    assert_file_not_exists "$CCO_GLOBAL_DIR/.claude/rules/dry-test.md"

    # Cleanup
    rm -f "$REPO_ROOT/defaults/global/.claude/rules/dry-test.md"
}

test_update_migrations_run_in_order() {
    # Migrations execute in order by MIGRATION_ID
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    # Substitute language placeholders
    sed -i "s/{{COMM_LANG}}/English/g" "$CCO_GLOBAL_DIR/.claude/rules/language.md"
    sed -i "s/{{DOCS_LANG}}/English/g" "$CCO_GLOBAL_DIR/.claude/rules/language.md"
    sed -i "s/{{CODE_LANG}}/English/g" "$CCO_GLOBAL_DIR/.claude/rules/language.md"

    # Create .cco-meta with schema_version 0
    create_cco_meta "$CCO_GLOBAL_DIR/.claude/.cco-meta" "schema_version: 0
created_at: 2026-01-01T00:00:00Z
updated_at: 2026-01-01T00:00:00Z

languages:
  communication: English
  documentation: English
  code_comments: English

manifest:"

    run_cco update
    # Schema version should be updated to latest (currently 4: migration 001 + 002 + 003 + 004)
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/.cco-meta" "schema_version: 4"
}

test_update_migration_failure_stops() {
    # If a migration fails, execution stops and schema_version is not bumped
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    # Substitute language placeholders
    sed -i "s/{{COMM_LANG}}/English/g" "$CCO_GLOBAL_DIR/.claude/rules/language.md"
    sed -i "s/{{DOCS_LANG}}/English/g" "$CCO_GLOBAL_DIR/.claude/rules/language.md"
    sed -i "s/{{CODE_LANG}}/English/g" "$CCO_GLOBAL_DIR/.claude/rules/language.md"

    # Create a failing migration with higher ID
    mkdir -p "$REPO_ROOT/migrations/global"
    cat > "$REPO_ROOT/migrations/global/999_test_fail.sh" <<'MIGEOF'
#!/usr/bin/env bash
MIGRATION_ID=999
MIGRATION_DESC="Test failure migration"
migrate() { return 1; }
MIGEOF

    # Create .cco-meta with schema_version 0
    create_cco_meta "$CCO_GLOBAL_DIR/.claude/.cco-meta" "schema_version: 0
created_at: 2026-01-01T00:00:00Z
updated_at: 2026-01-01T00:00:00Z

languages:
  communication: English
  documentation: English
  code_comments: English

manifest:"

    # Update should fail (migration 999 fails)
    run_cco update || true
    assert_output_contains "failed"

    # Cleanup test migration
    rm -f "$REPO_ROOT/migrations/global/999_test_fail.sh"
}

test_update_init_creates_cco_meta() {
    # cco init should generate a correct .cco-meta file
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "Italian:Italian:English"

    local meta="$CCO_GLOBAL_DIR/.claude/.cco-meta"
    assert_file_exists "$meta" ".cco-meta should be created by init"
    assert_file_contains "$meta" "schema_version:"
    assert_file_contains "$meta" "communication: Italian"
    assert_file_contains "$meta" "documentation: Italian"
    assert_file_contains "$meta" "code_comments: English"
    assert_file_contains "$meta" "manifest:"
    # Manifest should list managed files
    assert_file_contains "$meta" "CLAUDE.md:"
    assert_file_contains "$meta" "settings.json:"
    assert_file_contains "$meta" "rules/workflow.md:"
}

test_update_language_preserved() {
    # Language choices survive updates
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "Italian:Italian:English"

    # Verify language.md has Italian
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/rules/language.md" "Italian"

    # Run update
    run_cco update

    # Language should still be Italian
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/rules/language.md" "Italian"
    # .cco-meta should still have Italian
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/.cco-meta" "communication: Italian"
}

test_update_help() {
    # --help should show usage text
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco update --help
    assert_output_contains "Usage: cco update"
    assert_output_contains "--dry-run"
    assert_output_contains "--force"
    assert_output_contains "--project"
}

# ── Migration 003: user-config-dir restructure ──────────────────────

# Helper: source colors for direct migration tests
_source_migration_deps() {
    source "$REPO_ROOT/lib/colors.sh"
}

test_migration_003_moves_directories() {
    # Migration 003 should move global/, projects/, packs/ into user-config/
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_migration_deps

    # Create old layout
    mkdir -p "$tmpdir/global/.claude/rules"
    echo "# Test CLAUDE.md" > "$tmpdir/global/.claude/CLAUDE.md"
    echo "# Test rule" > "$tmpdir/global/.claude/rules/workflow.md"
    mkdir -p "$tmpdir/global/packs/test-pack"
    echo "name: test" > "$tmpdir/global/packs/test-pack/pack.yml"
    mkdir -p "$tmpdir/projects/my-proj/.claude"
    echo "name: my-proj" > "$tmpdir/projects/my-proj/project.yml"

    # Run migration with REPO_ROOT pointing to tmpdir
    local saved_repo_root="$REPO_ROOT"
    REPO_ROOT="$tmpdir"
    unset CCO_USER_CONFIG_DIR
    source "$saved_repo_root/migrations/global/003_user-config-dir.sh"
    migrate "$tmpdir/global/.claude"
    REPO_ROOT="$saved_repo_root"

    # Verify new structure
    assert_dir_exists "$tmpdir/user-config/global/.claude"
    assert_file_exists "$tmpdir/user-config/global/.claude/CLAUDE.md"
    assert_file_exists "$tmpdir/user-config/global/.claude/rules/workflow.md"
    assert_dir_exists "$tmpdir/user-config/packs/test-pack"
    assert_file_exists "$tmpdir/user-config/packs/test-pack/pack.yml"
    assert_dir_exists "$tmpdir/user-config/projects/my-proj"
    assert_file_exists "$tmpdir/user-config/projects/my-proj/project.yml"
    assert_dir_exists "$tmpdir/user-config/templates"

    # Verify old structure is gone
    assert_dir_not_exists "$tmpdir/global"
    assert_dir_not_exists "$tmpdir/projects"
}

test_migration_003_idempotent() {
    # Running migration 003 twice should be safe (second run is a no-op)
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_migration_deps

    # Create old layout
    mkdir -p "$tmpdir/global/.claude/rules"
    echo "# CLAUDE.md" > "$tmpdir/global/.claude/CLAUDE.md"
    mkdir -p "$tmpdir/projects/proj1"

    # Run migration twice
    local saved_repo_root="$REPO_ROOT"
    REPO_ROOT="$tmpdir"
    unset CCO_USER_CONFIG_DIR
    source "$saved_repo_root/migrations/global/003_user-config-dir.sh"
    migrate "$tmpdir/global/.claude"

    # Second run — user-config/global/.claude already exists → skip
    migrate "$tmpdir/user-config/global/.claude"
    REPO_ROOT="$saved_repo_root"

    # Should still be valid
    assert_dir_exists "$tmpdir/user-config/global/.claude"
    assert_file_exists "$tmpdir/user-config/global/.claude/CLAUDE.md"
}

test_migration_003_fresh_install_noop() {
    # Fresh installs (no old global/) should skip migration
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_migration_deps

    # No old global/ exists — just user-config/
    mkdir -p "$tmpdir/user-config/global/.claude"

    local saved_repo_root="$REPO_ROOT"
    REPO_ROOT="$tmpdir"
    unset CCO_USER_CONFIG_DIR
    source "$saved_repo_root/migrations/global/003_user-config-dir.sh"
    migrate "$tmpdir/user-config/global/.claude"
    REPO_ROOT="$saved_repo_root"

    # Nothing should have changed
    assert_dir_exists "$tmpdir/user-config/global/.claude"
}

test_migration_003_elevates_packs() {
    # Packs should be elevated from global/packs/ to user-config/packs/ (sibling, not nested)
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_migration_deps

    mkdir -p "$tmpdir/global/.claude"
    mkdir -p "$tmpdir/global/packs/pack-a"
    echo "name: a" > "$tmpdir/global/packs/pack-a/pack.yml"
    mkdir -p "$tmpdir/global/packs/pack-b"
    echo "name: b" > "$tmpdir/global/packs/pack-b/pack.yml"

    local saved_repo_root="$REPO_ROOT"
    REPO_ROOT="$tmpdir"
    unset CCO_USER_CONFIG_DIR
    source "$saved_repo_root/migrations/global/003_user-config-dir.sh"
    migrate "$tmpdir/global/.claude"
    REPO_ROOT="$saved_repo_root"

    # Packs should be at user-config/packs/, not user-config/global/packs/
    assert_dir_exists "$tmpdir/user-config/packs/pack-a"
    assert_dir_exists "$tmpdir/user-config/packs/pack-b"
    assert_dir_not_exists "$tmpdir/user-config/global/packs"
}

test_migration_003_no_projects_dir() {
    # If only global/ exists (no projects/), migration should still work
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_migration_deps

    mkdir -p "$tmpdir/global/.claude"
    echo "# CLAUDE.md" > "$tmpdir/global/.claude/CLAUDE.md"
    # No projects/ directory

    local saved_repo_root="$REPO_ROOT"
    REPO_ROOT="$tmpdir"
    unset CCO_USER_CONFIG_DIR
    source "$saved_repo_root/migrations/global/003_user-config-dir.sh"
    migrate "$tmpdir/global/.claude"
    REPO_ROOT="$saved_repo_root"

    assert_dir_exists "$tmpdir/user-config/global/.claude"
    assert_dir_exists "$tmpdir/user-config/projects"
    assert_dir_exists "$tmpdir/user-config/templates"
}

# ── Root file copy-if-missing ────────────────────────────────────────

test_update_global_missing_setup_sh_restored() {
    # cco update restores missing global setup.sh from defaults
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Verify setup.sh was created by init
    [[ -f "$CCO_GLOBAL_DIR/setup.sh" ]] || fail "setup.sh not created by init"

    # Delete it to simulate missing file
    rm "$CCO_GLOBAL_DIR/setup.sh"
    [[ ! -f "$CCO_GLOBAL_DIR/setup.sh" ]] || fail "setup.sh should be deleted"

    # Run update — should restore it
    run_cco update
    [[ -f "$CCO_GLOBAL_DIR/setup.sh" ]] || fail "setup.sh not restored by update"
    assert_output_contains "setup.sh"
}

test_update_global_existing_setup_sh_not_overwritten() {
    # cco update does NOT overwrite existing global setup.sh
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # User customizes setup.sh
    printf '#!/bin/bash\napt-get install -y tmux\n' > "$CCO_GLOBAL_DIR/setup.sh"

    run_cco update
    # User content preserved
    assert_file_contains "$CCO_GLOBAL_DIR/setup.sh" "apt-get install"
}

test_update_global_missing_setup_sh_dry_run() {
    # --dry-run reports missing global setup.sh without copying
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    rm "$CCO_GLOBAL_DIR/setup.sh"

    run_cco update --dry-run
    assert_output_contains "setup.sh"
    assert_output_contains "missing"
    # File should NOT be created in dry-run
    [[ ! -f "$CCO_GLOBAL_DIR/setup.sh" ]] || fail "setup.sh should not be created in dry-run"
}

test_update_project_missing_setup_sh_restored() {
    # cco update --project restores missing project setup.sh from template
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    run_cco project create "test-proj" --repo "$CCO_DUMMY_REPO"

    # Delete setup.sh
    rm "$CCO_PROJECTS_DIR/test-proj/setup.sh"

    run_cco update --project test-proj
    [[ -f "$CCO_PROJECTS_DIR/test-proj/setup.sh" ]] || fail "setup.sh not restored by update"
    assert_output_contains "setup.sh"
}
