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

# Engage container-operator mode with a DIRECT (G,Pc,Po) triple (space-separated),
# for triples that have no named preset — e.g. case 6 `(none rw rw)` "edit every
# project but not the store". Mirrors a granular `--cco-access global=…,current=…,
# others=…` launch (CCO_ACCESS_TRIPLE is what `cco start` exports). $1 = "G Pc Po".
_as_triple() {
    export CCO_CONTAINER_OPERATOR=1 CCO_ACCESS_TRIPLE="${1// /,}" \
           CCO_DATA_HOME=/x CCO_STATE_HOME=/y CCO_CACHE_HOME=/z
    unset CCO_CCO_ACCESS
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
    [[ "$(_env_scope_class path)"     == "project" ]] || fail "path → project class (RC-4)"
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

test_as_hidden_notice_projects_only_leads_with_read_all() {
    # V4-F-V4-03 / Q-C3: OTHER projects ride Po, so only read-all reveals them
    # (read-global's SOLE difference from read-all is that projects stay hidden —
    # access-scope.sh:24). A notice that hid nothing but projects and then offers
    # read-global names a widening that reveals NONE of what it hid. When the hidden
    # set is projects-only the remedy must be read-all, and read-global must not
    # appear at all — an unreachable remedy is worse than no remedy.
    _as_source
    _as_operator read-project
    export PROJECT_NAME=alpha
    _env_note_hidden project; _env_note_hidden project
    local out; out=$(_env_flush_hidden_notice 2>&1)
    [[ "$out" == *"2 projects hidden by access scope"* ]] \
        || fail "the count/wording must be unchanged, got: $out"
    [[ "$out" == *"read-all"* ]] \
        || fail "a projects-only notice must offer read-all, got: $out"
    [[ "$out" != *"read-global"* ]] \
        || fail "a projects-only notice must NOT offer read-global (it reveals no project), got: $out"
    return 0
}

test_as_hidden_notice_mixed_still_names_both() {
    # The converse guard: as soon as a global-class kind is also hidden, read-global
    # IS a real widening for that part, so both must be named. This is what keeps the
    # fix an ordering/selection fix rather than a blanket substitution.
    _as_source
    _as_operator read-project
    export PROJECT_NAME=alpha
    _env_note_hidden project
    _env_note_hidden template
    local out; out=$(_env_flush_hidden_notice 2>&1)
    [[ "$out" == *"read-global"* ]] \
        || fail "a mixed notice must still offer read-global, got: $out"
    [[ "$out" == *"read-all"* ]] \
        || fail "a mixed notice must still name read-all for the projects, got: $out"
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

# ── The three availability states (RC-2 / D-M2, 04-host-path-class.md §6.2) ──

test_member_state_not_mounted() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _as_source
    _as_operator read-project
    export CCO_WORKDIR="$tmp/ws"; mkdir -p "$CCO_WORKDIR"
    # Index binding present, host path absent AND its mount absent → not-mounted.
    [[ "$(_env_member_state backend /host/absent/backend)" == "not-mounted" ]] \
        || fail "operator: a bound-but-unmounted member is 'not-mounted', not 'unresolved'"
    return 0
}

test_member_state_here_via_mount() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _as_source
    _as_operator read-project
    export CCO_WORKDIR="$tmp/ws"; mkdir -p "$CCO_WORKDIR/backend"
    [[ "$(_env_member_state backend /host/absent/backend)" == "here" ]] \
        || fail "operator: a member mounted at <ws>/<name> is 'here'"
    return 0
}

test_member_state_here_via_declared_target() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _as_source
    _as_operator read-project
    export CCO_WORKDIR="$tmp/ws"; mkdir -p "$CCO_WORKDIR/docs/specs"
    # INV-F.2: an explicit declared target is where the mount actually lives.
    [[ "$(_env_member_state assets /host/x "$CCO_WORKDIR/docs/specs")" == "here" ]] \
        || fail "operator: an explicit-target mount is 'here' at its target"
    return 0
}

