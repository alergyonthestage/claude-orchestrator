#!/usr/bin/env bash
# lib/cmd-project.sh — Project management commands
#
# Provides: cmd_project_create(), cmd_project_list(), cmd_project_show(),
#           cmd_project_validate(), cmd_project_install(),
#           cmd_project_add_pack(), cmd_project_remove_pack(),
#           cmd_project_publish()
# Dependencies: colors.sh, utils.sh, yaml.sh, remote.sh, manifest.sh
# Globals: PROJECTS_DIR, GLOBAL_DIR, NATIVE_TEMPLATES_DIR, TEMPLATES_DIR, USER_CONFIG_DIR

cmd_project_create() {
    check_global

    local name=""
    local repos=()
    local description=""
    local template_name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo) repos+=("$2"); shift 2 ;;
            --description) description="$2"; shift 2 ;;
            --template)
                [[ -z "${2:-}" ]] && die "--template requires a template name"
                template_name="$2"; shift 2 ;;
            --help)
                cat <<'EOF'
Usage: cco project create <name> [OPTIONS]

Options:
  --repo <path>        Add a repo to the project (repeatable)
  --description <d>    Project description
  --template <name>    Use a specific template (default: base)
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
    _check_reserved_project_name "$name"

    local project_dir="$PROJECTS_DIR/$name"
    [[ -d "$project_dir" ]] && die "Project '$name' already exists at projects/$name/"

    # Resolve template
    local template_dir
    template_dir=$(_resolve_template "project" "${template_name:-base}")

    # Copy template
    cp -r "$template_dir" "$project_dir"

    # Replace placeholders
    [[ -z "$description" ]] && description="TODO: Add project description"

    # Update project.yml
    local project_yml="$project_dir/project.yml"
    sed -i '' "s/{{PROJECT_NAME}}/$name/g" "$project_yml" 2>/dev/null || \
        sed -i "s/{{PROJECT_NAME}}/$name/g" "$project_yml"
    sed -i '' "s/{{DESCRIPTION}}/$description/g" "$project_yml" 2>/dev/null || \
        sed -i "s/{{DESCRIPTION}}/$description/g" "$project_yml"

    # Substitute framework path placeholders (used by config-editor, etc.)
    sed -i '' "s|{{CCO_REPO_ROOT}}|$REPO_ROOT|g" "$project_yml" 2>/dev/null || \
        sed -i "s|{{CCO_REPO_ROOT}}|$REPO_ROOT|g" "$project_yml"
    sed -i '' "s|{{CCO_USER_CONFIG_DIR}}|$USER_CONFIG_DIR|g" "$project_yml" 2>/dev/null || \
        sed -i "s|{{CCO_USER_CONFIG_DIR}}|$USER_CONFIG_DIR|g" "$project_yml"

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

    # Ensure claude-state and memory dirs exist
    mkdir -p "$project_dir/.cco/claude-state"
    mkdir -p "$project_dir/memory"

    # ── Bootstrap .cco/meta, .cco/base/, .cco/source ─────────────────
    # Initialize update system metadata for the new project.

    # Determine template source string for .cco/source
    local template_source=""
    local resolved_template_name="${template_name:-base}"
    if [[ -d "$TEMPLATES_DIR/project/$resolved_template_name" ]]; then
        # User template
        template_source="user:template/$resolved_template_name"
    else
        # Native template
        template_source="native:project/$resolved_template_name"
    fi

    # Write .cco/source only for non-base templates (base is the default, tracked via .cco/meta)
    mkdir -p "$project_dir/.cco"
    if [[ "$resolved_template_name" != "base" ]]; then
        printf '%s\n' "$template_source" > "$project_dir/.cco/source"
    fi

    # Generate .cco/meta with schema_version and manifest
    local latest_schema
    latest_schema=$(_latest_schema_version "project")
    local now
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local meta_file="$project_dir/.cco/meta"

    # Build manifest entries from tracked project files
    # Use actual template source (not always base) for .cco/base/ seeding
    local defaults_dir
    local resolved_tmpl_dir="$NATIVE_TEMPLATES_DIR/project/$resolved_template_name/.claude"
    if [[ -d "$resolved_tmpl_dir" ]]; then
        defaults_dir="$resolved_tmpl_dir"
    else
        defaults_dir="$NATIVE_TEMPLATES_DIR/project/base/.claude"
    fi
    (
        local entry rel policy
        for entry in "${PROJECT_FILE_POLICIES[@]}"; do
            rel="${entry%:*}"
            policy="${entry##*:}"
            [[ "$policy" != "tracked" ]] && continue
            rel="${rel#.claude/}"
            if [[ -f "$project_dir/.claude/$rel" ]]; then
                printf '%s\t%s\n' "$rel" "$(_file_hash "$project_dir/.claude/$rel")"
            fi
        done
    ) | _generate_project_cco_meta "$meta_file" "$latest_schema" "$now" "$resolved_template_name"

    # Save base versions for future 3-way merge
    _save_all_base_versions "$project_dir/.cco/base" "$defaults_dir" "project"

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
Usage: cco project install <source> [options]

