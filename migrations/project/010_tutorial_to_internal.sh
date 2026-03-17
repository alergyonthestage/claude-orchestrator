#!/usr/bin/env bash
# Migration 010: Tutorial project moved to internal
#
# The tutorial is now a built-in framework resource at internal/tutorial/.
# It is no longer installed in user-config/projects/.
# This migration handles two cases:
#   1. Legacy framework tutorial (source: native:project/tutorial) → offer removal
#   2. User project named "tutorial" (different source) → warn about reserved name

MIGRATION_ID=10
MIGRATION_DESC="Tutorial project is now built-in"

migrate() {
    local project_dir="$1"
    local pname
    pname="$(basename "$project_dir")"

    # Only applies to projects named "tutorial"
    [[ "$pname" != "tutorial" ]] && return 0

    # Determine if this is the framework's tutorial or a user project
    local is_legacy_tutorial=false
    local source_file="$project_dir/.cco/source"
    if [[ -f "$source_file" ]]; then
        local source_line
        source_line=$(head -1 "$source_file")
        [[ "$source_line" == "native:project/tutorial" ]] && is_legacy_tutorial=true
    else
        # No .cco/source — likely an old installation before source tracking.
        # Check for tutorial-specific files as heuristic.
        if [[ -f "$project_dir/.claude/skills/tutorial/SKILL.md" && \
              -f "$project_dir/.claude/rules/tutorial-behavior.md" ]]; then
            is_legacy_tutorial=true
        fi
    fi

    echo ""

    if $is_legacy_tutorial; then
        # Case 1: Legacy framework tutorial → offer removal
        warn "The tutorial is now built-in. Run 'cco start tutorial' directly — always up to date."
        echo ""
        echo "  Your existing projects/tutorial/ is a legacy copy that no longer receives updates."
        echo "  It can be safely removed."
        echo ""

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
                info "  Kept legacy tutorial project."
                warn "  Note: 'tutorial' is now a reserved name. 'cco start tutorial' will not"
                warn "  launch this project — it launches the built-in tutorial instead."
                echo "  To avoid conflicts, rename or remove this project:"
                echo "    Rename:  mv $project_dir ${project_dir%/*}/my-tutorial"
                echo "    Remove:  rm -rf $project_dir"
            fi
        else
            # Non-interactive: inform only
            info "  Non-interactive mode: keeping legacy tutorial. Remove or rename manually:"
            echo "    rm -rf $project_dir"
        fi
    else
        # Case 2: User project named "tutorial" → warn about reserved name
        warn "'tutorial' is now a reserved name for the built-in tutorial."
        echo ""
        echo "  Your project 'tutorial' appears to be a custom project (not the framework tutorial)."
        echo "  'cco start tutorial' will NOT launch this project — it launches the built-in tutorial."
        echo ""
        echo "  Please rename your project to avoid the conflict:"
        echo "    mv $project_dir ${project_dir%/*}/<new-name>"
        echo "  Then update any references to the project name."
    fi

    return 0
}
