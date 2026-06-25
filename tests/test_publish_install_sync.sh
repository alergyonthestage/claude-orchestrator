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
    source "$REPO_ROOT/lib/update-hash-io.sh"
    source "$REPO_ROOT/lib/update-merge.sh"
    source "$REPO_ROOT/lib/update-meta.sh"
    source "$REPO_ROOT/lib/update-discovery.sh"
    source "$REPO_ROOT/lib/update-sync.sh"
    source "$REPO_ROOT/lib/update-changelog.sh"
    source "$REPO_ROOT/lib/update-remote.sh"
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
    export CCO_DATA_HOME="$tmpdir/data"
    # The install-provenance source now lives in DATA, keyed by project id.
    # With a project.yml `name:`, the id is that name (ADR-0022 D1).
    mkdir -p "$tmpdir/.cco"
    printf 'name: src-proj\n' > "$tmpdir/.cco/project.yml"

    local result
    result=$(_cco_project_source "$tmpdir")
    assert_equals "$(_cco_data_dir)/projects/src-proj/source" "$result" \
        "Should resolve to the DATA source path keyed by project id"
}

test_cco_project_source_default_path() {
    _source_libs
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    export CCO_DATA_HOME="$tmpdir/data"
    # With no project.yml, the id falls back to the dir basename.
    local result
    result=$(_cco_project_source "$tmpdir")
    assert_equals "$(_cco_data_dir)/projects/$(basename "$tmpdir")/source" "$result" \
        "Should resolve to the DATA source path keyed by dir basename"
}

# ── _is_installed_project ────────────────────────────────────────────

test_is_installed_project_remote() {
    _source_libs
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    export CCO_DATA_HOME="$tmpdir/data" CCO_STATE_HOME="$tmpdir/state"
    mkdir -p "$tmpdir/project/.cco"
    # Coordinate → DATA source; install commit → STATE meta (ADR-0022 D1).
    local src_file meta_file
    src_file=$(_cco_project_source "$tmpdir/project")
    meta_file=$(_cco_project_meta "$tmpdir/project")
    mkdir -p "$(dirname "$src_file")" "$(dirname "$meta_file")"
    printf 'url: https://github.com/team/config.git\nref: main\n' > "$src_file"
    printf 'installed_commit: abc123\n' > "$meta_file"

    _is_installed_project "$tmpdir/project"
    assert_equals "https://github.com/team/config.git" "$_INSTALLED_SOURCE_URL" \
        "_is_installed_project should set URL"
    assert_equals "abc123" "$_INSTALLED_SOURCE_COMMIT" \
        "_is_installed_project should set commit"
}

test_is_installed_project_local() {
    _source_libs
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    export CCO_DATA_HOME="$tmpdir/data" CCO_STATE_HOME="$tmpdir/state"
    mkdir -p "$tmpdir/project/.cco"
    # Authored/disconnected source coordinate → DATA, first key `url: local`.
    local src_file; src_file=$(_cco_project_source "$tmpdir/project")
    mkdir -p "$(dirname "$src_file")"
    printf 'url: local\n' > "$src_file"

    ! _is_installed_project "$tmpdir/project" || \
        fail "Local project should return false"
}

test_is_installed_project_native() {
    _source_libs
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    export CCO_DATA_HOME="$tmpdir/data" CCO_STATE_HOME="$tmpdir/state"
    mkdir -p "$tmpdir/project/.cco"
    local src_file; src_file=$(_cco_project_source "$tmpdir/project")
    mkdir -p "$(dirname "$src_file")"
    printf 'native:project/base\n' > "$src_file"

    ! _is_installed_project "$tmpdir/project" || \
        fail "Native project should return false"
}

test_is_installed_project_no_source() {
    _source_libs
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    export CCO_DATA_HOME="$tmpdir/data" CCO_STATE_HOME="$tmpdir/state"
    mkdir -p "$tmpdir/project/.cco"

    ! _is_installed_project "$tmpdir/project" || \
        fail "Project without a DATA source should return false"
}

# ── Source-aware update ──────────────────────────────────────────────

