#!/usr/bin/env bash
# lib/colors.sh — Color definitions and output helpers
#
# Provides: RED, GREEN, YELLOW, BLUE, BOLD, NC, info(), ok(), note(), warn(),
#           error(), die() (exit 1 — actual error), refuse() (exit 2 — policy
#           refusal), _cco_exit() (exit <code> — any other DELIBERATE termination),
#           and the warn-capture buffer the start-time gate reads
#           (_cco_warn_capture_begin/_list/_count/_end — ADR-0059 D5/D6)
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
note()  { printf 'note: %s\n' "$*" >&2; }
warn()  { echo -e "${YELLOW}⚠${NC} $*" >&2; _cco_warn_capture_append "$*"; }
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

# Append one message. Called by `warn` only. Newlines are folded to spaces so one
# warning is always one record — otherwise a multi-line message would be counted,
# and listed, as several.
_cco_warn_capture_append() {
    [[ -n "${_CCO_WARN_LOG:-}" ]] || return 0
    [[ -w "$_CCO_WARN_LOG" ]] || return 0
    local _m="$*"
    _m="${_m//$'\n'/ }"
    printf '%s\n' "$_m" >> "$_CCO_WARN_LOG" 2>/dev/null || true
    return 0
}

# The captured messages, in emission order, DEDUPLICATED on exact text: one
# condition can have two producers (lib/packs.sh:167 and lib/session-context.sh:38
# emit the same sentence), and listing it twice reads as two problems.
_cco_warn_capture_list() {
    [[ -n "${_CCO_WARN_LOG:-}" && -f "${_CCO_WARN_LOG:-}" ]] || return 0
    awk '!_cco_seen[$0]++' "$_CCO_WARN_LOG"
}

# How many DISTINCT messages were captured. Counted with awk, never `wc -l`: BSD
# `wc` pads its output with spaces, so `[[ "$n" == "0" ]]` fails on macOS against a
# count that is genuinely zero.
_cco_warn_capture_count() {
    if [[ -z "${_CCO_WARN_LOG:-}" || ! -f "${_CCO_WARN_LOG:-}" ]]; then
        printf '0\n'
        return 0
    fi
    awk '!_cco_seen[$0]++ { n++ } END { print n+0 }' "$_CCO_WARN_LOG"
}

# Remove the buffer and disarm the capture. Cleanup is EXPLICIT at the verb's exit
# paths, never an EXIT trap alone: `cco new` installs its own trap
# (lib/cmd-new.sh:75) which REPLACES bin/cco's sentinel trap (ADR-0059 D9). A file
# left behind by a hard kill is inert — an unread list of strings in $TMPDIR.
_cco_warn_capture_end() {
    [[ -n "${_CCO_WARN_LOG:-}" ]] || return 0
    rm -f "$_CCO_WARN_LOG" 2>/dev/null || true
    unset _CCO_WARN_LOG
    return 0
}
die()   { error "$@"; _cco_completed=true; exit 1; }
# Policy refusal (D8/ADR-0043 exit-code convention): the request is well-formed but
# denied by access scope, host-only status, a removed alias, or a bare namespace.
# Distinct exit 2 so callers/tests can tell "refused by policy" (retry with wider
# access / on the host) from an actual error (exit 1: unknown verb, missing file,
# parse). Graceful degrade (scope-filtered output) stays exit 0 with a notice.
refuse() { error "$@"; _cco_completed=true; exit 2; }

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
_cco_exit() { _cco_completed=true; exit "${1:-0}"; }
