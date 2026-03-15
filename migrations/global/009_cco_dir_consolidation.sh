#!/usr/bin/env bash
# Migration: Consolidate framework files into .cco/ directories
#
# Moves scattered framework-managed files (.cco-meta, .cco-base/, .cco-remotes,
# .cco-source, .cco-install-tmp/) into per-scope .cco/ subdirectories.
# Also moves claude-state/ into .cco/ at project level (handled by project migration).

MIGRATION_ID=9
MIGRATION_DESC="Consolidate framework files into .cco/ directories"

# $1 = target directory (e.g. global/.claude)
migrate() {
    local target_dir="$1"

    mkdir -p "$target_dir/.cco"

    # Move .cco-meta → .cco/meta
    if [[ -f "$target_dir/.cco-meta" && ! -f "$target_dir/.cco/meta" ]]; then
        mv "$target_dir/.cco-meta" "$target_dir/.cco/meta"
    elif [[ -f "$target_dir/.cco-meta" ]]; then
        rm -f "$target_dir/.cco-meta"  # stale duplicate
    fi

    # Move .cco-base/ → .cco/base/ (guarded: skip if target exists)
    if [[ -d "$target_dir/.cco-base" && ! -d "$target_dir/.cco/base" ]]; then
        mv "$target_dir/.cco-base" "$target_dir/.cco/base"
    elif [[ -d "$target_dir/.cco-base" ]]; then
        rm -rf "$target_dir/.cco-base"  # stale duplicate
    fi

    # Top-level: .cco-remotes → .cco/remotes
    local user_config_dir
    user_config_dir=$(dirname "$(dirname "$target_dir")")  # up from global/.claude/
    if [[ -f "$user_config_dir/.cco-remotes" && ! -f "$user_config_dir/.cco/remotes" ]]; then
        mkdir -p "$user_config_dir/.cco"
        mv "$user_config_dir/.cco-remotes" "$user_config_dir/.cco/remotes"
    elif [[ -f "$user_config_dir/.cco-remotes" ]]; then
        rm -f "$user_config_dir/.cco-remotes"
    fi

    # Pack consolidation (iterate packs/ from user-config root)
    local packs_dir="$user_config_dir/packs"
    if [[ -d "$packs_dir" ]]; then
        for pack_dir in "$packs_dir"/*/; do
            [[ -d "$pack_dir" ]] || continue
            mkdir -p "$pack_dir/.cco"
            if [[ -f "$pack_dir/.cco-source" && ! -f "$pack_dir/.cco/source" ]]; then
                mv "$pack_dir/.cco-source" "$pack_dir/.cco/source"
            elif [[ -f "$pack_dir/.cco-source" ]]; then
                rm -f "$pack_dir/.cco-source"
            fi
            if [[ -d "$pack_dir/.cco-install-tmp" && ! -d "$pack_dir/.cco/install-tmp" ]]; then
                mv "$pack_dir/.cco-install-tmp" "$pack_dir/.cco/install-tmp"
            elif [[ -d "$pack_dir/.cco-install-tmp" ]]; then
                rm -rf "$pack_dir/.cco-install-tmp"
            fi
        done
    fi

    # Update vault .gitignore if vault is initialized
    if [[ -f "$user_config_dir/.gitignore" ]]; then
        _migrate_vault_gitignore_009 "$user_config_dir/.gitignore"
    fi

    # Warn if sessions are running
    if command -v docker >/dev/null 2>&1; then
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^cc-"; then
            warn "Running sessions detected. Restart them after migration: cco stop && cco start <project>"
        fi
    fi

    return 0
}

# Migrate vault .gitignore patterns from old to new .cco/ layout
_migrate_vault_gitignore_009() {
    local gitignore="$1"

    # Replace old patterns with new ones
    local -a replacements=(
        "projects/\\*/.managed/|projects/*/.cco/managed/"
        "projects/\\*/.tmp/|projects/*/.cco/tmp/"
        "projects/\\*/.pack-manifest|projects/*/.cco/pack-manifest"
        "projects/\\*/.cco-meta|projects/*/.cco/meta"
        "projects/\\*/docker-compose.yml|projects/*/.cco/docker-compose.yml"
        "projects/\\*/claude-state/|projects/*/.cco/claude-state/"
        "packs/\\*/.cco-install-tmp/|packs/*/.cco/install-tmp/"
        ".cco-remotes|.cco/remotes"
    )

    for pair in "${replacements[@]}"; do
        local old="${pair%%|*}"
        local new="${pair##*|}"
        if grep -qF "$old" "$gitignore" 2>/dev/null; then
            sed -i '' "s|${old}|${new}|g" "$gitignore" 2>/dev/null || \
                sed -i "s|${old}|${new}|g" "$gitignore"
        fi
    done

    # Add new patterns if missing
    if ! grep -qF "global/.claude/.cco/meta" "$gitignore" 2>/dev/null; then
        echo "global/.claude/.cco/meta" >> "$gitignore"
    fi
    if ! grep -qF "projects/*/.cco/docker-compose.yml" "$gitignore" 2>/dev/null && \
       ! grep -qF ".cco/docker-compose.yml" "$gitignore" 2>/dev/null; then
        echo "projects/*/.cco/docker-compose.yml" >> "$gitignore"
    fi
    if ! grep -qF "projects/*/.cco/claude-state/" "$gitignore" 2>/dev/null && \
       ! grep -qF ".cco/claude-state/" "$gitignore" 2>/dev/null; then
        echo "projects/*/.cco/claude-state/" >> "$gitignore"
    fi
}