test_update_installed_project_skips_sync() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    init_global "$tmpdir" --lang "English"

    # Installed-from-remote project (P5): DATA source coordinate + STATE meta
    # (schema + installed commit) + the committed <repo>/.cco/claude tree.
    create_project "$tmpdir" "remote-app" "name: remote-app"
    local latest_schema
    latest_schema=$(bash -c "source '$REPO_ROOT/lib/colors.sh'; source '$REPO_ROOT/lib/utils.sh'; source '$REPO_ROOT/lib/paths.sh'; source '$REPO_ROOT/lib/yaml.sh'; source '$REPO_ROOT/lib/update-hash-io.sh'; source '$REPO_ROOT/lib/update-merge.sh'; source '$REPO_ROOT/lib/update-meta.sh'; source '$REPO_ROOT/lib/update-discovery.sh'; source '$REPO_ROOT/lib/update-sync.sh'; source '$REPO_ROOT/lib/update-changelog.sh'; source '$REPO_ROOT/lib/update-remote.sh'; source '$REPO_ROOT/lib/update.sh'; _latest_schema_version project")
    mkdir -p "$(dirname "$(data_project_source remote-app)")"
    printf 'url: https://github.com/team/config.git\nref: main\n' \
        > "$(data_project_source remote-app)"
    mkdir -p "$(dirname "$(state_project_meta remote-app)")"
    printf 'schema_version: %s\ninstalled_commit: abc123\n' "$latest_schema" \
        > "$(state_project_meta remote-app)"
    cp -r "$REPO_ROOT/templates/project/base/.claude/"* \
        "$(host_cco_dir "$tmpdir" remote-app)/claude/" 2>/dev/null || true

    run_cco update --sync remote-app
    assert_output_contains "installed from" \
        "Should mention project is installed from remote"
    assert_output_contains "publisher" \
        "Should mention publisher chain"
}

test_update_local_project_applies_sync() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    init_global "$tmpdir" --lang "English"

    create_project "$tmpdir" "local-app" "$(minimal_project_yml local-app)"
    run_cco update --sync local-app --keep
    # Should process local project normally (no "installed from" message)
    assert_output_contains "Update complete"
}

# ── Project internalize ──────────────────────────────────────────────



# ── Discovery output ─────────────────────────────────────────────────

test_update_discovery_offline() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    init_global "$tmpdir" --lang "English"

    # Installed project (P5): DATA source + STATE meta + committed claude tree.
    create_project "$tmpdir" "team-svc" "name: team-svc"
    local latest_schema
    latest_schema=$(bash -c "source '$REPO_ROOT/lib/colors.sh'; source '$REPO_ROOT/lib/utils.sh'; source '$REPO_ROOT/lib/paths.sh'; source '$REPO_ROOT/lib/yaml.sh'; source '$REPO_ROOT/lib/update-hash-io.sh'; source '$REPO_ROOT/lib/update-merge.sh'; source '$REPO_ROOT/lib/update-meta.sh'; source '$REPO_ROOT/lib/update-discovery.sh'; source '$REPO_ROOT/lib/update-sync.sh'; source '$REPO_ROOT/lib/update-changelog.sh'; source '$REPO_ROOT/lib/update-remote.sh'; source '$REPO_ROOT/lib/update.sh'; _latest_schema_version project")
    mkdir -p "$(dirname "$(data_project_source team-svc)")"
    printf 'url: https://github.com/team/config.git\nref: main\n' \
        > "$(data_project_source team-svc)"
    mkdir -p "$(dirname "$(state_project_meta team-svc)")"
    printf 'schema_version: %s\ninstalled_commit: abc123\n' "$latest_schema" \
        > "$(state_project_meta team-svc)"
    cp -r "$REPO_ROOT/templates/project/base/.claude/"* \
        "$(host_cco_dir "$tmpdir" team-svc)/claude/" 2>/dev/null || true

    run_cco update --offline
    assert_output_contains "team-svc"
}

