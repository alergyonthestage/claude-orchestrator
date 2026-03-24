#!/usr/bin/env bash
# lib/llms.sh — LLMs.txt resource helpers (resolve, mount, validate)
#
# Provides: _llms_resolve_primary_file(), _generate_llms_mounts(),
#           _generate_llms_packs_md(), _validate_llms_refs(),
#           _collect_llms_names()
# Dependencies: colors.sh, utils.sh, yaml.sh
# Globals: LLMS_DIR, PACKS_DIR

# Resolve the primary documentation file for an llms entry.
# Priority: full > medium > small > index (llms.txt).
# If a variant is specified, use that directly.
# Outputs the filename (not full path) of the primary file.
_llms_resolve_primary_file() {
    local llms_dir="$1"    # e.g., user-config/llms/svelte
    local variant="${2:-}"  # optional: full, medium, small, index

    if [[ -n "$variant" ]]; then
        case "$variant" in
            full)   [[ -f "$llms_dir/llms-full.txt" ]]   && echo "llms-full.txt"   && return 0 ;;
            medium) [[ -f "$llms_dir/llms-medium.txt" ]] && echo "llms-medium.txt" && return 0 ;;
            small)  [[ -f "$llms_dir/llms-small.txt" ]]  && echo "llms-small.txt"  && return 0 ;;
            index)  [[ -f "$llms_dir/llms.txt" ]]        && echo "llms.txt"        && return 0 ;;
        esac
        # Variant requested but not found — fall through to auto-resolve
    fi

    # Auto-resolve: prefer full, then medium, then small, then index
    [[ -f "$llms_dir/llms-full.txt" ]]   && echo "llms-full.txt"   && return 0
    [[ -f "$llms_dir/llms-medium.txt" ]] && echo "llms-medium.txt" && return 0
    [[ -f "$llms_dir/llms-small.txt" ]]  && echo "llms-small.txt"  && return 0
    [[ -f "$llms_dir/llms.txt" ]]        && echo "llms.txt"        && return 0

    return 1  # no file found
}

