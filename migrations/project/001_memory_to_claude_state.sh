#!/usr/bin/env bash
# Migration: Migrate legacy memory/ directory to claude-state/memory/

MIGRATION_ID=1
MIGRATION_DESC="Migrate memory to claude-state"

# $1 = target directory (e.g. projects/myapp)
# Must be idempotent (safe to run multiple times)
# Return 0 on success, non-zero on failure
migrate() {
    local target_dir="$1"

    # Move legacy memory/ to claude-state/memory/ if needed
    if [[ -d "$target_dir/memory" && ! -d "$target_dir/claude-state" ]]; then
        info "Migrating $target_dir/memory → claude-state/memory"
        mkdir -p "$target_dir/claude-state"
        mv "$target_dir/memory" "$target_dir/claude-state/memory"
    fi

    # Ensure claude-state/memory/ exists
    mkdir -p "$target_dir/claude-state/memory"

    return 0
}
