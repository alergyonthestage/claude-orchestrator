#!/usr/bin/env bash
# lib/cmd-template.sh — Template management commands
#
# Provides: cmd_template(), _resolve_template()
# Dependencies: colors.sh, utils.sh, yaml.sh
# Globals: TEMPLATES_DIR, NATIVE_TEMPLATES_DIR, PROJECTS_DIR, PACKS_DIR

# ── Template Resolution ──────────────────────────────────────────────

# Resolve a template by name. Checks user templates first, then native.
# Usage: _resolve_template "project" "base"
# Outputs the resolved template directory path.
_resolve_template() {
    local kind="$1"    # "project" or "pack"
    local name="$2"    # template name or empty for "base"

    name="${name:-base}"

    # 1. User templates (priority)
    if [[ -d "$TEMPLATES_DIR/$kind/$name" ]]; then
        echo "$TEMPLATES_DIR/$kind/$name"
        return 0
    fi

    # 2. Native templates (fallback)
    if [[ -d "$NATIVE_TEMPLATES_DIR/$kind/$name" ]]; then
        echo "$NATIVE_TEMPLATES_DIR/$kind/$name"
        return 0
    fi

    die "Template '$name' not found for $kind. Run 'cco template list --$kind' to see available templates."
}

# ── Template Commands ─────────────────────────────────────────────────

cmd_template() {
    local subcmd="${1:-}"
    if [[ -z "$subcmd" || "$subcmd" == "--help" ]]; then
        cat <<'EOF'
Usage: cco template <command> [options]

Commands:
  list [--project|--pack]    List available templates
  show <name>                Show template details
  create <name>              Create a new user template
  remove <name>              Remove a user template

Run 'cco template <command> --help' for command-specific options.
EOF
        return 0
    fi
    shift

    case "$subcmd" in
        list)   cmd_template_list "$@" ;;
        show)   cmd_template_show "$@" ;;
        create) cmd_template_create "$@" ;;
        remove) cmd_template_remove "$@" ;;
        *)      die "Unknown template command: $subcmd. Run 'cco template --help'." ;;
    esac
}

cmd_template_list() {
    local filter=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project) filter="project"; shift ;;
            --pack)    filter="pack"; shift ;;
            --help)
                cat <<'EOF'
Usage: cco template list [--project|--pack]

List all available templates (native + user-defined).
EOF
                return 0
                ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    local found=false

    # List project templates
    if [[ -z "$filter" || "$filter" == "project" ]]; then
        echo "Project templates:"
        # Native
        if [[ -d "$NATIVE_TEMPLATES_DIR/project" ]]; then
            local d
            for d in "$NATIVE_TEMPLATES_DIR/project"/*/; do
                [[ ! -d "$d" ]] && continue
                local name
                name=$(basename "$d")
                local desc=""
                if [[ -f "$d/template.yml" ]]; then
                    desc=$(awk '/^description:/ {$1=""; sub(/^ /, ""); print}' "$d/template.yml")
                fi
                printf "  %-20s (native)  %s\n" "$name" "$desc"
                found=true
            done
        fi
        # User
        if [[ -d "$TEMPLATES_DIR/project" ]]; then
            local d
            for d in "$TEMPLATES_DIR/project"/*/; do
                [[ ! -d "$d" ]] && continue
                local name
                name=$(basename "$d")
                local desc=""
                if [[ -f "$d/template.yml" ]]; then
                    desc=$(awk '/^description:/ {$1=""; sub(/^ /, ""); print}' "$d/template.yml")
                fi
                printf "  %-20s (user)    %s\n" "$name" "$desc"
                found=true
            done
        fi
        echo ""
    fi

    # List pack templates
    if [[ -z "$filter" || "$filter" == "pack" ]]; then
        echo "Pack templates:"
        # Native
        if [[ -d "$NATIVE_TEMPLATES_DIR/pack" ]]; then
            local d
            for d in "$NATIVE_TEMPLATES_DIR/pack"/*/; do
                [[ ! -d "$d" ]] && continue
                local name
                name=$(basename "$d")
                printf "  %-20s (native)\n" "$name"
                found=true
            done
        fi
        # User
        if [[ -d "$TEMPLATES_DIR/pack" ]]; then
            local d
            for d in "$TEMPLATES_DIR/pack"/*/; do
                [[ ! -d "$d" ]] && continue
                local name
                name=$(basename "$d")
                printf "  %-20s (user)\n" "$name"
                found=true
            done
        fi
        echo ""
    fi

    if ! $found; then
        info "No templates found."
    fi
}