test_member_state_unresolved_no_binding() {
    _as_source
    _as_operator read-project
    export CCO_WORKDIR=/ws
    # INV-F.1: an empty index path is 'unresolved' — never 'here', never 'not-mounted'.
    [[ "$(_env_member_state backend "")" == "unresolved" ]] \
        || fail "operator: an unbound member is 'unresolved'"
    return 0
}

test_member_state_host_two_valued() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _as_source
    unset CCO_CONTAINER_OPERATOR
    mkdir -p "$tmp/real"
    [[ "$(_env_member_state backend "$tmp/real")" == "here" ]] \
        || fail "host: an existing dir is 'here'"
    [[ "$(_env_member_state backend "$tmp/gone")" == "unresolved" ]] \
        || fail "host: a missing dir is 'unresolved'"
    [[ "$(_env_member_state backend "$tmp/gone")" != "not-mounted" ]] \
        || fail "host must never report 'not-mounted' (that state is operator-only)"
    return 0
}

test_project_state_out_of_scope() {
    _as_source
    source "$REPO_ROOT/lib/index.sh"; source "$REPO_ROOT/lib/cmd-resolve.sh"
    _as_operator read-project
    export PROJECT_NAME=alpha
    # At read-project (Po=none) another project is hidden → out-of-scope.
    [[ "$(_env_project_state beta)" == "out-of-scope" ]] \
        || fail "read-project: a non-current project is 'out-of-scope'"
    return 0
}

test_unmounted_notice_wording() {
    _as_source
    _as_operator read-project
    _env_note_unmounted project; _env_note_unmounted project
    local out; out=$(_env_flush_hidden_notice 2>&1)
    [[ "$out" == *"not mounted in this session"* ]] \
        || fail "the unmounted notice must say 'not mounted in this session', got: $out"
    [[ "$out" == *"2 projects"* ]] \
        || fail "the unmounted notice must count the members, got: $out"
    [[ "$out" != *"cco resolve"* ]] \
        || fail "the unmounted notice must NOT say 'cco resolve' — that is the lie this replaces, got: $out"
    return 0
}

test_unavailable_warn_matches_unavailable_wording() {
    _as_source
    _as_operator read-project
    # INV-E: the fatal and the degrade helpers render the SAME sentence per state.
    local sentence warn_out refuse_out
    for st in not-mounted unresolved; do
        sentence=$(_env_unavailable_sentence "$st" repo foo)
        warn_out=$(_env_unavailable_warn "$st" repo foo 2>&1) || true
        [[ "$warn_out" == *"$sentence"* ]] \
            || fail "_env_unavailable_warn $st must render the shared sentence, got: $warn_out"
        refuse_out=$( _env_unavailable "$st" repo foo 2>&1; true )
        [[ "$refuse_out" == *"$sentence"* ]] \
            || fail "_env_unavailable $st must render the shared sentence, got: $refuse_out"
    done
    return 0
}

test_hidden_notice_unchanged() {
    # Regression guard: with ONLY _env_note_hidden, the notice is byte-identical to
    # today (the unmounted block must never bleed into the hidden one).
    _as_source
    _as_operator read-project
    export PROJECT_NAME=alpha
    _env_note_hidden project
    local out; out=$(_env_flush_hidden_notice 2>&1)
    [[ "$out" == *"1 project hidden by access scope"* ]] \
        || fail "the hidden notice wording must be unchanged, got: $out"
    [[ "$out" != *"not mounted in this session"* ]] \
        || fail "a hidden-only flush must not emit the unmounted sentence, got: $out"
    return 0
}

# ── RC-4: path-kind owner attribution + the ratified Po axis (06 §6.3/§6.5) ──────

