#!/usr/bin/env bash
# tests/test_tag.sh — `cco tag` / `cco list` over the DATA tag registry
# (ADR-0010/0011/0015; P3-2a). Tags are internal, per-user, kind-typed
# (packs/projects/templates), auto-detected, and live in <data>/cco/tags.yml —
# never in pack.yml / project.yml / manifest / index.

# Create a pack/template directory under ~/.cco (config bucket) for kind detection.
_mk_pack()     { mkdir -p "$HOME/.cco/packs/$1"; }
_mk_template() { mkdir -p "$HOME/.cco/templates/$1"; }

test_tag_add_project_autodetect() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    create_project "$tmpdir" "proj-x" "$(minimal_project_yml proj-x)"
    run_cco tag add proj-x work
    assert_output_contains "tagged project 'proj-x' with 'work'"
    run_cco list --tag work
    assert_output_contains "proj-x"
}

test_tag_add_pack_autodetect() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    _mk_pack "my-api"
    run_cco tag add my-api infra
    assert_output_contains "tagged pack 'my-api'"
    run_cco list --tag infra
    assert_output_contains "my-api"
}

test_tag_add_template_autodetect() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    _mk_template "base-go"
    run_cco tag add base-go scaffold
    assert_output_contains "tagged template 'base-go'"
}

test_tag_remove() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    _mk_pack "my-api"
    run_cco tag add my-api work
    run_cco tag rm my-api work
    assert_output_contains "removed tag 'work'"
    run_cco list --tag work
    if echo "${CCO_OUTPUT:-}" | grep -qF "my-api"; then
        fail "my-api should no longer carry tag 'work' after rm"
    fi
}

test_tag_remove_canonical_verb() {
    # ADR-0029 D3: `cco tag remove` is the canonical verb; `rm` is an alias.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    _mk_pack "my-api"
    run_cco tag add my-api work
    run_cco tag remove my-api work
    assert_output_contains "removed tag 'work'"
    run_cco list --tag work
    if echo "${CCO_OUTPUT:-}" | grep -qF "my-api"; then
        fail "my-api should no longer carry tag 'work' after 'tag remove'"
    fi
}

test_tag_remove_rm_alias_still_works() {
    # The `rm` short alias keeps working alongside the canonical `remove`.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    _mk_pack "my-api"
    run_cco tag add my-api work
    run_cco tag rm my-api work
    assert_output_contains "removed tag 'work'"
}

test_tag_idempotent_no_duplicate() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    _mk_pack "my-api"
    run_cco tag add my-api work
    run_cco tag add my-api work
    # The registry line must carry exactly one 'work'.
    local f="$CCO_DATA_HOME/tags.yml"
    local n; n=$(grep -c "work" "$f" 2>/dev/null || echo 0)
    [[ "$n" -eq 1 ]] || fail "expected a single 'work' tag, found $n occurrence(s)"
}

test_tag_ambiguous_requires_flag() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    _mk_pack "shared"
    _mk_template "shared"
    if run_cco tag add shared work 2>/dev/null; then
        fail "ambiguous name should require a kind flag"
    fi
    assert_output_contains "ambiguous"
}

test_tag_forced_kind_disambiguates() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    _mk_pack "shared"
    _mk_template "shared"
    run_cco tag add shared work --pack
    assert_output_contains "tagged pack 'shared'"
    run_cco tag add shared other --template
    assert_output_contains "tagged template 'shared'"
}

test_tag_unknown_name_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    if run_cco tag add ghost work 2>/dev/null; then
        fail "tagging an unknown resource should fail"
    fi
    assert_output_contains "No pack, project, or template named 'ghost'"
}

test_list_shows_all_tagged() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    create_project "$tmpdir" "proj-x" "$(minimal_project_yml proj-x)"
    _mk_pack "my-api"
    run_cco tag add proj-x work
    run_cco tag add my-api infra
    run_cco list
    assert_output_contains "proj-x"
    assert_output_contains "my-api"
    assert_output_contains "work"
    assert_output_contains "infra"
}

test_tags_not_in_project_yml() {
    # ADR-0011/0015: a tag must NEVER leak into the committed project.yml.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    create_project "$tmpdir" "proj-x" "$(minimal_project_yml proj-x)"
    run_cco tag add proj-x secret-tag
    local host_yml; host_yml="$(host_cco_dir "$tmpdir" proj-x)/project.yml"
    if grep -qF "secret-tag" "$host_yml"; then
        fail "tag leaked into the committed project.yml"
    fi
}

# ── _tags_forget (lifecycle delete-cascade primitive; ADR-0021 Dec.2/4) ──────

test_tags_forget_removes_whole_entry() {
    # _tags_forget drops the ENTIRE <kind>/<name> entry — unlike _tags_remove,
    # which drops a single tag — and must not touch sibling entries (incl. names
    # that share a prefix).
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/tags.sh"

    _tags_set packs "my-api"    "work infra"
    _tags_set packs "my-api-v2" "infra"
    _tags_set projects "my-api" "prod"   # same name, different kind — must survive

    _tags_forget packs "my-api"

    [[ -z "$(_tags_get packs my-api)" ]]            || fail "packs/my-api entry should be gone"
    [[ "$(_tags_get packs my-api-v2)" == "infra" ]] || fail "prefix-sharing sibling packs/my-api-v2 must survive"
    [[ "$(_tags_get projects my-api)" == "prod" ]]  || fail "same-name-different-kind projects/my-api must survive"
    # Gone entirely, not merely emptied to "[]": no packs-section line survives.
    local n; n=$(awk '/^packs:/{p=1;next} p&&/^[^ #]/{p=0} p&&/^  my-api:/{c++} END{print c+0}' "$CCO_DATA_HOME/tags.yml")
    [[ "$n" -eq 0 ]] || fail "the packs/my-api line should be removed entirely, not emptied"
}

test_tags_forget_noop_when_absent() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/tags.sh"
    # No registry file yet — must not error.
    _tags_forget packs "never-existed" || fail "_tags_forget must be a no-op when the registry is absent"
}
