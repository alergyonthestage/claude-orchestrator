#!/usr/bin/env bash
# tests/test_vault.sh — cco vault command tests
#
# Verifies vault init, sync, diff, log, status, and secret detection.

# ── Helper: set up an initialized vault ───────────────────────────────

_setup_vault() {
    local tmpdir="$1"
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    run_cco vault init
}

# ── vault init ────────────────────────────────────────────────────────

test_vault_init_creates_git_repo() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    run_cco vault init
    assert_dir_exists "$CCO_USER_CONFIG_DIR/.git"
}

test_vault_init_creates_gitignore() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    run_cco vault init
    assert_file_exists "$CCO_USER_CONFIG_DIR/.gitignore"
    assert_file_contains "$CCO_USER_CONFIG_DIR/.gitignore" "secrets.env"
    assert_file_contains "$CCO_USER_CONFIG_DIR/.gitignore" "*.key"
    assert_file_contains "$CCO_USER_CONFIG_DIR/.gitignore" ".credentials.json"
}

test_vault_init_creates_initial_commit() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    run_cco vault init
    local count
    count=$(git -C "$CCO_USER_CONFIG_DIR" rev-list --count HEAD 2>/dev/null)
    assert_equals "1" "$count" "Expected 1 initial commit"
}

test_vault_init_idempotent() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    run_cco vault init
    # Second init should warn but not fail
    run_cco vault init
    assert_output_contains "already initialized"
}

test_vault_init_includes_share_yml() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    run_cco vault init
    # share.yml should be in the initial commit
    local files
    files=$(git -C "$CCO_USER_CONFIG_DIR" show --name-only --format="" HEAD)
    if ! echo "$files" | grep -qF "share.yml"; then
        echo "ASSERTION FAILED: share.yml should be in initial commit"
        echo "  Files: $files"
        return 1
    fi
}

# ── vault sync ────────────────────────────────────────────────────────

test_vault_sync_no_changes() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"
    run_cco vault sync --yes
    assert_output_contains "up to date"
}

test_vault_sync_commits_changes() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"

    # Make a change
    printf '# New rule\n' > "$CCO_GLOBAL_DIR/.claude/rules/test-rule.md"

    run_cco vault sync "added test rule" --yes
    assert_output_contains "Committed"

    # Verify commit exists
    local log
    log=$(git -C "$CCO_USER_CONFIG_DIR" log --oneline -1)
    if ! echo "$log" | grep -qF "added test rule"; then
        echo "ASSERTION FAILED: commit message not found in log"
        echo "  Log: $log"
        return 1
    fi
}

test_vault_sync_dry_run() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"

    # Make a change
    printf '# New rule\n' > "$CCO_GLOBAL_DIR/.claude/rules/test-rule.md"

    run_cco vault sync --dry-run
    assert_output_contains "Dry run"

    # Should NOT be committed
    local status
    status=$(git -C "$CCO_USER_CONFIG_DIR" status --porcelain)
    if [[ -z "$status" ]]; then
        echo "ASSERTION FAILED: file should still be uncommitted after dry run"
        return 1
    fi
}

test_vault_sync_categorizes_changes() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"

    # Make changes in different categories
    printf '# Global change\n' > "$CCO_GLOBAL_DIR/.claude/rules/test.md"
    mkdir -p "$CCO_PACKS_DIR/test-pack"
    printf 'name: test-pack\n' > "$CCO_PACKS_DIR/test-pack/pack.yml"

    run_cco vault sync --dry-run
    assert_output_contains "global:"
    assert_output_contains "packs:"
}

test_vault_sync_aborts_on_secret_files() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"

    # Create a secret file that bypasses gitignore
    # (simulate: user modified .gitignore to remove secret exclusions)
    sed -i 's/^secrets.env$/# secrets.env/' "$CCO_USER_CONFIG_DIR/.gitignore"
    sed -i 's/^\*\.env$/# *.env/' "$CCO_USER_CONFIG_DIR/.gitignore"
    printf 'API_KEY=secret123\n' > "$CCO_USER_CONFIG_DIR/secrets.env"

    if run_cco vault sync --yes 2>/dev/null; then
        echo "ASSERTION FAILED: sync should abort when secret files are detected"
        return 1
    fi
}

test_vault_sync_default_message() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"

    printf '# Change\n' > "$CCO_GLOBAL_DIR/.claude/rules/test.md"

    run_cco vault sync --yes
    local log
    log=$(git -C "$CCO_USER_CONFIG_DIR" log --oneline -1)
    if ! echo "$log" | grep -qF "vault: snapshot"; then
        echo "ASSERTION FAILED: default message should contain 'vault: snapshot'"
        echo "  Log: $log"
        return 1
    fi
}

# ── vault diff ────────────────────────────────────────────────────────

test_vault_diff_no_changes() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"
    run_cco vault diff
    assert_output_contains "No uncommitted"
}

test_vault_diff_shows_categories() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"

    printf '# Change\n' > "$CCO_GLOBAL_DIR/.claude/rules/test.md"

    run_cco vault diff
    assert_output_contains "Global:"
}

# ── vault log ─────────────────────────────────────────────────────────

test_vault_log_shows_commits() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"
    run_cco vault log
    assert_output_contains "initial commit"
}

test_vault_log_limit() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"

    # Create extra commits
    printf '# A\n' > "$CCO_GLOBAL_DIR/.claude/rules/a.md"
    run_cco vault sync "commit a" --yes
    printf '# B\n' > "$CCO_GLOBAL_DIR/.claude/rules/b.md"
    run_cco vault sync "commit b" --yes

    run_cco vault log --limit 1
    # Should only show 1 commit
    local line_count
    line_count=$(echo "$CCO_OUTPUT" | grep -c . || true)
    assert_equals "1" "$line_count" "Expected 1 line with --limit 1"
}

# ── vault status ──────────────────────────────────────────────────────

test_vault_status_not_initialized() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco vault status
    assert_output_contains "not initialized"
}

test_vault_status_initialized() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"
    run_cco vault status
    assert_output_contains "initialized"
    assert_output_contains "Branch:"
    assert_output_contains "Commits:"
}

test_vault_status_shows_uncommitted_count() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"

    printf '# Change\n' > "$CCO_GLOBAL_DIR/.claude/rules/test.md"

    run_cco vault status
    assert_output_contains "uncommitted"
}

test_vault_status_clean() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"
    run_cco vault status
    assert_output_contains "clean"
}

# ── vault not initialized errors ─────────────────────────────────────

test_vault_sync_fails_without_init() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    if run_cco vault sync --yes 2>/dev/null; then
        echo "ASSERTION FAILED: sync should fail without vault init"
        return 1
    fi
}

test_vault_diff_fails_without_init() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    if run_cco vault diff 2>/dev/null; then
        echo "ASSERTION FAILED: diff should fail without vault init"
        return 1
    fi
}

test_vault_log_fails_without_init() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    if run_cco vault log 2>/dev/null; then
        echo "ASSERTION FAILED: log should fail without vault init"
        return 1
    fi
}

# ── vault help ────────────────────────────────────────────────────────

test_vault_help() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco vault --help
    assert_output_contains "vault"
    assert_output_contains "init"
    assert_output_contains "sync"
    assert_output_contains "diff"
    assert_output_contains "status"
}