test_as_path_kind_owner_attribution() {
    # RC-4 (06 §6.3): the `path` kind scopes by the row's EFFECTIVE owner.
    _as_source
    # (a) fully-open triple + empty owner → visible (rides Po=ro).
    _as_triple "ro ro ro"
    _env_in_scope path orphan "" || fail "path/empty-owner must be visible at (ro,ro,ro) (Po=ro)"
    # (b) project-scoped: current owner visible (Pc), other + empty owner hidden (Po=none).
    _as_triple "none ro none"; export PROJECT_NAME=alpha
    _env_in_scope path r alpha   || fail "path owned by the current project must be visible (Pc)"
    _env_in_scope path r beta    && fail "path owned by another project must be hidden (Po=none)"
    _env_in_scope path orphan "" && fail "path with empty owner must be hidden below read-all (E2-02)"
    return 0
}

test_as_path_unattributable_rides_po_not_g() {
    # RC-4 AXIS PIN at the layer (06 §4.1 / §8 Q1, maintainer-ratified = Po): an
    # unattributable (empty-owner) path row rides Po, NOT G. A G-axis (A7)
    # implementation inverts all four legs.
    _as_source
    _as_triple "ro ro none"   # read-global: G=ro but Po=none → hidden
    _env_in_scope path x "" && fail "read-global (Po=none) must HIDE an empty-owner path row (not G=ro)"
    _as_triple "rw rw none"   # edit-global: G=rw but Po=none → hidden
    _env_in_scope path x "" && fail "edit-global (Po=none) must HIDE an empty-owner path row (not G=rw)"
    _as_triple "none rw rw"   # case 6: G=none but Po=rw → visible
    _env_in_scope path x "" || fail "case 6 (Po=rw) must SHOW an empty-owner path row (not G=none)"
    _as_triple "ro ro ro"     # read-all: Po=ro → visible
    _env_in_scope path x "" || fail "read-all (Po=ro) must SHOW an empty-owner path row"
    return 0
}

test_as_owner_in_scope_is_single_source() {
    # RC-4 (06 §6.3): _env_owner_in_scope "" is the SINGLE source, and _env_in_scope
    # path X "" IS exactly it, across triples. Asserted on the EMPTY-owner leg — the
    # non-empty leg is already identical today (project)/*) run the same Pc-else-Po
    # logic), so it would pass the moment the helper is defined even if `path)` were
    # never wired; the empty-owner form fails until `path)` actually delegates.
    _as_source
    local t owner_rc scope_rc po
    for t in "none ro none" "ro ro none" "none rw rw" "ro ro ro"; do
        _as_triple "$t"
        _env_owner_in_scope "";           owner_rc=$?
        _env_in_scope path anyname "";    scope_rc=$?
        [[ "$owner_rc" == "$scope_rc" ]] \
            || fail "at ($t): _env_in_scope path must EQUAL _env_owner_in_scope \"\" (single source), got owner=$owner_rc scope=$scope_rc"
        # …and that single source is exactly (Po >= ro).
        po="${t##* }"
        if [[ "$po" == "none" ]]; then
            [[ "$owner_rc" == "1" ]] || fail "at ($t): empty owner with Po=none must be hidden"
        else
            [[ "$owner_rc" == "0" ]] || fail "at ($t): empty owner with Po>=ro must be visible"
        fi
    done
    return 0
}

test_as_unknown_kind_stays_default_deny() {
    # RC-4 guard against A3: the `*)` net stays default-deny even fully open — the
    # new path)/project) permissiveness is opted into by NAMING a kind, never
    # inherited by an unregistered kind with an empty owner.
    _as_source
    _as_triple "ro ro ro"
    _env_in_scope bogus x "" && fail "an unknown kind with empty owner must stay hidden even at (ro,ro,ro)"
    return 0
}

