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

# ── D18 — a warning is printed EXACTLY ONCE ──────────────────────────
# Discriminates against: the shipped-then-amended model, where every warning
# appeared twice — inline at emission and again in the gate's list. The first real
# project rendered 14 warnings as 28 lines.

test_warn_is_not_printed_at_emission_while_captured() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_warn_capture "$tmpdir/state"

    # Unarmed: warn prints, exactly as it always has.
    local off; off=$(warn "a session condition" 2>&1)
    case "$off" in *"a session condition"*) : ;; *) fail "with no capture armed warn must print: $off"; return 1 ;; esac

    # Armed: warn records and says nothing.
    _cco_warn_capture_begin
    local on; on=$(warn "a session condition" 2>&1)
    assert_empty "$on" "while the capture is armed warn must NOT print — the gate's list is the single rendering (D18)"
    assert_equals "1" "$(_cco_warn_capture_count)" "…and it must have been recorded rather than dropped"

    # The flush is where it appears, once.
    local flushed; flushed=$(_cco_warn_flush 2>&1)
    case "$flushed" in *"a session condition"*) : ;; *) fail "the flush must print the deferred warning: $flushed"; return 1 ;; esac
    assert_equals "1" "$(printf '%s\n' "$flushed" | grep -c "a session condition" | tr -d ' ')" \
        "the flush must print it ONCE"

    # And a second flush prints nothing: flushing empties the buffer.
    local again; again=$(_cco_warn_flush 2>&1)
    assert_empty "$again" "a second flush must print nothing — the buffer is emptied by the first"
    _cco_warn_capture_end
}

test_warn_prints_immediately_when_the_record_cannot_be_written() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_warn_capture "$tmpdir/state"

    # THE invariant that makes deferral safe (D18): deferral is conditional on the
    # append succeeding. A capture that cannot be written degrades to the old
    # behaviour instead of destroying the message it was built to deliver.
    export _CCO_WARN_LOG="$tmpdir/no/such/dir/cco-warn.XXXXXX"
    local out; out=$(warn "the message still has to arrive" 2>&1)
    case "$out" in *"the message still has to arrive"*) : ;;
        *) fail "an unwritable buffer must make warn print immediately, not swallow it: $out"; return 1 ;; esac
    unset _CCO_WARN_LOG
}

test_die_flushes_before_the_error() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_warn_capture "$tmpdir/state"

    # A command that fails half-way must not swallow the warnings it deferred. The
    # `die` runs inside $( ), so it terminates only that subshell (FI-62) — which is
    # exactly what makes this testable in-process.
    _cco_warn_capture_begin
    local out
    out=$( warn "deferred before the failure"; die "boom" 2>&1 ) 2>&1 || true
    case "$out" in
        *"deferred before the failure"*) : ;;
        *) fail "die must flush the deferred warnings — an error path that swallows them is the defect this whole unit exists to end: $out"; return 1 ;;
    esac
    # The error belongs LAST, where it is read.
    local w_line e_line
    w_line=$(printf '%s\n' "$out" | grep -n "deferred before the failure" | head -1 | cut -d: -f1)
    e_line=$(printf '%s\n' "$out" | grep -n "boom" | head -1 | cut -d: -f1)
    [[ -n "$w_line" && -n "$e_line" && "$w_line" -lt "$e_line" ]] \
        || fail "the warnings must precede the ✗ (warn line=$w_line, error line=$e_line): $out"
    _cco_warn_capture_end
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

