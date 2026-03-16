#!/usr/bin/env bash
# lib/update.sh — Update engine: 3-way merge, manifest I/O, migration runner
#
# Provides: _file_hash(), _read_cco_meta(), _read_manifest(), _read_languages(),
#           _generate_cco_meta(), _latest_schema_version(), _run_migrations(),
#           _collect_file_changes(),
#           _save_base_versions(), _merge_file(),
#           _show_file_diffs(), _interactive_apply(),
#           _read_changelog_entries(), _show_changelog_summary(),
#           _show_changelog_details(), _show_changelog_news(),
#           _update_changelog_notifications(),
#           _max_changelog_id(), _latest_changelog_id(),
#           _update_last_seen_changelog(),
#           _update_global(), _update_project()
# Dependencies: colors.sh, utils.sh
# Globals: GLOBAL_DIR, DEFAULTS_DIR, NATIVE_TEMPLATES_DIR, REPO_ROOT

# ── File Policies ─────────────────────────────────────────────────────
# Declarative classification of all managed files.
# Policies:
#   tracked    — 3-way merge on update (user customizations preserved)
#   user-owned — never touched after initial copy
#   generated  — regenerated from template + saved values (e.g., language.md)

GLOBAL_FILE_POLICIES=(
    ".claude/CLAUDE.md:tracked"
    ".claude/settings.json:tracked"
    ".claude/mcp.json:user-owned"
    ".claude/agents/analyst.md:tracked"
    ".claude/agents/reviewer.md:tracked"
    ".claude/rules/diagrams.md:tracked"
    ".claude/rules/git-practices.md:tracked"
    ".claude/rules/workflow.md:tracked"
    ".claude/rules/language.md:generated"
    ".claude/skills/analyze/SKILL.md:tracked"
    ".claude/skills/review/SKILL.md:tracked"
    ".claude/skills/design/SKILL.md:tracked"
    ".claude/skills/commit/SKILL.md:tracked"
    "setup.sh:user-owned"
    "setup-build.sh:user-owned"
)

# Note: only .claude/ files are tracked here. Root files (project.yml, setup.sh,
# secrets.env, mcp-packages.txt) are handled by PROJECT_ROOT_COPY_IF_MISSING —
# they are copied once if missing but never overwritten by the update system.
PROJECT_FILE_POLICIES=(
    ".claude/CLAUDE.md:user-owned"
    ".claude/settings.json:tracked"
    ".claude/rules/language.md:user-owned"
)

# Derived lists for _collect_file_changes().
# Global scope: _collect_file_changes operates on files relative to .claude/,
# so we strip the ".claude/" prefix from policy paths inside .claude/.
# Root files (setup.sh, etc.) are outside the scan scope — handled separately.
GLOBAL_USER_FILES=()
GLOBAL_SPECIAL_FILES=()
PROJECT_USER_FILES=()
for _p in "${GLOBAL_FILE_POLICIES[@]}"; do
    _rel="${_p%:*}"
    _pol="${_p##*:}"
    # Strip .claude/ prefix for files inside .claude/
    _rel="${_rel#.claude/}"
    case "$_pol" in
        user-owned) GLOBAL_USER_FILES+=("$_rel") ;;
        generated)  GLOBAL_SPECIAL_FILES+=("$_rel") ;;
    esac
done
for _p in "${PROJECT_FILE_POLICIES[@]}"; do
    _rel="${_p%:*}"
    _rel="${_rel#.claude/}"
    [[ "${_p##*:}" == "user-owned" ]] && PROJECT_USER_FILES+=("$_rel")
done
unset _p _rel _pol

# Root files: copied from defaults if missing, never overwritten.
# Checked AFTER migrations run, so migration 005 can create setup-build.sh
# with migrated content before the copy-if-missing fallback kicks in.
GLOBAL_ROOT_COPY_IF_MISSING=("setup.sh" "setup-build.sh")
# Project root files: copied from template if missing, never overwritten
PROJECT_ROOT_COPY_IF_MISSING=("setup.sh" "secrets.env" "mcp-packages.txt")

# ── Hashing ──────────────────────────────────────────────────────────

# Compute sha256 hash of a file. Returns empty string if file doesn't exist.
_file_hash() {
    local file="$1"
    [[ ! -f "$file" ]] && return 0
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    else
        shasum -a 256 "$file" | awk '{print $1}'
    fi
}

# ── Base Version Storage (.cco/base/) ─────────────────────────────────

# Save a file to .cco/base/ (the framework version at install/update time).
# Used as the "ancestor" in 3-way merge.
_save_base_version() {
    local base_dir="$1"  # .cco/base/ directory
    local rel_path="$2"  # relative path (e.g., CLAUDE.md or project.yml)
    local source="$3"    # source file to copy

    mkdir -p "$(dirname "$base_dir/$rel_path")"
    cp "$source" "$base_dir/$rel_path"
}

