#!/usr/bin/env bash
# lib/cmd-project-create.sh — Create projects from templates
#
# Provides: cmd_project_create(), _resolve_template_vars()
# Dependencies: colors.sh, utils.sh, yaml.sh, paths.sh, cmd-template.sh
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
Usage: cco project create [<name>] [OPTIONS]

Arguments:
  name                 Project name (optional if --template is provided;
                       defaults to the template name)

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

    # Default name to template name when --template is provided
    if [[ -z "$name" && -n "$template_name" ]]; then
        name="$template_name"
    fi
    [[ -z "$name" ]] && die "Usage: cco project create <name>"

    # Validate name
    if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
        die "Project name must be lowercase letters, numbers, and hyphens only."
    fi
    _check_reserved_project_name "$name"

    local project_dir="$PROJECTS_DIR/$name"
    [[ -d "$project_dir" ]] && die "Project '$name' already exists at projects/$name/"

    # Check cross-branch uniqueness (if vault exists)
    if [[ -d "$USER_CONFIG_DIR/.git" ]]; then
        local current_branch
        current_branch=$(git -C "$USER_CONFIG_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)
        local conflict_branch
        if conflict_branch=$(_name_exists_on_other_branch "$USER_CONFIG_DIR" "project" "$name" "$current_branch"); then
            die "Project '$name' already exists on branch '$conflict_branch'. Project names must be unique across all profiles."
        fi
    fi

    # Resolve template
    local template_dir
    template_dir=$(_resolve_template "project" "${template_name:-base}")

    # Copy template
    cp -r "$template_dir" "$project_dir"

    # Replace placeholders
    [[ -z "$description" ]] && description="TODO: Add project description"

    # Update project.yml
    local project_yml="$project_dir/project.yml"
    _substitute "$project_yml" "PROJECT_NAME" "$name"
    _substitute "$project_yml" "DESCRIPTION" "$description"

    # Substitute framework path placeholders (used by config-editor, etc.)
    _sed_i "$project_yml" "{{CCO_REPO_ROOT}}" "$REPO_ROOT" "|"
    _sed_i "$project_yml" "{{CCO_USER_CONFIG_DIR}}" "$USER_CONFIG_DIR" "|"

    # Update CLAUDE.md placeholder replacement
    local claude_md="$project_dir/.claude/CLAUDE.md"
    _substitute "$claude_md" "PROJECT_NAME" "$name"
    _substitute "$claude_md" "DESCRIPTION" "$description"

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
        _sed_i_raw "$project_yml" '/^repos: \[\]/r '"$repos_tmp"
        _sed_i_raw "$project_yml" '/^repos: \[\]/d'
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

    # Save base versions for future 3-way merge.
    # Use the interpolated project directory (not the raw template) so the base
    # reflects what was actually delivered to the user (placeholders resolved).
    _save_all_base_versions "$project_dir/.cco/base" "$project_dir/.claude" "project"

    ok "Project created at projects/$name/"

    # Auto-register in vault profile if active
    local active_profile
    active_profile=$(_get_active_profile 2>/dev/null || true)
    if [[ -n "$active_profile" ]]; then
        _profile_add_to_list "projects" "$name"
        ok "Added to profile '$active_profile' (.vault-profile updated)"
        info "Run 'cco vault save' to commit."
    fi

    info "Edit project.yml to configure repos and settings"
    info "Edit projects/$name/.claude/CLAUDE.md to add instructions for Claude"
    info "Run: cco start $name"
    echo ""
    info "Tip: On your first session, use Claude's /init command to auto-generate"
    info "     detailed CLAUDE.md content based on your codebase."
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
        _sed_i_raw "$file" "${sed_args[@]}"
    done
}
