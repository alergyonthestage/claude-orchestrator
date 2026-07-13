#!/usr/bin/env bash
# tests/test_operator_shim.sh — wrapped-cco whitelist/blocklist shim
# (ADR-0036 D4, implementation step 4).
#
# The shim gates which cco verbs run in-container under container-operator mode.
# Blocked verbs die early with a "host-only" hint; read verbs pass at any level;
# write verbs pass only under an edit level (CCO_CCO_ACCESS ∈ edit-*). Tests drive
# `bin/cco` with the operator env set (absolute CCO_*_HOME + CCO_CONTAINER_OPERATOR)
# and assert on exit code + message — no Docker daemon required.

# Run bin/cco in container-operator mode. $1 = cco_access level; rest = argv.
# Buckets point at a throwaway dir so operator mode engages; the shim classifies
# BEFORE any bucket use for blocked verbs. Captures stdout+stderr into OP_OUT.
#
# CCO_STORE_ELEVATED=1 pins the run to the in-process gate path: it skips the
# Phase II setuid trampoline (bin/cco:438) so a store-touching verb is gated
# HERE, at the simulated CCO_CCO_ACCESS/CCO_ACCESS_TRIPLE, instead of being
# re-execed through the real cco-svc-helper — which, in a live boundary-enabled
# container, would override the simulated level with the session's trusted
# /etc/cco/session-access descriptor. On the host (no helper) it is a no-op (the
# trampoline guard is already false), so the suite behaves identically host and
# in-container. This isolates the GATE logic under test; the trampoline itself is
# covered by tests/test_privilege_boundary.sh.
_op_cco() {
    local level="$1"; shift
    local tmp; tmp=$(mktemp -d)
    OP_OUT=$(
        export CCO_IN_CONTAINER=1 CCO_CONTAINER_OPERATOR=1 CCO_CCO_ACCESS="$level" \
               CCO_STORE_ELEVATED=1 \
               CCO_DATA_HOME="$tmp/data" CCO_STATE_HOME="$tmp/state" CCO_CACHE_HOME="$tmp/cache" \
               HOME="$tmp/home"
        mkdir -p "$HOME"
        bash "$REPO_ROOT/bin/cco" "$@" 2>&1
    )
    OP_RC=$?
    rm -rf "$tmp"
    return 0
}

# Like _op_cco, but with a SEEDED throwaway store so store-touching gates can
# resolve real resources: projects `alpha` + `beta` (each its own member repo,
# create_project-style) and a pack `p1`. $1=cco_access level, $2=current
# PROJECT_NAME (may be `config-editor`), rest=argv. Honors two optional caller
# vars: OP_TARGETS → CCO_CONFIG_TARGETS (config-editor targets), OP_SHP →
# CCO_SHOW_HOST_PATHS (default true). Seeds via the real index API so the on-disk
# format matches production. Captures stdout+stderr → OP_OUT, exit → OP_RC.
_op_seed() {
    local level="$1" cur="$2"; shift 2
    local tmp; tmp=$(mktemp -d)
    mkdir -p "$tmp/home/.cco/packs/p1" "$tmp/state" "$tmp/data" "$tmp/cache" \
             "$tmp/repos/alpha" "$tmp/repos/beta"
    ( source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/utils.sh"
      source "$REPO_ROOT/lib/paths.sh";  source "$REPO_ROOT/lib/index.sh"
      # CCO_ALLOW_HOST_RESOLVE=1: seeding writes the index host-side; inside a
      # session container the anti-in-container guard (ADR-0007) otherwise refuses
      # index writes (mirrors setup_cco_env). No-op on the host.
      export CCO_STATE_HOME="$tmp/state" CCO_ALLOW_HOST_RESOLVE=1
      _index_set_path alpha "$tmp/repos/alpha"; _index_set_project_repos alpha alpha
      _index_set_path beta  "$tmp/repos/beta";  _index_set_project_repos beta  beta
    ) >/dev/null 2>&1
    OP_OUT=$(
        export CCO_IN_CONTAINER=1 CCO_CONTAINER_OPERATOR=1 CCO_STORE_ELEVATED=1 \
               CCO_CCO_ACCESS="$level" PROJECT_NAME="$cur" \
               CCO_CONFIG_TARGETS="${OP_TARGETS:-}" CCO_SHOW_HOST_PATHS="${OP_SHP:-true}" \
               CCO_DATA_HOME="$tmp/data" CCO_STATE_HOME="$tmp/state" CCO_CACHE_HOME="$tmp/cache" \
               HOME="$tmp/home"
        unset CCO_ACCESS_TRIPLE
        bash "$REPO_ROOT/bin/cco" "$@" 2>&1
    )
    OP_RC=$?
    rm -rf "$tmp"
    return 0
}

