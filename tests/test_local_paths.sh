#!/usr/bin/env bash
# tests/test_local_paths.sh — unified local path resolution tests
#
# Verifies lib/local-paths.sh: YAML get/set, sanitize/resolve roundtrip,
# extract/restore for vault save, and installed path resolution.

_source_local_paths() {
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/yaml.sh"
    source "$REPO_ROOT/lib/local-paths.sh"
}

# ── _local_paths_get / _local_paths_set ──────────────────────────────

test_local_paths_set_creates_file() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_local_paths

    local lp="$tmpdir/project/.cco/local-paths.yml"
    _local_paths_set "$lp" "repos" "backend-api" "~/Projects/backend-api"

    assert_file_exists "$lp"
    assert_file_contains "$lp" "repos:"
    assert_file_contains "$lp" 'backend-api: "~/Projects/backend-api"'
}

test_local_paths_get_reads_value() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_local_paths

    local lp="$tmpdir/local-paths.yml"
    _local_paths_set "$lp" "repos" "backend-api" "~/Projects/backend-api"

    local result
    result=$(_local_paths_get "$lp" "repos" "backend-api")
    assert_equals "~/Projects/backend-api" "$result" "Should read back the set value"
}

test_local_paths_get_missing_key_returns_empty() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_local_paths

    local lp="$tmpdir/local-paths.yml"
    _local_paths_set "$lp" "repos" "backend-api" "~/Projects/backend-api"

    local result
    result=$(_local_paths_get "$lp" "repos" "nonexistent")
    assert_empty "$result" "Missing key should return empty"
}

test_local_paths_get_missing_file_returns_empty() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_local_paths

    local result
    result=$(_local_paths_get "$tmpdir/nonexistent.yml" "repos" "foo")
    assert_empty "$result" "Missing file should return empty"
}

test_local_paths_set_updates_existing() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_local_paths

    local lp="$tmpdir/local-paths.yml"
    _local_paths_set "$lp" "repos" "backend-api" "~/old-path"
    _local_paths_set "$lp" "repos" "backend-api" "~/new-path"

    local result
    result=$(_local_paths_get "$lp" "repos" "backend-api")
    assert_equals "~/new-path" "$result" "Should update existing entry"
}

test_local_paths_set_appends_to_section() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_local_paths

    local lp="$tmpdir/local-paths.yml"
    _local_paths_set "$lp" "repos" "backend-api" "~/be"
    _local_paths_set "$lp" "repos" "frontend-app" "~/fe"

    local result1 result2
    result1=$(_local_paths_get "$lp" "repos" "backend-api")
    result2=$(_local_paths_get "$lp" "repos" "frontend-app")
    assert_equals "~/be" "$result1" "First entry should persist"
    assert_equals "~/fe" "$result2" "Second entry should be appended"
}

test_local_paths_multiple_sections() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_local_paths

    local lp="$tmpdir/local-paths.yml"
    _local_paths_set "$lp" "repos" "backend-api" "~/be"
    _local_paths_set "$lp" "extra_mounts" "/workspace/docs" "~/docs"

    local r1 r2
    r1=$(_local_paths_get "$lp" "repos" "backend-api")
    r2=$(_local_paths_get "$lp" "extra_mounts" "/workspace/docs")
    assert_equals "~/be" "$r1" "Repos section"
    assert_equals "~/docs" "$r2" "Extra mounts section"
}

# ── _get_repo_url ───────────────────────────────────────────────────

test_get_repo_url_extracts_url_by_name() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_local_paths

    cat > "$tmpdir/project.yml" <<'YAML'
name: test-project
repos:
  - path: "@local"
    name: api
    url: git@github.com:acme/api.git
  - path: "@local"
    name: web
    url: git@github.com:acme/web.git
YAML

    local result
    result=$(_get_repo_url "$tmpdir/project.yml" "api")
    assert_equals "git@github.com:acme/api.git" "$result" "Should extract api URL"

    result=$(_get_repo_url "$tmpdir/project.yml" "web")
    assert_equals "git@github.com:acme/web.git" "$result" "Should extract web URL"
}

test_get_repo_url_returns_empty_when_no_url() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_local_paths

    cat > "$tmpdir/project.yml" <<'YAML'
name: test-project
repos:
  - path: "@local"
    name: api
YAML

    local result
    result=$(_get_repo_url "$tmpdir/project.yml" "api")
    assert_empty "$result" "Should return empty when no url: field"
}

test_get_repo_url_returns_empty_for_nonexistent_repo() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_local_paths

    cat > "$tmpdir/project.yml" <<'YAML'
name: test-project
repos:
  - path: "@local"
    name: api
    url: git@github.com:acme/api.git
YAML

    local result
    result=$(_get_repo_url "$tmpdir/project.yml" "nonexistent")
    assert_empty "$result" "Should return empty for non-existent repo"
}

# ── _update_yml_path ────────────────────────────────────────────────

test_update_yml_path_updates_repo_path() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_local_paths

    cat > "$tmpdir/project.yml" <<'YAML'
name: test-project
repos:
  - path: "@local"
    name: api
  - path: "@local"
    name: web
YAML

    _update_yml_path "$tmpdir/project.yml" "repos" "name" "api" "path" "~/Projects/api"

    assert_file_contains "$tmpdir/project.yml" 'path: "~/Projects/api"'
    # web should remain @local
    local at_local_count
    at_local_count=$(grep -c '@local' "$tmpdir/project.yml" || true)
    [[ "$at_local_count" -eq 1 ]] || fail "Expected 1 @local remaining, got $at_local_count"
}

