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
    # Schema version should be updated to latest (currently 7: migration 001-007)
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/.cco-meta" "schema_version: 7"
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

# ── Migration 005: split global setup ─────────────────────────────────

test_migration_005_renames_setup_with_build_content() {
    # setup.sh with apt-get → renamed to setup-build.sh, new setup.sh created
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    # Simulate pre-migration state: only setup.sh with build content
    printf '#!/bin/bash\napt-get update && apt-get install -y vim\n' > "$CCO_GLOBAL_DIR/setup.sh"

    # Set schema_version to 4 (before migration 005)
    create_cco_meta "$CCO_GLOBAL_DIR/.claude/.cco-meta" "schema_version: 4
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

    create_cco_meta "$CCO_GLOBAL_DIR/.claude/.cco-meta" "schema_version: 4
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

    create_cco_meta "$CCO_GLOBAL_DIR/.claude/.cco-meta" "schema_version: 4
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

    create_cco_meta "$CCO_GLOBAL_DIR/.claude/.cco-meta" "schema_version: 4
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
    [[ -f "$CCO_GLOBAL_DIR/.claude/.cco-base/rules/workflow.md" ]] && \
        before_base_hash=$(sha256sum "$CCO_GLOBAL_DIR/.claude/.cco-base/rules/workflow.md" | cut -d' ' -f1)

    run_cco update
    assert_output_contains "update"

    # File must NOT be modified
    local after_hash; after_hash=$(sha256sum "$CCO_GLOBAL_DIR/.claude/rules/workflow.md" | cut -d' ' -f1)
    [[ "$before_hash" == "$after_hash" ]] || fail "Discovery mode modified installed file"

    # .cco-base/ must NOT be updated
    local after_base_hash=""
    [[ -f "$CCO_GLOBAL_DIR/.claude/.cco-base/rules/workflow.md" ]] && \
        after_base_hash=$(sha256sum "$CCO_GLOBAL_DIR/.claude/.cco-base/rules/workflow.md" | cut -d' ' -f1)
    [[ "$before_base_hash" == "$after_base_hash" ]] || fail "Discovery mode updated .cco-base/"

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
    # --news mode shows changelog entries and updates last_seen_changelog
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
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

    # Set last_seen_changelog to 0 in .cco-meta
    local meta="$CCO_GLOBAL_DIR/.claude/.cco-meta"
    if grep -q '^last_seen_changelog:' "$meta"; then
        sed -i "s/^last_seen_changelog: .*/last_seen_changelog: 0/" "$meta"
    fi

    run_cco update --news
    assert_output_contains "Test feature for news"

    # last_seen_changelog should be updated to 1
    assert_file_contains "$meta" "last_seen_changelog: 1"

    # Restore changelog
    cat > "$REPO_ROOT/changelog.yml" <<'YML'
# changelog.yml — Additive changes notification
# Each entry describes a new optional feature or configuration field.
# Users are notified of new entries by `cco update`.
#
# Format:
#   - id: <sequential integer>
#     date: "YYYY-MM-DD"
#     type: additive
#     title: "Short description"
#     description: "Details about the new feature and how to use it"

entries: []
YML
}

test_update_news_no_new_entries() {
    # --news with no new entries shows "No new features"
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Create a changelog with one entry already seen
    cat > "$REPO_ROOT/changelog.yml" <<'YML'
entries:
  - id: 1
    date: "2026-03-01"
    type: additive
    title: "Already seen feature"
    description: "Already seen"
YML

    # Set last_seen_changelog to 1 in .cco-meta (already seen)
    local meta="$CCO_GLOBAL_DIR/.claude/.cco-meta"
    if grep -q '^last_seen_changelog:' "$meta"; then
        sed -i "s/^last_seen_changelog: .*/last_seen_changelog: 1/" "$meta"
    fi

    run_cco update --news
    assert_output_contains "No new features"

    # Restore changelog
    cat > "$REPO_ROOT/changelog.yml" <<'YML'
# changelog.yml — Additive changes notification
entries: []
YML
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
    local meta="$CCO_GLOBAL_DIR/.claude/.cco-meta"
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
    # --keep preserves user file and updates .cco-base/ to current default
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Both user and framework change (conflict scenario)
    printf '\n# User edit for keep test\n' >> "$CCO_GLOBAL_DIR/.claude/rules/workflow.md"
    printf '\n# Framework edit for keep test\n' >> "$REPO_ROOT/defaults/global/.claude/rules/workflow.md"

    run_cco update --keep
    # User file must be preserved
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/rules/workflow.md" "User edit for keep test"
    # .cco-base/ IS updated to current default (so next update won't re-trigger)
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/.cco-base/rules/workflow.md" "Framework edit for keep test"

    # Restore
    cd "$REPO_ROOT" && git checkout -- defaults/global/.claude/rules/workflow.md
}

