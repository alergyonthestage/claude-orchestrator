#!/usr/bin/env bash
# lib/cmd-pack.sh — Pack management commands
#
# Provides: cmd_pack_create(), cmd_pack_list(), cmd_pack_show(),
#           cmd_pack_remove(), cmd_pack_validate(),
#           cmd_pack_install(), cmd_pack_update(), cmd_pack_export(),
#           cmd_pack_internalize()
# Dependencies: colors.sh, utils.sh, yaml.sh, packs.sh, manifest.sh, remote.sh
# Globals: PACKS_DIR, PROJECTS_DIR, USER_CONFIG_DIR

# ── Pack commands ─────────────────────────────────────────────────────

cmd_pack_create() {
    check_global

    local name=""
    local template_name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --template)
                [[ -z "${2:-}" ]] && die "--template requires a template name"
                template_name="$2"; shift 2 ;;
            --help)
                cat <<'EOF'
Usage: cco pack create <name> [--template <name>]

Create a new knowledge pack.

Options:
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

    [[ -z "$name" ]] && die "Usage: cco pack create <name>"

    # Validate name
    if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
        die "Pack name must be lowercase letters, numbers, and hyphens only."
    fi

    local pack_dir="$PACKS_DIR/$name"
    [[ -d "$pack_dir" ]] && die "Pack '$name' already exists at packs/$name/"

    # Cross-branch uniqueness check (if vault exists)
    if [[ -d "$USER_CONFIG_DIR/.git" ]]; then
        local current_branch
        current_branch=$(git -C "$USER_CONFIG_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)
        local conflict_branch
        if conflict_branch=$(_name_exists_on_other_branch "$USER_CONFIG_DIR" "pack" "$name" "$current_branch"); then
            die "Pack '$name' already exists on branch '$conflict_branch'. Pack names must be unique across all profiles."
        fi
    fi

    # Ensure packs directory exists (may have been removed by vault move)
    mkdir -p "$PACKS_DIR"

    # Resolve and copy template
    local template_dir
    template_dir=$(_resolve_template "pack" "${template_name:-base}")
    cp -r "$template_dir" "$pack_dir"

    # Replace name placeholder in pack.yml if present
    if [[ -f "$pack_dir/pack.yml" ]]; then
        _substitute "$pack_dir/pack.yml" "PACK_NAME" "$name"
        # Also replace literal "name: base" with actual name
        _sed_i "$pack_dir/pack.yml" "^name: base$" "name: $name"
    fi

    # Update manifest.yml
    manifest_refresh "$USER_CONFIG_DIR"

    ok "Pack created at packs/$name/"
    info "Add resources to the subdirectories:"
    info "  knowledge/ — documentation files"
    info "  skills/    — skill directories (each with SKILL.md)"
    info "  agents/    — agent definition files (.md)"
    info "  rules/     — rule files (.md)"
    info "Edit packs/$name/pack.yml to declare resources"
}

cmd_pack_list() {
    if [[ "${1:-}" == "--help" ]]; then
        cat <<'EOF'
Usage: cco pack list

List all installed packs with resource counts (knowledge, skills, agents, rules).
EOF
        return 0
    fi

    check_global

    echo -e "${BOLD}NAME              KNOWLEDGE  SKILLS  AGENTS  RULES${NC}"

    for dir in "$PACKS_DIR"/*/; do
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

    local pack_dir="$PACKS_DIR/$name"
    local pack_yml="$pack_dir/pack.yml"
    [[ ! -d "$pack_dir" ]] && die "Pack '$name' not found at packs/$name/"

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

    local pack_dir="$PACKS_DIR/$name"
    [[ ! -d "$pack_dir" ]] && die "Pack '$name' not found at packs/$name/"

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

    # Update manifest.yml
    manifest_refresh "$USER_CONFIG_DIR"

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
        [[ ! -d "$PACKS_DIR/$name" ]] && die "Pack '$name' not found"
        _validate_single_pack "$name"
    else
        local has_errors=false
        for dir in "$PACKS_DIR"/*/; do
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

# ── Install / Update / Export ──────────────────────────────────────────

cmd_pack_install() {
    local url="" pick="" token="" force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pick)
                [[ -z "${2:-}" ]] && die "--pick requires a pack name"
                pick="$2"; shift 2
                ;;
            --token)
                [[ -z "${2:-}" ]] && die "--token requires a value"
                token="$2"; shift 2
                ;;
            --force) force=true; shift ;;
            --help)
                cat <<'EOF'