# ═══════════════════════════════════════════════════════════════════════
# U2 — the gate (ADR-0059 D7…D11). Test-plan coverage: T4, T5, T6, T8, T10.
#
# ⚠ WHAT THIS FILE CANNOT REACH, stated rather than implied. The prompt's last
# three lines (`read -r reply < /dev/tty` and the case that reads it) need a
# controlling terminal, and `cco start` / `cco new` are host-only verbs that end in
# `docker compose run`. So the gate is covered in two honest halves:
#   · the RENDERER — pure, no read, no terminal — is exercised directly, the same
#     split `_resolve_reuse_menu` / `_resolve_disambiguate` already use;
#   · PLACEMENT (D7/D8/D9) is asserted statically on the call order, because
#     "after secrets, before the marker" IS the decision, and a run under
#     CCO_NONINTERACTIVE cannot discriminate a misplaced gate from a correct one
#     (neither prompts). Each static probe carries a check that it found what it
#     was looking for — an order assertion over two line numbers that are both
#     zero passes for free.
# The end-to-end abort and the ADR-0058 A2 live check are HOST acceptance steps.
# ═══════════════════════════════════════════════════════════════════════

# Echo <function>'s body from <file>, numbered from 1 within the function.
_wg_fn_body() {
    awk -v want="^$2\\\\(\\\\)" '$0 ~ want { inside=1 } inside { print } inside && /^}/ { exit }' "$1"
}

# Echo the 1-based index of the first line of <body> matching <pattern>, or 0.
# COMMENT LINES ARE SKIPPED — this repo explains its mechanisms in prose right next
# to them, and `_start_launch`'s own comment names `docker compose run` several
# lines before the call, which made a correct order read as a violation.
_wg_line_of() {
    printf '%s\n' "$1" | awk -v pat="$2" '
        { l=$0; sub(/^[ \t]+/, "", l); if (l ~ /^#/) next }
        $0 ~ pat { print NR; found=1; exit }
        END { if (!found) print 0 }'
}

# ── The renderer — the half with content in it ───────────────────────

test_warn_gate_renders_nothing_on_a_clean_run() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_warn_capture "$tmpdir/state"

    _cco_warn_capture_begin
    local out rc=0
    out=$(_cco_warn_gate_render) || rc=$?
    assert_equals "1" "$rc" "no warnings ⇒ the renderer reports nothing to show"
    assert_empty "$out" "a clean start must stay silent — a gate that fires unconditionally reads as 'working'"
    _cco_warn_capture_end
}

test_warn_gate_renders_every_warning_once_in_order() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_warn_capture "$tmpdir/state"

    _cco_warn_capture_begin
    {
        warn "Pack 'core-dev-framework' not resolved — run 'cco resolve'."
        warn "Agent teams: 1 agent definition(s) keep NO return channel."
        warn "Pack 'core-dev-framework' not resolved — run 'cco resolve'."   # second producer
    } 2>/dev/null

    local out rc=0
    out=$(_cco_warn_gate_render) || rc=$?
    assert_equals "0" "$rc" "warnings present ⇒ the renderer has something to show"

    # The header counts DISTINCT warnings — the number the user is about to read.
    case "$out" in
        *"2 warnings for this session"*) : ;;
        *) fail "the header must count the deduplicated warnings, got:"$'\n'"$out"; return 1 ;;
    esac

    # One line per warning, each exactly once. Matched on the message text, not on
    # "⚠ <text>": the badge carries its colour reset between the glyph and the
    # message, so an adjacency pattern silently matches nothing and passes.
    assert_equals "1" "$(printf '%s\n' "$out" | grep -c "Pack 'core-dev-framework' not resolved" | tr -d ' ')" \
        "the duplicate must be listed once, not twice"
    assert_equals "1" "$(printf '%s\n' "$out" | grep -c "Agent teams: 1 agent" | tr -d ' ')" \
        "the second, distinct warning must be listed"
    case "$out" in
        *"Pack 'core-dev-framework'"*"Agent teams"*) : ;;
        *) fail "the list must follow emission order, got:"$'\n'"$out"; return 1 ;;
    esac
    _cco_warn_capture_end
}