# ── Project Create Bootstrap ─────────────────────────────────────────

test_project_create_initializes_cco_meta() {
    # cco project create should generate .cco-meta and .cco-base/
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    run_cco project create "test-bootstrap" --repo "$CCO_DUMMY_REPO"

    local proj_dir="$CCO_PROJECTS_DIR/test-bootstrap"
    assert_file_exists "$proj_dir/.cco-meta" ".cco-meta should exist after project create"
    assert_file_contains "$proj_dir/.cco-meta" "schema_version:"
    assert_dir_exists "$proj_dir/.cco-base" ".cco-base/ should exist after project create"
}

test_project_create_cco_source_not_for_base() {
    # Base template (default) should NOT create .cco-source
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    run_cco project create "test-base-src" --repo "$CCO_DUMMY_REPO"

    assert_file_not_exists "$CCO_PROJECTS_DIR/test-base-src/.cco-source" \
        ".cco-source should NOT exist for base template"
}

test_project_create_cco_source_for_tutorial() {
    # Tutorial template should create .cco-source with native:project/tutorial
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    run_cco project create "test-tut-src" --repo "$CCO_DUMMY_REPO" --template tutorial

    local source_file="$CCO_PROJECTS_DIR/test-tut-src/.cco-source"
    assert_file_exists "$source_file" ".cco-source should exist for tutorial template"
    assert_file_contains "$source_file" "native:project/tutorial"
}

# ── Template Source Resolution ───────────────────────────────────────

test_resolve_project_defaults_dir_base() {
    # Project with no .cco-source returns base template path
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"

    # Source the necessary libs and set required globals
    export NATIVE_TEMPLATES_DIR="$REPO_ROOT/templates"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/update.sh"

    # Create a minimal project dir without .cco-source
    local proj_dir="$tmpdir/test-proj"
    mkdir -p "$proj_dir"

    local result
    result=$(_resolve_project_defaults_dir "$proj_dir")
    [[ "$result" == *"templates/project/base/.claude"* ]] || \
        fail "Expected base template path, got: $result"
}

test_resolve_project_defaults_dir_tutorial() {
    # Project with .cco-source pointing to tutorial returns tutorial template path
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"

    export NATIVE_TEMPLATES_DIR="$REPO_ROOT/templates"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/update.sh"

    local proj_dir="$tmpdir/test-proj"
    mkdir -p "$proj_dir"
    printf 'native:project/tutorial\n' > "$proj_dir/.cco-source"

    local result
    result=$(_resolve_project_defaults_dir "$proj_dir")
    [[ "$result" == *"templates/project/tutorial/.claude"* ]] || \
        fail "Expected tutorial template path, got: $result"
}

# ── Changelog Parsing ────────────────────────────────────────────────

test_read_changelog_entries_empty() {
    # changelog.yml with entries: [] returns no output
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT

    # Temporarily replace changelog.yml
    local saved_changelog="$tmpdir/changelog.bak"
    cp "$REPO_ROOT/changelog.yml" "$saved_changelog"

    cat > "$REPO_ROOT/changelog.yml" <<'YML'
entries: []
YML

    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/update.sh"

    local result
    result=$(_read_changelog_entries)
    [[ -z "$result" ]] || fail "Expected empty output for empty changelog, got: $result"

    # Restore
    cp "$saved_changelog" "$REPO_ROOT/changelog.yml"
}

test_read_changelog_entries_with_entries() {
    # changelog.yml with entries returns correct id/title pairs
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT

    local saved_changelog="$tmpdir/changelog.bak"
    cp "$REPO_ROOT/changelog.yml" "$saved_changelog"

    cat > "$REPO_ROOT/changelog.yml" <<'YML'
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

    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/update.sh"

    local result
    result=$(_read_changelog_entries)
    local count
    count=$(echo "$result" | grep -c '.' || true)
    [[ "$count" -eq 2 ]] || fail "Expected 2 entries, got $count"

    # Verify entry content
    echo "$result" | grep -qF "First feature" || fail "First entry title not found"
    echo "$result" | grep -qF "Second feature" || fail "Second entry title not found"

    # Restore
    cp "$saved_changelog" "$REPO_ROOT/changelog.yml"
}