Usage: cco pack install <source> [options]

Install packs from a remote Config Repo.

Arguments:
  <source>          Git URL or registered remote name

Options:
  --pick <name>     Install a specific pack by name
  --token <token>   Auth token for HTTPS repos
  --force           Overwrite existing packs without asking

URL can include @ref suffix: <url>@<branch-or-tag>

Examples:
  cco pack install albit --pick alberghi-it
  cco pack install https://github.com/team/config.git
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

    [[ -z "$url" ]] && die "Usage: cco pack install <source> [--pick <name>]\n\n<source> can be a git URL or a registered remote name."
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
        # Only treat as ref if it doesn't look like user@host (SSH)
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
    local single_pack=false
    local manifest_file=""
    if [[ -f "$tmpdir/manifest.yml" ]]; then
        manifest_file="$tmpdir/manifest.yml"
    elif [[ -f "$tmpdir/pack.yml" ]]; then
        single_pack=true
    else
        _cleanup_clone "$tmpdir"
        die "Not a valid CCO Config Repo: no manifest.yml or pack.yml found"
    fi

    if $single_pack; then
        # Single-pack repo: install the root as a pack
        local name
        name=$(yml_get "$tmpdir/pack.yml" "name")
        [[ -z "$name" ]] && die "pack.yml has no 'name' field"
        _install_pack_from_dir "$tmpdir" "$name" "$url" "$ref" "" "$force" "$clone_commit"
    else
        # Multi-pack repo: read available packs from manifest
        local available
        available=$(_manifest_get_names "$manifest_file" "packs")

        if [[ -z "$available" ]]; then
            _cleanup_clone "$tmpdir"
            die "No packs listed in manifest"
        fi

        if [[ -n "$pick" ]]; then
            # Install specific pack
            if ! echo "$available" | grep -qxF "$pick"; then
                _cleanup_clone "$tmpdir"
                die "Pack '$pick' not found in manifest. Available: $(echo "$available" | tr '\n' ' ')"
            fi
            _install_pack_from_dir "$tmpdir/packs/$pick" "$pick" "$url" "$ref" "packs/$pick" "$force" "$clone_commit"
        else
            # Install all packs
            local count=0
            while IFS= read -r name; do
                [[ -z "$name" ]] && continue
                if [[ -d "$tmpdir/packs/$name" ]]; then
                    _install_pack_from_dir "$tmpdir/packs/$name" "$name" "$url" "$ref" "packs/$name" "$force" "$clone_commit"
                    count=$((count + 1))
                else
                    warn "Pack '$name' listed in manifest but not found on disk — skipping"
                fi
            done <<< "$available"
            ok "Installed $count pack(s) from $url"
        fi
    fi

    # Update manifest.yml
    manifest_refresh "$USER_CONFIG_DIR"

    _cleanup_clone "$tmpdir"
    trap - EXIT
}

cmd_pack_update() {
    local name="" force=false update_all=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)   update_all=true; shift ;;
            --force) force=true; shift ;;
            --help)
                cat <<'EOF'
Usage: cco pack update <name> [--force]
       cco pack update --all [--force]

Update a pack from its recorded remote source.

