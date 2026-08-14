#!/usr/bin/env bash
# tests/test_warn_capture.sh — the message taxonomy and the warn-capture buffer
#
# Contract under test: ADR-0059 D1…D6 and the API table in
# docs/maintainers/cli/design/design-warning-gate-and-onboarding-prompts.md §4.2.
# These tests are written from that contract — inputs → expected outputs — not from
# the implementation: they must hold for ANY buffer that satisfies §4.2, and fail
# for the shell-array one §4.1 rejects.
#
# Test-plan coverage (design §6): T1, T2, T3 ⭐, T7, T9. T4–T6, T8, T10 belong to the
# gate (unit U2) and T12–T13 to the surface fixes (U3); neither exists yet.
#
# ⚠ WHY THERE IS NO LIVE PROMPT HERE. `_prompt_for_path` reads /dev/tty, and the
# suite's own runner captures the output of every test — a prompt whose text is
# swallowed while the read blocks is the silent, unattributable hang
# `test_invariant_tty_gate_single_spelling` and CCO_NONINTERACTIVE=1 exist to
# prevent. The prompt-local arm of T9 is therefore checked statically, against the
# six sites D4 names.

_source_warn_capture() {
    export CCO_ALLOW_HOST_RESOLVE=1
    export CCO_STATE_HOME="$1"
    unset XDG_STATE_HOME
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/yaml.sh"
    source "$REPO_ROOT/lib/index.sh"
    source "$REPO_ROOT/lib/local-paths.sh"
}

# ── T1 — a clean run is silent, and arming the capture changes no output ──
# Discriminates against: a buffer that reports something of its own (the gate would
# then fire, or print, on a run that has nothing to say — and read as "working").

test_warn_capture_clean_run_captures_nothing() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_warn_capture "$tmpdir/state"

    _cco_warn_capture_begin
    info "a chronicle line"
    ok   "another chronicle line"
    note "an accepted divergence"

    assert_equals "0" "$(_cco_warn_capture_count)" "no warn ⇒ the count must be 0"
    assert_empty "$(_cco_warn_capture_list)" "no warn ⇒ the list must be empty"
    _cco_warn_capture_end
}

test_warn_capture_does_not_change_warn_output() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_warn_capture "$tmpdir/state"

    local off on
    off=$(warn "a session condition" 2>&1)
    _cco_warn_capture_begin
    on=$(warn "a session condition" 2>&1)
    _cco_warn_capture_end

    assert_equals "$off" "$on" "arming the capture must not alter a single byte of what warn prints"
}

# ── T2 — a warn is captured, with its exact text ─────────────────────
# Discriminates against: a buffer that is written but never read back.

test_warn_capture_records_the_exact_message() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_warn_capture "$tmpdir/state"

    _cco_warn_capture_begin
    warn "Pack 'core-dev-framework' not resolved — run 'cco resolve'." 2>/dev/null

    assert_equals "1" "$(_cco_warn_capture_count)" "one warn ⇒ one captured message"
    assert_equals "Pack 'core-dev-framework' not resolved — run 'cco resolve'." \
        "$(_cco_warn_capture_list)" "the captured text must be the message body, verbatim"
    _cco_warn_capture_end
}

test_warn_capture_keeps_emission_order() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_warn_capture "$tmpdir/state"

    _cco_warn_capture_begin
    { warn "first"; warn "second"; warn "third"; } 2>/dev/null

    assert_equals "first
second
third" "$(_cco_warn_capture_list)" "the list is the buffer in EMISSION order (the gate reads it top to bottom)"
    _cco_warn_capture_end
}

# ── T3 ⭐ — a warn emitted inside $( ) reaches the buffer ─────────────
# THE test the design exists for (D5). Driven through a PRODUCTION call path, never
# a synthetic subshell: _effective_extra_mounts resolves each mount's readonly flag
# with `ro=$(_parse_bool "$ro_raw" "true")` (lib/local-paths.sh), and _parse_bool
# warns on an invalid boolean (lib/yaml.sh) — so that warn runs in a subshell of the
# real start-time path, exactly like the ones §4.1 measured.
#
# NOTE ON THE DRIVER. The design names `_prompt_for_path` as the driver; D4 — landed
# in this same unit — reclassifies every message inside it to prompt-local, so it no
# longer emits a warn at all and can no longer drive this test. The property under
# test is unchanged and so is D5's rationale: `$( )` subshells still carry
# production warns, and this is one of them.
#
# Discriminates against: THE SHELL-ARRAY BUFFER, which would lose exactly this
# message while passing every other test in this file. The second assertion proves
# the driver really is a subshell, so a pass here is not an accident of the fixture.

