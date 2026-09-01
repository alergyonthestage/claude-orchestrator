#!/usr/bin/env bash
# lib/colors.sh — Color definitions and output helpers
#
# Provides: RED, GREEN, YELLOW, BLUE, BOLD, NC, info(), ok(), note(), warn(),
#           error(), die() (exit 1 — actual error), refuse() (exit 2 — policy
#           refusal), _cco_exit() (exit <code> — any other DELIBERATE termination),
#           and the message buffer the start-time pause reads
#           (_cco_warn_capture_begin/_list/_count/_end — ADR-0059 D5/D6/A2 D22)
# Dependencies: none
# Globals: _cco_completed (the EXIT-trap sentinel owned by bin/cco),
#          _CCO_WARN_LOG (the capture buffer's path; unset = capture off)

# ── Colors ───────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ── Helpers ──────────────────────────────────────────────────────────
#
# FOUR MESSAGE LEVELS, EXACTLY ONE OF WHICH GATES A LAUNCH (ADR-0059 D2):
#
#   warn  ⚠      a condition of THIS session the user may want to act on before
#                working inside it              → GATES `cco start` / `cco new`
#   note  note:  an accepted divergence or an explanation; nothing is wrong → no gate
#   info/ok      the chronicle of what the command did                      → no gate
#   plain echo   validation feedback INSIDE an interactive prompt the user is
#     … >&2      already reading and answering                              → no gate
#
# The corollary is the whole point and must be applied whenever a message is
# written: IF A MESSAGE MUST NOT STOP THE LAUNCH, IT MUST NOT BE A `warn`. The gate
# has no curated list of "important" warnings (D1/P2) — a `warn` written years from
# now gates on the day it is written, with nobody remembering ADR-0059.
info()  { echo -e "${BLUE}ℹ${NC} $*" >&2; }
ok()    { echo -e "${GREEN}✓${NC} $*" >&2; }
# `note:` was an idiom before it was a function — five bare `echo "note: …" >&2`
# sites with nothing behind them. D3 makes it real: without a spelling in code, the
# non-gating level exists only in prose and the next author reaches for `warn`
# because it is the only thing that looks like a function.
#
# It is CAPTURED exactly like `warn` (A2 D22). Under D1 a note printed, was never
# recorded, and was overwritten by the TUI seconds later: write-only, which is not a
# level at all — and the next author facing that reaches for `warn` for the very
# reason D3 exists. Deferral is conditional on the append succeeding, same as `warn`.
note()  { _cco_warn_capture_append note "${BASH_SOURCE[1]:-}" "$*" && return 0
          printf 'note: %s\n' "$*" >&2; }
# A warning is printed EXACTLY ONCE (ADR-0059 A1/D18). While the capture is armed
# `warn` only records — the organized list at the gate is the single rendering. If
# the record cannot be written, it prints here and now: deferral is conditional on
# the append SUCCEEDING, so a broken capture degrades to the old behaviour instead
# of eating the message.
#
# ${BASH_SOURCE[1]} is the file that called `warn` — read here, in warn's own frame,
# and correct inside a command substitution too (measured). It is what the gate
# groups by (D17), derived rather than declared, so no call site carries a tag.
warn()  { _cco_warn_capture_append warn "${BASH_SOURCE[1]:-}" "$*" && return 0
          echo -e "${YELLOW}⚠${NC} $*" >&2; }
error() { echo -e "${RED}✗${NC} $*" >&2; }

