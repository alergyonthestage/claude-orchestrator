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
    _index_set_path demo "repo1" "$repo_dir"

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

test_effective_extra_mounts_new_schema_target_default_and_ro() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_local_paths_index "$tmpdir/state"

    local asset="$tmpdir/assets"; mkdir -p "$asset"
    _index_set_path demo "shared-assets" "$asset"

    local proj="$tmpdir/proj"; mkdir -p "$proj"
    cat > "$proj/project.yml" <<'YAML'
name: demo
extra_mounts:
  - name: shared-assets
YAML

    # No target → default /workspace/<name>; no readonly → default true; no
    # config_access_policy → default ro (4th field, ADR-0049 §7); no role — a
    # user-declared mount is never framework-roled, so the 5th field is empty
    # but PRESENT (the record is always 5 fields — RC-1 §3.3).
    local out; out=$(_effective_extra_mounts "$proj/project.yml")
    assert_equals "$asset"$'\t'"/workspace/shared-assets"$'\t'"true"$'\t'"ro"$'\t' "$out" "mount defaults wrong"
}

test_effective_extra_mounts_new_schema_explicit_target_rw() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_local_paths_index "$tmpdir/state"

    local asset="$tmpdir/assets"; mkdir -p "$asset"
    _index_set_path demo "assets" "$asset"

    local proj="$tmpdir/proj"; mkdir -p "$proj"
    cat > "$proj/project.yml" <<'YAML'
name: demo
extra_mounts:
  - name: assets
    target: /workspace/custom
    readonly: false
YAML

    local out; out=$(_effective_extra_mounts "$proj/project.yml")
    assert_equals "$asset"$'\t'"/workspace/custom"$'\t'"false"$'\t'"ro"$'\t' "$out" "explicit target/ro not honored"
}

# config_access_policy is parsed as the 4th field; project/write pass through,
# anything else (or absent) defaults to the strict `ro` (ADR-0049 §7).
test_effective_extra_mounts_config_access_policy() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_local_paths_index "$tmpdir/state"
    local asset="$tmpdir/assets"; mkdir -p "$asset"
    _index_set_path demo "assets" "$asset"
    local proj="$tmpdir/proj"; mkdir -p "$proj"
    local out
    # project policy honored.
    cat > "$proj/project.yml" <<'YAML'
name: demo
extra_mounts:
  - name: assets
    config_access_policy: project
YAML
    out=$(_effective_extra_mounts "$proj/project.yml")
    assert_equals "$asset"$'\t'"/workspace/assets"$'\t'"true"$'\t'"project"$'\t' "$out" "project policy not parsed"
    # write policy honored.
    cat > "$proj/project.yml" <<'YAML'
name: demo
extra_mounts:
  - name: assets
    config_access_policy: write
YAML
    out=$(_effective_extra_mounts "$proj/project.yml")
    assert_equals "$asset"$'\t'"/workspace/assets"$'\t'"true"$'\t'"write"$'\t' "$out" "write policy not parsed"
    # invalid → strict ro.
    cat > "$proj/project.yml" <<'YAML'
name: demo
extra_mounts:
  - name: assets
    config_access_policy: bogus
YAML
    out=$(_effective_extra_mounts "$proj/project.yml")
    assert_equals "$asset"$'\t'"/workspace/assets"$'\t'"true"$'\t'"ro"$'\t' "$out" "invalid policy must default to ro"
}

test_project_effective_paths_new_schema_status() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_local_paths_index "$tmpdir/state"

    local repo_dir="$tmpdir/dev/repo1"; mkdir -p "$repo_dir"
    _index_set_path demo "repo1" "$repo_dir"
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
    # No project.yml in $proj below → the resolver derives an empty project name,
    # so seed the global (unscoped) bucket which _index_get_path falls back to.
    _index_set_unscoped "repo1" "$repo_dir"

    local proj="$tmpdir/proj"; mkdir -p "$proj"
    # Already resolved + existing → returns it, rc 0, no prompt (safe non-TTY).
    local got rc=0
    got=$(_resolve_entry_index "$proj" "repos" "repo1" "") || rc=$?
    assert_equals 0 "$rc" "should succeed for already-resolved entry"
    assert_equals "$repo_dir" "$got" "should return the index path"
}