# Collect all unique llms names for a project (from project.yml + active packs).
# Outputs one line per entry: "<name>\t<description>\t<variant>"
# Project-level entries take precedence over pack-level for same name.
_collect_llms_names() {
    local project_yml="$1"
    local pack_names="$2"  # newline-separated pack names

    # Use arrays for deduplication (project wins over pack)
    local seen_keys=() seen_vals=()

    # Pack llms first (lower priority)
    if [[ -n "$pack_names" ]]; then
        while IFS= read -r pack_name; do
            [[ -z "$pack_name" ]] && continue
            local pack_yml="$PACKS_DIR/${pack_name}/pack.yml"
            [[ ! -f "$pack_yml" ]] && continue
            local pack_llms
            pack_llms=$(yml_get_llms "$pack_yml")
            [[ -z "$pack_llms" ]] && continue
            while IFS=$'\t' read -r lname ldesc lvariant; do
                [[ -z "$lname" ]] && continue
                local found=false
                for ((i=0; i<${#seen_keys[@]}; i++)); do
                    [[ "${seen_keys[$i]}" == "$lname" ]] && { found=true; break; }
                done
                if [[ "$found" == "false" ]]; then
                    seen_keys+=("$lname")
                    seen_vals+=("${lname}	${ldesc}	${lvariant}")
                fi
            done <<< "$pack_llms"
        done <<< "$pack_names"
    fi

    # Project llms (higher priority — override pack entries)
    if [[ -f "$project_yml" ]]; then
        local proj_llms
        proj_llms=$(yml_get_llms "$project_yml")
        if [[ -n "$proj_llms" ]]; then
            while IFS=$'\t' read -r lname ldesc lvariant; do
                [[ -z "$lname" ]] && continue
                local found=false
                for ((i=0; i<${#seen_keys[@]}; i++)); do
                    if [[ "${seen_keys[$i]}" == "$lname" ]]; then
                        seen_vals[$i]="${lname}	${ldesc}	${lvariant}"
                        found=true
                        break
                    fi
                done
                if [[ "$found" == "false" ]]; then
                    seen_keys+=("$lname")
                    seen_vals+=("${lname}	${ldesc}	${lvariant}")
                fi
            done <<< "$proj_llms"
        fi
    fi

    # Output all collected entries
    if [[ ${#seen_vals[@]} -gt 0 ]]; then
        printf '%s\n' "${seen_vals[@]}"
    fi
}

# Generate Docker volume mount lines for llms resources.
# Outputs compose-format volume lines to stdout.
_generate_llms_mounts() {
    local project_yml="$1"
    local pack_names="$2"

    local entries
    entries=$(_collect_llms_names "$project_yml" "$pack_names")
    [[ -z "$entries" ]] && return 0

    echo "      # LLMs.txt documentation (read-only mounts from central llms registry)"
    while IFS=$'\t' read -r lname ldesc lvariant; do
        [[ -z "$lname" ]] && continue
        local llms_dir="$LLMS_DIR/$lname"
        if [[ -d "$llms_dir" ]]; then
            echo "      - ${llms_dir}:/workspace/.claude/llms/${lname}:ro"
        else
            warn "LLMs '$lname': directory not found at $llms_dir (run 'cco llms install' first)"
        fi
    done <<< "$entries"
}

# Generate the llms section for packs.md.
# Outputs markdown lines to stdout (empty if no llms configured).
_generate_llms_packs_md() {
    local project_yml="$1"
    local pack_names="$2"
    local count_var="$3"  # name of variable to store line count

    local entries
    entries=$(_collect_llms_names "$project_yml" "$pack_names")
    [[ -z "$entries" ]] && return 0

    # Buffer entries first to avoid orphaned header when all dirs are missing
    local buffered_lines=()
    while IFS=$'\t' read -r lname ldesc lvariant; do
        [[ -z "$lname" ]] && continue
        local llms_dir="$LLMS_DIR/$lname"
        [[ ! -d "$llms_dir" ]] && continue
        local primary
        primary=$(_llms_resolve_primary_file "$llms_dir" "$lvariant") || continue
        local fpath="/workspace/.claude/llms/${lname}/${primary}"
        local line_count
        line_count=$(wc -l < "$llms_dir/$primary" 2>/dev/null || echo "?")
        line_count=$(echo "$line_count" | tr -d ' ')

        # Build description
        local desc_text=""
        if [[ -n "$ldesc" ]]; then
            desc_text="$ldesc"
        else
            # Auto-generate from H1 heading
            local h1
            h1=$(head -20 "$llms_dir/$primary" 2>/dev/null | grep -m1 '^# ' | sed 's/^# //')
            if [[ -n "$h1" ]]; then
                desc_text="$h1"
            else
                desc_text="$lname documentation"
            fi
        fi

        # Add type hint
        local type_hint=""
        if [[ "$primary" == "llms.txt" ]]; then
            type_hint=" (${line_count} lines, index — WebFetch for details)"
        else
            type_hint=" (${line_count} lines)"
        fi

        buffered_lines+=("- ${fpath} — ${desc_text}${type_hint}")
    done <<< "$entries"

    # Only emit section if at least one valid entry exists
    if [[ ${#buffered_lines[@]} -eq 0 ]]; then
        return 0
    fi

    local lines=${#buffered_lines[@]}
    echo ""
    echo "## Official Framework Documentation (llms.txt)"
    echo ""
    echo "The following official framework documentation files are installed."
    echo "Consult them BEFORE writing code that uses these frameworks — do not rely solely on training data."
    echo "For large files, read selectively using offset/limit. For index files, WebFetch specific pages as needed."
    echo ""
    printf '%s\n' "${buffered_lines[@]}"

    # Set the count via nameref-compatible eval
    if [[ -n "$count_var" ]]; then
        eval "$count_var=$lines"
    fi
}

# Validate llms references in a pack or project YAML file.
# Returns 0 if all valid, 1 if errors found.
_validate_llms_refs() {
    local yaml_file="$1"
    local context="$2"  # e.g., "Pack 'frontend-stack'" or "Project 'my-app'"
    local errors=0

    local llms_names
    llms_names=$(yml_get_llms_names "$yaml_file")
    [[ -z "$llms_names" ]] && return 0

    while IFS= read -r lname; do
        [[ -z "$lname" ]] && continue
        local llms_dir="$LLMS_DIR/$lname"
        if [[ ! -d "$llms_dir" ]]; then
            error "$context: llms '$lname' not found (run 'cco llms install' first)"
            ((errors++))
            continue
        fi
        if ! _llms_resolve_primary_file "$llms_dir" "" > /dev/null 2>&1; then
            error "$context: llms '$lname' has no documentation files"
            ((errors++))
        fi
    done <<< "$llms_names"

    [[ $errors -gt 0 ]] && return 1 || return 0
}

# Check llms.txt freshness for cco update discovery phase.
# Warns if any llms entry was downloaded more than 30 days ago.
_update_check_llms_freshness() {
    local threshold_days=30
    [[ ! -d "$LLMS_DIR" ]] && return 0

    local stale_entries=()
    for dir in "$LLMS_DIR"/*/; do
        [[ ! -d "$dir" ]] && continue
        local dname
        dname=$(basename "$dir")
        [[ "$dname" == ".cco" ]] && continue
        local source_file="$dir/.cco/source"
        [[ ! -f "$source_file" ]] && continue
        local downloaded
        downloaded=$(yml_get "$source_file" "downloaded" 2>/dev/null)
        [[ -z "$downloaded" ]] && continue
        # Extract date part (YYYY-MM-DD)
        local dl_date="${downloaded%%T*}"
        # Calculate age in days using portable date arithmetic
        local dl_epoch today_epoch age_days
        dl_epoch=$(date -d "$dl_date" +%s 2>/dev/null || date -jf "%Y-%m-%d" "$dl_date" +%s 2>/dev/null) || continue
        today_epoch=$(date +%s)
        age_days=$(( (today_epoch - dl_epoch) / 86400 ))
        if [[ $age_days -ge $threshold_days ]]; then
            stale_entries+=("$dname (${age_days} days ago)")
        fi
    done

    if [[ ${#stale_entries[@]} -gt 0 ]]; then
        echo ""
        info "llms.txt updates may be available:"
        for entry in "${stale_entries[@]}"; do
            info "  $entry"
        done
        info "Run 'cco llms update --all' to refresh."
    fi
}
