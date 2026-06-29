#!/usr/bin/env bash
# Migration 015: flatten the global config home (ADR-0028).
#
# Moves the global Claude config from the vault-era nested location
# ~/.cco/global/.claude to the flat ~/.cco/.claude. ~/.cco is already the global
# config scope, so the `global/` wrapper is redundant; this drops it. Only the
# user-store destination changes — the shipped source `defaults/global/.claude/`
# is unaffected.
#
# The actual move is `_cco_flatten_global_claude` (lib/migrate.sh) — the SAME
# helper the dispatch-time bootstrap (`_cco_first_run`) calls on every command, so
# a pre-flatten layout self-heals even before this migration's schema gate runs.
# This migration is the schema-version record (14 → 15) of that breaking change.
# Idempotent; never clobbers a populated flat dir.

MIGRATION_ID=15
MIGRATION_DESC="Flatten global config home: ~/.cco/global/.claude -> ~/.cco/.claude"

# $1 = the (new) flat global .claude dir, ~/.cco/.claude. Its parent is the config
# home (~/.cco); pass it to the shared helper so no resolver call is needed (the
# helper stays usable from this sourced-in-a-subshell migration and from tests).
migrate() {
    _cco_flatten_global_claude "$(dirname "$1")"
}