# ── The warn-capture buffer (ADR-0059 D5/D6) ─────────────────────────
#
# `warn` is the one level that gates a launch, so the gate needs the set of
# warnings a run actually emitted. `warn` is instrumented HERE, beside the emitter,
# so there is a single producer and no second warning function to keep in step.
#
# WHY A FILE AND NOT A SHELL ARRAY — measured, not preferred. Production `warn`s
# run inside command substitution: `ro=$(_parse_bool …)` (lib/local-paths.sh:312 →
# lib/yaml.sh:118) and `resolved=$(_prompt_for_path …)` (lib/local-paths.sh:474,
# :497). Those execute in a SUBSHELL, and an array append dies with it. The array
# version works everywhere EXCEPT the interactive surface — which is what makes it
# dangerous rather than merely wrong. Same class as the die-inside-$( ) defect
# (FI-62), already paid for once live and once latent.
#
# WHERE — `${TMPDIR:-/tmp}` through an mktemp TEMPLATE, the spelling BSD and GNU
# agree on (lib/sync-meta.sh is the precedent; the bare `mktemp` form is GNU-only).
# NEVER STATE/DATA/CACHE: ADR-0047's INV-S1 forbids code outside lib/store.sh from
# mutating OR PREDICATING a confined path, and a warning buffer does not justify a
# store-op crossing.
#
# The capture is OPT-IN and FAIL-SOFT: with `$_CCO_WARN_LOG` unset every helper is a
# no-op and `warn` behaves exactly as it always did; if the buffer cannot be created
# or written, the warning is still printed. A capture problem must never turn a
# warning into an error — that would trade the message for the mechanism meant to
# deliver it.

# Create the buffer and export its path. Idempotent: a second call on a live buffer
# is a no-op. ALWAYS returns 0 — a caller runs under `set -e`, and failing to arm an
# advisory capture must not abort the verb it was arming.
_cco_warn_capture_begin() {
    [[ -n "${_CCO_WARN_LOG:-}" && -f "${_CCO_WARN_LOG:-}" ]] && return 0
    local _f
    _f=$(mktemp "${TMPDIR:-/tmp}/cco-warn.XXXXXX" 2>/dev/null) || return 0
    export _CCO_WARN_LOG="$_f"
    return 0
}

# Append one record: "<level>\t<producer-file>\t<message>". Called by `warn` and
# `note` only — they are the two levels the pause renders (A2 D22).
#
# Returns 0 ONLY when the record was written — that status is what `warn`/`note`
# read to decide whether they may defer printing (D18). Newlines are folded to
# spaces so one message is always one record; otherwise a multi-line message would
# be counted, and listed, as several.
_cco_warn_capture_append() {
    [[ -n "${_CCO_WARN_LOG:-}" ]] || return 1
    [[ -w "$_CCO_WARN_LOG" ]] || return 1
    local _lvl="$1"; shift
    local _src="${1##*/}"; shift
    local _m="$*"
    _m="${_m//$'\n'/ }"
    printf '%s\t%s\t%s\n' "${_lvl:-warn}" "${_src:-other}" "$_m" >> "$_CCO_WARN_LOG" 2>/dev/null || return 1
    return 0
}

# Map a producing FILE to the area the gate groups it under (ADR-0059 D17).
#
# ⚠ This is a maintained list, and it is admissible HERE precisely where a gating
# list was not (P2). A file missing from it falls through to `other`: its warning is
# still shown, still counted, still gates. The list can only ever cost a LABEL. That
# is the whole difference from a curated list of "important" warnings, which would
# cost the guarantee — and the reason the AREA is derived from BASH_SOURCE rather
# than tagged at ~130 call sites, where forgetting one is the normal outcome.
_cco_warn_area() {
    case "$1" in
        packs.sh|cmd-pack.sh|session-context.sh)           printf 'packs & overlays' ;;
        reminders.sh|cmd-config.sh|cmd-sync.sh|cmd-project-save.sh) printf 'config hygiene' ;;
        llms.sh|cmd-llms.sh)                               printf 'documentation / llms' ;;
        agents.sh)                                         printf 'agent teams' ;;
        index.sh|local-paths.sh|cmd-resolve.sh|paths.sh)   printf 'paths & index' ;;
        secrets.sh|auth.sh)                                printf 'auth & secrets' ;;
        yaml.sh)                                           printf 'project.yml' ;;
        cmd-start.sh|cmd-new.sh|cmd-chrome.sh)             printf 'session' ;;
        update*.sh|migrate.sh|cmd-update.sh|cmd-build.sh)  printf 'updates' ;;
        *)                                                 printf 'other' ;;
    esac
}

