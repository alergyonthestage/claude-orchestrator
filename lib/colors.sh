#!/usr/bin/env bash
# lib/colors.sh — Color definitions and output helpers
#
# Provides: RED, GREEN, YELLOW, BLUE, BOLD, NC, info(), ok(), warn(), error(), die()
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
