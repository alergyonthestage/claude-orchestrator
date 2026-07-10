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

test_as_read_global_vs_read_all_symmetry() {
    # ADR-0043 symmetric model: read-global shows all packs/llms/templates/remotes
    # but the `project` kind only the CURRENT project — other projects need
    # read-all (the SOLE global-vs-all difference).
    _as_source
    _as_operator read-global
    export PROJECT_NAME=alpha
    local k
    for k in pack llms template remote; do
        _env_in_scope "$k" whatever || fail "read-global must show global-store $k"
    done
    _env_in_scope project alpha || fail "read-global must show the current project"
    _env_in_scope project beta  && fail "read-global must HIDE other projects (needs read-all)"
    # read-all lifts the other-project restriction.
    _as_operator read-all
    export PROJECT_NAME=alpha
    _env_in_scope project beta || fail "read-all must show other projects"
    return 0
}

test_as_config_editor_target_is_current_not_other() {
    # F2 / ADR-0044 D9: in a config-editor session PROJECT_NAME is always
    # 'config-editor'; its edit targets are CCO_CONFIG_TARGETS. _env_in_scope must
    # treat a target as "current" (Pc), the SAME predicate B5 uses — otherwise a
    # config-editor edit-project (Po=none) session hides its own target from
    # `list project`/`project show`.
    _as_source
    _as_operator edit-project           # triple (none,rw,none): Pc=rw, Po=none
    export PROJECT_NAME=config-editor CCO_CONFIG_TARGETS=alpha
    _env_in_scope project alpha || fail "config-editor target must be visible (Pc), not hidden as an 'other' project"
    _env_in_scope project beta  && fail "a non-target project must stay hidden (Po=none)"
    # Owner-tagged project-class resource follows the same predicate.
    _env_in_scope tag t1 alpha || fail "a tag owned by the config-editor target must be visible (Pc)"
    _env_in_scope tag t2 beta  && fail "a tag owned by a non-target project must be hidden (Po=none)"
    return 0
}

test_as_edit_levels_read_at_matching_scope() {
    # D6: read/write symmetry — edit-project reads at PROJECT scope (mirrors
    # read-project, NOT "everything"); edit-global at global; edit-all at all.
    _as_source
    # edit-project: project-scoped → global-class hidden, other projects hidden.
    _as_operator edit-project
    export PROJECT_NAME=alpha CCO_PROJECT_PACKS=p1 CCO_PROJECT_LLMS=svelte
    _env_in_scope project alpha    || fail "edit-project must show the current project"
    _env_in_scope project beta     && fail "edit-project must HIDE other projects (project scope)"
    _env_in_scope template base    && fail "edit-project must HIDE templates (project scope)"
    _env_in_scope pack p1          || fail "edit-project must show a referenced pack"
    _env_in_scope pack p9          && fail "edit-project must hide an unreferenced pack"
    # edit-global: global-scoped → global-store visible, other projects hidden.
    _as_operator edit-global
    export PROJECT_NAME=alpha
    _env_in_scope template base    || fail "edit-global must show templates (global scope)"
    _env_in_scope project beta     && fail "edit-global must hide other projects (global scope)"
    # edit-all: everything.
    _as_operator edit-all
    export PROJECT_NAME=alpha
    _env_in_scope project beta     || fail "edit-all must show other projects (all scope)"
    _env_in_scope template base    || fail "edit-all must show templates (all scope)"
    return 0
}

test_as_level_scope_maps() {
    # The pure level→scope maps (single source, INV-E).
    _as_source
    [[ "$(_cco_level_read_scope read-project)"  == "project" ]] || fail "read-project → project read"
    [[ "$(_cco_level_read_scope edit-project)"  == "project" ]] || fail "edit-project → project read (symmetric)"
    [[ "$(_cco_level_read_scope read-global)"   == "global"  ]] || fail "read-global → global read"
    [[ "$(_cco_level_read_scope edit-global)"   == "global"  ]] || fail "edit-global → global read"
    [[ "$(_cco_level_read_scope read-all)"      == "all"     ]] || fail "read-all → all read"
    [[ "$(_cco_level_read_scope edit-all)"      == "all"     ]] || fail "edit-all → all read"
    [[ "$(_cco_level_read_scope read)"          == "all"     ]] || fail "bare read alias → all read"
    [[ "$(_cco_level_read_scope none)"          == "none"    ]] || fail "none → none read"
    [[ "$(_cco_level_write_scope read-global)"  == "none"    ]] || fail "read-* → no write"
    [[ "$(_cco_level_write_scope edit-project)" == "project" ]] || fail "edit-project → project write"
    [[ "$(_cco_level_write_scope edit-global)"  == "global"  ]] || fail "edit-global → global write"
    [[ "$(_cco_level_write_scope edit-all)"     == "all"     ]] || fail "edit-all → all write"
    # satisfies matrix: all grants everything; else exact match only.
    _cco_write_scope_satisfies all project     || fail "all satisfies project"
    _cco_write_scope_satisfies global global   || fail "global satisfies global"
    _cco_write_scope_satisfies global project  && fail "global must NOT satisfy project"
    _cco_write_scope_satisfies project global  && fail "project must NOT satisfy global"
    _cco_write_scope_satisfies none  global    && fail "none satisfies nothing"
    return 0
}

