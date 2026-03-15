#!/usr/bin/env bash
# Migration: Initialize .cco-base for pre-Sprint-5b global config
#
# Global configs initialized before Sprint 5b have .cco-meta (from init)
# but no .cco-base/ directory. Without .cco-base/, the 3-way merge
# falls back to interactive mode. This migration creates .cco-base/
# retroactively so subsequent updates can auto-merge.

MIGRATION_ID=7
MIGRATION_DESC="Initialize .cco-base for 3-way merge support"

# $1 = target directory (e.g. global/.claude)
# Must be idempotent (safe to run multiple times)
# Return 0 on success, non-zero on failure
migrate() {
    local target_dir="$1"
    local base_dir
    local defaults_dir="$DEFAULTS_DIR/global/.claude"

    # Post-consolidation path (.cco/base/) takes priority
    if [[ -d "$target_dir/.cco/base" ]]; then
        return 0
    fi

    # Pre-consolidation path (.cco-base/) — migration 009 will move it later
    local base_dir="$target_dir/.cco-base"
    [[ -d "$base_dir" ]] && return 0

    # Save current defaults as base versions for future 3-way merge.
    # Create at .cco/base/ directly if .cco/ dir exists (post-009),
    # otherwise at .cco-base/ (pre-009, will be moved by 009).
    if [[ -d "$target_dir/.cco" ]]; then
        base_dir="$target_dir/.cco/base"
    fi
    _save_all_base_versions "$base_dir" "$defaults_dir" "global"

    return 0
}