test_warn_capture_survives_command_substitution() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_warn_capture "$tmpdir/state"

    local mount_dir="$tmpdir/dev/docs"; mkdir -p "$mount_dir"
    _index_set_path demo "docs" "$mount_dir"

    local proj="$tmpdir/proj"; mkdir -p "$proj"
    cat > "$proj/project.yml" <<'YAML'
name: demo
extra_mounts:
  - name: docs
    target: /workspace/docs
    readonly: sometimes
YAML

    _cco_warn_capture_begin
    local out; out=$(_effective_extra_mounts "$proj/project.yml" 2>/dev/null)

    # The mount still resolves — the invalid boolean falls back to the secure
    # default. The warning is the point, not a failure of the surrounding work.
    assert_equals "$mount_dir"$'\t'"/workspace/docs"$'\t'"true"$'\t'"ro"$'\t' "$out" \
        "an invalid readonly: must still fall back to the secure default"
    assert_equals "1" "$(_cco_warn_capture_count)" \
        "⭐ a warn emitted inside \$( ) MUST reach the buffer — this is what the file-backed buffer exists for (ADR-0059 D5)"
    assert_equals "Invalid boolean value 'sometimes' — defaulting to 'true'" \
        "$(_cco_warn_capture_list)" "and it must arrive with its text intact"
    _cco_warn_capture_end

    # Prove the oracle discriminates: the same shape loses a SHELL-ARRAY append, so
    # the array implementation would fail the assertion above rather than sneak past
    # it. Without this, a pass proves only that the fixture ran.
    local -a probe_arr=()
    _t3_probe_subshell() { probe_arr+=("lost"); printf 'value\n'; }
    local _v; _v=$(_t3_probe_subshell)
    assert_equals "0" "${#probe_arr[@]}" \
        "the production shape IS a subshell — an array append made inside it does not survive"
}

# ── T7 — one condition with two producers is ONE list entry ──────────
# Discriminates against: a buffer that does not deduplicate. lib/packs.sh and
# lib/session-context.sh emit the same sentence for the same malformed pack.yml;
# listing it twice reads as two problems.

test_warn_capture_deduplicates_identical_messages() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_warn_capture "$tmpdir/state"

    local msg="Pack 'demo': pack.yml has no valid top-level keys — ignoring."
    _t7_producer_one() { warn "$msg"; }
    _t7_producer_two() { warn "$msg"; }

    _cco_warn_capture_begin
    { _t7_producer_one; _t7_producer_two; } 2>/dev/null

    assert_equals "1" "$(_cco_warn_capture_count)" "the same text from two producers is ONE entry"
    assert_equals "$msg" "$(_cco_warn_capture_list)" "and the entry is that text"

    # Negative control: dedup must collapse duplicates, not distinct messages.
    warn "a different condition entirely" 2>/dev/null
    assert_equals "2" "$(_cco_warn_capture_count)" \
        "dedup is on EXACT text — two distinct messages stay two entries"
    _cco_warn_capture_end
}

# ── T9 — only `warn` is captured ─────────────────────────────────────
# Discriminates against: D2 collapsing back into "everything gates", which is the
# state the taxonomy exists to leave. A gate that fires on a chronicle line teaches
# users to answer it without reading, and then the one message that mattered is lost
# in the same way it is lost today.

test_warn_capture_ignores_the_non_gating_levels() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_warn_capture "$tmpdir/state"

    _cco_warn_capture_begin
    {
        info  "started demo from repo [source: cwd]"
        ok    "Cloned demo"
        note  "dev-sandbox active — internal state isolated"
        error "Failed to clone git@example.com:org/demo.git"
        echo  "  Invalid choice 'x'" >&2      # prompt-local (D4)
    } 2>/dev/null

    assert_equals "0" "$(_cco_warn_capture_count)" \
        "info/ok/note/error and prompt-local feedback must NOT gate a launch (ADR-0059 D2)"
    _cco_warn_capture_end
}

