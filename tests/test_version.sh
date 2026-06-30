#!/usr/bin/env bash
# tests/test_version.sh — top-level `cco --version`/`-v` and `--help`/`-h` (FI-11).
# Version's source of truth is package.json (ADR-0037 D7); --help aliases `cco help`.

test_version_long_flag_matches_package_json() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local v; v=$(jq -r '.version' "$REPO_ROOT/package.json")
    run_cco --version
    assert_output_contains "cco $v"
}

test_version_short_flag_matches_package_json() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local v; v=$(jq -r '.version' "$REPO_ROOT/package.json")
    run_cco -v
    assert_output_contains "cco $v"
}

test_help_long_flag_prints_usage() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco --help
    assert_output_contains "Usage: cco <command>"
}

test_help_short_flag_prints_usage() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco -h
    assert_output_contains "Usage: cco <command>"
}

test_unknown_flag_still_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    if run_cco --bogus 2>/dev/null; then
        fail "Expected 'cco --bogus' to fail"
    fi
    assert_output_contains "Unknown command"
}