# ── (G,Pc,Po) triple model (ADR-0046) ────────────────────────────────

# Engage operator mode with an explicit triple (mirrors what `cco start` exports).
_as_triple() {
    export CCO_CONTAINER_OPERATOR=1 CCO_ACCESS_TRIPLE="$1" \
           CCO_DATA_HOME=/x CCO_STATE_HOME=/y CCO_CACHE_HOME=/z
    unset CCO_CCO_ACCESS
}

test_as_axis_rank() {
    _as_source
    [[ "$(_cco_axis_rank none)" == "0" ]] || fail "none → 0"
    [[ "$(_cco_axis_rank ro)"   == "1" ]] || fail "ro → 1"
    [[ "$(_cco_axis_rank rw)"   == "2" ]] || fail "rw → 2"
    [[ "$(_cco_axis_rank junk)" == "0" ]] || fail "unknown → 0 (default-deny)"
    return 0
}

test_as_preset_triples() {
    # ADR-0046 §3 symmetric ladder — each preset publishes its exact triple;
    # edit-global is REDEFINED to (rw,rw,none) (Pc gains rw).
    _as_source
    [[ "$(_cco_preset_triple none)"         == "none none none" ]] || fail "none"
    [[ "$(_cco_preset_triple read-project)" == "none ro none"   ]] || fail "read-project"
    [[ "$(_cco_preset_triple read-global)"  == "ro ro none"     ]] || fail "read-global"
    [[ "$(_cco_preset_triple read-all)"     == "ro ro ro"       ]] || fail "read-all"
    [[ "$(_cco_preset_triple edit-project)" == "none rw none"   ]] || fail "edit-project"
    [[ "$(_cco_preset_triple edit-global)"  == "rw rw none"     ]] || fail "edit-global gains Pc=rw"
    [[ "$(_cco_preset_triple edit-all)"     == "rw rw rw"       ]] || fail "edit-all"
    [[ "$(_cco_preset_triple read)"         == "ro ro ro"       ]] || fail "bare read → read-all triple"
    if _cco_preset_triple bogus >/dev/null; then fail "non-preset must return 1"; fi
    return 0
}

test_as_parse_granular() {
    _as_source
    # Order-free, partial, spaces tolerated. Unspecified → empty (pipe-delimited).
    [[ "$(_cco_parse_granular 'global=ro,current=rw,others=none')" == "ro|rw|none" ]] || fail "full triple"
    [[ "$(_cco_parse_granular 'others=rw, current=rw')"            == "|rw|rw"      ]] || fail "partial, order-free, spaces"
    [[ "$(_cco_parse_granular 'global=rw')"                        == "rw||"        ]] || fail "single axis"
    # A scalar (no '=') is not granular → rc 1.
    if _cco_parse_granular 'read-global' >/dev/null; then fail "scalar must return 1"; fi
    # Bad value / unknown key die.
    local rc=0; ( _cco_parse_granular 'current=maybe' ) >/dev/null 2>&1 || rc=$?
    [[ $rc -ne 0 ]] || fail "bad axis value must die"
    rc=0; ( _cco_parse_granular 'bogus=rw' ) >/dev/null 2>&1 || rc=$?
    [[ $rc -ne 0 ]] || fail "unknown key must die"
    return 0
}

