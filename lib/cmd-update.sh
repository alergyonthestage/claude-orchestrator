#!/usr/bin/env bash
# lib/cmd-update.sh — Update global/project config from defaults
#
# Provides: cmd_update()
# Dependencies: colors.sh, utils.sh, update.sh
# Globals: GLOBAL_DIR, DEFAULTS_DIR, PROJECTS_DIR

cmd_update() {
    local mode="interactive"
    local dry_run=false
    local no_backup=false
    local project=""
    local update_all=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project)
                [[ -z "${2:-}" ]] && die "--project requires a project name"
                project="$2"; shift 2 ;;
            --all)        update_all=true; shift ;;
            --dry-run)    dry_run=true; shift ;;
            --force)      mode="force"; shift ;;
            --keep)       mode="keep"; shift ;;
            --replace)    mode="replace"; shift ;;
            --no-backup)  no_backup=true; shift ;;
            --help)
                cat <<'EOF'
Usage: cco update [OPTIONS]

Update global and/or project configuration from defaults.
Uses 3-way merge to preserve user customizations while applying framework updates.

Options:
  --project <name>   Update a specific project (instead of global)
  --all              Update global config + all projects
  --dry-run          Show what would change without modifying anything
  --force            Overwrite even user-modified files (creates .bak)
  --keep             Always keep user version on conflicts
  --replace          Replace changed files with new version + create .bak
  --no-backup        Disable automatic .bak file creation
  --help             Show this help message

Default behavior (no flags): 3-way merge with automatic backup.
Files where both user and framework made changes are merged line-by-line.
Clean merges are auto-applied. Conflicts prompt for resolution.

Examples:
  cco update                    # Update global defaults (3-way merge)
  cco update --dry-run          # Preview changes
  cco update --project myapp    # Update specific project
  cco update --all              # Update global + all projects
  cco update --replace          # Replace all + .bak backup
  cco update --force --no-backup  # Overwrite without backups
EOF
                return 0
                ;;
            *) die "Unknown option: $1. Run 'cco update --help' for usage." ;;
        esac
    done

    check_global

    if $update_all; then
        # Update global
        info "Updating global config..."
        _update_global "$mode" "$dry_run" "$no_backup"

        # Update all projects
        local project_dir
        for project_dir in "$PROJECTS_DIR"/*/; do
            [[ ! -d "$project_dir" ]] && continue
            [[ ! -f "$project_dir/project.yml" ]] && continue
            local pname
            pname="$(basename "$project_dir")"
            info "Updating project '$pname'..."
            _update_project "$project_dir" "$mode" "$dry_run" "$no_backup"
        done
    elif [[ -n "$project" ]]; then
        # Update specific project
        local project_dir="$PROJECTS_DIR/$project"
        [[ ! -d "$project_dir" ]] && die "Project '$project' not found. Run 'cco project list'."
        [[ ! -f "$project_dir/project.yml" ]] && die "No project.yml in projects/$project/"
        info "Updating project '$project'..."
        _update_project "$project_dir" "$mode" "$dry_run" "$no_backup"
    else
        # Default: update global only
        info "Updating global config..."
        _update_global "$mode" "$dry_run" "$no_backup"
    fi

    if $dry_run; then
        echo ""
        info "Dry run complete. No changes made."
    else
        echo ""
        ok "Update complete."
    fi
}
