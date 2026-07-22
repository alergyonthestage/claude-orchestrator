#!/usr/bin/env bash
# tests/test_version_gate.sh — fail-loud version gate (ADR-0052 §1, WS-1)
#
# The gate (_cco_version_gate, lib/migrate.sh) runs in _cco_first_run, host-side
# only, and dies on ANY command when on-disk state is NEWER than this binary
# supports. Two bounds: the global .cco/meta schema_version vs the highest
# migrations/global/ ID, and the index version: vs the CCO_INDEX_VERSION constant
# (_latest_index_version). This closes FI-16 (a newer cco leaving state an older
# one silently misreads) and is what makes N1/N2's non-destructive reconcile safe.
#
# Host mode is forced deterministically with CCO_IN_CONTAINER=0 (the paths.sh fix
# this workstream also lands): the override honoured only ==1 before, so the
# host-only gate could not be exercised on a machine where /.dockerenv exists —
# such as cco's own self-dev container, where this suite runs.

# Source the gate + its dependencies with host semantics forced (CCO_IN_CONTAINER=0,
# NOT CCO_ALLOW_HOST_RESOLVE — so the container-skip test can flip to container mode
# and see the gate no-op). Each test runs in its own bin/test subshell.
_vg_env() {
    export HOME="$1/home"; mkdir -p "$HOME"
    export CCO_STATE_HOME="$1/state"
    export CCO_DATA_HOME="$1/data"
    export CCO_CACHE_HOME="$1/cache"
    unset XDG_STATE_HOME XDG_DATA_HOME XDG_CACHE_HOME CCO_ALLOW_HOST_RESOLVE
    export CCO_IN_CONTAINER=0
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/index.sh"
    source "$REPO_ROOT/lib/update-meta.sh"
    source "$REPO_ROOT/lib/migrate.sh"
}

# Write a minimal index carrying an explicit version line (the gate reads only
# `version:`; the empty sections keep it shaped like a real scaffold).
_vg_write_index_version() {
    local f; f=$(_index_file)
    mkdir -p "$(dirname "$f")"
    printf 'version: %s\nprojects:\nproject_paths:\nllms:\nunscoped:\n' "$1" > "$f"
}

# Write a global .cco/meta carrying an explicit schema_version.
_vg_write_meta_schema() {
    local m; m=$(_cco_global_meta)
    mkdir -p "$(dirname "$m")"
    printf 'schema_version: %s\n' "$1" > "$m"
}

# ── _latest_index_version / the constant ─────────────────────────────

test_latest_index_version_echoes_the_constant() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _vg_env "$tmp"

    [[ "$(_latest_index_version)" == "$CCO_INDEX_VERSION" ]] \
        || fail "_latest_index_version must echo CCO_INDEX_VERSION, got: $(_latest_index_version) vs $CCO_INDEX_VERSION"
    [[ "$CCO_INDEX_VERSION" == "2" ]] \
        || fail "CCO_INDEX_VERSION is expected to be 2 this cycle, got: $CCO_INDEX_VERSION"
}

# The scaffold writer must stamp the constant, not a stale literal — a bump to the
# constant must flow through to freshly-created indexes with no other edit.
test_ensure_file_stamps_the_constant() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _vg_env "$tmp"

    _index_ensure_file
    [[ "$(_index_version)" == "$CCO_INDEX_VERSION" ]] \
        || fail "a fresh scaffold must be at CCO_INDEX_VERSION, got: $(_index_version)"
}

# ── _cco_in_container ==0 forces host (the paths.sh fix) ──────────────

test_cco_in_container_zero_forces_host() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _vg_env "$tmp"

    # ==0 must win over a present /.dockerenv (this suite runs in a container).
    ( export CCO_IN_CONTAINER=0; _cco_in_container ) \
        && fail "CCO_IN_CONTAINER=0 must force host mode (_cco_in_container returns 1)"
    # ==1 still forces container.
    ( export CCO_IN_CONTAINER=1; _cco_in_container ) \
        || fail "CCO_IN_CONTAINER=1 must still force container mode (returns 0)"
    return 0
}

