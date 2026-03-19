#!/usr/bin/env bash
# Migration: Rename diagrams.md → documentation.md in global rules
#
# The diagrams rule has been expanded to include documentation structure
# practices (directory layout, stale docs review, reorganization).
# The file is renamed to reflect its broader scope.

MIGRATION_ID=11
MIGRATION_DESC="Rename diagrams.md to documentation.md"

# $1 = target directory (e.g. user-config/global/.claude)
migrate() {
    local target_dir="$1"
    local old_file="$target_dir/rules/diagrams.md"
    local new_file="$target_dir/rules/documentation.md"
    local old_base="$target_dir/.cco/base/rules/diagrams.md"
    local new_base="$target_dir/.cco/base/rules/documentation.md"

    # Skip if already renamed
    if [[ -f "$new_file" ]]; then
        return 0
    fi

    # Rename the user file if it exists
    if [[ -f "$old_file" ]]; then
        mv "$old_file" "$new_file"
    fi

    # Rename the base tracking file if it exists
    if [[ -f "$old_base" ]]; then
        mv "$old_base" "$new_base"
    fi

    # Update active_policies in .cco/meta if present
    local meta_file="$target_dir/.cco/meta"
    if [[ -f "$meta_file" ]] && grep -q "diagrams.md" "$meta_file" 2>/dev/null; then
        sed -i.bak 's/diagrams\.md/documentation.md/g' "$meta_file"
        rm -f "$meta_file.bak"
    fi

    return 0
}
