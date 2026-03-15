#!/usr/bin/env bash
# Migration: Consolidate framework files into .cco/ directories (project scope)
#
# Moves scattered framework-managed files into per-project .cco/ directory.
# Also moves claude-state/ into .cco/ (session transcripts are transparent to users).

MIGRATION_ID=9
MIGRATION_DESC="Consolidate framework files into .cco/ directories"

# $1 = target directory (e.g. projects/<name>/)
migrate() {
    local target_dir="$1"

    mkdir -p "$target_dir/.cco"

    # Move .cco-meta → .cco/meta (guarded: skip if target exists)
    if [[ -f "$target_dir/.cco-meta" && ! -f "$target_dir/.cco/meta" ]]; then
        mv "$target_dir/.cco-meta" "$target_dir/.cco/meta"
    fi

    # Move .cco-base/ → .cco/base/ (guarded)
    if [[ -d "$target_dir/.cco-base" && ! -d "$target_dir/.cco/base" ]]; then
        mv "$target_dir/.cco-base" "$target_dir/.cco/base"
    fi

    # Move .managed/ → .cco/managed/ (guarded)
    if [[ -d "$target_dir/.managed" && ! -d "$target_dir/.cco/managed" ]]; then
        mv "$target_dir/.managed" "$target_dir/.cco/managed"
    fi

    # Move docker-compose.yml → .cco/docker-compose.yml (guarded)
    if [[ -f "$target_dir/docker-compose.yml" && ! -f "$target_dir/.cco/docker-compose.yml" ]]; then
        mv "$target_dir/docker-compose.yml" "$target_dir/.cco/docker-compose.yml"
    fi

    # Move claude-state/ → .cco/claude-state/ (guarded)
    if [[ -d "$target_dir/claude-state" && ! -d "$target_dir/.cco/claude-state" ]]; then
        mv "$target_dir/claude-state" "$target_dir/.cco/claude-state"
    fi

    # Clean up stale .tmp/ if present (now ephemeral by default, --dump for persistent)
    if [[ -d "$target_dir/.tmp" ]]; then
        warn "Removing stale .tmp/ in $(basename "$target_dir") (dry-run now uses ephemeral staging; use --dump to persist)"
        rm -rf "$target_dir/.tmp"
    fi

    # Move .pack-manifest → .cco/pack-manifest (lives inside .claude/, guarded)
    if [[ -f "$target_dir/.claude/.pack-manifest" && ! -f "$target_dir/.claude/.cco/pack-manifest" ]]; then
        mkdir -p "$target_dir/.claude/.cco"
        mv "$target_dir/.claude/.pack-manifest" "$target_dir/.claude/.cco/pack-manifest"
    fi

    return 0
}
