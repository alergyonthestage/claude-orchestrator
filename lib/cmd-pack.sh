#!/usr/bin/env bash
# lib/cmd-pack.sh — Pack management commands
#
# Provides: cmd_pack_create(), cmd_pack_list(), cmd_pack_show(),
#           cmd_pack_remove(), cmd_pack_validate()
# Dependencies: colors.sh, utils.sh, yaml.sh, packs.sh
# Globals: GLOBAL_DIR, PROJECTS_DIR

# ── Pack commands ─────────────────────────────────────────────────────

cmd_pack_create() {
    check_global

    local name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                cat <<'EOF'
Usage: cco pack create <name>

Create a new knowledge pack.
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

    [[ -z "$name" ]] && die "Usage: cco pack create <name>"

    # Validate name
    if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
        die "Pack name must be lowercase letters, numbers, and hyphens only."
    fi

    local pack_dir="$GLOBAL_DIR/packs/$name"
    [[ -d "$pack_dir" ]] && die "Pack '$name' already exists at global/packs/$name/"

    # Create directory structure
    mkdir -p "$pack_dir"/{knowledge,skills,agents,rules}

    # Generate pack.yml
    cat > "$pack_dir/pack.yml" <<YAML
name: $name

# ── Knowledge files ─────────────────────────────────────────────────
# knowledge:
#   source: ~/path/to/docs    # optional; omit to use pack's own knowledge/ dir
#   files:
#     - path: guide.md
#       description: "Read when working on X"
#     - simple.md

# ── Skills (directory names under skills/) ──────────────────────────
# skills:
#   - deploy

# ── Agents (filenames under agents/) ────────────────────────────────
# agents:
#   - specialist.md

# ── Rules (filenames under rules/) ──────────────────────────────────
# rules:
#   - conventions.md
YAML

    ok "Pack created at global/packs/$name/"
    info "Add resources to the subdirectories:"
    info "  knowledge/ — documentation files"
    info "  skills/    — skill directories (each with SKILL.md)"
    info "  agents/    — agent definition files (.md)"
    info "  rules/     — rule files (.md)"
    info "Edit global/packs/$name/pack.yml to declare resources"
}

