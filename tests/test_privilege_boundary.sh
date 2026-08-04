#!/usr/bin/env bash
# tests/test_privilege_boundary.sh — internal-store privilege boundary (ADR-0047).
#
# Phase II confines the internal store (STATE index, DATA registries, CACHE) behind a
# cco-svc mode-0700 real-FS root reached only through a setuid helper. The BOUNDARY
# ITSELF — EACCES on parent traversal, the setuid elevation, the fakeowner layout — is
# image/entrypoint plumbing and is verified only after `cco build && cco start` on a
# real container (self-dev caveat; ADR-0047 §8 Test B + the maintainer check-in). These
# tests cover the BASH-side contract that IS exercisable in-session:
#   1. the resolver redirect (operator mode never creates/stats under the root),
#   2. the host-side session descriptor (content + :ro mount),
#   3. the store-verb classifier that decides what re-execs elevated,
#   4. the setuid helper's fail-closed contract (compiled + run when gcc is present).

# ── 1. Resolver: operator mode skips _cco_ensure_dir under the privileged root ──
# In a container-operator session CCO_*_HOME point under /var/lib/cco-internal, which
# the claude user cannot traverse. The resolver must return the path STRING without
# trying to create/stat it (EACCES) — the buckets are pre-created + mounted host-side.
test_boundary_resolver_no_ensure_under_root() {
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"

    local root="/nonexistent-cco-internal-$$"
    local val rc=0
    val=$( export CCO_IN_CONTAINER=1 CCO_CONTAINER_OPERATOR=1 \
                  CCO_DATA_HOME="$root/share/cco" CCO_STATE_HOME="$root/state/cco" \
                  CCO_CACHE_HOME="$root/cache/cco"
           _cco_state_dir ) || rc=$?
    [[ $rc -eq 0 && "$val" == "$root/state/cco" ]] \
        || fail "operator STATE resolver: rc=$rc val=$val (expected the redirected path)"
    [[ ! -e "$root" ]] \
        || fail "operator resolver must NOT create anything under the privileged root"
}

# ── 2. Host-side session descriptor: content + :ro mount ──────────────
# `cco start` writes the trusted descriptor (the resolved triple + membership) that the
# setuid helper reads to gate every elevated store op (R2). It must carry the whitelist
# keys and be mounted :ro (VFS-level, so the agent cannot forge a wider scope).
test_boundary_descriptor_content_and_mount() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    mkdir -p "$CCO_DUMMY_REPO/.cco"
    run_cco start "test-proj" --cco-access read-global --dry-run --dump

    local desc="$DRY_RUN_DIR/.cco/session-access"
    [[ -f "$desc" ]] || fail "session descriptor not generated at $desc"
    # read-global → symmetric triple (ro, ro, none).
    grep -q '^CCO_ACCESS_TRIPLE=ro,ro,none$' "$desc" \
        || fail "descriptor must carry the resolved triple, got: $(grep CCO_ACCESS_TRIPLE "$desc")"
    grep -q '^PROJECT_NAME=test-proj$' "$desc" || fail "descriptor must carry PROJECT_NAME"
    grep -q '^CCO_SHOW_HOST_PATHS=' "$desc"    || fail "descriptor must carry CCO_SHOW_HOST_PATHS"
    # Mounted :ro at the fixed helper path so it cannot be forged in-session.
    local c; c=$(cat "$DRY_RUN_DIR/.cco/docker-compose.yml")
    echo "$c" | grep -qE '/etc/cco/session-access:ro"' \
        || fail "descriptor must be bind-mounted :ro at /etc/cco/session-access"
    # The descriptor stays OUT of the bulk-mounted managed overlay (/workspace/.managed).
    if echo "$c" | grep -qE 'session-access:/workspace/\.managed'; then
        fail "descriptor must not surface under /workspace/.managed"
    fi
}

