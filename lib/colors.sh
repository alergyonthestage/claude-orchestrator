#!/usr/bin/env bash
# lib/colors.sh — Color definitions and output helpers
#
# Provides: RED, GREEN, YELLOW, BLUE, BOLD, NC, info(), ok(), warn(), error(),
#           die() (exit 1 — actual error), refuse() (exit 2 — policy refusal)
# Dependencies: none
# Globals: none

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