test_as_promote_triple() {
    # ADR-0046 §2 auto-promotion of unspecified axes to the invariant floor.
    _as_source
    # others=rw (Pc,G empty) → Pc=rw (INV-4), G=none.
    [[ "$(_cco_promote_triple '' '' rw)"   == "none rw rw"   ]] || fail "others=rw promotes Pc=rw"
    # others=ro → Pc=ro (INV-2+INV-4), G=none.
    [[ "$(_cco_promote_triple '' '' ro)"   == "none ro ro"   ]] || fail "others=ro promotes Pc=ro"
    # nothing → read-project floor.
    [[ "$(_cco_promote_triple '' '' '')"   == "none ro none" ]] || fail "empty → read-project floor"
    # global=rw only → (rw, ro, none) — the off-ladder curate-global point.
    [[ "$(_cco_promote_triple rw '' '')"   == "rw ro none"   ]] || fail "global=rw → curate-global"
    # explicit case 6 & 7 pass unchanged.
    [[ "$(_cco_promote_triple none rw rw)" == "none rw rw"   ]] || fail "case 6 strict"
    [[ "$(_cco_promote_triple rw ro ro)"   == "rw ro ro"     ]] || fail "case 7"
    return 0
}

test_as_promote_triple_rejects_invariant_violations() {
    _as_source
    local out rc
    # INV-4: others cannot exceed current.
    rc=0; out=$( _cco_promote_triple none ro rw 2>&1 ) || rc=$?
    [[ $rc -ne 0 ]]           || fail "current=ro,others=rw must be rejected"
    [[ "$out" == *"INV-4"* ]] || fail "rejection should name INV-4, got: $out"
    # INV-2: explicit current=none while enabled.
    rc=0; out=$( _cco_promote_triple none none none 2>&1 ) || rc=$?
    [[ $rc -ne 0 ]]           || fail "explicit current=none must be rejected"
    [[ "$out" == *"INV-2"* ]] || fail "rejection should name INV-2, got: $out"
    return 0
}

test_as_resolve_access_scalar_and_granular() {
    _as_source
    # Scalar preset.
    [[ "$(_cco_resolve_access edit-global)" == "rw rw none" ]] || fail "scalar preset resolves"
    # Granular with auto-promotion.
    [[ "$(_cco_resolve_access 'others=rw')" == "none rw rw" ]] || fail "granular resolves + promotes"
    [[ "$(_cco_resolve_access 'global=rw,current=ro,others=ro')" == "rw ro ro" ]] || fail "case 7 granular"
    # Unknown scalar dies with the enum message.
    local out rc=0; out=$( _cco_resolve_access bogus 2>&1 ) || rc=$?
    [[ $rc -ne 0 ]]                    || fail "unknown scalar must die"
    [[ "$out" == *"Invalid cco_access"* ]] || fail "message should say Invalid cco_access, got: $out"
    return 0
}

test_as_triple_label_roundtrip() {
    _as_source
    [[ "$(_cco_triple_label none ro none)" == "read-project" ]] || fail "label read-project"
    [[ "$(_cco_triple_label rw rw none)"   == "edit-global"  ]] || fail "label edit-global"
    [[ "$(_cco_triple_label rw rw rw)"     == "edit-all"     ]] || fail "label edit-all"
    # Asymmetric (case 6/7) → granular label.
    [[ "$(_cco_triple_label none rw rw)"   == "global=none,current=rw,others=rw" ]] || fail "case 6 granular label"
    [[ "$(_cco_triple_label rw ro ro)"     == "global=rw,current=ro,others=ro"   ]] || fail "case 7 granular label"
    return 0
}

test_as_triple_write_satisfies() {
    # ADR-0046 §7 write-authority by target tree → axis.
    _as_source
    # edit-global = (rw,rw,none): writes project (Pc=rw) AND global (G=rw), not others.
    _cco_triple_write_satisfies rw rw none project || fail "edit-global writes project (Pc=rw)"
    _cco_triple_write_satisfies rw rw none global  || fail "edit-global writes global (G=rw)"
    _cco_triple_write_satisfies rw rw none all     && fail "edit-global must NOT write others (Po=none)"
    # edit-project = (none,rw,none): project only.
    _cco_triple_write_satisfies none rw none project || fail "edit-project writes project"
    _cco_triple_write_satisfies none rw none global  && fail "edit-project must NOT write global"
    # edit-all = (rw,rw,rw): everything.
    _cco_triple_write_satisfies rw rw rw all || fail "edit-all writes others"
    return 0
}

