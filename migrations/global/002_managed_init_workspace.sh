#!/usr/bin/env bash
# Migration: Move init-workspace skill from user global to managed level

MIGRATION_ID=2
MIGRATION_DESC="Move init-workspace to managed level"

# $1 = target directory (e.g. global/.claude)
# Must be idempotent (safe to run multiple times)
# Return 0 on success, non-zero on failure
migrate() {
    local target_dir="$1"
    [[ -z "$target_dir" ]] && return 1

    # Remove init-workspace from user skills (now managed at /etc/claude-code/.claude/skills/)
    if [[ -d "$target_dir/skills/init-workspace" ]]; then
        rm -rf "$target_dir/skills/init-workspace"
        info "Removed skills/init-workspace/ (now managed — baked in Docker image)"
    fi

    return 0
}