test_as_path_claim_helper_attribution() {
    # RC-4 (06 §6.5 opt-1): _path_claimed_names is hermetically unit-testable via an
    # INJECTED manifest path. A declared name with NO project_paths entry is claimed
    # (its unscoped fallback is live); a SHADOWED name (own pp entry) is not; an
    # UNDECLARED name is not. Pins the anti-false-positive half of criterion B.
    _as_source
    source "$REPO_ROOT/lib/yaml.sh"; source "$REPO_ROOT/lib/index.sh"
    source "$REPO_ROOT/lib/cmd-resolve.sh"
    local tmp; tmp=$(mktemp -d)
    export CCO_STATE_HOME="$tmp/state" CCO_ALLOW_HOST_RESOLVE=1
    mkdir -p "$tmp/state"
    # Fixture manifest: project `demo` declares repo `dcode` + extra_mount `dmnt`.
    local yml="$tmp/project.yml"
    printf 'name: demo\nrepos:\n  - name: dcode\n    url: x\nextra_mounts:\n  - name: dmnt\n    url: y\n' > "$yml"
    # Shadow `dcode` with its own project_paths binding; leave `dmnt` unshadowed.
    ( unset CCO_CONTAINER_OPERATOR; _index_set_path demo dcode "$tmp/code" ) >/dev/null 2>&1
    local claimed
    claimed=$(printf 'demo\t%s\n' "$yml" | _path_claimed_names)
    [[ "$claimed" == *"dmnt"$'\t'"demo"* ]] \
        || fail "an unshadowed declared name (dmnt) must be claimed, got: $claimed"
    [[ "$claimed" != *"dcode"* ]] \
        || fail "a shadowed name (dcode, own project_paths binding) must NOT be claimed, got: $claimed"
    # Lookup helper: returns the claimer, else empty.
    [[ "$(_path_claim_lookup dmnt "$claimed")" == "demo" ]] \
        || fail "claim lookup must return the claiming project for a claimed name"
    [[ -z "$(_path_claim_lookup nope "$claimed")" ]] \
        || fail "claim lookup for an unclaimed name must be empty"
    rm -rf "$tmp"
    return 0
}

# ── ADR-0056 (S4): INV-AVAIL — one owner for availability answers ─────
# Each test below pins a CONTRACT the ADR states, not the implementation that
# happens to satisfy it. They are the regression half of the unit: every defect
# rerouted through lib/access-scope.sh gets a test that reproduces the old answer
# and then passes on the new one.

# D3 — the widening is a function of what is hidden. The builder is now ONE
# function; these pin its three rows directly, so a future caller that re-inlines
# the logic diverges from a tested contract rather than from an intention.
test_as_widening_builder_projects_only() {
    _as_source
    local w; w=$(_env_widening_clause 3 0)
    [[ "$w" == *"read-all"* ]] || fail "projects-only must offer read-all, got: $w"
    [[ "$w" != *"read-global"* ]] \
        || fail "projects-only must NOT name read-global — it reveals no project (ADR-0056 D3), got: $w"
    return 0
}

test_as_widening_builder_store_only() {
    _as_source
    local w; w=$(_env_widening_clause 0 2)
    [[ "$w" == *"read-global"* ]] || fail "store-kinds-only must offer read-global, got: $w"
    [[ "$w" != *"read-all"* ]] \
        || fail "store-kinds-only need not escalate to read-all (ADR-0056 D3), got: $w"
    return 0
}

test_as_widening_builder_mixed_names_both() {
    _as_source
    local w; w=$(_env_widening_clause 1 1)
    [[ "$w" == *"read-global"* && "$w" == *"read-all"* ]] \
        || fail "a mixed hidden set must name both (ADR-0056 D3), got: $w"
    return 0
}

# D3 — the two PER-RESOURCE sites must share the builder's ANSWER, not merely its
# intent. This is the defect all four review sessions found independently: both
# offered read-global for a project, the one level that keeps projects hidden.
test_as_require_visible_project_offers_read_all_not_read_global() {
    _as_source
    _as_operator read-project
    export PROJECT_NAME=alpha
    local out rc=0
    out=$( (_env_require_visible project beta) 2>&1 ) || rc=$?
    [[ "$rc" -eq 2 ]] || fail "a hidden resource is a policy refusal (exit 2), got rc=$rc"
    [[ "$out" == *"read-all"* ]] \
        || fail "a hidden PROJECT must be offered read-all (ADR-0056 D3), got: $out"
    [[ "$out" != *"read-global"* ]] \
        || fail "a hidden PROJECT must NOT be offered read-global — it reveals nothing, got: $out"
    return 0
}

