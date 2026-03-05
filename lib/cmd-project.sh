#!/usr/bin/env bash
# lib/cmd-project.sh — Project management commands
#
# Provides: cmd_project_create(), cmd_project_list(), cmd_project_show(),
#           cmd_project_validate(), cmd_project_install(),
#           cmd_project_add_pack(), cmd_project_remove_pack()
# Dependencies: colors.sh, utils.sh, yaml.sh, remote.sh, manifest.sh
# Globals: PROJECTS_DIR, GLOBAL_DIR, TEMPLATE_DIR, USER_CONFIG_DIR

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

    if [[ $errors -gt 0 ]]; then
        return 1
    fi
    ok "Project '$name' is valid"
}

# ── Project Install ──────────────────────────────────────────────────

cmd_project_install() {
    local url="" pick="" as_name="" token="" force=false
    local -a vars=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pick)
                [[ -z "${2:-}" ]] && die "--pick requires a template name"
                pick="$2"; shift 2
                ;;
            --as)
                [[ -z "${2:-}" ]] && die "--as requires a project name"
                as_name="$2"; shift 2
                ;;
            --token)
                [[ -z "${2:-}" ]] && die "--token requires a value"
                token="$2"; shift 2
                ;;
            --var)
                [[ -z "${2:-}" ]] && die "--var requires KEY=VALUE"
                vars+=("$2"); shift 2
                ;;
            --force) force=true; shift ;;
            --help)
                cat <<'EOF'
Usage: cco project install <git-url> [options]

Install a project template from a remote Config Repo.

Options:
  --pick <name>       Install a specific template by name
  --as <name>         Override the project name (default: template name)
  --var KEY=VALUE     Pre-set a template variable (repeatable)
  --token <token>     Auth token for HTTPS repos
  --force             Overwrite existing project without asking

