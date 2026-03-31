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

# ── _sanitize_project_paths ──────────────────────────────────────────

test_sanitize_replaces_repo_paths_with_at_local() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_local_paths

    cat > "$tmpdir/project.yml" <<'YAML'
name: test-project
repos:
  - path: ~/Projects/backend-api
    name: backend-api
  - path: ~/dev/frontend
    name: frontend
YAML

    _sanitize_project_paths "$tmpdir/project.yml"

    assert_file_contains "$tmpdir/project.yml" 'path: "@local"'
    assert_file_not_contains "$tmpdir/project.yml" "~/Projects/backend-api"
    assert_file_not_contains "$tmpdir/project.yml" "~/dev/frontend"
    assert_file_contains "$tmpdir/project.yml" "name: backend-api"
    assert_file_contains "$tmpdir/project.yml" "name: frontend"
}

test_sanitize_replaces_extra_mount_source_with_at_local() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_local_paths

    cat > "$tmpdir/project.yml" <<'YAML'
name: test-project
repos:
  - path: ~/Projects/api
    name: api
extra_mounts:
  - source: ~/documents/api-specs
    target: /workspace/docs/api-specs
    readonly: true
YAML

    _sanitize_project_paths "$tmpdir/project.yml"

    assert_file_contains "$tmpdir/project.yml" 'source: "@local"'
    assert_file_not_contains "$tmpdir/project.yml" "~/documents/api-specs"
    assert_file_contains "$tmpdir/project.yml" "target: /workspace/docs/api-specs"
}

test_sanitize_preserves_already_at_local() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_local_paths

    cat > "$tmpdir/project.yml" <<'YAML'
name: test-project
repos:
  - path: "@local"
    name: backend-api
YAML

    _sanitize_project_paths "$tmpdir/project.yml"

    # Should still have @local and name
    assert_file_contains "$tmpdir/project.yml" '"@local"'
    assert_file_contains "$tmpdir/project.yml" "name: backend-api"
}

# ── _resolve_project_paths ───────────────────────────────────────────

test_resolve_restores_paths_from_local_paths_yml() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_local_paths

    local proj="$tmpdir/project"
    mkdir -p "$proj/.cco"

    cat > "$proj/project.yml" <<'YAML'
name: test-project
repos:
  - path: "@local"
    name: backend-api
  - path: "@local"
    name: frontend
YAML

    cat > "$proj/.cco/local-paths.yml" <<'YAML'
repos:
  backend-api: ~/Projects/backend-api
  frontend: ~/dev/frontend
YAML

    _resolve_project_paths "$proj"

    assert_file_contains "$proj/project.yml" "path: ~/Projects/backend-api"
    assert_file_contains "$proj/project.yml" "path: ~/dev/frontend"
    assert_file_not_contains "$proj/project.yml" "@local"
}

test_resolve_leaves_at_local_if_not_in_local_paths() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_local_paths

    local proj="$tmpdir/project"
    mkdir -p "$proj/.cco"

    cat > "$proj/project.yml" <<'YAML'
name: test-project
repos:
  - path: "@local"
    name: backend-api
YAML

    # Empty local-paths.yml
    cat > "$proj/.cco/local-paths.yml" <<'YAML'
repos:
  other-repo: ~/other
YAML

    _resolve_project_paths "$proj"

    # backend-api should stay @local (not found in local-paths.yml)
    assert_file_contains "$proj/project.yml" "@local"
}

test_resolve_handles_extra_mounts() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_local_paths

    local proj="$tmpdir/project"
    mkdir -p "$proj/.cco"

    cat > "$proj/project.yml" <<'YAML'
name: test-project
repos:
  - path: "@local"
    name: api
extra_mounts:
  - source: "@local"
    target: /workspace/docs
    readonly: true
YAML

    cat > "$proj/.cco/local-paths.yml" <<'YAML'
repos:
  api: ~/Projects/api

extra_mounts:
  /workspace/docs: ~/documents/docs
YAML

    _resolve_project_paths "$proj"

    assert_file_contains "$proj/project.yml" "path: ~/Projects/api"
    assert_file_contains "$proj/project.yml" "source: ~/documents/docs"
    assert_file_not_contains "$proj/project.yml" "@local"
}

# ── Sanitize + Resolve roundtrip ─────────────────────────────────────

test_sanitize_resolve_roundtrip() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_local_paths

    local proj="$tmpdir/project"
    mkdir -p "$proj/.cco"

    cat > "$proj/project.yml" <<'YAML'
name: test-project
repos:
  - path: ~/Projects/backend-api
    name: backend-api
extra_mounts:
  - source: ~/docs/specs
    target: /workspace/docs
    readonly: true
YAML

    # Save original for comparison
    cp "$proj/project.yml" "$proj/project.yml.orig"

    # Write paths to local-paths.yml (like vault save does)
    _write_local_paths "$proj/project.yml" "$proj/.cco/local-paths.yml"

    # Sanitize
    _sanitize_project_paths "$proj/project.yml"

    # Verify sanitized
    assert_file_contains "$proj/project.yml" "@local"
    assert_file_not_contains "$proj/project.yml" "~/Projects/backend-api"

    # Resolve
    _resolve_project_paths "$proj"

    # Verify restored
    assert_file_contains "$proj/project.yml" "path: ~/Projects/backend-api"
    assert_file_contains "$proj/project.yml" "source: ~/docs/specs"
    assert_file_not_contains "$proj/project.yml" "@local"
}

