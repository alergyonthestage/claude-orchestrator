#!/usr/bin/env bash
# tests/test_running_registry.sh — session running registry (ADR-0045, refined by
# ADR-0047). Unit-level coverage of the STATE `running/` markers + reconciliation +
# the tri-state _cco_session_status (B4), exercised by sourcing the helpers directly
# and controlling the environment (context + a docker stub).
#
# Covered:
#   - mark/unmark create + remove the per-session marker (host writer)
#   - _cco_session_status host branch = docker-authoritative (running/stopped)
#   - _cco_session_status in-container branch = registry read; absent registry → unknown (B4)
#   - _cco_running_reconcile prunes markers with no live container, keeps live ones
#   - no-`cco stop` exit → the next reconciliation reaps the stale marker (B-DF3)
#   - reconcile is a no-op in-container (no full docker)

# Source the helpers (+ deps) into the test subshell.
_rr_source() {
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"
    # Tests drive the helpers off a pinned STATE home without the in-container guard.
    export CCO_ALLOW_HOST_RESOLVE=1
}

# Force host vs in-container context deterministically (the suite itself may run
# inside a container, where /.dockerenv would otherwise pin _cco_in_container true).
_rr_host()      { _cco_in_container() { return 1; }; }
_rr_container() { _cco_in_container() { return 0; }; }

# A docker stub returning a live container id ONLY for the given project labels.
# Usage: _rr_stub_docker_live <label> [<label> ...]
_rr_stub_docker_live() {
    _RR_LIVE=" $* "
    docker() {
        [[ "$1" == ps ]] || { [[ "$1" == info || "$1" == image ]] && return 0; return 0; }
        local args="$*" lbl
        # Extract the queried label from --filter label=cco.project=<lbl>
        lbl=$(printf '%s\n' "$args" | sed -n 's/.*label=cco\.project=\([^ ]*\).*/\1/p')
        [[ -n "$lbl" && "$_RR_LIVE" == *" $lbl "* ]] && printf '%s\n' "id-$lbl"
        return 0
    }
}

# ── mark / unmark ─────────────────────────────────────────────────────

test_rr_mark_creates_and_unmark_removes() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _rr_source
    export CCO_STATE_HOME="$tmpdir/state"
    _cco_running_mark "alpha"
    assert_file_exists "$tmpdir/state/running/alpha" || return 1
    # Body carries informational metadata, not required for reconciliation.
    assert_file_contains "$tmpdir/state/running/alpha" "started_at=" || return 1
    _cco_running_unmark "alpha"
    assert_file_not_exists "$tmpdir/state/running/alpha" || return 1
    # Idempotent: unmark a missing marker is a no-op success.
    _cco_running_unmark "alpha"
}

# ── _cco_session_status: host branch (docker-authoritative) ───────────

test_rr_status_host_docker_authoritative() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _rr_source
    export CCO_STATE_HOME="$tmpdir/state"
    _rr_host
    _rr_stub_docker_live "alpha"
    [[ "$(_cco_session_status alpha)" == running ]] || fail "alpha should be running (docker live)"
    [[ "$(_cco_session_status beta)"  == stopped ]] || fail "beta should be stopped (docker empty)"
    # Host is never 'unknown', even with no registry dir present.
    [[ "$(_cco_session_status beta)" != unknown ]] || fail "host must never report unknown"
}

# ── _cco_session_status: in-container branch (registry read + B4) ─────

test_rr_status_container_reads_registry() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _rr_source
    export CCO_STATE_HOME="$tmpdir/state"
    _rr_container
    # In-container must NOT consult docker — a live stub for beta must be ignored.
    _rr_stub_docker_live "beta"
    mkdir -p "$tmpdir/state/running"
    : > "$tmpdir/state/running/alpha"
    [[ "$(_cco_session_status alpha)" == running ]] || fail "alpha marker → running"
    [[ "$(_cco_session_status beta)"  == stopped ]] || fail "no marker → stopped (docker ignored in-container)"
}

test_rr_status_container_unknown_without_registry() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _rr_source
    # STATE home exists but the running/ dir does not (e.g. cco_access=none → no mount).
    export CCO_STATE_HOME="$tmpdir/state"
    mkdir -p "$tmpdir/state"
    _rr_container
    [[ "$(_cco_session_status alpha)" == unknown ]] || fail "absent registry → unknown (B4), never stopped"
}

# ── reconciliation (host-only backstop reaper) ───────────────────────

test_rr_reconcile_prunes_dead_keeps_live() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _rr_source
    export CCO_STATE_HOME="$tmpdir/state"
    _rr_host
    _cco_running_mark "alpha"   # will be live
    _cco_running_mark "beta"    # will be dead
    _rr_stub_docker_live "alpha"
    _cco_running_reconcile
    assert_file_exists "$tmpdir/state/running/alpha" || return 1
    assert_file_not_exists "$tmpdir/state/running/beta" || return 1
}

# B-DF3: a normal exit does not call `cco stop`, so a marker can be left behind. The
# next host read's reconciliation must reap it (docker ps = truth).
test_rr_no_stop_exit_reaped_on_next_read() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _rr_source
    export CCO_STATE_HOME="$tmpdir/state"
    _rr_host
    _cco_running_mark "ghost"   # session exited without cco stop → stale marker
    _rr_stub_docker_live         # nothing live
    _cco_running_reconcile
    assert_file_not_exists "$tmpdir/state/running/ghost" || return 1
}

test_rr_reconcile_noop_in_container() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _rr_source
    export CCO_STATE_HOME="$tmpdir/state"
    # Seed a marker on the (host-visible) tmp, then reconcile in-container: no full
    # docker in a session → the sweep must be a no-op (never prune).
    mkdir -p "$tmpdir/state/running"; : > "$tmpdir/state/running/alpha"
    _rr_container
    _rr_stub_docker_live          # even if docker were consulted, alpha is dead
    _cco_running_reconcile
    assert_file_exists "$tmpdir/state/running/alpha" || return 1
}
