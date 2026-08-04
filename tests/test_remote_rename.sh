#!/usr/bin/env bash
# tests/test_remote_rename.sh — `cco remote rename` (ADR-0050 B.3, registry kind).
# Re-keys the DATA url registry entry and migrates the STATE token, preserving both.

test_remote_rename_rekeys_url_and_token() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    run_cco remote add up https://example.com/repo.git --token secret123 || fail "add failed: $CCO_OUTPUT" || return 1

    run_cco remote rename up origin -y || fail "rename failed: $CCO_OUTPUT" || return 1

    # url registry re-keyed (DATA), url preserved
    assert_file_contains "$CCO_DATA_HOME/remotes" "origin=https://example.com/repo.git" || return 1
    assert_file_not_contains "$CCO_DATA_HOME/remotes" "up=https://example.com/repo.git" || return 1
    # token migrated (STATE)
    assert_file_contains "$CCO_STATE_HOME/remotes-token" "origin=secret123" || return 1
    grep -q "^up=" "$CCO_STATE_HOME/remotes-token" && fail "old token key remains" || true
}

test_remote_rename_without_token() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    run_cco remote add plain https://example.com/p.git || fail "$CCO_OUTPUT" || return 1
    run_cco remote rename plain shared -y || fail "$CCO_OUTPUT" || return 1
    assert_file_contains "$CCO_DATA_HOME/remotes" "shared=https://example.com/p.git" || return 1
}

test_remote_rename_missing_and_duplicate() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    run_cco remote add a https://example.com/a.git || return 1
    run_cco remote add b https://example.com/b.git || return 1
    run_cco remote rename nope x -y && fail "expected 'not found'" || true
    run_cco remote rename a b -y   && fail "expected duplicate refusal" || true
    assert_file_contains "$CCO_DATA_HOME/remotes" "a=https://example.com/a.git" || return 1
}
