#!/usr/bin/env bash
# tests/test_publish_install_sync.sh — FI-7 publish-install sync tests
#
# Tests: yml_set/yml_remove, _is_installed_project, _cco_project_source,
#        source-aware update, project internalize, publish safety checks

# ── Helper to source libs ────────────────────────────────────────────

_source_libs() {
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/yaml.sh"
    source "$REPO_ROOT/lib/update.sh"
}

# ── yml_set / yml_remove ─────────────────────────────────────────────

test_yml_set_top_level_new() {
    _source_libs
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    printf 'name: test\n' > "$tmpdir/test.yml"

    yml_set "$tmpdir/test.yml" "version" "1.0"
    assert_file_contains "$tmpdir/test.yml" "version: 1.0"
}

test_yml_set_top_level_update() {
    _source_libs
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    printf 'name: test\nversion: 0.9\n' > "$tmpdir/test.yml"

    yml_set "$tmpdir/test.yml" "version" "1.0"
    assert_file_contains "$tmpdir/test.yml" "version: 1.0"
    assert_file_not_contains "$tmpdir/test.yml" "version: 0.9"
}

test_yml_set_nested_new_parent() {
    _source_libs
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    printf 'name: test\n' > "$tmpdir/test.yml"

    yml_set "$tmpdir/test.yml" "remote_cache.commit" "abc123"
    assert_file_contains "$tmpdir/test.yml" "remote_cache:"
    assert_file_contains "$tmpdir/test.yml" "  commit: abc123"
}

test_yml_set_nested_existing_parent() {
    _source_libs
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    printf 'name: test\nremote_cache:\n  commit: old\n' > "$tmpdir/test.yml"

    yml_set "$tmpdir/test.yml" "remote_cache.commit" "new123"
    assert_file_contains "$tmpdir/test.yml" "  commit: new123"
    assert_file_not_contains "$tmpdir/test.yml" "  commit: old"
}

test_yml_remove_top_level() {
    _source_libs
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    printf 'name: test\nremote_cache:\n  commit: abc\n  checked: now\nversion: 1\n' > "$tmpdir/test.yml"

    yml_remove "$tmpdir/test.yml" "remote_cache"
    assert_file_not_contains "$tmpdir/test.yml" "remote_cache:"
    assert_file_not_contains "$tmpdir/test.yml" "  commit:"
    assert_file_contains "$tmpdir/test.yml" "name: test"
    assert_file_contains "$tmpdir/test.yml" "version: 1"
}

# ── _cco_project_source helper ───────────────────────────────────────

test_cco_project_source_new_path() {
    _source_libs
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    mkdir -p "$tmpdir/.cco"
    printf 'source: local\n' > "$tmpdir/.cco/source"

    local result
    result=$(_cco_project_source "$tmpdir")
    assert_equals "$tmpdir/.cco/source" "$result" \
        "Should return new path when .cco/source exists"
}

test_cco_project_source_default_path() {
    _source_libs
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    local result
    result=$(_cco_project_source "$tmpdir")
    assert_equals "$tmpdir/.cco/source" "$result" \
        "Should return .cco/source as default path"
}

# ── _is_installed_project ────────────────────────────────────────────

test_is_installed_project_remote() {
    _source_libs
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    mkdir -p "$tmpdir/project/.cco"
    printf 'source: https://github.com/team/config.git\nref: main\ncommit: abc123\n' > "$tmpdir/project/.cco/source"

    _is_installed_project "$tmpdir/project"
    assert_equals "https://github.com/team/config.git" "$_INSTALLED_SOURCE_URL" \
        "_is_installed_project should set URL"
    assert_equals "abc123" "$_INSTALLED_SOURCE_COMMIT" \
        "_is_installed_project should set commit"
}

test_is_installed_project_local() {
    _source_libs
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    mkdir -p "$tmpdir/project/.cco"
    printf 'source: local\n' > "$tmpdir/project/.cco/source"

    ! _is_installed_project "$tmpdir/project" || \
        fail "Local project should return false"
}

test_is_installed_project_native() {
    _source_libs
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    mkdir -p "$tmpdir/project/.cco"
    printf 'native:project/base\n' > "$tmpdir/project/.cco/source"

    ! _is_installed_project "$tmpdir/project" || \
        fail "Native project should return false"
}

test_is_installed_project_no_source() {
    _source_libs
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    mkdir -p "$tmpdir/project/.cco"

    ! _is_installed_project "$tmpdir/project" || \
        fail "Project without .cco/source should return false"
}

# ── Source-aware update ──────────────────────────────────────────────