test_update_yml_path_updates_mount_source() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_local_paths

    cat > "$tmpdir/project.yml" <<'YAML'
name: test-project
extra_mounts:
  - source: "@local"
    target: /workspace/docs
    readonly: true
  - source: "@local"
    target: /workspace/specs
YAML

    _update_yml_path "$tmpdir/project.yml" "extra_mounts" "target" "/workspace/docs" "source" "~/my-docs"

    assert_file_contains "$tmpdir/project.yml" 'source: "~/my-docs"'
    # /workspace/specs should remain @local
    local at_local_count
    at_local_count=$(grep -c '@local' "$tmpdir/project.yml" || true)
    [[ "$at_local_count" -eq 1 ]] || fail "Expected 1 @local remaining, got $at_local_count"
}

# ── Schema bridge — NEW (index-backed) resolution (Commit A) ─────────
#
# The decentralized schema carries logical names only; absolute paths live in
# the STATE index. These tests cover the new branch of the schema bridge that
# coexists (transitionally) with the legacy @local/local-paths.yml path above.

_source_local_paths_index() {
    export CCO_ALLOW_HOST_RESOLVE=1
    export CCO_STATE_HOME="$1"
    unset XDG_STATE_HOME
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/yaml.sh"
    source "$REPO_ROOT/lib/index.sh"
    source "$REPO_ROOT/lib/local-paths.sh"
}

test_effective_repo_mounts_new_schema_reads_index() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_local_paths_index "$tmpdir/state"

    local repo_dir="$tmpdir/dev/repo1"; mkdir -p "$repo_dir"
    _index_set_path "repo1" "$repo_dir"

    local proj="$tmpdir/proj"; mkdir -p "$proj"
    cat > "$proj/project.yml" <<'YAML'
name: demo
repos:
  - name: repo1
    url: git@example.com:org/repo1.git
YAML

    local out; out=$(_effective_repo_mounts "$proj/project.yml")
    assert_equals "repo1"$'\t'"$repo_dir" "$out" "new-schema repo should resolve via index"
}

test_effective_repo_mounts_legacy_schema_passthrough() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_local_paths_index "$tmpdir/state"

    local proj="$tmpdir/proj"; mkdir -p "$proj"
    cat > "$proj/project.yml" <<'YAML'
name: demo
repos:
  - path: /tmp/legacy-repo
    name: legacy
YAML

    local out; out=$(_effective_repo_mounts "$proj/project.yml")
    assert_equals "legacy"$'\t'"/tmp/legacy-repo" "$out" "legacy repo should pass through unchanged"
}

test_effective_extra_mounts_new_schema_target_default_and_ro() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_local_paths_index "$tmpdir/state"

    local asset="$tmpdir/assets"; mkdir -p "$asset"
    _index_set_path "shared-assets" "$asset"

    local proj="$tmpdir/proj"; mkdir -p "$proj"
    cat > "$proj/project.yml" <<'YAML'
name: demo
extra_mounts:
  - name: shared-assets
YAML

    # No target → default /workspace/<name>; no readonly → default true.
    local out; out=$(_effective_extra_mounts "$proj/project.yml")
    assert_equals "$asset"$'\t'"/workspace/shared-assets"$'\t'"true" "$out" "mount defaults wrong"
}

test_effective_extra_mounts_new_schema_explicit_target_rw() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_local_paths_index "$tmpdir/state"

    local asset="$tmpdir/assets"; mkdir -p "$asset"
    _index_set_path "assets" "$asset"

    local proj="$tmpdir/proj"; mkdir -p "$proj"
    cat > "$proj/project.yml" <<'YAML'
name: demo
extra_mounts:
  - name: assets
    target: /workspace/custom
    readonly: false
YAML

    local out; out=$(_effective_extra_mounts "$proj/project.yml")
    assert_equals "$asset"$'\t'"/workspace/custom"$'\t'"false" "$out" "explicit target/ro not honored"
}

test_project_effective_paths_new_schema_status() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_local_paths_index "$tmpdir/state"

    local repo_dir="$tmpdir/dev/repo1"; mkdir -p "$repo_dir"
    _index_set_path "repo1" "$repo_dir"
    # repo2 deliberately unseeded → unresolved.

    local proj="$tmpdir/proj"; mkdir -p "$proj"
    cat > "$proj/project.yml" <<'YAML'
name: demo
repos:
  - name: repo1
  - name: repo2
YAML

    local out; out=$(_project_effective_paths "$proj")
    grep -qE $'^repos\trepo1\t'"$repo_dir"$'\texists$' <<< "$out" \
        || fail "repo1 should be exists; got: $out"
    grep -qE $'^repos\trepo2\t\tunresolved$' <<< "$out" \
        || fail "repo2 should be unresolved; got: $out"
}

test_resolve_entry_index_returns_existing_without_prompt() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_local_paths_index "$tmpdir/state"

    local repo_dir="$tmpdir/dev/repo1"; mkdir -p "$repo_dir"
    _index_set_path "repo1" "$repo_dir"

    local proj="$tmpdir/proj"; mkdir -p "$proj"
    # Already resolved + existing → returns it, rc 0, no prompt (safe non-TTY).
    local got rc=0
    got=$(_resolve_entry_index "$proj" "repos" "repo1" "") || rc=$?
    assert_equals 0 "$rc" "should succeed for already-resolved entry"
    assert_equals "$repo_dir" "$got" "should return the index path"
}
