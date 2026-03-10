#!/usr/bin/env bash
# Migration: Split global setup.sh into setup-build.sh (build time) + setup.sh (runtime)

MIGRATION_ID=5
MIGRATION_DESC="Split global setup.sh into setup-build.sh (build) + setup.sh (runtime)"

# $1 = target directory (global/.claude)
# Must be idempotent (safe to run multiple times)
# Return 0 on success, non-zero on failure
migrate() {
    local target_dir="$1"

    # Derive global dir from target_dir (global/.claude → global/)
    local global_dir
    global_dir="$(dirname "$target_dir")"

    local old_setup="$global_dir/setup.sh"
    local build_setup="$global_dir/setup-build.sh"
    local runtime_setup="$global_dir/setup.sh"

    # Already migrated: setup-build.sh exists
    if [[ -f "$build_setup" ]]; then
        # Warn if setup.sh still contains build-time commands (user may need to move them)
        if [[ -f "$runtime_setup" ]] && grep -qE '^\s*(apt-get|dpkg|curl|wget|make|cmake)\b' "$runtime_setup" 2>/dev/null; then
            echo "[migration-005] WARNING: setup.sh appears to contain build-time commands (apt-get, curl, etc.)." >&2
            echo "[migration-005] These will now run as user 'claude' at cco start (not root at cco build)." >&2
            echo "[migration-005] Move build-time commands to setup-build.sh manually." >&2
        fi
        # Ensure runtime setup.sh exists (may have been skipped)
        if [[ ! -f "$runtime_setup" ]]; then
            _create_runtime_template "$runtime_setup"
        fi
        return 0
    fi

    # No setup.sh at all: create both templates
    if [[ ! -f "$old_setup" ]]; then
        _create_build_template "$build_setup"
        _create_runtime_template "$runtime_setup"
        return 0
    fi

    # setup.sh exists but setup-build.sh does not: check content
    local has_content=false
    if grep -qvE '^\s*$|^\s*#' "$old_setup" 2>/dev/null; then
        has_content=true
    fi

    if [[ "$has_content" == "true" ]]; then
        # Has actual commands: copy to setup-build.sh, replace setup.sh with runtime template.
        # Backup original so user can recover mixed content if needed.
        cp "$old_setup" "$global_dir/setup.sh.bak"
        cp "$old_setup" "$build_setup"
        echo "" >> "$build_setup"
        echo "# NOTE: This file was migrated from setup.sh by cco update." >> "$build_setup"
        echo "# It runs at build time (cco build). For runtime config, use setup.sh." >> "$build_setup"
        _create_runtime_template "$runtime_setup"
        echo "[migration-005] Migrated setup.sh → setup-build.sh (backup: setup.sh.bak)" >&2
    else
        # Only comments/empty: create both fresh templates
        _create_build_template "$build_setup"
        _create_runtime_template "$runtime_setup"
    fi

    return 0
}

_create_build_template() {
    cat > "$1" <<'TMPL'
#!/bin/bash
# Global build-time setup — executed once during `cco build` as root.
#
# USE FOR:
#   - apt-get install (system packages, compilers, CLI tools)
#   - Downloading and installing binary tools (terraform, kubectl, etc.)
#   - Heavy dependencies that would slow down every `cco start`
#
# DO NOT USE FOR:
#   - Dotfiles, tmux keybindings, shell aliases, git config
#   - User-level settings that should apply at runtime
#   → Use setup.sh instead (runs at every `cco start`)
#
# Changes require `cco build` to take effect.
# See: docs/user-guides/advanced/custom-environment.md
#
# Example:
#   apt-get update && apt-get install -y chromium && rm -rf /var/lib/apt/lists/*
TMPL
}

_create_runtime_template() {
    cat > "$1" <<'TMPL'
#!/bin/bash
# Global runtime setup — executed at every `cco start`, before project setup.
# Runs as user `claude` inside the container.
#
# USE FOR:
#   - Dotfiles (~/.tmux.conf, ~/.bashrc additions, ~/.vimrc)
#   - Shell aliases and functions
#   - tmux keybindings and configuration
#   - Lightweight pip/npm packages needed in all projects
#   - git config overrides (git config --global ...)
#
# DO NOT USE FOR:
#   - apt-get install, system packages, heavy downloads
#   → Use setup-build.sh instead (runs once at `cco build`)
#
# This script must be idempotent (safe to run multiple times).
# See: docs/user-guides/advanced/custom-environment.md
TMPL
}
