#!/usr/bin/env bash
# Migration: Rename share.yml to manifest.yml

MIGRATION_ID=4
MIGRATION_DESC="Rename share.yml to manifest.yml"

# $1 = target directory
# Must be idempotent (safe to run multiple times)
# Return 0 on success, non-zero on failure
migrate() {
    local target_dir="$1"

    local user_config="$REPO_ROOT/user-config"
    if [[ -n "${CCO_USER_CONFIG_DIR:-}" ]]; then
        user_config="$CCO_USER_CONFIG_DIR"
    fi

    local share_file="$user_config/share.yml"
    local manifest_file="$user_config/manifest.yml"

    # Skip if already migrated
    [[ ! -f "$share_file" ]] && return 0

    # If both exist, keep manifest.yml (user already has the new file)
    if [[ -f "$manifest_file" ]]; then
        rm -f "$share_file"
        info "Removed leftover share.yml (manifest.yml already exists)"
        return 0
    fi

    mv "$share_file" "$manifest_file"
    info "Renamed share.yml → manifest.yml"
    return 0
}