# ── Blocklist: host-only verbs die with a hint ───────────────────────

test_operator_blocks_container_spawning() {
    local v
    for v in start stop build new; do
        _op_cco read "$v" foo
        [[ $OP_RC -ne 0 ]] || fail "'cco $v' should be blocked in operator mode (rc=0)"
        [[ "$OP_OUT" == *"host-only"* ]] || fail "'cco $v' block should mention host-only, got: $OP_OUT"
    done
    return 0
}

test_operator_blocks_lifecycle_and_path_resolving() {
    local v
    for v in resolve sync init join forget update clean; do
        _op_cco edit-all "$v"
        [[ $OP_RC -ne 0 ]] || fail "'cco $v' should be blocked (rc=0)"
        [[ "$OP_OUT" == *"host-only"* ]] || fail "'cco $v' should mention host-only, got: $OP_OUT"
    done
    return 0
}

test_operator_blocks_config_push_pull_hostonly() {
    _op_cco edit-all config push
    [[ $OP_RC -ne 0 && "$OP_OUT" == *"host-only"* ]] \
        || fail "'config push' must be host-only, got rc=$OP_RC: $OP_OUT"
    _op_cco edit-all config pull
    [[ $OP_RC -ne 0 && "$OP_OUT" == *"host-only"* ]] \
        || fail "'config pull' must be host-only, got rc=$OP_RC: $OP_OUT"
    return 0
}

test_operator_blocks_remote_token_verbs() {
    _op_cco edit-all remote set-token acme tok
    [[ $OP_RC -ne 0 && "$OP_OUT" == *"host-only"* ]] \
        || fail "'remote set-token' must be host-only, got rc=$OP_RC: $OP_OUT"
    _op_cco edit-all remote remove-token acme
    [[ $OP_RC -ne 0 && "$OP_OUT" == *"host-only"* ]] \
        || fail "'remote remove-token' must be host-only, got rc=$OP_RC: $OP_OUT"
    return 0
}

test_operator_blocks_project_rename() {
    _op_cco edit-all project rename old new
    [[ $OP_RC -ne 0 && "$OP_OUT" == *"host-only"* ]] \
        || fail "'project rename' must be host-only, got rc=$OP_RC: $OP_OUT"
    return 0
}

# CLI-surface review F1: `config validate` sweeps machine-local index/state that
# is incoherent in a container (the mounted STATE index carries HOST paths that
# never resolve in-container → wholesale false orphans + host-path leak). It must
# be host-only at EVERY level, including the read-project default.
test_operator_blocks_config_validate_hostonly() {
    local lvl
    for lvl in read-project read-global read-all edit-all; do
        _op_cco "$lvl" config validate
        [[ $OP_RC -ne 0 && "$OP_OUT" == *"host-only"* ]] \
            || fail "'config validate' must be host-only at $lvl, got rc=$OP_RC: $OP_OUT"
    done
    return 0
}

# ── Write gating: write verbs need an edit level ─────────────────────

test_operator_read_level_refuses_writes() {
    # Write verbs targeting the global store/registry are refused at a read level
    # with the tree-aware message (R5) and the policy-refusal exit code 2 (D8).
    # (`tag` is now gated by the tagged resource's axis — B5 — and covered by the
    # dedicated per-target tests below, not this blanket-global case.)
    _op_cco read config save
    [[ $OP_RC -eq 2 && "$OP_OUT" == *"needs G=rw"* ]] \
        || fail "'config save' under read must be refused (exit 2, edit-global), got rc=$OP_RC: $OP_OUT"
    _op_cco read remote add acme https://x
    [[ $OP_RC -eq 2 && "$OP_OUT" == *"needs G=rw"* ]] \
        || fail "'remote add' under read must be refused (exit 2, edit-global), got rc=$OP_RC: $OP_OUT"
    return 0
}

# A write verb passes the SHIM under an edit level (it may fail later for other
# reasons, but never with the shim's block/refuse messages).
test_operator_edit_level_passes_writes_through_shim() {
    _op_cco edit-all tag add proj mytag
    [[ "$OP_OUT" != *"host-only"* && "$OP_OUT" != *"edit access level"* \
       && "$OP_OUT" != *"not available in a container session"* ]] \
        || fail "'tag add' under edit-all should pass the shim, got: $OP_OUT"
    return 0
}