Options:
  --all     Update all packs with a remote source
  --force   Overwrite local modifications
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
        local -a failed_packs=()
        for dir in "$PACKS_DIR"/*/; do
            [[ ! -d "$dir" ]] && continue
            local pack_name
            pack_name=$(basename "$dir")
            local source_file
            source_file=$(_cco_pack_source "$dir")
            [[ ! -f "$source_file" ]] && continue
            local source_url
            source_url=$(yml_get "$source_file" "url")
            [[ "$source_url" == "local" || -z "$source_url" ]] && continue
            info "Updating $pack_name..."
            # Isolate errors: run in subshell so die() does not abort the loop
            if ( _update_single_pack "$pack_name" "$force" ); then
                updated=$((updated + 1))
            else
                warn "Failed to update '$pack_name'"
                failed_packs+=("$pack_name")
            fi
        done
        if [[ $updated -eq 0 && ${#failed_packs[@]} -eq 0 ]]; then
            info "No packs with remote sources found"
        elif [[ $updated -gt 0 && ${#failed_packs[@]} -eq 0 ]]; then
            ok "Updated $updated pack(s)"
        fi
        if [[ ${#failed_packs[@]} -gt 0 ]]; then
            error "Failed to update ${#failed_packs[@]} pack(s): ${failed_packs[*]}"
            return 1
        fi
        return 0
    fi

    [[ -z "$name" ]] && die "Usage: cco pack update <name> [--force]"
    [[ ! -d "$PACKS_DIR/$name" ]] && die "Pack '$name' not found"

    _update_single_pack "$name" "$force"
}

cmd_pack_export() {
    local name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                cat <<'EOF'
Usage: cco pack export <name>

Export a pack as a .tar.gz archive.
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

    [[ -z "$name" ]] && die "Usage: cco pack export <name>"
    [[ ! -d "$PACKS_DIR/$name" ]] && die "Pack '$name' not found"

    local archive="${name}.tar.gz"
    tar czf "$archive" -C "$PACKS_DIR" --exclude='.cco/source' \
        --exclude='.cco/install-tmp' "$name"
    ok "Exported pack to $archive"
}

# ── Internal helpers for install/update ────────────────────────────────

# Install a pack from a local directory (clone temp or single-pack root).
# Usage: _install_pack_from_dir <source_dir> <name> <url> <ref> <path> <force> [commit]
_install_pack_from_dir() {
    local source_dir="$1"
    local name="$2"
    local url="$3"
    local ref="$4"
    local path="$5"
    local force="$6"
    local commit="${7:-}"

    local target_dir="$PACKS_DIR/$name"

    # Conflict check
    if [[ -d "$target_dir" ]]; then
        if [[ "$force" == true ]]; then
            rm -rf "$target_dir"
        else
            local existing_source="" existing_src_file
            existing_src_file=$(_cco_pack_source "$target_dir")
            if [[ -f "$existing_src_file" ]]; then
                existing_source=$(yml_get "$existing_src_file" "url")
            fi

            if [[ "$existing_source" == "$url" ]]; then
                info "Pack '$name' already installed from same source — updating"
                rm -rf "$target_dir"
            elif [[ "$existing_source" == "local" ]]; then
                die "Pack '$name' was created locally. Use --force to overwrite."
            else
                die "Pack '$name' already exists (source: ${existing_source:-unknown}). Use --force to overwrite."
            fi
        fi
    fi

    # Copy pack contents
    cp -r "$source_dir" "$target_dir"

    # Remove .git if present (from single-pack repos)
    rm -rf "$target_dir/.git"

    # Write the DATA source provenance (machine-agnostic upstream coordinate
    # only) + the STATE meta bookkeeping (install commit + dates), ADR-0022 D1.
    local now src_file
    now=$(date +%Y-%m-%d)
    src_file=$(_cco_pack_source "$target_dir")
    mkdir -p "$(dirname "$src_file")"
    cat > "$src_file" <<YAML
url: $url
resource: ${path:-}
ref: ${ref:-}
YAML
    _meta_record_provenance "$(_cco_pack_meta "$target_dir")" "${commit:-}" "$now" "$now"

    ok "Installed pack '$name'"
}

# Update a single pack from its recorded source.
# Usage: _update_single_pack <name> <force>
_update_single_pack() {
    local name="$1"
    local force="${2:-false}"
    local source_file
    source_file=$(_cco_pack_source "$PACKS_DIR/$name")

    if [[ ! -f "$source_file" ]]; then
        die "Pack '$name' has no recorded source — cannot determine remote source"
    fi

    local source_url source_ref source_path
    source_url=$(yml_get "$source_file" "url")
    source_ref=$(yml_get "$source_file" "ref")
    source_path=$(yml_get "$source_file" "resource")

    if [[ "$source_url" == "local" || -z "$source_url" ]]; then
        die "Pack '$name' was created locally — no remote source to update from"
    fi

    # Auto-resolve token from registered remote
    local token=""
    token=$(remote_resolve_token_for_url "$source_url" 2>/dev/null) || true

    info "Fetching $source_url${source_ref:+ (ref: $source_ref)}..."
    local tmpdir
    tmpdir=$(_clone_config_repo "$source_url" "$source_ref" "$token")

    # Determine source directory within clone
    local remote_dir="$tmpdir"
    if [[ -n "$source_path" ]]; then
        remote_dir="$tmpdir/$source_path"
    fi

    if [[ ! -d "$remote_dir" ]]; then
        _cleanup_clone "$tmpdir"
        die "Remote path '$source_path' not found in cloned repo"
    fi

    # Capture commit hash for version tracking
    local update_commit=""
    update_commit=$(git -C "$tmpdir" rev-parse HEAD 2>/dev/null) || true

    # Install (force=true since we're explicitly updating). This rewrites the
    # DATA source coordinate and records the new commit + updated date in the
    # STATE meta (_meta_record_provenance) — no separate date bump needed.
    _install_pack_from_dir "$remote_dir" "$name" "$source_url" "$source_ref" "$source_path" true "$update_commit"

    # Update manifest.yml
    manifest_refresh "$USER_CONFIG_DIR"

    _cleanup_clone "$tmpdir"
    ok "Updated pack '$name'"
}

# ── Pack internalize ─────────────────────────────────────────────────

cmd_pack_internalize() {
    local name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                cat <<'EOF'
Usage: cco pack internalize <name>

Convert a pack to fully self-contained and locally owned:
  - If pack.yml has knowledge.source, copies referenced files into
    the pack's own knowledge/ directory and removes the source: field.
  - If the pack tracks a remote sharing repo, disconnects by setting its
    recorded url to local (the pack will no longer receive remote updates).
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

    [[ -z "$name" ]] && die "Usage: cco pack internalize <name>"
    check_global

    local pack_dir="$PACKS_DIR/$name"
    local pack_yml="$pack_dir/pack.yml"
    [[ ! -d "$pack_dir" ]] && die "Pack '$name' not found in packs/."
    [[ ! -f "$pack_yml" ]] && die "Pack '$name': pack.yml not found."

    local did_something=false

    # ── 1. Knowledge source internalization ───────────────────────────
    local k_source
    k_source=$(yml_get_pack_knowledge_source "$pack_yml")
    if [[ -n "$k_source" ]]; then
        # Expand and validate source path
        local expanded_source
        expanded_source=$(expand_path "$k_source")
        if [[ ! -d "$expanded_source" ]]; then
            die "Knowledge source not found: $k_source (expanded: $expanded_source)"
        fi

        # Get file list and copy
        local k_files
        k_files=$(yml_get_pack_knowledge_files "$pack_yml")
        local count=0
        if [[ -n "$k_files" ]]; then
            mkdir -p "$pack_dir/knowledge"
            while IFS=$'\t' read -r fname desc; do
                [[ -z "$fname" ]] && continue
                local src="$expanded_source/$fname"
                local dst="$pack_dir/knowledge/$fname"
                if [[ -f "$src" ]]; then
                    mkdir -p "$(dirname "$dst")"
                    cp "$src" "$dst"
                    count=$((count + 1))
                else
                    warn "File not found: $src (skipping)"
                fi
            done <<< "$k_files"
        fi

        # Remove source: line from pack.yml
        local tmpfile
        tmpfile=$(mktemp)
        awk '
            /^knowledge:/ { in_k=1; print; next }
            in_k && /^  source:/ { next }
            in_k && /^[^ #]/ { in_k=0 }
            { print }
        ' "$pack_yml" > "$tmpfile"
        mv "$tmpfile" "$pack_yml"

        ok "Knowledge internalized: $count file(s) copied to knowledge/"
        did_something=true
    fi

    # ── 2. Sharing-repo source disconnection ──────────────────────────
    local source_file
    source_file=$(_cco_pack_source "$pack_dir")
    if [[ -f "$source_file" ]]; then
        local source_url
        source_url=$(yml_get "$source_file" "url")
        if [[ -n "$source_url" && "$source_url" != "local" ]]; then
            # Overwrite the DATA source — set url to local, preserve install
            # history as a comment.
            {
                printf 'url: local\n'
                printf '# previously installed from: %s\n' "$source_url"
            } > "$source_file"

            # Clear the cached remote HEAD from the STATE meta if present
            local meta_file
            meta_file=$(_cco_pack_meta "$pack_dir")
            if [[ -f "$meta_file" ]]; then
                yml_remove "$meta_file" "remote_cache"
            fi

            ok "Disconnected from remote source: $source_url"
            did_something=true
        fi
    fi

    # ── 3. Report if nothing to do ────────────────────────────────────
    if [[ "$did_something" != "true" ]]; then
        ok "Pack '$name' is already self-contained (no knowledge source, no remote tracking)"
    fi
}

# ── Pack publish ─────────────────────────────────────────────────────

cmd_pack_publish() {
    local name="" remote_arg="" message="" dry_run=false force=false token=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --message)
                [[ -z "${2:-}" ]] && die "--message requires a value"
                message="$2"; shift 2 ;;
            --dry-run)  dry_run=true; shift ;;
            --force)    force=true; shift ;;
            --token)
                [[ -z "${2:-}" ]] && die "--token requires a value"
                token="$2"; shift 2 ;;
            --help)
                cat <<'EOF'
Usage: cco pack publish <name> [<remote>] [OPTIONS]

Publish a pack to a remote Config Repo.

Arguments:
  <name>             Pack to publish
  <remote>           Remote name or URL (default: re-derived from the pack's
                     recorded upstream against your registered remotes)

Options:
  --message <msg>    Commit message (default: "publish pack <name>")
  --dry-run          Show what would be published, don't push
  --force            Overwrite remote version without confirmation
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

    [[ -z "$name" ]] && die "Usage: cco pack publish <name> [<remote>]"

    local pack_dir="$PACKS_DIR/$name"
    [[ ! -f "$pack_dir/pack.yml" ]] && die "Pack '$name' not found."

    # Resolve remote URL
    local remote_url="" remote_name=""
    _resolve_publish_remote "$remote_arg" "$pack_dir" remote_url remote_name

    [[ -z "$message" ]] && message="publish pack $name"

    # Auto-resolve token from remote if not explicitly provided
    if [[ -z "$token" ]]; then
        if [[ -n "$remote_name" ]]; then
            token=$(remote_get_token "$remote_name" 2>/dev/null) || true
        else
            token=$(remote_resolve_token_for_url "$remote_url" 2>/dev/null) || true
        fi
    fi

    info "Publishing pack '$name' to $remote_url..."

    # Clone remote repo (push-ready)
    local tmpdir
    tmpdir=$(_clone_for_publish "$remote_url" "$token")
    trap "_cleanup_clone '$tmpdir'" EXIT

    # Check for existing pack on remote
    if [[ -d "$tmpdir/packs/$name" ]]; then
        if $dry_run; then
            info "Pack '$name' already exists on remote — would overwrite"
        elif ! $force; then
            local diff_summary
            diff_summary=$(diff -rq "$pack_dir" "$tmpdir/packs/$name" 2>/dev/null \
                | grep -v '.cco/source' | grep -v '.cco/install-tmp' | head -10)
            if [[ -n "$diff_summary" ]]; then
                warn "Pack '$name' already exists on remote. Differences:"
                echo "$diff_summary" | sed 's/^/  /'
                if [[ -t 0 ]]; then
                    printf "\nOverwrite? [y/N] " >&2
                    local reply; read -r reply
                    [[ ! "$reply" =~ ^[Yy]$ ]] && { _cleanup_clone "$tmpdir"; die "Aborted."; }
                else
                    _cleanup_clone "$tmpdir"
                    die "Pack exists on remote. Use --force to overwrite."
                fi
            fi
        fi
        rm -rf "$tmpdir/packs/$name"
    fi

    # Copy pack to temp dir
    mkdir -p "$tmpdir/packs"
    cp -R "$pack_dir" "$tmpdir/packs/$name"

    # Strip any local-only framework dir from the published copy (the source
    # provenance now lives in DATA, never inside the pack tree — ADR-0022 D1)
    rm -rf "$tmpdir/packs/$name/.cco"

    # Internalize if pack has knowledge.source
    local k_source
    k_source=$(yml_get_pack_knowledge_source "$tmpdir/packs/$name/pack.yml")
    if [[ -n "$k_source" ]]; then
        info "Internalizing knowledge from $k_source..."
        local expanded_source
        expanded_source=$(expand_path "$k_source")
        if [[ -d "$expanded_source" ]]; then
            local k_files
            k_files=$(yml_get_pack_knowledge_files "$tmpdir/packs/$name/pack.yml")
            mkdir -p "$tmpdir/packs/$name/knowledge"
            while IFS=$'\t' read -r fname desc; do
                [[ -z "$fname" ]] && continue
                local src="$expanded_source/$fname"
                if [[ -f "$src" ]]; then
                    mkdir -p "$(dirname "$tmpdir/packs/$name/knowledge/$fname")"
                    cp "$src" "$tmpdir/packs/$name/knowledge/$fname"
                else
                    warn "Knowledge file not found: $src"
                fi
            done <<< "$k_files"

            # Remove source: from published pack.yml
            local tmpf; tmpf=$(mktemp)
            awk '
                /^knowledge:/ { in_k=1; print; next }
                in_k && /^  source:/ { next }
                in_k && /^[^ #]/ { in_k=0 }
                { print }
            ' "$tmpdir/packs/$name/pack.yml" > "$tmpf"
            mv "$tmpf" "$tmpdir/packs/$name/pack.yml"
        else
            warn "Knowledge source not found: $k_source — publishing without internalization"
        fi
    fi

    # Refresh manifest in temp dir
    manifest_refresh "$tmpdir"

    if $dry_run; then
        echo ""
        echo -e "${BOLD}Would publish:${NC}"
        echo "  Pack: $name"
        echo "  Remote: $remote_url"
        echo "  Files:"
        find "$tmpdir/packs/$name" -type f | sed "s|$tmpdir/||; s/^/    /"
        _cleanup_clone "$tmpdir"
        trap - EXIT
        ok "Dry run complete — nothing pushed"
        return 0
    fi

    # Commit and push
    git -C "$tmpdir" add -A
    git -C "$tmpdir" commit -q -m "$message"
    git -C "$tmpdir" push origin HEAD >/dev/null 2>&1 \
        || { _cleanup_clone "$tmpdir"; die "Failed to push to $remote_url"; }

    # Record the published url as the pack's upstream coordinate (working-copy
    # model, P16): the sharing repo is now the source-of-truth, so a subsequent
    # `cco pack publish <name>` re-derives this remote on demand (F4) without a
    # stored publish_target.
    _record_pack_publish_url "$pack_dir" "$remote_url"

    _cleanup_clone "$tmpdir"
    trap - EXIT
    ok "Published pack '$name' to $remote_url"
}

# Resolve remote for publish: name → URL. With no explicit arg, re-derive the
# default remote (F4 / ADR-0022 D1) by reverse-looking-up the pack's recorded
# upstream `url` against the DATA remotes registry — no stored publish_target.
_resolve_publish_remote() {
    local remote_arg="$1" pack_dir="$2"
    # Output: sets the url var ($3) and the remote-name var ($4) in caller scope

    if [[ -n "$remote_arg" ]]; then
        # Try as registered remote name first
        local resolved
        if resolved=$(remote_get_url "$remote_arg"); then
            eval "$3=\$resolved"
            eval "$4=\$remote_arg"
            return 0
        fi
        # Treat as direct URL if contains : or /
        if [[ "$remote_arg" == *:* || "$remote_arg" == */* ]]; then
            eval "$3=\$remote_arg"
            eval "$4="
            return 0
        fi
        die "Remote '$remote_arg' not found. Register with 'cco remote add $remote_arg <url>'."
    fi

    # Re-derive from the recorded upstream coordinate: reverse-lookup its url
    # in the remotes registry (F4). The url is itself a usable push target even
    # when not registered (the name is then empty; token auto-resolve may fail).
    local src_file recorded_url
    src_file=$(_cco_pack_source "$pack_dir")
    if [[ -f "$src_file" ]]; then
        recorded_url=$(yml_get "$src_file" "url")
        if [[ -n "$recorded_url" && "$recorded_url" != "local" ]]; then
            local rname
            if rname=$(remote_get_name_for_url "$recorded_url"); then
                eval "$3=\$recorded_url"
                eval "$4=\$rname"
                return 0
            fi
            # Reachable url but not a registered remote — push to it directly.
            eval "$3=\$recorded_url"
            eval "$4="
            return 0
        fi
    fi

    die "No remote specified and the pack has no registered upstream. Usage: cco pack publish <name> <remote>"
}

# Record the upstream url the pack was published to in its DATA source (so the
# default remote can be re-derived on the next publish — F4). Replaces the old
# stored publish_target.
_record_pack_publish_url() {
    local pack_dir="$1" url="$2"
    [[ -z "$url" ]] && return 0
    local source_file
    source_file=$(_cco_pack_source "$pack_dir")
    mkdir -p "$(dirname "$source_file")"
    if [[ -f "$source_file" ]]; then
        _sed_i_or_append "$source_file" "url" "$url"
    else
        printf 'url: %s\n' "$url" > "$source_file"
    fi
}