test_warn_gate_header_agrees_with_a_single_warning() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_warn_capture "$tmpdir/state"

    _cco_warn_capture_begin
    warn "the only thing wrong with this session" 2>/dev/null
    local out; out=$(_cco_warn_gate_render)
    case "$out" in
        *"1 warning for this session, in 1 area:"*) : ;;
        *) fail "one warning in one area must not be announced as '1 warnings … 1 areas', got:"$'\n'"$out"; return 1 ;;
    esac
    _cco_warn_capture_end
}

# ── D17 — the list is grouped by an area DERIVED from the producer ───
# Discriminates against: a flat list (what shipped and did not survive a real
# project), and against a mapping that silently drops a warning whose producer it
# does not know.

test_warn_gate_groups_by_producer_area() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_warn_capture "$tmpdir/state"

    _cco_warn_capture_begin
    # The producer is recorded, not declared — these are the real file names.
    _cco_warn_capture_append "lib/packs.sh"     "committed rules are shadowed"
    _cco_warn_capture_append "lib/llms.sh"      "2 llms are not installed"
    _cco_warn_capture_append "lib/reminders.sh" "~/.cco has uncommitted changes"
    _cco_warn_capture_append "lib/packs.sh"     "committed .claude/packs/ is reserved"

    local out; out=$(_cco_warn_gate_render)
    case "$out" in
        *"3 areas"*) : ;;
        *) fail "four warnings from three producers must render as three areas, got:"$'\n'"$out"; return 1 ;;
    esac
    case "$out" in
        *"packs & overlays (2)"*) : ;;
        *) fail "the two lib/packs.sh warnings must be grouped and counted together, got:"$'\n'"$out"; return 1 ;;
    esac
    # Declared order, so two runs of the same project read the same way: packs
    # before llms before config hygiene, whatever order they were emitted in.
    case "$out" in
        *"packs & overlays"*"documentation / llms"*"config hygiene"*) : ;;
        *) fail "areas must render in the declared order, got:"$'\n'"$out"; return 1 ;;
    esac
    _cco_warn_capture_end
}

test_warn_from_an_unmapped_producer_still_appears() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_warn_capture "$tmpdir/state"

    # THE property that makes the file→area table admissible at all (D17/P2): it is
    # a maintained list, and a file missing from it may cost a LABEL, never the
    # warning. A gating list would cost the guarantee — which is why there isn't one.
    _cco_warn_capture_begin
    _cco_warn_capture_append "lib/a-module-invented-tomorrow.sh" "something is wrong with this session"

    assert_equals "1" "$(_cco_warn_capture_count)" "an unmapped producer's warning is still counted"
    local out; out=$(_cco_warn_gate_render)
    case "$out" in
        *"other (1)"*"something is wrong with this session"*) : ;;
        *) fail "an unmapped producer must fall through to 'other' with its warning intact, got:"$'\n'"$out"; return 1 ;;
    esac
    _cco_warn_capture_end
}

test_warn_gate_renders_the_remedy_column() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_warn_capture "$tmpdir/state"

    _cco_warn_capture_begin
    _cco_warn_capture_append "lib/reminders.sh" "project repos have divergent .cco → cco sync"
    _cco_warn_capture_append "lib/reminders.sh" "nothing to suggest here"

    local out; out=$(_cco_warn_gate_render | sed 's/\x1b\[[0-9;]*m//g')
    case "$out" in
        *"project repos have divergent .cco"*"→ cco sync"*) : ;;
        *) fail "a ' → remedy' suffix must survive into the rendering, got:"$'\n'"$out"; return 1 ;;
    esac
    # No arrow, no column — the convention degrades instead of demanding adoption.
    case "$out" in
        *"nothing to suggest here"*) : ;;
        *) fail "a message with no remedy must render plainly, got:"$'\n'"$out"; return 1 ;;
    esac
    _cco_warn_capture_end
}

# ── T4 — no controlling terminal ⇒ no prompt, the launch proceeds ────
# Discriminates against: the suite-hanging prompt. A question whose text a
# capturing caller swallowed still blocks on /dev/tty — silent and unattributable.

