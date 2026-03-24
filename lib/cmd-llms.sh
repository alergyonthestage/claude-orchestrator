#!/usr/bin/env bash
# lib/cmd-llms.sh — LLMs.txt management: install, list, show, update, remove
#
# Provides: cmd_llms()
# Dependencies: colors.sh, utils.sh, paths.sh, yaml.sh, llms.sh
# Globals: LLMS_DIR, PACKS_DIR, PROJECTS_DIR

cmd_llms() {
    local subcmd="${1:-}"
    if [[ -z "$subcmd" || "$subcmd" == "--help" ]]; then
        cat <<'EOF'
Usage: cco llms <command> [options]

Commands:
  install <url>        Download and install an llms.txt file
  list                 List installed llms documentation
  show <name>          Show details for an installed llms entry
  update [name]        Re-download llms files from source URLs
  remove <name>        Remove an installed llms entry

Run 'cco llms <command> --help' for command-specific options.
EOF
        return 0
    fi
    shift
    case "$subcmd" in
        install) _llms_install "$@" ;;
        list)    _llms_list "$@" ;;
        show)    _llms_show "$@" ;;
        update)  _llms_update "$@" ;;
        remove)  _llms_remove "$@" ;;
        *)       die "Unknown llms command: $subcmd. Run 'cco llms --help'." ;;
    esac
}

# ── install ──────────────────────────────────────────────────────────

_llms_install() {
    local url="" name="" variant="" pack="" project=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)    name="$2"; shift 2 ;;
            --variant) variant="$2"; shift 2 ;;
            --pack)    pack="$2"; shift 2 ;;
            --project) project="$2"; shift 2 ;;
            --help)
                cat <<'EOF'
Usage: cco llms install <url> [options]

Download an llms.txt file and save it to user-config/llms/<name>/.

Options:
  --name <name>        Override the auto-detected framework name
  --variant <v>        Force variant: full, medium, small, index (default: auto)
  --pack <pack>        Add reference to this pack's pack.yml
  --project <project>  Add reference to this project's project.yml

Examples:
  cco llms install https://svelte.dev/docs/svelte/llms.txt
  cco llms install https://shadcn-svelte.com/llms.txt --name shadcn-svelte
  cco llms install https://svelte.dev/llms.txt --variant medium --pack my-pack
