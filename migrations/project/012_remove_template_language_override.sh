#!/usr/bin/env bash
# Migration: Remove non-functional language.md override from projects
#
# The base project template included a "commented-out" language.md using
# # prefixes, but in markdown # creates headings, not comments. The file
# was visible to the agent as active content. Users who need a project-level
# language override should create it explicitly.

MIGRATION_ID=12
MIGRATION_DESC="Remove non-functional language.md template override"

# Known content of the template file (trimmed for matching)
_TEMPLATE_MARKER="Language Preferences (Project Override)"

# $1 = target directory (e.g. user-config/projects/<name>/.claude)
migrate() {
    local target_dir="$1"
    local lang_file="$target_dir/rules/language.md"

    # Skip if file doesn't exist
    [[ ! -f "$lang_file" ]] && return 0

    # Only delete if it matches the known template content
    if grep -q "$_TEMPLATE_MARKER" "$lang_file" 2>/dev/null; then
        rm -f "$lang_file"
        # Clean up empty rules directory
        if [[ -d "$target_dir/rules" ]] && \
           [[ -z "$(ls -A "$target_dir/rules" 2>/dev/null)" ]]; then
            rmdir "$target_dir/rules" 2>/dev/null || true
        fi
    fi

    return 0
}
