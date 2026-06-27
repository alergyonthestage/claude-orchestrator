#!/usr/bin/env bash
# tests/test_list.sh — the unified `cco list` resource index (ADR-0029 D1).
#
# `cco list` is the single listing surface: a compact cross-resource index
# (KIND · NAME · TAGS) by default, the detailed per-kind view for a bare
# `cco list <kind>`, and a sortable/filterable index whenever --tag/--sort is
# given. The per-noun `cco <noun> list` verbs were removed (redirect stubs).
# The compact path needs no global config (it enumerates the stores/index
# directly); only the detailed-routing test sets up a global.

_mk_pack() { mkdir -p "$HOME/.cco/packs/$1"; }

test_list_unified_shows_all_kinds() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    create_project "$tmpdir" "proj-x" "$(minimal_project_yml proj-x)"
    _mk_pack "my-api"
    run_cco list
    assert_output_contains "KIND"
    assert_output_contains "TAGS"
    assert_output_contains "proj-x"
    assert_output_contains "my-api"
    assert_output_contains "project"
    assert_output_contains "pack"
}

test_list_tag_column_shows_tags() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    _mk_pack "my-api"
    run_cco tag add my-api infra
    run_cco list
    assert_output_contains "my-api"
    assert_output_contains "infra"
}

test_list_sort_name_orders() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    create_project "$tmpdir" "zeta"  "$(minimal_project_yml zeta)"
    create_project "$tmpdir" "alpha" "$(minimal_project_yml alpha)"
    run_cco list --sort name
    assert_output_contains "alpha"
    assert_output_contains "zeta"
    local pa pz
    pa=$(printf '%s\n' "${CCO_OUTPUT:-}" | grep -n 'alpha' | head -1 | cut -d: -f1)
    pz=$(printf '%s\n' "${CCO_OUTPUT:-}" | grep -n 'zeta'  | head -1 | cut -d: -f1)
    [[ -n "$pa" && -n "$pz" && "$pa" -lt "$pz" ]] \
        || fail "--sort name should order alpha before zeta (alpha@$pa zeta@$pz)"
}

test_list_scoped_filter_tag() {
    # Scoped + filtered renders the compact index (no global needed).
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    _mk_pack "tagged-pack"
    _mk_pack "plain-pack"
    run_cco tag add tagged-pack keep
    run_cco list pack --tag keep
    assert_output_contains "tagged-pack"
    assert_output_not_contains "plain-pack"
}

test_list_kind_routes_to_detailed_view() {
    # A bare `cco list <kind>` shows the rich per-kind lister (here: pack's
    # resource-count columns), not the compact index.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    _mk_pack "my-api"
    run_cco list pack
    assert_output_contains "KNOWLEDGE"
    assert_output_contains "my-api"
}

test_list_removed_noun_verbs_redirect() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local n
    for n in project pack template llms remote; do
        run_cco "$n" list
        assert_output_contains "removed"
        assert_output_contains "cco list $n"
    done
}

test_list_unknown_kind_errors() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco list bogus
    assert_output_contains "Unknown resource kind"
}
