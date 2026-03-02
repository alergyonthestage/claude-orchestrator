#!/usr/bin/env bash
# tests/test_managed_scope.sh — managed scope architecture tests
#
# Verifies that the managed/global/project scope hierarchy is correct:
# - defaults/managed/ contains framework infrastructure (hooks, env, deny rules)
# - defaults/global/.claude/ contains user-owned defaults (agents, skills, rules, settings)
# - cco init copies global defaults without overwriting existing files
# - Migration from old system-sync layout works correctly

test_managed_files_exist_in_defaults() {
    # defaults/managed/ must contain managed-settings.json and CLAUDE.md
    assert_file_exists "$REPO_ROOT/defaults/managed/managed-settings.json" \
        "managed-settings.json missing from defaults/managed/"
    assert_file_exists "$REPO_ROOT/defaults/managed/CLAUDE.md" \
        "CLAUDE.md missing from defaults/managed/"
    assert_file_exists "$REPO_ROOT/defaults/managed/.claude/skills/init-workspace/SKILL.md" \
        "init-workspace skill missing from defaults/managed/.claude/skills/"
}

test_managed_settings_has_hooks() {
    # managed-settings.json must contain hooks, env, statusLine, and deny rules
    local f="$REPO_ROOT/defaults/managed/managed-settings.json"
    assert_file_contains "$f" '"hooks"'
    assert_file_contains "$f" '"SessionStart"'
    assert_file_contains "$f" '"SubagentStart"'
    assert_file_contains "$f" '"PreCompact"'
    assert_file_contains "$f" '"env"'
    assert_file_contains "$f" '"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"'
    assert_file_contains "$f" '"statusLine"'
    assert_file_contains "$f" '"deny"'
}

test_global_settings_has_no_hooks() {
    # global/.claude/settings.json must NOT contain hooks, env, statusLine, or deny
    local f="$REPO_ROOT/defaults/global/.claude/settings.json"
    assert_file_exists "$f"
    assert_file_not_contains "$f" '"hooks"'
    assert_file_not_contains "$f" '"env"'
    assert_file_not_contains "$f" '"statusLine"'
    assert_file_not_contains "$f" '"deny"'
}

test_global_settings_has_user_preferences() {
    # global/.claude/settings.json must contain user preferences
    local f="$REPO_ROOT/defaults/global/.claude/settings.json"
    assert_file_contains "$f" '"allow"'
    assert_file_contains "$f" '"attribution"'
    assert_file_contains "$f" '"teammateMode"'
    assert_file_contains "$f" '"cleanupPeriodDays"'
}

test_dockerfile_copies_managed() {
    # Dockerfile must COPY defaults/managed/ to /etc/claude-code/
    assert_file_contains "$REPO_ROOT/Dockerfile" "COPY"
    assert_file_contains "$REPO_ROOT/Dockerfile" "defaults/managed/"
    assert_file_contains "$REPO_ROOT/Dockerfile" "/etc/claude-code/"
}

test_no_system_dir_exists() {
    # defaults/system/ must not exist (replaced by managed + global)
    if [[ -d "$REPO_ROOT/defaults/system" ]]; then
        echo "ASSERTION FAILED: defaults/system/ should not exist"
        return 1
    fi
}

