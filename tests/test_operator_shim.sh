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

# ── Write gating: write verbs need an edit level ─────────────────────

test_operator_read_level_refuses_writes() {
    _op_cco read tag add proj mytag
    [[ $OP_RC -ne 0 && "$OP_OUT" == *"edit access level"* ]] \
        || fail "'tag add' under read must be refused, got rc=$OP_RC: $OP_OUT"
    _op_cco read config save
    [[ $OP_RC -ne 0 && "$OP_OUT" == *"edit access level"* ]] \
        || fail "'config save' under read must be refused, got rc=$OP_RC: $OP_OUT"
    _op_cco read remote add acme https://x
    [[ $OP_RC -ne 0 && "$OP_OUT" == *"edit access level"* ]] \
        || fail "'remote add' under read must be refused, got rc=$OP_RC: $OP_OUT"
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
