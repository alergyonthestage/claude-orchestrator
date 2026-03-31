# lib/update-discovery.sh — File change detection and diff display

# ── File Change Detection ────────────────────────────────────────────

# Collect file changes between defaults and installed using 3-version comparison.
# Uses .cco/base/ files as the ancestor (base) version.
# Output: "STATUS\trelative_path" lines to stdout.
# STATUS: NEW, NO_UPDATE, UPDATE_AVAILABLE, MERGE_AVAILABLE, USER_MODIFIED, REMOVED, BASE_MISSING
_collect_file_changes() {
    local defaults_dir="$1"
    local installed_dir="$2"
    local base_dir="$3"
    local scope="$4"

    # Discover default files (relative to .claude/)
    local default_files=()
    if [[ -d "$defaults_dir" ]]; then
        while IFS= read -r fpath; do
            [[ -z "$fpath" ]] && continue
            # Make relative to defaults_dir
            local rel="${fpath#$defaults_dir/}"
            # Skip untracked and special files
            if [[ "$scope" == "global" ]]; then
                if [[ ${#GLOBAL_UNTRACKED_FILES[@]} -gt 0 ]] && _in_array "$rel" "${GLOBAL_UNTRACKED_FILES[@]}"; then
                    continue
                fi
                # Special files (language.md) are regenerated separately
                if [[ ${#GLOBAL_SPECIAL_FILES[@]} -gt 0 ]] && _in_array "$rel" "${GLOBAL_SPECIAL_FILES[@]}"; then
                    continue
                fi
            elif [[ "$scope" == "project" ]]; then
                if [[ ${#PROJECT_UNTRACKED_FILES[@]} -gt 0 ]] && _in_array "$rel" "${PROJECT_UNTRACKED_FILES[@]}"; then
                    continue
                fi
            fi
            default_files+=("$rel")
        done < <(find "$defaults_dir" -type f | sort)
    fi

    # Track which base files we've seen (for REMOVED detection)
    local seen_base_files=""

    # For project scope, derive project_dir for safety net interpolation.
    # The safety net interpolates ALL recoverable placeholders ({{PROJECT_NAME}}
    # and {{DESCRIPTION}}) to match what _seed_base_from_interpolated_template
    # produces. Without this, base_hash (seeded with both interpolated) would
    # differ from new_hash, causing false MERGE_AVAILABLE.
    local _fc_project_dir=""
    if [[ "$scope" == "project" ]]; then
        _fc_project_dir=$(dirname "$installed_dir")
    fi

    # For each default file, classify using the 3-version algorithm
    local rel
    for rel in ${default_files[@]+"${default_files[@]}"}; do
        local new_hash installed_hash base_hash

        # Safety net: for project scope, interpolate recoverable placeholders
        # ({{PROJECT_NAME}} and {{DESCRIPTION}}) in the template before hashing.
        # Must match _seed_base_from_interpolated_template to avoid false diffs.
        if [[ -n "$_fc_project_dir" ]]; then
            local _fc_tmp
            _fc_tmp=$(_interpolate_template_tmp "$defaults_dir/$rel" "$_fc_project_dir")
            new_hash=$(_file_hash "$_fc_tmp")
            rm -f "$_fc_tmp"
        else
            new_hash=$(_file_hash "$defaults_dir/$rel")
        fi
        installed_hash=$(_file_hash "$installed_dir/$rel")
        base_hash=$(_file_hash "$base_dir/$rel")

        seen_base_files+="$rel"$'\n'

        if [[ -z "$installed_hash" ]] && [[ -z "$base_hash" ]]; then
            # File exists in defaults but not in target AND not in .cco/base/
            printf 'NEW\t%s\n' "$rel"

        elif [[ -z "$installed_hash" ]] && [[ -n "$base_hash" ]]; then
            # File was in base but user deleted it
            if [[ "$new_hash" != "$base_hash" ]]; then
                # Framework updated the file since user deleted it — notify
                printf 'DELETED_UPDATED\t%s\n' "$rel"
            else
                # Framework unchanged — respect user's deletion silently
                printf 'NO_UPDATE\t%s\n' "$rel"
            fi

        elif [[ -z "$base_hash" ]]; then
            # BASE_MISSING: no .cco/base/ entry for this file
            # Fallback: compare defaults directly against user file
            if [[ "$installed_hash" == "$new_hash" ]]; then
                printf 'NO_UPDATE\t%s\n' "$rel"
            else
                printf 'BASE_MISSING\t%s\n' "$rel"
            fi

        elif [[ "$new_hash" == "$base_hash" ]]; then
            # Framework hasn't changed since last install/apply
            if [[ "$installed_hash" != "$base_hash" ]]; then
                printf 'USER_MODIFIED\t%s\n' "$rel"
            else
                printf 'NO_UPDATE\t%s\n' "$rel"
            fi

        elif [[ "$installed_hash" == "$base_hash" ]]; then
            # User hasn't modified, framework has updated
            printf 'UPDATE_AVAILABLE\t%s\n' "$rel"

        elif [[ "$installed_hash" != "$base_hash" ]] && [[ "$new_hash" != "$base_hash" ]]; then
            # Both user and framework have changed — check divergence level
            local inst_lines=0 base_lines=1
            [[ -f "$installed_dir/$rel" ]] && inst_lines=$(wc -l < "$installed_dir/$rel")
            [[ -f "$base_dir/$rel" ]] && base_lines=$(wc -l < "$base_dir/$rel")
            [[ $base_lines -eq 0 ]] && base_lines=1
            if [[ $inst_lines -gt $(( base_lines * 3 )) ]]; then
                printf 'USER_RESTRUCTURED\t%s\n' "$rel"
            else
                printf 'MERGE_AVAILABLE\t%s\n' "$rel"
            fi
        fi
    done

    # Detect files in .cco/base/ but no longer in defaults (REMOVED)
    if [[ -d "$base_dir" ]]; then
        while IFS= read -r fpath; do
            [[ -z "$fpath" ]] && continue
            local rel="${fpath#$base_dir/}"
            # Skip if already processed (exists in defaults)
            if echo "$seen_base_files" | grep -qxF "$rel"; then
                continue
            fi
            # Skip untracked files
            if [[ "$scope" == "global" && ${#GLOBAL_UNTRACKED_FILES[@]} -gt 0 ]] && _in_array "$rel" "${GLOBAL_UNTRACKED_FILES[@]}"; then
                continue
            fi
            if [[ "$scope" == "project" && ${#PROJECT_UNTRACKED_FILES[@]} -gt 0 ]] && _in_array "$rel" "${PROJECT_UNTRACKED_FILES[@]}"; then
                continue
            fi
            printf 'REMOVED\t%s\n' "$rel"
        done < <(find "$base_dir" -type f | sort)
    fi
}

# ── Discovery Summary ─────────────────────────────────────────────────

# Show a concise read-only summary of discovered changes.
# Input: newline-separated "STATUS\tpath" lines (from _collect_file_changes).
# Only shows output if there are actionable changes. Silent if everything is NO_UPDATE.
_show_discovery_summary() {
    local changes="$1"
    local scope_label="$2"  # e.g., "Global" or "Project 'myapp'"

    [[ -z "$changes" ]] && return 0

    local update_count=0 merge_count=0 new_count=0 removed_count=0 base_missing_count=0 deleted_updated_count=0 restructured_count=0

    while IFS=$'\t' read -r status rel_path; do
        [[ -z "$status" ]] && continue
        case "$status" in
            UPDATE_AVAILABLE|SAFE_UPDATE) update_count=$(( update_count + 1 )) ;;
            MERGE_AVAILABLE|CONFLICT)     merge_count=$(( merge_count + 1 )) ;;
            USER_RESTRUCTURED)            restructured_count=$(( restructured_count + 1 )) ;;
            NEW)                          new_count=$(( new_count + 1 )) ;;
            REMOVED)                      removed_count=$(( removed_count + 1 )) ;;
            BASE_MISSING)                 base_missing_count=$(( base_missing_count + 1 )) ;;
            DELETED_UPDATED)              deleted_updated_count=$(( deleted_updated_count + 1 )) ;;
        esac
    done <<< "$changes"

    local total=$(( update_count + merge_count + restructured_count + new_count + removed_count + base_missing_count + deleted_updated_count ))
    [[ $total -eq 0 ]] && return 0

    echo ""
    info "$scope_label: opinionated updates available:"
    [[ $update_count -gt 0 ]] && info "  $update_count file(s) updated by the framework — safe to apply"
    [[ $merge_count -gt 0 ]] && info "  $merge_count file(s) changed by both you and the framework — review needed"
    [[ $restructured_count -gt 0 ]] && info "  $restructured_count file(s) heavily customized — .new review recommended"
    [[ $new_count -gt 0 ]] && info "  $new_count new file(s) from the framework"
    [[ $removed_count -gt 0 ]] && info "  $removed_count file(s) no longer shipped by the framework"
    [[ $base_missing_count -gt 0 ]] && info "  $base_missing_count file(s) with available updates — manual review recommended"
    [[ $deleted_updated_count -gt 0 ]] && info "  $deleted_updated_count file(s) you removed have new framework updates"
    echo ""
    info "Run 'cco update --diff' for details, 'cco update --sync' to review and apply."
}

# ── Diff Summary ─────────────────────────────────────────────────────

# Show per-file summary (name + status) without diff content.
# Used by --diff without scope (overview mode).
_show_file_diffs_summary() {
    local changes="$1"
    local scope_label="$2"

    [[ -z "$changes" ]] && return 0

    local shown=0
    local lines=""

    while IFS=$'\t' read -r status rel_path; do
        [[ -z "$status" ]] && continue
        case "$status" in
            NEW)                 lines+="  $rel_path — new framework file"$'\n'; shown=$(( shown + 1 )) ;;
            UPDATE_AVAILABLE|SAFE_UPDATE) lines+="  $rel_path — framework updated (safe to apply)"$'\n'; shown=$(( shown + 1 )) ;;
            BASE_MISSING)        lines+="  $rel_path — update available (manual review recommended)"$'\n'; shown=$(( shown + 1 )) ;;
            MERGE_AVAILABLE|CONFLICT) lines+="  $rel_path — both modified (merge needed)"$'\n'; shown=$(( shown + 1 )) ;;
            USER_RESTRUCTURED)   lines+="  $rel_path — heavily customized (review .new recommended)"$'\n'; shown=$(( shown + 1 )) ;;
            REMOVED)             lines+="  $rel_path — removed from framework"$'\n'; shown=$(( shown + 1 )) ;;
            DELETED_UPDATED)     lines+="  $rel_path — you deleted, framework has updates"$'\n'; shown=$(( shown + 1 )) ;;
        esac
    done <<< "$changes"

    [[ $shown -eq 0 ]] && return 0

    echo ""
    info "$scope_label:"
    printf '%s' "$lines"
}

# ── Diff Display ─────────────────────────────────────────────────────

# Show detailed diffs for each discovered change.
# Input: newline-separated "STATUS\tpath" lines (from _collect_file_changes).
_show_file_diffs() {
    local changes="$1"
    local defaults_dir="$2"
    local installed_dir="$3"
    local base_dir="$4"
    local scope_label="$5"

    [[ -z "$changes" ]] && return 0

    local shown=0

    # For project scope, prepare an interpolated temp copy of the template
    # for display. This avoids showing raw {{PLACEHOLDER}} in diffs.
    local _sfd_project_dir=""
    if [[ "$scope_label" != "Global" ]]; then
        _sfd_project_dir=$(dirname "$installed_dir")
    fi

    while IFS=$'\t' read -r status rel_path; do
        [[ -z "$status" ]] && continue

        # Get interpolated template path (temp file for project scope, raw for global)
        local _sfd_new_file="$defaults_dir/$rel_path"
        local _sfd_tmp=""
        if [[ -n "$_sfd_project_dir" && -f "$defaults_dir/$rel_path" ]]; then
            _sfd_tmp=$(_interpolate_template_tmp "$defaults_dir/$rel_path" "$_sfd_project_dir")
            _sfd_new_file="$_sfd_tmp"
        fi

        case "$status" in
            NEW)
                echo ""
                info "$scope_label: $rel_path (new framework file)"
                echo "  --- /dev/null"
                echo "  +++ $rel_path"
                if [[ -f "$_sfd_new_file" ]]; then
                    sed 's/^/  + /' "$_sfd_new_file"
                fi
                shown=$(( shown + 1 ))
                ;;
            UPDATE_AVAILABLE|SAFE_UPDATE)
                echo ""
                info "$scope_label: $rel_path (framework updated, you haven't modified)"
                if command -v diff >/dev/null 2>&1; then
                    diff -u "$installed_dir/$rel_path" "$_sfd_new_file" \
                        --label "your version" --label "new default" 2>/dev/null | sed 's/^/  /' || true
                fi
                shown=$(( shown + 1 ))
                ;;
            BASE_MISSING)
                echo ""
                info "$scope_label: $rel_path (framework update available — manual review recommended)"
                if command -v diff >/dev/null 2>&1; then
                    diff -u "$installed_dir/$rel_path" "$_sfd_new_file" \
                        --label "your version" --label "new default" 2>/dev/null | sed 's/^/  /' || true
                fi
                shown=$(( shown + 1 ))
                ;;
            MERGE_AVAILABLE|CONFLICT)
                echo ""
                info "$scope_label: $rel_path (both you and the framework modified this file)"
                if [[ -f "$base_dir/$rel_path" ]]; then
                    echo "  --- framework changes (base → new):"
                    diff -u "$base_dir/$rel_path" "$_sfd_new_file" \
                        --label "previous default" --label "new default" 2>/dev/null | sed 's/^/  /' || true
                    echo ""
                    echo "  --- your changes (base → current):"
                    diff -u "$base_dir/$rel_path" "$installed_dir/$rel_path" \
                        --label "previous default" --label "your version" 2>/dev/null | sed 's/^/  /' || true
                else
                    diff -u "$installed_dir/$rel_path" "$_sfd_new_file" \
                        --label "your version" --label "new default" 2>/dev/null | sed 's/^/  /' || true
                fi
                shown=$(( shown + 1 ))
                ;;
            USER_RESTRUCTURED)
                echo ""
                info "$scope_label: $rel_path (heavily customized — text merge unlikely to help)"
                if [[ -f "$base_dir/$rel_path" ]]; then
                    echo "  --- framework changes (base → new):"
                    diff -u "$base_dir/$rel_path" "$_sfd_new_file" \
                        --label "previous default" --label "new default" 2>/dev/null | sed 's/^/  /' || true
                else
                    diff -u "$installed_dir/$rel_path" "$_sfd_new_file" \
                        --label "your version" --label "new default" 2>/dev/null | sed 's/^/  /' || true
                fi
                shown=$(( shown + 1 ))
                ;;
            REMOVED)
                echo ""
                info "$scope_label: $rel_path (removed from framework defaults)"
                shown=$(( shown + 1 ))
                ;;
            DELETED_UPDATED)
                echo ""
                info "$scope_label: $rel_path (you deleted this file, but framework has updates)"
                if [[ -f "$base_dir/$rel_path" ]]; then
                    echo "  --- framework changes since you deleted:"
                    diff -u "$base_dir/$rel_path" "$_sfd_new_file" \
                        --label "version when deleted" --label "new default" 2>/dev/null | sed 's/^/  /' || true
                fi
                shown=$(( shown + 1 ))
                ;;
        esac

        # Clean up interpolated temp file for this iteration
        [[ -n "$_sfd_tmp" ]] && rm -f "$_sfd_tmp"
    done <<< "$changes"

    [[ $shown -eq 0 ]] && return 0
    echo ""
    info "$scope_label: $shown file(s) with available changes."
    info "Run 'cco update --sync' to interactively apply."
}
