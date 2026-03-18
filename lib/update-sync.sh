# lib/update-sync.sh — Interactive sync with merge/replace/keep/skip prompts

# ── File Change Application ──────────────────────────────────────────

# Apply collected file changes with 3-way merge support.
# Reads "STATUS\tpath" lines from first argument (string).
# Returns updated manifest entries via _UPDATE_MANIFEST_ENTRIES (newline-separated "path\thash").
_UPDATE_MANIFEST_ENTRIES=""
_LAST_RESOLVE_AUTOMERGE=false  # set by _resolve_with_merge for counter tracking
_LAST_RESOLVE_SKIPPED=false    # set by _resolve_with_merge when user chooses skip inside conflict
_SYNC_FILES_APPLIED=0          # set by _interactive_sync: count of files applied/merged/kept (not skipped)

## _apply_file_changes — REMOVED (replaced by _interactive_sync in Sprint 3+4)

# ── Interactive Apply ─────────────────────────────────────────────────

# Interactive per-file apply with user prompts.
# Called only in --sync mode.
_interactive_sync() {
    local changes="$1"
    local defaults_dir="$2"
    local installed_dir="$3"
    local base_dir="$4"
    local no_backup="$5"
    local auto_action="$6"  # "" for interactive, "replace"|"keep"|"skip" for auto
    local scope_label="$7"

    [[ -z "$changes" ]] && return 0

    _UPDATE_MANIFEST_ENTRIES=""
    local applied=0 skipped=0 merged=0 kept=0

    while IFS=$'\t' read -r status rel_path; do
        [[ -z "$status" ]] && continue

        case "$status" in
            NEW)
                local choice="$auto_action"
                if [[ -z "$choice" ]]; then
                    echo ""
                    info "$scope_label: $rel_path (new framework file)"
                    echo "  (A)dd file  (S)kip"
                    if (exec < /dev/tty) 2>/dev/null; then
                        read -rp "  Choice [A/s]: " choice < /dev/tty
                    fi
                    choice="${choice:-A}"
                    choice="$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')"
                fi
                case "$choice" in
                    a|add|replace)
                        mkdir -p "$(dirname "$installed_dir/$rel_path")"
                        cp "$defaults_dir/$rel_path" "$installed_dir/$rel_path"
                        _save_base_version "$base_dir" "$rel_path" "$defaults_dir/$rel_path"
                        local h; h=$(_file_hash "$defaults_dir/$rel_path")
                        _UPDATE_MANIFEST_ENTRIES+="${rel_path}	${h}"$'\n'
                        ok "  + $rel_path (added)"
                        applied=$(( applied + 1 ))
                        ;;
                    *)
                        # Skip: don't update .cco/base/ or manifest — will be reported again next run
                        info "  Skipped $rel_path"
                        skipped=$(( skipped + 1 ))
                        ;;
                esac
                ;;

            UPDATE_AVAILABLE|SAFE_UPDATE)
                local choice="$auto_action"
                if [[ -z "$choice" ]]; then
                    echo ""
                    info "$scope_label: $rel_path (framework updated, you haven't modified)"
                    echo "  (A)pply update  (S)kip  (D)iff"
                    if (exec < /dev/tty) 2>/dev/null; then
                        read -rp "  Choice [A/s/d]: " choice < /dev/tty
                    fi
                    choice="${choice:-A}"
                    choice="$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')"
                    # Handle (D)iff: show diff then re-prompt
                    if [[ "$choice" == "d" ]]; then
                        diff -u "$installed_dir/$rel_path" "$defaults_dir/$rel_path" \
                            --label "your version" --label "new default" 2>/dev/null | sed 's/^/  /' || true
                        echo ""
                        if (exec < /dev/tty) 2>/dev/null; then
                            read -rp "  (A)pply update  (S)kip [A/s]: " choice < /dev/tty
                        fi
                        choice="${choice:-A}"
                        choice="$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')"
                    fi
                fi
                case "$choice" in
                    a|apply|replace)
                        if [[ "$no_backup" != "true" && -f "$installed_dir/$rel_path" ]]; then
                            cp "$installed_dir/$rel_path" "$installed_dir/${rel_path}.bak"
                        fi
                        cp "$defaults_dir/$rel_path" "$installed_dir/$rel_path"
                        _save_base_version "$base_dir" "$rel_path" "$defaults_dir/$rel_path"
                        local h; h=$(_file_hash "$defaults_dir/$rel_path")
                        _UPDATE_MANIFEST_ENTRIES+="${rel_path}	${h}"$'\n'
                        ok "  ~ $rel_path (updated)"
                        applied=$(( applied + 1 ))
                        ;;
                    keep)
                        # Keep user file but update .cco/base/ so update isn't reported again
                        _save_base_version "$base_dir" "$rel_path" "$defaults_dir/$rel_path"
                        local h; h=$(_file_hash "$defaults_dir/$rel_path")
                        _UPDATE_MANIFEST_ENTRIES+="${rel_path}	${h}"$'\n'
                        info "  Kept user version of $rel_path"
                        kept=$(( kept + 1 ))
                        ;;
                    *)
                        # Skip: don't update .cco/base/ or manifest — will be reported again next run
                        info "  Skipped $rel_path"
                        skipped=$(( skipped + 1 ))
                        ;;
                esac
                ;;

            BASE_MISSING)
                # No .cco/base/ entry — can't determine if user modified the file.
                # Offer New-file as default since user may have customized this file.
                # In non-TTY mode without auto_action, skip (don't silently create .new files).
                local choice="$auto_action"
                if [[ -z "$choice" ]]; then
                    if ! (exec < /dev/tty) 2>/dev/null; then
                        # Non-TTY: skip silently
                        choice="s"
                    else
                        echo ""
                        info "$scope_label: $rel_path (framework update available — manual review recommended)"
                        echo "  (N)ew-file (.new)  (A)pply update  (K)eep yours  (S)kip  (D)iff"
                        echo "  Tip: (N) saves framework version as .new for manual review — recommended if you customized this file"
                        read -rp "  Choice [N/a/k/s/d]: " choice < /dev/tty
                        choice="${choice:-N}"
                    fi
                    choice="$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')"
                    # Handle (D)iff: show diff then re-prompt
                    if [[ "$choice" == "d" ]]; then
                        diff -u "$installed_dir/$rel_path" "$defaults_dir/$rel_path" \
                            --label "your version" --label "new default" 2>/dev/null | sed 's/^/  /' || true
                        echo ""
                        if (exec < /dev/tty) 2>/dev/null; then
                            read -rp "  (N)ew-file (.new)  (A)pply update  (K)eep yours  (S)kip [N/a/k/s]: " choice < /dev/tty
                        fi
                        choice="${choice:-N}"
                        choice="$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')"
                    fi
                fi
                case "$choice" in
                    n|new)
                        # Save framework version as .new alongside user's file
                        cp "$defaults_dir/$rel_path" "$installed_dir/${rel_path}.new"
                        _save_base_version "$base_dir" "$rel_path" "$defaults_dir/$rel_path"
                        local h; h=$(_file_hash "$defaults_dir/$rel_path")
                        _UPDATE_MANIFEST_ENTRIES+="${rel_path}	${h}"$'\n'
                        ok "  ~ $rel_path → saved framework version as ${rel_path}.new"
                        info "    Review .new and integrate changes manually, then delete the .new file"
                        applied=$(( applied + 1 ))
                        ;;
                    a|apply|replace)
                        if [[ "$no_backup" != "true" && -f "$installed_dir/$rel_path" ]]; then
                            cp "$installed_dir/$rel_path" "$installed_dir/${rel_path}.bak"
                        fi
                        cp "$defaults_dir/$rel_path" "$installed_dir/$rel_path"
                        _save_base_version "$base_dir" "$rel_path" "$defaults_dir/$rel_path"
                        local h; h=$(_file_hash "$defaults_dir/$rel_path")
                        _UPDATE_MANIFEST_ENTRIES+="${rel_path}	${h}"$'\n'
                        ok "  ~ $rel_path (updated)"
                        applied=$(( applied + 1 ))
                        ;;
                    k|keep)
                        # Keep user file but update .cco/base/ so update isn't reported again
                        _save_base_version "$base_dir" "$rel_path" "$defaults_dir/$rel_path"
                        local h; h=$(_file_hash "$defaults_dir/$rel_path")
                        _UPDATE_MANIFEST_ENTRIES+="${rel_path}	${h}"$'\n'
                        info "  Kept user version of $rel_path"
                        kept=$(( kept + 1 ))
                        ;;
                    *)
                        # Skip: don't update .cco/base/ or manifest — will be reported again next run
                        info "  Skipped $rel_path"
                        skipped=$(( skipped + 1 ))
                        ;;
                esac
                ;;

            MERGE_AVAILABLE|CONFLICT)
                local choice="$auto_action"
                if [[ -z "$choice" ]]; then
                    echo ""
                    info "$scope_label: $rel_path (both modified — merge needed)"
                    echo "  (M)erge 3-way  (N)ew-file (.new)  (R)eplace + .bak  (K)eep yours  (S)kip  (D)iff"
                    echo "  Tip: use (N) if you restructured this file — saves framework version as .new for manual review"
                    if (exec < /dev/tty) 2>/dev/null; then
                        read -rp "  Choice [M/n/r/k/s/d]: " choice < /dev/tty
                    fi
                    choice="${choice:-M}"
                    choice="$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')"
                    # Handle (D)iff: show diff then re-prompt
                    if [[ "$choice" == "d" ]]; then
                        if [[ -f "$base_dir/$rel_path" ]]; then
                            echo "  --- framework changes (base → new):"
                            diff -u "$base_dir/$rel_path" "$defaults_dir/$rel_path" \
                                --label "previous default" --label "new default" 2>/dev/null | sed 's/^/  /' || true
                            echo ""
                            echo "  --- your changes (base → current):"
                            diff -u "$base_dir/$rel_path" "$installed_dir/$rel_path" \
                                --label "previous default" --label "your version" 2>/dev/null | sed 's/^/  /' || true
                        else
                            diff -u "$installed_dir/$rel_path" "$defaults_dir/$rel_path" \
                                --label "your version" --label "new default" 2>/dev/null | sed 's/^/  /' || true
                        fi
                        echo ""
                        if (exec < /dev/tty) 2>/dev/null; then
                            read -rp "  (M)erge 3-way  (N)ew-file (.new)  (R)eplace + .bak  (K)eep yours  (S)kip [M/n/r/k/s]: " choice < /dev/tty
                        fi
                        choice="${choice:-M}"
                        choice="$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')"
                    fi
                fi
                case "$choice" in
                    m|merge)
                        _LAST_RESOLVE_AUTOMERGE=false
                        _LAST_RESOLVE_SKIPPED=false
                        _resolve_with_merge "$rel_path" "$defaults_dir" "$installed_dir" "$base_dir" "$no_backup"
                        if $_LAST_RESOLVE_SKIPPED; then
                            # Skip inside conflict resolution — defer to next run
                            skipped=$(( skipped + 1 ))
                        else
                            _save_base_version "$base_dir" "$rel_path" "$defaults_dir/$rel_path"
                            local h; h=$(_file_hash "$defaults_dir/$rel_path")
                            _UPDATE_MANIFEST_ENTRIES+="${rel_path}	${h}"$'\n'
                            if $_LAST_RESOLVE_AUTOMERGE; then
                                merged=$(( merged + 1 ))
                            else
                                applied=$(( applied + 1 ))
                            fi
                        fi
                        ;;
                    n|new)
                        # Save framework version as .new alongside user's file
                        cp "$defaults_dir/$rel_path" "$installed_dir/${rel_path}.new"
                        _save_base_version "$base_dir" "$rel_path" "$defaults_dir/$rel_path"
                        local h; h=$(_file_hash "$defaults_dir/$rel_path")
                        _UPDATE_MANIFEST_ENTRIES+="${rel_path}	${h}"$'\n'
                        ok "  ~ $rel_path → saved framework version as ${rel_path}.new"
                        info "    Review .new and integrate changes manually, then delete the .new file"
                        applied=$(( applied + 1 ))
                        ;;
                    r|replace)
                        if [[ "$no_backup" != "true" && -f "$installed_dir/$rel_path" ]]; then
                            cp "$installed_dir/$rel_path" "$installed_dir/${rel_path}.bak"
                            warn "  ↻ $rel_path (replaced, backup → ${rel_path}.bak)"
                        else
                            warn "  ↻ $rel_path (replaced)"
                        fi
                        cp "$defaults_dir/$rel_path" "$installed_dir/$rel_path"
                        _save_base_version "$base_dir" "$rel_path" "$defaults_dir/$rel_path"
                        local h; h=$(_file_hash "$defaults_dir/$rel_path")
                        _UPDATE_MANIFEST_ENTRIES+="${rel_path}	${h}"$'\n'
                        applied=$(( applied + 1 ))
                        ;;
                    k|keep)
                        # Keep user file but update .cco/base/ so update isn't reported again
                        _save_base_version "$base_dir" "$rel_path" "$defaults_dir/$rel_path"
                        local h; h=$(_file_hash "$defaults_dir/$rel_path")
                        _UPDATE_MANIFEST_ENTRIES+="${rel_path}	${h}"$'\n'
                        info "  Kept user version of $rel_path"
                        kept=$(( kept + 1 ))
                        ;;
                    *)
                        # Skip: don't update .cco/base/ or manifest — will be reported again next run
                        info "  Skipped $rel_path"
                        skipped=$(( skipped + 1 ))
                        ;;
                esac
                ;;

            USER_MODIFIED|NO_UPDATE)
                # Keep current hash in manifest — no action needed
                local h; h=$(_file_hash "$installed_dir/$rel_path")
                _UPDATE_MANIFEST_ENTRIES+="${rel_path}	${h}"$'\n'
                ;;

            REMOVED)
                local choice="$auto_action"
                if [[ -z "$choice" ]]; then
                    echo ""
                    warn "$scope_label: $rel_path (removed from framework defaults)"
                    echo "  File will be kept locally. No action needed."
                fi
                if [[ -f "$installed_dir/$rel_path" ]]; then
                    local h; h=$(_file_hash "$installed_dir/$rel_path")
                    _UPDATE_MANIFEST_ENTRIES+="${rel_path}	${h}"$'\n'
                fi
                ;;

            DELETED_UPDATED)
                local choice="$auto_action"
                if [[ -z "$choice" ]]; then
                    echo ""
                    info "$scope_label: $rel_path (you deleted, framework has updates)"
                    echo "  (A)dd back with new version  (S)kip"
                    if (exec < /dev/tty) 2>/dev/null; then
                        read -rp "  Choice [s/A]: " choice < /dev/tty
                    fi
                    choice="${choice:-s}"
                    choice="$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')"
                fi
                case "$choice" in
                    a|add|replace)
                        mkdir -p "$(dirname "$installed_dir/$rel_path")"
                        cp "$defaults_dir/$rel_path" "$installed_dir/$rel_path"
                        _save_base_version "$base_dir" "$rel_path" "$defaults_dir/$rel_path"
                        local h; h=$(_file_hash "$defaults_dir/$rel_path")
                        _UPDATE_MANIFEST_ENTRIES+="${rel_path}	${h}"$'\n'
                        ok "  + $rel_path (re-added with latest version)"
                        applied=$(( applied + 1 ))
                        ;;
                    *)
                        # Skip: update .cco/base/ to stop notifying, respect deletion
                        _save_base_version "$base_dir" "$rel_path" "$defaults_dir/$rel_path"
                        info "  Skipped $rel_path (won't notify again until next framework update)"
                        skipped=$(( skipped + 1 ))
                        ;;
                esac
                ;;
        esac
    done <<< "$changes"

    # Export sync result for callers that need to know if anything was applied
    _SYNC_FILES_APPLIED=$(( applied + merged + kept ))

    # Show summary
    local total_changes=$(( applied + merged + kept ))
    if [[ $total_changes -gt 0 || $skipped -gt 0 ]]; then
        local parts=()
        [[ $applied -gt 0 ]] && parts+=("$applied applied")
        [[ $merged -gt 0 ]] && parts+=("$merged merged")
        [[ $kept -gt 0 ]] && parts+=("$kept kept")
        [[ $skipped -gt 0 ]] && parts+=("$skipped skipped")
        if [[ ${#parts[@]} -gt 0 ]]; then
            local summary
            printf -v summary '%s, ' "${parts[@]}"
            summary="${summary%, }"
            info "$scope_label files: $summary"
        fi
    fi
}
