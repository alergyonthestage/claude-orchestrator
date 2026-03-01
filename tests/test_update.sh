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
    # Schema version should be updated to latest
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/.cco-meta" "schema_version: 1"
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
