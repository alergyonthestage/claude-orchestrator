#!/usr/bin/env bash
# tests/test_secrets.sh — secrets loading tests
#
# Verifies global and per-project secrets handling.

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