test_warn_gate_is_silent_and_proceeds_without_a_tty() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_warn_capture "$tmpdir/state"

    _cco_warn_capture_begin
    warn "a condition worth gating on" 2>/dev/null

    # bin/test exports CCO_NONINTERACTIVE=1, which is precisely "behave as if no
    # terminal existed" — the same branch CI and Docker take.
    local out rc=0
    out=$(_cco_warn_gate 2>&1) || rc=$?
    assert_equals "0" "$rc" "no terminal ⇒ the launch proceeds exactly as today"
    assert_empty "$out" "no terminal ⇒ not one byte of prompt (a captured run must not change)"

    # Prove the oracle discriminates: the silence above is the TTY gate, not an
    # empty buffer. The renderer — the same data the prompt would print — is full.
    local menu; menu=$(_cco_warn_gate_render)
    case "$menu" in
        *"a condition worth gating on"*) : ;;
        *) fail "the buffer was empty, so T4 proved nothing about the tty gate"; return 1 ;;
    esac
    _cco_warn_capture_end
}

# ── T8 — a malformed secrets.env line reaches the buffer ─────────────
# Discriminates against: a gate placed before secrets loading (D7). This is the
# dynamic half — the message must be capturable at all; the placement probe below
# proves the gate sits downstream of the call that emits it.

test_secrets_warning_is_captured() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _source_warn_capture "$tmpdir/state"
    source "$REPO_ROOT/lib/secrets.sh"

    printf 'GOOD=value\nthis line has no equals sign\n' > "$tmpdir/secrets.env"
    local run_env=()
    _cco_warn_capture_begin
    load_secrets_file run_env "$tmpdir/secrets.env" 2>/dev/null

    assert_equals "1" "$(_cco_warn_capture_count)" "the malformed line must be captured"
    case "$(_cco_warn_capture_list)" in
        *"secrets.env:2: skipping malformed line"*) : ;;
        *) fail "expected the malformed-line warning in the buffer, got: $(_cco_warn_capture_list)"; return 1 ;;
    esac
    # The good line still loaded — the warning is about line 2 only.
    assert_equals "2" "${#run_env[@]}" "the well-formed secret must still be loaded"
    _cco_warn_capture_end
}

# ── T5 + T8 (placement) — after secrets, before the marker ───────────
# Discriminates against: a gate placed after `_cco_running_mark` (an abort would
# leave a registry entry with no container to reap) or before secrets are loaded
# (it would miss the warnings emitted last of all).

test_warn_gate_sits_after_secrets_and_before_the_marker() {
    local body; body=$(_wg_fn_body "$REPO_ROOT/lib/cmd-start.sh" "_start_launch")
    local secrets gate mark run
    secrets=$(_wg_line_of "$body" "load_secrets_file")
    gate=$(_wg_line_of "$body" "_cco_warn_gate")
    mark=$(_wg_line_of "$body" "_cco_running_mark")
    run=$(_wg_line_of "$body" "docker compose")

    # The probe must have found all four, or every order assertion below passes for
    # free on a body of zeroes.
    [[ "$secrets" -gt 0 && "$gate" -gt 0 && "$mark" -gt 0 && "$run" -gt 0 ]] \
        || { fail "the placement probe did not find its four anchors in _start_launch (secrets=$secrets gate=$gate mark=$mark run=$run) — it would have passed vacuously"; return 1; }

    [[ "$secrets" -lt "$gate" ]] \
        || { fail "D7: the gate must run AFTER load_secrets_file — secrets warn last of all (lib/secrets.sh), so an earlier gate silently misses them"; return 1; }
    [[ "$gate" -lt "$mark" ]] \
        || { fail "D7: the gate must run BEFORE _cco_running_mark — an abort must leave no running-registry entry to reap"; return 1; }
    [[ "$mark" -lt "$run" ]] \
        || { fail "the marker must still precede the container run"; return 1; }
}

