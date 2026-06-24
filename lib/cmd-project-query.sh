#!/usr/bin/env bash
# lib/cmd-project-query.sh — Project listing and display
#
# Provides: cmd_project_list(), cmd_project_show()
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
            echo -e "  ${YELLOW}⚠${NC} ${yml_name:-$name}: $_unresolved reference(s) unresolved — run 'cco resolve $name' to configure them"
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
