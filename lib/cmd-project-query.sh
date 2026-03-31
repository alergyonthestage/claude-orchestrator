#!/usr/bin/env bash
# lib/cmd-project-query.sh — Project listing, display, validation, and path resolution
#
# Provides: cmd_project_list(), cmd_project_show(), cmd_project_validate(),
#   cmd_project_resolve()
# Dependencies: colors.sh, utils.sh, yaml.sh, local-paths.sh
# Globals: PROJECTS_DIR, PACKS_DIR

cmd_project_list() {
    if [[ "${1:-}" == "--help" ]]; then
        cat <<'EOF'
Usage: cco project list

List all configured projects with repo count and running status.
EOF
        return 0
    fi

    echo -e "${BOLD}NAME              REPOS    STATUS${NC}"

    for dir in "$PROJECTS_DIR"/*/; do
        [[ ! -d "$dir" ]] && continue
        local name
        name=$(basename "$dir")
        [[ "$name" == "_template" ]] && continue

        local project_yml="$dir/project.yml"
        local repo_count="-"
        if [[ -f "$project_yml" ]]; then
            repo_count=$(yml_get_repos "$project_yml" | grep -c . 2>/dev/null || echo "0")
        fi

        local status="stopped"
        local project_name
        project_name=$(yml_get "$project_yml" "name" 2>/dev/null)
        [[ -z "$project_name" ]] && project_name="$name"
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^cc-${project_name}$"; then
            status="${GREEN}running${NC}"
        fi

        printf "%-18s %-8s %b\n" "$name" "$repo_count" "$status"
    done
}

cmd_project_show() {
    local name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                cat <<'EOF'
Usage: cco project show <name>

Show details for a configured project.
EOF
                return 0
                ;;
            -*)  die "Unknown option: $1" ;;
            *)
                if [[ -z "$name" ]]; then
                    name="$1"; shift
                else
                    die "Unexpected argument: $1"
                fi
                ;;
        esac
    done

    [[ -z "$name" ]] && die "Usage: cco project show <name>"

    local project_dir="$PROJECTS_DIR/$name"
    local project_yml="$project_dir/project.yml"
    [[ ! -f "$project_yml" ]] && die "Project '$name' not found at projects/$name/"

    # Name and description
    local yml_name
    yml_name=$(yml_get "$project_yml" "name")
    local description
    description=$(yml_get "$project_yml" "description")

    echo -e "${BOLD}Project: ${yml_name:-$name}${NC}"
    [[ -n "$description" ]] && echo "  $description"
    echo ""

    # Repos
    echo -e "${BOLD}Repos:${NC}"
    local repos
    repos=$(yml_get_repos "$project_yml")
    if [[ -n "$repos" ]]; then
        while IFS=: read -r repo_path repo_name; do
            [[ -z "$repo_path" ]] && continue
            local expanded
            expanded=$(expand_path "$repo_path")
            if [[ -d "$expanded" ]]; then
                echo "  $repo_name ($repo_path)"
            else
                echo -e "  $repo_name ($repo_path) ${YELLOW}[missing]${NC}"
            fi
        done <<< "$repos"
    else
        echo "  (none)"
    fi
    echo ""

    # Packs
    echo -e "${BOLD}Packs:${NC}"
    local packs
    packs=$(yml_get_packs "$project_yml")
    if [[ -n "$packs" ]]; then
        while IFS= read -r pack; do
            [[ -z "$pack" ]] && continue
            if [[ -d "$PACKS_DIR/$pack" ]]; then
                echo "  $pack"
            else
                echo -e "  $pack ${YELLOW}[not found]${NC}"
            fi
        done <<< "$packs"
    else
        echo "  (none)"
    fi
    echo ""

    # Docker config
    echo -e "${BOLD}Docker:${NC}"
    local auth_method
    auth_method=$(yml_get "$project_yml" "auth.method")
    echo "  Auth: ${auth_method:-oauth}"
    local ports
    ports=$(yml_get_ports "$project_yml")
    if [[ -n "$ports" ]]; then
        echo "  Ports: $(echo "$ports" | tr '\n' ' ')"
    else
        echo "  Ports: (none)"
    fi
    local network
    network=$(yml_get "$project_yml" "docker.network")
    echo "  Network: ${network:-cc-${yml_name:-$name}}"
    echo ""

    # Status
    echo -e "${BOLD}Status:${NC}"
    local container_name="cc-${yml_name:-$name}"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container_name}$"; then
        echo -e "  ${GREEN}running${NC}"
    else
        echo "  stopped"
    fi
}

cmd_project_validate() {
    local name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                cat <<'EOF'
Usage: cco project validate <name>

Validate project structure and configuration.
EOF
                return 0
                ;;
            -*)  die "Unknown option: $1" ;;
            *)
                if [[ -z "$name" ]]; then
                    name="$1"; shift
                else
                    die "Unexpected argument: $1"
                fi
                ;;
        esac
    done

    [[ -z "$name" ]] && die "Usage: cco project validate <name>"

    local project_dir="$PROJECTS_DIR/$name"
    local project_yml="$project_dir/project.yml"
    local errors=0

    # project.yml exists
    if [[ ! -f "$project_yml" ]]; then
        error "Project '$name': project.yml not found"
        return 1
    fi

    # name field present
    local yml_name
    yml_name=$(yml_get "$project_yml" "name")
    if [[ -z "$yml_name" ]]; then
        error "Project '$name': 'name' field missing in project.yml"
        ((errors++))
    fi

    # .claude/ directory
    if [[ ! -d "$project_dir/.claude" ]]; then
        warn "Project '$name': .claude/ directory missing"
    fi

    # Repos paths exist
    local repos
    repos=$(yml_get_repos "$project_yml")
    if [[ -z "$repos" ]]; then
        warn "Project '$name': no repos configured"
    else
        while IFS=: read -r repo_path repo_name; do
            [[ -z "$repo_path" ]] && continue
            local expanded
            expanded=$(expand_path "$repo_path")
            if [[ ! -d "$expanded" ]]; then
                error "Project '$name': repo path not found: $repo_path"
                ((errors++))
            fi
        done <<< "$repos"
    fi

    # Referenced packs exist
    local packs
    packs=$(yml_get_packs "$project_yml")
    if [[ -n "$packs" ]]; then
        while IFS= read -r pack; do
            [[ -z "$pack" ]] && continue
            if [[ ! -d "$PACKS_DIR/$pack" ]]; then
                error "Project '$name': pack '$pack' not found in packs/"
                ((errors++))
            fi
        done <<< "$packs"
    fi

    # Referenced llms entries exist
    if ! _validate_llms_refs "$project_yml" "Project '$name'"; then
        ((errors++))
    fi

    if [[ $errors -gt 0 ]]; then
        return 1
    fi
    ok "Project '$name' is valid"
}

# ── cco project resolve ─────────────────────────────────────────────

cmd_project_resolve() {
    local name="" show_only=false reset=false
    local -a repo_args=()
    local -a mount_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                cat <<'EOF'
Usage: cco project resolve <project> [options]

Configure local paths for a project's repositories and mounts.

Without flags: interactive mode — shows all entries and prompts for unresolved.
With flags: set specific paths non-interactively.

Options:
  --repo <name> <path>      Set local path for a repository
  --mount <target> <path>   Set local path for an extra mount
  --show                    Show current path mappings (no changes)
  --reset                   Remove all local overrides (re-prompt on next start)

Examples:
  cco project resolve myapp                          # Interactive
  cco project resolve myapp --repo backend ~/dev/be  # Direct
  cco project resolve myapp --show                   # Status
EOF
                return 0
                ;;
            --show)  show_only=true; shift ;;
            --reset) reset=true; shift ;;
            --repo)
                [[ $# -lt 3 ]] && die "--repo requires <name> and <path>"
                repo_args+=("$2=$3"); shift 3
                ;;
            --mount)
                [[ $# -lt 3 ]] && die "--mount requires <target> and <path>"
                mount_args+=("$2=$3"); shift 3
                ;;
            -*) die "Unknown option: $1" ;;
            *)
                if [[ -z "$name" ]]; then
                    name="$1"; shift
                else
                    die "Unexpected argument: $1"
                fi
                ;;
        esac
    done

    [[ -z "$name" ]] && die "Usage: cco project resolve <project>. Run 'cco project list' to see available projects."

    local project_dir="$PROJECTS_DIR/$name"
    [[ ! -d "$project_dir" ]] && die "Project '$name' not found."

    local project_yml="$project_dir/project.yml"
    [[ ! -f "$project_yml" ]] && die "No project.yml found for '$name'."

    local local_paths="$project_dir/.cco/local-paths.yml"

    # --reset: remove local-paths.yml
    if $reset; then
        if [[ -f "$local_paths" ]]; then
            rm -f "$local_paths"
            ok "Local path mappings removed for '$name'. Paths will be prompted on next 'cco start'."
        else
            info "No local path mappings to remove."
        fi
        return 0
    fi

    # --show: display current mappings
    if $show_only; then
        echo -e "${BOLD}Project: $name${NC}"
        echo ""

        # Show repos
        local repos
        repos=$(yml_get_repos "$project_yml" 2>/dev/null)
        if [[ -n "$repos" ]]; then
            echo "  Repos:"
            while IFS=: read -r repo_path repo_name; do
                [[ -z "$repo_name" ]] && continue
                local display_path="$repo_path"
                local status_icon

                # Check local-paths.yml for resolved path
                if [[ "$repo_path" == "@local" || "$repo_path" == *"{{REPO_"* ]]; then
                    local lp
                    lp=$(_local_paths_get "$local_paths" "repos" "$repo_name")
                    if [[ -n "$lp" ]]; then
                        display_path="$lp"
                        local expanded
                        expanded=$(expand_path "$lp")
                        if [[ -d "$expanded" ]]; then
                            status_icon="${GREEN}✓ exists${NC}"
                        else
                            status_icon="${YELLOW}✗ path missing${NC}"
                        fi
                    else
                        display_path="@local (not configured)"
                        status_icon="${RED}✗ needs path${NC}"
                    fi
                else
                    local expanded
                    expanded=$(expand_path "$repo_path")
                    if [[ -d "$expanded" ]]; then
                        status_icon="${GREEN}✓ exists${NC}"
                    else
                        status_icon="${YELLOW}✗ path missing${NC}"
                    fi
                fi
                printf "    %-20s %-35s %b\n" "$repo_name" "$display_path" "$status_icon"
            done <<< "$repos"
        else
            echo "  Repos: (none)"
        fi

        echo ""

        # Show extra_mounts
        local mounts
        mounts=$(yml_get_extra_mounts "$project_yml" 2>/dev/null)
        if [[ -n "$mounts" ]]; then
            echo "  Extra mounts:"
            while IFS= read -r mount_line; do
                [[ -z "$mount_line" ]] && continue
                local source="${mount_line%%:*}"
                local rest="${mount_line#*:}"
                local target="${rest%%:*}"

                local display_source="$source"
                local status_icon

                if [[ "$source" == "@local" ]]; then
                    local lp
                    lp=$(_local_paths_get "$local_paths" "extra_mounts" "$target")
                    if [[ -n "$lp" ]]; then
                        display_source="$lp"
                        local expanded
                        expanded=$(expand_path "$lp")
                        if [[ -d "$expanded" ]]; then
                            status_icon="${GREEN}✓ exists${NC}"
                        else
                            status_icon="${YELLOW}✗ path missing${NC}"
                        fi
                    else
                        display_source="@local (not configured)"
                        status_icon="${RED}✗ needs path${NC}"
                    fi
                else
                    local expanded
                    expanded=$(expand_path "$source")
                    if [[ -d "$expanded" ]]; then
                        status_icon="${GREEN}✓ exists${NC}"
                    else
                        status_icon="${YELLOW}✗ path missing${NC}"
                    fi
                fi
                printf "    %-20s %-35s %b\n" "$target" "$display_source" "$status_icon"
            done <<< "$mounts"
        else
            echo "  Extra mounts: (none)"
        fi

        return 0
    fi

    # --repo / --mount: direct set mode
    if [[ ${#repo_args[@]} -gt 0 || ${#mount_args[@]} -gt 0 ]]; then
        for entry in ${repo_args[@]+"${repo_args[@]}"}; do
            local rname="${entry%%=*}"
            local rpath="${entry#*=}"
            _local_paths_set "$local_paths" "repos" "$rname" "$rpath"
            _update_yml_path "$project_yml" "repos" "name" "$rname" "path" "$rpath"
            ok "Saved: $rname → $rpath"
        done
        for entry in ${mount_args[@]+"${mount_args[@]}"}; do
            local mtarget="${entry%%=*}"
            local mpath="${entry#*=}"
            _local_paths_set "$local_paths" "extra_mounts" "$mtarget" "$mpath"
            _update_yml_path "$project_yml" "extra_mounts" "target" "$mtarget" "source" "$mpath"
            ok "Saved: $mtarget → $mpath"
        done
        return 0
    fi

    # Interactive mode: show status and prompt for unresolved
    echo -e "${BOLD}Project: $name${NC}"
    echo ""

    local any_unresolved=false

    # Repos
    local repos
    repos=$(yml_get_repos "$project_yml" 2>/dev/null)
    if [[ -n "$repos" ]]; then
        echo "  Repos:"
        while IFS=: read -r repo_path repo_name; do
            [[ -z "$repo_name" ]] && continue

            local needs_resolve=false
            if [[ "$repo_path" == "@local" || "$repo_path" == *"{{REPO_"* ]]; then
                # Check local-paths.yml
                local lp
                lp=$(_local_paths_get "$local_paths" "repos" "$repo_name")
                if [[ -n "$lp" ]]; then
                    local expanded; expanded=$(expand_path "$lp")
                    if [[ -d "$expanded" ]]; then
                        printf "    %-20s %-35s ${GREEN}✓ exists${NC}\n" "$repo_name" "$lp"
                    else
                        printf "    %-20s %-35s ${YELLOW}✗ path missing${NC}\n" "$repo_name" "$lp"
                        needs_resolve=true
                    fi
                else
                    printf "    %-20s %-35s ${RED}✗ needs path${NC}\n" "$repo_name" "@local (not configured)"
                    needs_resolve=true
                fi
            else
                local expanded; expanded=$(expand_path "$repo_path")
                if [[ -d "$expanded" ]]; then
                    printf "    %-20s %-35s ${GREEN}✓ exists${NC}\n" "$repo_name" "$repo_path"
                else
                    printf "    %-20s %-35s ${YELLOW}✗ path missing${NC}\n" "$repo_name" "$repo_path"
                    needs_resolve=true
                fi
            fi

            if $needs_resolve; then
                any_unresolved=true
                local url
                url=$(_get_repo_url "$project_yml" "$repo_name")
                local resolved
                resolved=$(_resolve_entry "$project_dir" "repos" "$repo_name" "$url")
                local rc=$?
                if [[ $rc -eq 0 && -n "$resolved" ]]; then
                    _update_yml_path "$project_yml" "repos" "name" "$repo_name" "path" "$resolved"
                elif [[ $rc -eq 2 ]]; then
                    return 0
                fi
            fi
        done <<< "$repos"
    fi

    echo ""

    # Extra mounts
    local mounts
    mounts=$(yml_get_extra_mounts "$project_yml" 2>/dev/null)
    if [[ -n "$mounts" ]]; then
        echo "  Extra mounts:"
        while IFS= read -r mount_line; do
            [[ -z "$mount_line" ]] && continue
            local source="${mount_line%%:*}"
            local rest="${mount_line#*:}"
            local target="${rest%%:*}"

            if [[ "$source" == "@local" ]]; then
                local lp
                lp=$(_local_paths_get "$local_paths" "extra_mounts" "$target")
                if [[ -n "$lp" ]]; then
                    local expanded; expanded=$(expand_path "$lp")
                    if [[ -d "$expanded" ]]; then
                        printf "    %-20s %-35s ${GREEN}✓ exists${NC}\n" "$target" "$lp"
                    else
                        printf "    %-20s %-35s ${YELLOW}✗ path missing${NC}\n" "$target" "$lp"
                        any_unresolved=true
                        local resolved
                        resolved=$(_resolve_entry "$project_dir" "extra_mounts" "$target" "")
                        local rc=$?
                        if [[ $rc -eq 0 && -n "$resolved" ]]; then
                            _update_yml_path "$project_yml" "extra_mounts" "target" "$target" "source" "$resolved"
                        elif [[ $rc -eq 2 ]]; then
                            return 0
                        fi
                    fi
                else
                    printf "    %-20s %-35s ${RED}✗ needs path${NC}\n" "$target" "@local (not configured)"
                    any_unresolved=true
                    local resolved
                    resolved=$(_resolve_entry "$project_dir" "extra_mounts" "$target" "")
                    local rc=$?
                    if [[ $rc -eq 0 && -n "$resolved" ]]; then
                        _update_yml_path "$project_yml" "extra_mounts" "target" "$target" "source" "$resolved"
                    elif [[ $rc -eq 2 ]]; then
                        return 0
                    fi
                fi
            else
                local expanded; expanded=$(expand_path "$source")
                if [[ -d "$expanded" ]]; then
                    printf "    %-20s %-35s ${GREEN}✓ exists${NC}\n" "$target" "$source"
                else
                    printf "    %-20s %-35s ${YELLOW}✗ path missing${NC}\n" "$target" "$source"
                fi
            fi
        done <<< "$mounts"
    fi

    echo ""
    if ! $any_unresolved; then
        ok "All paths resolved."
    fi
}