test_init_copies_global_defaults() {
    # cco init must copy agents, skills, rules, settings.json from defaults/global/
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Agents
    assert_file_exists "$CCO_GLOBAL_DIR/.claude/agents/analyst.md"
    assert_file_exists "$CCO_GLOBAL_DIR/.claude/agents/reviewer.md"

    # Skills (init-workspace is now managed, not in user global)
    assert_file_exists "$CCO_GLOBAL_DIR/.claude/skills/analyze/SKILL.md"
    assert_file_exists "$CCO_GLOBAL_DIR/.claude/skills/commit/SKILL.md"
    assert_file_exists "$CCO_GLOBAL_DIR/.claude/skills/design/SKILL.md"
    assert_file_exists "$CCO_GLOBAL_DIR/.claude/skills/review/SKILL.md"
    assert_file_not_exists "$CCO_GLOBAL_DIR/.claude/skills/init-workspace/SKILL.md" \
        "init-workspace should NOT be in user global (it is managed)"

    # Rules
    assert_file_exists "$CCO_GLOBAL_DIR/.claude/rules/workflow.md"
    assert_file_exists "$CCO_GLOBAL_DIR/.claude/rules/diagrams.md"
    assert_file_exists "$CCO_GLOBAL_DIR/.claude/rules/git-practices.md"
    assert_file_exists "$CCO_GLOBAL_DIR/.claude/rules/language.md"

    # Settings
    assert_file_exists "$CCO_GLOBAL_DIR/.claude/settings.json"
    assert_file_not_contains "$CCO_GLOBAL_DIR/.claude/settings.json" '"hooks"'
}

test_init_idempotent() {
    # Running init twice should not report any migration on second run
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    run_cco init --lang "English"

    # The output should NOT contain migration messages on second run
    if echo "$CCO_OUTPUT" | grep -qF "Managed scope migration"; then
        echo "ASSERTION FAILED: second init should not report migration"
        echo "  Output: $CCO_OUTPUT"
        return 1
    fi
}

test_init_preserves_user_customizations() {
    # User-added skills/agents/rules must survive re-init
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Add user custom skill, agent, and rule
    mkdir -p "$CCO_GLOBAL_DIR/.claude/skills/my-custom"
    printf 'my custom skill' > "$CCO_GLOBAL_DIR/.claude/skills/my-custom/SKILL.md"
    printf 'my custom agent' > "$CCO_GLOBAL_DIR/.claude/agents/my-agent.md"
    printf 'my custom rule' > "$CCO_GLOBAL_DIR/.claude/rules/my-rule.md"

    # Modify an existing default file (user customization)
    printf '# My custom workflow rules\n' > "$CCO_GLOBAL_DIR/.claude/rules/workflow.md"

    # Run init again (without --force)
    run_cco init --lang "English"

    # User files must still be there
    assert_file_exists "$CCO_GLOBAL_DIR/.claude/skills/my-custom/SKILL.md"
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/skills/my-custom/SKILL.md" "my custom skill"
    assert_file_exists "$CCO_GLOBAL_DIR/.claude/agents/my-agent.md"
    assert_file_exists "$CCO_GLOBAL_DIR/.claude/rules/my-rule.md"

    # Modified default file must NOT be overwritten
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/rules/workflow.md" "My custom workflow rules"
}

test_reinit_does_not_overwrite_existing() {
    # Second init (without --force) must not overwrite any existing files
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Plant canaries in user default files
    printf '\n# MCP_CANARY\n' >> "$CCO_GLOBAL_DIR/.claude/mcp.json"
    printf '\n# LANG_CANARY\n' >> "$CCO_GLOBAL_DIR/.claude/rules/language.md"
    printf '\n# SETTINGS_CANARY\n' >> "$CCO_GLOBAL_DIR/.claude/settings.json"

    # Run init again (without --force)
    run_cco init --lang "English"

    # All canaries must survive
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/mcp.json" "# MCP_CANARY"
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/rules/language.md" "# LANG_CANARY"
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/settings.json" "# SETTINGS_CANARY"
}

test_init_with_force_recopies_globals() {
    # --force must recopy all defaults from defaults/global/
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Corrupt settings.json
    printf '{"corrupted": true}' > "$CCO_GLOBAL_DIR/.claude/settings.json"

    # Run init with --force
    run_cco init --force --lang "English"

    # Settings should be restored from defaults
    assert_file_not_contains "$CCO_GLOBAL_DIR/.claude/settings.json" '"corrupted"'
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/settings.json" '"attribution"'
}

