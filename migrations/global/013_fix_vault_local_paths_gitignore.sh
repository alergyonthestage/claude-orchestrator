#!/usr/bin/env bash
# Migration: Fix local-paths gitignore patterns applied to wrong directory
#
# Migration 012 had a bug: it computed vault_dir with a single dirname
# (→ user-config/global) instead of double (→ user-config/). This meant
# the gitignore patterns were never applied to existing vaults.
# This migration re-applies the patterns to the correct location.

MIGRATION_ID=13
MIGRATION_DESC="Fix local-paths gitignore patterns (re-apply to correct vault dir)"

# $1 = target directory (global/.claude)
migrate() {
    local target_dir="$1"

    # target_dir = user-config/global/.claude → global → user-config
    local global_dir vault_dir
    global_dir="$(dirname "$target_dir")"
    vault_dir="$(dirname "$global_dir")"

    local gitignore="$vault_dir/.gitignore"

    # No vault initialized: nothing to do
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

    # Clean up patterns that 012 may have incorrectly written to global/.gitignore
    local wrong_gitignore="$global_dir/.gitignore"
    if [[ -f "$wrong_gitignore" ]]; then
        if grep -qF 'projects/*/.cco/local-paths.yml' "$wrong_gitignore" 2>/dev/null; then
            # Remove the incorrectly placed patterns from the wrong file
            local tmpf
            tmpf=$(mktemp "${wrong_gitignore}.XXXXXX")
            awk '
                /^# Machine-specific local path mappings$/ { skip=1; next }
                /^# Temporary backup during vault save path extraction$/ { skip=1; next }
                /^projects\/\*\/\.cco\/local-paths\.yml$/ { next }
                /^projects\/\*\/\.cco\/project\.yml\.pre-save$/ { next }
                skip { skip=0; next }
                # Remove blank lines left by removed blocks
                /^$/ && prev_blank { next }
                { prev_blank = ($0 == ""); print }
            ' "$wrong_gitignore" > "$tmpf" && mv "$tmpf" "$wrong_gitignore"
            changed=true
        fi
    fi

    if $changed; then
        echo "[migration-013] Fixed local-paths gitignore patterns in vault root" >&2
    fi
    return 0
}