# The declared render order. Fixed, so two runs of the same project read the same
# way — an order that follows cco's internal pipeline is arbitrary to the reader.
_CCO_WARN_AREAS='project.yml
session
paths & index
packs & overlays
documentation / llms
agent teams
auth & secrets
config hygiene
updates
other'

# Emit "<level>\t<area>\t<message>" per DISTINCT message, in emission order.
# With a <level> argument (warn|note) only that level's records are emitted.
#
# Deduplicated on the MESSAGE alone: one condition can have two producers
# (lib/packs.sh and lib/session-context.sh emit the same sentence), and listing it
# twice reads as two problems. The first occurrence's level and area win — which is
# also why the dedup runs BEFORE the level filter: a sentence emitted once as a
# `warn` and once as a `note` is one condition, and it is the warning that stands.
_cco_warn_capture_records() {
    [[ -n "${_CCO_WARN_LOG:-}" && -f "${_CCO_WARN_LOG:-}" ]] || return 0
    local _want="${1:-}" _ln _lvl _src _msg
    while IFS= read -r _ln; do
        [[ -z "$_ln" ]] && continue
        _lvl="${_ln%%$'\t'*}"; _ln="${_ln#*$'\t'}"
        _src="${_ln%%$'\t'*}"; _msg="${_ln#*$'\t'}"
        [[ -n "$_want" && "$_lvl" != "$_want" ]] && continue
        printf '%s\t%s\t%s\n' "$_lvl" "$(_cco_warn_area "$_src")" "$_msg"
    done < <(awk '{ m=$0; sub(/^[^\t]*\t[^\t]*\t/, "", m) } !_cco_seen[m]++' "$_CCO_WARN_LOG")
}

# The captured messages, in order, deduplicated — the plain list, no level, no
# areas. Optional <level> filter, as above.
_cco_warn_capture_list() {
    _cco_warn_capture_records "${1:-}" | while IFS= read -r _r; do
        _r="${_r#*$'\t'}"; printf '%s\n' "${_r#*$'\t'}"
    done
}

# How many DISTINCT messages were captured, optionally at one <level> only.
# Counted with awk, never `wc -l`: BSD `wc` pads its output with spaces, so
# `[[ "$n" == "0" ]]` fails on macOS against a count that is genuinely zero.
_cco_warn_capture_count() {
    if [[ -z "${_CCO_WARN_LOG:-}" || ! -f "${_CCO_WARN_LOG:-}" ]]; then
        printf '0\n'
        return 0
    fi
    awk -v want="${1:-}" '
        { m=$0; sub(/^[^\t]*\t[^\t]*\t/, "", m); l=$0; sub(/\t.*/, "", l) }
        !_cco_seen[m]++ && (want == "" || l == want) { n++ }
        END { print n+0 }' "$_CCO_WARN_LOG"
}

