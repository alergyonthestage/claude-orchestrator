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

# ── Never trust a version we could not cleanly read (review F1/F2/F5b) ─

# F2: an unreadable index must die HONESTLY, not silently coerce to version 1 and
# sail past (which would give the gate zero protection — the FI-16 misread class).
test_gate_dies_on_an_unreadable_index() {
    [[ "$(id -u)" -eq 0 ]] && return 0   # root ignores the mode bits
    local tmp; tmp=$(mktemp -d)
    trap "chmod -R u+rwX '$tmp' 2>/dev/null; rm -rf '$tmp'" EXIT
    _vg_env "$tmp"

    _vg_write_index_version "$(_latest_index_version)"   # current, not newer
    chmod 000 "$(_index_file)"
    local rc=0 out
    out=$( ( _cco_version_gate ) 2>&1 ) || rc=$?
    chmod 644 "$(_index_file)"
    [[ "$rc" -eq 1 ]] || fail "an unreadable index must die cleanly (exit 1), got rc=$rc"
    [[ "$out" == *"cannot be read"* ]] || fail "the die must name the read failure, got: $out"
}

# F2/F5b: a readable index whose version line is not an integer must die, not pass
# by coercion (the old `${v//[^0-9]/}` would have silently mangled it).
test_gate_dies_on_a_malformed_index_version() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _vg_env "$tmp"

    local f; f=$(_index_file); mkdir -p "$(dirname "$f")"
    printf 'version: abc\nprojects:\nproject_paths:\nllms:\nunscoped:\n' > "$f"
    local rc=0 out
    out=$( ( _cco_version_gate ) 2>&1 ) || rc=$?
    [[ "$rc" -eq 1 ]] || fail "a malformed index version must die (exit 1), got rc=$rc"
    [[ "$out" == *"unreadable version line"* ]] || fail "must name the malformation, got: $out"
}

# F1 (unit): an unreadable global meta must die honestly — the readability probe
# fires before _read_cco_meta, so its trailing awk never runs on the bad file.
test_gate_dies_on_an_unreadable_meta() {
    [[ "$(id -u)" -eq 0 ]] && return 0
    local tmp; tmp=$(mktemp -d)
    trap "chmod -R u+rwX '$tmp' 2>/dev/null; rm -rf '$tmp'" EXIT
    _vg_env "$tmp"

    _vg_write_meta_schema "$(_latest_schema_version global)"   # current, not newer
    chmod 000 "$(_cco_global_meta)"
    local rc=0 out
    out=$( ( _cco_version_gate ) 2>&1 ) || rc=$?
    chmod 644 "$(_cco_global_meta)"
    [[ "$rc" -eq 1 ]] || fail "an unreadable meta must die cleanly (exit 1), got rc=$rc"
    [[ "$out" == *"cannot be read"* ]] || fail "the die must name the read failure, got: $out"
}

test_gate_dies_on_a_malformed_meta_schema() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _vg_env "$tmp"

    _vg_write_meta_schema "abc"   # readable but non-integer
    local rc=0 out
    out=$( ( _cco_version_gate ) 2>&1 ) || rc=$?
    [[ "$rc" -eq 1 ]] || fail "a malformed schema_version must die (exit 1), got rc=$rc"
    [[ "$out" == *"malformed schema_version"* ]] || fail "must name the malformation, got: $out"
}

# F1 (regression, the real crash): through the dispatcher (bin/cco has set -euo
# pipefail), an unreadable meta must die CLEANLY (exit 1 + message), NOT crash raw
# through _read_cco_meta's trailing awk — which surfaced as the generic
# "exited unexpectedly" (exit 2) trap, the non-actionable UX this cluster kills.
test_gate_unreadable_meta_dies_cleanly_via_cco() {
    [[ "$(id -u)" -eq 0 ]] && return 0
    local tmp; tmp=$(mktemp -d)
    trap "chmod -R u+rwX '$tmp' 2>/dev/null; rm -rf '$tmp'" EXIT
    _vg_env "$tmp"

    _vg_write_meta_schema "$(_latest_schema_version global)"
    chmod 000 "$(_cco_global_meta)"
    local rc=0 out
    out=$(CCO_IN_CONTAINER=0 HOME="$HOME" \
          CCO_STATE_HOME="$CCO_STATE_HOME" CCO_DATA_HOME="$CCO_DATA_HOME" \
          CCO_CACHE_HOME="$CCO_CACHE_HOME" CCO_SKIP_BUILD=1 \
          bash "$REPO_ROOT/bin/cco" help 2>&1) || rc=$?
    chmod 644 "$(_cco_global_meta)"
    [[ "$rc" -eq 1 ]] || fail "unreadable meta must die cleanly (exit 1), got rc=$rc"
    [[ "$out" == *"cannot be read"* ]] || fail "must name the read failure, got: $out"
    [[ "$out" != *"exited unexpectedly"* ]] || fail "must NOT crash raw, got: $out"
}

# F4: when the latest schema is indeterminate (mis-resolved FRAMEWORK_ROOT →
# _latest_schema_version 0), the >0 guard must SKIP the schema arm rather than
# brick a working install on an undeterminable bound (the index arm still protects).
test_gate_skips_schema_when_latest_indeterminate() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _vg_env "$tmp"

    export FRAMEWORK_ROOT="$tmp/no-framework"; mkdir -p "$FRAMEWORK_ROOT"
    [[ "$(_latest_schema_version global)" == "0" ]] \
        || fail "precondition: latest schema must be indeterminate (0) with no migrations dir"
    _vg_write_meta_schema "999"   # far newer than anything — must NOT trigger a die
    # Index absent → index arm skips; the schema arm must be skipped by the >0 guard.
    ( _cco_version_gate ) || fail "an indeterminate latest must skip the schema gate, not brick"
}