test_effective_extra_mounts_skips_non_absolute_index_value() {
    # B defense: a non-absolute index value (e.g. a stale legacy `@local`
    # marker) must NEVER reach the compose — its leading `@` is a reserved YAML
    # char that breaks `docker compose`. The bridge conscious-skips it.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_local_paths_index "$tmpdir/state"

    _index_set_path demo "badmount" "@local"       # bogus marker, not a path

    local proj="$tmpdir/proj"; mkdir -p "$proj"
    cat > "$proj/project.yml" <<'YAML'
name: demo
extra_mounts:
  - name: badmount
    target: /workspace/badmount
YAML

    local out; out=$(_effective_extra_mounts "$proj/project.yml")
    assert_equals "" "$out" "a non-absolute (@local) index value must be skipped, never emitted"
}

# ── RC-1 §3.3: the mount ROLE column ─────────────────────────────────
#
# `role` is the authoritative "framework-generated, and it exposes THIS config
# tree" signal, carried where the path already is (_CCO_MOUNT_OVERRIDE) rather
# than inferred from a `-config` name suffix a user mount can collide with.

# T13 — _effective_extra_mounts emits a 5-field record. Asserted through
# _peel_tab, the mandated consumer idiom: `IFS=$'\t' read` would fold the empty
# role of the user mount into the policy field and the test would still "pass".
test_effective_extra_mounts_emits_role_field() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_local_paths_index "$tmpdir/state"

    local store="$tmpdir/store"; mkdir -p "$store"
    local user="$tmpdir/assets"; mkdir -p "$user"
    _index_set_path demo "assets" "$user"
    # The store mount resolves through the session override (never the index),
    # which is where the role travels.
    _CCO_MOUNT_OVERRIDE=$(printf 'cco-config\t%s\tstore' "$store")

    local proj="$tmpdir/proj"; mkdir -p "$proj"
    cat > "$proj/project.yml" <<'YAML'
name: demo
extra_mounts:
  - name: cco-config
    target: /workspace/cco-config
    readonly: false
  - name: assets
YAML

    local out; out=$(_effective_extra_mounts "$proj/project.yml")
    local line src tgt ro pol role
    line=$(printf '%s\n' "$out" | grep -F "/workspace/cco-config")
    _peel_tab "$line" src tgt ro pol role
    assert_equals "$store" "$src" "override source"
    assert_equals "false" "$ro" "override readonly"
    assert_equals "ro" "$pol" "policy stays the strict default"
    assert_equals "store" "$role" "framework mount must carry its role"
    # A user-declared mount is never roled — the 5th field is present and empty.
    line=$(printf '%s\n' "$out" | grep -F "/workspace/assets")
    _peel_tab "$line" src tgt ro pol role
    assert_equals "$user" "$src" "index-resolved source"
    assert_equals "ro" "$pol" "user mount policy"
    assert_equals "" "$role" "a user extra_mount must never carry a role"
    unset _CCO_MOUNT_OVERRIDE
}

# T14 — _mount_override_get must peel THREE fields. Reading the line with
# `read -r oname opath` absorbs "path<TAB>role" into opath and every generated
# mount silently resolves to a path that does not exist.
test_mount_override_get_ignores_role_column() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_local_paths_index "$tmpdir/state"
    _CCO_MOUNT_OVERRIDE=$(printf 'cco-config\t/h/.cco\tstore\ncco-docs\t/h/docs\t\nmy-config\t/h/repo/.cco\tproject-config')

    assert_equals "/h/.cco" "$(_mount_override_get cco-config)" "role column leaked into the path"
    assert_equals "/h/docs" "$(_mount_override_get cco-docs)" "empty role column leaked into the path"
    assert_equals "/h/repo/.cco" "$(_mount_override_get my-config)" "role column leaked into the path"

    assert_equals "store" "$(_mount_override_role cco-config)" "store role"
    assert_equals "" "$(_mount_override_role cco-docs)" "cco-docs is deliberately role-less"
    assert_equals "project-config" "$(_mount_override_role my-config)" "target role"

    # An unknown name is not an empty role: both accessors return 1 so a caller
    # can tell "user mount" from "framework mount with no role".
    _mount_override_get ghost && fail "unknown name must not resolve"
    _mount_override_role ghost && fail "unknown name must not yield a role"
    unset _CCO_MOUNT_OVERRIDE
    return 0
}