# Save base versions for all tracked files in a scope.
# Called at cco init and after successful cco update.
_save_all_base_versions() {
    local base_dir="$1"       # .cco/base/ directory
    local defaults_dir="$2"   # defaults source directory (already scoped to .claude/ for global)
    local scope="$3"          # "global" or "project"

    local policies_ref
    if [[ "$scope" == "global" ]]; then
        policies_ref=("${GLOBAL_FILE_POLICIES[@]}")
    else
        policies_ref=("${PROJECT_FILE_POLICIES[@]}")
    fi

    local entry rel policy
    for entry in "${policies_ref[@]}"; do
        rel="${entry%:*}"
        policy="${entry##*:}"
        [[ "$policy" != "tracked" ]] && continue
        # Strip .claude/ prefix — defaults_dir is already scoped to .claude/ content
        rel="${rel#.claude/}"
        if [[ -f "$defaults_dir/$rel" ]]; then
            _save_base_version "$base_dir" "$rel" "$defaults_dir/$rel"
        fi
    done
}

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

# ── Portable sed -i ──────────────────────────────────────────────────

_sed_i() {
    local file="$1" pattern="$2" replacement="$3"
    sed -i '' "s|${pattern}|${replacement}|g" "$file" 2>/dev/null || \
        sed -i "s|${pattern}|${replacement}|g" "$file"
}

# Update a key: value field in-place, or append it if missing.
# Usage: _sed_i_or_append <file> <key> <value>
_sed_i_or_append() {
    local file="$1" key="$2" value="$3"
    if grep -q "^${key}:" "$file" 2>/dev/null; then
        _sed_i "$file" "^${key}: .*" "${key}: ${value}"
    else
        printf '%s: %s\n' "$key" "$value" >> "$file"
    fi
}

# ── .cco/meta I/O ────────────────────────────────────────────────────

# Read schema_version from .cco/meta. Returns 0 if file missing.
_read_cco_meta() {
    local meta_file="$1"
    [[ ! -f "$meta_file" ]] && echo "0" && return 0
    awk '/^schema_version:/ {print $2}' "$meta_file"
}

# Read last_seen_changelog from .cco/meta. Returns 0 if file missing or field absent.
_read_last_seen_changelog() {
    local meta_file="$1"
    [[ ! -f "$meta_file" ]] && echo "0" && return 0
    local val
    val=$(awk '/^last_seen_changelog:/ {print $2}' "$meta_file")
    echo "${val:-0}"
}

# Read last_read_changelog from .cco/meta. Returns 0 if file missing or field absent.
_read_last_read_changelog() {
    local meta_file="$1"
    [[ ! -f "$meta_file" ]] && echo "0" && return 0
    local val
    val=$(awk '/^last_read_changelog:/ {print $2}' "$meta_file")
    echo "${val:-0}"
}

# Read manifest entries from .cco/meta. Output: "path\thash" per line.
_read_manifest() {
    local meta_file="$1"
    [[ ! -f "$meta_file" ]] && return 0
    awk '
        /^manifest:/ { in_manifest=1; next }
        /^[a-z]/ { in_manifest=0 }
        in_manifest && /^  [^ ]/ {
            gsub(/^  /, "")
            split($0, parts, ": ")
            printf "%s\t%s\n", parts[1], parts[2]
        }
    ' "$meta_file"
}

# Read languages from .cco/meta. Output: three lines (communication, documentation, code_comments).
_read_languages() {
    local meta_file="$1"
    [[ ! -f "$meta_file" ]] && return 0
    awk '
        /^languages:/ { in_lang=1; next }
        /^[a-z]/ && !/^  / { in_lang=0 }
        in_lang && /communication:/ { gsub(/.*: /, ""); print }
        in_lang && /documentation:/ { gsub(/.*: /, ""); print }
        in_lang && /code_comments:/ { gsub(/.*: /, ""); print }
    ' "$meta_file"
}

# Generate a complete .cco/meta file. Manifest entries read from stdin as "path\thash" lines.
_generate_cco_meta() {
    local meta_file="$1"
    local schema="$2"
    local created="$3"
    local comm_lang="$4"
    local docs_lang="$5"
    local code_lang="$6"
    local last_seen_changelog="${7:-0}"
    local last_read_changelog="${8:-0}"

    {
        printf '# Auto-generated by cco — do not edit\n'
        printf 'schema_version: %d\n' "$schema"
        printf 'created_at: %s\n' "$created"
        printf 'updated_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '\nlast_seen_changelog: %d\n' "$last_seen_changelog"
        printf 'last_read_changelog: %d\n' "$last_read_changelog"
        printf '\nlanguages:\n'
        printf '  communication: %s\n' "$comm_lang"
        printf '  documentation: %s\n' "$docs_lang"
        printf '  code_comments: %s\n' "$code_lang"
        printf '\nmanifest:\n'
        while IFS=$'\t' read -r path hash; do
            [[ -z "$path" ]] && continue
            printf '  %s: %s\n' "$path" "$hash"
        done
    } > "$meta_file"
}