# CLI-surface review F2: the STATE token store is never mounted in a container,
# so `remote add --token` would write the secret to an ephemeral container path
# while falsely reporting "[token saved]". The command must refuse the token half
# (mirroring host-only `remote set-token`) — before any partial write — while a
# plain `remote add` (no token) still registers the url at an edit level.
test_operator_remote_add_token_refused() {
    _op_cco edit-all remote add acme https://x --token ghp_secret
    [[ $OP_RC -ne 0 ]] \
        || fail "'remote add --token' must be refused in a container, got rc=$OP_RC: $OP_OUT"
    [[ "$OP_OUT" == *"set-token"* && "$OP_OUT" == *"host"* ]] \
        || fail "'remote add --token' refusal should point to host set-token, got: $OP_OUT"
    [[ "$OP_OUT" != *"token saved"* ]] \
        || fail "'remote add --token' must NOT claim the token was saved, got: $OP_OUT"
    # The plain form (no token) still passes at an edit level.
    _op_cco edit-all remote add acme https://x
    [[ "$OP_OUT" != *"host-only"* && "$OP_OUT" != *"cannot persist a token"* ]] \
        || fail "plain 'remote add' should pass the shim at edit-all, got: $OP_OUT"
    return 0
}

# R5 (symmetric write gate): the ~/.cco store is writable only at edit-global/
# edit-all; `config save` writes the global store → at edit-project (write_scope
# project) it is REFUSED at the shim gate (exit 2), before the ro filesystem,
# with the tree-aware "needs G=rw" message. At edit-all it passes the
# gate (may fail later for other reasons, but never with the gate message).
test_operator_config_save_edit_project_needs_edit_global() {
    _op_cco edit-project config save -m x
    [[ $OP_RC -eq 2 && "$OP_OUT" == *"needs G=rw"* ]] \
        || fail "'config save' at edit-project must be gate-refused (exit 2, edit-global), got rc=$OP_RC: $OP_OUT"
    _op_cco edit-all config save -m x
    [[ "$OP_OUT" != *"needs G=rw"* ]] \
        || fail "'config save' at edit-all should pass the write gate, got: $OP_OUT"
    return 0
}

# ── Read verbs pass at any operator level ────────────────────────────

test_operator_read_verbs_pass_shim() {
    local v
    for v in "list" "list remotes" "docs" "path list"; do
        # shellcheck disable=SC2086
        _op_cco read $v
        [[ "$OP_OUT" != *"host-only"* && "$OP_OUT" != *"not available in a container session"* ]] \
            || fail "'cco $v' should pass the shim under read, got: $OP_OUT"
    done
    return 0
}

# ── R6: the `none` contract — cco refused wholesale in-session ───────────────

test_none_session_refuses_cco() {
    # At cco_access=none, cco start injects CCO_SESSION_CONTEXT but NOT the operator
    # env. The early guard must refuse EVERY invocation (exit 2) with the none
    # message — not fall through to the host dispatcher.
    local tmp; tmp=$(mktemp -d)
    local out rc
    out=$(
        export CCO_IN_CONTAINER=1 CCO_SESSION_CONTEXT="eA==" HOME="$tmp/home"
        # Ensure NO operator env leaks in.
        unset CCO_CONTAINER_OPERATOR CCO_DATA_HOME CCO_STATE_HOME CCO_CACHE_HOME
        mkdir -p "$HOME"
        bash "$REPO_ROOT/bin/cco" list 2>&1
    ); rc=$?
    rm -rf "$tmp"
    [[ $rc -eq 2 ]] || fail "cco at none must refuse with exit 2, got rc=$rc: $out"
    [[ "$out" == *"cco_access=none"* ]] || fail "none refusal should name cco_access=none, got: $out"
    # A single clean refusal — no spurious ADR-0007 host-resolve warning.
    [[ "$out" != *"anti-in-container"* ]] || fail "none refusal must be clean (no ADR-0007 warning), got: $out"
    return 0
}

test_none_session_refuses_docs() {
    # `cco docs` is a cco verb → also refused at none (R6, consistent).
    local tmp; tmp=$(mktemp -d)
    local rc
    (
        export CCO_IN_CONTAINER=1 CCO_SESSION_CONTEXT="eA==" HOME="$tmp/home"
        unset CCO_CONTAINER_OPERATOR CCO_DATA_HOME CCO_STATE_HOME CCO_CACHE_HOME
        mkdir -p "$HOME"
        bash "$REPO_ROOT/bin/cco" docs >/dev/null 2>&1
    ); rc=$?
    rm -rf "$tmp"
    [[ $rc -eq 2 ]] || fail "cco docs at none must refuse with exit 2, got rc=$rc"
    return 0
}

# ── R9 refusal taxonomy: unknown / removed-alias / host-only --help ──────────

