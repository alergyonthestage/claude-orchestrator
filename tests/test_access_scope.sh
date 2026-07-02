#!/usr/bin/env bash
# tests/test_access_scope.sh — unified CLI environment & access-scope layer
# (ADR-0043, workstream B2 step 4.5).
#
# Two dimensions are exercised:
#   1. Layer unit tests — the scope logic in lib/access-scope.sh in isolation:
#      the host-open invariant (INV-A), the project|global taxonomy, membership
#      via PROJECT_NAME / CCO_PROJECT_PACKS / CCO_PROJECT_LLMS, and the count-only
#      hidden notice (INV-B/C, idempotent).
#   2. Wired-verb integration — bin/cco driven in container-operator mode against
#      a populated store, asserting read-verb OUTPUT is scoped (other projects,
#      unreferenced packs, and non-referenced llms hidden at read-project; all
#      visible at read-global; everything visible on the host), plus graceful
#      `show` degradation (_env_require_visible) instead of a raw fs error.

# Source the layer (+ its deps) into the current test subshell.
_as_source() {
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/access-scope.sh"
}

# Engage container-operator mode with absolute bucket overrides (mirrors what
# `cco start` sets); $1 = cco_access level.
_as_operator() {
    export CCO_CONTAINER_OPERATOR=1 CCO_CCO_ACCESS="$1" \
           CCO_DATA_HOME=/x CCO_STATE_HOME=/y CCO_CACHE_HOME=/z
}

# ── 1. Layer unit tests ───────────────────────────────────────────────

test_as_host_open_invariant() {
    # INV-A: on the host every resource is visible, whatever the kind.
    _as_source
    unset CCO_CONTAINER_OPERATOR
    export PROJECT_NAME=alpha
    [[ "$(_env_context)" == "host" ]] || fail "expected host context"
    [[ "$(_env_access)" == "unrestricted" ]] || fail "host access should be unrestricted"
    local k
    for k in project pack llms template remote; do
        _env_in_scope "$k" anything || fail "host must show $k (INV-A)"
    done
    return 0
}

test_as_scope_class_taxonomy() {
    _as_source
    [[ "$(_env_scope_class project)"  == "project" ]] || fail "project → project class"
    [[ "$(_env_scope_class pack)"     == "project" ]] || fail "pack → project class"
    [[ "$(_env_scope_class llms)"     == "project" ]] || fail "llms → project class"
    [[ "$(_env_scope_class template)" == "global"  ]] || fail "template → global class"
    [[ "$(_env_scope_class remote)"   == "global"  ]] || fail "remote → global class"
    [[ "$(_env_scope_class bogus)"    == "project" ]] || fail "unknown kind defaults to project (default-deny)"
    return 0
}

test_as_read_project_scopes_by_membership() {
    _as_source
    _as_operator read-project
    export PROJECT_NAME=alpha CCO_PROJECT_PACKS=p1,p2 CCO_PROJECT_LLMS=svelte
    [[ "$(_env_context)" == "operator" ]] || fail "expected operator context"
    # project: only the current one
    _env_in_scope project alpha || fail "current project must be visible"
    _env_in_scope project beta  && fail "other project must be hidden"
    # pack: only referenced
    _env_in_scope pack p1 || fail "referenced pack p1 must be visible"
    _env_in_scope pack p9 && fail "unreferenced pack p9 must be hidden"
    # llms: only referenced
    _env_in_scope llms svelte || fail "referenced llms must be visible"
    _env_in_scope llms react  && fail "unreferenced llms must be hidden"
    # global-class kinds: hidden entirely at read-project
    _env_in_scope template base   && fail "template must be hidden at read-project"
    _env_in_scope remote  origin  && fail "remote must be hidden at read-project"
    return 0
}

