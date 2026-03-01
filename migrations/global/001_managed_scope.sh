#!/usr/bin/env bash
# Migration: Managed scope migration — remove legacy system-sync artifacts

MIGRATION_ID=1
MIGRATION_DESC="Managed scope migration"

# $1 = target directory (e.g. global/.claude)
# Must be idempotent (safe to run multiple times)
# Return 0 on success, non-zero on failure
migrate() {
    local target_dir="$1"

    # Remove .system-manifest (no longer needed)
    if [[ -f "$target_dir/.system-manifest" ]]; then
        rm -f "$target_dir/.system-manifest"
        info "Removed legacy .system-manifest"
    fi

    # Remove old skills/init/ (renamed to init-workspace/)
    if [[ -d "$target_dir/skills/init" ]]; then
        rm -rf "$target_dir/skills/init"
        info "Removed old skills/init/ (renamed to init-workspace/)"
    fi

    # If settings.json contains hooks (old unified format), replace with user-only settings
    if [[ -f "$target_dir/settings.json" ]]; then
        if grep -q '"hooks"' "$target_dir/settings.json" 2>/dev/null; then
            cp "$target_dir/settings.json" "$target_dir/settings.json.pre-managed"
            local defaults_settings="$DEFAULTS_DIR/global/.claude/settings.json"
            if [[ -f "$defaults_settings" ]]; then
                cp "$defaults_settings" "$target_dir/settings.json"
                info "Migrated settings.json (old version backed up as settings.json.pre-managed)"
            fi
        fi
    fi

    # Remove old migration marker (replaced by .cco-meta schema_version)
    rm -f "$target_dir/.managed-migration-done"

    return 0
}
