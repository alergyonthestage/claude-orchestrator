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

    # Move .cco-meta → .cco/meta (guarded: skip if target exists)
    if [[ -f "$target_dir/.cco-meta" && ! -f "$target_dir/.cco/meta" ]]; then
        mv "$target_dir/.cco-meta" "$target_dir/.cco/meta"
    fi

    # Move .cco-base/ → .cco/base/ (guarded: skip if target exists)
    if [[ -d "$target_dir/.cco-base" && ! -d "$target_dir/.cco/base" ]]; then
        mv "$target_dir/.cco-base" "$target_dir/.cco/base"
    fi

    # Top-level: .cco-remotes → .cco/remotes
    local user_config_dir
    user_config_dir=$(dirname "$(dirname "$target_dir")")  # up from global/.claude/
    if [[ -f "$user_config_dir/.cco-remotes" && ! -f "$user_config_dir/.cco/remotes" ]]; then
        mkdir -p "$user_config_dir/.cco"
        mv "$user_config_dir/.cco-remotes" "$user_config_dir/.cco/remotes"
    fi

    # Pack consolidation (iterate packs/ from user-config root)
    local packs_dir="$user_config_dir/packs"
    if [[ -d "$packs_dir" ]]; then
        for pack_dir in "$packs_dir"/*/; do
            [[ -d "$pack_dir" ]] || continue
            mkdir -p "$pack_dir/.cco"
            if [[ -f "$pack_dir/.cco-source" && ! -f "$pack_dir/.cco/source" ]]; then
                mv "$pack_dir/.cco-source" "$pack_dir/.cco/source"
            fi
            if [[ -d "$pack_dir/.cco-install-tmp" && ! -d "$pack_dir/.cco/install-tmp" ]]; then
                mv "$pack_dir/.cco-install-tmp" "$pack_dir/.cco/install-tmp"
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

    # Replace old patterns with new ones.
    # Each entry: old_grep_pattern|old_sed_pattern|new_pattern
    # grep uses fixed strings (-F), sed uses the escaped version.
    local -a replacements=(
        "projects/*/.managed/|projects/\\*/.managed/|projects/*/.cco/managed/"
        "projects/*/.pack-manifest|projects/\\*/.pack-manifest|projects/*/.claude/.cco/pack-manifest"
        "projects/*/.cco-meta|projects/\\*/.cco-meta|projects/*/.cco/meta"
        "projects/*/docker-compose.yml|projects/\\*/docker-compose.yml|projects/*/.cco/docker-compose.yml"
        "projects/*/claude-state/|projects/\\*/claude-state/|projects/*/.cco/claude-state/"
        "packs/*/.cco-install-tmp/|packs/\\*/.cco-install-tmp/|packs/*/.cco/install-tmp/"
        ".cco-remotes|.cco-remotes|.cco/remotes"
    )
    # Note: projects/*/.tmp/ is intentionally NOT replaced — it stays outside .cco/

    for entry in "${replacements[@]}"; do
        local grep_pat sed_pat new_pat
        grep_pat="${entry%%|*}"
        local rest="${entry#*|}"
        sed_pat="${rest%%|*}"
        new_pat="${rest##*|}"
        if grep -qF "$grep_pat" "$gitignore" 2>/dev/null; then
            sed -i '' "s|${sed_pat}|${new_pat}|g" "$gitignore" 2>/dev/null || \
                sed -i "s|${sed_pat}|${new_pat}|g" "$gitignore"
        fi
    done

    # Add new patterns if missing
    local -a new_patterns=(
        "global/.claude/.cco/meta"
        "projects/*/.cco/docker-compose.yml"
        "projects/*/.cco/claude-state/"
        "projects/*/.claude/.cco/pack-manifest"
    )
    for pat in "${new_patterns[@]}"; do
        if ! grep -qF "$pat" "$gitignore" 2>/dev/null; then
            echo "$pat" >> "$gitignore"
        fi
    done
}
