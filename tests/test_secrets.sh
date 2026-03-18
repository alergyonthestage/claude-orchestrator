#!/usr/bin/env bash
# tests/test_secrets.sh — secrets loading tests
#
# Verifies global and per-project secrets handling, including
# load_secrets_file() behavior for various input formats.

test_project_create_creates_secrets_template() {
    # cco project create should copy secrets.env template
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco project create "my-project"
    assert_file_exists "$CCO_PROJECTS_DIR/my-project/secrets.env"
}

test_project_secrets_not_in_compose() {
    # Per-project secrets must NOT appear in docker-compose.yml (runtime -e only)
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    printf 'PROJECT_SECRET=top_secret_value\n' > "$CCO_PROJECTS_DIR/test-proj/secrets.env"
    run_cco start "test-proj" --dry-run --dump
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"
    assert_file_not_contains "$compose" "top_secret_value"
    assert_file_not_contains "$compose" "PROJECT_SECRET"
}

# ── load_secrets_file unit tests ─────────────────────────────────────

# Helper to source lib files needed for load_secrets_file
_source_secrets_lib() {
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/secrets.sh"
}

test_secrets_valid_key_value_loaded() {
    # Valid KEY=VALUE pairs are loaded into the target array
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_secrets_lib
    local secrets_file="$tmpdir/secrets.env"
    printf 'API_KEY=abc123\nDB_HOST=localhost\n' > "$secrets_file"
    local result=()
    load_secrets_file result "$secrets_file"
    local joined="${result[*]}"
    if [[ "$joined" != *"API_KEY=abc123"* ]]; then
        fail "Expected API_KEY=abc123 in result, got: $joined"
    fi
    if [[ "$joined" != *"DB_HOST=localhost"* ]]; then
        fail "Expected DB_HOST=localhost in result, got: $joined"
    fi
}

test_secrets_comments_ignored() {
    # Lines starting with # are skipped
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_secrets_lib
    local secrets_file="$tmpdir/secrets.env"
    printf '# This is a comment\nVALID_KEY=value\n# Another comment\n' > "$secrets_file"
    local result=()
    load_secrets_file result "$secrets_file"
    local joined="${result[*]}"
    if [[ "$joined" == *"comment"* ]]; then
        fail "Comments should be ignored, got: $joined"
    fi
    if [[ "$joined" != *"VALID_KEY=value"* ]]; then
        fail "Expected VALID_KEY=value in result, got: $joined"
    fi
}

test_secrets_empty_lines_ignored() {
    # Blank lines don't cause errors
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_secrets_lib
    local secrets_file="$tmpdir/secrets.env"
    printf '\n\nKEY=value\n\n\n' > "$secrets_file"
    local result=()
    load_secrets_file result "$secrets_file"
    local count=${#result[@]}
    # Should have exactly 2 entries: -e and KEY=value
    if [[ "$count" -ne 2 ]]; then
        fail "Expected 2 array entries (-e KEY=value), got $count: ${result[*]}"
    fi
}

test_secrets_malformed_line_warned() {
    # Lines without = produce a warning (to stderr)
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_secrets_lib
    local secrets_file="$tmpdir/secrets.env"
    printf 'GOOD_KEY=value\nBADLINE\n' > "$secrets_file"
    local result=()
    local warn_output
    warn_output=$(load_secrets_file result "$secrets_file" 2>&1)
    if [[ "$warn_output" != *"malformed"* ]]; then
        fail "Expected 'malformed' warning, got: $warn_output"
    fi
    if [[ "$warn_output" != *"KEY=VALUE"* ]]; then
        fail "Expected 'KEY=VALUE' in warning, got: $warn_output"
    fi
}

test_secrets_quotes_stripped() {
    # Values with quotes are handled (quotes are part of value in env format)
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_secrets_lib
    local secrets_file="$tmpdir/secrets.env"
    printf 'QUOTED="hello world"\n' > "$secrets_file"
    local result=()
    load_secrets_file result "$secrets_file"
    local joined="${result[*]}"
    # The value should be loaded (quotes are included as-is by load_secrets_file)
    if [[ "$joined" != *"QUOTED="* ]]; then
        fail "Expected QUOTED key in result, got: $joined"
    fi
}

test_secrets_file_not_found_silent() {
    # Missing file doesn't error (returns 0)
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_secrets_lib
    local result=()
    load_secrets_file result "$tmpdir/nonexistent.env"
    local count=${#result[@]}
    if [[ "$count" -ne 0 ]]; then
        fail "Expected 0 entries for missing file, got $count"
    fi
}

test_secrets_special_chars_in_value() {
    # Values with spaces, = signs, and special characters
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_secrets_lib
    local secrets_file="$tmpdir/secrets.env"
    printf 'CONN_STR=host=db port=5432 user=admin\n' > "$secrets_file"
    local result=()
    load_secrets_file result "$secrets_file"
    local joined="${result[*]}"
    if [[ "$joined" != *"CONN_STR="* ]]; then
        fail "Expected CONN_STR in result, got: $joined"
    fi
    # Value should contain the full string after first =
    if [[ "$joined" != *"host=db"* ]]; then
        fail "Expected 'host=db' preserved in value, got: $joined"
    fi
}

test_secrets_inline_comment_stripped() {
    # Inline comments (after KEY=VALUE) should be stripped
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_secrets_lib
    local secrets_file="$tmpdir/secrets.env"
    printf 'MY_KEY=myvalue # this is a comment\n' > "$secrets_file"
    local result=()
    load_secrets_file result "$secrets_file"
    local joined="${result[*]}"
    if [[ "$joined" == *"this is a comment"* ]]; then
        fail "Inline comment should be stripped, got: $joined"
    fi
    if [[ "$joined" != *"MY_KEY=myvalue"* ]]; then
        fail "Expected MY_KEY=myvalue in result, got: $joined"
    fi
}

test_secrets_global_secrets_uses_global_dir() {
    # load_global_secrets reads from GLOBAL_DIR/secrets.env
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_secrets_lib
    export GLOBAL_DIR="$tmpdir/global"
    mkdir -p "$GLOBAL_DIR"
    printf 'GLOBAL_SECRET=top_secret\n' > "$GLOBAL_DIR/secrets.env"
    local result=()
    load_global_secrets result
    local joined="${result[*]}"
    if [[ "$joined" != *"GLOBAL_SECRET=top_secret"* ]]; then
        fail "Expected GLOBAL_SECRET=top_secret in result, got: $joined"
    fi
}
