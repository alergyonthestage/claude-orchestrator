#!/usr/bin/env bash
# Migration: Add commented github: section to existing project.yml files

MIGRATION_ID=4
MIGRATION_DESC="Add GitHub MCP integration section to project.yml"

# $1 = target directory (e.g. projects/myapp)
# Must be idempotent (safe to run multiple times)
# Return 0 on success, non-zero on failure
migrate() {
    local target_dir="$1"
    local yml="$target_dir/project.yml"

    [[ ! -f "$yml" ]] && return 0

    # Idempotent: skip if github section already exists (commented or not)
    if grep -q '^\s*#\?\s*github:' "$yml" 2>/dev/null; then
        return 0
    fi

    # The block to insert (matches defaults/_template/project.yml)
    local github_block
    github_block='# ── GitHub Integration (optional) ────────────────────────────────────
# Enable Claude to interact with GitHub via MCP (issues, PRs, code search).
# Requires a GitHub token with appropriate scopes (repo, read:org, etc.).
# Set GITHUB_TOKEN in global/secrets.env or project secrets.env before use.
#
# github:
#   enabled: false            # true to activate github MCP server
#   token_env: GITHUB_TOKEN   # env var containing the GitHub token (default: GITHUB_TOKEN)
'

    # Insert before the Browser Automation section if it exists
    if grep -q '^# ── Browser Automation' "$yml" 2>/dev/null; then
        local tmpfile
        tmpfile=$(mktemp)
        local inserted=false
        while IFS= read -r line; do
            if [[ "$inserted" == "false" && "$line" == "# ── Browser Automation"* ]]; then
                printf '%s\n' "$github_block" >> "$tmpfile"
                inserted=true
            fi
            printf '%s\n' "$line" >> "$tmpfile"
        done < "$yml"
        mv "$tmpfile" "$yml"
    elif grep -q '^# ── Docker options' "$yml" 2>/dev/null; then
        # Fallback: insert before Docker options
        local tmpfile
        tmpfile=$(mktemp)
        local inserted=false
        while IFS= read -r line; do
            if [[ "$inserted" == "false" && "$line" == "# ── Docker options"* ]]; then
                printf '%s\n' "$github_block" >> "$tmpfile"
                inserted=true
            fi
            printf '%s\n' "$line" >> "$tmpfile"
        done < "$yml"
        mv "$tmpfile" "$yml"
    else
        # Final fallback: append to end of file
        printf '\n%s\n' "$github_block" >> "$yml"
    fi

    return 0
}