# ── Project update (no remote) ───────────────────────────────────────



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
    local tmpdir; tmpdir=$(mktemp -d)
    setup_cco_env "$tmpdir"
    init_global "$tmpdir" --lang "English"

    # Create installed project with a modified file to trigger sync. The
    # installed claude tree lives in the committed <repo>/.cco/claude (P5).
    create_project "$tmpdir" "remote-app" "name: remote-app"
    local cco; cco=$(host_cco_dir "$tmpdir" "remote-app")
    mkdir -p "$cco/claude"
    local latest_schema
    latest_schema=$(bash -c "source '$REPO_ROOT/lib/colors.sh'; source '$REPO_ROOT/lib/utils.sh'; source '$REPO_ROOT/lib/paths.sh'; source '$REPO_ROOT/lib/yaml.sh'; source '$REPO_ROOT/lib/update-hash-io.sh'; source '$REPO_ROOT/lib/update-merge.sh'; source '$REPO_ROOT/lib/update-meta.sh'; source '$REPO_ROOT/lib/update-discovery.sh'; source '$REPO_ROOT/lib/update-sync.sh'; source '$REPO_ROOT/lib/update-changelog.sh'; source '$REPO_ROOT/lib/update-remote.sh'; source '$REPO_ROOT/lib/update.sh'; _latest_schema_version project")
    # Coordinate → DATA source; schema + install commit → STATE meta (ADR-0022 D1).
    mkdir -p "$(dirname "$(data_project_source remote-app)")"
    printf 'url: https://github.com/team/config.git\nref: main\n' \
        > "$(data_project_source remote-app)"
    mkdir -p "$(dirname "$(state_project_meta remote-app)")"
    printf 'schema_version: %s\ninstalled_commit: abc123\n' "$latest_schema" \
        > "$(state_project_meta remote-app)"
    # Copy base template files (project base template has CLAUDE.md, settings.json, etc.)
    cp -r "$REPO_ROOT/templates/project/base/.claude/"* "$cco/claude/" 2>/dev/null || true
    # Save base versions (matching installed) → STATE base (H6)
    mkdir -p "$(state_project_base remote-app)"
    cp -r "$REPO_ROOT/templates/project/base/.claude/"* "$(state_project_base remote-app)/" 2>/dev/null || true

    # Simulate framework update: modify the PROJECT base template CLAUDE.md
    # (this is what project sync compares against for installed projects)
    with_framework_change "templates/project/base/.claude/CLAUDE.md" \
        $'\n# Framework improvement for projects\n'

    # --local should apply framework defaults (not skip like without --local)
    run_cco update --sync remote-app --local --force
    assert_output_contains "escape hatch" \
        "Should mention --local escape hatch"

    # Verify framework file content was actually applied to the project directory
    # With --force on UPDATE_AVAILABLE, the file IS replaced with the new default
    assert_file_contains "$cco/claude/CLAUDE.md" \
        "Framework improvement for projects" \
        "--local --force should apply framework file content to installed project"

    # NOTE: The local_framework_override marker is set by yml_set before
    # _interactive_sync, but _generate_project_cco_meta rewrites the entire
    # .cco/meta file without preserving it. This is a known implementation gap.
    # The marker IS written (line 1960 in update.sh) but lost during meta
    # regeneration (line 2012). Documenting here for future fix.
    # with_framework_change trap restores the template file automatically
}

# ── project internalize non-TTY requires --yes ───────────────────────


# ── project install writes .cco/source ───────────────────────────────


# ── publish safety: .cco/publish-ignore ──────────────────────────────


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


# ── Publish detects secrets at project root ──────────────────────────


# ── _is_installed_project after internalize ──────────────────────────

test_is_installed_project_after_internalize() {
    _source_libs
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    export CCO_DATA_HOME="$tmpdir/data" CCO_STATE_HOME="$tmpdir/state"
    mkdir -p "$tmpdir/project/.cco"
    # Write internalized format: url: local on first line, comment on second
    local src_file; src_file=$(_cco_project_source "$tmpdir/project")
    mkdir -p "$(dirname "$src_file")"
    printf 'url: local\n# previously installed from: https://example.com\n' \
        > "$src_file"

    ! _is_installed_project "$tmpdir/project" || \
        fail "Internalized project should be detected as local"
}

# ── Content-based secret scan ─────────────────────────────────────────



# ── Migration check (L-2 fix) ────────────────────────────────────────


# ── Publish dry-run shows diff ────────────────────────────────────────


# ── Publish writes metadata ──────────────────────────────────────────


# ── Publish-ignore with path patterns ────────────────────────────────


# ── T-1: End-to-end project update 3-way merge scenarios ─────────────

# Scenario 1: Publisher updates a file; consumer has no local changes → clean apply

