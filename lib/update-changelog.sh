# lib/update-changelog.sh — Changelog parsing, tracking, and display

# ── Changelog Notifications ──────────────────────────────────────────

# Read changelog entries from changelog.yml.
# Output: one line per entry as "id\tdate\ttitle\tdescription"
# Supports YAML folded (>) and literal (|) block scalars for description.
_read_changelog_entries() {
    local changelog="$REPO_ROOT/changelog.yml"
    [[ ! -f "$changelog" ]] && return 0

    # Parse YAML entries — simple line-based parser
    local in_entry=false in_desc=false
    local entry_id="" entry_date="" entry_title="" entry_desc=""

    while IFS= read -r line; do
        # Strip leading whitespace for matching (entries may be indented under `entries:`)
        local trimmed="${line#"${line%%[![:space:]]*}"}"

        # Check if this is a continuation line for a multi-line description.
        # Continuation lines are non-empty, don't start a new field, and appear
        # after a description: > or description: | declaration.
        if $in_desc; then
            case "$trimmed" in
                "- id:"*|"date:"*|"title:"*|"type:"*|"description:"*|"- date:"*|"- title:"*|"- type:"*|"- description:"*)
                    in_desc=false
                    ;;
                "")
                    # Empty line inside block scalar — skip (YAML treats as paragraph break)
                    ;;
                *)
                    # Continuation line — accumulate into description
                    entry_desc="${entry_desc:+$entry_desc }${trimmed}"
                    continue
                    ;;
            esac
        fi

        case "$trimmed" in
            "- id:"*)
                # Emit previous entry if any
                if [[ -n "$entry_id" ]]; then
                    printf '%s\t%s\t%s\t%s\n' "$entry_id" "$entry_date" "$entry_title" "$entry_desc"
                fi
                entry_id="${trimmed#*: }"
                entry_date="" entry_title="" entry_desc=""
                in_entry=true
                in_desc=false
                ;;
            "date:"*|"- date:"*)
                $in_entry && entry_date="${trimmed#*: }" && entry_date="${entry_date%\"}" && entry_date="${entry_date#\"}"
                ;;
            "title:"*|"- title:"*)
                $in_entry && entry_title="${trimmed#*: }" && entry_title="${entry_title%\"}" && entry_title="${entry_title#\"}"
                ;;
            "description:"*|"- description:"*)
                if $in_entry; then
                    local desc_val="${trimmed#*: }"
                    desc_val="${desc_val%\"}"
                    desc_val="${desc_val#\"}"
                    if [[ "$desc_val" == ">" || "$desc_val" == "|" || "$desc_val" == ">-" || "$desc_val" == "|-" ]]; then
                        # Block scalar — actual content is on continuation lines
                        entry_desc=""
                        in_desc=true
                    else
                        # Inline value
                        entry_desc="$desc_val"
                        in_desc=false
                    fi
                fi
                ;;
        esac
    done < "$changelog"

    # Emit last entry
    if [[ -n "$entry_id" ]]; then
        printf '%s\t%s\t%s\t%s\n' "$entry_id" "$entry_date" "$entry_title" "$entry_desc"
    fi
}

# Show changelog summary (brief, shown in default mode).
# Only shows entries with id > last_seen_changelog.
# Shows --news hint only if there are unread entries (last_read < latest).
_show_changelog_summary() {
    local last_seen="$1"
    local last_read="$2"

    local entries
    entries=$(_read_changelog_entries)
    [[ -z "$entries" ]] && return 0

    local shown=0 max_shown_id=0
    while IFS=$'\t' read -r eid edate etitle edesc; do
        [[ -z "$eid" ]] && continue
        [[ "$eid" -le "$last_seen" ]] && continue
        if [[ $shown -eq 0 ]]; then
            echo ""
            info "What's new in cco:"
        fi
        info "  + $etitle"
        shown=$(( shown + 1 ))
        [[ "$eid" -gt "$max_shown_id" ]] && max_shown_id="$eid"
    done <<< "$entries"

    # Show --news hint only if user hasn't read the details yet
    if [[ $shown -gt 0 && "$last_read" -lt "$max_shown_id" ]]; then
        info "  Run 'cco update --news' for details and examples."
    fi
}