cmd_template_show() {
    local name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                cat <<'EOF'
Usage: cco template show <name>

Show details about a template including its structure and variables.
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

    [[ -z "$name" ]] && die "Usage: cco template show <name>"

    # Try to find in both project and pack
    local template_dir="" kind=""
    for k in project pack; do
        if [[ -d "$TEMPLATES_DIR/$k/$name" ]]; then
            template_dir="$TEMPLATES_DIR/$k/$name"
            kind="$k (user)"
            break
        elif [[ -d "$NATIVE_TEMPLATES_DIR/$k/$name" ]]; then
            template_dir="$NATIVE_TEMPLATES_DIR/$k/$name"
            kind="$k (native)"
            break
        fi
    done

    [[ -z "$template_dir" ]] && die "Template '$name' not found."

    echo "Template: $name"
    echo "Type: $kind"
    echo "Path: $template_dir"

    if [[ -f "$template_dir/template.yml" ]]; then
        echo ""
        echo "Metadata (template.yml):"
        sed 's/^/  /' "$template_dir/template.yml"
    fi

    echo ""
    echo "Structure:"
    # Simple tree-like output
    (cd "$template_dir" && find . -type f | sed 's|^\./|  |' | sort)
}

cmd_template_create() {
    check_global
    local name=""
    local kind=""
    local from=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project) kind="project"; shift ;;
            --pack)    kind="pack"; shift ;;
            --from)
                [[ -z "${2:-}" ]] && die "--from requires a resource path"
                from="$2"; shift 2 ;;
            --help)
                cat <<'EOF'
Usage: cco template create <name> --project|--pack [--from <resource>]

Create a new user template.

Options:
  --project          Create a project template
  --pack             Create a pack template
  --from <resource>  Create template from an existing project or pack
                     (e.g., --from projects/my-app or --from packs/my-pack)
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

    [[ -z "$name" ]] && die "Usage: cco template create <name> --project|--pack"
    [[ -z "$kind" ]] && die "Specify --project or --pack"

    # Validate name
    if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
        die "Template name must be lowercase letters, numbers, and hyphens only."
    fi

    local target_dir="$TEMPLATES_DIR/$kind/$name"
    [[ -d "$target_dir" ]] && die "Template '$name' already exists at templates/$kind/$name/"

    mkdir -p "$TEMPLATES_DIR/$kind"

    if [[ -n "$from" ]]; then
        # Create from existing resource
        local source_dir=""
        if [[ -d "$PROJECTS_DIR/$from" ]]; then
            source_dir="$PROJECTS_DIR/$from"
        elif [[ -d "$PACKS_DIR/$from" ]]; then
            source_dir="$PACKS_DIR/$from"
        elif [[ -d "$from" ]]; then
            source_dir="$from"
        else
            die "Resource '$from' not found."
        fi

        cp -r "$source_dir" "$target_dir"

        # Strip runtime state and generated artifacts
        rm -rf "$target_dir/.cco" "$target_dir/.tmp"
        # Clear secrets content but keep the file
        if [[ -f "$target_dir/secrets.env" ]]; then
            > "$target_dir/secrets.env"
        fi

        ok "Template '$name' created from '$from'"
        info "Review and customize at: templates/$kind/$name/"
        info "Consider replacing project-specific values with {{PLACEHOLDER}} variables."
    else
        # Create empty template from base
        local base_dir
        base_dir=$(_resolve_template "$kind" "base")
        cp -r "$base_dir" "$target_dir"

        ok "Template '$name' created at templates/$kind/$name/"
        info "Customize the template files, then use with:"
        info "  cco $kind create <name> --template $name"
    fi
}

cmd_template_remove() {
    local name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                cat <<'EOF'
Usage: cco template remove <name>

Remove a user-defined template. Native templates cannot be removed.
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

    [[ -z "$name" ]] && die "Usage: cco template remove <name>"

    # Find in user templates only
    local found_dir=""
    for k in project pack; do
        if [[ -d "$TEMPLATES_DIR/$k/$name" ]]; then
            found_dir="$TEMPLATES_DIR/$k/$name"
            break
        fi
    done

    [[ -z "$found_dir" ]] && die "User template '$name' not found. Only user templates can be removed."

    rm -rf "$found_dir"
    ok "Template '$name' removed."
}

# Resolve {{VARIABLE}} patterns in project template files (relocated here from the
# removed cmd-project-create.sh; consumed by `cco project install`/`update`).
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