test_prompt_local_sites_emit_no_warn() {
    # The dynamic half of T9 cannot run without a terminal (see the file header), so
    # the six D4 sites are checked where they live. This is the arm that fails if a
    # later author "restores" a warn inside the prompt: under D1 a corrected typo
    # would then hold the launch hostage at the end of the run.
    local body
    body=$(awk '/^_prompt_for_path\(\)/,/^}/' "$REPO_ROOT/lib/local-paths.sh")
    assert_empty "$(printf '%s\n' "$body" | grep -n '^[^#]*[^A-Za-z0-9_]warn ' || true)" \
        "_prompt_for_path is prompt-local (ADR-0059 D4) — it must contain no warn"

    body=$(awk '/^_resolve_disambiguate\(\)/,/^}/' "$REPO_ROOT/lib/local-paths.sh")
    assert_empty "$(printf '%s\n' "$body" | grep -n '^[^#]*[^A-Za-z0-9_]warn ' || true)" \
        "_resolve_disambiguate is prompt-local (ADR-0059 D4) — it must contain no warn"

    # Discrimination: the grep must actually find a warn when one is there, or both
    # assertions above would pass against any text whatsoever.
    body=$(awk '/^_resolve_entry_index\(\)/,/^}/' "$REPO_ROOT/lib/local-paths.sh")
    local found; found=$(printf '%s\n' "$body" | grep -c '^[^#]*[^A-Za-z0-9_]warn ' || true)
    [[ "$found" -ge 1 ]] || { fail "the prompt-local probe does NOT discriminate: it found no warn in _resolve_entry_index, which legitimately keeps one (the failed index bind — §3.3 'unchanged, gates')"; return 1; }
}

# ── The buffer's own contract (§4.2 + D6) ────────────────────────────

test_warn_capture_buffer_lives_outside_the_confined_buckets() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_warn_capture "$tmpdir/state"

    _cco_warn_capture_begin
    local buf="${_CCO_WARN_LOG:-}"
    [[ -n "$buf" ]] || { fail "_cco_warn_capture_begin must export _CCO_WARN_LOG"; return 1; }
    assert_file_exists "$buf" "the buffer file must exist once the capture is armed"

    # D6 / ADR-0047 INV-S1: never STATE, DATA or CACHE — code outside lib/store.sh
    # may not even PREDICATE a confined path, and a warning buffer does not justify
    # a store-op crossing.
    local tmproot="${TMPDIR:-/tmp}"; tmproot="${tmproot%/}"
    case "$buf" in
        "$tmproot"/cco-warn.*) : ;;
        *) fail "the buffer must be an mktemp template under \${TMPDIR:-/tmp} (D6), got: $buf"; return 1 ;;
    esac
    case "$buf" in
        "$tmpdir/state"*|*/.local/state/cco/*|*/.local/share/cco/*|*/.cache/cco/*)
            fail "INV-S1: the buffer must never live in STATE/DATA/CACHE, got: $buf"; return 1 ;;
    esac
    _cco_warn_capture_end
}

test_warn_capture_begin_is_idempotent() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_warn_capture "$tmpdir/state"

    _cco_warn_capture_begin
    local first="$_CCO_WARN_LOG"
    warn "captured before the second begin" 2>/dev/null
    _cco_warn_capture_begin
    assert_equals "$first" "$_CCO_WARN_LOG" "a second begin must not re-create the buffer"
    assert_equals "1" "$(_cco_warn_capture_count)" "…and must not discard what was already captured"
    _cco_warn_capture_end
}

test_warn_capture_end_removes_the_buffer_and_disarms() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_warn_capture "$tmpdir/state"

    _cco_warn_capture_begin
    local buf="$_CCO_WARN_LOG"
    warn "something" 2>/dev/null
    _cco_warn_capture_end

    assert_file_not_exists "$buf" "end must remove the buffer file"
    assert_equals "" "${_CCO_WARN_LOG:-}" "end must unset _CCO_WARN_LOG"
    assert_equals "0" "$(_cco_warn_capture_count)" "a disarmed capture counts 0, it does not error"

    # Disarmed, warn must still be a plain warn.
    local out; out=$(warn "after the capture ended" 2>&1)
    assert_equals "0" "$(_cco_warn_capture_count)" "a warn after end is not captured anywhere"
    case "$out" in *"after the capture ended"*) : ;; *) fail "warn must still print once the capture is disarmed: $out"; return 1 ;; esac
}

test_warn_still_works_when_the_buffer_is_unwritable() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_warn_capture "$tmpdir/state"

    # §4.2: "a capture failure never breaks warn". Point the buffer at a path that
    # cannot be written — a warning must never be traded for the mechanism that was
    # meant to deliver it.
    export _CCO_WARN_LOG="$tmpdir/no/such/dir/cco-warn.XXXXXX"
    local out rc=0
    out=$(warn "the message still has to arrive" 2>&1) || rc=$?

    assert_equals "0" "$rc" "warn must succeed even when the capture cannot be written"
    case "$out" in *"the message still has to arrive"*) : ;; *) fail "warn must still print with an unwritable buffer: $out"; return 1 ;; esac
    assert_equals "0" "$(_cco_warn_capture_count)" "an unwritable buffer counts 0 rather than failing"
    unset _CCO_WARN_LOG
}
