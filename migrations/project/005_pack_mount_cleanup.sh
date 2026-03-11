#!/usr/bin/env bash
# Migration: Remove legacy copied pack files (now mounted read-only, ADR-14)

MIGRATION_ID=5
MIGRATION_DESC="Remove legacy copied pack files (now mounted read-only)"

# $1 = target directory (e.g. projects/myapp)
# Must be idempotent (safe to run multiple times)
# Return 0 on success, non-zero on failure
migrate() {
    local target_dir="$1"
    local manifest="$target_dir/.claude/.pack-manifest"

    # Clean files listed in manifest (if exists from pre-ADR-14 sessions)
    if [[ -f "$manifest" ]]; then
        while IFS= read -r rel_path; do
            [[ -z "$rel_path" ]] && continue
            local full="$target_dir/.claude/${rel_path}"
            [[ -f "$full" ]] && rm -f "$full"
            [[ -d "$full" ]] && rm -rf "$full"
        done < "$manifest"
        rm -f "$manifest"
    fi

    # Clean orphaned packs directory (knowledge was copied here)
    if [[ -d "$target_dir/.claude/packs" ]]; then
        rm -rf "$target_dir/.claude/packs"
    fi

    return 0
}
