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

    # Internalize (--yes for non-interactive)
    run_cco project internalize remote-app --yes
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

# ── yml_set scoping (bug regression) ─────────────────────────────────

test_yml_set_nested_scoped_to_parent() {
    # Critical: yml_set must only update the child under the correct parent,
    # not all children with the same name across different parents
    _source_libs
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    cat > "$tmpdir/test.yml" <<'YAML'
block_a:
  commit: aaa
  checked: time_a
block_b:
  commit: bbb
  checked: time_b
YAML

    yml_set "$tmpdir/test.yml" "block_a.commit" "NEW"
    assert_file_contains "$tmpdir/test.yml" "  commit: NEW"
    # block_b's commit must NOT be changed
    local block_b_commit
    block_b_commit=$(awk '/^block_b:/{f=1;next} f&&/^[^ ]/{f=0} f&&/commit:/{print $2}' "$tmpdir/test.yml")
    assert_equals "bbb" "$block_b_commit" \
        "yml_set should only update child under the target parent"
}

test_yml_set_nested_add_new_child() {
    _source_libs
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    printf 'remote_cache:\n  commit: abc\n' > "$tmpdir/test.yml"

    yml_set "$tmpdir/test.yml" "remote_cache.checked" "2026-03-17"
    assert_file_contains "$tmpdir/test.yml" "  checked: 2026-03-17"
    assert_file_contains "$tmpdir/test.yml" "  commit: abc"
}

test_yml_remove_nonexistent_is_noop() {
    _source_libs
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    printf 'name: test\nversion: 1\n' > "$tmpdir/test.yml"

    yml_remove "$tmpdir/test.yml" "nonexistent"
    assert_file_contains "$tmpdir/test.yml" "name: test"
    assert_file_contains "$tmpdir/test.yml" "version: 1"
}

# ── _cache_fresh ─────────────────────────────────────────────────────

test_cache_fresh_recent() {
    _source_libs
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    _cache_fresh "$now" 3600 || fail "Recent timestamp should be fresh"
}

test_cache_fresh_expired() {
    _source_libs
    ! _cache_fresh "2020-01-01T00:00:00Z" 3600 || \
        fail "Old timestamp should be expired"
}

test_cache_fresh_empty() {
    _source_libs
    ! _cache_fresh "" 3600 || \
        fail "Empty timestamp should be treated as stale"
}

# ── --local flag on installed project ────────────────────────────────

test_update_sync_installed_with_local() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Create installed project with a modified file to trigger sync
    create_project "$tmpdir" "remote-app" "name: remote-app"
    mkdir -p "$CCO_PROJECTS_DIR/remote-app/.cco/base" "$CCO_PROJECTS_DIR/remote-app/.claude"
    local latest_schema
    latest_schema=$(bash -c "source '$REPO_ROOT/lib/colors.sh'; source '$REPO_ROOT/lib/utils.sh'; source '$REPO_ROOT/lib/paths.sh'; source '$REPO_ROOT/lib/yaml.sh'; source '$REPO_ROOT/lib/update.sh'; _latest_schema_version project")
    printf 'source: https://github.com/team/config.git\nref: main\ncommit: abc123\n' \
        > "$CCO_PROJECTS_DIR/remote-app/.cco/source"
    printf 'schema_version: %s\n' "$latest_schema" \
        > "$CCO_PROJECTS_DIR/remote-app/.cco/meta"
    # Copy base template files
    cp -r "$REPO_ROOT/templates/project/base/.claude/"* "$CCO_PROJECTS_DIR/remote-app/.claude/" 2>/dev/null || true
    # Save base versions (matching installed)
    cp -r "$REPO_ROOT/templates/project/base/.claude/"* "$CCO_PROJECTS_DIR/remote-app/.cco/base/" 2>/dev/null || true
    # Simulate framework update: modify a default file
    printf '\n# Framework improvement\n' >> "$REPO_ROOT/defaults/global/.claude/rules/workflow.md"

    # --local should apply framework defaults (not skip like without --local)
    run_cco update --sync remote-app --local --keep
    assert_output_contains "escape hatch" \
        "Should mention --local escape hatch"
    # Should set override marker in meta
    assert_file_contains "$CCO_PROJECTS_DIR/remote-app/.cco/meta" "local_framework_override: true"

    # Restore default
    cd "$REPO_ROOT" && git checkout -- defaults/global/.claude/rules/workflow.md
}

# ── project internalize non-TTY requires --yes ───────────────────────

test_project_internalize_non_tty_requires_yes() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    create_project "$tmpdir" "remote-app" "name: remote-app"
    mkdir -p "$CCO_PROJECTS_DIR/remote-app/.cco"
    printf 'source: https://github.com/team/config.git\nref: main\n' \
        > "$CCO_PROJECTS_DIR/remote-app/.cco/source"

    # Without --yes in non-TTY, should fail
    ! run_cco project internalize remote-app || \
        fail "internalize without --yes in non-TTY should fail"
    assert_output_contains "--yes"
}

# ── project install writes .cco/source ───────────────────────────────