EOF
                return 0
                ;;
            -*) die "Unknown option: $1" ;;
            *)
                if [[ -z "$url" ]]; then
                    url="$1"; shift
                else
                    die "Unexpected argument: $1"
                fi
                ;;
        esac
    done

    [[ -z "$url" ]] && die "Usage: cco llms install <url> [--name <name>] [--variant <v>]"

    # Auto-detect name from URL if not provided
    if [[ -z "$name" ]]; then
        name=$(_llms_resolve_name_from_url "$url")
        [[ -z "$name" ]] && die "Cannot determine name from URL. Use --name <name>."
    fi

    # Validate name: safe filesystem component, no path traversal
    if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
        die "Invalid llms name '$name': must start with alphanumeric and contain only [a-zA-Z0-9._-]"
    fi

    local target_dir="$LLMS_DIR/$name"

    # Warn if already exists
    if [[ -d "$target_dir" ]]; then
        warn "LLMs '$name' already exists. Files will be overwritten."
    fi

    mkdir -p "$target_dir" "$target_dir/.cco"

    # Determine base URL for variant probing
    local base_url
    base_url=$(_llms_base_url "$url")

    # Detect available variants
    info "Detecting variants for $name..."
    local variants_found=()
    local variant_urls=()

    for v in "" "-full" "-medium" "-small"; do
        local probe_url="${base_url}/llms${v}.txt"
        local status
        status=$(curl -sI -o /dev/null -w '%{http_code}' --max-time 10 "$probe_url" 2>/dev/null || echo "000")
        local label
        if [[ "$v" == "" ]]; then label="index"; else label="${v#-}"; fi
        if [[ "$status" == "200" ]]; then
            info "  llms${v}.txt   found ($label)"
            variants_found+=("$label")
            variant_urls+=("$probe_url")
        fi
    done

    if [[ ${#variants_found[@]} -eq 0 ]]; then
        # Try the original URL directly (might not follow standard naming)
        local status
        status=$(curl -sI -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null || echo "000")
        if [[ "$status" != "200" ]]; then
            die "No llms.txt files found at $base_url/ (tried llms.txt, llms-full.txt, etc.)"
        fi
        # Download just the provided URL (normalize filename to llms.txt)
        info "Downloading $url..."
        local fname="llms.txt"
        curl -sL --max-time 120 "$url" -o "$target_dir/$fname" || die "Download failed"
        local line_count
        line_count=$(wc -l < "$target_dir/$fname" | tr -d ' ')
        ok "Saved $fname ($line_count lines)"

        _llms_write_source "$target_dir" "$url" "index" ""
        ok "Installed llms '$name' to llms/$name/"
        _llms_add_to_yaml "$name" "$pack" "$project"
        return 0
    fi

    # Determine which variant to download as primary
    local target_variant=""
    if [[ -n "${variant:-}" ]]; then
        # Check if user-requested variant is available
        local variant_available=false
        for ((i=0; i<${#variants_found[@]}; i++)); do
            [[ "${variants_found[$i]}" == "$variant" ]] && { variant_available=true; break; }
        done
        if [[ "$variant_available" == "true" ]]; then
            target_variant="$variant"
        else
            warn "Variant '$variant' not available. Auto-selecting best variant."
        fi
    fi
    if [[ -z "$target_variant" ]]; then
        # Auto-select: prefer full > medium > small > index
        for pref in full medium small index; do
            for ((i=0; i<${#variants_found[@]}; i++)); do
                if [[ "${variants_found[$i]}" == "$pref" ]]; then
                    target_variant="$pref"
                    break 2
                fi
            done
        done
    fi

    # Download all found variants (they're usually small relative to full)
    local resolved_url=""
    for ((i=0; i<${#variants_found[@]}; i++)); do
        local vlabel="${variants_found[$i]}"
        local vurl="${variant_urls[$i]}"
        local vfile
        if [[ "$vlabel" == "index" ]]; then
            vfile="llms.txt"
        else
            vfile="llms-${vlabel}.txt"
        fi
        info "Downloading $vfile..."
        curl -sL --max-time 120 "$vurl" -o "$target_dir/$vfile" || { warn "Failed to download $vfile"; continue; }
        local lc
        lc=$(wc -l < "$target_dir/$vfile" | tr -d ' ')
        ok "  $vfile ($lc lines)"
        if [[ "$vlabel" == "$target_variant" ]]; then
            resolved_url="$vurl"
        fi
    done

    # Get ETag for change detection
    local etag=""
    if [[ -n "$resolved_url" ]]; then
        etag=$(curl -sI --max-time 10 "$resolved_url" 2>/dev/null | grep -i '^etag:' | sed 's/^[^:]*: *//; s/\r//' || true)
    fi

    _llms_write_source "$target_dir" "$url" "$target_variant" "$etag"
    ok "Installed llms '$name' (primary: $target_variant)"

    _llms_add_to_yaml "$name" "$pack" "$project"
}

# ── list ─────────────────────────────────────────────────────────────

_llms_list() {
    if [[ "${1:-}" == "--help" ]]; then
        cat <<'EOF'
Usage: cco llms list

List all installed llms documentation with metadata.
EOF
        return 0
    fi

    if [[ ! -d "$LLMS_DIR" ]]; then
        info "No llms documentation installed. Use 'cco llms install <url>' to add some."
        return 0
    fi
    # Check for at least one non-.cco entry directory
    local has_entries=false
    for _d in "$LLMS_DIR"/*/; do
        [[ ! -d "$_d" ]] && continue
        [[ "$(basename "$_d")" == ".cco" ]] && continue
        has_entries=true; break
    done
    if [[ "$has_entries" == "false" ]]; then
        info "No llms documentation installed. Use 'cco llms install <url>' to add some."
        return 0
    fi

    printf "${BOLD}%-20s %-10s %-8s %-14s %s${NC}\n" "NAME" "VARIANT" "LINES" "DOWNLOADED" "SOURCE"

    for dir in "$LLMS_DIR"/*/; do
        [[ ! -d "$dir" ]] && continue
        local dname
        dname=$(basename "$dir")
        [[ "$dname" == ".cco" ]] && continue

        local var="?" lines="?" downloaded="?" source_url="?"
        local source_file="$dir/.cco/source"
        if [[ -f "$source_file" ]]; then
            var=$(yml_get "$source_file" "variant" 2>/dev/null || echo "?")
            downloaded=$(yml_get "$source_file" "downloaded" 2>/dev/null || echo "?")
            source_url=$(yml_get "$source_file" "url" 2>/dev/null || echo "?")
            # Truncate date to YYYY-MM-DD
            downloaded="${downloaded%%T*}"
            # Truncate URL for display
            source_url="${source_url#https://}"
            source_url="${source_url#http://}"
            [[ ${#source_url} -gt 40 ]] && source_url="${source_url:0:37}..."
        fi

        # Count lines of primary file
        local primary
        primary=$(_llms_resolve_primary_file "$dir" "$var" 2>/dev/null)
        if [[ -n "$primary" && -f "$dir/$primary" ]]; then
            lines=$(wc -l < "$dir/$primary" | tr -d ' ')
        fi

        printf "%-20s %-10s %-8s %-14s %s\n" "$dname" "$var" "$lines" "$downloaded" "$source_url"
    done

    # Show usage by packs and projects
    echo ""
    echo "${BOLD}Used by:${NC}"
    local any_usage=false
    for dir in "$LLMS_DIR"/*/; do
        [[ ! -d "$dir" ]] && continue
        local dname
        dname=$(basename "$dir")
        [[ "$dname" == ".cco" ]] && continue
        local users=""
        users=$(_llms_find_users "$dname")
        if [[ -n "$users" ]]; then
            printf "  %-20s %s\n" "$dname" "$users"
            any_usage=true
        fi
    done
    [[ "$any_usage" == "false" ]] && echo "  (none referenced by any pack or project)"
}

# ── show ─────────────────────────────────────────────────────────────

_llms_show() {
    local name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                cat <<'EOF'
Usage: cco llms show <name>

Show detailed information about an installed llms entry.
EOF
                return 0
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

    [[ -z "$name" ]] && die "Usage: cco llms show <name>"

    local llms_dir="$LLMS_DIR/$name"
    [[ ! -d "$llms_dir" ]] && die "LLMs '$name' not found. Run 'cco llms list' to see installed entries."

    echo "${BOLD}Name:${NC}       $name"

    local source_file="$llms_dir/.cco/source"
    if [[ -f "$source_file" ]]; then
        local url var downloaded etag
        url=$(yml_get "$source_file" "url" 2>/dev/null || echo "unknown")
        var=$(yml_get "$source_file" "variant" 2>/dev/null || echo "auto")
        downloaded=$(yml_get "$source_file" "downloaded" 2>/dev/null || echo "unknown")
        etag=$(yml_get "$source_file" "etag" 2>/dev/null || echo "")
        echo "${BOLD}Source:${NC}     $url"
        echo "${BOLD}Variant:${NC}    $var"
        echo "${BOLD}Downloaded:${NC} $downloaded"
        [[ -n "$etag" ]] && echo "${BOLD}ETag:${NC}       $etag"
    fi

    echo "${BOLD}Files:${NC}"
    for f in "$llms_dir"/llms*.txt; do
        [[ ! -f "$f" ]] && continue
        local fname lc
        fname=$(basename "$f")
        lc=$(wc -l < "$f" | tr -d ' ')
        local primary_marker=""
        local resolved
        resolved=$(_llms_resolve_primary_file "$llms_dir" "" 2>/dev/null)
        [[ "$fname" == "$resolved" ]] && primary_marker=" (primary)"
        echo "  $fname ($lc lines)${primary_marker}"
    done

    local users
    users=$(_llms_find_users "$name")
    if [[ -n "$users" ]]; then
        echo "${BOLD}Used by:${NC}    $users"
    else
        echo "${BOLD}Used by:${NC}    (none)"
    fi
}

# ── update ───────────────────────────────────────────────────────────

_llms_update() {
    local name="" update_all=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)  update_all=true; shift ;;
            --help)
                cat <<'EOF'
Usage: cco llms update [<name>] [--all]

Re-download llms files from their source URLs.

Options:
  --all   Update all installed llms entries

Examples:
  cco llms update svelte
  cco llms update --all
EOF
                return 0
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

    if [[ "$update_all" == "true" ]]; then
        if [[ ! -d "$LLMS_DIR" ]]; then
            info "No llms documentation installed."
            return 0
        fi
        local updated=0
        for dir in "$LLMS_DIR"/*/; do
            [[ ! -d "$dir" ]] && continue
            local dname
            dname=$(basename "$dir")
            [[ "$dname" == ".cco" ]] && continue
            _llms_update_single "$dname" && ((updated++)) || true
        done
        ok "Updated $updated llms entries."
        return 0
    fi

    [[ -z "$name" ]] && die "Usage: cco llms update <name> or cco llms update --all"
    [[ ! -d "$LLMS_DIR/$name" ]] && die "LLMs '$name' not found."
    _llms_update_single "$name"
}

_llms_update_single() {
    local name="$1"
    local llms_dir="$LLMS_DIR/$name"
    local source_file="$llms_dir/.cco/source"

    if [[ ! -f "$source_file" ]]; then
        warn "LLMs '$name': no source metadata — cannot update (was it installed manually?)"
        return 1
    fi

    local url variant
    url=$(yml_get "$source_file" "url" 2>/dev/null)
    variant=$(yml_get "$source_file" "variant" 2>/dev/null)

    [[ -z "$url" ]] && { warn "LLMs '$name': no source URL"; return 1; }

    info "Checking $name..."

    local base_url
    base_url=$(_llms_base_url "$url")

    # Re-download all variants that exist locally
    local any_updated=false
    for f in "$llms_dir"/llms*.txt; do
        [[ ! -f "$f" ]] && continue
        local fname vurl
        fname=$(basename "$f")
        vurl="${base_url}/${fname}"
        # Check HTTP status before downloading
        local http_status
        http_status=$(curl -sI -o /dev/null -w '%{http_code}' --max-time 10 "$vurl" 2>/dev/null || echo "000")
        if [[ "$http_status" != "200" ]]; then
            warn "  $fname: HTTP $http_status — skipped"
            continue
        fi
        local old_hash
        old_hash=$(md5sum "$f" 2>/dev/null | cut -d' ' -f1 || md5 -q "$f" 2>/dev/null)
        curl -sL --max-time 120 "$vurl" -o "$f.tmp" 2>/dev/null || { warn "  Failed to fetch $fname"; rm -f "$f.tmp"; continue; }
        local new_hash
        new_hash=$(md5sum "$f.tmp" 2>/dev/null | cut -d' ' -f1 || md5 -q "$f.tmp" 2>/dev/null)
        mv "$f.tmp" "$f"
        if [[ "$old_hash" != "$new_hash" ]]; then
            local new_lines
            new_lines=$(wc -l < "$f" | tr -d ' ')
            ok "  $fname updated ($new_lines lines)"
            any_updated=true
        fi
    done

    # Update source metadata timestamp
    local resolved_url=""
    if [[ "$variant" == "index" || -z "$variant" ]]; then
        resolved_url="${base_url}/llms.txt"
    else
        resolved_url="${base_url}/llms-${variant}.txt"
    fi
    local etag=""
    etag=$(curl -sI --max-time 10 "$resolved_url" 2>/dev/null | grep -i '^etag:' | sed 's/^[^:]*: *//; s/\r//' || true)
    _llms_write_source "$llms_dir" "$url" "$variant" "$etag"

    if [[ "$any_updated" == "false" ]]; then
        info "  $name: already up to date"
    fi
    return 0
}

# ── remove ───────────────────────────────────────────────────────────

_llms_remove() {
    local name="" force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force=true; shift ;;
            --help)
                cat <<'EOF'
Usage: cco llms remove <name> [--force]

Remove an installed llms entry.

Options:
  --force   Skip confirmation prompt
EOF
                return 0
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

    [[ -z "$name" ]] && die "Usage: cco llms remove <name>"

    local llms_dir="$LLMS_DIR/$name"
    [[ ! -d "$llms_dir" ]] && die "LLMs '$name' not found."

    # Check usage
    local users
    users=$(_llms_find_users "$name")
    if [[ -n "$users" && "$force" == "false" ]]; then
        warn "LLMs '$name' is referenced by: $users"
        printf "Remove anyway? [y/N] "
        read -r confirm
        [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { info "Cancelled."; return 0; }
    fi

    rm -rf "$llms_dir"
    ok "Removed llms '$name'"
}

# ── Helpers ──────────────────────────────────────────────────────────

# Extract framework name from URL.
_llms_resolve_name_from_url() {
    local url="$1"
    local path
    path=$(echo "$url" | sed 's|https\?://[^/]*||; s|/llms[^/]*$||; s|/$||')

    if [[ -n "$path" && "$path" != "/" ]]; then
        # Use last path segment: /docs/svelte → svelte
        basename "$path"
    else
        # Use domain name: shadcn-svelte.com → shadcn-svelte
        echo "$url" | sed 's|https\?://||; s|/.*||; s|\.[^.]*$||'
    fi
}

# Derive base URL (directory) from an llms.txt URL.
_llms_base_url() {
    local url="$1"
    # Strip the filename (llms.txt, llms-full.txt, etc.)
    echo "$url" | sed 's|/llms[^/]*$||'
}

# Write .cco/source metadata file.
_llms_write_source() {
    local dir="$1" url="$2" variant="$3" etag="$4"
    mkdir -p "$dir/.cco"
    local resolved_url
    if [[ "$variant" == "index" || -z "$variant" ]]; then
        resolved_url="${url}"
    else
        local base
        base=$(_llms_base_url "$url")
        resolved_url="${base}/llms-${variant}.txt"
    fi
    cat > "$dir/.cco/source" <<YAML
url: "$url"
variant: $variant
downloaded: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
resolved_url: "$resolved_url"
etag: "$etag"
YAML
}

# Find packs and projects that reference a given llms name.
# Returns a human-readable string like "my-pack (pack), my-app (project)".
_llms_find_users() {
    local name="$1"
    local users=()

    # Check packs
    if [[ -d "$PACKS_DIR" ]]; then
        for pdir in "$PACKS_DIR"/*/; do
            [[ ! -d "$pdir" ]] && continue
            local pyml="$pdir/pack.yml"
            [[ ! -f "$pyml" ]] && continue
            local names
            names=$(yml_get_llms_names "$pyml" 2>/dev/null)
            if echo "$names" | grep -qxF "$name"; then
                users+=("$(basename "$pdir") (pack)")
            fi
        done
    fi

    # Check projects
    if [[ -d "$PROJECTS_DIR" ]]; then
        for pdir in "$PROJECTS_DIR"/*/; do
            [[ ! -d "$pdir" ]] && continue
            local pyml="$pdir/project.yml"
            [[ ! -f "$pyml" ]] && continue
            local names
            names=$(yml_get_llms_names "$pyml" 2>/dev/null)
            if echo "$names" | grep -qxF "$name"; then
                users+=("$(basename "$pdir") (project)")
            fi
        done
    fi

    if [[ ${#users[@]} -gt 0 ]]; then
        local IFS=", "
        echo "${users[*]}"
    fi
}

# Add an llms reference to a pack or project YAML file.
_llms_add_to_yaml() {
    local name="$1" pack="$2" project="$3"

    if [[ -n "$pack" ]]; then
        local pack_yml="$PACKS_DIR/$pack/pack.yml"
        [[ ! -f "$pack_yml" ]] && { warn "Pack '$pack' not found — skipping YAML update."; return; }
        # Check if already referenced
        if yml_get_llms_names "$pack_yml" | grep -qxF "$name"; then
            info "LLMs '$name' already in pack '$pack'"
        else
            _llms_append_to_yaml_list "$pack_yml" "llms" "$name"
            ok "Added '$name' to pack '$pack' llms list"
        fi
    fi

    if [[ -n "$project" ]]; then
        local proj_yml="$PROJECTS_DIR/$project/project.yml"
        [[ ! -f "$proj_yml" ]] && { warn "Project '$project' not found — skipping YAML update."; return; }
        if yml_get_llms_names "$proj_yml" | grep -qxF "$name"; then
            info "LLMs '$name' already in project '$project'"
        else
            _llms_append_to_yaml_list "$proj_yml" "llms" "$name"
            ok "Added '$name' to project '$project' llms list"
        fi
    fi
}

# Append a simple list entry to a YAML file under a top-level key.
# Creates the key if it doesn't exist.
_llms_append_to_yaml_list() {
    local file="$1" key="$2" value="$3"

    # Escape sed metacharacters in value to prevent injection
    local safe_value
    safe_value=$(printf '%s' "$value" | sed 's/[&/\]/\\&/g')
    if grep -qF "${key}:" "$file" 2>/dev/null; then
        # Key exists — append entry after it
        _sed_i_raw "$file" "/^${key}:/a\\
  - ${safe_value}"
    else
        # Key doesn't exist — append at end of file
        printf '\n%s:\n  - %s\n' "$key" "$value" >> "$file"
    fi
}