test_operator_unknown_verb_is_error() {
    # An unrecognized verb is a typo (exit 1 error), NOT a host-only refusal — this
    # removes the "run 'cco whoami' on the host" misfire.
    _op_cco read-all bogusverb
    [[ $OP_RC -eq 1 ]] || fail "unknown verb must exit 1 (error), got rc=$OP_RC: $OP_OUT"
    [[ "$OP_OUT" == *"Unknown cco command"* ]] || fail "unknown verb should say so, got: $OP_OUT"
    [[ "$OP_OUT" != *"host-only"* && "$OP_OUT" != *"on your host"* ]] \
        || fail "unknown verb must NOT be reported as host-only, got: $OP_OUT"
    return 0
}

test_operator_removed_alias_redirects() {
    # cco pack list / cco project list were removed (ADR-0029) → redirect to
    # 'cco list <kind>' with exit 2 (policy), from the shim (single wiring point).
    _op_cco read-all pack list
    [[ $OP_RC -eq 2 && "$OP_OUT" == *"use 'cco list pack'"* ]] \
        || fail "'pack list' should redirect (exit 2) to 'cco list pack', got rc=$OP_RC: $OP_OUT"
    _op_cco read-all project list
    [[ $OP_RC -eq 2 && "$OP_OUT" == *"use 'cco list project'"* ]] \
        || fail "'project list' should redirect (exit 2) to 'cco list project', got rc=$OP_RC: $OP_OUT"
    return 0
}

test_operator_hostonly_help_is_informational() {
    # D7: `<host-only-verb> --help` shows usage, never refuses (S3-6/F5).
    _op_cco read-all start --help
    [[ $OP_RC -eq 0 && "$OP_OUT" == *"Usage: cco start"* ]] \
        || fail "'cco start --help' should show usage (exit 0), got rc=$OP_RC: $OP_OUT"
    [[ "$OP_OUT" != *"host-only"* ]] \
        || fail "'cco start --help' must not refuse, got: $OP_OUT"
    return 0
}

# ── whoami: F4 session introspection — always available, never host-only ─────

test_operator_whoami_reports_state() {
    # `cco whoami` passes the shim at any read level (it is in the known-verb set)
    # and reports the resolved scopes + per-tree rw/ro from write_scope.
    _op_cco read-all whoami
    [[ $OP_RC -eq 0 ]] || fail "'cco whoami' must succeed at read-all, got rc=$OP_RC: $OP_OUT"
    [[ "$OP_OUT" != *"host-only"* && "$OP_OUT" != *"not available in a container session"* ]] \
        || fail "'cco whoami' must never be host-only-refused, got: $OP_OUT"
    # R2: read-all is a preset, so `level` names it (not the granular form) and the
    # `triple` line carries the read/write scope in the deduplicated `read:`/`write:` form.
    [[ "$OP_OUT" == *"level:"*"read-all"* ]] || fail "whoami should name preset read-all, got: $OP_OUT"
    [[ "$OP_OUT" == *"read: all"* ]] || fail "whoami should report read: all, got: $OP_OUT"
    # R1: identity-first Session block replaces the old single 'project' line.
    [[ "$OP_OUT" == *"Session"* && "$OP_OUT" == *"identity:"* ]] \
        || fail "whoami should render the identity-first Session block, got: $OP_OUT"
    # R2 dedup: the old redundant 'cco_access'/'granular form'/'access triple' labels are gone.
    [[ "$OP_OUT" != *"granular form:"* && "$OP_OUT" != *"access triple:"* ]] \
        || fail "whoami must not carry the pre-R2 duplicated access rows, got: $OP_OUT"
    # At edit-project the project tree is rw, the global store ro (symmetric model).
    _op_cco edit-project whoami
    [[ "$OP_OUT" == *"write: project"* ]] || fail "whoami edit-project write scope, got: $OP_OUT"
    [[ "$OP_OUT" == *"level:"*"edit-project"* ]] || fail "whoami should name preset edit-project, got: $OP_OUT"
    [[ "$OP_OUT" == *"project config (<repo>/.cco):        rw"* ]] \
        || fail "whoami edit-project must show project config rw, got: $OP_OUT"
    return 0
}