test_project_install_writes_source_metadata() {
    # After install, project should have .cco/source with YAML metadata
    # This test requires a real Config Repo — we create one locally
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Create a bare Config Repo with a template
    local repo_dir="$tmpdir/config-repo"
    mkdir -p "$repo_dir/templates/test-tmpl/.claude/rules"
    printf 'name: test-tmpl\ndescription: test\nrepos: []\n' > "$repo_dir/templates/test-tmpl/project.yml"
    printf '# Test CLAUDE.md\n' > "$repo_dir/templates/test-tmpl/.claude/CLAUDE.md"
    printf '# Test rule\n' > "$repo_dir/templates/test-tmpl/.claude/rules/test.md"
    cat > "$repo_dir/manifest.yml" <<'YAML'
name: test-config
description: test
packs: []
templates:
  - name: test-tmpl
    description: test template
YAML
    git -C "$repo_dir" init -q
    git -C "$repo_dir" add -A
    git -C "$repo_dir" commit -q -m "init"

    # Install from local git repo
    run_cco project install "$repo_dir" --pick test-tmpl --as test-proj
    assert_file_exists "$CCO_PROJECTS_DIR/test-proj/.cco/source" \
        ".cco/source should be created after install"
    assert_file_contains "$CCO_PROJECTS_DIR/test-proj/.cco/source" "source: $repo_dir" \
        ".cco/source should contain the remote URL"
    assert_file_contains "$CCO_PROJECTS_DIR/test-proj/.cco/source" "installed:" \
        ".cco/source should contain install date"
    assert_file_contains "$CCO_PROJECTS_DIR/test-proj/.cco/source" "commit:" \
        ".cco/source should contain commit hash"
    assert_dir_exists "$CCO_PROJECTS_DIR/test-proj/.cco/base" \
        ".cco/base should be created for future 3-way merge"
}

# ── publish safety: .cco/publish-ignore ──────────────────────────────

test_publish_ignore_excludes_files() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Create project with publish-ignore
    run_cco project create pub-test
    mkdir -p "$CCO_PROJECTS_DIR/pub-test/.cco"
    printf 'local-*.md\n*.draft\n' > "$CCO_PROJECTS_DIR/pub-test/.cco/publish-ignore"
    echo "local notes" > "$CCO_PROJECTS_DIR/pub-test/.claude/rules/local-notes.md"
    echo "draft" > "$CCO_PROJECTS_DIR/pub-test/.claude/rules/review.draft"

    # Create bare remote
    local bare_dir
    bare_dir=$(_create_bare_remote_for_test "$tmpdir")

    run_cco project publish pub-test "$bare_dir" --force
    # Verify excluded files are not in the remote
    local work_dir="$tmpdir/verify"
    git clone -q "$bare_dir" "$work_dir"
    assert_file_not_exists "$work_dir/templates/pub-test/.claude/rules/local-notes.md" \
        "publish-ignore should exclude local-*.md"
    assert_file_not_exists "$work_dir/templates/pub-test/.claude/rules/review.draft" \
        "publish-ignore should exclude *.draft"
}

# Helper for publish tests
# ── --local validation ────────────────────────────────────────────────

test_local_flag_requires_sync() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    ! run_cco update --local || \
        fail "--local without --sync should fail"
    assert_output_contains "--local can only be used with --sync"
}

# ── internalize writes source:local as first line ────────────────────

test_internalize_source_local_first_line() {
    _source_libs
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    create_project "$tmpdir" "remote-app" "name: remote-app"
    mkdir -p "$CCO_PROJECTS_DIR/remote-app/.cco"
    printf 'source: https://github.com/team/config.git\nref: main\n' \
        > "$CCO_PROJECTS_DIR/remote-app/.cco/source"
    printf 'schema_version: 10\nlocal_framework_override: true\n' \
        > "$CCO_PROJECTS_DIR/remote-app/.cco/meta"
    cp -r "$REPO_ROOT/templates/project/base/.claude/"* "$CCO_PROJECTS_DIR/remote-app/.claude/" 2>/dev/null || true

    run_cco project internalize remote-app --yes

    # source: local must be first line (not a comment)
    local first_line
    first_line=$(head -1 "$CCO_PROJECTS_DIR/remote-app/.cco/source")
    assert_equals "source: local" "$first_line" \
        "First line of .cco/source should be 'source: local'"

    # local_framework_override should be cleared
    assert_file_not_contains "$CCO_PROJECTS_DIR/remote-app/.cco/meta" "local_framework_override"
}

# ── Publish detects secrets at project root ──────────────────────────

test_publish_detects_root_secrets() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    run_cco project create secret-root-app

    # Create a .key file at the project root (not inside .claude/)
    touch "$CCO_PROJECTS_DIR/secret-root-app/server.key"

    # Create bare remote
    local bare_dir
    bare_dir=$(_create_bare_remote_for_test "$tmpdir")

    ! run_cco project publish secret-root-app "$bare_dir" --force || \
        fail "Publish should block on root-level secrets"
    assert_output_contains "secrets detected"
}

# ── _is_installed_project after internalize ──────────────────────────

test_is_installed_project_after_internalize() {
    _source_libs
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    mkdir -p "$tmpdir/project/.cco"
    # Write internalized format: source: local on first line, comment on second
    printf 'source: local\n# previously installed from: https://example.com\n' \
        > "$tmpdir/project/.cco/source"

    ! _is_installed_project "$tmpdir/project" || \
        fail "Internalized project should be detected as local"
}

# ── Helper ────────────────────────────────────────────────────────────

_create_bare_remote_for_test() {
    local tmpdir="$1"
    local bare_dir="$tmpdir/publish-remote.git"
    local work_dir="$tmpdir/init-work"
    mkdir -p "$work_dir"
    git -C "$work_dir" init -q
    printf 'name: ""\ndescription: ""\npacks: []\ntemplates: []\n' > "$work_dir/manifest.yml"
    git -C "$work_dir" add -A
    git -C "$work_dir" commit -q -m "init"
    git init --bare -q "$bare_dir"
    git -C "$work_dir" remote add origin "$bare_dir"
    git -C "$work_dir" push -q origin main 2>/dev/null || \
        git -C "$work_dir" push -q origin master 2>/dev/null
    rm -rf "$work_dir"
    echo "$bare_dir"
}
