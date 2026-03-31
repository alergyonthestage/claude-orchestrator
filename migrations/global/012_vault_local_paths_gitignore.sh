#!/usr/bin/env bash
# Migration: Add local-paths.yml and project.yml.pre-save to vault .gitignore
#
# The unified local path resolution feature stores machine-specific paths
# in .cco/local-paths.yml (gitignored) and creates temporary backups during
# vault save. Both patterns must be excluded from version control.

MIGRATION_ID=12
MIGRATION_DESC="Add local path resolution patterns to vault .gitignore"

# $1 = target directory (e.g. user-config/global/.claude)
migrate() {
    local target_dir="$1"

    # This migration operates on the vault .gitignore, not the global config.
    # The vault dir is the parent of global/ — i.e., user-config/.
    local vault_dir
    vault_dir=$(dirname "$target_dir")

    local gitignore="$vault_dir/.gitignore"

    # Only apply if this is a vault (has .gitignore)
    [[ ! -f "$gitignore" ]] && return 0

    local changed=false

    # Add local-paths.yml pattern if missing
    if ! grep -qF 'projects/*/.cco/local-paths.yml' "$gitignore" 2>/dev/null; then
        {
            echo ""
            echo "# Machine-specific local path mappings"
            echo "projects/*/.cco/local-paths.yml"
        } >> "$gitignore"
        changed=true
    fi

    # Add project.yml.pre-save pattern if missing
    if ! grep -qF 'projects/*/.cco/project.yml.pre-save' "$gitignore" 2>/dev/null; then
        {
            echo ""
            echo "# Temporary backup during vault save path extraction"
            echo "projects/*/.cco/project.yml.pre-save"
        } >> "$gitignore"
        changed=true
    fi

    if $changed; then
        return 0
    fi
    return 0
}