# R2: a config-editor-style ASYMMETRIC triple has no preset → `level: custom (…)`
# carries the granular form, and no row byte-duplicates another. cco start resolves
# the triple and exports CCO_ACCESS_TRIPLE (a granular CCO_CCO_ACCESS scalar is not
# parsed by _env_triple), so simulate the resolved config-editor project triple here.
test_operator_whoami_custom_triple_names_custom() {
    local tmp; tmp=$(mktemp -d); mkdir -p "$tmp/home"
    OP_OUT=$(
        export CCO_IN_CONTAINER=1 CCO_CONTAINER_OPERATOR=1 CCO_STORE_ELEVATED=1 \
               CCO_CCO_ACCESS="global=ro,current=rw,others=none" CCO_ACCESS_TRIPLE="ro,rw,none" \
               PROJECT_NAME=config-editor CCO_CONFIG_TARGETS="alpha" CCO_CLAUDE_ACCESS=repo \
               CCO_DATA_HOME="$tmp/data" CCO_STATE_HOME="$tmp/state" CCO_CACHE_HOME="$tmp/cache" \
               HOME="$tmp/home"
        bash "$REPO_ROOT/bin/cco" whoami 2>&1
    ); OP_RC=$?; rm -rf "$tmp"
    [[ $OP_RC -eq 0 ]] || fail "'cco whoami' custom triple must succeed, got rc=$OP_RC: $OP_OUT"
    [[ "$OP_OUT" == *"level:"*"custom (global=ro,current=rw,others=none)"* ]] \
        || fail "whoami asymmetric triple should read 'custom (…)', got: $OP_OUT"
    [[ "$OP_OUT" == *"triple:"*"G=ro Pc=rw Po=none"* ]] \
        || fail "whoami should still render the explicit triple, got: $OP_OUT"
    # config-editor: identity is the envelope, editing target names what it edits.
    [[ "$OP_OUT" == *"identity:"*"config-editor"* ]] \
        || fail "whoami config-editor identity should be config-editor, got: $OP_OUT"
    [[ "$OP_OUT" == *"editing target:"*"alpha"* ]] \
        || fail "whoami config-editor should name the editing target, got: $OP_OUT"
    return 0
}

# ── path: only 'list' is read-only, 'set' is host-only ───────────────

test_operator_path_set_blocked_list_allowed() {
    _op_cco edit-all path set foo /bar
    [[ $OP_RC -ne 0 && "$OP_OUT" == *"host-only"* ]] \
        || fail "'path set' must be host-only, got rc=$OP_RC: $OP_OUT"
    _op_cco read path list
    [[ "$OP_OUT" != *"host-only"* ]] \
        || fail "'path list' should pass the shim, got: $OP_OUT"
    return 0
}

# ── Read scope gating (ADR-0042) ─────────────────────────────────────
# read-project cannot browse personal-global management namespaces (template
# reads, remote list); read-global+ can. Unified `cco list` stays open at any
# read level (the on-demand discovery cornerstone).

test_operator_read_project_gates_global_namespaces() {
    _op_cco read-project template show foo
    [[ $OP_RC -ne 0 && "$OP_OUT" == *"read-global scope"* ]] \
        || fail "'template show' under read-project must need read-global, got rc=$OP_RC: $OP_OUT"
    _op_cco read-project remote list
    [[ $OP_RC -ne 0 && "$OP_OUT" == *"read-global scope"* ]] \
        || fail "'remote list' under read-project must need read-global, got rc=$OP_RC: $OP_OUT"
    return 0
}

test_operator_read_global_allows_global_namespaces() {
    local v
    for v in "template show foo" "template list" "remote list"; do
        # shellcheck disable=SC2086
        _op_cco read-global $v
        [[ "$OP_OUT" != *"read-global scope"* && "$OP_OUT" != *"host-only"* ]] \
            || fail "'cco $v' should pass the shim under read-global, got: $OP_OUT"
    done
    return 0
}

test_operator_read_project_allows_project_verbs() {
    local v
    for v in "docs" "list" "list packs" "pack show foo" "llms show foo" "path list" "project show foo"; do
        # shellcheck disable=SC2086
        _op_cco read-project $v
        [[ "$OP_OUT" != *"read-global scope"* && "$OP_OUT" != *"host-only"* \
           && "$OP_OUT" != *"not available in a container session"* ]] \
            || fail "'cco $v' should pass the shim under read-project, got: $OP_OUT"
    done
    return 0
}

