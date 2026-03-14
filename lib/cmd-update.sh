#!/usr/bin/env bash
# lib/cmd-update.sh — Update global/project config from defaults
#
# Provides: cmd_update()
# Dependencies: colors.sh, utils.sh, update.sh
# Globals: GLOBAL_DIR, DEFAULTS_DIR, PROJECTS_DIR, REPO_ROOT

cmd_update() {
    local cmd_mode="discovery"   # discovery | diff | apply | news
    local dry_run=false
    local no_backup=false
    local project=""
    local update_all=false
    # Hidden legacy auto-action modes (--force, --keep, --replace)
    local auto_action=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project)
                [[ -z "${2:-}" ]] && die "--project requires a project name"
                project="$2"; shift 2 ;;
            --all)        update_all=true; shift ;;
            --dry-run)    dry_run=true; shift ;;
            --diff)       cmd_mode="diff"; shift ;;
            --apply)      cmd_mode="apply"; shift ;;
            --news)       cmd_mode="news"; shift ;;
            --no-backup)  no_backup=true; shift ;;
            # Hidden backward-compatible aliases
            --force)      cmd_mode="apply"; auto_action="replace"; shift ;;
            --keep)       cmd_mode="apply"; auto_action="keep"; shift ;;
            --replace)    cmd_mode="apply"; auto_action="replace"; shift ;;
            --help)
                cat <<'EOF'
Usage: cco update [OPTIONS]

Migrations + discovery + additive notifications.
Shows available opinionated file updates without modifying files.

Modes:
  (no flags)              Migrations + discovery summary + notifications
  --diff                  Show detailed diffs for available updates
  --apply                 Interactive per-file: apply/merge/replace/keep/skip
  --news                  Show full details of additive changes

Options:
  --project <name>        Scope to specific project (+ global)
  --all                   Scope to global + all projects (default if no --project)
  --no-backup             Disable .bak creation (combine with --apply)
  --dry-run               Show pending migrations without running + discovery
  --help                  Show this help message

Non-interactive mode:
  When stdin is not a TTY, --apply defaults to (S)kip for all files.

Examples:
  cco update                    # Discover available updates
  cco update --diff             # Show diffs for all available updates
  cco update --apply            # Interactively apply updates
  cco update --project myapp    # Scope to global + myapp
  cco update --all              # Global + all projects
  cco update --dry-run          # Preview pending migrations
  cco update --news             # Show new features and examples
EOF
                return 0
                ;;
            *) die "Unknown option: $1. Run 'cco update --help' for usage." ;;
        esac
    done

    # Validate flag combinations
    if [[ "$cmd_mode" == "diff" && -n "$auto_action" ]]; then
        die "--diff and --force/--keep/--replace are mutually exclusive."
    fi

    # Non-TTY warning for --apply mode
    if [[ "$cmd_mode" == "apply" && -z "$auto_action" ]]; then
        if ! (exec < /dev/tty) 2>/dev/null; then
            warn "Non-interactive mode: skipping all file changes. Use a terminal for interactive merge."
            auto_action="skip"
        fi
    fi

    check_global

    # Default scope: if no --project, behave like --all
    if [[ -z "$project" ]]; then
        update_all=true
    fi

    if $update_all; then
        # Update global
        info "Updating global config..."
        _update_global "$cmd_mode" "$dry_run" "$no_backup" "$auto_action"

        # Show changelog notifications (global scope only)
        _update_changelog_notifications "$cmd_mode" "$dry_run"

        # TODO: pack and template migration scopes (design §4.15)
        # When migrations/pack/ or migrations/template/ exist, iterate
        # user-config/packs/*/ and user-config/templates/*/ here.

        # Update all projects
        local project_dir
        for project_dir in "$PROJECTS_DIR"/*/; do
            [[ ! -d "$project_dir" ]] && continue
            [[ ! -f "$project_dir/project.yml" ]] && continue
            local pname
            pname="$(basename "$project_dir")"
            info "Updating project '$pname'..."
            _update_project "$project_dir" "$cmd_mode" "$dry_run" "$no_backup" "$auto_action"
        done
    elif [[ -n "$project" ]]; then
        # Global always runs (even with --project)
        info "Updating global config..."
        _update_global "$cmd_mode" "$dry_run" "$no_backup" "$auto_action"

        # Show changelog notifications
        _update_changelog_notifications "$cmd_mode" "$dry_run"

        # Update specific project
        local project_dir="$PROJECTS_DIR/$project"
        [[ ! -d "$project_dir" ]] && die "Project '$project' not found. Run 'cco project list'."
        [[ ! -f "$project_dir/project.yml" ]] && die "No project.yml in projects/$project/"
        info "Updating project '$project'..."
        _update_project "$project_dir" "$cmd_mode" "$dry_run" "$no_backup" "$auto_action"
    fi

    if $dry_run; then
        echo ""
        info "Dry run complete. No changes made."
    elif [[ "$cmd_mode" == "discovery" || "$cmd_mode" == "diff" ]]; then
        echo ""
        ok "Update check complete."
    else
        echo ""
        ok "Update complete."
    fi
}