test_update_installed_project_skips_sync() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Create a project with remote .cco/source
    create_project "$tmpdir" "remote-app" "name: remote-app"
    mkdir -p "$CCO_PROJECTS_DIR/remote-app/.cco"
    printf 'source: https://github.com/team/config.git\nref: main\ncommit: abc123\n' \
        > "$CCO_PROJECTS_DIR/remote-app/.cco/source"

    # Bootstrap .cco/meta with current schema
    local latest_schema
    latest_schema=$(bash -c "source '$REPO_ROOT/lib/colors.sh'; source '$REPO_ROOT/lib/utils.sh'; source '$REPO_ROOT/lib/paths.sh'; source '$REPO_ROOT/lib/yaml.sh'; source '$REPO_ROOT/lib/update.sh'; _latest_schema_version project")
    printf 'schema_version: %s\n' "$latest_schema" \
        > "$CCO_PROJECTS_DIR/remote-app/.cco/meta"

    # Copy base template files
    cp -r "$REPO_ROOT/templates/project/base/.claude/"* "$CCO_PROJECTS_DIR/remote-app/.claude/" 2>/dev/null || true

    run_cco update --sync remote-app
    assert_output_contains "installed from" \
        "Should mention project is installed from remote"
    assert_output_contains "publisher" \
        "Should mention publisher chain"
}

test_update_local_project_applies_sync() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    run_cco project create local-app
    run_cco update --sync local-app --keep
    # Should process local project normally (no "installed from" message)
    assert_output_contains "Update complete"
}

# ── Project internalize ──────────────────────────────────────────────

test_project_internalize() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Create a project with remote source
    create_project "$tmpdir" "remote-app" "name: remote-app"
    mkdir -p "$CCO_PROJECTS_DIR/remote-app/.cco"
    local latest_schema
    latest_schema=$(bash -c "source '$REPO_ROOT/lib/colors.sh'; source '$REPO_ROOT/lib/utils.sh'; source '$REPO_ROOT/lib/paths.sh'; source '$REPO_ROOT/lib/yaml.sh'; source '$REPO_ROOT/lib/update.sh'; _latest_schema_version project")
    printf 'source: https://github.com/team/config.git\nref: main\ncommit: abc123\n' \
        > "$CCO_PROJECTS_DIR/remote-app/.cco/source"
    printf 'schema_version: %s\nremote_cache:\n  commit: abc123\n  checked: 2026-03-17\n' \
        "$latest_schema" \
        > "$CCO_PROJECTS_DIR/remote-app/.cco/meta"

    cp -r "$REPO_ROOT/templates/project/base/.claude/"* "$CCO_PROJECTS_DIR/remote-app/.claude/" 2>/dev/null || true

    # Internalize
    echo "y" | run_cco project internalize remote-app
    assert_output_contains "now local" \
        "Should report project is now local"

    assert_file_contains "$CCO_PROJECTS_DIR/remote-app/.cco/source" "source: local"
    assert_file_not_contains "$CCO_PROJECTS_DIR/remote-app/.cco/meta" "remote_cache:"
}

test_project_internalize_already_local() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    run_cco project create local-app
    run_cco project internalize local-app
    assert_output_contains "already local"
}

# ── Discovery output ─────────────────────────────────────────────────

test_update_discovery_offline() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Create installed project
    create_project "$tmpdir" "team-svc" "name: team-svc"
    mkdir -p "$CCO_PROJECTS_DIR/team-svc/.cco"
    local latest_schema
    latest_schema=$(bash -c "source '$REPO_ROOT/lib/colors.sh'; source '$REPO_ROOT/lib/utils.sh'; source '$REPO_ROOT/lib/paths.sh'; source '$REPO_ROOT/lib/yaml.sh'; source '$REPO_ROOT/lib/update.sh'; _latest_schema_version project")
    printf 'source: https://github.com/team/config.git\nref: main\ncommit: abc123\n' \
        > "$CCO_PROJECTS_DIR/team-svc/.cco/source"
    printf 'schema_version: %s\n' "$latest_schema" \
        > "$CCO_PROJECTS_DIR/team-svc/.cco/meta"
    cp -r "$REPO_ROOT/templates/project/base/.claude/"* "$CCO_PROJECTS_DIR/team-svc/.claude/" 2>/dev/null || true

    run_cco update --offline
    assert_output_contains "team-svc"
}

# ── Project update (no remote) ───────────────────────────────────────

test_project_update_local_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    run_cco project create my-app

    ! run_cco project update my-app || \
        fail "project update on local project should fail"
    assert_output_contains "local"
}

test_project_update_help() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco project update --help
    assert_output_contains "3-way merge"
}
