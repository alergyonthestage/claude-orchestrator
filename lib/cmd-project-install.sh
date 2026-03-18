#!/usr/bin/env bash
# lib/cmd-project-install.sh — Install projects from remote Config Repos
#
# Provides: cmd_project_install(), _resolve_repo_entries()
# Dependencies: colors.sh, utils.sh, yaml.sh, remote.sh, manifest.sh, paths.sh
# NOTE: _resolve_template_vars() is defined in cmd-project-create.sh
# Globals: PROJECTS_DIR, PACKS_DIR, USER_CONFIG_DIR

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

    # Capture commit hash for version tracking
    local clone_commit=""
    clone_commit=$(git -C "$tmpdir" rev-parse HEAD 2>/dev/null) || true

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
            _install_pack_from_dir "$tmpdir/packs/$pack_name" "$pack_name" "$url" "$ref" "packs/$pack_name" false "$clone_commit"
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

    # Save base versions for future 3-way merge.
    # Use the installed directory (after placeholder interpolation) so the base
    # reflects what was actually delivered, not the raw template with {{PLACEHOLDER}}.
    local project_base_dir="$target_dir/.cco/base"
    mkdir -p "$project_base_dir"
    if [[ -d "$target_dir/.claude" ]]; then
        _save_all_base_versions "$project_base_dir" "$target_dir/.claude" "project"
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
