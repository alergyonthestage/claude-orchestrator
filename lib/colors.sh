#!/usr/bin/env bash
# lib/colors.sh — Color definitions and output helpers
#
# Provides: RED, GREEN, YELLOW, BLUE, BOLD, NC, info(), ok(), warn(), error(),
#           die() (exit 1 — actual error), refuse() (exit 2 — policy refusal),
#           _cco_exit() (exit <code> — any other DELIBERATE termination)
# Dependencies: none
# Globals: _cco_completed (the EXIT-trap sentinel owned by bin/cco)

# ── Colors ───────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ── Helpers ──────────────────────────────────────────────────────────
info()  { echo -e "${BLUE}ℹ${NC} $*" >&2; }
ok()    { echo -e "${GREEN}✓${NC} $*" >&2; }
warn()  { echo -e "${YELLOW}⚠${NC} $*" >&2; }
error() { echo -e "${RED}✗${NC} $*" >&2; }
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
