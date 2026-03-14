#!/usr/bin/env bash
# lib/update.sh — Update engine: 3-way merge, manifest I/O, migration runner
#
# Provides: _file_hash(), _read_cco_meta(), _read_manifest(), _read_languages(),
#           _generate_cco_meta(), _latest_schema_version(), _run_migrations(),
#           _collect_file_changes(), _apply_file_changes(),
#           _save_base_versions(), _merge_file(),
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

# ── Base Version Storage (.cco-base/) ─────────────────────────────────

# Save a file to .cco-base/ (the framework version at install/update time).
# Used as the "ancestor" in 3-way merge.
_save_base_version() {
    local base_dir="$1"  # .cco-base/ directory
    local rel_path="$2"  # relative path (e.g., CLAUDE.md or project.yml)
    local source="$3"    # source file to copy

    mkdir -p "$(dirname "$base_dir/$rel_path")"
    cp "$source" "$base_dir/$rel_path"
}

# Save base versions for all tracked files in a scope.
# Called at cco init and after successful cco update.
_save_all_base_versions() {
    local base_dir="$1"       # .cco-base/ directory
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
    git merge-file --diff3 \
        -L "your version" -L "previous default" -L "new default" \
        "$tmpdir/current" "$tmpdir/base" "$tmpdir/new" 2>/dev/null
    local exit_code=$?

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

# ── .cco-meta I/O ───────────────────────────────────────────────────

# Read schema_version from .cco-meta. Returns 0 if file missing.
_read_cco_meta() {
    local meta_file="$1"
    [[ ! -f "$meta_file" ]] && echo "0" && return 0
    awk '/^schema_version:/ {print $2}' "$meta_file"
}

# Read last_seen_changelog from .cco-meta. Returns 0 if file missing or field absent.
_read_last_seen_changelog() {
    local meta_file="$1"
    [[ ! -f "$meta_file" ]] && echo "0" && return 0
    local val
    val=$(awk '/^last_seen_changelog:/ {print $2}' "$meta_file")
    echo "${val:-0}"
}

# Read manifest entries from .cco-meta. Output: "path\thash" per line.
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

# Read languages from .cco-meta. Output: three lines (communication, documentation, code_comments).
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

# Generate a complete .cco-meta file. Manifest entries read from stdin as "path\thash" lines.
_generate_cco_meta() {
    local meta_file="$1"
    local schema="$2"
    local created="$3"
    local comm_lang="$4"
    local docs_lang="$5"
    local code_lang="$6"
    local last_seen_changelog="${7:-0}"

    {
        printf '# Auto-generated by cco — do not edit\n'
        printf 'schema_version: %d\n' "$schema"
        printf 'created_at: %s\n' "$created"
        printf 'updated_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '\nlast_seen_changelog: %d\n' "$last_seen_changelog"
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

# Generate a project-scope .cco-meta file. No languages, no changelog.
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
        (
            # shellcheck source=/dev/null
            source "$migration_file"
            migrate "$target_dir"
        )
        local exit_code=$?

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
# Uses .cco-base/ files as the ancestor (base) version.
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
            # File exists in defaults but not in target AND not in .cco-base/
            printf 'NEW\t%s\n' "$rel"

        elif [[ -z "$installed_hash" ]] && [[ -n "$base_hash" ]]; then
            # File was in base but user deleted it — don't re-add
            printf 'NO_UPDATE\t%s\n' "$rel"

        elif [[ -z "$base_hash" ]]; then
            # BASE_MISSING: no .cco-base/ entry for this file
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

    # Detect files in .cco-base/ but no longer in defaults (REMOVED)
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

_apply_file_changes() {
    local changes="$1"
    local defaults_dir="$2"
    local installed_dir="$3"
    local base_dir="$4"     # .cco-base/ directory for 3-way merge
    local mode="$5"         # force|keep|replace|interactive (default)
    local dry_run="$6"
    local no_backup="$7"    # "true" to skip .bak creation

    _UPDATE_MANIFEST_ENTRIES=""
    local updated=0 skipped=0 new_count=0 merged=0 conflicts=0

    while IFS=$'\t' read -r status rel_path; do
        [[ -z "$status" ]] && continue

        case "$status" in
            NEW)
                if [[ "$dry_run" == "true" ]]; then
                    info "  + $rel_path (new file)"
                else
                    mkdir -p "$(dirname "$installed_dir/$rel_path")"
                    cp "$defaults_dir/$rel_path" "$installed_dir/$rel_path"
                    ok "  + $rel_path (new)"
                fi
                new_count=$(( new_count + 1 ))
                local h; h=$(_file_hash "$defaults_dir/$rel_path")
                _UPDATE_MANIFEST_ENTRIES+="${rel_path}	${h}"$'\n'
                ;;
            SAFE_UPDATE|UPDATE_AVAILABLE)
                if [[ "$dry_run" == "true" ]]; then
                    info "  ~ $rel_path (framework updated, you haven't modified)"
                else
                    if [[ "$no_backup" != "true" && -f "$installed_dir/$rel_path" ]]; then
                        cp "$installed_dir/$rel_path" "$installed_dir/${rel_path}.bak"
                    fi
                    cp "$defaults_dir/$rel_path" "$installed_dir/$rel_path"
                    ok "  ~ $rel_path (updated)"
                fi
                updated=$(( updated + 1 ))
                local h; h=$(_file_hash "$defaults_dir/$rel_path")
                _UPDATE_MANIFEST_ENTRIES+="${rel_path}	${h}"$'\n'
                ;;
            BASE_MISSING)
                # Treat as UPDATE_AVAILABLE (conservative fallback)
                if [[ "$dry_run" == "true" ]]; then
                    info "  ~ $rel_path (update available, base missing)"
                else
                    if [[ "$no_backup" != "true" && -f "$installed_dir/$rel_path" ]]; then
                        cp "$installed_dir/$rel_path" "$installed_dir/${rel_path}.bak"
                    fi
                    cp "$defaults_dir/$rel_path" "$installed_dir/$rel_path"
                    ok "  ~ $rel_path (updated, base reconstructed)"
                fi
                updated=$(( updated + 1 ))
                local h; h=$(_file_hash "$defaults_dir/$rel_path")
                _UPDATE_MANIFEST_ENTRIES+="${rel_path}	${h}"$'\n'
                ;;
            CONFLICT|MERGE_AVAILABLE)
                case "$mode" in
                    force)
                        conflicts=$(( conflicts + 1 ))
                        if [[ "$dry_run" == "true" ]]; then
                            info "  ! $rel_path (conflict → force overwrite)"
                        else
                            # Backup before overwrite (unless --no-backup)
                            if [[ "$no_backup" != "true" ]]; then
                                cp "$installed_dir/$rel_path" "$installed_dir/${rel_path}.bak"
                            fi
                            cp "$defaults_dir/$rel_path" "$installed_dir/$rel_path"
                            warn "  ! $rel_path (conflict → overwritten)"
                        fi
                        local h; h=$(_file_hash "$defaults_dir/$rel_path")
                        _UPDATE_MANIFEST_ENTRIES+="${rel_path}	${h}"$'\n'
                        ;;
                    keep)
                        conflicts=$(( conflicts + 1 ))
                        if [[ "$dry_run" == "true" ]]; then
                            info "  ≡ $rel_path (conflict → keep user version)"
                        else
                            info "  ≡ $rel_path (kept user version)"
                        fi
                        # Save default hash so next run sees manifest==default → NO_UPDATE
                        local h; h=$(_file_hash "$defaults_dir/$rel_path")
                        _UPDATE_MANIFEST_ENTRIES+="${rel_path}	${h}"$'\n'
                        ;;
                    replace)
                        conflicts=$(( conflicts + 1 ))
                        if [[ "$dry_run" == "true" ]]; then
                            info "  ↻ $rel_path (conflict → replace + backup)"
                        else
                            if [[ "$no_backup" != "true" ]]; then
                                cp "$installed_dir/$rel_path" "$installed_dir/${rel_path}.bak"
                                warn "  ↻ $rel_path (replaced, backup → ${rel_path}.bak)"
                            else
                                warn "  ↻ $rel_path (replaced)"
                            fi
                            cp "$defaults_dir/$rel_path" "$installed_dir/$rel_path"
                        fi
                        local h; h=$(_file_hash "$defaults_dir/$rel_path")
                        _UPDATE_MANIFEST_ENTRIES+="${rel_path}	${h}"$'\n'
                        ;;
                    *)
                        # Default: attempt 3-way merge
                        if [[ "$dry_run" == "true" ]]; then
                            # Check if merge would succeed
                            local base_file="$base_dir/$rel_path"
                            if [[ -f "$base_file" ]]; then
                                local merge_out
                                merge_out=$(mktemp)
                                if _merge_file "$installed_dir/$rel_path" "$base_file" "$defaults_dir/$rel_path" "$merge_out"; then
                                    info "  ✓ $rel_path (auto-merge, no conflicts)"
                                    merged=$(( merged + 1 ))
                                else
                                    info "  ? $rel_path (merge has conflicts — needs resolution)"
                                    conflicts=$(( conflicts + 1 ))
                                fi
                                rm -f "$merge_out"
                            else
                                info "  ? $rel_path (both changed — needs resolution)"
                                conflicts=$(( conflicts + 1 ))
                            fi
                        else
                            _LAST_RESOLVE_AUTOMERGE=false
                            _resolve_with_merge "$rel_path" "$defaults_dir" "$installed_dir" "$base_dir" "$no_backup"
                            if $_LAST_RESOLVE_AUTOMERGE; then
                                merged=$(( merged + 1 ))
                            else
                                conflicts=$(( conflicts + 1 ))
                            fi
                        fi
                        ;;
                esac
                ;;
            USER_MODIFIED)
                if [[ "$dry_run" == "true" ]]; then
                    info "  ≡ $rel_path (user modified, no framework change)"
                fi
                skipped=$(( skipped + 1 ))
                # Keep current hash in manifest
                local h; h=$(_file_hash "$installed_dir/$rel_path")
                _UPDATE_MANIFEST_ENTRIES+="${rel_path}	${h}"$'\n'
                ;;
            NO_UPDATE)
                # Keep current hash in manifest
                local h; h=$(_file_hash "$installed_dir/$rel_path")
                _UPDATE_MANIFEST_ENTRIES+="${rel_path}	${h}"$'\n'
                ;;
            REMOVED)
                if [[ "$dry_run" == "true" ]]; then
                    info "  - $rel_path (removed from defaults)"
                else
                    warn "  - $rel_path (removed from defaults, keeping local copy)"
                fi
                # Keep in manifest with current hash
                if [[ -f "$installed_dir/$rel_path" ]]; then
                    local h; h=$(_file_hash "$installed_dir/$rel_path")
                    _UPDATE_MANIFEST_ENTRIES+="${rel_path}	${h}"$'\n'
                fi
                ;;
        esac
    done <<< "$changes"

    # Show summary
    local total_changes=$(( new_count + updated + merged + conflicts ))
    if [[ $total_changes -gt 0 || $skipped -gt 0 ]]; then
        if [[ "$dry_run" == "true" ]]; then
            [[ $new_count -gt 0 ]] && info "$new_count new file(s) to add"
            [[ $updated -gt 0 ]] && info "$updated file(s) to update"
            [[ $merged -gt 0 ]] && info "$merged file(s) auto-merged"
            [[ $conflicts -gt 0 ]] && info "$conflicts conflict(s) to resolve"
            [[ $skipped -gt 0 ]] && info "$skipped file(s) with user modifications (preserved)"
        else
            local parts=()
            [[ $new_count -gt 0 ]] && parts+=("$new_count added")
            [[ $updated -gt 0 ]] && parts+=("$updated updated")
            [[ $merged -gt 0 ]] && parts+=("$merged merged")
            [[ $conflicts -gt 0 ]] && parts+=("$conflicts conflict(s)")
            [[ $skipped -gt 0 ]] && parts+=("$skipped preserved")
            if [[ ${#parts[@]} -gt 0 ]]; then
                local summary
                printf -v summary '%s, ' "${parts[@]}"
                summary="${summary%, }"
                info "Files: $summary"
            fi
        fi
    fi
}

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
    _merge_file "$installed_dir/$rel_path" "$base_file" "$defaults_dir/$rel_path" "$merge_out"
    local merge_result=$?

    if [[ $merge_result -eq 0 ]]; then
        # Clean merge — auto-apply with backup
        _LAST_RESOLVE_AUTOMERGE=true
        if [[ "$no_backup" != "true" ]]; then
            cp "$installed_dir/$rel_path" "$installed_dir/${rel_path}.bak"
        fi
        cp "$merge_out" "$installed_dir/$rel_path"
        rm -f "$merge_out"
        ok "  ✓ $rel_path (auto-merged)"
        local h; h=$(_file_hash "$installed_dir/$rel_path")
        _UPDATE_MANIFEST_ENTRIES+="${rel_path}	${h}"$'\n'
    elif [[ $merge_result -eq 1 ]]; then
        # Conflicts in merge — show to user
        echo ""
        warn "Merge conflict: $rel_path"
        echo "  Both you and the framework changed this file."
        echo "  3-way merge produced conflicts that need resolution."
        echo ""

        local has_editor=false
        [[ -n "${EDITOR:-}" ]] && command -v "$EDITOR" >/dev/null 2>&1 && has_editor=true

        if $has_editor; then
            echo "  (M)erge — open in \$EDITOR with conflict markers"
        fi
        echo "  (K)eep your version (no changes)"
        echo "  (R)eplace with new default + create .bak"
        echo "  (S)kip (decide later)"
        echo ""

        local choice
        if (exec < /dev/tty) 2>/dev/null; then
            if $has_editor; then
                read -rp "  Choice [K/m/r/s]: " choice < /dev/tty
            else
                read -rp "  Choice [K/r/s]: " choice < /dev/tty
            fi
        else
            choice=""
        fi
        choice="${choice:-K}"
        choice="$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')"

        case "$choice" in
            m)
                # Open merged file with conflicts in editor
                if [[ "$no_backup" != "true" ]]; then
                    cp "$installed_dir/$rel_path" "$installed_dir/${rel_path}.bak"
                fi
                cp "$merge_out" "$installed_dir/$rel_path"
                "$EDITOR" "$installed_dir/$rel_path" < /dev/tty
                # Check if conflict markers were resolved
                if grep -q '<<<<<<<' "$installed_dir/$rel_path" 2>/dev/null; then
                    warn "  Conflict markers still present in $rel_path"
                else
                    ok "  ✓ $rel_path (manually merged)"
                fi
                local h; h=$(_file_hash "$installed_dir/$rel_path")
                _UPDATE_MANIFEST_ENTRIES+="${rel_path}	${h}"$'\n'
                ;;
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

# Extract language values from an existing language.md file (fallback if no .cco-meta)
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

    local update_count=0 merge_count=0 new_count=0 removed_count=0 base_missing_count=0

    while IFS=$'\t' read -r status rel_path; do
        [[ -z "$status" ]] && continue
        case "$status" in
            UPDATE_AVAILABLE|SAFE_UPDATE) update_count=$(( update_count + 1 )) ;;
            MERGE_AVAILABLE|CONFLICT)     merge_count=$(( merge_count + 1 )) ;;
            NEW)                          new_count=$(( new_count + 1 )) ;;
            REMOVED)                      removed_count=$(( removed_count + 1 )) ;;
            BASE_MISSING)                 base_missing_count=$(( base_missing_count + 1 )) ;;
        esac
    done <<< "$changes"

    local total=$(( update_count + merge_count + new_count + removed_count + base_missing_count ))
    [[ $total -eq 0 ]] && return 0

    echo ""
    info "$scope_label: opinionated updates available:"
    [[ $update_count -gt 0 ]] && info "  $update_count file(s) can be auto-applied (UPDATE_AVAILABLE)"
    [[ $merge_count -gt 0 ]] && info "  $merge_count file(s) need merge (MERGE_AVAILABLE)"
    [[ $new_count -gt 0 ]] && info "  $new_count new file(s) available (NEW)"
    [[ $removed_count -gt 0 ]] && info "  $removed_count file(s) removed from defaults (REMOVED)"
    [[ $base_missing_count -gt 0 ]] && info "  $base_missing_count file(s) with missing base (BASE_MISSING)"
    echo ""
    info "Run 'cco update --diff' for details, 'cco update --apply' to merge."
}