# Scenario 2: Publisher updates; consumer has local changes → --force replaces + .bak preserves

# Scenario 3: Consumer used --local, then publisher updates

# ── T-1 Priority 4: cco project update --all ─────────────────────────


# ── Strengthen: test_update_discovery_offline ─────────────────────────

test_update_discovery_offline_no_cache_update() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    init_global "$tmpdir" --lang "English"

    # Installed project with a pre-set remote_cache timestamp (P5): DATA source +
    # STATE meta (schema + remote_cache) + committed claude tree.
    create_project "$tmpdir" "offline-svc" "name: offline-svc"
    local latest_schema
    latest_schema=$(bash -c "source '$REPO_ROOT/lib/colors.sh'; source '$REPO_ROOT/lib/utils.sh'; source '$REPO_ROOT/lib/paths.sh'; source '$REPO_ROOT/lib/yaml.sh'; source '$REPO_ROOT/lib/update-hash-io.sh'; source '$REPO_ROOT/lib/update-merge.sh'; source '$REPO_ROOT/lib/update-meta.sh'; source '$REPO_ROOT/lib/update-discovery.sh'; source '$REPO_ROOT/lib/update-sync.sh'; source '$REPO_ROOT/lib/update-changelog.sh'; source '$REPO_ROOT/lib/update-remote.sh'; source '$REPO_ROOT/lib/update.sh'; _latest_schema_version project")
    mkdir -p "$(dirname "$(data_project_source offline-svc)")"
    printf 'url: https://github.com/team/config.git\nref: main\n' \
        > "$(data_project_source offline-svc)"
    mkdir -p "$(dirname "$(state_project_meta offline-svc)")"
    printf 'schema_version: %s\ninstalled_commit: abc123\nremote_cache:\n  commit: abc123\n  checked: 2026-03-17T10:00:00Z\n' \
        "$latest_schema" \
        > "$(state_project_meta offline-svc)"
    cp -r "$REPO_ROOT/templates/project/base/.claude/"* \
        "$(host_cco_dir "$tmpdir" offline-svc)/claude/" 2>/dev/null || true

    # Run with --offline
    run_cco update --offline
    assert_output_contains "offline-svc"

    # Verify remote_cache.checked was NOT updated (no network call happened)
    assert_file_contains "$(state_project_meta offline-svc)" \
        "checked: 2026-03-17T10:00:00Z" \
        "--offline should not update remote_cache.checked timestamp"
}

# ── Strengthen: test_update_local_project_applies_sync ────────────────

test_update_local_project_sync_with_divergence() {
    local tmpdir; tmpdir=$(mktemp -d)
    setup_cco_env "$tmpdir"
    init_global "$tmpdir" --lang "English"

    create_project "$tmpdir" "sync-test-app" "$(minimal_project_yml sync-test-app)"
    local cco; cco=$(host_cco_dir "$tmpdir" "sync-test-app")

    # Create actual framework divergence in CLAUDE.md (tracked by PROJECT_FILE_POLICIES)
    # The project template base is templates/project/base/.claude/CLAUDE.md
    with_framework_change "templates/project/base/.claude/CLAUDE.md" \
        $'\n# Sync divergence test change\n'

    # Run sync with --force to apply changes non-interactively
    run_cco update --sync sync-test-app --force
    assert_output_contains "Update complete" \
        "Sync should complete successfully"

    # Verify the divergent content was actually applied to the project's claude tree
    assert_file_contains "$cco/claude/CLAUDE.md" \
        "Sync divergence test change" \
        "Framework divergence should be applied to the project"
    # with_framework_change trap restores the template file
}

# ── Priority 2: _check_remote_update cache behavior ──────────────────

test_check_remote_cache_hit_no_network() {
    _source_libs
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT

    # Set up a source coordinate + meta with the install commit and a fresh
    # cache timestamp (now). Coordinate (url/ref) → source; installed_commit +
    # remote_cache → meta (ADR-0022 D1).
    mkdir -p "$tmpdir/project/.cco"
    printf 'url: https://unreachable.example.com/config.git\nref: main\n' \
        > "$tmpdir/project/.cco/source"
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    printf 'schema_version: 1\ninstalled_commit: abc123\nremote_cache:\n  commit: abc123\n  checked: %s\n' "$now" \
        > "$tmpdir/project/.cco/meta"

    # _check_remote_update should return up_to_date from cache (no network needed)
    # If it tried network, it would fail on unreachable.example.com
    local result
    result=$(_check_remote_update "$tmpdir/project/.cco/source" "$tmpdir/project/.cco/meta" "default")
    assert_equals "up_to_date" "$result" \
        "Fresh cache should return up_to_date without network call"
}