test_as_read_global_shows_everything() {
    _as_source
    _as_operator read-global
    export PROJECT_NAME=alpha
    local k
    for k in project pack llms template remote; do
        _env_in_scope "$k" whatever || fail "read-global must show $k"
    done
    # edit levels read everything too.
    _as_operator edit-project
    _env_in_scope template base || fail "edit-project must show global-class kinds (reads all)"
    return 0
}

test_as_hidden_notice_counts_and_stderr() {
    # INV-B/C: one count-only notice on stderr; llms is not pluralized.
    _as_source
    _as_operator read-project
    export PROJECT_NAME=alpha
    _env_note_hidden project
    _env_note_hidden llms; _env_note_hidden llms
    _env_note_hidden template
    local out; out=$(_env_flush_hidden_notice 2>&1)
    [[ "$out" == *"note:"* ]]        || fail "notice should start with 'note:', got: $out"
    [[ "$out" == *"1 project"* ]]    || fail "notice should count 1 project, got: $out"
    [[ "$out" == *"2 llms"* ]]       || fail "notice should count 2 llms (no double plural), got: $out"
    [[ "$out" != *"llmss"* ]]        || fail "llms must not be pluralized to 'llmss', got: $out"
    [[ "$out" == *"1 template"* ]]   || fail "notice should count 1 template, got: $out"
    [[ "$out" == *"read-global"* ]]  || fail "notice should say how to widen, got: $out"
    return 0
}

test_as_hidden_notice_idempotent() {
    _as_source
    _as_operator read-project
    _env_note_hidden pack
    _env_flush_hidden_notice 2>/dev/null
    local second; second=$(_env_flush_hidden_notice 2>&1)
    [[ -z "$second" ]] || fail "second flush must be a no-op, got: $second"
    return 0
}

test_as_notice_noop_when_nothing_hidden() {
    _as_source
    _as_operator read-project
    local out; out=$(_env_flush_hidden_notice 2>&1)
    [[ -z "$out" ]] || fail "flush with nothing hidden must be silent, got: $out"
    return 0
}

test_as_require_visible_degrades_gracefully() {
    _as_source
    _as_operator read-project
    export PROJECT_NAME=alpha CCO_PROJECT_PACKS=p1
    # In scope → returns 0, no output.
    ( _env_require_visible pack p1 ) || fail "in-scope pack must pass require_visible"
    # Out of scope (project-class) → dies with a scope message, not a raw error.
    local out rc
    out=$( _env_require_visible pack p9 2>&1 ); rc=$?
    [[ $rc -ne 0 ]] || fail "out-of-scope pack must be refused"
    [[ "$out" == *"not available at this access scope"* ]] \
        || fail "require_visible should explain the scope, got: $out"
    # Global-class message names the personal-global nature.
    out=$( _env_require_visible template base 2>&1 )
    [[ "$out" == *"personal-global"* ]] \
        || fail "global-class require_visible should mention personal-global, got: $out"
    return 0
}

# ── 2. Wired-verb integration (bin/cco in operator mode) ──────────────
# Populate a store on the host, then drive bin/cco with the operator env set so
# the SAME buckets are read behind the shim. setup_cco_env already exports
# absolute CCO_*_HOME (so operator mode engages) + the store dir overrides.

_as_seed_store() {
    local tmpdir="$1"
    setup_cco_env "$tmpdir"
    create_project "$tmpdir" "alpha" "$(minimal_project_yml alpha)"
    create_project "$tmpdir" "beta"  "$(minimal_project_yml beta)"
    create_pack "$tmpdir" "p1" "$(printf 'name: p1\nknowledge:\n  files: []\n')"
    create_pack "$tmpdir" "p2" "$(printf 'name: p2\nknowledge:\n  files: []\n')"
    mkdir -p "$CCO_LLMS_DIR/svelte" "$CCO_LLMS_DIR/react"
}

