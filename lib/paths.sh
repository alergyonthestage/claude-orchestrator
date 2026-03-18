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

# ── Generic path resolution ─────────────────────────────────────────
# Resolve between new (post-migration) and old (pre-migration) paths.
# Checks for existence with the appropriate test (-f for file, -d for dir),
# returns the new path if neither exists (default for new installations).
# Usage: _cco_resolve_path <type> <new_path> <old_path>
#   type: "f" for file, "d" for directory
_cco_resolve_path() {
    local type="$1" new="$2" old="$3"
    if [[ "-${type}" == "-f" ]]; then
        if [[ -f "$new" ]]; then echo "$new"
        elif [[ -f "$old" ]]; then echo "$old"
        else echo "$new"
        fi
    else
        if [[ -d "$new" ]]; then echo "$new"
        elif [[ -d "$old" ]]; then echo "$old"
        else echo "$new"
        fi
    fi
}

# ── Top-level ────────────────────────────────────────────────────────

_cco_remotes_file() {
    _cco_resolve_path f "$USER_CONFIG_DIR/.cco/remotes" "$USER_CONFIG_DIR/.cco-remotes"
}

# ── Global scope ─────────────────────────────────────────────────────

_cco_global_meta() {
    _cco_resolve_path f "$GLOBAL_DIR/.claude/.cco/meta" "$GLOBAL_DIR/.claude/.cco-meta"
}

_cco_global_base_dir() {
    _cco_resolve_path d "$GLOBAL_DIR/.claude/.cco/base" "$GLOBAL_DIR/.claude/.cco-base"
}

# ── Project scope ($1 = project_dir) ────────────────────────────────

_cco_project_meta() {
    _cco_resolve_path f "$1/.cco/meta" "$1/.cco-meta"
}

_cco_project_base_dir() {
    _cco_resolve_path d "$1/.cco/base" "$1/.cco-base"
}

_cco_project_managed() {
    _cco_resolve_path d "$1/.cco/managed" "$1/.managed"
}

_cco_project_compose() {
    _cco_resolve_path f "$1/.cco/docker-compose.yml" "$1/docker-compose.yml"
}

_cco_project_claude_state() {
    _cco_resolve_path d "$1/.cco/claude-state" "$1/claude-state"
}

# Note: pack-manifest lives inside .claude/, not project root
_cco_project_pack_manifest() {
    _cco_resolve_path f "$1/.claude/.cco/pack-manifest" "$1/.claude/.pack-manifest"
}

# ── Pack scope ($1 = pack_dir) ──────────────────────────────────────

_cco_pack_source() {
    _cco_resolve_path f "$1/.cco/source" "$1/.cco-source"
}

_cco_project_source() {
    _cco_resolve_path f "$1/.cco/source" "$1/.cco-source"
}

_cco_pack_install_tmp() {
    _cco_resolve_path d "$1/.cco/install-tmp" "$1/.cco-install-tmp"
}
