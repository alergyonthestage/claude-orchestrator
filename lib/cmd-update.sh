#!/usr/bin/env bash
# lib/cmd-update.sh — Update global/project config from defaults
#
# Provides: cmd_update()
# Dependencies: colors.sh, utils.sh, update.sh
# Globals: GLOBAL_DIR, DEFAULTS_DIR, PROJECTS_DIR, REPO_ROOT

cmd_update() {
    local cmd_mode="discovery"   # discovery | diff | sync | news
    local dry_run=false
    local no_backup=false
    local scope=""               # "" = all, "global" = global only, "<name>" = project
    local auto_action=""         # "" = interactive, "replace" = overwrite, "keep" = preserve
    local offline_mode=false
    local cache_mode="default"   # default | force
    local local_override=false
    local diff_all=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --sync)
                cmd_mode="sync"
                # Optional scope argument (global | project-name)
                if [[ -n "${2:-}" && "${2:0:1}" != "-" ]]; then
                    scope="$2"; shift
                fi
                shift ;;
            --diff)
                cmd_mode="diff"
                # Optional scope argument (global | project-name) and --all flag
                while [[ -n "${2:-}" ]]; do
                    case "$2" in
                        --all) diff_all=true; shift ;;
                        -*) break ;;
                        *)  scope="$2"; shift ;;
                    esac
                done
                shift ;;
            --news)       cmd_mode="news"; shift ;;
            --dry-run)    dry_run=true; shift ;;
            --no-backup)  no_backup=true; shift ;;
            --force)      cmd_mode="sync"; auto_action="replace"; shift ;;
            --keep)       cmd_mode="sync"; auto_action="keep"; shift ;;
            --replace)    cmd_mode="sync"; auto_action="replace"; shift ;;
            --offline)    offline_mode=true; shift ;;
            --no-cache)   cache_mode="force"; shift ;;
            --local)      local_override=true; shift ;;
            --help)
                cat <<'EOF'
Usage: cco update [OPTIONS]

Runs pending migrations (global + all projects) and shows available updates.
Checks both framework defaults and remote sources for installed projects/packs.

Modes:
  (default)           Run migrations + show available config updates + changelog
  --sync [scope]      Run migrations + interactively sync config from framework defaults
  --diff [scope]      Run migrations + show summary of available config updates
  --diff [scope] --all  Show full diffs (not just summary)
  --news              Show details of new features and additive changes

Scope (for --sync and --diff):
  (omitted)           Global + all projects
  global              Global config only
  <project-name>      One specific project only (no global)

Options:
  --force             Non-interactive sync: overwrite all files with framework version
  --keep              Non-interactive sync: keep all user files, update .cco/base/ only
  --local             Apply framework defaults directly on installed projects
                      (bypasses publisher update chain; use with --sync)
  --offline           Skip remote source checks (framework-only discovery)
  --no-cache          Force fresh remote version check (ignore cache)
  --no-backup         Skip .bak file creation (with --sync)
  --dry-run           Preview pending migrations without running
  --help              Show this help message

Non-interactive mode:
  When stdin is not a TTY, --sync defaults to (S)kip for all files.

Migrations run automatically in all modes (except --news and --dry-run).
Config sync (--sync) covers opinionated files: rules, agents, skills,
and other framework defaults that you may have customized.

For installed projects (from Config Repos), framework updates are managed
by the publisher. Use 'cco project update <name>' to get publisher updates.
Use --local with --sync to apply framework defaults directly (escape hatch).

