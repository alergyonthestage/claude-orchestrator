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
    # target_dir is .claude/ — .cco-base is inside .claude/ (sibling to settings.json etc.)
    base_dir="$target_dir/.cco-base"
    local defaults_dir="$DEFAULTS_DIR/global/.claude"

    # If .cco-base/ already exists, nothing to do
    [[ -d "$base_dir" ]] && return 0

    # Save current defaults as base versions for future 3-way merge
    _save_all_base_versions "$base_dir" "$defaults_dir" "global"

    return 0
}
