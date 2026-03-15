#!/usr/bin/env bash
# lib/secrets.sh — Secrets loading and migration helpers
#
# Provides: load_secrets_file(), load_global_secrets(),
#           migrate_memory_to_claude_state() [deprecated — use migrations/project/001],
#           _migrate_to_managed() [deprecated — use migrations/global/001]
# Dependencies: colors.sh, utils.sh
# Globals: GLOBAL_DIR, DEFAULTS_DIR

# Load secrets from a specific file into an array of -e flags
# Usage: load_secrets_file array_name file_path
load_secrets_file() {
    local _target=$1
    local secrets_file="$2"
    [[ ! -f "$secrets_file" ]] && return 0
    local line_num=0
    while IFS= read -r line; do
        line_num=$(( line_num + 1 ))
        # Skip empty lines and comments
        [[ -z "$line" || "$line" == \#* ]] && continue
        # Strip inline comments
        line="${line%%#*}"
        # Trim trailing whitespace
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        # Validate KEY=VALUE format
        if [[ "$line" != *=* ]]; then
            warn "$(basename "$secrets_file"):${line_num}: skipping malformed line (expected KEY=VALUE)"
            continue
        fi
        eval "${_target}+=(-e $(printf '%q' "$line"))"
    done < "$secrets_file"
}

# Load global secrets from global/secrets.env into an array of -e flags
# Usage: load_global_secrets array_name
load_global_secrets() {
    load_secrets_file "$1" "$GLOBAL_DIR/secrets.env"
}

# DEPRECATED: Use migrations/project/001_memory_to_claude_state.sh instead.
# Kept for backward compatibility with cmd-start.sh (users who haven't run cco update).
# Uses .cco/claude-state/ (post-consolidation path) with fallback for legacy installs.
migrate_memory_to_claude_state() {
    local project_dir="$1"
    local cs_dir
    cs_dir=$(_cco_project_claude_state "$project_dir")
    if [[ -d "$project_dir/memory" && ! -d "$cs_dir" ]]; then
        info "Migrating $project_dir/memory → $cs_dir/memory (one-time)"
        mkdir -p "$cs_dir"
        mv "$project_dir/memory" "$cs_dir/memory"
    fi
    mkdir -p "$cs_dir" "$project_dir/memory"
}

# DEPRECATED: Use migrations/global/001_managed_scope.sh instead.
# Kept for backward compatibility with existing installs that call cmd-init
# before running cco update for the first time.
_migrate_to_managed() {
    local global_dir="$GLOBAL_DIR"
    local marker="$global_dir/.claude/.managed-migration-done"

    [[ -f "$marker" ]] && return 0
    [[ ! -d "$global_dir/.claude" ]] && return 0

    # Remove .system-manifest (no longer needed)
    rm -f "$global_dir/.claude/.system-manifest"

    # Legacy migration: remove old skills/init/ (renamed to init-workspace/)
    if [[ -d "$global_dir/.claude/skills/init" ]]; then
        rm -rf "$global_dir/.claude/skills/init"
        info "Migrated: removed old skills/init/ (renamed to init-workspace/)"
    fi

    # If settings.json contains hooks (old unified format),
    # replace with user-only settings
    if [[ -f "$global_dir/.claude/settings.json" ]]; then
        if grep -q '"hooks"' "$global_dir/.claude/settings.json" 2>/dev/null; then
            cp "$global_dir/.claude/settings.json" "$global_dir/.claude/settings.json.pre-managed"
            cp "$DEFAULTS_DIR/global/.claude/settings.json" "$global_dir/.claude/settings.json"
            info "Migrated: settings.json split (old version backed up as settings.json.pre-managed)"
        fi
    fi

    touch "$marker"
    ok "Managed scope migration complete"
}
