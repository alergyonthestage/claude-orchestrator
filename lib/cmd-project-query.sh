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
            repo_count=$(_effective_repo_mounts "$project_yml" | grep -c . 2>/dev/null || echo "0")
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

# Classify a member repo's role w.r.t. <project> (ADR-0024 D5):
#   host (its <repo>/.cco/ hosts this project) · synced (.cco present, in sync) ·
#   divergent (.cco edited since last sync) · code-only (no .cco).
_project_member_role() {
    local repo_path="$1" project="$2" repo_name="$3"
    # Central projects mount via @local/local-paths; fall back to the index path.
    [[ ! -d "$repo_path" && -n "$repo_name" ]] && repo_path=$(_index_get_path "$repo_name" 2>/dev/null)
    [[ -n "$repo_path" && -f "$repo_path/.cco/project.yml" ]] || { printf 'code-only'; return 0; }
    local hosted; hosted=$(_cco_project_id "$repo_path" 2>/dev/null)
    if [[ "$hosted" == "$project" ]]; then printf 'host'
    elif _sync_is_divergent "$repo_path" 2>/dev/null; then printf 'divergent'
    else printf 'synced'; fi
}

# Repo-centric view (ADR-0024 D5): from a repo dir, report the project it hosts,
# its members + each member's resolution, and the projects referencing this repo.
_project_show_repo_centric() {
    local repo="$1" hosted
    hosted=$(_cco_project_id "$repo")
    echo -e "${BOLD}Repo:${NC} $repo"
    echo "  hosts project: $hosted"
    echo ""
    echo -e "${BOLD}Members:${NC}"
    local _line rn p refby any=false
    while IFS= read -r _line; do
        rn="${_line%%$'\t'*}"
        [[ -z "$rn" ]] && continue
        any=true
        p=$(_index_get_path "$rn" 2>/dev/null)
        refby=$(_index_repos_get_projects "$rn" 2>/dev/null | grep -vxF "$hosted" | paste -sd, - 2>/dev/null)
        local l="  $rn"
        [[ -n "$p" ]] && l="$l ($p)" || l="$l (unresolved)"
        [[ -n "$refby" ]] && l="$l — also in: $refby"
        echo "$l"
    done < <(yml_get_repo_coords "$repo/.cco/project.yml")
    $any || echo "  (none)"
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

    # Repo-centric view (ADR-0024 D5): invoked from a repo dir that hosts a
    # project, with no explicit name → summarize this repo's relationships.
    if [[ -z "$name" && -f "$PWD/.cco/project.yml" ]]; then
        _project_show_repo_centric "$PWD"
        return $?
    fi
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

    # Repos (schema-agnostic via the bridge: name<TAB>abs_path)
    echo -e "${BOLD}Repos:${NC}"
    local repos
    repos=$(_effective_repo_mounts "$project_yml")
    if [[ -n "$repos" ]]; then
        local repo_name repo_path
        local _unresolved=0
        while IFS=$'\t' read -r repo_name repo_path; do
            [[ -z "$repo_name" ]] && continue
            # D5 (ADR-0024): each member's role + the other projects referencing it.
            local role refby
            role=$(_project_member_role "$repo_path" "${yml_name:-$name}" "$repo_name")
            refby=$(_index_repos_get_projects "$repo_name" 2>/dev/null | grep -vxF "${yml_name:-$name}" | paste -sd, - 2>/dev/null)
            local suffix="[$role]"
            [[ -n "$refby" ]] && suffix="$suffix — also referenced by: $refby"
            if [[ -d "$repo_path" ]]; then
                echo "  $repo_name ($repo_path) $suffix"
            else
                echo -e "  $repo_name (${repo_path:-unresolved}) ${YELLOW}[missing]${NC} $suffix"
                _unresolved=$(( _unresolved + 1 ))
            fi
        done <<< "$repos"
        # Passive ⚠ badge (F49 / ADR-0019 D2 layer-e) — awareness, never a block.
        if [[ $_unresolved -gt 0 ]]; then
            echo -e "  ${YELLOW}⚠${NC} ${yml_name:-$name}: $_unresolved reference(s) unresolved — run 'cco project validate' for details"
        fi
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

    # Repos paths exist (schema-agnostic via the bridge: name<TAB>abs_path)
    local repos
    repos=$(_effective_repo_mounts "$project_yml")
    if [[ -z "$repos" ]]; then
        warn "Project '$name': no repos configured"
    else
        local repo_name repo_path
        while IFS=$'\t' read -r repo_name repo_path; do
            [[ -z "$repo_name" ]] && continue
            if [[ ! -d "$repo_path" ]]; then
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

    # --show: display current mappings.
    # Delegates to _project_effective_paths (single source of truth, same
    # helper used by `cco start` via _assert_resolved_paths). This
    # eliminates the old divergence where --show could report `✓ exists`
    # for an entry that cco start then rejected with "Unresolved" — they
    # now derive from the exact same data (fix #B18).
    if $show_only; then
        echo -e "${BOLD}Project: $name${NC}"
        echo ""

        local have_repos=false have_mounts=false
        local effective_lines
        effective_lines=$(_project_effective_paths "$project_dir")

        # Repos section
        local kind key effective status display_path status_icon
        echo "  Repos:"
        while IFS=$'\t' read -r kind key effective status; do
            [[ "$kind" != "repos" ]] && continue
            have_repos=true
            case "$status" in
                exists)     display_path="$effective"; status_icon="${GREEN}✓ exists${NC}" ;;
                missing)    display_path="$effective"; status_icon="${YELLOW}✗ path missing${NC}" ;;
                unresolved) display_path="@local (not configured)"; status_icon="${RED}✗ needs path${NC}" ;;
            esac
            printf "    %-20s %-35s %b\n" "$key" "$display_path" "$status_icon"
        done <<< "$effective_lines"
        $have_repos || echo "    (none)"

        echo ""

        # Extra mounts section
        echo "  Extra mounts:"
        while IFS=$'\t' read -r kind key effective status; do
            [[ "$kind" != "mounts" ]] && continue
            have_mounts=true
            case "$status" in
                exists)     display_path="$effective"; status_icon="${GREEN}✓ exists${NC}" ;;
                missing)    display_path="$effective"; status_icon="${YELLOW}✗ path missing${NC}" ;;
                unresolved) display_path="@local (not configured)"; status_icon="${RED}✗ needs path${NC}" ;;
            esac
            printf "    %-20s %-35s %b\n" "$key" "$display_path" "$status_icon"
        done <<< "$effective_lines"
        $have_mounts || echo "    (none)"

        return 0
    fi

    # --repo / --mount: direct set mode. Schema-bridged: legacy projects keep
    # writing local-paths.yml + project.yml; new-schema projects write the index.
    if [[ ${#repo_args[@]} -gt 0 || ${#mount_args[@]} -gt 0 ]]; then
        local _legacy_repos _legacy_mounts
        _legacy_repos=$(yml_get_repos "$project_yml" 2>/dev/null)
        _legacy_mounts=$(yml_get_extra_mounts "$project_yml" 2>/dev/null)
        for entry in ${repo_args[@]+"${repo_args[@]}"}; do
            local rname="${entry%%=*}"
            local rpath="${entry#*=}"
            if [[ -n "$_legacy_repos" ]]; then
                _local_paths_set "$local_paths" "repos" "$rname" "$rpath"
                _update_yml_path "$project_yml" "repos" "name" "$rname" "path" "$rpath"
            else
                _index_set_path "$rname" "$(expand_path "$rpath")"
            fi
            ok "Saved: $rname → $rpath"
        done
        for entry in ${mount_args[@]+"${mount_args[@]}"}; do
            local mtarget="${entry%%=*}"
            local mpath="${entry#*=}"
            if [[ -n "$_legacy_mounts" ]]; then
                _local_paths_set "$local_paths" "extra_mounts" "$mtarget" "$mpath"
                _update_yml_path "$project_yml" "extra_mounts" "target" "$mtarget" "source" "$mpath"
            else
                _index_set_path "$mtarget" "$(expand_path "$mpath")"
            fi
            ok "Saved: $mtarget → $mpath"
        done
        return 0
    fi

    # Interactive mode: show status and prompt for unresolved.
    # Single source of truth (same as --show): _project_effective_paths
    # emits one tab-separated line per repo/mount with kind/key/path/status.
    # This eliminates two copies of the display logic and fixes #B21 —
    # the previous inline loop used `-d` (directory-only), so file-mounts
    # like .docx were always "path missing" and did not set
    # any_unresolved → the summary printed "All paths resolved".
    echo -e "${BOLD}Project: $name${NC}"
    echo ""

    local effective_lines
    effective_lines=$(_project_effective_paths "$project_dir")

    local any_unresolved=false
    local -a unresolved_entries=()  # kind<TAB>key per entry

    # Repos section
    local kind key effective status display_path status_icon
    local have_repos=false
    echo "  Repos:"
    while IFS=$'\t' read -r kind key effective status; do
        [[ "$kind" != "repos" ]] && continue
        have_repos=true
        case "$status" in
            exists)
                display_path="$effective"
                status_icon="${GREEN}✓ exists${NC}"
                ;;
            missing)
                display_path="$effective"
                status_icon="${YELLOW}✗ path missing${NC}"
                any_unresolved=true
                unresolved_entries+=("repos"$'\t'"$key")
                ;;
            unresolved)
                display_path="@local (not configured)"
                status_icon="${RED}✗ needs path${NC}"
                any_unresolved=true
                unresolved_entries+=("repos"$'\t'"$key")
                ;;
        esac
        printf "    %-20s %-35s %b\n" "$key" "$display_path" "$status_icon"
    done <<< "$effective_lines"
    $have_repos || echo "    (none)"

    echo ""

    # Extra mounts section
    local have_mounts=false
    echo "  Extra mounts:"
    while IFS=$'\t' read -r kind key effective status; do
        [[ "$kind" != "mounts" ]] && continue
        have_mounts=true
        case "$status" in
            exists)
                display_path="$effective"
                status_icon="${GREEN}✓ exists${NC}"
                ;;
            missing)
                display_path="$effective"
                status_icon="${YELLOW}✗ path missing${NC}"
                any_unresolved=true
                unresolved_entries+=("extra_mounts"$'\t'"$key")
                ;;
            unresolved)
                display_path="@local (not configured)"
                status_icon="${RED}✗ needs path${NC}"
                any_unresolved=true
                unresolved_entries+=("extra_mounts"$'\t'"$key")
                ;;
        esac
        printf "    %-20s %-35s %b\n" "$key" "$display_path" "$status_icon"
    done <<< "$effective_lines"
    $have_mounts || echo "    (none)"

    echo ""

    if ! $any_unresolved; then
        ok "All paths resolved."
        return 0
    fi

    # Prompt interactively for every unresolved entry. Schema-bridged: legacy
    # projects resolve via local-paths.yml + project.yml; new-schema projects
    # resolve into the STATE index (no project.yml path write — AD3).
    local entry section path_field key_field url resolved rc legacy
    for entry in ${unresolved_entries[@]+"${unresolved_entries[@]}"}; do
        IFS=$'\t' read -r section key <<< "$entry"
        url=""
        if [[ "$section" == "repos" ]]; then
            path_field="path"; key_field="name"
            legacy=$(yml_get_repos "$project_yml" 2>/dev/null)
            if [[ -n "$legacy" ]]; then
                url=$(_get_repo_url "$project_yml" "$key")
            else
                url=$(yml_get_repo_coords "$project_yml" 2>/dev/null | awk -F'\t' -v n="$key" '$1==n{print $2; exit}')
            fi
        else
            path_field="source"; key_field="target"
            legacy=$(yml_get_extra_mounts "$project_yml" 2>/dev/null)
        fi
        rc=0
        if [[ -n "$legacy" ]]; then
            resolved=$(_resolve_entry "$project_dir" "$section" "$key" "$url") || rc=$?
            if [[ $rc -eq 0 && -n "$resolved" ]]; then
                _update_yml_path "$project_yml" "$section" "$key_field" "$key" "$path_field" "$resolved"
            elif [[ $rc -eq 2 ]]; then
                return 0
            fi
        else
            resolved=$(_resolve_entry_index "$project_dir" "$section" "$key" "$url") || rc=$?
            [[ $rc -eq 2 ]] && return 0
        fi
    done
}