Install a project template from a remote Config Repo.

Arguments:
  <source>            Git URL or registered remote name

Options:
  --pick <name>       Install a specific template by name
  --as <name>         Override the project name (default: template name)
  --var KEY=VALUE     Pre-set a template variable (repeatable)
  --token <token>     Auth token for HTTPS repos
  --force             Overwrite existing project without asking

URL can include @ref suffix: <url>@<branch-or-tag>

Examples:
  cco project install albit --pick acme-service
  cco project install https://github.com/team/config.git
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

    [[ -z "$url" ]] && die "Usage: cco project install <source> [--pick <name>]\n\n<source> can be a git URL or a registered remote name."
    check_global

    # Resolve remote name → URL + token
    local resolved_url
    resolved_url=$(remote_get_url "$url" 2>/dev/null) || true
    if [[ -n "$resolved_url" ]]; then
        if [[ -z "$token" ]]; then
            token=$(remote_get_token "$url" 2>/dev/null) || true
        fi
        url="$resolved_url"
    fi

    # Parse @ref suffix
    local ref=""
    if [[ "$url" == *@* ]]; then
        local after_at="${url##*@}"
        if [[ "$after_at" != *:* && "$after_at" != *.* ]]; then
            ref="$after_at"
            url="${url%@*}"
        fi
    fi

    # Auto-resolve token from registered remote if not explicitly provided
    if [[ -z "$token" ]]; then
        token=$(remote_resolve_token_for_url "$url" 2>/dev/null) || true
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
    _check_reserved_project_name "$project_name"

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

    # Resolve repo entries: validate paths, offer to clone from url if available
    _resolve_repo_entries "$target_dir/project.yml" "${vars[@]+"${vars[@]}"}"

    # Auto-install packs from the same Config Repo
    local -a installed_packs=()
    local project_packs
    project_packs=$(yml_get_packs "$target_dir/project.yml" 2>/dev/null)
    while IFS= read -r pack_name; do
        [[ -z "$pack_name" ]] && continue
        if [[ -d "$PACKS_DIR/$pack_name" ]]; then
            info "Pack '$pack_name' already installed — skipping"
        elif [[ -d "$tmpdir/packs/$pack_name" ]]; then
            info "Auto-installing pack '$pack_name' from Config Repo..."
            _install_pack_from_dir "$tmpdir/packs/$pack_name" "$pack_name" "$url" "$ref" "packs/$pack_name" false
            installed_packs+=("$pack_name")
        else
            warn "Pack '$pack_name' required but not found. Install manually."
        fi
    done <<< "$project_packs"

    # Ensure claude-state and memory dirs exist
    mkdir -p "$target_dir/.cco/claude-state"
    mkdir -p "$target_dir/memory"

    # Write .cco/source with remote origin metadata
    local install_commit=""
    install_commit=$(git -C "$tmpdir" rev-parse HEAD 2>/dev/null) || true
    {
        printf 'source: %s\n' "$url"
        printf 'path: templates/%s\n' "$pick"
        [[ -n "$ref" ]] && printf 'ref: %s\n' "$ref"
        printf 'installed: %s\n' "$(date +%Y-%m-%d)"
        [[ -n "$install_commit" ]] && printf 'commit: %s\n' "$install_commit"
    } > "$target_dir/.cco/source"

    # Save base versions from remote template (for future 3-way merge)
    local project_base_dir="$target_dir/.cco/base"
    mkdir -p "$project_base_dir"
    if [[ -d "$template_dir/.claude" ]]; then
        _save_all_base_versions "$project_base_dir" "$template_dir/.claude" "project"
    fi

    _cleanup_clone "$tmpdir"
    trap - EXIT

    # Update manifest
    manifest_refresh "$USER_CONFIG_DIR"

    ok "Project '$project_name' installed from $url"
    if [[ ${#installed_packs[@]} -gt 0 ]]; then
        ok "Auto-installed packs: ${installed_packs[*]}"
    fi
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
            # Non-interactive: use sensible defaults or fail for required vars
            case "$name" in
                DESCRIPTION) value="TODO: Add project description" ;;
                REPO_*)
                    die "Required variable '$name' not set. Use --var $name=<path> in non-interactive mode."
                    ;;
                *)  value="$name" ;;
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

