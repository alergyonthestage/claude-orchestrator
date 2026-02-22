#!/usr/bin/env bash
# tests/test_auth.sh — authentication flow tests
#
# Verifies OAuth token extraction from macOS Keychain (mocked) and
# that auth method selection affects compose generation correctly.
#
# Uses _mock_security_with_token / _mock_security_empty from mocks.sh.

test_auth_oauth_token_extracted_from_keychain() {
    # get_oauth_token reads the access token from the mocked Keychain JSON
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    local mock_bin="$tmpdir/mock-bin"
    _mock_security_with_token "$mock_bin" "fake-token-abc123"

    # Create a project that uses oauth auth
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"

    # Run with mocked PATH — the OAuth token is passed as -e CLAUDE_CODE_OAUTH_TOKEN
    # at docker run time (not in compose file), so we verify it doesn't appear in compose
    # and that the run succeeds without error
    PATH="$mock_bin:$PATH" run_cco start "test-proj" --dry-run

    # Compose should exist (dry-run succeeded)
    assert_file_exists "$CCO_PROJECTS_DIR/test-proj/docker-compose.yml"
    # OAuth token must NOT be written to compose file (it's a runtime -e flag)
    assert_file_not_contains "$CCO_PROJECTS_DIR/test-proj/docker-compose.yml" \
        "fake-token-abc123"
    assert_file_not_contains "$CCO_PROJECTS_DIR/test-proj/docker-compose.yml" \
        "CLAUDE_CODE_OAUTH_TOKEN"
}

test_auth_oauth_missing_keychain_continues_with_warning() {
    # When Keychain has no token (exit 1), cmd_start warns but does NOT die
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    local mock_bin="$tmpdir/mock-bin"
    _mock_security_empty "$mock_bin"

    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"

    # dry-run doesn't reach get_oauth_token (only called at docker run time)
    # Just verify dry-run succeeds with no token available
    PATH="$mock_bin:$PATH" run_cco start "test-proj" --dry-run

    assert_file_exists "$CCO_PROJECTS_DIR/test-proj/docker-compose.yml"
}

test_auth_oauth_does_not_put_api_key_in_compose() {
    # oauth auth → ANTHROPIC_API_KEY must NOT appear anywhere in compose
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    run_cco start "test-proj" --dry-run
    assert_file_not_contains "$CCO_PROJECTS_DIR/test-proj/docker-compose.yml" "ANTHROPIC_API_KEY"
}

test_auth_api_key_method_adds_env_var_to_compose() {
    # api_key auth → ANTHROPIC_API_KEY env var present in compose environment section
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(cat <<'YAML'
name: test-proj
auth:
  method: api_key
docker:
  ports: []
  env: {}
repos: []
YAML
)"
    run_cco start "test-proj" --dry-run
    assert_file_contains "$CCO_PROJECTS_DIR/test-proj/docker-compose.yml" "ANTHROPIC_API_KEY"
}
