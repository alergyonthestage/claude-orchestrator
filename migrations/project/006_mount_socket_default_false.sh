#!/usr/bin/env bash
# Migration: Notify about docker.mount_socket default change (true → false)
#
# The default for docker.mount_socket changed from true to false.
# This migration does NOT auto-enable the socket — security first.
# It warns the user to review projects that may need explicit mount_socket: true.

MIGRATION_ID=6
MIGRATION_DESC="Notify: docker.mount_socket default changed from true to false"

# $1 = target directory (e.g. projects/myapp)
# Must be idempotent (safe to run multiple times)
# Return 0 on success, non-zero on failure
migrate() {
    local target_dir="$1"
    local yml="$target_dir/project.yml"
    local project_name

    [[ -f "$yml" ]] || return 0

    # Skip if mount_socket is already declared explicitly
    if grep -q 'mount_socket' "$yml" 2>/dev/null; then
        return 0
    fi

    # Extract project name for the warning message
    project_name=$(grep '^name:' "$yml" | head -1 | sed 's/^name:[[:space:]]*//' | tr -d '"' | tr -d "'")

    # Emit warning — do NOT modify the file
    warn "BREAKING CHANGE: docker.mount_socket now defaults to false (was true)"
    warn "  Project '${project_name:-unknown}' does not declare mount_socket explicitly."
    warn "  If this project needs Docker socket access, add to project.yml:"
    warn "    docker:"
    warn "      mount_socket: true"
    warn ""

    return 0
}