test_as_unavailable_warn_project_offers_read_all_not_read_global() {
    _as_source
    _as_operator read-project
    export PROJECT_NAME=alpha
    local out; out=$(_env_unavailable_warn out-of-scope project beta 2>&1 || true)
    [[ "$out" == *"read-all"* ]] \
        || fail "the warn sibling must share the builder's answer (ADR-0056 D3), got: $out"
    [[ "$out" != *"read-global"* ]] \
        || fail "the warn sibling still offers read-global for a project, got: $out"
    return 0
}

test_as_require_visible_pack_still_offers_read_global() {
    # The counterweight: a store-resident kind rides G, so read-global IS its
    # widening. A fix that made everything say read-all would pass the tests above
    # and be equally wrong.
    _as_source
    _as_operator read-project
    export PROJECT_NAME=alpha CCO_PROJECT_PACKS=""
    local out; out=$( (_env_require_visible pack somepack) 2>&1 ) || true
    [[ "$out" == *"read-global"* ]] \
        || fail "a hidden PACK must be offered read-global (ADR-0046 §7: it rides G), got: $out"
    return 0
}

# D4 — the refusal must not disclose existence or location below read scope `all`.
test_as_require_visible_project_is_non_disclosing() {
    _as_source
    _as_operator read-project
    export PROJECT_NAME=alpha
    local out; out=$( (_env_require_visible project beta) 2>&1 ) || true
    [[ "$out" != *"outside this session's project"* ]] \
        || fail "D-V31-1: the refusal must not assert WHERE the resource is, got: $out"
    [[ "$out" != *"exists on this machine"* ]] \
        || fail "D-V31-1: the refusal must not assert THAT the resource exists, got: $out"
    [[ "$out" == *"not available at this access scope"* ]] \
        || fail "the shared vocabulary must be preserved, got: $out"
    return 0
}

# D4 — the `unknown` arm exists ONLY at read scope `all`.
test_as_project_state_unknown_only_at_read_all() {
    _as_source
    # A stub index with exactly one registered project, and a resolver that never
    # resolves — so the ONLY thing separating the two scopes is D4's gate.
    _index_list_projects() { printf 'alpha=/tmp/alpha\n'; }
    _resolve_project_yml() { return 1; }

    _as_operator read-all
    export PROJECT_NAME=alpha
    [[ "$(_env_project_state nosuch)" == "unknown" ]] \
        || fail "at read scope all an unregistered name must be 'unknown' (ADR-0056 D4), got: $(_env_project_state nosuch)"
    [[ "$(_env_project_state alpha)" == "not-mounted" ]] \
        || fail "a REGISTERED but unresolvable project stays not-mounted, got: $(_env_project_state alpha)"

    # Below `all` the arm must NOT materialise — A5 was rejected precisely because
    # it would turn this into an existence oracle across the scope boundary.
    _as_operator read-global
    export PROJECT_NAME=alpha
    [[ "$(_env_project_state alpha)" == "not-mounted" ]] \
        || fail "at read-global the unknown arm must not fire, got: $(_env_project_state alpha)"
    return 0
}

test_as_unknown_sentence_does_not_claim_existence() {
    _as_source
    _as_operator read-all
    local s; s=$(_env_unavailable_sentence unknown project nosuch)
    [[ "$s" != *"exists on this machine"* ]] \
        || fail "the unknown arm exists to STOP that claim (ADR-0056 D4), got: $s"
    [[ "$s" == *"not registered on this machine"* ]] \
        || fail "the unknown arm must name the real cause, got: $s"
    return 0
}

# D2 — a remedy is a function of the print site.
test_as_unresolved_remedy_is_host_qualified_in_session() {
    _as_source
    _as_operator read-project
    local s; s=$(_env_unavailable_sentence unresolved repo myrepo)
    [[ "$s" == *"cco resolve myrepo"* ]] || fail "the remedy must still name the verb, got: $s"
    [[ "$s" == *"on your host"* ]] \
        || fail "ADR-0056 D2: 'cco resolve' is host-only in a session, so the in-container sentence must say so, got: $s"
    return 0
}