# The descriptor is written ONLY for an operator session; cco-access none has none.
test_boundary_no_descriptor_when_access_none() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    mkdir -p "$CCO_DUMMY_REPO/.cco"
    run_cco start "test-proj" --cco-access none --dry-run --dump
    [[ ! -f "$DRY_RUN_DIR/.cco/session-access" ]] \
        || fail "no session descriptor should be written under cco-access none"
}

# ── 3. Store-verb classifier (the trampoline decision) ────────────────
# Extract just _cco_verb_touches_store from bin/cco (sourcing bin/cco would run main)
# and assert store reads/writes elevate while config-content + host verbs do not.
test_boundary_verb_classifier() {
    eval "$(sed -n '/^_cco_verb_touches_store()/,/^}/p' "$REPO_ROOT/bin/cco")"
    local spec
    for spec in "list" "path list" "tag add" "tag remove" "tag rm" "remote list" \
                "project show" "project validate" "project coords" \
                "pack show" "template show" "template validate" "llms show"; do
        # shellcheck disable=SC2086
        _cco_verb_touches_store $spec || fail "store verb '$spec' should re-exec elevated"
    done
    for spec in "config save" "config push" "whoami" "docs" "help" "start" "stop" \
                "tag" "path set" "project export" "remote add" "pack install"; do
        # shellcheck disable=SC2086
        if _cco_verb_touches_store $spec; then fail "non-store verb '$spec' must NOT elevate"; fi
    done
    return 0
}

# ── 4. Setuid helper: fail-closed contract ────────────────────────────
# Compile config/cco-svc-helper.c (skipped when no C toolchain) and assert it refuses
# (exit 2) both a missing store verb and — when the fixed descriptor path is absent — a
# missing descriptor. The real EACCES boundary is verified post-build (self-dev caveat).
test_boundary_helper_fail_closed() {
    command -v gcc >/dev/null 2>&1 || return 0   # no toolchain in this env → skip
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    local bin="$tmpdir/cco-svc-helper"
    gcc -Wall -Wextra -O2 -o "$bin" "$REPO_ROOT/config/cco-svc-helper.c" 2>"$tmpdir/cc.log" \
        || fail "cco-svc-helper.c failed to compile: $(cat "$tmpdir/cc.log")"

    # No store verb → refuse (checked before the descriptor is even opened).
    local out rc=0
    out=$("$bin" 2>&1) || rc=$?
    [[ $rc -eq 2 ]] || fail "helper with no verb must exit 2 (fail-closed), got rc=$rc: $out"

    # A verb but no descriptor → refuse. Only assert when the fixed path is truly absent
    # (a running Phase-II container would have it; this test env does not).
    if [[ ! -e /etc/cco/session-access ]]; then
        rc=0
        out=$("$bin" list 2>&1) || rc=$?
        [[ $rc -eq 2 ]] || fail "helper with no descriptor must exit 2 (fail-closed), got rc=$rc: $out"
        echo "$out" | grep -qi 'fail-closed\|descriptor' \
            || fail "helper refusal should name the missing descriptor, got: $out"
    fi
    return 0
}

# ── 5. store-op: the RC-3 internal store crossing (05-store-write-path.md §3.7) ──
# `store-op` is an INTERNAL boundary-crossing target reached only through the cco-svc
# helper's elevated re-entry (`cco __store store-op <mode> <op> args…`). It is NEVER a
# public verb. These cover the bash-side contract: INV-S2 (the elevated arm re-gates
# off the trusted triple), INV-S1 (validation runs BEFORE the gate, fail-closed), and
# §3.7 (it is absent from the host dispatcher).

