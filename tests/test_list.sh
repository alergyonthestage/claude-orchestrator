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

test_list_sort_tag_orders() {
    # --sort tag orders by the first tag; untagged sort last.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    _mk_pack "bravo"; _mk_pack "alpha-pack"; _mk_pack "charlie"
    run_cco tag add bravo      alpha   # first tag "alpha" → sorts first
    run_cco tag add alpha-pack zulu    # first tag "zulu"  → sorts after alpha
    # charlie carries no tag → sorts last
    run_cco list --sort tag
    local pb pa pc
    pb=$(printf '%s\n' "${CCO_OUTPUT:-}" | grep -n 'bravo'      | head -1 | cut -d: -f1)
    pa=$(printf '%s\n' "${CCO_OUTPUT:-}" | grep -n 'alpha-pack' | head -1 | cut -d: -f1)
    pc=$(printf '%s\n' "${CCO_OUTPUT:-}" | grep -n 'charlie'    | head -1 | cut -d: -f1)
    [[ -n "$pb" && -n "$pa" && -n "$pc" && "$pb" -lt "$pa" && "$pa" -lt "$pc" ]] \
        || fail "--sort tag order wrong (bravo@$pb alpha-pack@$pa charlie@$pc)"
}

test_list_reverse_inverts() {
    # --reverse flips the chosen order; -r is an accepted alias.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    _mk_pack "aaa"; _mk_pack "zzz"
    run_cco list --sort name --reverse
    local pa pz
    pz=$(printf '%s\n' "${CCO_OUTPUT:-}" | grep -n 'zzz' | head -1 | cut -d: -f1)
    pa=$(printf '%s\n' "${CCO_OUTPUT:-}" | grep -n 'aaa' | head -1 | cut -d: -f1)
    [[ -n "$pa" && -n "$pz" && "$pz" -lt "$pa" ]] \
        || fail "--sort name --reverse should order zzz before aaa (zzz@$pz aaa@$pa)"
    # -r alias routes to the compact index even without --sort.
    run_cco list -r
    assert_output_contains "KIND"
}

# B3: the compact index carries a dedicated STATUS column for the project kind
# (tri-state; other kinds show '-'). Seeded in both contexts: registry marker
# (in-container) + smart docker mock (host).
test_list_compact_status_column() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    local mock_bin="$tmpdir/bin"
    _mock_docker_with_project_session "$mock_bin" "svc"
    setup_mocks "$mock_bin"
    setup_cco_env "$tmpdir"
    create_project "$tmpdir" "svc" "$(minimal_project_yml svc)"
    _seed_running "svc"
    run_cco list
    assert_output_contains "STATUS"
    assert_output_contains "running"
}

# B3: --sort status orders running before stopped (then by name).
test_list_sort_status_orders() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    local mock_bin="$tmpdir/bin"
    _mock_docker_with_project_session "$mock_bin" "bb-run"
    setup_mocks "$mock_bin"
    setup_cco_env "$tmpdir"
    create_project "$tmpdir" "aa-stop" "$(minimal_project_yml aa-stop)"
    create_project "$tmpdir" "bb-run"  "$(minimal_project_yml bb-run)"
    _seed_running_dir          # both present-but-stopped by default in-container
    _seed_running "bb-run"     # bb-run marked running
    run_cco list --sort status
    local pr ps
    pr=$(printf '%s\n' "${CCO_OUTPUT:-}" | grep -n 'bb-run'  | head -1 | cut -d: -f1)
    ps=$(printf '%s\n' "${CCO_OUTPUT:-}" | grep -n 'aa-stop' | head -1 | cut -d: -f1)
    [[ -n "$pr" && -n "$ps" && "$pr" -lt "$ps" ]] \
        || fail "--sort status should order running (bb-run@$pr) before stopped (aa-stop@$ps)"
}

test_list_long_name_truncated() {
    # A name wider than the NAME column is ellipsized, never wrapped/shifted.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local longname="this-is-an-extremely-long-pack-name-well-beyond-the-cap"
    _mk_pack "$longname"
    run_cco list
    assert_output_contains "…"
    assert_output_not_contains "$longname"
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