URL can include @ref suffix: <url>@<branch-or-tag>
EOF
                return 0
                ;;
            -*)  die "Unknown option: $1" ;;
            *)
                if [[ -z "$url" ]]; then
                    url="$1"; shift
                else
                    die "Unexpected argument: $1"
                fi
                ;;
        esac
    done

    [[ -z "$url" ]] && die "Usage: cco project install <git-url> [--pick <name>]"
    check_global

    # Parse @ref suffix
    local ref=""
    if [[ "$url" == *@* ]]; then
        local after_at="${url##*@}"
        if [[ "$after_at" != *:* && "$after_at" != *.* ]]; then
            ref="$after_at"
            url="${url%@*}"
        fi
    fi

    info "Cloning $url${ref:+ (ref: $ref)}..."
    local tmpdir
    tmpdir=$(_clone_config_repo "$url" "$ref" "$token")
    trap "_cleanup_clone '$tmpdir'" EXIT

    # Detect repo type
    local manifest_file=""
    if [[ -f "$tmpdir/manifest.yml" ]]; then
        manifest_file="$tmpdir/manifest.yml"
    else
        _cleanup_clone "$tmpdir"
        die "Not a valid CCO Config Repo: no manifest.yml found"
    fi

    # Read available templates from manifest
    local available
    available=$(_manifest_get_names "$manifest_file" "templates")

    if [[ -z "$available" ]]; then
        _cleanup_clone "$tmpdir"
        die "No templates listed in manifest"
    fi

    if [[ -n "$pick" ]]; then
        if ! echo "$available" | grep -qxF "$pick"; then
            _cleanup_clone "$tmpdir"
            die "Template '$pick' not found in manifest. Available: $(echo "$available" | tr '\n' ' ')"
        fi
    else
        # If only one template, auto-select
        local count
        count=$(echo "$available" | grep -c . || true)
        if [[ $count -eq 1 ]]; then
            pick=$(echo "$available" | head -1)
        else
            info "Available templates:"
            echo "$available" | sed 's/^/  - /'
            die "Multiple templates found. Use --pick <name> to select one."
        fi
    fi

    local template_dir="$tmpdir/templates/$pick"
    if [[ ! -d "$template_dir" ]]; then
        _cleanup_clone "$tmpdir"
        die "Template directory 'templates/$pick' not found in repo"
    fi

    # Determine project name
    local project_name="${as_name:-$pick}"

    # Validate project name
    if [[ ! "$project_name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
        _cleanup_clone "$tmpdir"
        die "Project name must be lowercase letters, numbers, and hyphens only."
    fi

    local target_dir="$PROJECTS_DIR/$project_name"

    # Conflict check
    if [[ -d "$target_dir" ]]; then
        if [[ "$force" == true ]]; then
            rm -rf "$target_dir"
        else
            _cleanup_clone "$tmpdir"
            die "Project '$project_name' already exists. Use --force to overwrite."
        fi
    fi

    # Copy template
    cp -r "$template_dir" "$target_dir"

    # Resolve template variables in key files
    _resolve_template_vars "$target_dir" "$project_name" "${vars[@]+"${vars[@]}"}"

    # Ensure claude-state dir exists
    mkdir -p "$target_dir/claude-state/memory"

    _cleanup_clone "$tmpdir"
    trap - EXIT

    ok "Project '$project_name' installed from $url"
    info "Edit projects/$project_name/project.yml to configure repos"
    info "Run: cco start $project_name"
}

# Resolve {{VARIABLE}} patterns in project template files.
# Scans project.yml and .claude/CLAUDE.md for placeholders.
# Pre-set values via vars array; prompts interactively for remaining.
# Usage: _resolve_template_vars <project_dir> <project_name> [vars...]
_resolve_template_vars() {
    local project_dir="$1"
    local project_name="$2"
    shift 2

    # Build lookup of preset vars as newline-separated "KEY=VALUE" entries
    # (bash 3.2 compatible — no associative arrays)
    local preset_list=""
    while [[ $# -gt 0 ]]; do
        preset_list+="$1"$'\n'
        shift
    done

    # Always preset PROJECT_NAME (unless already in list)
    if ! echo "$preset_list" | grep -q "^PROJECT_NAME="; then
        preset_list+="PROJECT_NAME=$project_name"$'\n'
    fi

    # Find all template files to process
    local -a template_files=()
    [[ -f "$project_dir/project.yml" ]] && template_files+=("$project_dir/project.yml")
    [[ -f "$project_dir/.claude/CLAUDE.md" ]] && template_files+=("$project_dir/.claude/CLAUDE.md")

    # Collect all variables from all files
    local all_vars=""
    for file in "${template_files[@]+"${template_files[@]}"}"; do
        local file_vars
        file_vars=$(grep -oE '\{\{[A-Z_]+\}\}' "$file" 2>/dev/null | sort -u || true)
        all_vars+="$file_vars"$'\n'
    done
    all_vars=$(echo "$all_vars" | sort -u | grep -v '^$' || true)

    [[ -z "$all_vars" ]] && return 0

    # Build sed substitution args
    local -a sed_args=()
    local var name value
    for var in $all_vars; do
        name="${var//[\{\}]/}"

        # Lookup in preset list
        local preset_match
        preset_match=$(echo "$preset_list" | grep "^${name}=" | head -1 || true)

        if [[ -n "$preset_match" ]]; then
            value="${preset_match#*=}"
        elif [[ -t 0 ]]; then
            # Interactive prompt
            local default=""
            case "$name" in
                DESCRIPTION) default="TODO: Add project description" ;;
            esac
            if [[ -n "$default" ]]; then
                read -rp "  $name [$default]: " value < /dev/tty
                value="${value:-$default}"
            else
                read -rp "  $name: " value < /dev/tty
            fi
            [[ -z "$value" ]] && die "Value required for $name"
        else
            # Non-interactive: use sensible defaults
            case "$name" in
                DESCRIPTION) value="TODO: Add project description" ;;
                *)           value="$name" ;;
            esac
        fi

        sed_args+=("-e" "s|{{$name}}|$value|g")
    done

    # Apply substitutions to all template files
    for file in "${template_files[@]+"${template_files[@]}"}"; do
        sed -i '' "${sed_args[@]}" "$file" 2>/dev/null || \
            sed -i "${sed_args[@]}" "$file"
    done
}

# ── add-pack / remove-pack ───────────────────────────────────────────

cmd_project_add_pack() {
    local project="" pack=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                cat <<'EOF'
Usage: cco project add-pack <project> <pack>

Add a knowledge pack to a project's packs list in project.yml.
EOF
                return 0
                ;;
            -*)  die "Unknown option: $1" ;;
            *)
                if [[ -z "$project" ]]; then
                    project="$1"
                elif [[ -z "$pack" ]]; then
                    pack="$1"
                else
                    die "Unexpected argument: $1"
                fi
                shift
                ;;
        esac
    done

    [[ -z "$project" || -z "$pack" ]] && die "Usage: cco project add-pack <project> <pack>"

    local project_dir="$PROJECTS_DIR/$project"
    local project_yml="$project_dir/project.yml"
    [[ ! -f "$project_yml" ]] && die "Project '$project' not found at $project_dir/"

    # Validate pack exists
    [[ ! -d "$PACKS_DIR/$pack" ]] && die "Pack '$pack' not found in packs/."

    # Check if already present
    if _project_has_pack "$project_yml" "$pack"; then
        warn "Pack '$pack' is already in project '$project'"
        return 0
    fi

    # Add pack to project.yml
    _project_yml_add_pack "$project_yml" "$pack"
    ok "Added pack '$pack' to project '$project'"
}