# ── _extract_local_paths + _restore_local_paths ──────────────────────

test_extract_restore_vault_save_cycle() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_local_paths

    # Simulate vault structure
    local vault_dir="$tmpdir/vault"
    local proj="$vault_dir/projects/myapp"
    mkdir -p "$proj/.cco"

    cat > "$proj/project.yml" <<'YAML'
name: myapp
repos:
  - path: ~/Projects/myapp-api
    name: api
  - path: ~/dev/myapp-web
    name: web
YAML

    # Save original
    cp "$proj/project.yml" "$tmpdir/original.yml"

    # Extract (pre-commit)
    _extract_local_paths "$vault_dir"

    # Verify: project.yml sanitized
    assert_file_contains "$proj/project.yml" "@local"
    assert_file_not_contains "$proj/project.yml" "~/Projects/myapp-api"

    # Verify: backup created
    assert_file_exists "$proj/.cco/project.yml.pre-save"

    # Verify: local-paths.yml created
    assert_file_exists "$proj/.cco/local-paths.yml"
    assert_file_contains "$proj/.cco/local-paths.yml" 'api: "~/Projects/myapp-api"'
    assert_file_contains "$proj/.cco/local-paths.yml" 'web: "~/dev/myapp-web"'

    # Restore (post-commit)
    _restore_local_paths "$vault_dir"

    # Verify: project.yml restored to original
    assert_file_not_contains "$proj/project.yml" "@local"
    assert_file_contains "$proj/project.yml" "~/Projects/myapp-api"
    assert_file_contains "$proj/project.yml" "~/dev/myapp-web"

    # Verify: backup removed
    assert_file_not_exists "$proj/.cco/project.yml.pre-save"
}

test_extract_skips_already_at_local() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_local_paths

    local vault_dir="$tmpdir/vault"
    local proj="$vault_dir/projects/myapp"
    mkdir -p "$proj/.cco"

    cat > "$proj/project.yml" <<'YAML'
name: myapp
repos:
  - path: "@local"
    name: api
YAML

    _extract_local_paths "$vault_dir"

    # Should not create backup (nothing to sanitize)
    assert_file_not_exists "$proj/.cco/project.yml.pre-save"
}

test_extract_recovers_from_interrupted_save() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_local_paths

    local vault_dir="$tmpdir/vault"
    local proj="$vault_dir/projects/myapp"
    mkdir -p "$proj/.cco"

    # Simulate interrupted save: backup exists, project.yml is sanitized
    cat > "$proj/.cco/project.yml.pre-save" <<'YAML'
name: myapp
repos:
  - path: ~/real-path
    name: api
YAML

    cat > "$proj/project.yml" <<'YAML'
name: myapp
repos:
  - path: "@local"
    name: api
YAML

    # Extract should first restore from backup
    _extract_local_paths "$vault_dir" 2>/dev/null

    # After extract, the backup should be there (because real paths were extracted again)
    # and project.yml should be sanitized with the real path extracted
    assert_file_exists "$proj/.cco/local-paths.yml"
    assert_file_contains "$proj/.cco/local-paths.yml" 'api: "~/real-path"'
}

# ── _resolve_all_local_paths ─────────────────────────────────────────

test_resolve_all_processes_multiple_projects() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_local_paths

    local vault_dir="$tmpdir/vault"

    # Project 1
    local proj1="$vault_dir/projects/app1"
    mkdir -p "$proj1/.cco"
    cat > "$proj1/project.yml" <<'YAML'
name: app1
repos:
  - path: "@local"
    name: api
YAML
    cat > "$proj1/.cco/local-paths.yml" <<'YAML'
repos:
  api: ~/app1/api
YAML

    # Project 2
    local proj2="$vault_dir/projects/app2"
    mkdir -p "$proj2/.cco"
    cat > "$proj2/project.yml" <<'YAML'
name: app2
repos:
  - path: "@local"
    name: web
YAML
    cat > "$proj2/.cco/local-paths.yml" <<'YAML'
repos:
  web: ~/app2/web
YAML

    _resolve_all_local_paths "$vault_dir"

    assert_file_contains "$proj1/project.yml" "path: ~/app1/api"
    assert_file_contains "$proj2/project.yml" "path: ~/app2/web"
}

# ── Mixed real + @local paths ────────────────────────────────────────

test_sanitize_mixed_paths() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_local_paths

    cat > "$tmpdir/project.yml" <<'YAML'
name: test-project
repos:
  - path: "@local"
    name: already-remote
  - path: ~/Projects/local-repo
    name: local-repo
YAML

    _sanitize_project_paths "$tmpdir/project.yml"

    # already-remote should stay @local
    # local-repo should become @local
    assert_file_not_contains "$tmpdir/project.yml" "~/Projects/local-repo"
    assert_file_contains "$tmpdir/project.yml" "name: already-remote"
    assert_file_contains "$tmpdir/project.yml" "name: local-repo"

    # Count @local occurrences — should be 2
    local count
    count=$(grep -c '@local' "$tmpdir/project.yml" || true)
    [[ "$count" -eq 2 ]] || fail "Expected 2 @local markers, got $count"
}
