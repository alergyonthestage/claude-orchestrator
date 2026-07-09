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