# ── Scope-aware usage in operator mode (ADR-0042) ────────────────────
# `cco help` inside operator mode flags host-only top-level verbs and prints the
# container-session banner; the write-only `tag` verb is marked at a read level.
# D7: in-container help is FILTERED by default (host-only + above-scope verbs
# omitted, with a hidden count); `--help --host` shows the full list flagged. The
# header caveats are recomputed from the resolved level (S6-04).
test_operator_usage_filters_by_default() {
    _op_cco read-project help
    [[ "$OP_OUT" == *"Container session (cco_access=read-project)"* ]] \
        || fail "operator usage should show the container-session banner, got: $OP_OUT"
    # Default view HIDES host-only verbs (build/start) and the write-only `tag`.
    echo "$OP_OUT" | grep -qE '^  build ' \
        && fail "default filtered help must hide host-only 'build', got: $OP_OUT"
    echo "$OP_OUT" | grep -qE '^  tag ' \
        && fail "default filtered help must hide write-only 'tag' at read-project, got: $OP_OUT"
    # Runnable read verbs stay visible.
    echo "$OP_OUT" | grep -qE '^  list ' \
        || fail "'list' should remain visible in filtered help, got: $OP_OUT"
    [[ "$OP_OUT" == *"host-only/above-scope verbs hidden"* ]] \
        || fail "filtered help should note how many verbs are hidden, got: $OP_OUT"
    # S6-04: the header recomputes real caveats (no gates that don't apply).
    [[ "$OP_OUT" == *"read project, write none"* ]] \
        || fail "header should report the resolved read/write scopes, got: $OP_OUT"
    return 0
}

test_operator_usage_host_flag_shows_all_flagged() {
    _op_cco read-project help --host
    echo "$OP_OUT" | grep -qE '^  build .*host only' \
        || fail "'cco --help --host' should show 'build' flagged host-only, got: $OP_OUT"
    echo "$OP_OUT" | grep -qE '^  start .*host only' \
        || fail "'cco --help --host' should show 'start' flagged host-only, got: $OP_OUT"
    return 0
}

# B1: whoami is runnable under operator mode (always-available read verb) → it must
# be listed in the filtered help, not omitted.
# whoami renders the Axis-B (Cr,Cp,Cg,Co) claude triple + the Authoring trees
# section (ADR-0049). Custom (non-preset) label passes through verbatim.
test_operator_whoami_renders_claude_triple() {
    local tmp; tmp=$(mktemp -d); mkdir -p "$tmp/home"
    OP_OUT=$(
        export CCO_IN_CONTAINER=1 CCO_CONTAINER_OPERATOR=1 CCO_STORE_ELEVATED=1 \
               CCO_CCO_ACCESS="edit-global" CCO_ACCESS_TRIPLE="rw,rw,none" \
               CCO_CLAUDE_ACCESS="repo=ro,current=rw,global=rw,others=ro" \
               CCO_CLAUDE_TRIPLE="ro,rw,rw,ro" PROJECT_NAME=demo \
               CCO_DATA_HOME="$tmp/data" CCO_STATE_HOME="$tmp/state" CCO_CACHE_HOME="$tmp/cache" \
               HOME="$tmp/home"
        bash "$REPO_ROOT/bin/cco" whoami 2>&1
    ); OP_RC=$?; rm -rf "$tmp"
    [[ $OP_RC -eq 0 ]] || fail "whoami must succeed, got rc=$OP_RC: $OP_OUT"
    [[ "$OP_OUT" == *"claude triple:"*"Cr=ro Cp=rw Cg=rw Co=ro"* ]] \
        || fail "whoami should render the Cr/Cp/Cg/Co claude triple, got: $OP_OUT"
    [[ "$OP_OUT" == *"Authoring trees (.claude)"* ]] \
        || fail "whoami should render the .claude authoring trees section, got: $OP_OUT"
    [[ "$OP_OUT" == *"global ~/.cco/.claude (Cg):"*"rw"* ]] \
        || fail "whoami should show global .claude (Cg) rw under edit-global, got: $OP_OUT"
    return 0
}
test_operator_usage_lists_whoami() {
    _op_cco read-project help
    echo "$OP_OUT" | grep -qE '^  whoami ' \
        || fail "operator help should list the runnable 'whoami' verb (B1), got: $OP_OUT"
    return 0
}

# B2: a section whose verbs are all filtered out must not leave a dangling header.
test_operator_usage_suppresses_empty_sections() {
    _op_cco read-project help
    # 'Sessions:' (start/new/stop) and 'Local paths & sync:' (resolve/sync) are wholly
    # host-only → their headers must be gone, not left standing over nothing.
    [[ "$OP_OUT" != *"Sessions:"* ]] \
        || fail "empty 'Sessions:' header should be suppressed (B2), got: $OP_OUT"
    [[ "$OP_OUT" != *"Local paths & sync:"* ]] \
        || fail "empty 'Local paths & sync:' header should be suppressed (B2), got: $OP_OUT"
    # A section that still has a runnable verb must remain.
    [[ "$OP_OUT" == *"Discovery:"* ]] \
        || fail "non-empty 'Discovery:' section should remain, got: $OP_OUT"
    return 0
}