# Generate a project-scope .cco/meta file. No languages, no changelog.
# Manifest entries read from stdin as "path\thash" lines.
_generate_project_cco_meta() {
    local meta_file="$1"
    local schema="$2"
    local created="$3"
    local template="${4:-base}"

    {
        printf '# Auto-generated by cco — do not edit\n'
        printf 'schema_version: %d\n' "$schema"
        printf 'created_at: %s\n' "$created"
        printf 'updated_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '\ntemplate: %s\n' "$template"
        printf '\nmanifest:\n'
        while IFS=$'\t' read -r path hash; do
            [[ -z "$path" ]] && continue
            printf '  %s: %s\n' "$path" "$hash"
        done
    } > "$meta_file"
}

# ── Migration Engine ─────────────────────────────────────────────────

# Scan migrations directory, return the highest MIGRATION_ID found.
_latest_schema_version() {
    local scope="$1"
    local migrations_dir="$REPO_ROOT/migrations/$scope"
    local max_id=0

    [[ ! -d "$migrations_dir" ]] && echo "0" && return 0

    local migration_file
    for migration_file in "$migrations_dir"/*.sh; do
        [[ ! -f "$migration_file" ]] && continue
        local mid
        mid=$(awk '/^MIGRATION_ID=/ {split($0,a,"="); print a[2]}' "$migration_file")
        [[ -n "$mid" && "$mid" -gt "$max_id" ]] && max_id="$mid"
    done

    echo "$max_id"
}

# Run pending migrations for a scope. Returns 0 on success, 1 on failure.
_run_migrations() {
    local scope="$1"
    local target_dir="$2"
    local current_version="$3"
    local meta_file="${4:-}"
    local migrations_dir="$REPO_ROOT/migrations/$scope"
    local ran=0

    [[ ! -d "$migrations_dir" ]] && return 0

    local migration_file
    for migration_file in "$migrations_dir"/*.sh; do
        [[ ! -f "$migration_file" ]] && continue

        # Source in a subshell-safe way: read MIGRATION_ID and MIGRATION_DESC
        local mid mdesc
        mid=$(awk '/^MIGRATION_ID=/ {split($0,a,"="); print a[2]}' "$migration_file")
        mdesc=$(awk -F'"' '/^MIGRATION_DESC=/ {print $2}' "$migration_file")

        [[ -z "$mid" ]] && continue
        [[ "$mid" -le "$current_version" ]] && continue

        info "Running migration $mid: $mdesc"

        # Source the file to get migrate() function, then call it
        local exit_code=0
        (
            # shellcheck source=/dev/null
            source "$migration_file"
            migrate "$target_dir"
        ) || exit_code=$?

        if [[ $exit_code -ne 0 ]]; then
            error "Migration $mid failed (exit code $exit_code)"
            return 1
        fi

        ok "Migration $mid completed"
        ran=$(( ran + 1 ))

        # Update schema_version in meta file if provided
        if [[ -n "$meta_file" && -f "$meta_file" ]]; then
            _sed_i "$meta_file" "^schema_version: .*" "schema_version: $mid"
        fi
    done

    [[ $ran -gt 0 ]] && ok "Ran $ran migration(s)"
    return 0
}

# ── File Change Detection ────────────────────────────────────────────

# Check if a path is in a bash array (passed as remaining args)
_in_array() {
    local needle="$1"; shift
    local item
    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

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
            # Skip user-owned and special files
            if [[ "$scope" == "global" ]]; then
                if _in_array "$rel" "${GLOBAL_USER_FILES[@]}"; then
                    continue
                fi
                # Special files (language.md) are regenerated separately
                if _in_array "$rel" "${GLOBAL_SPECIAL_FILES[@]}"; then
                    continue
                fi
            elif [[ "$scope" == "project" ]]; then
                if _in_array "$rel" "${PROJECT_USER_FILES[@]}"; then
                    continue
                fi
            fi
            default_files+=("$rel")
        done < <(find "$defaults_dir" -type f | sort)
    fi

    # Track which base files we've seen (for REMOVED detection)
    local seen_base_files=""

    # For each default file, classify using the 3-version algorithm
    local rel
    for rel in ${default_files[@]+"${default_files[@]}"}; do
        local new_hash installed_hash base_hash

        new_hash=$(_file_hash "$defaults_dir/$rel")
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
            # Both user and framework have changed
            printf 'MERGE_AVAILABLE\t%s\n' "$rel"
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
            # Skip user-owned files
            if [[ "$scope" == "global" ]] && _in_array "$rel" "${GLOBAL_USER_FILES[@]}"; then
                continue
            fi
            if [[ "$scope" == "project" ]] && _in_array "$rel" "${PROJECT_USER_FILES[@]}"; then
                continue
            fi
            printf 'REMOVED\t%s\n' "$rel"
        done < <(find "$base_dir" -type f | sort)
    fi
}

# ── File Change Application ──────────────────────────────────────────

# Apply collected file changes with 3-way merge support.
# Reads "STATUS\tpath" lines from first argument (string).
# Returns updated manifest entries via _UPDATE_MANIFEST_ENTRIES (newline-separated "path\thash").
_UPDATE_MANIFEST_ENTRIES=""
_LAST_RESOLVE_AUTOMERGE=false  # set by _resolve_with_merge for counter tracking
_LAST_RESOLVE_SKIPPED=false    # set by _resolve_with_merge when user chooses skip inside conflict

## _apply_file_changes — REMOVED (replaced by _interactive_apply in Sprint 3+4)

# Resolve a conflict using 3-way merge, falling back to interactive prompt
_resolve_with_merge() {
    local rel_path="$1"
    local defaults_dir="$2"
    local installed_dir="$3"
    local base_dir="$4"
    local no_backup="$5"
    local base_file="$base_dir/$rel_path"

    # If no base version available, fall back to interactive (no merge possible)
    if [[ ! -f "$base_file" ]]; then
        _resolve_conflict_interactive "$rel_path" "$defaults_dir" "$installed_dir" "$no_backup"
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
        _resolve_conflict_interactive "$rel_path" "$defaults_dir" "$installed_dir" "$no_backup"
    fi
}

# Fallback interactive conflict resolution (no base available for merge)
_resolve_conflict_interactive() {
    local rel_path="$1"
    local defaults_dir="$2"
    local installed_dir="$3"
    local no_backup="$4"

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
            local h; h=$(_file_hash "$defaults_dir/$rel_path")
            _UPDATE_MANIFEST_ENTRIES+="${rel_path}	${h}"$'\n'
            ;;
        s)
            # Save default hash so: if default changes again → new CONFLICT,
            # if default stays same → USER_MODIFIED (skipped silently)
            info "  Skipped $rel_path (will be flagged if defaults change again)"
            local h; h=$(_file_hash "$defaults_dir/$rel_path")
            _UPDATE_MANIFEST_ENTRIES+="${rel_path}	${h}"$'\n'
            ;;
        *)
            # Save default hash so next run sees manifest==default → NO_UPDATE
            info "  Kept user version of $rel_path"
            local h; h=$(_file_hash "$defaults_dir/$rel_path")
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

# ── Discovery Summary ─────────────────────────────────────────────────

# Show a concise read-only summary of discovered changes.
# Input: newline-separated "STATUS\tpath" lines (from _collect_file_changes).
# Only shows output if there are actionable changes. Silent if everything is NO_UPDATE.
_show_discovery_summary() {
    local changes="$1"
    local scope_label="$2"  # e.g., "Global" or "Project 'myapp'"

    [[ -z "$changes" ]] && return 0

    local update_count=0 merge_count=0 new_count=0 removed_count=0 base_missing_count=0 deleted_updated_count=0

    while IFS=$'\t' read -r status rel_path; do
        [[ -z "$status" ]] && continue
        case "$status" in
            UPDATE_AVAILABLE|SAFE_UPDATE) update_count=$(( update_count + 1 )) ;;
            MERGE_AVAILABLE|CONFLICT)     merge_count=$(( merge_count + 1 )) ;;
            NEW)                          new_count=$(( new_count + 1 )) ;;
            REMOVED)                      removed_count=$(( removed_count + 1 )) ;;
            BASE_MISSING)                 base_missing_count=$(( base_missing_count + 1 )) ;;
            DELETED_UPDATED)              deleted_updated_count=$(( deleted_updated_count + 1 )) ;;
        esac
    done <<< "$changes"

    local total=$(( update_count + merge_count + new_count + removed_count + base_missing_count + deleted_updated_count ))
    [[ $total -eq 0 ]] && return 0

    echo ""
    info "$scope_label: opinionated updates available:"
    [[ $update_count -gt 0 ]] && info "  $update_count file(s) can be auto-applied (UPDATE_AVAILABLE)"
    [[ $merge_count -gt 0 ]] && info "  $merge_count file(s) need merge (MERGE_AVAILABLE)"
    [[ $new_count -gt 0 ]] && info "  $new_count new file(s) available (NEW)"
    [[ $removed_count -gt 0 ]] && info "  $removed_count file(s) removed from defaults (REMOVED)"
    [[ $base_missing_count -gt 0 ]] && info "  $base_missing_count file(s) with missing base (BASE_MISSING)"
    [[ $deleted_updated_count -gt 0 ]] && info "  $deleted_updated_count file(s) you deleted have framework updates (DELETED_UPDATED)"
    echo ""
    info "Run 'cco update --diff' for details, 'cco update --sync' to merge."
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

    while IFS=$'\t' read -r status rel_path; do
        [[ -z "$status" ]] && continue

        case "$status" in
            NEW)
                echo ""
                info "$scope_label: $rel_path (new framework file)"
                echo "  --- /dev/null"
                echo "  +++ $rel_path"
                if [[ -f "$defaults_dir/$rel_path" ]]; then
                    sed 's/^/  + /' "$defaults_dir/$rel_path"
                fi
                shown=$(( shown + 1 ))
                ;;
            UPDATE_AVAILABLE|SAFE_UPDATE)
                echo ""
                info "$scope_label: $rel_path (framework updated, you haven't modified)"
                if command -v diff >/dev/null 2>&1; then
                    diff -u "$installed_dir/$rel_path" "$defaults_dir/$rel_path" \
                        --label "your version" --label "new default" 2>/dev/null | sed 's/^/  /' || true
                fi
                shown=$(( shown + 1 ))
                ;;
            BASE_MISSING)
                echo ""
                info "$scope_label: $rel_path (update available, base missing)"
                if command -v diff >/dev/null 2>&1; then
                    diff -u "$installed_dir/$rel_path" "$defaults_dir/$rel_path" \
                        --label "your version" --label "new default" 2>/dev/null | sed 's/^/  /' || true
                fi
                shown=$(( shown + 1 ))
                ;;
            MERGE_AVAILABLE|CONFLICT)
                echo ""
                info "$scope_label: $rel_path (both modified — merge needed)"
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
                    diff -u "$base_dir/$rel_path" "$defaults_dir/$rel_path" \
                        --label "version when deleted" --label "new default" 2>/dev/null | sed 's/^/  /' || true
                fi
                shown=$(( shown + 1 ))
                ;;
        esac
    done <<< "$changes"

    [[ $shown -eq 0 ]] && return 0
    echo ""
    info "$scope_label: $shown file(s) with available changes."
    info "Run 'cco update --sync' to interactively apply."
}

# ── Interactive Apply ─────────────────────────────────────────────────

# Interactive per-file apply with user prompts.
# Called only in --sync mode.
_interactive_apply() {
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

            UPDATE_AVAILABLE|SAFE_UPDATE|BASE_MISSING)
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

            MERGE_AVAILABLE|CONFLICT)
                local choice="$auto_action"
                if [[ -z "$choice" ]]; then
                    echo ""
                    info "$scope_label: $rel_path (both modified — merge needed)"
                    echo "  (M)erge 3-way  (R)eplace + .bak  (K)eep yours  (S)kip  (D)iff"
                    if (exec < /dev/tty) 2>/dev/null; then
                        read -rp "  Choice [M/r/k/s/d]: " choice < /dev/tty
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
                            read -rp "  (M)erge 3-way  (R)eplace + .bak  (K)eep yours  (S)kip [M/r/k/s]: " choice < /dev/tty
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

# ── Orchestration ────────────────────────────────────────────────────

# Update global config
_update_global() {
    local cmd_mode="$1"       # discovery | diff | sync | news
    local dry_run="$2"
    local no_backup="${3:-false}"
    local auto_action="${4:-}"  # "" | replace | keep | skip
    local meta_file
    meta_file=$(_cco_global_meta)
    local installed_dir="$GLOBAL_DIR/.claude"
    local defaults_dir="$DEFAULTS_DIR/global/.claude"
    local base_dir
    base_dir=$(_cco_global_base_dir)

    # Read current state
    local current_schema
    current_schema=$(_read_cco_meta "$meta_file")
    local latest_schema
    latest_schema=$(_latest_schema_version "global")

    # Read or detect languages
    local comm_lang docs_lang code_lang
    if [[ -f "$meta_file" ]]; then
        local lang_lines
        lang_lines=$(_read_languages "$meta_file")
        comm_lang=$(echo "$lang_lines" | sed -n '1p')
        docs_lang=$(echo "$lang_lines" | sed -n '2p')
        code_lang=$(echo "$lang_lines" | sed -n '3p')
    else
        # Fallback: detect from existing language.md
        local detected
        detected=$(_detect_languages_from_file "$installed_dir/rules/language.md")
        comm_lang=$(echo "$detected" | sed -n '1p')
        docs_lang=$(echo "$detected" | sed -n '2p')
        code_lang=$(echo "$detected" | sed -n '3p')
    fi
    comm_lang="${comm_lang:-English}"
    docs_lang="${docs_lang:-English}"
    code_lang="${code_lang:-English}"

    # Regenerate language.md from saved choices before comparing (only in sync mode)
    if [[ "$cmd_mode" == "sync" && "$dry_run" != "true" ]]; then
        _regenerate_language_md "$installed_dir" "$comm_lang" "$docs_lang" "$code_lang"
    fi

    # Phase 1: Run migrations (always, unless --dry-run or --news)
    local pending_migrations=$(( latest_schema - current_schema ))
    [[ $pending_migrations -lt 0 ]] && pending_migrations=0
    local vault_synced_pre_migration=false

    if [[ $pending_migrations -gt 0 && "$cmd_mode" != "news" ]]; then
        if [[ "$dry_run" == "true" ]]; then
            info "$pending_migrations global migration(s) pending"
        else
            # Vault pre-migration snapshot (prompt before any file modifications)
            if [[ -d "$USER_CONFIG_DIR/.git" ]]; then
                local do_vault="y"
                if (exec < /dev/tty) 2>/dev/null; then
                    read -rp "  Vault detected. Commit current state before running $pending_migrations migration(s)? [Y/n] " do_vault < /dev/tty
                    do_vault="${do_vault:-y}"
                fi
                if [[ "$do_vault" =~ ^[Yy] ]]; then
                    cmd_vault_sync "pre-migration snapshot" </dev/tty >/dev/tty 2>/dev/tty || warn "Vault snapshot failed, continuing..."
                    vault_synced_pre_migration=true
                fi
            fi

            if ! _run_migrations "global" "$installed_dir" "$current_schema" "$meta_file"; then
                error "Global migrations failed. Run 'cco update' again after resolving the issue."
                return 1
            fi

            # Refresh paths if migration moved the directory (e.g. 003_user-config-dir)
            if [[ ! -d "$installed_dir" && -d "$USER_CONFIG_DIR/global/.claude" ]]; then
                GLOBAL_DIR="$USER_CONFIG_DIR/global"
                PROJECTS_DIR="$USER_CONFIG_DIR/projects"
                PACKS_DIR="$USER_CONFIG_DIR/packs"
                TEMPLATES_DIR="$USER_CONFIG_DIR/templates"
                installed_dir="$GLOBAL_DIR/.claude"
                meta_file=$(_cco_global_meta)
                base_dir=$(_cco_global_base_dir)
            fi
        fi
    fi

    # --news mode: only changelog (handled by caller), skip discovery
    [[ "$cmd_mode" == "news" ]] && return 0

    # Phase 2: COLLECT — detect file changes
    local changes
    changes=$(_collect_file_changes "$defaults_dir" "$installed_dir" "$base_dir" "global")

    # Count actionable changes
    local actionable
    actionable=$(echo "$changes" | grep -cvE '^(NO_UPDATE|USER_MODIFIED|$)' || true)

    # Check for missing global root files (setup.sh)
    local global_defaults_root="$DEFAULTS_DIR/global"
    local root_missing=()
    local rf
    for rf in "${GLOBAL_ROOT_COPY_IF_MISSING[@]}"; do
        if [[ -f "$global_defaults_root/$rf" && ! -f "$GLOBAL_DIR/$rf" ]]; then
            root_missing+=("$rf")
        fi
    done

    if [[ $actionable -eq 0 && $pending_migrations -eq 0 && ${#root_missing[@]} -eq 0 ]]; then
        ok "Global config is up to date."
        return 0
    fi

    # Phase 3: Route based on cmd_mode
    case "$cmd_mode" in
        discovery)
            _show_discovery_summary "$changes" "Global"
            ;;
        diff)
            _show_file_diffs "$changes" "$defaults_dir" "$installed_dir" "$base_dir" "Global"
            ;;
        sync)
            # Vault pre-update snapshot (optional, skip if already done pre-migration)
            if [[ "$dry_run" != "true" && -z "$auto_action" && "$vault_synced_pre_migration" != "true" ]]; then
                if [[ -d "$USER_CONFIG_DIR/.git" ]]; then
                    local do_vault="y"
                    if (exec < /dev/tty) 2>/dev/null; then
                        read -rp "  Vault detected. Commit current state before updating? [Y/n] " do_vault < /dev/tty
                        do_vault="${do_vault:-y}"
                    fi
                    if [[ "$do_vault" =~ ^[Yy] ]]; then
                        cmd_vault_sync "pre-update snapshot" </dev/tty >/dev/tty 2>/dev/tty || warn "Vault snapshot failed, continuing..."
                        [[ "$no_backup" != "true" ]] && info "Vault snapshot created. You can use --no-backup to skip .bak files."
                    fi
                fi
            fi

            if [[ "$dry_run" == "true" ]]; then
                # In dry-run + sync, show what would be available
                _show_discovery_summary "$changes" "Global"
            else
                _interactive_apply "$changes" "$defaults_dir" "$installed_dir" "$base_dir" "$no_backup" "$auto_action" "Global"
            fi
            ;;
    esac

    # Copy missing root files from defaults (after migrations)
    # Re-check what's actually missing now (migrations may have created files)
    root_missing=()
    for rf in "${GLOBAL_ROOT_COPY_IF_MISSING[@]}"; do
        if [[ -f "$global_defaults_root/$rf" && ! -f "$GLOBAL_DIR/$rf" ]]; then
            root_missing+=("$rf")
        fi
    done
    if [[ ${#root_missing[@]} -gt 0 ]]; then
        for rf in "${root_missing[@]}"; do
            if [[ "$dry_run" == "true" ]]; then
                info "  + $rf (missing, will copy from defaults)"
            else
                cp "$global_defaults_root/$rf" "$GLOBAL_DIR/$rf"
                ok "  + $rf (copied from defaults)"
            fi
        done
    fi

    # Update .cco/meta (only in sync mode or after migrations)
    if [[ "$dry_run" != "true" ]]; then
        local created
        if [[ -f "$meta_file" ]]; then
            created=$(awk '/^created_at:/ {print $2}' "$meta_file")
        fi
        created="${created:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

        # Ensure .cco/ parent directory exists for writing
        mkdir -p "$(dirname "$meta_file")"

        local new_schema="$latest_schema"

        # Add special files (language.md) to manifest entries
        local special_entries=""
        local sf
        for sf in "${GLOBAL_SPECIAL_FILES[@]}"; do
            if [[ -f "$installed_dir/$sf" ]]; then
                local sh; sh=$(_file_hash "$installed_dir/$sf")
                special_entries+="${sf}	${sh}"$'\n'
            fi
        done

        # Preserve changelog trackers from existing meta
        local last_seen last_read
        last_seen=$(_read_last_seen_changelog "$meta_file")
        last_read=$(_read_last_read_changelog "$meta_file")

        if [[ "$cmd_mode" == "sync" ]]; then
            # Use manifest entries from _interactive_apply
            {
                echo "$_UPDATE_MANIFEST_ENTRIES"
                echo "$special_entries"
            } | _generate_cco_meta \
                "$meta_file" "$new_schema" "$created" \
                "$comm_lang" "$docs_lang" "$code_lang" "$last_seen" "$last_read"

            # Note: .cco/base/ is saved per-file inside _interactive_apply
            # (only for Apply/Keep/Merge/Replace, not Skip)
        else
            # Discovery/diff mode: only update schema_version (from migrations)
            if [[ $pending_migrations -gt 0 ]]; then
                # Rebuild manifest from current installed files
                local current_manifest=""
                local entry rel policy
                for entry in "${GLOBAL_FILE_POLICIES[@]}"; do
                    rel="${entry%:*}"
                    policy="${entry##*:}"
                    [[ "$policy" == "user-owned" ]] && continue
                    rel="${rel#.claude/}"
                    if [[ -f "$installed_dir/$rel" ]]; then
                        local h; h=$(_file_hash "$installed_dir/$rel")
                        current_manifest+="${rel}	${h}"$'\n'
                    fi
                done
                {
                    echo "$current_manifest"
                    echo "$special_entries"
                } | _generate_cco_meta \
                    "$meta_file" "$new_schema" "$created" \
                    "$comm_lang" "$docs_lang" "$code_lang" "$last_seen" "$last_read"
            fi
        fi
    fi
}

# Resolve the defaults directory for a project based on .cco/source.
# Returns the path to the .claude/ directory in the template source.
_resolve_project_defaults_dir() {
    local project_dir="$1"
    local source_file
    source_file=$(_cco_pack_source "$project_dir")
    local fallback="$NATIVE_TEMPLATES_DIR/project/base/.claude"

    if [[ ! -f "$source_file" ]]; then
        echo "$fallback"
        return 0
    fi

    local source_line
    source_line=$(head -1 "$source_file")

    case "$source_line" in
        native:project/*)
            local tmpl_name="${source_line#native:project/}"
            local tmpl_dir="$NATIVE_TEMPLATES_DIR/project/$tmpl_name/.claude"
            if [[ -d "$tmpl_dir" ]]; then
                echo "$tmpl_dir"
            else
                warn "Template '$tmpl_name' referenced by project '$(basename "$project_dir")' not found."
                warn "  Falling back to base template for discovery."
                echo "$fallback"
            fi
            ;;
        user:template/*)
            local tmpl_name="${source_line#user:template/}"
            local user_tmpl_dir="$TEMPLATES_DIR/project/$tmpl_name/.claude"
            if [[ -d "$user_tmpl_dir" ]]; then
                echo "$user_tmpl_dir"
            else
                # User template removed — fall back to base
                echo "$fallback"
            fi
            ;;
        http://*|https://*)
            # Remote-installed project: use base template for opinionated files
            echo "$fallback"
            ;;
        *)
            # Unknown format — fall back to base
            echo "$fallback"
            ;;
    esac
}

# Update a project's config
_update_project() {
    local project_dir="$1"
    local cmd_mode="$2"       # discovery | diff | sync | news
    local dry_run="$3"
    local no_backup="${4:-false}"
    local auto_action="${5:-}"  # "" | replace | keep | skip
    local pname
    pname="$(basename "$project_dir")"
    local meta_file
    meta_file=$(_cco_project_meta "$project_dir")
    local installed_dir="$project_dir/.claude"
    local base_dir
    base_dir=$(_cco_project_base_dir "$project_dir")

    # Resolve template source based on .cco/source
    local defaults_dir
    defaults_dir=$(_resolve_project_defaults_dir "$project_dir")

    # Read current state
    local current_schema
    current_schema=$(_read_cco_meta "$meta_file")
    local latest_schema
    latest_schema=$(_latest_schema_version "project")

    # Phase 1: Run migrations (always, unless --dry-run or --news)
    local pending_migrations=$(( latest_schema - current_schema ))
    [[ $pending_migrations -lt 0 ]] && pending_migrations=0

    if [[ $pending_migrations -gt 0 && "$cmd_mode" != "news" ]]; then
        if [[ "$dry_run" == "true" ]]; then
            info "$pending_migrations project migration(s) pending for '$pname'"
        else
            if ! _run_migrations "project" "$project_dir" "$current_schema" "$meta_file"; then
                error "Project '$pname' migrations failed. Run 'cco update --project $pname' again after resolving the issue."
                return 1
            fi
        fi
    fi

    # --news mode: skip discovery for projects
    [[ "$cmd_mode" == "news" ]] && return 0

    # Phase 2: COLLECT — detect file changes
    local changes
    changes=$(_collect_file_changes "$defaults_dir" "$installed_dir" "$base_dir" "project")

    # Count actionable changes
    local actionable
    actionable=$(echo "$changes" | grep -cvE '^(NO_UPDATE|USER_MODIFIED|$)' || true)

    # Check for missing project root files (setup.sh, secrets.env, mcp-packages.txt)
    local template_root="$NATIVE_TEMPLATES_DIR/project/base"
    local root_missing=()
    local rf
    for rf in "${PROJECT_ROOT_COPY_IF_MISSING[@]}"; do
        if [[ -f "$template_root/$rf" && ! -f "$project_dir/$rf" ]]; then
            root_missing+=("$rf")
        fi
    done

    if [[ $actionable -eq 0 && $pending_migrations -eq 0 && ${#root_missing[@]} -eq 0 ]]; then
        ok "Project '$pname' config is up to date."
        return 0
    fi

    local scope_label="Project '$pname'"

    # Phase 3: Route based on cmd_mode
    case "$cmd_mode" in
        discovery)
            _show_discovery_summary "$changes" "$scope_label"
            ;;
        diff)
            _show_file_diffs "$changes" "$defaults_dir" "$installed_dir" "$base_dir" "$scope_label"
            ;;
        sync)
            if [[ "$dry_run" == "true" ]]; then
                _show_discovery_summary "$changes" "$scope_label"
            else
                _interactive_apply "$changes" "$defaults_dir" "$installed_dir" "$base_dir" "$no_backup" "$auto_action" "$scope_label"
            fi
            ;;
    esac

    # Copy missing root files from template
    if [[ ${#root_missing[@]} -gt 0 ]]; then
        for rf in "${root_missing[@]}"; do
            if [[ "$dry_run" == "true" ]]; then
                info "  + $rf (missing, will copy from template)"
            else
                cp "$template_root/$rf" "$project_dir/$rf"
                ok "  + $rf (copied from template)"
            fi
        done
    fi

    # Update .cco/meta (project scope: no languages, no changelog)
    if [[ "$dry_run" != "true" ]]; then
        local created
        if [[ -f "$meta_file" ]]; then
            created=$(awk '/^created_at:/ {print $2}' "$meta_file")
        fi
        created="${created:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

        # Ensure .cco/ parent directory exists for writing
        mkdir -p "$(dirname "$meta_file")"

        local new_schema="$latest_schema"

        # Read template name from existing .cco/meta or .cco/source
        local tmpl_name="base"
        if [[ -f "$meta_file" ]]; then
            local tmpl_val
            tmpl_val=$(awk '/^template:/ {print $2}' "$meta_file")
            [[ -n "$tmpl_val" ]] && tmpl_name="$tmpl_val"
        else
            local source_file
            source_file=$(_cco_pack_source "$project_dir")
            if [[ -f "$source_file" ]]; then
                local src_line
                src_line=$(head -1 "$source_file")
                case "$src_line" in
                    native:project/*) tmpl_name="${src_line#native:project/}" ;;
                    user:template/*)  tmpl_name="${src_line#user:template/}" ;;
                esac
            fi
        fi

        if [[ "$cmd_mode" == "sync" ]]; then
            echo "$_UPDATE_MANIFEST_ENTRIES" | _generate_project_cco_meta \
                "$meta_file" "$new_schema" "$created" "$tmpl_name"

            # Note: .cco/base/ is saved per-file inside _interactive_apply
            # (only for Apply/Keep/Merge/Replace, not Skip)
        else
            # Discovery/diff mode: only update schema_version (from migrations)
            if [[ $pending_migrations -gt 0 ]]; then
                local current_manifest=""
                local entry rel policy
                for entry in "${PROJECT_FILE_POLICIES[@]}"; do
                    rel="${entry%:*}"
                    policy="${entry##*:}"
                    [[ "$policy" == "user-owned" ]] && continue
                    rel="${rel#.claude/}"
                    if [[ -f "$installed_dir/$rel" ]]; then
                        local h; h=$(_file_hash "$installed_dir/$rel")
                        current_manifest+="${rel}	${h}"$'\n'
                    fi
                done
                echo "$current_manifest" | _generate_project_cco_meta \
                    "$meta_file" "$new_schema" "$created" "$tmpl_name"
            fi
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