# Show full changelog details (--news mode).
# Shows entries with id > last_read_changelog.
_show_changelog_news() {
    local last_read="$1"

    local entries
    entries=$(_read_changelog_entries)
    [[ -z "$entries" ]] && return 0

    local shown=0
    while IFS=$'\t' read -r eid edate etitle edesc; do
        [[ -z "$eid" ]] && continue
        [[ "$eid" -le "$last_read" ]] && continue
        echo ""
        info "[$edate] $etitle"
        [[ -n "$edesc" ]] && echo "  $edesc"
        shown=$(( shown + 1 ))
    done <<< "$entries"

    if [[ $shown -eq 0 ]]; then
        echo ""
        ok "No new features since last check."
    fi
}

# Get the highest changelog entry ID.
_latest_changelog_id() {
    local entries
    entries=$(_read_changelog_entries)
    [[ -z "$entries" ]] && echo "0" && return 0

    local max_id=0
    while IFS=$'\t' read -r eid edate etitle edesc; do
        [[ -z "$eid" ]] && continue
        [[ "$eid" -gt "$max_id" ]] && max_id="$eid"
    done <<< "$entries"
    echo "$max_id"
}

# Orchestrate changelog notifications based on cmd_mode.
# Discovery: updates last_seen only. News: updates both last_seen and last_read.
_update_changelog_notifications() {
    local cmd_mode="$1"
    local dry_run="$2"
    local meta_file
    meta_file=$(_cco_global_meta)

    local last_seen last_read latest_id
    last_seen=$(_read_last_seen_changelog "$meta_file")
    last_read=$(_read_last_read_changelog "$meta_file")
    latest_id=$(_latest_changelog_id)

    if [[ "$cmd_mode" == "news" ]]; then
        _show_changelog_news "$last_read"
        # News updates both trackers
        if [[ "$dry_run" != "true" && -f "$meta_file" && "$latest_id" -gt "$last_read" ]]; then
            _sed_i_or_append "$meta_file" "last_read_changelog" "$latest_id"
            _sed_i_or_append "$meta_file" "last_seen_changelog" "$latest_id"
        fi
    else
        _show_changelog_summary "$last_seen" "$last_read"
        # Discovery updates only last_seen
        if [[ "$dry_run" != "true" && -f "$meta_file" && "$latest_id" -gt "$last_seen" ]]; then
            _sed_i_or_append "$meta_file" "last_seen_changelog" "$latest_id"
        fi
    fi
}

# ── Changelog Helpers (spec-compliant API) ───────────────────────────

# Show full changelog details with title, date, and description.
# Delegates to _show_changelog_news. Parameter is last_read (entries not yet read in detail).
_show_changelog_details() {
    local last_read="${1:-0}"
    _show_changelog_news "$last_read"
}

# Get the maximum changelog entry id from changelog.yml.
_max_changelog_id() {
    _latest_changelog_id
}

# Update last_seen_changelog in .cco/meta file.
# Standalone helper for callers that need to update the field directly.
_update_last_seen_changelog() {
    local meta_file="$1"
    local new_id="$2"

    [[ ! -f "$meta_file" ]] && return 0

    if grep -q '^last_seen_changelog:' "$meta_file" 2>/dev/null; then
        _sed_i "$meta_file" "^last_seen_changelog: .*" "last_seen_changelog: $new_id"
    else
        # Field doesn't exist yet — append after updated_at
        local tmpfile
        tmpfile=$(mktemp)
        awk -v new_id="$new_id" '
            { print }
            /^updated_at:/ { print ""; print "last_seen_changelog: " new_id }
        ' "$meta_file" > "$tmpfile"
        mv "$tmpfile" "$meta_file"
    fi
}
