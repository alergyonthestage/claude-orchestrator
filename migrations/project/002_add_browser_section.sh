#!/usr/bin/env bash
# Migration: Add commented browser: section to existing project.yml files

MIGRATION_ID=2
MIGRATION_DESC="Add browser automation section to project.yml"

# $1 = target directory (e.g. projects/myapp)
# Must be idempotent (safe to run multiple times)
# Return 0 on success, non-zero on failure
migrate() {
    local target_dir="$1"
    local yml="$target_dir/project.yml"

    [[ ! -f "$yml" ]] && return 0

    # Idempotent: skip if browser section already exists (commented or not)
    if grep -q '^\s*#\?\s*browser:' "$yml" 2>/dev/null; then
        return 0
    fi

    # The block to insert (matches templates/project/base/project.yml)
    local browser_block
    browser_block='# ── Browser Automation (optional) ───────────────────────────────────
# Enable Claude to control a browser via chrome-devtools-mcp (CDP).
# The browser runs on your host OS and is visible while Claude operates it.
#
# Prerequisites:
#   1. Run: cco chrome start   (launches Chrome with remote debugging)
#   2. Set: browser.enabled: true in this file (or use --chrome flag)
#
# browser:
#   enabled: false          # true to activate chrome-devtools-mcp
#   mode: host              # "host" = Chrome on host (default and only mode)
#   cdp_port: 9222          # Chrome remote debugging port (default: 9222)
#   mcp_args: []            # extra flags for chrome-devtools-mcp
'

    # Insert before the Docker options section if it exists
    if grep -q '^# ── Docker options' "$yml" 2>/dev/null; then
        local tmpfile
        tmpfile=$(mktemp)
        local inserted=false
        while IFS= read -r line; do
            if [[ "$inserted" == "false" && "$line" == "# ── Docker options"* ]]; then
                printf '%s\n' "$browser_block" >> "$tmpfile"
                inserted=true
            fi
            printf '%s\n' "$line" >> "$tmpfile"
        done < "$yml"
        mv "$tmpfile" "$yml"
    else
        # Fallback: append before EOF
        printf '\n%s\n' "$browser_block" >> "$yml"
    fi

    return 0
}