# ── Orchestration ────────────────────────────────────────────────────

# Update global config
_update_global() {
    local mode="$1"
    local dry_run="$2"
    local no_backup="${3:-false}"
    local meta_file="$GLOBAL_DIR/.claude/.cco-meta"
    local installed_dir="$GLOBAL_DIR/.claude"
    local defaults_dir="$DEFAULTS_DIR/global/.claude"
    local base_dir="$GLOBAL_DIR/.claude/.cco-base"

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

    # Regenerate language.md from saved choices before comparing
    if [[ "$dry_run" != "true" ]]; then
        _regenerate_language_md "$installed_dir" "$comm_lang" "$docs_lang" "$code_lang"
    fi

    # Phase 1: COLLECT — detect file changes
    local changes
    changes=$(_collect_file_changes "$defaults_dir" "$installed_dir" "$base_dir" "global")

    # Count actionable changes
    local actionable
    actionable=$(echo "$changes" | grep -cvE '^(NO_UPDATE|USER_MODIFIED|$)' || true)

    # Count pending migrations
    local pending_migrations=$(( latest_schema - current_schema ))
    [[ $pending_migrations -lt 0 ]] && pending_migrations=0

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

    if [[ "$dry_run" == "true" ]]; then
        info "Global config changes:"
    fi

    # Vault pre-update snapshot (optional)
    if [[ "$dry_run" != "true" && "$mode" != "force" && "$mode" != "keep" ]]; then
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

    # Phase 2: APPLY — execute changes
    _apply_file_changes "$changes" "$defaults_dir" "$installed_dir" "$base_dir" "$mode" "$dry_run" "$no_backup"

    # Run migrations (before copy-if-missing, so migrations can create files
    # like setup-build.sh with migrated content before the template fallback)
    if [[ $pending_migrations -gt 0 ]]; then
        if [[ "$dry_run" == "true" ]]; then
            info "$pending_migrations migration(s) pending"
        else
            _run_migrations "global" "$installed_dir" "$current_schema" "$meta_file"

            # Refresh paths if migration moved the directory (e.g. 003_user-config-dir)
            if [[ ! -d "$installed_dir" && -d "$USER_CONFIG_DIR/global/.claude" ]]; then
                GLOBAL_DIR="$USER_CONFIG_DIR/global"
                PROJECTS_DIR="$USER_CONFIG_DIR/projects"
                PACKS_DIR="$USER_CONFIG_DIR/packs"
                TEMPLATES_DIR="$USER_CONFIG_DIR/templates"
                installed_dir="$GLOBAL_DIR/.claude"
                meta_file="$installed_dir/.cco-meta"
            fi
        fi
    fi

    # Copy missing root files from defaults (after migrations, which may create some)
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

    # Update .cco-meta
    if [[ "$dry_run" != "true" ]]; then
        local created
        if [[ -f "$meta_file" ]]; then
            created=$(awk '/^created_at:/ {print $2}' "$meta_file")
        fi
        created="${created:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

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

        # Preserve last_seen_changelog from existing meta
        local last_seen
        last_seen=$(_read_last_seen_changelog "$meta_file")

        {
            echo "$_UPDATE_MANIFEST_ENTRIES"
            echo "$special_entries"
        } | _generate_cco_meta \
            "$meta_file" "$new_schema" "$created" \
            "$comm_lang" "$docs_lang" "$code_lang" "$last_seen"

        # Save base versions for future 3-way merge
        _save_all_base_versions "$base_dir" "$defaults_dir" "global"
    fi
}

