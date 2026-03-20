# lib/update-merge.sh — 3-way merge engine and conflict resolution
#
# Cross-module globals (declared in update-sync.sh):
#   _UPDATE_MANIFEST_ENTRIES — appended by _resolve_with_merge
#   _LAST_RESOLVE_AUTOMERGE — set by _resolve_with_merge
#   _LAST_RESOLVE_SKIPPED   — set by _resolve_conflict_interactive

# ── 3-Way Merge ───────────────────────────────────────────────────────

# Attempt 3-way merge using git merge-file.
# Returns: 0 = clean merge, 1 = conflicts, 2 = error
# Merged result written to $output_file.
_merge_file() {
    local current="$1"   # user's current version
    local base="$2"      # framework version at last install/update
    local new="$3"       # updated framework version
    local output="$4"    # where to write merged result

    # If git merge-file is not available, fall back to simple replace
    if ! command -v git >/dev/null 2>&1; then
        cp "$new" "$output"
        return 2
    fi

    # Work on temp copies (git merge-file modifies first arg in-place)
    local tmpdir
    tmpdir=$(mktemp -d)
    cp "$current" "$tmpdir/current"
    cp "$base" "$tmpdir/base"
    cp "$new" "$tmpdir/new"

    # Run 3-way merge. Exit code: 0=clean, 1..127=conflicts, >=128=error/signal
    # Must capture exit code inline (|| ...) to avoid set -e aborting on conflicts
    local exit_code=0
    git merge-file --diff3 \
        -L "your version" -L "previous default" -L "new default" \
        "$tmpdir/current" "$tmpdir/base" "$tmpdir/new" 2>/dev/null || exit_code=$?

    cp "$tmpdir/current" "$output"
    rm -rf "$tmpdir"

    if [[ $exit_code -eq 0 ]]; then
        return 0  # Clean merge
    elif [[ $exit_code -lt 128 ]]; then
        return 1  # Conflicts exist (exit code = number of conflict markers)
    else
        return 2  # Error (signal/crash, git merge-file failed)
    fi
}

# Resolve a conflict using 3-way merge, falling back to interactive prompt
_resolve_with_merge() {
    local rel_path="$1"
    local defaults_dir="$2"
    local installed_dir="$3"
    local base_dir="$4"
    local no_backup="$5"
    local project_dir="${6:-}"  # project root dir (empty for global scope)
    local base_file="$base_dir/$rel_path"

    # If no base version available, fall back to interactive (no merge possible)
    if [[ ! -f "$base_file" ]]; then
        _resolve_conflict_interactive "$rel_path" "$defaults_dir" "$installed_dir" "$no_backup" "$project_dir"
        return
    fi

    # Attempt 3-way merge
    local merge_out
    merge_out=$(mktemp)
    local merge_result=0
    _merge_file "$installed_dir/$rel_path" "$base_file" "$defaults_dir/$rel_path" "$merge_out" || merge_result=$?

    if [[ $merge_result -eq 0 ]]; then
        # Clean merge — auto-apply with backup
        _LAST_RESOLVE_AUTOMERGE=true
        _LAST_RESOLVE_SKIPPED=false
        if [[ "$no_backup" != "true" ]]; then
            cp "$installed_dir/$rel_path" "$installed_dir/${rel_path}.bak"
        fi
        cp "$merge_out" "$installed_dir/$rel_path"
        rm -f "$merge_out"
        ok "  ✓ $rel_path (auto-merged)"
    elif [[ $merge_result -eq 1 ]]; then
        # Conflicts in merge — show conflict sections and let user resolve
        echo ""
        warn "Merge conflict: $rel_path"
        echo "  Both you and the framework changed overlapping sections."
        echo ""

        # Show conflict markers from merged output
        echo "  Conflicting sections:"
        grep -n -A 50 '<<<<<<<' "$merge_out" 2>/dev/null | while IFS= read -r line; do
            echo "  $line"
            # Stop after the closing marker
            [[ "$line" == *">>>>>>>"* ]] && break
        done
        echo ""

        local has_editor=false
        [[ -n "${EDITOR:-}" ]] && command -v "$EDITOR" >/dev/null 2>&1 && has_editor=true

        echo "  (M)erge — write file with conflict markers, resolve manually"
        if $has_editor; then
            echo "  (E)dit — write + open in \$EDITOR to resolve now"
        fi
        echo "  (R)eplace with new default + create .bak"
        echo "  (K)eep your version (no changes)"
        echo "  (S)kip (decide later)"
        echo ""

        local choice
        if (exec < /dev/tty) 2>/dev/null; then
            if $has_editor; then
                read -rp "  Choice [M/e/r/k/s]: " choice < /dev/tty
            else
                read -rp "  Choice [M/r/k/s]: " choice < /dev/tty
            fi
        else
            choice=""
        fi
        choice="${choice:-M}"
        choice="$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')"

        case "$choice" in
            m|e)
                # Write merged file with conflict markers
                _LAST_RESOLVE_SKIPPED=false
                if [[ "$no_backup" != "true" ]]; then
                    cp "$installed_dir/$rel_path" "$installed_dir/${rel_path}.bak"
                fi
                cp "$merge_out" "$installed_dir/$rel_path"

                # If edit mode and editor available, open it
                if [[ "$choice" == "e" ]] && $has_editor; then
                    "$EDITOR" "$installed_dir/$rel_path" < /dev/tty
                fi

                # Check if conflict markers were resolved
                # Either way, .cco/base is updated (user dealt with the merge).
                # cco start blocks if markers remain — that's the safety net.
                if grep -q '<<<<<<<' "$installed_dir/$rel_path" 2>/dev/null; then
                    warn "  ⚠ $rel_path written with conflict markers"
                    info "    Resolve markers manually. 'cco start' will block until resolved."
                    info "    Your original is saved as ${rel_path}.bak"
                else
                    ok "  ✓ $rel_path (conflicts resolved)"
                fi
                ;;
            r)
                _LAST_RESOLVE_SKIPPED=false
                if [[ "$no_backup" != "true" ]]; then
                    cp "$installed_dir/$rel_path" "$installed_dir/${rel_path}.bak"
                    warn "  ↻ $rel_path (replaced, backup → ${rel_path}.bak)"
                else
                    warn "  ↻ $rel_path (replaced)"
                fi
                cp "$defaults_dir/$rel_path" "$installed_dir/$rel_path"
                ;;
            k)
                _LAST_RESOLVE_SKIPPED=false
                info "  Kept user version of $rel_path"
                ;;
            s)
                _LAST_RESOLVE_SKIPPED=true
                info "  Skipped $rel_path (will be flagged again next run)"
                ;;
            *)
                _LAST_RESOLVE_SKIPPED=false
                info "  Kept user version of $rel_path"
                ;;
        esac
        rm -f "$merge_out"
    else
        # Merge error — fall back to interactive
        rm -f "$merge_out"
        _resolve_conflict_interactive "$rel_path" "$defaults_dir" "$installed_dir" "$no_backup" "$project_dir"
    fi
}

