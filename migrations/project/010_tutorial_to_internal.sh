#!/usr/bin/env bash
# Migration 010: Tutorial project moved to internal
#
# The tutorial is now a built-in framework resource at internal/tutorial/.
# It is no longer installed in user-config/projects/.
# This migration informs users and offers to remove the legacy project.

MIGRATION_ID=10
MIGRATION_DESC="Tutorial project is now built-in"

migrate() {
    local project_dir="$1"
    local pname
    pname="$(basename "$project_dir")"

    # Only applies to the tutorial project
    [[ "$pname" != "tutorial" ]] && return 0

    # Check if this is the original tutorial (has .cco/source with native:project/tutorial)
    local source_file="$project_dir/.cco/source"
    if [[ -f "$source_file" ]]; then
        local source_line
        source_line=$(head -1 "$source_file")
        [[ "$source_line" != "native:project/tutorial" ]] && return 0
    fi

    echo ""
    warn "The tutorial is now built-in. Run 'cco start tutorial' directly — always up to date."
    echo ""
    echo "  Your existing projects/tutorial/ is a legacy copy that no longer receives updates."
    echo "  It can be safely removed."
    echo ""

    # Ask for consent if running interactively
    if (exec < /dev/tty) 2>/dev/null; then
        local choice
        read -rp "  Remove legacy tutorial project? [y/N] " choice < /dev/tty
        choice="${choice:-n}"
        choice="$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')"
        if [[ "$choice" == "y" || "$choice" == "yes" ]]; then
            rm -rf "$project_dir"
            ok "  Legacy tutorial project removed."
            echo "  Run 'cco start tutorial' to use the built-in version."
        else
            info "  Kept legacy tutorial project. You can remove it later:"
            echo "    rm -rf $project_dir"
        fi
    else
        # Non-interactive: just inform, don't remove
        info "  Non-interactive mode: keeping legacy tutorial. Remove manually:"
        echo "    rm -rf $project_dir"
    fi

    return 0
}
