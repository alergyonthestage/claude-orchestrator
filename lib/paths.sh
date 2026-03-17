#!/usr/bin/env bash
# lib/paths.sh — Framework path resolution helpers
#
# Provides: _cco_remotes_file(), _cco_global_meta(), _cco_global_base_dir(),
#           _cco_project_meta(), _cco_project_base_dir(), _cco_project_managed(),
#           _cco_project_compose(), _cco_project_claude_state(),
#           _cco_project_pack_manifest(), _cco_project_source(),
#           _cco_pack_source(), _cco_pack_install_tmp()
# Dependencies: none
# Globals: USER_CONFIG_DIR, GLOBAL_DIR

# All framework-managed files live inside per-scope .cco/ directories.
# During rollout (migration 009), helpers check the new path first and
# fall back to the old path for backward compatibility.

# ── Top-level ────────────────────────────────────────────────────────

_cco_remotes_file() {
    local new="$USER_CONFIG_DIR/.cco/remotes"
    local old="$USER_CONFIG_DIR/.cco-remotes"
    if [[ -f "$new" ]]; then echo "$new"
    elif [[ -f "$old" ]]; then echo "$old"
    else echo "$new"
    fi
}

# ── Global scope ─────────────────────────────────────────────────────

_cco_global_meta() {
    local new="$GLOBAL_DIR/.claude/.cco/meta"
    local old="$GLOBAL_DIR/.claude/.cco-meta"
    if [[ -f "$new" ]]; then echo "$new"
    elif [[ -f "$old" ]]; then echo "$old"
    else echo "$new"
    fi
}

_cco_global_base_dir() {
    local new="$GLOBAL_DIR/.claude/.cco/base"
    local old="$GLOBAL_DIR/.claude/.cco-base"
    if [[ -d "$new" ]]; then echo "$new"
    elif [[ -d "$old" ]]; then echo "$old"
    else echo "$new"
    fi
}

# ── Project scope ($1 = project_dir) ────────────────────────────────

_cco_project_meta() {
    local new="$1/.cco/meta"
    local old="$1/.cco-meta"
    if [[ -f "$new" ]]; then echo "$new"
    elif [[ -f "$old" ]]; then echo "$old"
    else echo "$new"
    fi
}

_cco_project_base_dir() {
    local new="$1/.cco/base"
    local old="$1/.cco-base"
    if [[ -d "$new" ]]; then echo "$new"
    elif [[ -d "$old" ]]; then echo "$old"
    else echo "$new"
    fi
}

_cco_project_managed() {
    local new="$1/.cco/managed"
    local old="$1/.managed"
    if [[ -d "$new" ]]; then echo "$new"
    elif [[ -d "$old" ]]; then echo "$old"
    else echo "$new"
    fi
}

_cco_project_compose() {
    local new="$1/.cco/docker-compose.yml"
    local old="$1/docker-compose.yml"
    if [[ -f "$new" ]]; then echo "$new"
    elif [[ -f "$old" ]]; then echo "$old"
    else echo "$new"
    fi
}

_cco_project_claude_state() {
    local new="$1/.cco/claude-state"
    local old="$1/claude-state"
    if [[ -d "$new" ]]; then echo "$new"
    elif [[ -d "$old" ]]; then echo "$old"
    else echo "$new"
    fi
}

# Note: pack-manifest lives inside .claude/, not project root
_cco_project_pack_manifest() {
    local new="$1/.claude/.cco/pack-manifest"
    local old="$1/.claude/.pack-manifest"
    if [[ -f "$new" ]]; then echo "$new"
    elif [[ -f "$old" ]]; then echo "$old"
    else echo "$new"
    fi
}

# ── Pack scope ($1 = pack_dir) ──────────────────────────────────────

_cco_pack_source() {
    local new="$1/.cco/source"
    local old="$1/.cco-source"
    if [[ -f "$new" ]]; then echo "$new"
    elif [[ -f "$old" ]]; then echo "$old"
    else echo "$new"
    fi
}

_cco_project_source() {
    local new="$1/.cco/source"
    local old="$1/.cco-source"
    if [[ -f "$new" ]]; then echo "$new"
    elif [[ -f "$old" ]]; then echo "$old"
    else echo "$new"
    fi
}

_cco_pack_install_tmp() {
    local new="$1/.cco/install-tmp"
    local old="$1/.cco-install-tmp"
    if [[ -d "$new" ]]; then echo "$new"
    elif [[ -d "$old" ]]; then echo "$old"
    else echo "$new"
    fi
}