# ── The gate: pass cases ─────────────────────────────────────────────

test_gate_passes_on_a_fresh_machine() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _vg_env "$tmp"

    # No index, no meta — a clean install. The gate must be a silent no-op.
    ( _cco_version_gate ) || fail "the gate must pass on a fresh machine (no state yet)"
}

test_gate_passes_on_current_state() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _vg_env "$tmp"

    _vg_write_index_version "$(_latest_index_version)"
    _vg_write_meta_schema   "$(_latest_schema_version global)"
    ( _cco_version_gate ) || fail "the gate must pass when disk == supported"
}

# ── The gate: die cases ──────────────────────────────────────────────

test_gate_dies_on_a_newer_index() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _vg_env "$tmp"

    _vg_write_index_version "$(( $(_latest_index_version) + 1 ))"
    local rc=0 out
    out=$( ( _cco_version_gate ) 2>&1 ) || rc=$?
    [[ "$rc" -eq 1 ]] || fail "a newer index must die (exit 1), got rc=$rc"
    [[ "$out" == *"path index"* && "$out" == *"newer than this cco supports"* ]] \
        || fail "the die must name the index + the mismatch, got: $out"
}

test_gate_dies_on_a_newer_global_schema() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _vg_env "$tmp"

    # Leave the index absent/current so the index arm passes and the schema arm is
    # the one that fires.
    _vg_write_meta_schema "$(( $(_latest_schema_version global) + 1 ))"
    local rc=0 out
    out=$( ( _cco_version_gate ) 2>&1 ) || rc=$?
    [[ "$rc" -eq 1 ]] || fail "a newer global schema must die (exit 1), got rc=$rc"
    [[ "$out" == *"global config"* && "$out" == *"newer than this cco supports"* ]] \
        || fail "the die must name the global config + the mismatch, got: $out"
}

# An equal-to-supported schema must NOT die (boundary: die on strictly-greater).
test_gate_allows_equal_schema() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _vg_env "$tmp"

    _vg_write_index_version "$(_latest_index_version)"
    _vg_write_meta_schema   "$(_latest_schema_version global)"
    ( _cco_version_gate ) || fail "disk == supported is not > supported; must pass"
}

# ── The gate is host-only ────────────────────────────────────────────

test_gate_skips_inside_a_container() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _vg_env "$tmp"

    # Craft a newer index in host mode …
    _vg_write_index_version "$(( $(_latest_index_version) + 1 ))"
    # … then flip to container mode: the gate must be a no-op, not a die (the
    # buckets are bind-mounted in a session and never bootstrapped/gated there).
    local rc=0
    ( export CCO_IN_CONTAINER=1; unset CCO_ALLOW_HOST_RESOLVE; _cco_version_gate ) 2>/dev/null || rc=$?
    [[ "$rc" -eq 0 ]] || fail "the gate is host-only; it must skip in a container, got rc=$rc"
}

# ── Wiring: a real command is blocked through _cco_first_run/bin/cco ──

test_gate_blocks_a_real_command() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _vg_env "$tmp"

    _vg_write_index_version "$(( $(_latest_index_version) + 1 ))"
    # Invoke a real verb through the dispatcher: the gate runs in _cco_first_run,
    # before dispatch, so any command dies. `help` reaches first_run (only
    # --version/-v short-circuit earlier).
    local rc=0 out
    out=$(CCO_IN_CONTAINER=0 HOME="$HOME" \
          CCO_STATE_HOME="$CCO_STATE_HOME" CCO_DATA_HOME="$CCO_DATA_HOME" \
          CCO_CACHE_HOME="$CCO_CACHE_HOME" CCO_SKIP_BUILD=1 \
          bash "$REPO_ROOT/bin/cco" help 2>&1) || rc=$?
    [[ "$rc" -ne 0 ]] || fail "a newer index must block a real command, got rc=$rc"
    [[ "$out" == *"newer than this cco supports"* ]] \
        || fail "the blocked command must print the gate's message, got: $out"
}