# Per-axis read-visibility the ordinal cannot express: case 6 (none,rw,rw) sees
# OTHER projects (Po=rw) yet HIDES unreferenced globals + templates (G=none).
test_as_case6_visibility_axis_independence() {
    _as_source
    _as_triple "none rw rw"
    export PROJECT_NAME=alpha CCO_PROJECT_PACKS=p1 CCO_PROJECT_LLMS=svelte
    _env_in_scope project alpha   || fail "case6: current project visible (Pc)"
    _env_in_scope project beta    || fail "case6: OTHER project visible (Po=rw)"
    _env_in_scope pack p1         || fail "case6: referenced pack visible (Pc)"
    _env_in_scope pack p9         && fail "case6: UNreferenced pack hidden (G=none)"
    _env_in_scope template base   && fail "case6: template hidden (G=none)"
    _env_in_scope remote origin   && fail "case6: remote hidden (G=none)"
    # _env_require_kind_visible must also honour G, not the 'all' ordinal.
    local rc=0; ( _env_require_kind_visible template ) >/dev/null 2>&1 || rc=$?
    [[ $rc -ne 0 ]] || fail "case6: list templates must be refused (G=none)"
    return 0
}

# Case 7 (rw,ro,ro): global store readable, other projects readable, but nothing
# writable — a read-consult-all-while-curating-global intent.
test_as_case7_visibility() {
    _as_source
    _as_triple "rw ro ro"
    export PROJECT_NAME=alpha
    _env_in_scope template base || fail "case7: template visible (G=ro)"
    _env_in_scope project beta  || fail "case7: other project visible (Po=ro)"
    _env_in_scope pack p9       || fail "case7: unreferenced pack visible (G=ro)"
    return 0
}

# The CCO_ACCESS_TRIPLE env is authoritative; a preset-only launch (CCO_CCO_ACCESS,
# no triple) derives the triple via the preset fallback.
test_as_triple_env_precedence_and_fallback() {
    _as_source
    # Preset fallback: edit-global (no triple) → (rw,rw,none).
    export CCO_CONTAINER_OPERATOR=1 CCO_DATA_HOME=/x CCO_STATE_HOME=/y CCO_CACHE_HOME=/z
    unset CCO_ACCESS_TRIPLE; export CCO_CCO_ACCESS=edit-global
    [[ "$(_env_triple)" == "rw rw none" ]] || fail "preset fallback edit-global → triple"
    [[ "$(_env_axis Pc)" == "rw" ]]        || fail "axis accessor Pc"
    # Explicit triple wins over any preset.
    export CCO_ACCESS_TRIPLE="none rw rw" CCO_CCO_ACCESS=read-project
    [[ "$(_env_triple)" == "none rw rw" ]] || fail "explicit triple authoritative"
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

test_as_list_compact_global_hides_other_projects() {
    # read-global: all packs/llms/templates visible, but OTHER projects hidden
    # (beta) with the count-only notice — the sole global-vs-all difference.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _as_seed_store "$tmpdir"
    export CCO_CONTAINER_OPERATOR=1 CCO_CCO_ACCESS=read-global PROJECT_NAME=alpha
    run_cco list
    assert_output_contains "alpha"
    assert_output_contains "p2"
    assert_output_contains "react"
    assert_output_not_contains "beta"
    assert_output_contains "hidden by access scope"
}

test_as_list_compact_full_at_read_all() {
    # read-all: everything, including other projects, no notice.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _as_seed_store "$tmpdir"
    export CCO_CONTAINER_OPERATOR=1 CCO_CCO_ACCESS=read-all PROJECT_NAME=alpha
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

test_as_list_template_refused_at_read_project() {
    # R3: the bare per-kind view must route through the scope layer. `template` is
    # global-class → wholly out of reach below read-global → refuse (exit 2), not a
    # leaked/empty list.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _as_seed_store "$tmpdir"
    export CCO_CONTAINER_OPERATOR=1 CCO_CCO_ACCESS=read-project PROJECT_NAME=alpha
    run_cco list template; local rc=$?
    [[ "$rc" -eq 2 ]] || fail "'cco list template' at read-project must refuse with exit 2, got $rc"
    assert_output_contains "personal-global"
}

test_as_list_pack_degrades_at_read_project() {
    # R3: `cco list pack` at read-project shows the referenced pack + notice
    # (graceful degrade, exit 0) — never the host-only "run cco init" error.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _as_seed_store "$tmpdir"
    export CCO_CONTAINER_OPERATOR=1 CCO_CCO_ACCESS=read-project \
           PROJECT_NAME=alpha CCO_PROJECT_PACKS=p1
    run_cco list pack; local rc=$?
    [[ "$rc" -eq 0 ]] || fail "degraded pack list must exit 0, got $rc"
    assert_output_contains "p1"
    assert_output_not_contains "p2"
    assert_output_not_contains "run 'cco init'"
    assert_output_contains "hidden by access scope"
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
