#!/usr/bin/env bash
# tests/test_index.sh — machine-local STATE index (T2: ADR-0016 D4 / 0022 D2)
#
# The index subsumes @local + per-repo local-paths.yml: logical name → absolute
# path (paths:) and project → member repos (projects:), in <state>/cco/index.

# Each test runs in its own subshell (bin/test) so these exports do not leak.
_index_test_env() {
    export CCO_ALLOW_HOST_RESOLVE=1
    export CCO_STATE_HOME="$1"
    unset XDG_STATE_HOME CCO_DATA_HOME CCO_CACHE_HOME
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/index.sh"
}

test_index_set_get_roundtrip() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"

    _index_set_path repo1 /Users/me/dev/repo1
    local got; got=$(_index_get_path repo1)
    [[ "$got" == "/Users/me/dev/repo1" ]] || fail "Roundtrip failed, got: $got"
}

test_index_upsert_overwrites() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"

    _index_set_path repo1 /a/first
    _index_set_path repo1 /a/second
    local got; got=$(_index_get_path repo1)
    [[ "$got" == "/a/second" ]] || fail "Upsert should overwrite, got: $got"
    # No duplicate line left behind.
    local n; n=$(_index_list_paths | grep -c '^repo1=')
    [[ "$n" -eq 1 ]] || fail "Expected exactly one repo1 entry, got: $n"
}

test_index_get_missing_empty() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"

    [[ -z "$(_index_get_path nonexistent)" ]] || fail "Missing key should be empty"
}

test_index_remove_path() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"

    _index_set_path repo1 /a/b
    _index_remove_path repo1
    [[ -z "$(_index_get_path repo1)" ]] || fail "Removed key should be empty"
}

test_index_multiple_paths_coexist() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"

    _index_set_path repo1 /a/one
    _index_set_path repo2 /a/two
    _index_set_path shared-assets /a/assets
    [[ "$(_index_get_path repo1)" == "/a/one" ]]        || fail "repo1 wrong"
    [[ "$(_index_get_path repo2)" == "/a/two" ]]        || fail "repo2 wrong"
    [[ "$(_index_get_path shared-assets)" == "/a/assets" ]] || fail "shared-assets wrong"
    local n; n=$(_index_list_paths | wc -l | tr -d ' ')
    [[ "$n" -eq 3 ]] || fail "Expected 3 entries, got: $n"
}

test_index_project_repos_roundtrip() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"

    _index_set_project_repos projectA repo1 repo2 repo3
    local got; got=$(_index_get_project_repos projectA)
    [[ "$got" == "repo1 repo2 repo3" ]] || fail "Project repos roundtrip, got: $got"
}

test_index_paths_and_projects_coexist() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"

    _index_set_path repo1 /a/one
    _index_set_project_repos projectA repo1 repo2
    # Both sections must remain independently readable.
    [[ "$(_index_get_path repo1)" == "/a/one" ]]              || fail "path lost after project set"
    [[ "$(_index_get_project_repos projectA)" == "repo1 repo2" ]] || fail "project lost"
    _index_set_path repo2 /a/two
    [[ "$(_index_get_project_repos projectA)" == "repo1 repo2" ]] || fail "project clobbered by path set"
}

test_index_path_conflicts() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"

    _index_set_path repo1 /a/one
    _index_path_conflicts repo1 /a/DIFFERENT || fail "Different path should conflict (AD5)"
    if _index_path_conflicts repo1 /a/one; then fail "Same path must not conflict"; fi
    if _index_path_conflicts brand-new /a/x;  then fail "Unbound name must not conflict"; fi
}

test_index_scaffold_has_version_and_sections() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"

    _index_set_path repo1 /a/b
    local f; f=$(_index_file)
    grep -q '^version: 1$' "$f"  || fail "Missing version header"
    grep -q '^paths:$' "$f"      || fail "Missing paths: section"
    grep -q '^projects:$' "$f"   || fail "Missing projects: section"
    # Atomic write leaves no mktemp ghosts behind.
    local ghosts; ghosts=$(find "$(dirname "$f")" -name 'index.??????' | wc -l | tr -d ' ')
    [[ "$ghosts" -eq 0 ]] || fail "Atomic write left $ghosts tempfile ghost(s)"
}

# ── Reverse lookup: repo → referencing projects (ADR-0024 D5) ────────

test_index_repos_get_projects_reverse() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    index_set_project_repos projA shared apionly
    index_set_project_repos projB shared
    local out
    out=$(
        source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/utils.sh"
        source "$REPO_ROOT/lib/paths.sh"; source "$REPO_ROOT/lib/index.sh"
        _index_repos_get_projects shared
    )
    printf '%s\n' "$out" | grep -qx projA || fail "projA should reference 'shared'"
    printf '%s\n' "$out" | grep -qx projB || fail "projB should reference 'shared'"
    # A repo referenced by only one project is not over-reported.
    local out2
    out2=$(
        source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/utils.sh"
        source "$REPO_ROOT/lib/paths.sh"; source "$REPO_ROOT/lib/index.sh"
        _index_repos_get_projects apionly
    )
    printf '%s\n' "$out2" | grep -qx projA || fail "projA should reference 'apionly'"
    printf '%s\n' "$out2" | grep -qx projB && fail "projB must not reference 'apionly'" || true
}