test_as_unresolved_remedy_unqualified_on_host() {
    _as_source
    unset CCO_CONTAINER_OPERATOR CCO_CCO_ACCESS
    local s; s=$(_env_unavailable_sentence unresolved repo myrepo)
    [[ "$s" == *"cco resolve myrepo"* ]] || fail "host remedy must name the verb, got: $s"
    [[ "$s" != *"on your host"* ]] \
        || fail "on the HOST the qualifier is noise — D2 is about the print site, got: $s"
    return 0
}

# D5 — the hidden count comes from where enumeration is possible.
test_as_store_totals_supplement_counts_unenumerable_kinds() {
    # R-B: at G=none `~/.cco` is not mounted, so the pack loop never iterates —
    # zero rows, zero _env_note_hidden calls, and the notice was SILENT about packs
    # that certainly exist. The host-side signal supplies what the session cannot
    # enumerate. (The reports' "packs are not wired" diagnosis was wrong — they are;
    # the mount is absent. ADR-0056 D5 records the correction.)
    _as_source
    _as_operator read-project
    export PROJECT_NAME=alpha CCO_STORE_TOTALS="pack=4,template=2"
    # The verb declares what it enumerates exhaustively; only declared kinds are
    # supplemented (ratified 2026-07-30 — see test_as_store_subject_* below).
    _env_store_subject pack template
    # Nothing enumerated at all — the G=none shape.
    local out; out=$(_env_flush_hidden_notice 2>&1)
    [[ "$out" == *"hidden by access scope"* ]] \
        || fail "INV-B: an unenumerable hidden set must still produce the count notice, got: $out"
    [[ "$out" == *"4 packs"* ]] || fail "the pack count must come from the host signal, got: $out"
    [[ "$out" == *"2 templates"* ]] || fail "the template count must come from the host signal, got: $out"
    return 0
}

test_as_store_totals_subtract_what_was_enumerated() {
    # The read-project NARROWED mount: 2 of 4 packs are bound and visible, so the
    # hidden remainder is 2 — not 4 (double counting) and not 0 (the old silence).
    _as_source
    _as_operator read-project
    export PROJECT_NAME=alpha CCO_STORE_TOTALS="pack=4"
    _env_store_subject pack
    _env_note_seen pack; _env_note_seen pack
    local out; out=$(_env_flush_hidden_notice 2>&1)
    [[ "$out" == *"2 packs"* ]] \
        || fail "hidden = host_total - enumerated (ADR-0056 D5), got: $out"
    return 0
}

test_as_store_totals_silent_when_fully_enumerated() {
    _as_source
    _as_operator read-all
    export PROJECT_NAME=alpha CCO_STORE_TOTALS="pack=2"
    # The subject IS declared here on purpose: without it the output would be empty
    # for the wrong reason (no supplement at all) and this test would pass vacuously
    # while asserting nothing about the arithmetic it names.
    _env_store_subject pack
    _env_note_seen pack; _env_note_seen pack
    local out; out=$(_env_flush_hidden_notice 2>&1)
    [[ -z "$out" ]] \
        || fail "a fully enumerated store must produce NO hidden notice, got: $out"
    return 0
}

test_as_store_totals_ignored_on_host() {
    # INV-A: the host is never scoped, and it can always enumerate — a stray signal
    # must not make `cco list` on the host claim things are hidden.
    _as_source
    unset CCO_CONTAINER_OPERATOR CCO_CCO_ACCESS
    export CCO_STORE_TOTALS="pack=9"
    # Declared, so silence here proves the HOST guard and not the subject guard.
    _env_store_subject pack
    local out; out=$(_env_flush_hidden_notice 2>&1)
    [[ -z "$out" ]] || fail "INV-A: no scoping notice on the host, got: $out"
    return 0
}

