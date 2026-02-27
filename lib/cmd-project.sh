#!/usr/bin/env bash
# lib/cmd-project.sh — Project management commands
#
# Provides: cmd_project_create(), cmd_project_list(), cmd_project_show(),
#           cmd_project_validate()
# Dependencies: colors.sh, utils.sh, yaml.sh
# Globals: PROJECTS_DIR, GLOBAL_DIR, TEMPLATE_DIR

cmd_project_create() {
    check_global

    local name=""
    local repos=()
    local description=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo) repos+=("$2"); shift 2 ;;
            --description) description="$2"; shift 2 ;;
            --help)
                cat <<'EOF'
Usage: cco project create <name> [OPTIONS]

Options:
  --repo <path>        Add a repo to the project (repeatable)
  --description <d>    Project description
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

    [[ -z "$name" ]] && die "Usage: cco project create <name>"

    # Validate name
    if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
        die "Project name must be lowercase letters, numbers, and hyphens only."
    fi

    local project_dir="$PROJECTS_DIR/$name"
    [[ -d "$project_dir" ]] && die "Project '$name' already exists at projects/$name/"

    # Copy template
    cp -r "$TEMPLATE_DIR" "$project_dir"

    # Replace placeholders
    [[ -z "$description" ]] && description="TODO: Add project description"

    # Update project.yml
    local project_yml="$project_dir/project.yml"
    sed -i '' "s/{{PROJECT_NAME}}/$name/g" "$project_yml" 2>/dev/null || \
        sed -i "s/{{PROJECT_NAME}}/$name/g" "$project_yml"
    sed -i '' "s/{{DESCRIPTION}}/$description/g" "$project_yml" 2>/dev/null || \
        sed -i "s/{{DESCRIPTION}}/$description/g" "$project_yml"

    # Update CLAUDE.md placeholder replacement
    local claude_md="$project_dir/.claude/CLAUDE.md"
    sed -i '' "s/{{PROJECT_NAME}}/$name/g" "$claude_md" 2>/dev/null || \
        sed -i "s/{{PROJECT_NAME}}/$name/g" "$claude_md"
    sed -i '' "s/{{DESCRIPTION}}/$description/g" "$claude_md" 2>/dev/null || \
        sed -i "s/{{DESCRIPTION}}/$description/g" "$claude_md"

    # Add repos to project.yml and enrich CLAUDE.md if provided
    if [[ ${#repos[@]} -gt 0 ]]; then
        # Build repos block in a temp file
        local repos_tmp="${project_yml}.repos"
        echo "repos:" > "$repos_tmp"

        # Build repos section for CLAUDE.md
        local claude_repos=""

        for repo in "${repos[@]}"; do
            repo=$(expand_path "$repo")
            local repo_name
            repo_name=$(basename "$repo")
            echo "  - path: $repo" >> "$repos_tmp"
            echo "    name: $repo_name" >> "$repos_tmp"

            # Auto-detect repo info
            local repo_info=""
            if [[ -d "$repo" ]]; then
                if [[ -f "$repo/package.json" ]]; then
                    local pkg_desc
                    pkg_desc=$(python3 -c "import json; d=json.load(open('$repo/package.json')); print(d.get('description',''))" 2>/dev/null || true)
                    local pkg_scripts
                    pkg_scripts=$(python3 -c "
import json
d=json.load(open('$repo/package.json'))
s=d.get('scripts',{})
print(', '.join(['$'+k for k in ['dev','build','test','start','lint'] if k in s]))
" 2>/dev/null || true)
                    [[ -n "$pkg_desc" ]] && repo_info="$pkg_desc"
                    [[ -n "$pkg_scripts" ]] && repo_info="${repo_info:+$repo_info — }Scripts: $pkg_scripts"
                elif [[ -f "$repo/pyproject.toml" ]]; then
                    repo_info="Python project"
                elif [[ -f "$repo/go.mod" ]]; then
                    repo_info="Go module"
                elif [[ -f "$repo/Cargo.toml" ]]; then
                    repo_info="Rust crate"
                fi
            fi

            claude_repos+="- \`/workspace/${repo_name}/\`"
            [[ -n "$repo_info" ]] && claude_repos+=" — ${repo_info}"
            claude_repos+=$'\n'
        done

        # Replace the empty repos line in project.yml
        sed -i '' '/^repos: \[\]/r '"$repos_tmp" "$project_yml" 2>/dev/null || \
            sed -i '/^repos: \[\]/r '"$repos_tmp" "$project_yml"
        sed -i '' '/^repos: \[\]/d' "$project_yml" 2>/dev/null || \
            sed -i '/^repos: \[\]/d' "$project_yml"
        rm -f "$repos_tmp"

        # Enrich CLAUDE.md with detected repo info
        if [[ -n "$claude_repos" ]]; then
            local repos_section="${claude_repos}"
            # Replace the placeholder comment with actual repo info
            local tmp_claude="${claude_md}.tmp"
            awk -v repos="$repos_section" '
                /<!-- List your mounted repositories/ {
                    print repos
                    next
                }
                { print }
            ' "$claude_md" > "$tmp_claude"
            mv "$tmp_claude" "$claude_md"
        fi
    fi

    # Ensure claude-state dir exists
    mkdir -p "$project_dir/claude-state/memory"

    ok "Project created at projects/$name/"
    info "Edit project.yml to configure repos and settings"
    info "Edit projects/$name/.claude/CLAUDE.md to add instructions for Claude"
    info "Run: cco start $name"
    echo ""
    info "Tip: On your first session, use Claude's /init command to auto-generate"
    info "     detailed CLAUDE.md content based on your codebase."
}

cmd_project_list() {
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
            if [[ -d "$GLOBAL_DIR/packs/$pack" ]]; then
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
            if [[ ! -d "$GLOBAL_DIR/packs/$pack" ]]; then
                error "Project '$name': pack '$pack' not found in global/packs/"
                ((errors++))
            fi
        done <<< "$packs"
    fi

    if [[ $errors -gt 0 ]]; then
        return 1
    fi
    ok "Project '$name' is valid"
}