test_as_list_compact_scoped_at_read_project() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _as_seed_store "$tmpdir"
    export CCO_CONTAINER_OPERATOR=1 CCO_CCO_ACCESS=read-project \
           PROJECT_NAME=alpha CCO_PROJECT_PACKS=p1 CCO_PROJECT_LLMS=svelte
    run_cco list
    assert_output_contains "alpha"
    assert_output_contains "p1"
    assert_output_contains "svelte"
    assert_output_not_contains "beta"
    assert_output_not_contains "p2"
    assert_output_not_contains "react"
    assert_output_contains "hidden by access scope"
}

test_as_list_compact_full_at_read_global() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _as_seed_store "$tmpdir"
    export CCO_CONTAINER_OPERATOR=1 CCO_CCO_ACCESS=read-global PROJECT_NAME=alpha
    run_cco list
    assert_output_contains "alpha"
    assert_output_contains "beta"
    assert_output_contains "p2"
    assert_output_contains "react"
    assert_output_not_contains "hidden by access scope"
}

test_as_list_full_on_host() {
    # No operator flag → the layer never scopes (INV-A); everything shows.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _as_seed_store "$tmpdir"
    run_cco list
    assert_output_contains "alpha"
    assert_output_contains "beta"
    assert_output_contains "p2"
    assert_output_not_contains "hidden by access scope"
}

test_as_list_llms_scoped_at_read_project() {
    # llms lives in CACHE (mounted whole at every level) → the layer must scope
    # its OUTPUT; the shim allows `llms list` at read-project.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _as_seed_store "$tmpdir"
    export CCO_CONTAINER_OPERATOR=1 CCO_CCO_ACCESS=read-project \
           PROJECT_NAME=alpha CCO_PROJECT_LLMS=svelte
    run_cco list llms
    assert_output_contains "svelte"
    assert_output_not_contains "react"
    assert_output_contains "hidden by access scope"
}

test_as_llms_show_used_by_hides_out_of_scope_referrers() {
    # INV-B regression: `cco llms show <in-scope-llms>` must NOT leak the NAMES
    # of out-of-scope projects/packs that reference it (the "Used by:" line).
    # svelte is referenced by alpha (current → in scope) AND by beta (other
    # project → hidden) AND by p9 (unreferenced pack → hidden). The referrer
    # names beta/p9 must never appear; the filtering is announced count-only.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _as_seed_store "$tmpdir"
    printf 'name: beta\nllms:\n  - svelte\n' > "$(host_cco_dir "$tmpdir" beta)/project.yml"
    create_pack "$tmpdir" "p9" "$(printf 'name: p9\nllms:\n  - svelte\n')"
    export CCO_CONTAINER_OPERATOR=1 CCO_CCO_ACCESS=read-project \
           PROJECT_NAME=alpha CCO_PROJECT_LLMS=svelte CCO_PROJECT_PACKS=""
    run_cco llms show svelte || true
    assert_output_contains "svelte"
    assert_output_not_contains "beta"
    assert_output_not_contains "p9"
    assert_output_contains "hidden by access scope"
}

test_as_pack_show_out_of_scope_refused() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _as_seed_store "$tmpdir"
    export CCO_CONTAINER_OPERATOR=1 CCO_CCO_ACCESS=read-project \
           PROJECT_NAME=alpha CCO_PROJECT_PACKS=p1
    # p1 is in scope → shows.
    run_cco pack show p1 || true
    assert_output_contains "p1"
    # p2 is out of scope → refused with a scope message (not "not found at packs/").
    if run_cco pack show p2; then fail "out-of-scope 'pack show p2' should fail"; fi
    assert_output_contains "not available at this access scope"
}

test_as_project_show_out_of_scope_refused() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _as_seed_store "$tmpdir"
    export CCO_CONTAINER_OPERATOR=1 CCO_CCO_ACCESS=read-project PROJECT_NAME=alpha
    if run_cco project show beta; then fail "out-of-scope 'project show beta' should fail"; fi
    assert_output_contains "not available at this access scope"
}
