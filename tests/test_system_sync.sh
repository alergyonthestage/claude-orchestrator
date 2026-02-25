#!/usr/bin/env bash
# tests/test_system_sync.sh — system files sync tests
#
# Verifies that _sync_system_files correctly copies system-managed files,
# preserves user files, handles migration, and cleans up deprecated paths.

test_sync_copies_all_manifest_files() {
    # All files listed in system.manifest must exist in global/ after init
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    local manifest="$REPO_ROOT/defaults/system/system.manifest"
    while IFS= read -r rel_path; do
        [[ -z "$rel_path" || "$rel_path" == \#* ]] && continue
        assert_file_exists "$CCO_GLOBAL_DIR/$rel_path" \
            "System file missing after init: $rel_path"
    done < "$manifest"
}

test_sync_is_idempotent() {
    # Running init twice should not report any synced files on second run
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Second init — system files already current, should skip sync message
    run_cco init --lang "English"
    # The output should NOT contain "Synced" (no changes needed)
    if echo "$CCO_OUTPUT" | grep -qF "Synced"; then
        echo "ASSERTION FAILED: second init should not report synced files"
        echo "  Output: $CCO_OUTPUT"
        return 1
    fi
}

test_sync_preserves_user_files() {
    # User-added skills/agents/rules must survive system sync
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Add user custom skill, agent, and rule
    mkdir -p "$CCO_GLOBAL_DIR/.claude/skills/my-custom"
    printf 'my custom skill' > "$CCO_GLOBAL_DIR/.claude/skills/my-custom/SKILL.md"
    printf 'my custom agent' > "$CCO_GLOBAL_DIR/.claude/agents/my-agent.md"
    printf 'my custom rule' > "$CCO_GLOBAL_DIR/.claude/rules/my-rule.md"

    # Run init again (triggers system sync)
    run_cco init --lang "English"

    # User files must still be there
    assert_file_exists "$CCO_GLOBAL_DIR/.claude/skills/my-custom/SKILL.md"
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/skills/my-custom/SKILL.md" "my custom skill"
    assert_file_exists "$CCO_GLOBAL_DIR/.claude/agents/my-agent.md"
    assert_file_exists "$CCO_GLOBAL_DIR/.claude/rules/my-rule.md"
}

test_sync_removes_deprecated_paths() {
    # If a path was in the old manifest but not the new one, it should be removed
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Simulate an old manifest with an extra path
    local installed_manifest="$CCO_GLOBAL_DIR/.claude/.system-manifest"
    printf '.claude/rules/old-deprecated-rule.md\n' >> "$installed_manifest"
    # Create the file it points to
    printf 'deprecated content' > "$CCO_GLOBAL_DIR/.claude/rules/old-deprecated-rule.md"

    # Run init again — sync should remove the deprecated path
    run_cco init --lang "English"

    assert_file_not_exists "$CCO_GLOBAL_DIR/.claude/rules/old-deprecated-rule.md" \
        "Deprecated system file should have been removed"
}

test_sync_without_force_updates_system() {
    # System files must be updated even without --force
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Corrupt a system file
    printf 'corrupted' > "$CCO_GLOBAL_DIR/.claude/settings.json"

    # Run init without --force
    run_cco init --lang "English"

    # settings.json should be restored from system defaults
    assert_file_not_contains "$CCO_GLOBAL_DIR/.claude/settings.json" "corrupted"
    assert_file_exists "$CCO_GLOBAL_DIR/.claude/settings.json"
}

test_sync_does_not_touch_user_defaults() {
    # mcp.json and language.md must NOT be overwritten by system sync
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "Italian"

    # Plant canaries in user default files
    printf '\n# MCP_CANARY\n' >> "$CCO_GLOBAL_DIR/.claude/mcp.json"
    printf '\n# LANG_CANARY\n' >> "$CCO_GLOBAL_DIR/.claude/rules/language.md"

    # Run init again (without --force)
    run_cco init --lang "English"

    # Both canaries must survive (user defaults not touched)
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/mcp.json" "# MCP_CANARY"
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/rules/language.md" "# LANG_CANARY"
}

test_sync_migration_removes_old_init() {
    # Bootstrap migration: old skills/init/ should be removed on first sync
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"

    # Simulate pre-system layout: create global with old init/ skill, no .system-manifest
    mkdir -p "$tmpdir/global/.claude/skills/init"
    printf 'old init skill' > "$tmpdir/global/.claude/skills/init/SKILL.md"
    mkdir -p "$tmpdir/global/.claude/rules"
    printf 'placeholder' > "$tmpdir/global/.claude/rules/language.md"
    mkdir -p "$tmpdir/global/packs"

    # Run init — should trigger bootstrap migration
    run_cco init --lang "English"

    # Old init/ should be gone, init-workspace/ should exist
    assert_file_not_exists "$CCO_GLOBAL_DIR/.claude/skills/init/SKILL.md" \
        "Old skills/init/ should have been removed by migration"
    assert_file_exists "$CCO_GLOBAL_DIR/.claude/skills/init-workspace/SKILL.md"
}

test_sync_updates_settings_json() {
    # settings.json is a system file and must be updated even if modified
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Modify settings.json (simulating user edit)
    printf '{"modified": true}' > "$CCO_GLOBAL_DIR/.claude/settings.json"

    # Run init again
    run_cco init --lang "English"

    # Should be restored to the system version
    assert_file_not_contains "$CCO_GLOBAL_DIR/.claude/settings.json" '"modified": true'
}

test_sync_installs_system_manifest() {
    # After sync, .system-manifest should exist in global/.claude/
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    assert_file_exists "$CCO_GLOBAL_DIR/.claude/.system-manifest"
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/.system-manifest" ".claude/settings.json"
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/.system-manifest" ".claude/skills/init-workspace/SKILL.md"
}
