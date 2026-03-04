#!/usr/bin/env bash
# tests/test_init.sh — cco init command tests
#
# Verifies that cco init correctly copies default config, substitutes language
# placeholders, respects --force, and creates expected directories.
#
# Note: cmd_init tries to build Docker at the end, but gracefully warns and
# continues if Docker isn't running — no mock needed.

test_init_creates_global_claude_dir() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    assert_dir_exists "$CCO_GLOBAL_DIR/.claude"
}

test_init_copies_settings_json() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    assert_file_exists "$CCO_GLOBAL_DIR/.claude/settings.json"
}

test_init_copies_global_claude_md() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    assert_file_exists "$CCO_GLOBAL_DIR/.claude/CLAUDE.md"
}

test_init_copies_rules_directory() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    assert_dir_exists "$CCO_GLOBAL_DIR/.claude/rules"
    assert_file_exists "$CCO_GLOBAL_DIR/.claude/rules/language.md"
    assert_file_exists "$CCO_GLOBAL_DIR/.claude/rules/git-practices.md"
}

test_init_copies_agents_directory() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    assert_dir_exists "$CCO_GLOBAL_DIR/.claude/agents"
    assert_file_exists "$CCO_GLOBAL_DIR/.claude/agents/analyst.md"
    assert_file_exists "$CCO_GLOBAL_DIR/.claude/agents/reviewer.md"
}

test_init_substitutes_comm_lang_single_value() {
    # --lang "Italian" → COMM_LANG=Italian, DOCS_LANG=Italian, CODE_LANG=English
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "Italian"
    local lang_file="$CCO_GLOBAL_DIR/.claude/rules/language.md"
    assert_file_contains "$lang_file" "Italian"
    assert_no_placeholder "$lang_file" "{{COMM_LANG}}"
    assert_no_placeholder "$lang_file" "{{DOCS_LANG}}"
    assert_no_placeholder "$lang_file" "{{CODE_LANG}}"
}

test_init_substitutes_three_lang_format() {
    # --lang "Italian:Italian:English" → each placeholder replaced independently
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "Italian:Italian:English"
    local lang_file="$CCO_GLOBAL_DIR/.claude/rules/language.md"
    assert_no_placeholder "$lang_file" "{{COMM_LANG}}"
    assert_no_placeholder "$lang_file" "{{DOCS_LANG}}"
    assert_no_placeholder "$lang_file" "{{CODE_LANG}}"
}

test_init_no_overwrite_without_force() {
    # Design Invariant: init never overwrites existing user defaults without --force
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"

    # First init
    run_cco init --lang "English"

    # Plant a canary string in a user-owned file (not a system file)
    printf '\n# CANARY\n' >> "$CCO_GLOBAL_DIR/.claude/mcp.json"

    # Second init without --force — should skip user defaults
    run_cco init --lang "Italian"

    # Canary must still be there (user file was NOT overwritten)
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/mcp.json" "# CANARY"
}

test_init_force_overwrites_existing() {
    # --force causes overwrite of existing user defaults
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"

    run_cco init --lang "English"
    printf '\n# CANARY\n' >> "$CCO_GLOBAL_DIR/.claude/mcp.json"

    run_cco init --force --lang "English"

    # Canary should be gone (user file was replaced by --force)
    assert_file_not_contains "$CCO_GLOBAL_DIR/.claude/mcp.json" "# CANARY"
}

test_init_creates_projects_directory() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    assert_dir_exists "$CCO_PROJECTS_DIR"
}

test_init_creates_packs_directory() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    assert_dir_exists "$CCO_PACKS_DIR"
}

test_init_creates_templates_directory() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    assert_dir_exists "$CCO_TEMPLATES_DIR"
}

test_init_creates_user_config_structure() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    assert_dir_exists "$CCO_USER_CONFIG_DIR"
    assert_dir_exists "$CCO_USER_CONFIG_DIR/global/.claude"
    assert_dir_exists "$CCO_USER_CONFIG_DIR/projects"
    assert_dir_exists "$CCO_USER_CONFIG_DIR/packs"
    assert_dir_exists "$CCO_USER_CONFIG_DIR/templates"
}