# Drive the elevated store-op re-entry with a controlled triple + throwaway buckets.
# Sets SO_RC + SO_OUT. Self-contained (its own operator env, its own buckets), so it
# does not depend on setup_cco_env. Usage: _storeop <triple> <mode> <op> [args…]
_storeop() {
    local triple="$1" mode="$2"; shift 2
    local tmp; tmp=$(mktemp -d)
    mkdir -p "$tmp/data" "$tmp/state" "$tmp/cache" "$tmp/home"
    SO_OUT=$(
        export HOME="$tmp/home" CCO_ALLOW_HOST_RESOLVE=1
        export CCO_IN_CONTAINER=1 CCO_CONTAINER_OPERATOR=1 CCO_STORE_ELEVATED=1
        export CCO_DATA_HOME="$tmp/data" CCO_STATE_HOME="$tmp/state" CCO_CACHE_HOME="$tmp/cache"
        export CCO_ACCESS_TRIPLE="$triple" CCO_CCO_ACCESS=edit-global
        unset CCO_SESSION_CONTEXT PROJECT_NAME CCO_CONFIG_TARGETS || true
        bash "$REPO_ROOT/bin/cco" __store store-op "$mode" "$@" 2>&1
    )
    SO_RC=$?
    rm -rf "$tmp"
    return 0
}

# INV-S2: the elevated arm re-gates. A write that the session's G axis does not grant
# is refused (exit 2), even in the elevated re-entry. Pre-fix: store-op is an unknown
# verb → the top-level dispatcher dies exit 1, so the exit-2 assertion fails.
test_boundary_storeop_is_write_gated() {
    _storeop "ro,ro,none" apply sidecar-purge packs somepack
    assert_refused "$SO_RC" "$SO_OUT" "G=rw" || return 1
    return 0
}

# INV-S1 placement clause: validation runs FIRST, before the gate — a malformed op
# (path traversal in the name) is refused even when the gate WOULD pass (rw,rw,rw), and
# the "Invalid store op" message proves it was rejected at validation, not at dispatch.
# Pre-fix: store-op unknown → the assertion is unreachable.
test_boundary_storeop_validates_before_gate() {
    _storeop "rw,rw,rw" apply sidecar-rekey packs "../../state/cco" x
    assert_rc 1 "$SO_RC" "store-op with a traversal name must die before dispatch" || return 1
    [[ "$SO_OUT" == *"Invalid store op"* ]] \
        || { fail "a traversal op must be rejected at validation (INV-S1), got: $SO_OUT"; return 1; }
    return 0
}

# §3.7: store-op is dispatched ONLY inside the __store elevated re-entry, never from
# the top-level host dispatcher — otherwise `cco store-op …` would be a real, ungated,
# undocumented public host verb (the rev.1 regression). On a simulated HOST
# (_cco_container_operator false: no CCO_CONTAINER_OPERATOR/CCO_IN_CONTAINER), it must
# be an UNKNOWN command. Regression guard — passes today; it fails only if store-op is
# ever wired into the top-level `case "$cmd"`.
test_boundary_storeop_absent_from_host_dispatcher() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"           # HOST context (no operator env); pre-created roots
    local rc=0; run_cco store-op apply sidecar-purge packs x || rc=$?
    assert_rc 1 "$rc" "host 'cco store-op' must be an unknown command, not a hidden verb" || return 1
    [[ "$CCO_OUTPUT" == *"Unknown command: store-op"* ]] \
        || { fail "host store-op must report an unknown command (§3.7), got: $CCO_OUTPUT"; return 1; }
    return 0
}

# INV-S5 LOCK (alternative 4.1): the mixed store-mutating verbs must NOT be whole-verb
# elevated — that would make cco-svc rewrite a claude-owned tree (~/.cco/packs/<name>,
# a repo's project.yml). Their store cascades cross per-op through lib/store.sh; only
# the claude-owned half runs in-process. Passes today; it is the lock that keeps
# alternative 4.1 from being reintroduced (a bug-catcher would be reversed here).
test_boundary_mixed_verbs_do_not_whole_verb_elevate() {
    eval "$(sed -n '/^_cco_verb_touches_store()/,/^}/p' "$REPO_ROOT/bin/cco")"
    local spec
    for spec in "pack remove" "pack rename" "template remove" "template rename" \
                "llms remove" "llms rename" "remote add" "remote remove" "remote rename"; do
        # shellcheck disable=SC2086
        if _cco_verb_touches_store $spec; then
            fail "mixed store verb '$spec' must NOT whole-verb elevate (INV-S5) — it crosses per-op via lib/store.sh"
            return 1
        fi
    done
    return 0
}
