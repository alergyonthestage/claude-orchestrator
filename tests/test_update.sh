#!/usr/bin/env bash
# tests/test_update.sh — cco update command tests
#
# Verifies the update system: file change detection, conflict resolution,
# migrations, .cco/meta generation, and dry-run mode.

# ── Helper: init a global dir with .cco/meta ─────────────────────────

# Run cco init and return tmpdir. Sets up CCO env vars.
_setup_initialized() {
    local tmpdir; tmpdir=$(mktemp -d)
    setup_cco_env "$tmpdir"
    run_cco init --lang "Italian:Italian:English"
    echo "$tmpdir"
}

# ── Tests ─────────────────────────────────────────────────────────────

test_update_first_run_no_meta() {
    # First update on an install that has no .cco/meta should create it
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    # Simulate pre-update install (no .cco/meta)
    setup_global_from_defaults "$tmpdir"
    # Substitute language placeholders manually (as old init would)
    sed -i "s/{{COMM_LANG}}/English/g" "$CCO_GLOBAL_DIR/.claude/rules/language.md"
    sed -i "s/{{DOCS_LANG}}/English/g" "$CCO_GLOBAL_DIR/.claude/rules/language.md"
    sed -i "s/{{CODE_LANG}}/English/g" "$CCO_GLOBAL_DIR/.claude/rules/language.md"

    run_cco update
    assert_file_exists "$CCO_GLOBAL_DIR/.claude/.cco/meta" \
        "update should generate .cco/meta"
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/.cco/meta" "schema_version:"
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/.cco/meta" "manifest:"
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
    # When a default file changes but user hasn't modified it → safe update via --force
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Simulate framework update: modify a default file
    printf '# Updated workflow rules\n- New rule added\n' >> "$REPO_ROOT/defaults/global/.claude/rules/workflow.md"

    run_cco update --force
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

test_update_keep_survives_second_run() {
    # After --keep, a second update must NOT overwrite the kept file
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Create conflict: user modifies + framework changes
    printf '\n# My custom rule\n' >> "$CCO_GLOBAL_DIR/.claude/rules/workflow.md"
    printf '\n# Framework update\n' >> "$REPO_ROOT/defaults/global/.claude/rules/workflow.md"

    # First run: keep user version
    run_cco update --keep

    # Second run: no flags (default replace mode) — should see NO_UPDATE
    run_cco update
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/rules/workflow.md" "My custom rule" \
        "Kept file must survive a second update"

    # Restore
    cd "$REPO_ROOT" && git checkout -- defaults/global/.claude/rules/workflow.md
}

test_update_replace_creates_bak() {
    # --replace creates .bak file and overwrites with new default
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Create conflict
    printf '\n# My custom rule\n' >> "$CCO_GLOBAL_DIR/.claude/rules/workflow.md"
    printf '\n# Framework update\n' >> "$REPO_ROOT/defaults/global/.claude/rules/workflow.md"

    run_cco update --replace
    # Backup should exist with user's version
    assert_file_exists "$CCO_GLOBAL_DIR/.claude/rules/workflow.md.bak"
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/rules/workflow.md.bak" "My custom rule"
    # Updated file should have framework changes
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/rules/workflow.md" "Framework update"

    # Restore
    cd "$REPO_ROOT" && git checkout -- defaults/global/.claude/rules/workflow.md
}

test_update_new_file_added() {
    # New file in defaults is added via --force (auto-replace)
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Add a new file to defaults
    printf '# New Rule\nSome new convention.\n' > "$REPO_ROOT/defaults/global/.claude/rules/new-rule.md"

    run_cco update --force
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

    # Create .cco/meta with schema_version 0
    create_cco_meta "$CCO_GLOBAL_DIR/.claude/.cco/meta" "schema_version: 0
created_at: 2026-01-01T00:00:00Z
updated_at: 2026-01-01T00:00:00Z

languages:
  communication: English
  documentation: English
  code_comments: English

manifest:"

    run_cco update
    # Schema version should be updated to latest (currently 9: migration 001-009)
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/.cco/meta" "schema_version: 9"
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

    # Create .cco/meta with schema_version 0
    create_cco_meta "$CCO_GLOBAL_DIR/.claude/.cco/meta" "schema_version: 0
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
    # cco init should generate a correct .cco/meta file
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "Italian:Italian:English"

    local meta="$CCO_GLOBAL_DIR/.claude/.cco/meta"
    assert_file_exists "$meta" ".cco/meta should be created by init"
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
    # .cco/meta should still have Italian
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/.cco/meta" "communication: Italian"
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

# ── Migration 005: split global setup ─────────────────────────────────

test_migration_005_renames_setup_with_build_content() {
    # setup.sh with apt-get → renamed to setup-build.sh, new setup.sh created
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    # Simulate pre-migration state: only setup.sh with build content
    printf '#!/bin/bash\napt-get update && apt-get install -y vim\n' > "$CCO_GLOBAL_DIR/setup.sh"

    # Set schema_version to 4 (before migration 005)
    create_cco_meta "$CCO_GLOBAL_DIR/.claude/.cco/meta" "schema_version: 4
created_at: 2026-01-01T00:00:00Z
updated_at: 2026-01-01T00:00:00Z

languages:
  communication: English
  documentation: English
  code_comments: English

manifest:"

    run_cco update
    # setup-build.sh should contain the old content
    assert_file_contains "$CCO_GLOBAL_DIR/setup-build.sh" "apt-get install"
    # setup.sh should be the new runtime template (old content replaced)
    assert_file_contains "$CCO_GLOBAL_DIR/setup.sh" "runtime"
    assert_file_not_contains "$CCO_GLOBAL_DIR/setup.sh" "apt-get install"
    # Backup should exist
    [[ -f "$CCO_GLOBAL_DIR/setup.sh.bak" ]] || fail "setup.sh.bak backup not created"
}

test_migration_005_empty_setup_creates_templates() {
    # setup.sh with only comments → both templates created fresh
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    # Simulate pre-migration: setup.sh with only comments
    printf '#!/bin/bash\n# Global setup\n' > "$CCO_GLOBAL_DIR/setup.sh"

    create_cco_meta "$CCO_GLOBAL_DIR/.claude/.cco/meta" "schema_version: 4
created_at: 2026-01-01T00:00:00Z
updated_at: 2026-01-01T00:00:00Z

languages:
  communication: English
  documentation: English
  code_comments: English

manifest:"

    run_cco update
    [[ -f "$CCO_GLOBAL_DIR/setup-build.sh" ]] || fail "setup-build.sh not created"
    [[ -f "$CCO_GLOBAL_DIR/setup.sh" ]] || fail "setup.sh not created"
    assert_file_contains "$CCO_GLOBAL_DIR/setup-build.sh" "build-time"
    assert_file_contains "$CCO_GLOBAL_DIR/setup.sh" "runtime"
}

test_migration_005_both_files_exist_warns() {
    # setup-build.sh already exists + setup.sh has build commands → migration warns
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    # Both files exist: setup-build.sh (user-created) and setup.sh (with build commands)
    printf '#!/bin/bash\napt-get install -y vim\n' > "$CCO_GLOBAL_DIR/setup-build.sh"
    printf '#!/bin/bash\napt-get install -y curl\n' > "$CCO_GLOBAL_DIR/setup.sh"

    create_cco_meta "$CCO_GLOBAL_DIR/.claude/.cco/meta" "schema_version: 4
created_at: 2026-01-01T00:00:00Z
updated_at: 2026-01-01T00:00:00Z

languages:
  communication: English
  documentation: English
  code_comments: English

manifest:"

    run_cco update
    # Migration should warn about build-time commands in setup.sh
    assert_output_contains "WARNING"
    # setup-build.sh should be preserved (not overwritten)
    assert_file_contains "$CCO_GLOBAL_DIR/setup-build.sh" "vim"
}

test_migration_005_idempotent() {
    # Running migration twice produces same result
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    printf '#!/bin/bash\napt-get install -y vim\n' > "$CCO_GLOBAL_DIR/setup.sh"

    create_cco_meta "$CCO_GLOBAL_DIR/.claude/.cco/meta" "schema_version: 4
created_at: 2026-01-01T00:00:00Z
updated_at: 2026-01-01T00:00:00Z

languages:
  communication: English
  documentation: English
  code_comments: English

manifest:"

    run_cco update
    local build_hash; build_hash=$(sha256sum "$CCO_GLOBAL_DIR/setup-build.sh" | cut -d' ' -f1)

    # Run update again (schema is now 5, no migrations should run)
    run_cco update
    local build_hash2; build_hash2=$(sha256sum "$CCO_GLOBAL_DIR/setup-build.sh" | cut -d' ' -f1)
    [[ "$build_hash" == "$build_hash2" ]] || fail "setup-build.sh changed on second update"
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

test_update_global_missing_setup_build_sh_restored() {
    # cco update restores missing global setup-build.sh from defaults
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Verify setup-build.sh was created by init
    [[ -f "$CCO_GLOBAL_DIR/setup-build.sh" ]] || fail "setup-build.sh not created by init"

    # Delete it to simulate missing file
    rm "$CCO_GLOBAL_DIR/setup-build.sh"

    # Run update — should restore it
    run_cco update
    [[ -f "$CCO_GLOBAL_DIR/setup-build.sh" ]] || fail "setup-build.sh not restored by update"
    assert_output_contains "setup-build.sh"
}

test_update_global_existing_setup_build_sh_not_overwritten() {
    # cco update does NOT overwrite existing global setup-build.sh
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # User customizes setup-build.sh
    printf '#!/bin/bash\napt-get install -y terraform\n' > "$CCO_GLOBAL_DIR/setup-build.sh"

    run_cco update
    # User content preserved
    assert_file_contains "$CCO_GLOBAL_DIR/setup-build.sh" "apt-get install"
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

# ── CLI Modes & Interactive Apply ────────────────────────────────────

test_update_discovery_mode_no_file_changes() {
    # Default mode (no flags) shows discovery summary but does NOT modify files
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Modify a default file to create an available update
    printf '\n# Framework improvement\n' >> "$REPO_ROOT/defaults/global/.claude/rules/workflow.md"

    # Save user file content before update
    local before_hash; before_hash=$(sha256sum "$CCO_GLOBAL_DIR/.claude/rules/workflow.md" | cut -d' ' -f1)
    local before_base_hash=""
    [[ -f "$CCO_GLOBAL_DIR/.claude/.cco/base/rules/workflow.md" ]] && \
        before_base_hash=$(sha256sum "$CCO_GLOBAL_DIR/.claude/.cco/base/rules/workflow.md" | cut -d' ' -f1)

    run_cco update
    assert_output_contains "update"

    # File must NOT be modified
    local after_hash; after_hash=$(sha256sum "$CCO_GLOBAL_DIR/.claude/rules/workflow.md" | cut -d' ' -f1)
    [[ "$before_hash" == "$after_hash" ]] || fail "Discovery mode modified installed file"

    # .cco/base/ must NOT be updated
    local after_base_hash=""
    [[ -f "$CCO_GLOBAL_DIR/.claude/.cco/base/rules/workflow.md" ]] && \
        after_base_hash=$(sha256sum "$CCO_GLOBAL_DIR/.claude/.cco/base/rules/workflow.md" | cut -d' ' -f1)
    [[ "$before_base_hash" == "$after_base_hash" ]] || fail "Discovery mode updated .cco/base/"

    # Restore
    cd "$REPO_ROOT" && git checkout -- defaults/global/.claude/rules/workflow.md
}

test_update_diff_shows_changes() {
    # --diff mode shows diffs without modifying files
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Modify a default to create an available update
    printf '\n# Diff test change\n' >> "$REPO_ROOT/defaults/global/.claude/rules/workflow.md"

    local before_hash; before_hash=$(sha256sum "$CCO_GLOBAL_DIR/.claude/rules/workflow.md" | cut -d' ' -f1)

    run_cco update --diff
    # Output should contain either diff markers or the file path
    assert_output_contains "workflow.md"

    # File must NOT be modified
    local after_hash; after_hash=$(sha256sum "$CCO_GLOBAL_DIR/.claude/rules/workflow.md" | cut -d' ' -f1)
    [[ "$before_hash" == "$after_hash" ]] || fail "--diff mode modified installed file"

    # Restore
    cd "$REPO_ROOT" && git checkout -- defaults/global/.claude/rules/workflow.md
}

test_update_news_shows_entries() {
    # --news mode shows changelog entries and updates both trackers
    local tmpdir; tmpdir=$(mktemp -d)
    local saved_changelog="$tmpdir/changelog.bak"
    cp "$REPO_ROOT/changelog.yml" "$saved_changelog"
    trap "cp '$saved_changelog' '$REPO_ROOT/changelog.yml'; rm -rf '$tmpdir'" EXIT

    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Create a changelog with one entry
    cat > "$REPO_ROOT/changelog.yml" <<'YML'
entries:
  - id: 1
    date: "2026-03-01"
    type: additive
    title: "Test feature for news"
    description: "A test description for news mode"
YML

    # Set both trackers to 0 in .cco/meta
    local meta="$CCO_GLOBAL_DIR/.claude/.cco/meta"
    if grep -q '^last_seen_changelog:' "$meta"; then
        sed -i "s/^last_seen_changelog: .*/last_seen_changelog: 0/" "$meta"
    fi
    if grep -q '^last_read_changelog:' "$meta"; then
        sed -i "s/^last_read_changelog: .*/last_read_changelog: 0/" "$meta"
    else
        sed -i '/^last_seen_changelog:/a last_read_changelog: 0' "$meta"
    fi

    run_cco update --news
    assert_output_contains "Test feature for news"

    # Both trackers should be updated to 1
    assert_file_contains "$meta" "last_seen_changelog: 1"
    assert_file_contains "$meta" "last_read_changelog: 1"
}

test_update_news_no_new_entries() {
    # --news with no new entries shows "No new features"
    local tmpdir; tmpdir=$(mktemp -d)
    local saved_changelog="$tmpdir/changelog.bak"
    cp "$REPO_ROOT/changelog.yml" "$saved_changelog"
    trap "cp '$saved_changelog' '$REPO_ROOT/changelog.yml'; rm -rf '$tmpdir'" EXIT

    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Create a changelog with one entry already read
    cat > "$REPO_ROOT/changelog.yml" <<'YML'
entries:
  - id: 1
    date: "2026-03-01"
    type: additive
    title: "Already seen feature"
    description: "Already seen"
YML

    # Set both trackers to 1 (already seen and read)
    local meta="$CCO_GLOBAL_DIR/.claude/.cco/meta"
    if grep -q '^last_seen_changelog:' "$meta"; then
        sed -i "s/^last_seen_changelog: .*/last_seen_changelog: 1/" "$meta"
    fi
    # Append last_read_changelog if missing
    if grep -q '^last_read_changelog:' "$meta"; then
        sed -i "s/^last_read_changelog: .*/last_read_changelog: 1/" "$meta"
    else
        sed -i '/^last_seen_changelog:/a last_read_changelog: 1' "$meta"
    fi

    run_cco update --news
    assert_output_contains "No new features"
}

test_update_discovery_then_news() {
    # Discovery updates last_seen only; subsequent --news still shows details
    local tmpdir; tmpdir=$(mktemp -d)
    local saved_changelog="$tmpdir/changelog.bak"
    cp "$REPO_ROOT/changelog.yml" "$saved_changelog"
    trap "cp '$saved_changelog' '$REPO_ROOT/changelog.yml'; rm -rf '$tmpdir'" EXIT

    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    cat > "$REPO_ROOT/changelog.yml" <<'YML'
entries:
  - id: 1
    date: "2026-03-01"
    type: additive
    title: "Dual tracker test feature"
    description: "Details about the feature"
YML

    local meta="$CCO_GLOBAL_DIR/.claude/.cco/meta"
    sed -i "s/^last_seen_changelog: .*/last_seen_changelog: 0/" "$meta"

    # Step 1: Discovery — shows summary, updates last_seen only
    run_cco update
    assert_output_contains "Dual tracker test feature"
    assert_output_contains "Run 'cco update --news'"
    assert_file_contains "$meta" "last_seen_changelog: 1"

    # Step 2: News — still shows details (last_read was 0)
    run_cco update --news
    assert_output_contains "Dual tracker test feature"
    assert_output_contains "Details about the feature"
    assert_file_contains "$meta" "last_read_changelog: 1"

    # Step 3: Discovery again — nothing to show, no hint
    run_cco update
    assert_output_not_contains "What's new"
    assert_output_not_contains "Run 'cco update --news'"
}

test_update_news_first_then_discovery() {
    # --news first updates both trackers; subsequent discovery shows nothing
    local tmpdir; tmpdir=$(mktemp -d)
    local saved_changelog="$tmpdir/changelog.bak"
    cp "$REPO_ROOT/changelog.yml" "$saved_changelog"
    trap "cp '$saved_changelog' '$REPO_ROOT/changelog.yml'; rm -rf '$tmpdir'" EXIT

    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    cat > "$REPO_ROOT/changelog.yml" <<'YML'
entries:
  - id: 1
    date: "2026-03-01"
    type: additive
    title: "News first test"
    description: "Detailed description"
YML

    local meta="$CCO_GLOBAL_DIR/.claude/.cco/meta"
    sed -i "s/^last_seen_changelog: .*/last_seen_changelog: 0/" "$meta"

    # Step 1: News first — shows details, updates both trackers
    run_cco update --news
    assert_output_contains "News first test"
    assert_file_contains "$meta" "last_seen_changelog: 1"
    assert_file_contains "$meta" "last_read_changelog: 1"

    # Step 2: Discovery — nothing to show, no hint (both at latest)
    run_cco update
    assert_output_not_contains "What's new"
    assert_output_not_contains "Run 'cco update --news'"
}

test_update_diff_force_mutual_exclusion() {
    # --diff and --force are mutually exclusive
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Run with --force before --diff so --diff is parsed last and cmd_mode stays "diff"
    run_cco update --force --diff && fail "Expected error for --force --diff" || true
    assert_output_contains "mutually exclusive"
}

test_update_diff_keep_mutual_exclusion() {
    # --diff and --keep are mutually exclusive
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Run with --keep before --diff so --diff is parsed last and cmd_mode stays "diff"
    run_cco update --keep --diff && fail "Expected error for --keep --diff" || true
    assert_output_contains "mutually exclusive"
}

test_update_apply_non_tty_skips() {
    # Non-TTY stdin causes --apply to skip all changes
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Modify a default file to create an available update
    printf '\n# Non-TTY test change\n' >> "$REPO_ROOT/defaults/global/.claude/rules/workflow.md"

    local before_hash; before_hash=$(sha256sum "$CCO_GLOBAL_DIR/.claude/rules/workflow.md" | cut -d' ' -f1)

    # Run --apply with stdin from /dev/null (non-TTY)
    CCO_OUTPUT=$(
        CCO_USER_CONFIG_DIR="$CCO_USER_CONFIG_DIR" \
        CCO_GLOBAL_DIR="$CCO_GLOBAL_DIR" \
        CCO_PROJECTS_DIR="$CCO_PROJECTS_DIR" \
        CCO_PACKS_DIR="$CCO_PACKS_DIR" \
        CCO_TEMPLATES_DIR="$CCO_TEMPLATES_DIR" \
        bash "$REPO_ROOT/bin/cco" update --apply < /dev/null 2>&1
    ) || true
    assert_output_contains "Non-interactive"

    # File must NOT be modified (auto-skip)
    local after_hash; after_hash=$(sha256sum "$CCO_GLOBAL_DIR/.claude/rules/workflow.md" | cut -d' ' -f1)
    [[ "$before_hash" == "$after_hash" ]] || fail "Non-TTY apply modified installed file"

    # Restore
    cd "$REPO_ROOT" && git checkout -- defaults/global/.claude/rules/workflow.md
}

test_update_dry_run_shows_migrations() {
    # --dry-run shows pending migrations without running them
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Lower schema_version to simulate pending migrations
    local meta="$CCO_GLOBAL_DIR/.claude/.cco/meta"
    sed -i "s/^schema_version: .*/schema_version: 0/" "$meta"

    run_cco update --dry-run
    assert_output_contains "migration(s) pending"
    assert_output_contains "Dry run complete"

    # schema_version must NOT be updated
    assert_file_contains "$meta" "schema_version: 0"
}

test_update_force_applies_changes() {
    # --force (hidden alias for --apply + auto_action=replace) applies all changes
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Create an update: modify default (framework changes)
    printf '\n# Force-applied change\n' >> "$REPO_ROOT/defaults/global/.claude/rules/workflow.md"

    run_cco update --force
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/rules/workflow.md" "Force-applied change"

    # Restore
    cd "$REPO_ROOT" && git checkout -- defaults/global/.claude/rules/workflow.md
}

test_update_keep_preserves_user_file() {
    # --keep preserves user file and updates .cco/base/ to current default
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Both user and framework change (conflict scenario)
    printf '\n# User edit for keep test\n' >> "$CCO_GLOBAL_DIR/.claude/rules/workflow.md"
    printf '\n# Framework edit for keep test\n' >> "$REPO_ROOT/defaults/global/.claude/rules/workflow.md"

    run_cco update --keep
    # User file must be preserved
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/rules/workflow.md" "User edit for keep test"
    # .cco/base/ IS updated to current default (so next update won't re-trigger)
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/.cco/base/rules/workflow.md" "Framework edit for keep test"

    # Restore
    cd "$REPO_ROOT" && git checkout -- defaults/global/.claude/rules/workflow.md
}

# ── Project Create Bootstrap ─────────────────────────────────────────

test_project_create_initializes_cco_meta() {
    # cco project create should generate .cco/meta and .cco/base/
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    run_cco project create "test-bootstrap" --repo "$CCO_DUMMY_REPO"

    local proj_dir="$CCO_PROJECTS_DIR/test-bootstrap"
    assert_file_exists "$proj_dir/.cco/meta" ".cco/meta should exist after project create"
    assert_file_contains "$proj_dir/.cco/meta" "schema_version:"
    assert_dir_exists "$proj_dir/.cco/base" ".cco/base/ should exist after project create"
}

test_project_create_cco_source_not_for_base() {
    # Base template (default) should NOT create .cco/source
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    run_cco project create "test-base-src" --repo "$CCO_DUMMY_REPO"

    assert_file_not_exists "$CCO_PROJECTS_DIR/test-base-src/.cco/source" \
        ".cco/source should NOT exist for base template"
}

test_project_create_cco_source_for_tutorial() {
    # Tutorial template should create .cco/source with native:project/tutorial
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    run_cco project create "test-tut-src" --repo "$CCO_DUMMY_REPO" --template tutorial

    local source_file="$CCO_PROJECTS_DIR/test-tut-src/.cco/source"
    assert_file_exists "$source_file" ".cco/source should exist for tutorial template"
    assert_file_contains "$source_file" "native:project/tutorial"
}

# ── Template Source Resolution ───────────────────────────────────────

test_resolve_project_defaults_dir_base() {
    # Project with no .cco/source returns base template path
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"

    # Source the necessary libs and set required globals
    export NATIVE_TEMPLATES_DIR="$REPO_ROOT/templates"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/update.sh"

    # Create a minimal project dir without .cco/source
    local proj_dir="$tmpdir/test-proj"
    mkdir -p "$proj_dir"

    local result
    result=$(_resolve_project_defaults_dir "$proj_dir")
    [[ "$result" == *"templates/project/base/.claude"* ]] || \
        fail "Expected base template path, got: $result"
}

test_resolve_project_defaults_dir_tutorial() {
    # Project with .cco/source pointing to tutorial returns tutorial template path
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"

    export NATIVE_TEMPLATES_DIR="$REPO_ROOT/templates"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/update.sh"

    local proj_dir="$tmpdir/test-proj"
    mkdir -p "$proj_dir/.cco"
    printf 'native:project/tutorial\n' > "$proj_dir/.cco/source"

    local result
    result=$(_resolve_project_defaults_dir "$proj_dir")
    [[ "$result" == *"templates/project/tutorial/.claude"* ]] || \
        fail "Expected tutorial template path, got: $result"
}

# ── Changelog Parsing ────────────────────────────────────────────────

test_read_changelog_entries_empty() {
    # changelog.yml with entries: [] returns no output
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT

    cat > "$tmpdir/changelog.yml" <<'YML'
entries: []
YML

    local saved_repo_root="$REPO_ROOT"
    REPO_ROOT="$tmpdir"
    source "$saved_repo_root/lib/colors.sh"
    source "$saved_repo_root/lib/utils.sh"
    source "$saved_repo_root/lib/paths.sh"
    source "$saved_repo_root/lib/update.sh"

    local result
    result=$(_read_changelog_entries)
    REPO_ROOT="$saved_repo_root"
    [[ -z "$result" ]] || fail "Expected empty output for empty changelog, got: $result"
}

test_read_changelog_entries_with_entries() {
    # changelog.yml with entries returns correct id/title pairs
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT

    cat > "$tmpdir/changelog.yml" <<'YML'
entries:
  - id: 1
    date: "2026-01-15"
    type: additive
    title: "First feature"
    description: "First desc"
  - id: 2
    date: "2026-02-01"
    type: additive
    title: "Second feature"
    description: "Second desc"
YML

    local saved_repo_root="$REPO_ROOT"
    REPO_ROOT="$tmpdir"
    source "$saved_repo_root/lib/colors.sh"
    source "$saved_repo_root/lib/utils.sh"
    source "$saved_repo_root/lib/paths.sh"
    source "$saved_repo_root/lib/update.sh"

    local result
    result=$(_read_changelog_entries)
    REPO_ROOT="$saved_repo_root"
    local count
    count=$(echo "$result" | grep -c '.' || true)
    [[ "$count" -eq 2 ]] || fail "Expected 2 entries, got $count"

    # Verify entry content
    echo "$result" | grep -qF "First feature" || fail "First entry title not found"
    echo "$result" | grep -qF "Second feature" || fail "Second entry title not found"
}

# ── 3-Way Merge Tests ────────────────────────────────────────────────

test_merge_file_clean_merge() {
    # When user and framework modify different sections, merge succeeds cleanly
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT

    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/update.sh"

    # Base version (ancestor)
    cat > "$tmpdir/base.md" <<'EOF'
# Section A
Original A content.

# Section B
Original B content.
EOF

    # User modified section A
    cat > "$tmpdir/user.md" <<'EOF'
# Section A
User modified A content.

# Section B
Original B content.
EOF

    # Framework modified section B
    cat > "$tmpdir/new.md" <<'EOF'
# Section A
Original A content.

# Section B
Framework modified B content.
EOF

    _merge_file "$tmpdir/user.md" "$tmpdir/base.md" "$tmpdir/new.md" "$tmpdir/output.md"
    local rc=$?
    [[ $rc -eq 0 ]] || fail "Expected clean merge (rc=0), got rc=$rc"

    # Output should contain both modifications
    assert_file_contains "$tmpdir/output.md" "User modified A content"
    assert_file_contains "$tmpdir/output.md" "Framework modified B content"
}

test_merge_file_conflict() {
    # When user and framework modify the same line, conflict markers appear
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT

    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/update.sh"

    cat > "$tmpdir/base.md" <<'EOF'
# Rules
Follow the standard process.
EOF

    cat > "$tmpdir/user.md" <<'EOF'
# Rules
Follow the user custom process.
EOF

    cat > "$tmpdir/new.md" <<'EOF'
# Rules
Follow the improved framework process.
EOF

    _merge_file "$tmpdir/user.md" "$tmpdir/base.md" "$tmpdir/new.md" "$tmpdir/output.md"
    local rc=$?
    [[ $rc -ne 0 ]] || fail "Expected non-zero exit (conflict), got rc=0"

    assert_file_contains "$tmpdir/output.md" "<<<<<<<"
}

test_merge_file_no_base_fallback() {
    # When base file does not exist, _merge_file should fail gracefully
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT

    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/update.sh"

    echo "user content" > "$tmpdir/user.md"
    echo "new content" > "$tmpdir/new.md"

    _merge_file "$tmpdir/user.md" "$tmpdir/nonexistent_base.md" "$tmpdir/new.md" "$tmpdir/output.md" 2>/dev/null
    local rc=$?
    [[ $rc -ne 0 ]] || fail "Expected non-zero exit for missing base file, got rc=0"
}

# ── Discovery Status Tests ───────────────────────────────────────────

test_collect_file_changes_merge_available() {
    # When both user and framework modified a file, status is MERGE_AVAILABLE
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT

    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/update.sh"

    mkdir -p "$tmpdir/defaults" "$tmpdir/installed" "$tmpdir/base"

    echo "original content" > "$tmpdir/base/testfile.md"
    echo "user modified content" > "$tmpdir/installed/testfile.md"
    echo "framework modified content" > "$tmpdir/defaults/testfile.md"

    local changes
    changes=$(_collect_file_changes "$tmpdir/defaults" "$tmpdir/installed" "$tmpdir/base" "project")
    echo "$changes" | grep -qF "MERGE_AVAILABLE" || \
        fail "Expected MERGE_AVAILABLE in output, got: $changes"
}

test_collect_file_changes_removed() {
    # File in .cco/base but NOT in defaults → REMOVED
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT

    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/update.sh"

    mkdir -p "$tmpdir/defaults" "$tmpdir/installed" "$tmpdir/base"

    echo "old content" > "$tmpdir/base/obsolete.md"
    echo "old content" > "$tmpdir/installed/obsolete.md"

    local changes
    changes=$(_collect_file_changes "$tmpdir/defaults" "$tmpdir/installed" "$tmpdir/base" "project")
    echo "$changes" | grep -qF "REMOVED" || \
        fail "Expected REMOVED in output, got: $changes"
}

test_collect_file_changes_base_missing() {
    # File in defaults and installed, differs, no .cco/base → BASE_MISSING
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT

    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/update.sh"

    mkdir -p "$tmpdir/defaults" "$tmpdir/installed" "$tmpdir/base"

    echo "new default content" > "$tmpdir/defaults/somefile.md"
    echo "different installed content" > "$tmpdir/installed/somefile.md"

    local changes
    changes=$(_collect_file_changes "$tmpdir/defaults" "$tmpdir/installed" "$tmpdir/base" "project")
    echo "$changes" | grep -qF "BASE_MISSING" || \
        fail "Expected BASE_MISSING in output, got: $changes"
}

test_collect_file_changes_user_modified() {
    # Framework unchanged (defaults == base), user file differs → USER_MODIFIED
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT

    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/update.sh"

    mkdir -p "$tmpdir/defaults" "$tmpdir/installed" "$tmpdir/base"

    echo "same framework content" > "$tmpdir/defaults/rule.md"
    echo "same framework content" > "$tmpdir/base/rule.md"
    echo "user customized content" > "$tmpdir/installed/rule.md"

    local changes
    changes=$(_collect_file_changes "$tmpdir/defaults" "$tmpdir/installed" "$tmpdir/base" "project")
    echo "$changes" | grep -qF "USER_MODIFIED" || \
        fail "Expected USER_MODIFIED in output, got: $changes"
}

# ── Discovery Summary Tests ──────────────────────────────────────────

test_show_discovery_summary_with_changes() {
    # Summary should display counts and suggest --diff
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT

    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/update.sh"

    local changes
    changes=$(printf 'UPDATE_AVAILABLE\tfile1.md\nMERGE_AVAILABLE\tfile2.md\nNEW\tfile3.md\n')

    local summary_output
    summary_output=$(_show_discovery_summary "$changes" "Global" 2>&1)

    echo "$summary_output" | grep -qF "update" || \
        fail "Expected summary to mention updates, got: $summary_output"
    echo "$summary_output" | grep -qF "cco update --diff" || \
        fail "Expected summary to suggest --diff, got: $summary_output"
}

test_show_discovery_summary_no_changes() {
    # When only NO_UPDATE entries, summary should output nothing
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT

    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/update.sh"

    local changes
    changes=$(printf 'NO_UPDATE\tfile1.md\nNO_UPDATE\tfile2.md\n')

    local summary_output
    summary_output=$(_show_discovery_summary "$changes" "Global" 2>&1)

    [[ -z "$summary_output" ]] || \
        fail "Expected empty summary for NO_UPDATE only, got: $summary_output"
}

# ── Project-Scoped Update Isolation ──────────────────────────────────

test_update_project_scope_isolation() {
    # Running update --project proj-a should NOT modify proj-b files
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    run_cco project create "proj-a" --repo "$CCO_DUMMY_REPO"
    run_cco project create "proj-b" --repo "$CCO_DUMMY_REPO"

    local proj_b_claude="$CCO_PROJECTS_DIR/proj-b/.claude/CLAUDE.md"
    local hash_before
    hash_before=$(sha256sum "$proj_b_claude" | cut -d' ' -f1)

    # Simulate a framework change: add new file to project template defaults
    local proj_defaults="$REPO_ROOT/templates/project/base/.claude"
    printf '# New project rule\n' > "$proj_defaults/rules/new-test-rule.md"

    # Run update scoped to proj-a only
    run_cco update --project proj-a

    # proj-b should NOT have the new file
    assert_file_not_exists "$CCO_PROJECTS_DIR/proj-b/.claude/rules/new-test-rule.md" \
        "proj-b should not be modified when updating only proj-a"

    # proj-b CLAUDE.md hash should be unchanged
    local hash_after
    hash_after=$(sha256sum "$proj_b_claude" | cut -d' ' -f1)
    [[ "$hash_before" == "$hash_after" ]] || \
        fail "proj-b CLAUDE.md was modified by proj-a update"

    # Cleanup
    rm -f "$proj_defaults/rules/new-test-rule.md"
}

# ── Migration 008: separate memory from claude-state ─────────────────

test_migration_008_copies_memory_from_claude_state() {
    # Migration 008 should copy memory from claude-state/memory/ to memory/
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_migration_deps

    # Create pre-migration layout: memory inside claude-state
    local project_dir="$tmpdir/my-proj"
    mkdir -p "$project_dir/claude-state/memory"
    echo "# Memory Index" > "$project_dir/claude-state/memory/MEMORY.md"
    echo "# Topic" > "$project_dir/claude-state/memory/topic.md"

    source "$REPO_ROOT/migrations/project/008_separate_memory.sh"
    migrate "$project_dir"

    # Verify new location
    assert_file_exists "$project_dir/memory/MEMORY.md"
    assert_file_exists "$project_dir/memory/topic.md"
    assert_file_contains "$project_dir/memory/MEMORY.md" "# Memory Index"

    # Original should still exist (not deleted, just shadowed by mount)
    assert_file_exists "$project_dir/claude-state/memory/MEMORY.md"
}

test_migration_008_idempotent() {
    # Running migration 008 twice should be safe
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_migration_deps

    local project_dir="$tmpdir/my-proj"
    mkdir -p "$project_dir/claude-state/memory"
    echo "# Memory" > "$project_dir/claude-state/memory/MEMORY.md"

    source "$REPO_ROOT/migrations/project/008_separate_memory.sh"
    migrate "$project_dir"

    # Modify the migrated file
    echo "# Updated" > "$project_dir/memory/MEMORY.md"

    # Run again — should not overwrite
    migrate "$project_dir"
    assert_file_contains "$project_dir/memory/MEMORY.md" "# Updated"
}

test_migration_008_empty_claude_state_memory() {
    # When claude-state/memory/ exists but is empty, create empty memory/
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_migration_deps

    local project_dir="$tmpdir/my-proj"
    mkdir -p "$project_dir/claude-state/memory"

    source "$REPO_ROOT/migrations/project/008_separate_memory.sh"
    migrate "$project_dir"

    assert_dir_exists "$project_dir/memory"
}

test_migration_008_no_claude_state_memory() {
    # When claude-state/memory/ doesn't exist, create empty memory/
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_migration_deps

    local project_dir="$tmpdir/my-proj"
    mkdir -p "$project_dir/claude-state"

    source "$REPO_ROOT/migrations/project/008_separate_memory.sh"
    migrate "$project_dir"

    assert_dir_exists "$project_dir/memory"
}

# ── Migration 009: .cco/ directory consolidation (global) ────────────

test_migration_009_moves_global_files() {
    # Test that global migration moves .cco-meta -> .cco/meta and .cco-base -> .cco/base
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT

    # Set up old-layout global dir
    local target="$tmpdir/global/.claude"
    mkdir -p "$target"
    echo "schema_version: 8" > "$target/.cco-meta"
    mkdir -p "$target/.cco-base"
    echo "base content" > "$target/.cco-base/settings.json"

    # Set up user-config root with .cco-remotes
    local uc_dir="$tmpdir"
    echo "acme=git@example.com:acme.git" > "$uc_dir/.cco-remotes"

    # Source required libs
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/update.sh"
    source "$REPO_ROOT/migrations/global/009_cco_dir_consolidation.sh"

    migrate "$target"

    # Verify files moved to new locations
    assert_file_exists "$target/.cco/meta"
    assert_file_contains "$target/.cco/meta" "schema_version: 8"
    [[ -d "$target/.cco/base" ]] || fail ".cco/base/ should exist"
    assert_file_exists "$target/.cco/base/settings.json"
    assert_file_exists "$uc_dir/.cco/remotes"

    # Verify old files removed
    [[ ! -f "$target/.cco-meta" ]] || fail ".cco-meta should be removed"
    [[ ! -d "$target/.cco-base" ]] || fail ".cco-base/ should be removed"
    [[ ! -f "$uc_dir/.cco-remotes" ]] || fail ".cco-remotes should be removed"
}

# ── Migration 009: .cco/ directory consolidation (project) ───────────

test_migration_009_moves_project_files() {
    # Test that project migration moves all framework files into .cco/
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT

    local target="$tmpdir/project"
    mkdir -p "$target/.claude" "$target/.managed" "$target/claude-state"
    echo "schema_version: 8" > "$target/.cco-meta"
    mkdir -p "$target/.cco-base"
    echo "base" > "$target/.cco-base/settings.json"
    echo "managed" > "$target/.managed/browser.json"
    echo "generated" > "$target/docker-compose.yml"
    echo "transcript" > "$target/claude-state/session.jsonl"
    mkdir -p "$target/.tmp"
    echo "dry-run" > "$target/.tmp/output"
    # .pack-manifest lives inside .claude/
    echo "pack-data" > "$target/.claude/.pack-manifest"

    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/update.sh"
    source "$REPO_ROOT/migrations/project/009_cco_dir_consolidation.sh"

    migrate "$target"

    # Verify new locations
    assert_file_exists "$target/.cco/meta"
    [[ -d "$target/.cco/base" ]] || fail ".cco/base/ should exist"
    assert_file_exists "$target/.cco/managed/browser.json"
    assert_file_exists "$target/.cco/docker-compose.yml"
    assert_file_exists "$target/.cco/claude-state/session.jsonl"
    assert_file_exists "$target/.claude/.cco/pack-manifest"
    assert_file_contains "$target/.claude/.cco/pack-manifest" "pack-data"

    # Verify old locations removed
    [[ ! -f "$target/.cco-meta" ]] || fail ".cco-meta should be removed"
    [[ ! -d "$target/.cco-base" ]] || fail ".cco-base/ should be removed"
    [[ ! -d "$target/.managed" ]] || fail ".managed/ should be removed"
    [[ ! -f "$target/docker-compose.yml" ]] || fail "docker-compose.yml should be removed"
    [[ ! -d "$target/claude-state" ]] || fail "claude-state/ should be removed"
    [[ ! -f "$target/.claude/.pack-manifest" ]] || fail ".claude/.pack-manifest should be removed"

    # .tmp should be cleaned (not moved)
    [[ ! -d "$target/.tmp" ]] || fail ".tmp/ should be cleaned"
}

test_migration_009_idempotent() {
    # Running migration twice should not cause errors or data loss
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT

    local target="$tmpdir/project"
    mkdir -p "$target/.claude"
    echo "v8" > "$target/.cco-meta"
    mkdir -p "$target/.cco-base"
    echo "base" > "$target/.cco-base/s.json"

    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/update.sh"
    source "$REPO_ROOT/migrations/project/009_cco_dir_consolidation.sh"

    migrate "$target"
    migrate "$target"  # second run

    # Files should still be at new locations
    assert_file_exists "$target/.cco/meta"
    [[ -d "$target/.cco/base" ]] || fail ".cco/base/ should exist after second run"
    assert_file_exists "$target/.cco/base/s.json"
}

test_migration_009_partial_state() {
    # When both old and new paths exist (partial migration), skip safely — no data loss
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT

    local target="$tmpdir/project"
    mkdir -p "$target/.claude" "$target/.cco"
    # Old AND new both exist
    echo "old" > "$target/.cco-meta"
    echo "new" > "$target/.cco/meta"

    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/update.sh"
    source "$REPO_ROOT/migrations/project/009_cco_dir_consolidation.sh"

    migrate "$target"

    # New should be preserved (canonical copy)
    assert_file_contains "$target/.cco/meta" "new"
    # Old should also be preserved (guarded skip, not deleted)
    [[ -f "$target/.cco-meta" ]] || fail ".cco-meta should be preserved when both exist (guarded skip)"
}

test_migration_009_fresh_project() {
    # Migration on fresh project (no old files) should just create .cco/
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT

    local target="$tmpdir/project"
    mkdir -p "$target/.claude"

    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/update.sh"
    source "$REPO_ROOT/migrations/project/009_cco_dir_consolidation.sh"

    migrate "$target"

    [[ -d "$target/.cco" ]] || fail ".cco/ should be created"
}

test_migration_009_gitignore_patterns() {
    # Test that vault .gitignore patterns are migrated correctly
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT

    local target="$tmpdir/global/.claude"
    mkdir -p "$target"

    # Create old-style .gitignore at user-config level
    cat > "$tmpdir/.gitignore" <<'GI'
secrets.env
projects/*/.managed/
projects/*/.tmp/
projects/*/.cco-meta
projects/*/docker-compose.yml
projects/*/claude-state/
packs/*/.cco-install-tmp/
.cco-remotes
GI

    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/update.sh"
    source "$REPO_ROOT/migrations/global/009_cco_dir_consolidation.sh"

    migrate "$target"

    # Verify new patterns
    assert_file_contains "$tmpdir/.gitignore" "projects/*/.cco/managed/"
    assert_file_contains "$tmpdir/.gitignore" "projects/*/.cco/meta"
    assert_file_contains "$tmpdir/.gitignore" "projects/*/.cco/docker-compose.yml"
    assert_file_contains "$tmpdir/.gitignore" "projects/*/.cco/claude-state/"
    assert_file_contains "$tmpdir/.gitignore" "packs/*/.cco/install-tmp/"
    assert_file_contains "$tmpdir/.gitignore" ".cco/remotes"
    assert_file_contains "$tmpdir/.gitignore" "global/.claude/.cco/meta"
    assert_file_contains "$tmpdir/.gitignore" "projects/*/.claude/.cco/pack-manifest"

    # Verify .tmp/ NOT changed (stays outside .cco)
    assert_file_contains "$tmpdir/.gitignore" "projects/*/.tmp/"

    # Verify old patterns removed
    assert_file_not_contains "$tmpdir/.gitignore" "projects/*/.managed/"
    assert_file_not_contains "$tmpdir/.gitignore" ".cco-remotes"
    assert_file_not_contains "$tmpdir/.gitignore" "projects/*/.cco-meta"
    assert_file_not_contains "$tmpdir/.gitignore" "projects/*/docker-compose.yml"
    assert_file_not_contains "$tmpdir/.gitignore" "packs/*/.cco-install-tmp/"
}

# ── Changelog: missing last_read field backward compat ───────────────

test_update_changelog_missing_last_read_field() {
    # Scenario 7: .cco/meta has last_seen but no last_read -> defaults to 0
    local tmpdir; tmpdir=$(mktemp -d)
    local saved_changelog="$tmpdir/changelog.bak"
    cp "$REPO_ROOT/changelog.yml" "$saved_changelog"
    trap "cp '$saved_changelog' '$REPO_ROOT/changelog.yml'; rm -rf '$tmpdir'" EXIT

    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    cat > "$REPO_ROOT/changelog.yml" <<'YML'
entries:
  - id: 1
    date: "2026-03-01"
    type: additive
    title: "Missing last_read test"
    description: "Test backward compat"
YML

    # Manually set last_seen but remove last_read (simulate pre-upgrade meta)
    local meta="$CCO_GLOBAL_DIR/.claude/.cco/meta"
    sed -i "s/^last_seen_changelog: .*/last_seen_changelog: 0/" "$meta"
    # Remove last_read_changelog line if present
    sed -i '/^last_read_changelog:/d' "$meta"

    # --news should show entry (last_read defaults to 0)
    run_cco update --news
    assert_output_contains "Missing last_read test"
    assert_file_contains "$meta" "last_read_changelog: 1"
}

# ── Changelog scenario 3 fix: hint absent after news-first ────────────

test_update_news_first_no_hint_on_discovery() {
    # After --news updates both trackers, discovery must NOT show the --news hint
    local tmpdir; tmpdir=$(mktemp -d)
    local saved_changelog="$tmpdir/changelog.bak"
    cp "$REPO_ROOT/changelog.yml" "$saved_changelog"
    trap "cp '$saved_changelog' '$REPO_ROOT/changelog.yml'; rm -rf '$tmpdir'" EXIT

    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    cat > "$REPO_ROOT/changelog.yml" <<'YML'
entries:
  - id: 1
    date: "2026-03-01"
    type: additive
    title: "Hint suppression test"
    description: "Details"
YML

    local meta="$CCO_GLOBAL_DIR/.claude/.cco/meta"
    sed -i "s/^last_seen_changelog: .*/last_seen_changelog: 0/" "$meta"

    # Step 1: News first — updates both trackers
    run_cco update --news
    assert_file_contains "$meta" "last_seen_changelog: 1"
    assert_file_contains "$meta" "last_read_changelog: 1"

    # Step 2: Discovery — nothing to show AND no --news hint
    run_cco update
    assert_output_not_contains "What's new"
    assert_output_not_contains "Run 'cco update --news'"
}

# ── Changelog scenario 6: new entry after both read ───────────────────

test_update_new_entry_after_both_read() {
    # Both trackers at N, new entry N+1 arrives — discovery shows it, news shows it
    local tmpdir; tmpdir=$(mktemp -d)
    local saved_changelog="$tmpdir/changelog.bak"
    cp "$REPO_ROOT/changelog.yml" "$saved_changelog"
    trap "cp '$saved_changelog' '$REPO_ROOT/changelog.yml'; rm -rf '$tmpdir'" EXIT

    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Initial state: one entry, both trackers at 1
    cat > "$REPO_ROOT/changelog.yml" <<'YML'
entries:
  - id: 1
    date: "2026-03-01"
    type: additive
    title: "First feature"
    description: "First details"
YML

    local meta="$CCO_GLOBAL_DIR/.claude/.cco/meta"
    sed -i "s/^last_seen_changelog: .*/last_seen_changelog: 1/" "$meta"
    if grep -q '^last_read_changelog:' "$meta"; then
        sed -i "s/^last_read_changelog: .*/last_read_changelog: 1/" "$meta"
    else
        sed -i '/^last_seen_changelog:/a last_read_changelog: 1' "$meta"
    fi

    # Add new entry
    cat > "$REPO_ROOT/changelog.yml" <<'YML'
entries:
  - id: 1
    date: "2026-03-01"
    type: additive
    title: "First feature"
    description: "First details"
  - id: 2
    date: "2026-03-15"
    type: additive
    title: "Second feature"
    description: "Second details"
YML

    # Step 1: Discovery — shows new entry, hint shown
    run_cco update
    assert_output_contains "Second feature"
    assert_output_contains "Run 'cco update --news'"
    assert_file_contains "$meta" "last_seen_changelog: 2"

    # Step 2: News — shows new entry details
    run_cco update --news
    assert_output_contains "Second feature"
    assert_output_contains "Second details"
    assert_file_contains "$meta" "last_read_changelog: 2"

    # Step 3: Both at 2, nothing more to show
    run_cco update
    assert_output_not_contains "What's new"
}

# ── Migration 009: global migration includes pack consolidation ───────

test_migration_009_global_moves_packs() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT

    local target="$tmpdir/global/.claude"
    mkdir -p "$target"
    echo "schema_version: 8" > "$target/.cco-meta"

    # Set up packs with old-layout files
    local packs_dir="$tmpdir/packs"
    mkdir -p "$packs_dir/my-pack"
    echo "remote:acme/my-pack" > "$packs_dir/my-pack/.cco-source"
    mkdir -p "$packs_dir/my-pack/.cco-install-tmp"
    echo "temp" > "$packs_dir/my-pack/.cco-install-tmp/file.txt"

    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/update.sh"
    source "$REPO_ROOT/migrations/global/009_cco_dir_consolidation.sh"

    migrate "$target"

    # Pack files moved to new locations
    assert_file_exists "$packs_dir/my-pack/.cco/source"
    assert_file_contains "$packs_dir/my-pack/.cco/source" "remote:acme/my-pack"
    [[ -d "$packs_dir/my-pack/.cco/install-tmp" ]] || fail ".cco/install-tmp/ should exist"
    # Old locations removed
    [[ ! -f "$packs_dir/my-pack/.cco-source" ]] || fail ".cco-source should be removed"
    [[ ! -d "$packs_dir/my-pack/.cco-install-tmp" ]] || fail ".cco-install-tmp/ should be removed"
}

# ── Migration 009: idempotency with directories ──────────────────────

test_migration_009_idempotent_directories() {
    # Guarded moves for directories: both old and new exist -> skip safely
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT

    local target="$tmpdir/project"
    mkdir -p "$target/.claude"
    # Create both old and new directory locations
    mkdir -p "$target/.managed"
    echo "old" > "$target/.managed/browser.json"
    mkdir -p "$target/.cco/managed"
    echo "new" > "$target/.cco/managed/browser.json"

    mkdir -p "$target/claude-state"
    echo "old-session" > "$target/claude-state/session.jsonl"
    mkdir -p "$target/.cco/claude-state"
    echo "new-session" > "$target/.cco/claude-state/session.jsonl"

    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/update.sh"
    source "$REPO_ROOT/migrations/project/009_cco_dir_consolidation.sh"

    migrate "$target"

    # New should be preserved (not overwritten by old)
    assert_file_contains "$target/.cco/managed/browser.json" "new"
    assert_file_contains "$target/.cco/claude-state/session.jsonl" "new-session"
    # Old directories still exist (guarded skip, not deleted)
    [[ -d "$target/.managed" ]] || fail ".managed/ should be preserved when .cco/managed/ exists"
    [[ -d "$target/claude-state" ]] || fail "claude-state/ should be preserved when .cco/claude-state/ exists"
}

# ── Migration 009: gitignore removes old pack-manifest pattern ────────

test_migration_009_gitignore_removes_old_pack_manifest() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT

    local target="$tmpdir/global/.claude"
    mkdir -p "$target"

    cat > "$tmpdir/.gitignore" <<'GI'
secrets.env
projects/*/.pack-manifest
GI

    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/update.sh"
    source "$REPO_ROOT/migrations/global/009_cco_dir_consolidation.sh"

    migrate "$target"

    # Old pattern should be replaced
    assert_file_not_contains "$tmpdir/.gitignore" "projects/*/.pack-manifest"
    # New pattern should be present
    assert_file_contains "$tmpdir/.gitignore" "projects/*/.claude/.cco/pack-manifest"
}

# ── Changelog scenario 8: dry-run does NOT update trackers ─────────

test_update_dry_run_no_tracker_update() {
    # Dry-run must show changelog output but NOT update last_seen or last_read
    local tmpdir; tmpdir=$(mktemp -d)
    local saved_changelog="$tmpdir/changelog.bak"
    cp "$REPO_ROOT/changelog.yml" "$saved_changelog"
    trap "cp '$saved_changelog' '$REPO_ROOT/changelog.yml'; rm -rf '$tmpdir'" EXIT

    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    cat > "$REPO_ROOT/changelog.yml" <<'YML'
entries:
  - id: 1
    date: "2026-03-01"
    type: additive
    title: "Dry-run tracker test"
    description: "Should not update trackers"
YML

    local meta="$CCO_GLOBAL_DIR/.claude/.cco/meta"
    sed -i "s/^last_seen_changelog: .*/last_seen_changelog: 0/" "$meta"
    if grep -q '^last_read_changelog:' "$meta"; then
        sed -i "s/^last_read_changelog: .*/last_read_changelog: 0/" "$meta"
    else
        sed -i '/^last_seen_changelog:/a last_read_changelog: 0' "$meta"
    fi

    # Dry-run discovery — should show changelog but NOT update trackers
    run_cco update --dry-run
    assert_file_contains "$meta" "last_seen_changelog: 0"
    assert_file_contains "$meta" "last_read_changelog: 0"

    # Dry-run news — should also NOT update trackers
    run_cco update --news --dry-run
    assert_file_contains "$meta" "last_seen_changelog: 0"
    assert_file_contains "$meta" "last_read_changelog: 0"
}

# ── Migration 009: warns on running Docker session ─────────────────

test_migration_009_warns_running_session() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT

    local target="$tmpdir/global/.claude"
    mkdir -p "$target"
    echo "schema_version: 8" > "$target/.cco-meta"

    # Set up mock docker that reports a running cc-* container
    local mock_bin="$tmpdir/mock-bin"
    source "$REPO_ROOT/tests/mocks.sh"
    _mock_docker_with_containers "$mock_bin" "cc-my-proj"
    export PATH="$mock_bin:$PATH"

    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/update.sh"
    source "$REPO_ROOT/migrations/global/009_cco_dir_consolidation.sh"

    local output
    output=$(migrate "$target" 2>&1)

    echo "$output" | grep -q "Running sessions detected" || \
        fail "Migration should warn about running sessions"
}

test_migration_009_no_warn_when_no_sessions() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT

    local target="$tmpdir/global/.claude"
    mkdir -p "$target"
    echo "schema_version: 8" > "$target/.cco-meta"

    # Set up mock docker with no running containers
    local mock_bin="$tmpdir/mock-bin"
    source "$REPO_ROOT/tests/mocks.sh"
    _mock_docker_no_containers "$mock_bin"
    export PATH="$mock_bin:$PATH"

    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/update.sh"
    source "$REPO_ROOT/migrations/global/009_cco_dir_consolidation.sh"

    local output
    output=$(migrate "$target" 2>&1)

    echo "$output" | grep -q "Running sessions detected" && \
        fail "Migration should NOT warn when no sessions running" || true
}