test_as_store_totals_supplement_applied_once() {
    # _env_flush_hidden_notice is idempotent and several verbs call it on more than
    # one path; the supplement must not re-add itself and print a second notice.
    #
    # ⚠ BOTH flushes must run in ONE shell. Capturing each in its own $( ) would
    # sandbox the once-flag in a subshell and the test would pass vacuously —
    # measuring the capture, not the guard. Real callers flush in-process.
    _as_source
    _as_operator read-project
    export PROJECT_NAME=alpha CCO_STORE_TOTALS="pack=3"
    _env_store_subject pack
    local both
    both=$( { _env_flush_hidden_notice; printf -- '---MARK---\n' >&2; _env_flush_hidden_notice; } 2>&1 )
    [[ "${both%%---MARK---*}" == *"3 packs"* ]] \
        || fail "first flush must speak, got: $both"
    [[ "${both##*---MARK---}" != *"packs"* ]] \
        || fail "the supplement must be applied ONCE per invocation, got a second notice: $both"
    return 0
}

# D5 scoping (ratified 2026-07-30, after the post-build probe) — a notice speaks only
# about the kinds THIS invocation enumerates exhaustively.
test_as_store_subject_scopes_the_supplement() {
    # The shipped defect, at unit level: `cco list packs` enumerates packs and no llms,
    # so seen(llms)=0 and an unscoped supplement announced every llms on the machine as
    # hidden — while `cco list llms` in the same session shows them.
    _as_source
    _as_operator read-project
    export PROJECT_NAME=alpha CCO_STORE_TOTALS="pack=4,llms=3"
    _env_store_subject pack
    _env_note_seen pack
    local out; out=$(_env_flush_hidden_notice 2>&1)
    [[ "$out" == *"3 packs"* ]] \
        || fail "the declared kind must still be supplemented, got: $out"
    [[ "$out" != *"llms"* ]] \
        || fail "a kind this verb never enumerated must NOT be claimed hidden (the false clause the probe found), got: $out"
    return 0
}

test_as_store_subject_absent_means_no_supplement() {
    # Fail-safe default: not declaring yields silence, never a fabricated count. This
    # is the direction the shipped code had backwards.
    _as_source
    _as_operator read-project
    export PROJECT_NAME=alpha CCO_STORE_TOTALS="pack=4,llms=3"
    local out; out=$(_env_flush_hidden_notice 2>&1)
    [[ -z "$out" ]] \
        || fail "with no declared subject the supplement must stay silent, got: $out"
    return 0
}

test_as_store_subject_unified_list_speaks_for_every_kind() {
    # The other end: `cco list` with no kind DOES enumerate every store kind, so all of
    # them are legitimately supplemented. Without this arm, a lint-like fix that simply
    # dropped the supplement would also "pass" the two tests above.
    _as_source
    _as_operator read-project
    export PROJECT_NAME=alpha CCO_STORE_TOTALS="pack=4,llms=3"
    _env_store_subject pack template llms remote
    local out; out=$(_env_flush_hidden_notice 2>&1)
    [[ "$out" == *"4 packs"* && "$out" == *"3 llms"* ]] \
        || fail "the unified index must supplement every declared kind, got: $out"
    return 0
}

# D1 — the badge vocabulary belongs to the owner too.
test_as_state_badge_is_owned_and_retires_missing() {
    _as_source
    [[ "$(_env_state_badge here)" == "" ]] \
        || fail "a present member needs no badge, got: $(_env_state_badge here)"
    [[ "$(_env_state_badge not-mounted)" == "[not mounted in this session]" ]] \
        || fail "not-mounted badge drifted, got: $(_env_state_badge not-mounted)"
    [[ "$(_env_state_badge unresolved)" == "[unresolved]" ]] \
        || fail "unresolved badge drifted, got: $(_env_state_badge unresolved)"
    # ADR-0056 D7: `[missing]` was a fourth name for a state the classifier had
    # already named, and it is retired.
    local st
    for st in here not-mounted unresolved unknown out-of-scope; do
        [[ "$(_env_state_badge "$st")" != *"[missing]"* ]] \
            || fail "the retired [missing] badge came back for state '$st'"
    done
    return 0
}
