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
_op_cco() {
    local level="$1"; shift
    local tmp; tmp=$(mktemp -d)
    OP_OUT=$(
        export CCO_IN_CONTAINER=1 CCO_CONTAINER_OPERATOR=1 CCO_CCO_ACCESS="$level" \
               CCO_DATA_HOME="$tmp/data" CCO_STATE_HOME="$tmp/state" CCO_CACHE_HOME="$tmp/cache" \
               HOME="$tmp/home"
        mkdir -p "$HOME"
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
    _op_cco read tag add proj mytag
    [[ $OP_RC -eq 2 && "$OP_OUT" == *"needs an edit-global"* ]] \
        || fail "'tag add' under read must be refused (exit 2, edit-global), got rc=$OP_RC: $OP_OUT"
    _op_cco read config save
    [[ $OP_RC -eq 2 && "$OP_OUT" == *"needs an edit-global"* ]] \
        || fail "'config save' under read must be refused (exit 2, edit-global), got rc=$OP_RC: $OP_OUT"
    _op_cco read remote add acme https://x
    [[ $OP_RC -eq 2 && "$OP_OUT" == *"needs an edit-global"* ]] \
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
# with the tree-aware "needs an edit-global" message. At edit-all it passes the
# gate (may fail later for other reasons, but never with the gate message).
test_operator_config_save_edit_project_needs_edit_global() {
    _op_cco edit-project config save -m x
    [[ $OP_RC -eq 2 && "$OP_OUT" == *"needs an edit-global"* ]] \
        || fail "'config save' at edit-project must be gate-refused (exit 2, edit-global), got rc=$OP_RC: $OP_OUT"
    _op_cco edit-all config save -m x
    [[ "$OP_OUT" != *"needs an edit-global"* ]] \
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
    [[ "$OP_OUT" == *"read scope: all"* ]] || fail "whoami should report read scope all, got: $OP_OUT"
    # At edit-project the project tree is rw, the global store ro (symmetric model).
    _op_cco edit-project whoami
    [[ "$OP_OUT" == *"write scope: project"* ]] || fail "whoami edit-project write scope, got: $OP_OUT"
    [[ "$OP_OUT" == *"project config (<repo>/.cco):        rw"* ]] \
        || fail "whoami edit-project must show project config rw, got: $OP_OUT"
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