Examples:
  cco update                  # Run migrations + show available updates
  cco update --diff           # Show diffs for all available config updates
  cco update --diff global    # Show diffs for global config only
  cco update --sync           # Interactively sync all config from defaults
  cco update --sync global    # Sync global config only
  cco update --sync myapp     # Sync one project only (no global)
  cco update --sync myapp --local  # Force framework sync on installed project
  cco update --force          # Overwrite all files with latest defaults
  cco update --keep           # Keep all user files, mark defaults as seen
  cco update --news           # Show new features and examples
  cco update --dry-run        # Preview pending migrations
  cco update --offline        # Skip remote checks
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
    if [[ "$local_override" == "true" && "$cmd_mode" != "sync" ]]; then
        die "--local can only be used with --sync. Example: cco update --sync <project> --local"
    fi

    # Non-TTY warning for --sync mode
    if [[ "$cmd_mode" == "sync" && -z "$auto_action" ]]; then
        if ! (exec < /dev/tty) 2>/dev/null; then
            warn "Non-interactive mode: skipping all file changes. Use a terminal for interactive merge."
            auto_action="skip"
        fi
    fi

    # Validate scope: "global" is a keyword (see RESERVED_PROJECT_NAMES),
    # anything else must be an existing project
    if [[ -n "$scope" && "$scope" != "global" ]]; then
        local scoped_dir="$PROJECTS_DIR/$scope"
        [[ ! -d "$scoped_dir" ]] && die "Project '$scope' not found. Run 'cco project list'."
        [[ ! -f "$scoped_dir/project.yml" ]] && die "No project.yml in projects/$scope/"
    fi

    # Determine diff display mode: summary (file list only) or full (with diff content)
    # --diff without scope → summary; --diff with scope or --all → full
    local diff_mode="summary"
    if [[ "$cmd_mode" == "diff" ]]; then
        if [[ -n "$scope" || "$diff_all" == "true" ]]; then
            diff_mode="full"
        fi
    fi

    check_global

    # Choose verb based on mode
    local verb="Updating"
    if [[ "$cmd_mode" == "discovery" || "$cmd_mode" == "diff" || "$cmd_mode" == "news" ]]; then
        verb="Checking"
    fi
    if $dry_run; then
        verb="Checking"
    fi

    # Determine what to update based on scope
    local do_global=true
    local do_projects="all"   # "all" | "none" | project-name

    case "$scope" in
        "")       do_global=true;  do_projects="all" ;;
        "global") do_global=true;  do_projects="none" ;;
        *)        do_global=false; do_projects="$scope" ;;
    esac

    # In default mode (discovery), always update everything regardless of scope
    # Scope filtering only applies to --sync and --diff
    if [[ "$cmd_mode" == "discovery" || "$cmd_mode" == "news" ]]; then
        do_global=true
        do_projects="all"
    fi

    local global_failed=false
    local project_failed=false

    # Global update
    if $do_global; then
        info "$verb global config..."
        if ! _update_global "$cmd_mode" "$dry_run" "$no_backup" "$auto_action" "$diff_mode"; then
            global_failed=true
            if [[ "$do_projects" != "none" ]]; then
                warn "Global update encountered errors. Project updates will still be attempted."
            else
                warn "Global update encountered errors."
            fi
        fi

        # Show changelog notifications (discovery and news modes only)
        if [[ "$cmd_mode" == "discovery" || "$cmd_mode" == "news" ]]; then
            _update_changelog_notifications "$cmd_mode" "$dry_run"
        fi
    fi

    # Project updates
    if [[ "$do_projects" == "all" && "$cmd_mode" != "news" ]]; then
        # TODO: pack and template migration scopes (design §4.15)
        # When migrations/pack/ or migrations/template/ exist, iterate
        # user-config/packs/*/ and user-config/templates/*/ here.

        local project_dir project_errors=0
        for project_dir in "$PROJECTS_DIR"/*/; do
            [[ ! -d "$project_dir" ]] && continue
            [[ ! -f "$project_dir/project.yml" ]] && continue
            local pname
            pname="$(basename "$project_dir")"
            info "$verb project '$pname'..."
            if ! _update_project "$project_dir" "$cmd_mode" "$dry_run" "$no_backup" "$auto_action" "$offline_mode" "$cache_mode" "$local_override" "$diff_mode"; then
                warn "Project '$pname' update encountered errors."
                project_errors=$(( project_errors + 1 ))
            fi
        done
        if [[ $project_errors -gt 0 ]]; then
            warn "$project_errors project(s) had update errors. Run 'cco update' again after resolving."
            project_failed=true
        fi
    elif [[ "$do_projects" != "none" && "$do_projects" != "all" && "$cmd_mode" != "news" ]]; then
        local project_dir="$PROJECTS_DIR/$do_projects"
        info "$verb project '$do_projects'..."
        if ! _update_project "$project_dir" "$cmd_mode" "$dry_run" "$no_backup" "$auto_action" "$offline_mode" "$cache_mode" "$local_override" "$diff_mode"; then
            warn "Project '$do_projects' update encountered errors. Run 'cco update --sync $do_projects' again."
            project_failed=true
        fi
    fi

    # Pack remote discovery (discovery mode only, respect --offline)
    if [[ "$do_projects" == "all" && "$cmd_mode" == "discovery" && "$offline_mode" != "true" ]]; then
        local pack_dir
        for pack_dir in "$PACKS_DIR"/*/; do
            [[ ! -d "$pack_dir" ]] && continue
            local pack_source_file
            pack_source_file=$(_cco_pack_source "$pack_dir")
            [[ ! -f "$pack_source_file" ]] && continue
            local pack_source_url
            pack_source_url=$(yml_get "$pack_source_file" "source")
            [[ -z "$pack_source_url" || "$pack_source_url" == "local" ]] && continue
            local pack_name
            pack_name="$(basename "$pack_dir")"
            local pack_meta_file="$pack_dir/.cco/meta"
            local pack_remote_status
            pack_remote_status=$(_check_remote_update "$pack_source_file" "$pack_meta_file" "$cache_mode")
            # Format display URL
            local pack_source_display="$pack_source_url"
            pack_source_display="${pack_source_display#https://}"
            pack_source_display="${pack_source_display#http://}"
            pack_source_display="${pack_source_display%.git}"
            case "$pack_remote_status" in
                update_available)
                    info "Pack '$pack_name' (from $pack_source_display): Update available"
                    info "  -> run 'cco pack update $pack_name'"
                    ;;
                unknown)
                    info "Pack '$pack_name' (from $pack_source_display): Version tracking not initialized"
                    info "  -> run 'cco pack update $pack_name' to check"
                    ;;
                unreachable)
                    warn "Pack '$pack_name' (from $pack_source_display): Remote unreachable"
                    ;;
                up_to_date)
                    # Silent — no output for up-to-date packs
                    ;;
            esac
        done
    fi

    if $global_failed || $project_failed; then
        error "Update completed with errors. Run 'cco update' again after resolving."
        return 1
    fi

    if $dry_run; then
        echo ""
        info "Dry run complete. No changes made."
    elif [[ "$cmd_mode" == "discovery" || "$cmd_mode" == "diff" || "$cmd_mode" == "news" ]]; then
        if [[ "$cmd_mode" == "diff" && "$diff_mode" == "summary" ]]; then
            echo ""
            info "Use 'cco update --diff <scope>' or 'cco update --diff --all' for full diffs."
        fi
        echo ""
        ok "Update check complete."
    else
        echo ""
        ok "Update complete."
    fi
}
