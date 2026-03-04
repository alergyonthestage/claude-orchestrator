#!/usr/bin/env bash
# Migration: Restructure to unified user-config directory

MIGRATION_ID=3
MIGRATION_DESC="Restructure to unified user-config directory"

# $1 = target directory (e.g. global/.claude or user-config/global/.claude)
# Must be idempotent (safe to run multiple times)
# Return 0 on success, non-zero on failure
migrate() {
    local target_dir="$1"

    # Use REPO_ROOT directly (inherited from parent shell context)
    local user_config="$REPO_ROOT/user-config"
    local old_global="$REPO_ROOT/global"
    local old_projects="$REPO_ROOT/projects"

    # Respect CCO_USER_CONFIG_DIR if set to external path
    if [[ -n "${CCO_USER_CONFIG_DIR:-}" ]]; then
        user_config="$CCO_USER_CONFIG_DIR"
    fi

    # Skip if already migrated (user-config/global/.claude exists)
    [[ -d "$user_config/global/.claude" ]] && return 0

    # Skip if nothing to migrate (fresh install already uses new layout)
    [[ ! -d "$old_global/.claude" ]] && return 0

    info "Migrating to user-config/ directory structure..."

    # 1. Create user-config/
    mkdir -p "$user_config"

    # 2. Elevate packs BEFORE moving global (packs are inside global/)
    if [[ -d "$old_global/packs" ]]; then
        mv "$old_global/packs" "$user_config/packs"
        ok "  Elevated global/packs/ → user-config/packs/"
    else
        mkdir -p "$user_config/packs"
    fi

    # 3. Move global/ → user-config/global/
    if [[ -d "$old_global" ]]; then
        mv "$old_global" "$user_config/global"
        ok "  Moved global/ → user-config/global/"
    fi

    # 4. Move projects/ → user-config/projects/
    if [[ -d "$old_projects" ]]; then
        mv "$old_projects" "$user_config/projects"
        ok "  Moved projects/ → user-config/projects/"
    else
        mkdir -p "$user_config/projects"
    fi

    # 5. Create templates/ (new, empty)
    mkdir -p "$user_config/templates"
    ok "  Created user-config/templates/"

    info ""
    info "Migration complete. Run 'cco vault init' to enable versioning."

    return 0
}