# Resolve the defaults directory for a project based on .cco-source.
# Returns the path to the .claude/ directory in the template source.
_resolve_project_defaults_dir() {
    local project_dir="$1"
    local source_file="$project_dir/.cco-source"
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
    local mode="$2"
    local dry_run="$3"
    local no_backup="${4:-false}"
    local meta_file="$project_dir/.cco-meta"
    local installed_dir="$project_dir/.claude"
    local base_dir="$project_dir/.cco-base"

    # Resolve template source based on .cco-source
    local defaults_dir
    defaults_dir=$(_resolve_project_defaults_dir "$project_dir")

    # Read current state
    local current_schema
    current_schema=$(_read_cco_meta "$meta_file")
    local latest_schema
    latest_schema=$(_latest_schema_version "project")

    # Phase 1: COLLECT — detect file changes
    local changes
    changes=$(_collect_file_changes "$defaults_dir" "$installed_dir" "$base_dir" "project")

    # Count actionable changes
    local actionable
    actionable=$(echo "$changes" | grep -cvE '^(NO_UPDATE|USER_MODIFIED|$)' || true)

    # Count pending migrations
    local pending_migrations=$(( latest_schema - current_schema ))
    [[ $pending_migrations -lt 0 ]] && pending_migrations=0

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
        ok "Project config is up to date."
        return 0
    fi

    if [[ "$dry_run" == "true" ]]; then
        info "Project config changes:"
    fi

    # Phase 2: APPLY — execute changes
    _apply_file_changes "$changes" "$defaults_dir" "$installed_dir" "$base_dir" "$mode" "$dry_run" "$no_backup"

    # Run migrations (before copy-if-missing, so migrations can create files
    # with migrated content before the template fallback kicks in)
    if [[ $pending_migrations -gt 0 ]]; then
        if [[ "$dry_run" == "true" ]]; then
            info "$pending_migrations migration(s) pending"
        else
            _run_migrations "project" "$project_dir" "$current_schema" "$meta_file"
        fi
    fi

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

    # Update .cco-meta (project scope: no languages, no changelog)
    if [[ "$dry_run" != "true" ]]; then
        local created
        if [[ -f "$meta_file" ]]; then
            created=$(awk '/^created_at:/ {print $2}' "$meta_file")
        fi
        created="${created:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

        local new_schema="$latest_schema"

        # Read template name from existing .cco-meta or .cco-source
        local tmpl_name="base"
        if [[ -f "$meta_file" ]]; then
            local tmpl_val
            tmpl_val=$(awk '/^template:/ {print $2}' "$meta_file")
            [[ -n "$tmpl_val" ]] && tmpl_name="$tmpl_val"
        elif [[ -f "$project_dir/.cco-source" ]]; then
            local src_line
            src_line=$(head -1 "$project_dir/.cco-source")
            # Extract template name from native:project/<name> or user:template/<name>
            case "$src_line" in
                native:project/*) tmpl_name="${src_line#native:project/}" ;;
                user:template/*)  tmpl_name="${src_line#user:template/}" ;;
            esac
        fi

        echo "$_UPDATE_MANIFEST_ENTRIES" | _generate_project_cco_meta \
            "$meta_file" "$new_schema" "$created" "$tmpl_name"

        # Save base versions for future 3-way merge
        _save_all_base_versions "$base_dir" "$defaults_dir" "project"
    fi
}