test_check_remote_cache_hit_update_available() {
    _source_libs
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT

    # Set up: installed commit differs from cached remote commit
    mkdir -p "$tmpdir/project/.cco"
    printf 'url: https://unreachable.example.com/config.git\nref: main\n' \
        > "$tmpdir/project/.cco/source"
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    printf 'schema_version: 1\ninstalled_commit: old123\nremote_cache:\n  commit: new456\n  checked: %s\n' "$now" \
        > "$tmpdir/project/.cco/meta"

    local result
    result=$(_check_remote_update "$tmpdir/project/.cco/source" "$tmpdir/project/.cco/meta" "default")
    assert_equals "update_available" "$result" \
        "Cache with different commit should return update_available"
}

test_check_remote_cache_stale_unreachable() {
    _source_libs
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT

    # Set up: stale cache (old timestamp), unreachable remote
    mkdir -p "$tmpdir/project/.cco"
    printf 'url: https://unreachable.example.com/config.git\nref: main\n' \
        > "$tmpdir/project/.cco/source"
    printf 'schema_version: 1\ninstalled_commit: abc123\nremote_cache:\n  commit: abc123\n  checked: 2020-01-01T00:00:00Z\n' \
        > "$tmpdir/project/.cco/meta"

    local result
    result=$(_check_remote_update "$tmpdir/project/.cco/source" "$tmpdir/project/.cco/meta" "default")
    assert_equals "unreachable" "$result" \
        "Stale cache + unreachable remote should return unreachable"
}

# ── Priority 3: Pack update full-replace verification ─────────────────

test_pack_update_full_replace() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    init_global "$tmpdir" --lang "English"

    # Create a Config Repo with a pack
    local work_dir="$tmpdir/pack-work"
    local bare_dir="$tmpdir/pack-repo.git"
    mkdir -p "$work_dir/packs/test-pack"/{knowledge,agents,rules}
    cat > "$work_dir/packs/test-pack/pack.yml" <<'YAML'
name: test-pack
description: "Test pack"
agents:
  - bot.md
rules:
  - style.md
YAML
    printf '# Original agent\n' > "$work_dir/packs/test-pack/agents/bot.md"
    printf '# Original rules\n' > "$work_dir/packs/test-pack/rules/style.md"
    cat > "$work_dir/manifest.yml" <<'YAML'
name: test-config
description: test
packs:
  - name: test-pack
    description: test pack
templates: []
YAML
    git -C "$work_dir" init -q
    git -C "$work_dir" add -A
    git -C "$work_dir" commit -q -m "init"
    git init --bare -q "$bare_dir"
    git -C "$work_dir" remote add origin "$bare_dir"
    git -C "$work_dir" push -q origin main 2>/dev/null || \
        git -C "$work_dir" push -q origin master 2>/dev/null

    # Install the pack
    run_cco pack install "$bare_dir" --pick test-pack

    # Consumer modifies a file in the pack
    printf '# Consumer modified agent\n' > "$CCO_PACKS_DIR/test-pack/agents/bot.md"
    assert_file_contains "$CCO_PACKS_DIR/test-pack/agents/bot.md" "Consumer modified"

    # Publisher updates the pack in the Config Repo
    _update_config_repo "$bare_dir" "packs/test-pack/agents/bot.md" "# Publisher updated agent v2"

    # Run pack update
    run_cco pack update test-pack

    # Verify: consumer modification was overwritten (full-replace semantics)
    assert_file_contains "$CCO_PACKS_DIR/test-pack/agents/bot.md" "Publisher updated agent v2" \
        "Pack update should full-replace consumer modifications"
    assert_file_not_contains "$CCO_PACKS_DIR/test-pack/agents/bot.md" "Consumer modified" \
        "Consumer changes should be gone after pack update"
}

