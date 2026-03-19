#!/usr/bin/env bash
# Migration: Clean up residual old-format .cco-* files left by buggy migration 009
#
# A bug in the migration engine caused schema_version not to be persisted
# after migration 009 moved .cco-meta → .cco/meta. This led to:
# - Migration 009 re-running (idempotent but noisy)
# - Stale .cco-meta files being recreated alongside .cco/meta
# This migration removes those residual old-format files.

MIGRATION_ID=10
MIGRATION_DESC="Clean up residual old-format .cco-* files"

# $1 = target directory (e.g. global/.claude)
migrate() {
    local target_dir="$1"

    # ── Global scope: remove old files if new equivalents exist ──

    # .cco-meta → .cco/meta (already moved by 009, but may have been recreated)
    if [[ -f "$target_dir/.cco/meta" && -f "$target_dir/.cco-meta" ]]; then
        rm -f "$target_dir/.cco-meta"
    fi

    # .cco-base/ → .cco/base/ (already moved by 009)
    if [[ -d "$target_dir/.cco/base" && -d "$target_dir/.cco-base" ]]; then
        rm -rf "$target_dir/.cco-base"
    fi

    # ── Top-level scope: .cco-remotes ──
    local user_config_dir
    user_config_dir=$(dirname "$(dirname "$target_dir")")  # up from global/.claude/
    if [[ -f "$user_config_dir/.cco/remotes" && -f "$user_config_dir/.cco-remotes" ]]; then
        rm -f "$user_config_dir/.cco-remotes"
    fi

    # ── Pack scope: .cco-source, .cco-install-tmp/ ──
    local packs_dir="$user_config_dir/packs"
    if [[ -d "$packs_dir" ]]; then
        local pack_dir
        for pack_dir in "$packs_dir"/*/; do
            [[ -d "$pack_dir" ]] || continue
            if [[ -f "$pack_dir/.cco/source" && -f "$pack_dir/.cco-source" ]]; then
                rm -f "$pack_dir/.cco-source"
            fi
            if [[ -d "$pack_dir/.cco/install-tmp" && -d "$pack_dir/.cco-install-tmp" ]]; then
                rm -rf "$pack_dir/.cco-install-tmp"
            fi
        done
    fi

    return 0
}