# Render the captured messages to STDOUT, grouped by area, with a count per group
# (ADR-0059 D17). PURE — no read, no prompt, no terminal — so the half with content
# in it is unit-testable, the split _resolve_reuse_menu/_resolve_disambiguate
# already use. Exit: 0 = something rendered, 1 = nothing captured.
#
# ⚠ The badge lines are raw `echo`s and NOT `warn` calls: `warn` appends to the
# buffer, so rendering the list through it would grow the list it is rendering. The
# declared-legitimate side of the INV-WG2 limit — a report line, not a producer.
#
# A message may end in " → <remedy>"; the remedy is aligned into its own column when
# the line fits and dropped to an indented line when it does not. No arrow means no
# column — the convention degrades to plain text instead of requiring every message
# to adopt it.
# Print <text> after <prefix>, wrapped on word boundaries with the continuation
# lines hung under the first (ADR-0059 A1). An aggregated warning naming five files
# is long by construction, and a 250-column line reflowed by the terminal at column
# 0 destroys the list structure the grouping just built. A fixed width, not
# $COLUMNS: that variable is not exported to a script, so reading it would silently
# mean "80" everywhere and pretend to be adaptive.
_cco_warn_wrap() {
    local text="$1" pre="$2" width="${3:-88}" _first=1 _l
    while IFS= read -r _l; do
        if [[ $_first -eq 1 ]]; then printf '%s%s\n' "$pre" "$_l"; _first=0
        else printf '%*s%s\n' ${#pre} '' "$_l"; fi
    done < <(printf '%s\n' "$text" | fold -s -w "$width" 2>/dev/null || printf '%s\n' "$text")
}

# One level's section: the header line, then the groups. $1 = warn | note.
# Exit: 0 = rendered, 1 = nothing captured at that level.
_cco_warn_render_section() {
    local lvl="$1"
    local recs; recs=$(_cco_warn_capture_records "$lvl" | cut -f2-)
    [[ -n "$recs" ]] || return 1
    local n; n=$(printf '%s\n' "$recs" | grep -c .)
    local areas; areas=$(printf '%s\n' "$recs" | cut -f1 | awk '!s[$0]++')
    local na; na=$(printf '%s\n' "$areas" | grep -c .)

    local alabel="areas"; [[ "$na" -eq 1 ]] && alabel="area"
    local wlabel head_line
    if [[ "$lvl" == "note" ]]; then
        wlabel="notes"; [[ "$n" -eq 1 ]] && wlabel="note"
        head_line="${BOLD}note:${NC} ${n} ${wlabel} for this session, in ${na} ${alabel}:"
    else
        wlabel="warnings"; [[ "$n" -eq 1 ]] && wlabel="warning"
        head_line="${YELLOW}⚠${NC} ${n} ${wlabel} for this session, in ${na} ${alabel}:"
    fi
    echo ""
    echo -e "$head_line"

    local area line msg head rem cnt rule pad
    while IFS= read -r area; do
        [[ -z "$area" ]] && continue
        printf '%s\n' "$areas" | grep -qxF "$area" || continue
        cnt=$(printf '%s\n' "$recs" | cut -f1 | grep -cxF "$area")
        # A fixed-width rule keeps the group headers scannable as a column of their
        # own, whatever the messages under them do.
        rule=$(printf '%*s' $(( 52 - ${#area} )) ''); rule="${rule// /─}"
        echo ""
        echo -e "  ${BOLD}── ${area} (${cnt})${NC} ${rule}"
        while IFS= read -r line; do
            [[ "${line%%$'\t'*}" == "$area" ]] || continue
            msg="${line#*$'\t'}"
            head="$msg"; rem=""
            [[ "$msg" == *" → "* ]] && { head="${msg% → *}"; rem="${msg##* → }"; }
            if [[ -n "$rem" && ${#head} -le 44 ]]; then
                pad=$(printf '%*s' $(( 45 - ${#head} )) '')
                echo -e "   · ${head}${pad}${BLUE}→ ${rem}${NC}"
            else
                _cco_warn_wrap "$head" "   · "
                [[ -n "$rem" ]] && echo -e "     ${BLUE}→ ${rem}${NC}"
            fi
        done <<< "$recs"
    done <<< "$_CCO_WARN_AREAS"
    return 0
}

# Warnings first, then notes (A2 D22). Two sections, never one merged list: what
# the reader must decide about and what cco already settled are different
# questions, and the badge is the only thing that says which is which.
_cco_warn_gate_render() {
    local _any=1
    _cco_warn_render_section warn && _any=0
    _cco_warn_render_section note && _any=0
    return $_any
}

# Render the captured messages to STDERR and EMPTY the buffer (ADR-0059 D18). This
# is the single print: the buffer is flushed by the first of the pause, capture_end,
# or an exit primitive, and emptying it means a second flush prints nothing while a
# message raised afterwards is still captured and still shown.
_cco_warn_flush() {
    local out; out=$(_cco_warn_gate_render) || return 0
    # A trailing blank line, explicitly: `$( )` strips the renderer's own, and
    # without it the pause's question sits flush against the last message.
    printf '%s\n\n' "$out" >&2
    : > "$_CCO_WARN_LOG" 2>/dev/null || true
    return 0
}

# Flush, then remove the buffer and disarm the capture. Cleanup is EXPLICIT at the
# verb's exit paths, never an EXIT trap alone: `cco new` installs its own trap
# (lib/cmd-new.sh) which REPLACES bin/cco's sentinel trap (ADR-0059 D9).
#
# It FLUSHES because it is the last chance: on a headless run, a `--dry-run` or an
# abort no gate ever renders, and warnings that were deferred and never printed
# would be warnings destroyed by the mechanism built to deliver them.
_cco_warn_capture_end() {
    [[ -n "${_CCO_WARN_LOG:-}" ]] || return 0
    _cco_warn_flush
    rm -f "$_CCO_WARN_LOG" 2>/dev/null || true
    unset _CCO_WARN_LOG
    return 0
}
# `die` flushes BEFORE the ✗: a command that fails half-way must not swallow the
# warnings it had already deferred, and the error belongs last, where it is read.
die()   { _cco_warn_flush; error "$@"; _cco_completed=true; exit 1; }
# Policy refusal (D8/ADR-0043 exit-code convention): the request is well-formed but
# denied by access scope, host-only status, a removed alias, or a bare namespace.
# Distinct exit 2 so callers/tests can tell "refused by policy" (retry with wider
# access / on the host) from an actual error (exit 1: unknown verb, missing file,
# parse). Graceful degrade (scope-filtered output) stays exit 0 with a notice.
refuse() { _cco_warn_flush; error "$@"; _cco_completed=true; exit 2; }

# ── The EXIT-trap sentinel discipline (INV-EXIT, cycle-1.2 S5 / R-G) ──
#
# bin/cco arms an EXIT trap that prints "✗ cco exited unexpectedly (exit N)"
# unless `_cco_completed` is true. Its job is to surface real crashes — a `set -e`
# / `set -u` violation or a syntax error, which exit with no diagnostic of their
# own. It must NEVER fire on a run that terminated deliberately, because an ✗ on a
# correct exit is both a lie and a mask: once users learn to ignore it, the real
# crash it exists to catch reads as noise. (S2 established the mirror rule — a ✓
# must not survive a failure; this is the same rule read backwards.)
#
# `_cco_exit <code>` is the ONE spelling for a deliberate termination that is
# neither an error (`die`) nor a policy refusal (`refuse`): group help, --version,
# normal completion, and — the arm-2 case below — propagating a status out of a
# helper that already printed its own diagnostic.
#
# WHY propagation needs it. `die`/`refuse` set the sentinel themselves, but only
# in the shell that runs them. Called inside a command substitution they run in a
# SUBSHELL, so the assignment dies with it: `x=$(_cco_resolve_access …) || exit $?`
# left the PARENT's sentinel false, and a well-formed INV-2 refusal for a mistyped
# `--cco-access` — the ordinary user path — came out with "✗ cco exited
# unexpectedly (exit 1)" glued to it. `|| _cco_exit $?` sets the sentinel in the
# parent, where the trap will read it.
#
# INVARIANT: outside this file there is NO raw shell `exit`. Every deliberate
# termination goes through die / refuse / _cco_exit; a raw one is either a crash
# path (correct — let the trap speak) or a bug. Enforced statically by
# `test_invariant_exit_sentinel_discipline` in tests/test_invariants.sh, which
# records the one allowlisted subshell-local exit and its reason.
_cco_exit() { _cco_warn_flush; _cco_completed=true; exit "${1:-0}"; }
