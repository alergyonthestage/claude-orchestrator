#!/usr/bin/env bash
# Migration: Clean up residual old-format files + fix base files with unresolved placeholders
#
# Two issues fixed:
# 1. Bug in migration engine caused schema_version not to persist after migration 009,
#    leading to stale .cco-meta being recreated alongside .cco/meta.
# 2. Migration 007 saved raw template content (with {{PROJECT_NAME}}) into .cco/base/
#    instead of interpolated values, causing false diffs on cco update.

MIGRATION_ID=11
MIGRATION_DESC="Clean up residual old-format files and fix base placeholders"

# $1 = target directory (e.g. projects/myapp)
migrate() {
    local target_dir="$1"

    # ── Part 1: Remove residual old-format files if new equivalents exist ──

    # .cco-meta → .cco/meta
    if [[ -f "$target_dir/.cco/meta" && -f "$target_dir/.cco-meta" ]]; then
        rm -f "$target_dir/.cco-meta"
    fi

    # .cco-base/ → .cco/base/
    if [[ -d "$target_dir/.cco/base" && -d "$target_dir/.cco-base" ]]; then
        rm -rf "$target_dir/.cco-base"
    fi

    # .managed/ → .cco/managed/
    if [[ -d "$target_dir/.cco/managed" && -d "$target_dir/.managed" ]]; then
        rm -rf "$target_dir/.managed"
    fi

    # docker-compose.yml → .cco/docker-compose.yml
    if [[ -f "$target_dir/.cco/docker-compose.yml" && -f "$target_dir/docker-compose.yml" ]]; then
        rm -f "$target_dir/docker-compose.yml"
    fi

    # claude-state/ → .cco/claude-state/
    if [[ -d "$target_dir/.cco/claude-state" && -d "$target_dir/claude-state" ]]; then
        rm -rf "$target_dir/claude-state"
    fi

    # .pack-manifest → .claude/.cco/pack-manifest
    if [[ -f "$target_dir/.claude/.cco/pack-manifest" && -f "$target_dir/.claude/.pack-manifest" ]]; then
        rm -f "$target_dir/.claude/.pack-manifest"
    fi

    # .cco-source → .cco/source (not moved by project 009, but paths.sh has fallback)
    if [[ -f "$target_dir/.cco/source" && -f "$target_dir/.cco-source" ]]; then
        rm -f "$target_dir/.cco-source"
    fi
    # Also handle case where .cco-source exists but was never moved
    if [[ -f "$target_dir/.cco-source" && ! -f "$target_dir/.cco/source" ]]; then
        mkdir -p "$target_dir/.cco"
        mv "$target_dir/.cco-source" "$target_dir/.cco/source"
    fi

    # ── Part 2: Fix base files with unresolved {{PROJECT_NAME}} placeholders ──
    # Migration 007 used _save_all_base_versions with raw template, leaving
    # {{PROJECT_NAME}} and {{DESCRIPTION}} literals in .cco/base/CLAUDE.md.
    # Re-seed any base file that still contains these placeholders.

    local base_dir=""
    if [[ -d "$target_dir/.cco/base" ]]; then
        base_dir="$target_dir/.cco/base"
    elif [[ -d "$target_dir/.cco-base" ]]; then
        base_dir="$target_dir/.cco-base"
    fi

    if [[ -n "$base_dir" ]]; then
        local defaults_dir="$NATIVE_TEMPLATES_DIR/project/base/.claude"
        local entry rel policy
        for entry in "${PROJECT_FILE_POLICIES[@]}"; do
            rel="${entry%:*}"
            policy="${entry##*:}"
            [[ "$policy" != "tracked" ]] && continue
            rel="${rel#.claude/}"
            # Check if base file contains unresolved placeholders
            if [[ -f "$base_dir/$rel" ]] && grep -qF '{{PROJECT_NAME}}' "$base_dir/$rel" 2>/dev/null; then
                _seed_base_from_interpolated_template "$base_dir" "$rel" "$defaults_dir" "$target_dir"
            fi
        done
    fi

    return 0
}
