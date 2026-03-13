#!/usr/bin/env bash
# lib/cmd-clean.sh — Clean up backup files created by cco update
#
# Provides: cmd_clean()
# Dependencies: colors.sh, utils.sh
# Globals: GLOBAL_DIR, PROJECTS_DIR

cmd_clean() {
    local dry_run=false
    local project=""
    local clean_all=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project)
                [[ -z "${2:-}" ]] && die "--project requires a project name"
                project="$2"; shift 2 ;;
            --all)        clean_all=true; shift ;;
            --dry-run)    dry_run=true; shift ;;
            --help)
                cat <<'EOF'
Usage: cco clean [OPTIONS]

Remove .bak files created by 'cco update'.

Options:
  --project <name>   Clean a specific project only
  --all              Clean global config + all projects
  --dry-run          Show what would be removed without deleting
  --help             Show this help message

Default behavior (no flags): clean global config only.

Examples:
  cco clean                    # Clean global .bak files
  cco clean --dry-run          # Preview what would be removed
  cco clean --project myapp    # Clean specific project
  cco clean --all              # Clean everything
EOF
                return 0
                ;;
            *) die "Unknown option: $1. Run 'cco clean --help' for usage." ;;
        esac
    done

    check_global

    local total=0

    if $clean_all; then
        # Clean global
        total=$(_clean_dir "$GLOBAL_DIR/.claude" "$dry_run" "global")

        # Clean all projects
        local project_dir
        for project_dir in "$PROJECTS_DIR"/*/; do
            [[ ! -d "$project_dir" ]] && continue
            [[ ! -d "$project_dir/.claude" ]] && continue
            local pname
            pname="$(basename "$project_dir")"
            local count
            count=$(_clean_dir "$project_dir/.claude" "$dry_run" "project/$pname")
            total=$((total + count))
        done
    elif [[ -n "$project" ]]; then
        local project_dir="$PROJECTS_DIR/$project"
        [[ ! -d "$project_dir" ]] && die "Project '$project' not found."
        [[ ! -d "$project_dir/.claude" ]] && die "No .claude/ directory in project '$project'."
        total=$(_clean_dir "$project_dir/.claude" "$dry_run" "project/$project")
    else
        # Default: global only
        total=$(_clean_dir "$GLOBAL_DIR/.claude" "$dry_run" "global")
    fi

    if $dry_run; then
        echo ""
        if [[ $total -gt 0 ]]; then
            info "Would remove $total .bak file(s). Run without --dry-run to delete."
        else
            info "No .bak files found."
        fi
    else
        if [[ $total -gt 0 ]]; then
            ok "Removed $total .bak file(s)."
        else
            info "No .bak files found."
        fi
    fi
}

# Find and remove .bak files in a directory.
# Usage: _clean_dir <dir> <dry_run> <label>
# Prints count to stdout (for capture). Messages go to stderr.
_clean_dir() {
    local dir="$1"
    local dry_run="$2"
    local label="$3"
    local count=0

    [[ ! -d "$dir" ]] && echo 0 && return 0

    while IFS= read -r -d '' bakfile; do
        count=$((count + 1))
        local rel="${bakfile#$dir/}"
        if $dry_run; then
            echo "  [$label] $rel" >&2
        else
            rm -f "$bakfile"
        fi
    done < <(find "$dir" -name '*.bak' -type f -print0 2>/dev/null)

    echo "$count"
}
