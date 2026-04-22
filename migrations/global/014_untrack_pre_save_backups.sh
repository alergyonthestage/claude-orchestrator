#!/usr/bin/env bash
# Migration: Untrack .cco/project.yml.pre-save files from git
#
# Migration 012/013 added the gitignore pattern for pre-save backups,
# but if the files were already committed before the pattern existed,
# .gitignore alone doesn't untrack them. This causes persistent phantom
# diffs (D status) because _restore_local_paths deletes the working copy
# while git still tracks the committed version.
#
# This migration runs git rm --cached on the current branch. Other branches
# are cleaned lazily by _untrack_stale_pre_save() on next vault save/diff.

MIGRATION_ID=14
MIGRATION_DESC="Untrack pre-save backups from git index"

# $1 = target directory (global/.claude)
migrate() {
    local target_dir="$1"

    # Derive vault root: target_dir = user-config/global/.claude → user-config/
    local vault_dir
    vault_dir="$(dirname "$(dirname "$target_dir")")"

    # Only apply if this is a vault (git repo)
    [[ ! -d "$vault_dir/.git" ]] && return 0

    # Find tracked pre-save files on current branch
    local tracked
    tracked=$(git -C "$vault_dir" ls-files -- 'projects/*/.cco/project.yml.pre-save' 2>/dev/null)
    [[ -z "$tracked" ]] && return 0

    # Untrack from git index (keeps file on disk if present, but gitignore hides it)
    echo "$tracked" | xargs git -C "$vault_dir" rm --cached -q -- 2>/dev/null || true

    # Auto-commit the untracking (silent — this is housekeeping)
    if ! git -C "$vault_dir" diff --cached --quiet 2>/dev/null; then
        git -C "$vault_dir" commit -q -m "vault: untrack machine-specific pre-save backups"
        echo "[migration-014] Untracked pre-save backups on current branch" >&2
    fi

    return 0
}