test_operator_usage_header_recompute_edit_all() {
    # S6-04: at edit-all nothing is gated → no "needs edit level" caveat recited.
    _op_cco edit-all help
    [[ "$OP_OUT" == *"read all, write all"* ]] \
        || fail "edit-all header should report read all, write all, got: $OP_OUT"
    [[ "$OP_OUT" != *"need an edit level"* ]] \
        || fail "edit-all header must NOT recite an edit-level caveat, got: $OP_OUT"
    return 0
}

# ── Non-operator mode leaves the dispatcher untouched ────────────────
# Without the operator flag, the shim never runs — a host-only verb is NOT
# intercepted by the shim (it would run its normal host path).
test_operator_shim_inert_without_flag() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    local out
    out=$( export HOME="$tmp/home" CCO_ALLOW_HOST_RESOLVE=1; mkdir -p "$HOME"
           bash "$REPO_ROOT/bin/cco" help 2>&1 )
    [[ "$out" == *"Usage: cco"* ]] \
        || fail "Without operator flag, 'cco help' should show usage, got: $out"
}

# ── B5: `tag add/remove` gated by the TAGGED resource's axis (A1 §4.1) ─────────
# The blanket write:global gate (too strict AND too loose) is replaced by a
# per-target derivation: project(current)→Pc, project(other)→Po, pack/template→G.
# Kind + ownership resolve at the gate; ownership is config-editor-aware.

test_operator_tag_current_project_needs_pc() {
    # Too-strict fix: edit-project CAN tag its own current project (a Pc write),
    # which the old blanket-global gate wrongly refused.
    _op_seed edit-project alpha tag add alpha work
    [[ $OP_RC -eq 0 && "$OP_OUT" == *"tagged project 'alpha'"* ]] \
        || fail "edit-project should tag its own project (Pc=rw), got rc=$OP_RC: $OP_OUT"
    # A read level cannot (Pc=ro, not rw) — refused naming the Pc axis.
    _op_seed read-project alpha tag add alpha work
    [[ $OP_RC -eq 2 && "$OP_OUT" == *"needs Pc=rw"* ]] \
        || fail "read-project must refuse tagging its own project (needs Pc=rw), got rc=$OP_RC: $OP_OUT"
    return 0
}

test_operator_tag_other_project_needs_po() {
    # Too-loose fix: edit-global must NOT tag ANOTHER project — G=rw does not grant
    # Po; only edit-all (Po=rw) may.
    _op_seed edit-project alpha tag add beta work
    [[ $OP_RC -eq 2 && "$OP_OUT" == *"needs Po=rw"* ]] \
        || fail "edit-project must refuse tagging another project (needs Po=rw), got rc=$OP_RC: $OP_OUT"
    _op_seed edit-global alpha tag add beta work
    [[ $OP_RC -eq 2 && "$OP_OUT" == *"needs Po=rw"* ]] \
        || fail "edit-global must refuse tagging another project (G=rw ≠ Po; too-loose fix), got rc=$OP_RC: $OP_OUT"
    _op_seed edit-all alpha tag add beta work
    [[ $OP_RC -eq 0 && "$OP_OUT" == *"tagged project 'beta'"* ]] \
        || fail "edit-all should tag another project (Po=rw), got rc=$OP_RC: $OP_OUT"
    return 0
}

test_operator_tag_pack_needs_g() {
    # A pack is a global-store resource (uniformly G, referenced or not, §4.1) —
    # edit-project (G=none) cannot tag it, edit-global (G=rw) can.
    _op_seed edit-project alpha tag add p1 work
    [[ $OP_RC -eq 2 && "$OP_OUT" == *"needs G=rw"* ]] \
        || fail "edit-project must refuse tagging a pack (needs G=rw), got rc=$OP_RC: $OP_OUT"
    _op_seed edit-global alpha tag add p1 work
    [[ $OP_RC -eq 0 && "$OP_OUT" == *"tagged pack 'p1'"* ]] \
        || fail "edit-global should tag a pack (G=rw), got rc=$OP_RC: $OP_OUT"
    return 0
}

test_operator_tag_config_editor_targets_are_current() {
    # config-editor: PROJECT_NAME is always 'config-editor'; its editable "current"
    # projects are the CCO_CONFIG_TARGETS set (D9). A target project is a Pc write
    # (allowed at edit-project); a non-target project is 'other' → Po.
    OP_TARGETS=alpha _op_seed edit-project config-editor tag add alpha work
    [[ $OP_RC -eq 0 && "$OP_OUT" == *"tagged project 'alpha'"* ]] \
        || fail "config-editor edit-project should tag a CONFIG_TARGET project (Pc=rw), got rc=$OP_RC: $OP_OUT"
    OP_TARGETS=alpha _op_seed edit-project config-editor tag add beta work
    [[ $OP_RC -eq 2 && "$OP_OUT" == *"needs Po=rw"* ]] \
        || fail "config-editor edit-project must treat a NON-target project as other (needs Po=rw), got rc=$OP_RC: $OP_OUT"
    return 0
}