# Fallback interactive conflict resolution (no base available for merge)
_resolve_conflict_interactive() {
    local rel_path="$1"
    local defaults_dir="$2"
    local installed_dir="$3"
    local no_backup="$4"
    local project_dir="${5:-}"  # project root dir (empty for global scope)

    echo ""
    warn "Conflict: $rel_path"
    echo "  Your version differs from the new defaults."
    echo "  No base version available for 3-way merge."
    echo ""
    echo "  (K)eep your version"
    echo "  (R)eplace with new default + create .bak"
    echo "  (S)kip (decide later)"
    echo ""

    local choice
    if (exec < /dev/tty) 2>/dev/null; then
        read -rp "  Choice [K/r/s]: " choice < /dev/tty
    else
        choice=""
    fi
    choice="${choice:-K}"
    choice="$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')"

    case "$choice" in
        r)
            if [[ "$no_backup" != "true" ]]; then
                cp "$installed_dir/$rel_path" "$installed_dir/${rel_path}.bak"
                warn "  ↻ $rel_path (replaced, backup → ${rel_path}.bak)"
            else
                warn "  ↻ $rel_path (replaced)"
            fi
            cp "$defaults_dir/$rel_path" "$installed_dir/$rel_path"
            local h; h=$(_hash_for_scope "$defaults_dir/$rel_path" "$project_dir")
            _UPDATE_MANIFEST_ENTRIES+="${rel_path}	${h}"$'\n'
            ;;
        s)
            # Save default hash so: if default changes again → new CONFLICT,
            # if default stays same → USER_MODIFIED (skipped silently)
            info "  Skipped $rel_path (will be flagged if defaults change again)"
            local h; h=$(_hash_for_scope "$defaults_dir/$rel_path" "$project_dir")
            _UPDATE_MANIFEST_ENTRIES+="${rel_path}	${h}"$'\n'
            ;;
        *)
            # Save default hash so next run sees manifest==default → NO_UPDATE
            info "  Kept user version of $rel_path"
            local h; h=$(_hash_for_scope "$defaults_dir/$rel_path" "$project_dir")
            _UPDATE_MANIFEST_ENTRIES+="${rel_path}	${h}"$'\n'
            ;;
    esac
}

# ── Language Regeneration ────────────────────────────────────────────

# Regenerate language.md from template with saved language choices
_regenerate_language_md() {
    local installed_dir="$1"
    local comm_lang="$2"
    local docs_lang="$3"
    local code_lang="$4"
    local template="$DEFAULTS_DIR/global/.claude/rules/language.md"
    local target="$installed_dir/rules/language.md"

    [[ ! -f "$template" ]] && return 0

    mkdir -p "$(dirname "$target")"
    cp "$template" "$target"
    _sed_i "$target" "{{COMM_LANG}}" "$comm_lang"
    _sed_i "$target" "{{DOCS_LANG}}" "$docs_lang"
    _sed_i "$target" "{{CODE_LANG}}" "$code_lang"
}

# Extract language values from an existing language.md file (fallback if no .cco/meta)
_detect_languages_from_file() {
    local lang_file="$1"
    [[ ! -f "$lang_file" ]] && return 0
    # Parse "communicate in <LANG>" pattern
    local comm docs code
    comm=$(awk '/communicate in/ {print $NF}' "$lang_file" | head -1)
    docs=$(awk '/documentation.*in/ {print $NF}' "$lang_file" | head -1)
    code=$(awk '/code comments.*in/ {print $NF}' "$lang_file" | head -1)
    printf '%s\n%s\n%s\n' "${comm:-English}" "${docs:-English}" "${code:-English}"
}