# Resolve repo entries in an installed project: validate paths exist,
# offer to clone from url: field if available and path is missing.
# Usage: _resolve_repo_entries <project_yml> [vars...]
_resolve_repo_entries() {
    local project_yml="$1"
    shift

    local repos
    repos=$(yml_get_repos "$project_yml" 2>/dev/null)
    [[ -z "$repos" ]] && return 0

    local -a cloned_repos=()
    while IFS=: read -r repo_path repo_name; do
        [[ -z "$repo_path" ]] && continue
        local expanded
        expanded=$(expand_path "$repo_path")

        if [[ -d "$expanded" ]]; then
            continue  # path exists, nothing to do
        fi

        # Check if there's a url: field for this repo
        local repo_url
        repo_url=$(awk -v name="$repo_name" '
            /^repos:/ { in_repos=1; next }
            in_repos && /^[^ #]/ { exit }
            in_repos && /^    name:/ {
                n=$0; sub(/^    name: */, "", n); gsub(/[\"'\''[:space:]]/, "", n)
                current_name=n
            }
            in_repos && /^    url:/ && current_name == name {
                u=$0; sub(/^    url: */, "", u); gsub(/[\"'\''[:space:]]/, "", u)
                print u; exit
            }
        ' "$project_yml")

        if [[ -n "$repo_url" ]] && [[ -t 0 ]]; then
            echo ""
            echo -e "  ${BOLD}$repo_name${NC} ($repo_url)"
            echo -e "  Path ${YELLOW}$repo_path${NC} does not exist."
            printf "  Clone from %s? [Y/n] " "$repo_url" >&2
            local reply
            read -r reply < /dev/tty
            if [[ -z "$reply" || "$reply" =~ ^[Yy]$ ]]; then
                local parent; parent=$(dirname "$expanded")
                mkdir -p "$parent"
                info "Cloning into $expanded..."
                if git clone "$repo_url" "$expanded" >/dev/null 2>&1; then
                    cloned_repos+=("$repo_name")
                    ok "Cloned $repo_name"
                else
                    warn "Failed to clone $repo_url"
                fi
            fi
        elif [[ -n "$repo_url" ]]; then
            warn "Repo path $repo_path does not exist. Clone manually: git clone $repo_url $expanded"
        else
            warn "Repo path $repo_path does not exist."
        fi
    done <<< "$repos"

    if [[ ${#cloned_repos[@]} -gt 0 ]]; then
        ok "Repos cloned: ${cloned_repos[*]}"
    fi
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
        BEGIN { found=0 }
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

# ── project publish ──────────────────────────────────────────────────

cmd_project_publish() {
    local name="" remote_arg="" message="" dry_run=false force=false
    local token="" include_packs=true yes_mode=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --message)
                [[ -z "${2:-}" ]] && die "--message requires a value"
                message="$2"; shift 2 ;;
            --dry-run)        dry_run=true; shift ;;
            --force)          force=true; shift ;;
            --yes)            yes_mode=true; shift ;;
            --token)
                [[ -z "${2:-}" ]] && die "--token requires a value"
                token="$2"; shift 2 ;;
            --no-packs)       include_packs=false; shift ;;
            --help)
                cat <<'EOF'
Usage: cco project publish <name> [<remote>] [OPTIONS]

Publish a project template to a remote Config Repo with safety checks:
migration validation, secret scan, framework alignment, and diff review.

Arguments:
  <name>             Project to publish
  <remote>           Remote name or URL

Options:
  --message <msg>    Commit message (default: "publish project <name>")
  --dry-run          Show what would be published, don't push
  --force            Overwrite remote version without confirmation
  --yes              Skip interactive prompts (safety checks still apply)
  --no-packs         Don't bundle project's packs
  --token <token>    Auth token for HTTPS remotes
EOF
                return 0
                ;;
            -*)  die "Unknown option: $1" ;;
            *)
                if [[ -z "$name" ]]; then
                    name="$1"
                elif [[ -z "$remote_arg" ]]; then
                    remote_arg="$1"
                else
                    die "Unexpected argument: $1"
                fi
                shift
                ;;
        esac
    done

    [[ -z "$name" ]] && die "Usage: cco project publish <name> [<remote>]"

    local project_dir="$PROJECTS_DIR/$name"
    local project_yml="$project_dir/project.yml"
    [[ ! -f "$project_yml" ]] && die "Project '$name' not found."

    [[ -z "$remote_arg" ]] && die "Remote required. Usage: cco project publish <name> <remote>"

    # Resolve remote URL
    local remote_url="" remote_is_named=false
    local resolved
    if resolved=$(remote_get_url "$remote_arg"); then
        remote_url="$resolved"
        remote_is_named=true
    elif [[ "$remote_arg" == *:* || "$remote_arg" == */* ]]; then
        remote_url="$remote_arg"
    else
        die "Remote '$remote_arg' not found. Register with 'cco remote add $remote_arg <url>'."
    fi

    # Auto-resolve token from remote if not explicitly provided
    if [[ -z "$token" ]]; then
        if $remote_is_named; then
            token=$(remote_get_token "$remote_arg" 2>/dev/null) || true
        else
            token=$(remote_resolve_token_for_url "$remote_url" 2>/dev/null) || true
        fi
    fi

    [[ -z "$message" ]] && message="publish project $name"

    # ── Pre-publish safety pipeline ──────────────────────────────────

    # STEP 1: MIGRATION CHECK (blocking)
    # Only block publish if project has been through the update system and has
    # pending migrations. Projects with schema_version matching latest are current.
    # Projects without .cco/meta or with uninitialized schema (0) are not checked.
    local meta_file
    meta_file=$(_cco_project_meta "$project_dir")
    if [[ -f "$meta_file" ]]; then
        local current_schema
        current_schema=$(_read_cco_meta "$meta_file")
        local latest_schema
        latest_schema=$(_latest_schema_version "project")
        # Check if project was created by current system (has created_at or template field)
        # and has fallen behind on migrations
        if [[ "$current_schema" -gt 0 ]]; then
            local has_created_at=""
            has_created_at=$(grep -c "^created_at:" "$meta_file" 2>/dev/null) || true
            if [[ "${has_created_at:-0}" -gt 0 && "$current_schema" -lt "$latest_schema" ]]; then
                error "Project '$name' has pending migrations (schema: $current_schema, latest: $latest_schema)."
                die "Run 'cco update' first to apply migrations."
            fi
        fi
    fi

    # STEP 2: FRAMEWORK ALIGNMENT CHECK (warning)
    local defaults_dir
    defaults_dir=$(_resolve_project_defaults_dir "$project_dir")
    local base_dir
    base_dir=$(_cco_project_base_dir "$project_dir")
    local fw_changes
    fw_changes=$(_collect_file_changes "$defaults_dir" "$project_dir/.claude" "$base_dir" "project")
    local fw_actionable
    fw_actionable=$(echo "$fw_changes" | grep -cvE '^(NO_UPDATE|USER_MODIFIED|$)' || true)

    if [[ $fw_actionable -gt 0 ]]; then
        warn "$fw_actionable framework default(s) have updates not yet applied."
        warn "Run 'cco update --sync $name' to review before publishing."
        if [[ "$yes_mode" != "true" && -t 0 ]]; then
            printf "Continue anyway? [y/N] " >&2
            local reply
            read -r reply < /dev/tty
            [[ ! "$reply" =~ ^[Yy]$ ]] && die "Aborted."
        fi
    fi

    # STEP 3: SECRET SCAN (blocking)
    # Scan files that would actually be published. Excludes: .cco/, memory/,
    # secrets.env (same exclusion list as _copy_project_for_publish).
    local -a secret_hits=()
    local -a _scan_dirs=()
    [[ -d "$project_dir/.claude" ]] && _scan_dirs+=("$project_dir/.claude")

    # Also scan publishable root files (project.yml, setup.sh, etc.)
    for _root_item in "$project_dir"/*; do
        [[ ! -e "$_root_item" ]] && continue
        local _root_base
        _root_base=$(basename "$_root_item")
        # Skip excluded items
        case "$_root_base" in
            .cco|.claude|memory|secrets.env) continue ;;
        esac
        [[ -f "$_root_item" ]] && _scan_dirs+=("$_root_item")
    done

    for _scan_target in "${_scan_dirs[@]+"${_scan_dirs[@]}"}"; do
        while IFS= read -r file; do
            [[ -z "$file" ]] && continue
            [[ "$file" == */.cco/* ]] && continue
            local base_name
            base_name=$(basename "$file")
            for pattern in '*.env' '*.key' '*.pem' '.credentials.json'; do
                case "$base_name" in
                    $pattern)
                        local rel="${file#$project_dir/}"
                        secret_hits+=("$rel")
                        break
                        ;;
                esac
            done
        done < <(find "$_scan_target" -type f 2>/dev/null)
    done

    if [[ ${#secret_hits[@]} -gt 0 ]]; then
        error "Potential secrets detected in publishable files:"
        for f in "${secret_hits[@]}"; do
            error "  - $f"
        done
        die "Remove secrets or add patterns to .cco/publish-ignore"
    fi

    info "Publishing project '$name' to $remote_url..."

    # Clone remote repo
    local tmpdir
    tmpdir=$(_clone_for_publish "$remote_url" "$token")
    trap "_cleanup_clone '$tmpdir'" EXIT

    # Check for existing template on remote
    if [[ -d "$tmpdir/templates/$name" ]]; then
        if ! $force && ! $dry_run; then
            warn "Template '$name' already exists on remote."
            if [[ -t 0 ]]; then
                printf "Overwrite? [y/N] " >&2
                local reply; read -r reply
                [[ ! "$reply" =~ ^[Yy]$ ]] && { _cleanup_clone "$tmpdir"; die "Aborted."; }
            else
                _cleanup_clone "$tmpdir"
                die "Template exists on remote. Use --force to overwrite."
            fi
        fi
        rm -rf "$tmpdir/templates/$name"
    fi

    # Copy project to templates/<name>/
    mkdir -p "$tmpdir/templates/$name"
    _copy_project_for_publish "$project_dir" "$tmpdir/templates/$name"

    # Reverse-template repo paths in the published project.yml
    _reverse_template_repos "$tmpdir/templates/$name/project.yml"

    # Bundle packs if requested
    local -a published_packs=()
    if $include_packs; then
        local project_packs
        project_packs=$(yml_get_packs "$project_yml")
        while IFS= read -r pack_name; do
            [[ -z "$pack_name" ]] && continue
            if [[ -d "$PACKS_DIR/$pack_name" ]]; then
                # Copy pack to remote (internalize if needed)
                _publish_pack_to_tmpdir "$pack_name" "$tmpdir"
                published_packs+=("$pack_name")
            else
                warn "Pack '$pack_name' not found locally — skipping"
            fi
        done <<< "$project_packs"
    fi

    # Refresh manifest in temp dir
    manifest_refresh "$tmpdir"

    if $dry_run; then
        echo ""
        echo -e "${BOLD}Would publish:${NC}"
        echo "  Template: $name"
        if [[ ${#published_packs[@]} -gt 0 ]]; then
            echo "  Packs: ${published_packs[*]}"
        fi
        echo "  Remote: $remote_url"
        echo "  Files:"
        find "$tmpdir/templates/$name" -type f | sed "s|$tmpdir/||; s/^/    /"
        _cleanup_clone "$tmpdir"
        trap - EXIT
        ok "Dry run complete — nothing pushed"
        return 0
    fi

    # Commit and push
    git -C "$tmpdir" add -A
    git -C "$tmpdir" commit -q -m "$message"
    local publish_commit
    publish_commit=$(git -C "$tmpdir" rev-parse HEAD 2>/dev/null) || true
    git -C "$tmpdir" push origin HEAD >/dev/null 2>&1 \
        || { _cleanup_clone "$tmpdir"; die "Failed to push to $remote_url"; }

    _cleanup_clone "$tmpdir"
    trap - EXIT

    # Update publish metadata in .cco/source
    local source_file
    source_file=$(_cco_project_source "$project_dir")
    if [[ ! -f "$source_file" ]]; then
        # Create .cco/source for locally-created projects (track publish history)
        mkdir -p "$(dirname "$source_file")"
        printf 'source: local\n' > "$source_file"
    fi
    yml_set "$source_file" "published" "$(date +%Y-%m-%d)"
    [[ -n "$publish_commit" ]] && yml_set "$source_file" "publish_commit" "$publish_commit"

    local summary="Published project '$name'"
    if [[ ${#published_packs[@]} -gt 0 ]]; then
        summary+=" with packs: ${published_packs[*]}"
    fi
    ok "$summary"
}

# Copy project files for publishing, excluding runtime/generated files.
# Reads .cco/publish-ignore for additional exclusion patterns.
_copy_project_for_publish() {
    local src="$1" dst="$2"

    # Copy everything except excluded patterns
    local -a excludes=(
        ".cco"
        "memory"
        "secrets.env"
    )

    # Read .cco/publish-ignore patterns
    local -a ignore_patterns=()
    local ignore_file="$src/.cco/publish-ignore"
    if [[ -f "$ignore_file" ]]; then
        while IFS= read -r line; do
            # Skip comments and empty lines
            [[ -z "$line" || "$line" == \#* ]] && continue
            ignore_patterns+=("$line")
        done < "$ignore_file"
    fi

    # Build rsync-like exclusion via find + copy
    find "$src" -mindepth 1 -maxdepth 1 | while IFS= read -r item; do
        local base
        base=$(basename "$item")
        local skip=false
        for excl in "${excludes[@]}"; do
            [[ "$base" == "$excl" ]] && { skip=true; break; }
        done
        $skip && continue
        cp -R "$item" "$dst/"
    done

    # Remove nested .cco/ directories that were copied inside .claude/
    find "$dst" -mindepth 2 -name ".cco" -type d -exec rm -rf {} + 2>/dev/null || true

    # Apply publish-ignore patterns
    if [[ ${#ignore_patterns[@]} -gt 0 ]]; then
        local pattern
        for pattern in "${ignore_patterns[@]}"; do
            # Use find with -name or -path for glob matching
            find "$dst" -name "$pattern" -exec rm -rf {} + 2>/dev/null || true
            find "$dst" -path "*/$pattern" -exec rm -rf {} + 2>/dev/null || true
        done
    fi
}

# Reverse-template repo paths: replace local paths with {{REPO_NAME}} variables
# and add url: field from git remote.
_reverse_template_repos() {
    local yml_file="$1"

    # Capture original repo info BEFORE transforming paths
    # Format: "path:name" per line
    local orig_repos
    orig_repos=$(yml_get_repos "$yml_file" 2>/dev/null)

    # Build url map: name → git remote URL (best-effort)
    local url_map=""
    if [[ -n "$orig_repos" ]]; then
        while IFS=: read -r repo_path repo_name; do
            [[ -z "$repo_name" ]] && continue
            local expanded
            expanded=$(expand_path "$repo_path" 2>/dev/null) || continue
            if [[ -d "$expanded/.git" ]]; then
                local remote_url
                remote_url=$(git -C "$expanded" remote get-url origin 2>/dev/null) || true
                if [[ -n "$remote_url" ]]; then
                    url_map+="${repo_name}=${remote_url}"$'\n'
                fi
            fi
        done <<< "$orig_repos"
    fi

    # Replace paths with template variables and add url: fields
    awk -v url_map="$url_map" '
        BEGIN {
            n = split(url_map, entries, "\n")
            for (i = 1; i <= n; i++) {
                if (entries[i] == "") continue
                eq = index(entries[i], "=")
                if (eq > 0) {
                    k = substr(entries[i], 1, eq - 1)
                    urls[k] = substr(entries[i], eq + 1)
                }
            }
        }
        /^repos:/ { in_repos=1; print; next }
        in_repos && /^[^ #]/ { in_repos=0; print; next }
        in_repos && /^  - path:/ {
            saved=$0; getline
            if ($0 ~ /^    name:/) {
                name_line=$0
                sub(/^    name: */, "", name_line)
                gsub(/[\"'\''[:space:]]/, "", name_line)
                var = toupper(name_line)
                gsub(/-/, "_", var)
                print "  - path: \"{{REPO_" var "}}\""
                print $0
                if (name_line in urls) {
                    print "    url: " urls[name_line]
                }
            } else {
                print saved
                print $0
            }
            next
        }
        { print }
    ' "$yml_file" > "$yml_file.tmp" && mv "$yml_file.tmp" "$yml_file"
}

# Publish a pack into a tmpdir for bundling with a project.
_publish_pack_to_tmpdir() {
    local pack_name="$1" tmpdir="$2"
    local pack_dir="$PACKS_DIR/$pack_name"

    mkdir -p "$tmpdir/packs"
    if [[ -d "$tmpdir/packs/$pack_name" ]]; then
        rm -rf "$tmpdir/packs/$pack_name"
    fi
    cp -R "$pack_dir" "$tmpdir/packs/$pack_name"
    rm -rf "$tmpdir/packs/$pack_name/.cco"

    # Internalize if source-referencing
    local k_source=""
    k_source=$(yml_get_pack_knowledge_source "$tmpdir/packs/$pack_name/pack.yml")
    if [[ -n "$k_source" ]]; then
        local expanded_source
        expanded_source=$(expand_path "$k_source")
        if [[ -d "$expanded_source" ]]; then
            local k_files
            k_files=$(yml_get_pack_knowledge_files "$tmpdir/packs/$pack_name/pack.yml")
            mkdir -p "$tmpdir/packs/$pack_name/knowledge"
            while IFS=$'\t' read -r fname desc; do
                [[ -z "$fname" ]] && continue
                local src="$expanded_source/$fname"
                if [[ -f "$src" ]]; then
                    mkdir -p "$(dirname "$tmpdir/packs/$pack_name/knowledge/$fname")"
                    cp "$src" "$tmpdir/packs/$pack_name/knowledge/$fname"
                fi
            done <<< "$k_files"

            local tmpf; tmpf=$(mktemp)
            awk '
                /^knowledge:/ { in_k=1; print; next }
                in_k && /^  source:/ { next }
                in_k && /^[^ #]/ { in_k=0 }
                { print }
            ' "$tmpdir/packs/$pack_name/pack.yml" > "$tmpf"
            mv "$tmpf" "$tmpdir/packs/$pack_name/pack.yml"
        fi
    fi
}

# ── Project Update from Remote ────────────────────────────────────────

cmd_project_update() {
    local name="" force=false dry_run=false update_all=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)     update_all=true; shift ;;
            --force)   force=true; shift ;;
            --dry-run) dry_run=true; shift ;;
            --help)
                cat <<'EOF'
Usage: cco project update <name> [--force] [--dry-run]
       cco project update --all [--dry-run]

Check for and apply updates from the remote source of an installed project.
Uses 3-way merge to preserve your local customizations.

Options:
  --all       Update all installed projects
  --force     Replace all files without interactive merge (.bak saved)
  --dry-run   Show what would change without modifying files
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

    check_global

    if $update_all; then
        local updated=0
        for project_dir in "$PROJECTS_DIR"/*/; do
            [[ ! -d "$project_dir" ]] && continue
            [[ ! -f "$project_dir/project.yml" ]] && continue
            if _is_installed_project "$project_dir"; then
                local proj_name
                proj_name=$(basename "$project_dir")
                info "Checking project '$proj_name'..."
                _update_single_project "$proj_name" "$force" "$dry_run"
                updated=$((updated + 1))
            fi
        done
        if [[ $updated -eq 0 ]]; then
            info "No projects with remote sources found."
        fi
        return 0
    fi

    [[ -z "$name" ]] && die "Usage: cco project update <name> [--force] [--dry-run]"
    [[ ! -d "$PROJECTS_DIR/$name" ]] && die "Project '$name' not found."

    _update_single_project "$name" "$force" "$dry_run"
}

_update_single_project() {
    local name="$1"
    local force="${2:-false}"
    local dry_run="${3:-false}"

    local project_dir="$PROJECTS_DIR/$name"
    local source_file
    source_file=$(_cco_project_source "$project_dir")

    if ! _is_installed_project "$project_dir"; then
        die "Project '$name' is local — no remote source to update from. Use 'cco update --sync $name' for framework updates."
    fi

    local source_url="$_INSTALLED_SOURCE_URL"
    local source_ref="$_INSTALLED_SOURCE_REF"
    local source_path="$_INSTALLED_SOURCE_PATH"
    local installed_commit="$_INSTALLED_SOURCE_COMMIT"

    # Vault snapshot offer — use git commit with .gitignore respected (no -A)
    if [[ -d "$USER_CONFIG_DIR/.git" && "$dry_run" != "true" ]]; then
        if [[ -t 0 ]]; then
            printf "Create vault snapshot before updating? [Y/n] " >&2
            local reply
            read -r reply < /dev/tty
            if [[ ! "$reply" =~ ^[Nn]$ ]]; then
                # Stage only tracked + new gitignore-respecting files (no -A to avoid secrets)
                (cd "$USER_CONFIG_DIR" && git add --all --ignore-errors . && git diff --cached --quiet 2>/dev/null || git commit -q -m "vault: snapshot before project update ($name)") 2>/dev/null || true
                ok "Vault snapshot created."
            fi
        fi
    fi

    # Auto-resolve token from registered remote
    local token=""
    token=$(remote_resolve_token_for_url "$source_url" 2>/dev/null) || true

    info "Fetching $source_url${source_ref:+ (ref: $source_ref)}..."
    local tmpdir
    tmpdir=$(_clone_config_repo "$source_url" "$source_ref" "$token")
    trap "_cleanup_clone '$tmpdir'" EXIT

    # Compare versions
    local remote_head
    remote_head=$(git -C "$tmpdir" rev-parse HEAD 2>/dev/null) || true
    if [[ -n "$installed_commit" && "$remote_head" == "$installed_commit" ]]; then
        ok "Project '$name' is already up to date."
        _cleanup_clone "$tmpdir"
        trap - EXIT
        return 0
    fi

    # Locate remote project directory
    local remote_dir="$tmpdir"
    if [[ -n "$source_path" ]]; then
        remote_dir="$tmpdir/$source_path"
    fi

    if [[ ! -d "$remote_dir" ]]; then
        _cleanup_clone "$tmpdir"
        trap - EXIT
        die "Remote path '$source_path' not found in cloned repo."
    fi

    # Resolve template variables in fetched version (same as install)
    _resolve_template_vars "$remote_dir" "$name" "PROJECT_NAME=$name" 2>/dev/null || true

    # Set up paths for 3-way merge
    local installed_dir="$project_dir/.claude"
    local base_dir
    base_dir=$(_cco_project_base_dir "$project_dir")
    local remote_claude_dir="$remote_dir/.claude"

    if [[ ! -d "$remote_claude_dir" ]]; then
        warn "No .claude/ directory in remote project template."
        _cleanup_clone "$tmpdir"
        trap - EXIT
        return 0
    fi

    # Collect file changes (3-way: remote vs base vs installed)
    local changes
    changes=$(_collect_file_changes "$remote_claude_dir" "$installed_dir" "$base_dir" "project")

    local actionable
    actionable=$(echo "$changes" | grep -cvE '^(NO_UPDATE|USER_MODIFIED|$)' || true)

    if [[ $actionable -eq 0 ]]; then
        ok "Project '$name' files are up to date (remote has same content)."
        # Still update metadata (commit hash may differ)
    else
        local scope_label="Project '$name' (publisher update)"
        if [[ "$dry_run" == "true" ]]; then
            _show_discovery_summary "$changes" "$scope_label"
            _cleanup_clone "$tmpdir"
            trap - EXIT
            return 0
        fi

        local auto_action=""
        [[ "$force" == "true" ]] && auto_action="replace"

        _interactive_sync "$changes" "$remote_claude_dir" "$installed_dir" "$base_dir" "false" "$auto_action" "$scope_label"
    fi

    # Update .cco/base/ to new remote version (for future merges)
    if [[ "$dry_run" != "true" ]]; then
        _save_all_base_versions "$base_dir" "$remote_claude_dir" "project"

        # Update .cco/source metadata
        yml_set "$source_file" "commit" "$remote_head"
        yml_set "$source_file" "updated" "$(date +%Y-%m-%d)"

        # Read version field if publisher provides one
        if [[ -f "$remote_dir/.cco/source" ]]; then
            local new_version
            new_version=$(yml_get "$remote_dir/.cco/source" "version" 2>/dev/null)
            [[ -n "$new_version" ]] && yml_set "$source_file" "version" "$new_version"
        fi

        # Update remote cache in .cco/meta
        local meta_file
        meta_file=$(_cco_project_meta "$project_dir")
        yml_set "$meta_file" "remote_cache.commit" "$remote_head"
        yml_set "$meta_file" "remote_cache.checked" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

        local short_old="${installed_commit:0:7}"
        local short_new="${remote_head:0:7}"
        [[ -z "$short_old" ]] && short_old="unknown"
        ok "Updated project '$name' (${short_old} -> ${short_new})"
    fi

    _cleanup_clone "$tmpdir"
    trap - EXIT
}

# ── Project Internalize ───────────────────────────────────────────────

cmd_project_internalize() {
    local name="" yes_mode=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes)  yes_mode=true; shift ;;
            --help)
                cat <<'EOF'
Usage: cco project internalize <name> [--yes]

Disconnect a project from its remote source, converting it to a local project.
After internalizing, framework updates apply directly via 'cco update --sync'.

Options:
  --yes     Skip confirmation prompt
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

    [[ -z "$name" ]] && die "Usage: cco project internalize <name>"

    local project_dir="$PROJECTS_DIR/$name"
    [[ ! -d "$project_dir" ]] && die "Project '$name' not found."

    if ! _is_installed_project "$project_dir"; then
        ok "Project '$name' is already local."
        return 0
    fi

    local source_url="$_INSTALLED_SOURCE_URL"

    # Confirm (required unless --yes)
    if [[ "$yes_mode" != "true" ]]; then
        if [[ -t 0 ]]; then
            printf "This will disconnect '%s' from %s.\n" "$name" "$source_url" >&2
            printf "You will no longer receive publisher updates.\n" >&2
            printf "Framework updates will apply directly via 'cco update --sync'.\n" >&2
            printf "Continue? [y/N] " >&2
            local reply
            read -r reply < /dev/tty
            [[ ! "$reply" =~ ^[Yy]$ ]] && die "Aborted."
        else
            die "Non-interactive mode: use --yes to confirm internalization."
        fi
    fi

    local source_file
    source_file=$(_cco_project_source "$project_dir")

    # Update .cco/source — source: local must be first line for format detection
    {
        printf 'source: local\n'
        printf '# previously installed from: %s\n' "$source_url"
    } > "$source_file"

    # Update .cco/base/ to framework base template (for future cco update --sync)
    local base_dir
    base_dir=$(_cco_project_base_dir "$project_dir")
    rm -rf "$base_dir"
    mkdir -p "$base_dir"
    _save_all_base_versions "$base_dir" "$NATIVE_TEMPLATES_DIR/project/base/.claude" "project"

    # Clear remote cache and override marker from .cco/meta
    local meta_file
    meta_file=$(_cco_project_meta "$project_dir")
    if [[ -f "$meta_file" ]]; then
        yml_remove "$meta_file" "remote_cache"
        yml_remove "$meta_file" "local_framework_override"
    fi

    ok "Project '$name' is now local. Framework updates will apply directly via 'cco update --sync'."
}