cmd_pack_list() {
    check_global

    echo -e "${BOLD}NAME              KNOWLEDGE  SKILLS  AGENTS  RULES${NC}"

    for dir in "$GLOBAL_DIR/packs"/*/; do
        [[ ! -d "$dir" ]] && continue
        local name
        name=$(basename "$dir")

        local pack_yml="$dir/pack.yml"
        local k_count="-" s_count="-" a_count="-" r_count="-"
        if [[ -f "$pack_yml" ]]; then
            k_count=$(yml_get_pack_knowledge_files "$pack_yml" | grep -c . 2>/dev/null || echo "0")
            s_count=$(yml_get_pack_skills "$pack_yml" | grep -c . 2>/dev/null || echo "0")
            a_count=$(yml_get_pack_agents "$pack_yml" | grep -c . 2>/dev/null || echo "0")
            r_count=$(yml_get_pack_rules "$pack_yml" | grep -c . 2>/dev/null || echo "0")
        fi

        printf "%-18s %-11s %-8s %-8s %s\n" "$name" "$k_count" "$s_count" "$a_count" "$r_count"
    done
}

cmd_pack_show() {
    local name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                cat <<'EOF'
Usage: cco pack show <name>

Show details for a knowledge pack.
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

    [[ -z "$name" ]] && die "Usage: cco pack show <name>"

    local pack_dir="$GLOBAL_DIR/packs/$name"
    local pack_yml="$pack_dir/pack.yml"
    [[ ! -d "$pack_dir" ]] && die "Pack '$name' not found at global/packs/$name/"

    # Name
    local yml_name=""
    [[ -f "$pack_yml" ]] && yml_name=$(yml_get "$pack_yml" "name")
    echo -e "${BOLD}Pack: ${yml_name:-$name}${NC}"
    echo ""

    if [[ ! -f "$pack_yml" ]]; then
        warn "pack.yml not found"
        return 0
    fi

    # Knowledge
    echo -e "${BOLD}Knowledge:${NC}"
    local k_source
    k_source=$(yml_get_pack_knowledge_source "$pack_yml")
    if [[ -n "$k_source" ]]; then
        echo "  Source: $k_source"
    fi
    local k_files
    k_files=$(yml_get_pack_knowledge_files "$pack_yml")
    if [[ -n "$k_files" ]]; then
        while IFS=$'\t' read -r kfile kdesc; do
            [[ -z "$kfile" ]] && continue
            kdesc=$(echo "$kdesc" | sed 's/^ *//;s/ *$//')
            if [[ -n "$kdesc" ]]; then
                echo "  - $kfile — $kdesc"
            else
                echo "  - $kfile"
            fi
        done <<< "$k_files"
    else
        echo "  (none)"
    fi
    echo ""

    # Skills
    echo -e "${BOLD}Skills:${NC}"
    local skills
    skills=$(yml_get_pack_skills "$pack_yml")
    if [[ -n "$skills" ]]; then
        while IFS= read -r s; do
            [[ -z "$s" ]] && continue
            echo "  - $s"
        done <<< "$skills"
    else
        echo "  (none)"
    fi
    echo ""

    # Agents
    echo -e "${BOLD}Agents:${NC}"
    local agents
    agents=$(yml_get_pack_agents "$pack_yml")
    if [[ -n "$agents" ]]; then
        while IFS= read -r a; do
            [[ -z "$a" ]] && continue
            echo "  - $a"
        done <<< "$agents"
    else
        echo "  (none)"
    fi
    echo ""

    # Rules
    echo -e "${BOLD}Rules:${NC}"
    local rules
    rules=$(yml_get_pack_rules "$pack_yml")
    if [[ -n "$rules" ]]; then
        while IFS= read -r r; do
            [[ -z "$r" ]] && continue
            echo "  - $r"
        done <<< "$rules"
    else
        echo "  (none)"
    fi
    echo ""

    # Used by projects
    echo -e "${BOLD}Used by projects:${NC}"
    local found_any=false
    if [[ -d "$PROJECTS_DIR" ]]; then
        for proj_dir in "$PROJECTS_DIR"/*/; do
            [[ ! -d "$proj_dir" ]] && continue
            local proj_name
            proj_name=$(basename "$proj_dir")
            [[ "$proj_name" == "_template" ]] && continue
            local proj_yml="$proj_dir/project.yml"
            [[ ! -f "$proj_yml" ]] && continue
            local proj_packs
            proj_packs=$(yml_get_packs "$proj_yml")
            if echo "$proj_packs" | grep -qxF "$name"; then
                echo "  - $proj_name"
                found_any=true
            fi
        done
    fi
    if [[ "$found_any" == false ]]; then
        echo "  (none)"
    fi
}

cmd_pack_remove() {
    local name=""
    local force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force=true; shift ;;
            --help)
                cat <<'EOF'
Usage: cco pack remove <name> [--force]

Remove a knowledge pack.

Options:
  --force   Skip confirmation prompt
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

    [[ -z "$name" ]] && die "Usage: cco pack remove <name>"

    local pack_dir="$GLOBAL_DIR/packs/$name"
    [[ ! -d "$pack_dir" ]] && die "Pack '$name' not found at global/packs/$name/"

    # Check if used by any projects
    local used_by=()
    if [[ -d "$PROJECTS_DIR" ]]; then
        for proj_dir in "$PROJECTS_DIR"/*/; do
            [[ ! -d "$proj_dir" ]] && continue
            local proj_name
            proj_name=$(basename "$proj_dir")
            [[ "$proj_name" == "_template" ]] && continue
            local proj_yml="$proj_dir/project.yml"
            [[ ! -f "$proj_yml" ]] && continue
            local proj_packs
            proj_packs=$(yml_get_packs "$proj_yml")
            if echo "$proj_packs" | grep -qxF "$name"; then
                used_by+=("$proj_name")
            fi
        done
    fi

    if [[ ${#used_by[@]} -gt 0 ]]; then
        warn "Pack '$name' is used by: ${used_by[*]}"
        if [[ "$force" != true ]]; then
            if [[ -t 0 ]]; then
                printf "Remove anyway? [y/N] " >&2
                local reply
                read -r reply
                if [[ ! "$reply" =~ ^[Yy]$ ]]; then
                    info "Aborted"
                    return 0
                fi
            else
                error "Pack is in use. Use --force to remove anyway."
                return 1
            fi
        fi
    fi

    rm -rf "$pack_dir"
    ok "Pack '$name' removed"
}

cmd_pack_validate() {
    check_global

    local name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                cat <<'EOF'
Usage: cco pack validate [name]

Validate pack structure. Validates all packs if no name given.
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

    if [[ -n "$name" ]]; then
        [[ ! -d "$GLOBAL_DIR/packs/$name" ]] && die "Pack '$name' not found"
        _validate_single_pack "$name"
    else
        local has_errors=false
        for dir in "$GLOBAL_DIR/packs"/*/; do
            [[ ! -d "$dir" ]] && continue
            local pack_name
            pack_name=$(basename "$dir")
            if ! _validate_single_pack "$pack_name"; then
                has_errors=true
            fi
        done
        if [[ "$has_errors" == true ]]; then
            return 1
        fi
    fi
}
