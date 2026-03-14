#!/usr/bin/env bash
# Migration: Separate memory from claude-state for vault tracking
#
# Memory files (MEMORY.md, topic files) were previously stored inside
# claude-state/memory/ which is gitignored. This migration copies them
# to a standalone projects/<name>/memory/ directory that is vault-tracked.
# The old claude-state/memory/ is kept as fallback (shadowed by mount).

MIGRATION_ID=8
MIGRATION_DESC="Separate memory from claude-state for vault tracking"

# $1 = target directory (e.g. projects/myapp)
# Must be idempotent (safe to run multiple times)
# Return 0 on success, non-zero on failure
migrate() {
    local target_dir="$1"
    local memory_dst="$target_dir/memory"
    local memory_src="$target_dir/claude-state/memory"

    # Already migrated
    [[ -d "$memory_dst" ]] && return 0

    # Move memory from claude-state to project root
    if [[ -d "$memory_src" ]] && [[ -n "$(ls -A "$memory_src" 2>/dev/null)" ]]; then
        cp -r "$memory_src" "$memory_dst"
        # Don't delete source — it will be shadowed by the new mount
        # Keeping it prevents data loss if user runs old cco version
    else
        mkdir -p "$memory_dst"
    fi

    return 0
}