test_migration_to_managed() {
    # Existing installs with old .system-manifest and hooks in settings.json
    # should be migrated cleanly by the migration system
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"

    # Simulate pre-managed layout: global/ with system-manifest and old settings
    mkdir -p "$tmpdir/global/.claude/rules"
    mkdir -p "$tmpdir/global/.claude/agents"
    mkdir -p "$tmpdir/global/.claude/skills/analyze"
    printf '.claude/settings.json\n.claude/agents/analyst.md\n' > "$tmpdir/global/.claude/.system-manifest"
    printf '{"hooks": {"SessionStart": []}, "attribution": {}}' > "$tmpdir/global/.claude/settings.json"
    printf 'placeholder' > "$tmpdir/global/.claude/rules/language.md"
    mkdir -p "$tmpdir/global/packs"

    # Run init — should trigger migration via migration runner
    run_cco init --lang "English"

    # .system-manifest should be gone (removed by migration 001)
    assert_file_not_exists "$CCO_GLOBAL_DIR/.claude/.system-manifest" \
        ".system-manifest should have been removed by migration"

    # settings.json should be replaced with user-only version (no hooks)
    assert_file_not_contains "$CCO_GLOBAL_DIR/.claude/settings.json" '"hooks"'
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/settings.json" '"attribution"'

    # Backup of old settings should exist
    assert_file_exists "$CCO_GLOBAL_DIR/.claude/settings.json.pre-managed"
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/settings.json.pre-managed" '"hooks"'

    # Old migration marker should be removed (replaced by .cco-meta schema_version)
    assert_file_not_exists "$CCO_GLOBAL_DIR/.claude/.managed-migration-done" \
        ".managed-migration-done should be removed by new migration system"
}

test_migration_removes_old_init_skill() {
    # Old skills/init/ should be removed by migration
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"

    # Simulate old layout with skills/init/
    mkdir -p "$tmpdir/global/.claude/skills/init"
    printf 'old init skill' > "$tmpdir/global/.claude/skills/init/SKILL.md"
    mkdir -p "$tmpdir/global/.claude/rules"
    printf 'placeholder' > "$tmpdir/global/.claude/rules/language.md"
    mkdir -p "$tmpdir/global/packs"

    # Run init
    run_cco init --lang "English"

    # Old init/ should be gone
    assert_file_not_exists "$CCO_GLOBAL_DIR/.claude/skills/init/SKILL.md" \
        "Old skills/init/ should have been removed by migration"
}

test_migration_moves_init_workspace_to_managed() {
    # Existing installs with init-workspace in user global should have it
    # removed by migration 002 (now managed at /etc/claude-code/.claude/skills/)
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"

    # Simulate old layout with init-workspace in user skills
    mkdir -p "$tmpdir/global/.claude/skills/init-workspace"
    printf '---\nname: init-workspace\n---\nOld user copy' > "$tmpdir/global/.claude/skills/init-workspace/SKILL.md"
    mkdir -p "$tmpdir/global/.claude/rules"
    printf 'placeholder' > "$tmpdir/global/.claude/rules/language.md"
    mkdir -p "$tmpdir/global/packs"

    # Run init (triggers migrations)
    run_cco init --lang "English"

    # init-workspace should be gone from user global
    assert_file_not_exists "$CCO_GLOBAL_DIR/.claude/skills/init-workspace/SKILL.md" \
        "init-workspace should have been removed by migration 002 (now managed)"
}

test_init_workspace_not_in_global_defaults() {
    # init-workspace must NOT be in defaults/global/ (it lives in defaults/managed/)
    assert_file_not_exists "$REPO_ROOT/defaults/global/.claude/skills/init-workspace/SKILL.md" \
        "init-workspace should not be in defaults/global/ (must be in defaults/managed/)"
}

test_no_sync_function_in_cco() {
    # _sync_system_files should not exist in bin/cco
    if grep -q "_sync_system_files" "$REPO_ROOT/bin/cco"; then
        echo "ASSERTION FAILED: _sync_system_files still exists in bin/cco"
        return 1
    fi
}

test_no_system_manifest_in_cco() {
    # system.manifest should not be referenced in bin/cco
    if grep -q "system\.manifest" "$REPO_ROOT/bin/cco"; then
        echo "ASSERTION FAILED: system.manifest still referenced in bin/cco"
        return 1
    fi
}