# ── T6 — --dry-run does not gate (D8) ────────────────────────────────
# Discriminates against: a gate in `cmd_start` instead of `_start_launch`, which
# would prompt on the inspection path too. A run under CCO_NONINTERACTIVE cannot
# tell the two apart (neither prompts), so this is asserted where the difference
# actually lives — the call sites.

test_warn_gate_is_reached_only_through_the_two_launch_paths() {
    # Exactly two call sites in the whole library, and both are launches.
    local sites; sites=$(grep -rn '^[^#]*_cco_warn_gate\b' "$REPO_ROOT"/lib/*.sh \
        | grep -v 'lib/utils.sh' | sed "s|.*/lib/|lib/|" | cut -d: -f1 | sort -u)
    assert_equals "lib/cmd-new.sh
lib/cmd-start.sh" "$sites" "the gate must be called from the two launch paths and nowhere else (a call in cmd_start itself would gate --dry-run too — D8)"

    # And in cmd-start.sh it is inside _start_launch, not in cmd_start's own body.
    local cs; cs=$(_wg_fn_body "$REPO_ROOT/lib/cmd-start.sh" "cmd_start")
    assert_empty "$(printf '%s\n' "$cs" | grep -n '^[^#]*_cco_warn_gate\b' || true)" \
        "D8: cmd_start must not gate — the dry-run branch returns from there"

    # Discrimination: the extractor really did read cmd_start's body.
    case "$cs" in
        *"_start_launch"*) : ;;
        *) fail "the cmd_start probe extracted nothing recognisable — it would have passed vacuously"; return 1 ;;
    esac

    # The dry-run branch returns before the launch, which is what makes D8 true.
    local dr lau
    dr=$(_wg_line_of "$cs" 'if \$dry_run; then')
    lau=$(_wg_line_of "$cs" '_start_launch')
    [[ "$dr" -gt 0 && "$lau" -gt 0 && "$dr" -lt "$lau" ]] \
        || { fail "the dry-run branch must return before _start_launch (dry_run=$dr launch=$lau)"; return 1; }
}

# ── T10 — `cco new` gates identically (D9) ───────────────────────────
# Discriminates against: a fix applied to one launch path of two — the exact shape
# this repo has paid for repeatedly, and the reason D9 pulled `cco new` in.

test_cco_new_gates_through_the_same_implementation() {
    # ONE implementation. A second definition would drift from the first in a way
    # that is invisible from either side.
    local defs; defs=$(grep -rn '^_cco_warn_gate()' "$REPO_ROOT"/lib/*.sh | wc -l | tr -d ' ')
    assert_equals "1" "$defs" "_cco_warn_gate must be defined exactly once — two copies is how the twin verb keeps the defect"

    local body; body=$(_wg_fn_body "$REPO_ROOT/lib/cmd-new.sh" "cmd_new")
    local begin gate run
    begin=$(_wg_line_of "$body" "_cco_warn_capture_begin")
    gate=$(_wg_line_of "$body" "_cco_warn_gate")
    run=$(_wg_line_of "$body" "docker compose")
    [[ "$begin" -gt 0 && "$gate" -gt 0 && "$run" -gt 0 ]] \
        || { fail "cco new must arm the capture and gate before it launches (begin=$begin gate=$gate run=$run)"; return 1; }
    [[ "$begin" -lt "$gate" && "$gate" -lt "$run" ]] \
        || { fail "D9: cco new must arm, then gate, then run (begin=$begin gate=$gate run=$run)"; return 1; }

    # ⚠ cco new installs its own EXIT trap, which REPLACES bin/cco's sentinel trap —
    # so the buffer cannot rely on a trap of its own and must be swept by that one.
    case "$body" in
        *"rm -rf"*"_cco_warn_capture_end"*) : ;;
        *) fail "cco new's EXIT trap must also sweep the warn buffer (ADR-0059 D9) — it replaces the sentinel trap armed in bin/cco"; return 1 ;;
    esac
}