cmd_project_remove_pack() {
    local project="" pack=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                cat <<'EOF'
Usage: cco project remove-pack <project> <pack>

Remove a knowledge pack from a project's packs list in project.yml.
EOF
                return 0
                ;;
            -*)  die "Unknown option: $1" ;;
            *)
                if [[ -z "$project" ]]; then
                    project="$1"
                elif [[ -z "$pack" ]]; then
                    pack="$1"
                else
                    die "Unexpected argument: $1"
                fi
                shift
                ;;
        esac
    done

    [[ -z "$project" || -z "$pack" ]] && die "Usage: cco project remove-pack <project> <pack>"

    local project_dir="$PROJECTS_DIR/$project"
    local project_yml="$project_dir/project.yml"
    [[ ! -f "$project_yml" ]] && die "Project '$project' not found at $project_dir/"

    # Check if pack is in project
    if ! _project_has_pack "$project_yml" "$pack"; then
        warn "Pack '$pack' is not in project '$project'"
        return 0
    fi

    # Remove pack from project.yml
    _project_yml_remove_pack "$project_yml" "$pack"
    ok "Removed pack '$pack' from project '$project'"
}

# Check if a pack is listed in project.yml's packs section.
_project_has_pack() {
    local file="$1" pack="$2"
    # Match "  - pack-name" under the packs: section
    awk -v pack="$pack" '
        /^packs:/ { in_packs=1; next }
        in_packs && /^[^ #]/ { exit }
        in_packs && /^  - / {
            sub(/^  - */, "")
            gsub(/[\"'\''[:space:]]/, "")
            if ($0 == pack) { found=1; exit }
        }
        END { exit !found }
    ' "$file"
}

# Add a pack entry to project.yml's packs section.
_project_yml_add_pack() {
    local file="$1" pack="$2"

    if grep -q '^packs: *\[\]' "$file" 2>/dev/null; then
        # Replace empty array with list
        awk -v pack="$pack" '
            /^packs: *\[\]/ { print "packs:"; print "  - " pack; next }
            { print }
        ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    elif grep -q '^packs:' "$file" 2>/dev/null; then
        # Append after last pack entry (or after packs: line if section is empty)
        awk -v pack="$pack" '
            /^packs:/ { in_packs=1; print; next }
            in_packs && /^  - / { last_pack=NR; print; next }
            in_packs && /^[^ #]/ {
                # End of packs section — insert before this line
                if (!inserted) { print "  - " pack; inserted=1 }
                in_packs=0; print; next
            }
            { print }
            END { if (in_packs && !inserted) print "  - " pack }
        ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    elif grep -q '^# packs:' "$file" 2>/dev/null; then
        # Commented-out packs section — replace with active one
        awk -v pack="$pack" '
            /^# packs:/ { print "packs:"; print "  - " pack; next }
            { print }
        ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    else
        # No packs section — append one
        printf '\npacks:\n  - %s\n' "$pack" >> "$file"
    fi
}

# Remove a pack entry from project.yml's packs section.
_project_yml_remove_pack() {
    local file="$1" pack="$2"

    awk -v pack="$pack" '
        /^packs:/ { in_packs=1; print; next }
        in_packs && /^[^ #]/ { in_packs=0; print; next }
        in_packs && /^  - / {
            line=$0
            sub(/^  - */, "", line)
            gsub(/[\"'\''[:space:]]/, "", line)
            if (line == pack) next  # skip this entry
        }
        { print }
    ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"

    # If packs section is now empty, replace with packs: []
    if ! awk '/^packs:/ { in_packs=1; next } in_packs && /^  - / { found=1; exit } in_packs && /^[^ #]/ { exit } END { exit !found }' "$file" 2>/dev/null; then
        sed -i '' 's/^packs:$/packs: []/' "$file" 2>/dev/null || \
            sed -i 's/^packs:$/packs: []/' "$file"
    fi
}