# ── path list: output scoped like `cco list project`; host paths gated (A1 §4.3) ─

test_operator_path_list_scoped_at_read_project() {
    # Po<ro → scope to the current project's repos; others hidden + count notice.
    _op_seed read-project alpha path list
    [[ "$OP_OUT" == *"alpha"* ]] \
        || fail "path list should show the current project's repo, got: $OP_OUT"
    [[ "$OP_OUT" != *"beta"* ]] \
        || fail "path list at read-project must hide other projects' repos, got: $OP_OUT"
    [[ "$OP_OUT" == *"hidden by access scope"* ]] \
        || fail "path list should emit the count-only hidden notice, got: $OP_OUT"
    # F3: hidden entries are OTHER projects → the widening is read-all, not
    # read-global (which still hides other projects; A1 §2.2).
    [[ "$OP_OUT" == *"read-all"* && "$OP_OUT" != *"read-global session"* ]] \
        || fail "path list notice must point to read-all (not read-global), got: $OP_OUT"
    return 0
}

test_operator_path_list_full_at_read_all() {
    # Po≥ro → no scoping; all repos shown, no notice.
    _op_seed read-all alpha path list
    [[ "$OP_OUT" == *"alpha"* && "$OP_OUT" == *"beta"* ]] \
        || fail "path list at read-all should show every repo, got: $OP_OUT"
    [[ "$OP_OUT" != *"hidden by access scope"* ]] \
        || fail "path list at read-all must not hide anything, got: $OP_OUT"
    return 0
}

test_operator_path_list_masks_host_paths_when_off() {
    # show_host_paths=off → logical names only, no host-path column (S1b).
    OP_SHP=false _op_seed read-all alpha path list
    [[ "$OP_OUT" == *"alpha"* ]] \
        || fail "path list should still list logical names at show_host_paths=off, got: $OP_OUT"
    [[ "$OP_OUT" != *"/repos/alpha"* ]] \
        || fail "path list at show_host_paths=off must NOT print host paths, got: $OP_OUT"
    # With it on, the host path IS shown.
    OP_SHP=true _op_seed read-all alpha path list
    [[ "$OP_OUT" == *"/repos/alpha"* ]] \
        || fail "path list at show_host_paths=on should print host paths, got: $OP_OUT"
    return 0
}

# ── whoami+: explicit (G,Pc,Po) triple + granular form + boundary note (A1 §4.5) ─

test_operator_whoami_renders_triple_and_boundary() {
    _op_cco read-global whoami
    # R2: the explicit triple lives on the `triple:` line; read-global is a preset so
    # `level` names it (the granular is shown only for a preset-less custom triple).
    [[ "$OP_OUT" == *"triple:"* && "$OP_OUT" == *"G=ro Pc=ro Po=none"* ]] \
        || fail "whoami should render the explicit (G,Pc,Po) triple, got: $OP_OUT"
    [[ "$OP_OUT" == *"level:"*"read-global"* ]] \
        || fail "whoami should name the read-global preset, got: $OP_OUT"
    [[ "$OP_OUT" == *"ADR-0047 privilege boundary"* ]] \
        || fail "whoami should state enforcement is the privilege boundary, got: $OP_OUT"
    return 0
}

# ── B6: no silent exit-2 — every policy refusal states a reason (A1 §4.2) ───────

_b6_assert() {
    [[ $OP_RC -eq 2 ]] \
        || fail "expected a policy refusal (exit 2), got rc=$OP_RC: $OP_OUT"
    [[ -n "$OP_OUT" ]] \
        || fail "an exit-2 refusal must never be silent (B6)"
    [[ "$OP_OUT" == *"$1"* ]] \
        || fail "exit-2 refusal should state the reason '$1', got: $OP_OUT"
}

test_operator_no_silent_exit2() {
    # Host-only refusals name the host; above-scope refusals name the axis/scope.
    _op_cco read-project start foo;             _b6_assert host-only
    _op_cco read-project config validate;       _b6_assert host-only
    _op_cco edit-all path set foo /bar;         _b6_assert host-only
    _op_cco read-project template show foo;     _b6_assert read-global
    _op_cco read-project remote list;           _b6_assert read-global
    _op_seed edit-project alpha tag add p1 x;   _b6_assert "needs G=rw"
    _op_seed edit-project alpha tag add beta x; _b6_assert "needs Po=rw"
    _op_seed read-project alpha tag add alpha x; _b6_assert "needs Pc=rw"
    return 0
}
