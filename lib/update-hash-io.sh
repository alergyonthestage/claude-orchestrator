# lib/update-hash-io.sh — File hashing, base version management, policy transitions

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

# Seed a base file from an interpolated template. Resolves {{PROJECT_NAME}}
# and {{DESCRIPTION}} using values recoverable from the project directory.
# Uses awk for safe substitution (handles special chars in values).
# Used by _handle_policy_transitions().
_seed_base_from_interpolated_template() {
    local base_dir="$1"      # .cco/base/ directory
    local rel="$2"           # relative path (e.g., CLAUDE.md)
    local defaults_dir="$3"  # template .claude/ directory (may have placeholders)
    local project_dir="$4"   # project root directory

    local template_file="$defaults_dir/$rel"
    [[ -f "$template_file" ]] || return 0

    local project_name
    project_name=$(basename "$project_dir")

    # Read description from project.yml via yml_get (handles quotes, comments)
    local description="TODO: Add project description"
    local project_yml="$project_dir/project.yml"
    if [[ -f "$project_yml" ]]; then
        local yml_desc
        yml_desc=$(yml_get "$project_yml" "description" 2>/dev/null) || true
        [[ -n "$yml_desc" ]] && description="$yml_desc"
    fi

    # Interpolate placeholders using awk (safe with all special chars)
    mkdir -p "$(dirname "$base_dir/$rel")"
    awk -v name="$project_name" -v desc="$description" '{
        gsub(/\{\{PROJECT_NAME\}\}/, name)
        gsub(/\{\{DESCRIPTION\}\}/, desc)
        print
    }' "$template_file" > "$base_dir/$rel"
}

# Create an interpolated temp copy of a template file for comparison.
# Resolves {{PROJECT_NAME}} and {{DESCRIPTION}} using values recoverable
# from the project directory. Returns the temp file path on stdout.
# Caller is responsible for rm -f of the returned file.
_interpolate_template_tmp() {
    local template_file="$1"   # path to the raw template file
    local project_dir="$2"     # project root directory

    local project_name
    project_name=$(basename "$project_dir")

    local description="TODO: Add project description"
    local project_yml="$project_dir/project.yml"
    if [[ -f "$project_yml" ]]; then
        local yml_desc
        yml_desc=$(yml_get "$project_yml" "description" 2>/dev/null) || true
        [[ -n "$yml_desc" ]] && description="$yml_desc"
    fi

    local tmp
    tmp=$(mktemp)
    awk -v name="$project_name" -v desc="$description" '{
        gsub(/\{\{PROJECT_NAME\}\}/, name)
        gsub(/\{\{DESCRIPTION\}\}/, desc)
        print
    }' "$template_file" > "$tmp"
    printf '%s' "$tmp"
}

# ── Policy Transition Detection ──────────────────────────────────────

# Detect and handle file policy transitions (untracked↔tracked↔generated).
# Compares saved policies in .cco/meta against current *_FILE_POLICIES.
# Must be called BEFORE _collect_file_changes() so bases are up to date.
# Persists updated policies directly to .cco/meta (independent of
# _generate_*_cco_meta, so transitions work even in discovery/diff mode).
# In dry-run mode, skips all disk writes (base seeding and meta updates).
_handle_policy_transitions() {
    local project_dir="$1"
    local meta_file="$2"
    local base_dir="$3"
    local defaults_dir="$4"
    local scope="$5"          # "global" or "project"
    local dry_run="${6:-false}" # "true" to skip disk writes

    local policies_ref
    if [[ "$scope" == "global" ]]; then
        policies_ref=("${GLOBAL_FILE_POLICIES[@]}")
    else
        policies_ref=("${PROJECT_FILE_POLICIES[@]}")
    fi

    [[ -f "$meta_file" ]] || return 0

    local needs_policy_write=false
    local _installed_dir=""
    local entry rel policy saved_policy
    for entry in "${policies_ref[@]}"; do
        rel="${entry%:*}"
        policy="${entry##*:}"
        rel="${rel#.claude/}"

        # Read saved policy from .cco/meta (empty if not present)
        saved_policy=$(yml_get "$meta_file" "policies.$rel" 2>/dev/null) || true

        if [[ -z "$saved_policy" ]]; then
            # No saved policy = first run with policy tracking (bootstrap).
            # Seed base for tracked files that are missing from .cco/base/.
            needs_policy_write=true
            if [[ "$dry_run" != "true" && "$policy" == "tracked" && ! -f "$base_dir/$rel" ]]; then
                if [[ "$scope" == "project" ]]; then
                    _seed_base_from_interpolated_template \
                        "$base_dir" "$rel" "$defaults_dir" "$project_dir"
                else
                    # Global scope: save from defaults directly (no placeholders in tracked global files)
                    if [[ -f "$defaults_dir/$rel" ]]; then
                        _save_base_version "$base_dir" "$rel" "$defaults_dir/$rel"
                    fi
                fi
            fi
            continue
        fi

        # Same policy = no transition
        [[ "$saved_policy" == "$policy" ]] && continue

        needs_policy_write=true

        # Skip disk writes in dry-run mode
        [[ "$dry_run" == "true" ]] && continue

        case "${saved_policy}_to_${policy}" in
            untracked_to_tracked)
                # File was user-owned, now framework tracks it for merge support.
                if [[ "$scope" == "project" ]]; then
                    _seed_base_from_interpolated_template \
                        "$base_dir" "$rel" "$defaults_dir" "$project_dir"
                else
                    if [[ -f "$defaults_dir/$rel" ]]; then
                        _save_base_version "$base_dir" "$rel" "$defaults_dir/$rel"
                    fi
                fi
                ;;
            tracked_to_untracked)
                # Framework no longer tracks this file. Remove base entry.
                rm -f "$base_dir/$rel"
                ;;
            generated_to_tracked)
                # Was auto-regenerated, now user-customizable with merge support.
                # Save current installed version as the base.
                if [[ "$scope" == "project" ]]; then
                    _installed_dir="$project_dir/.claude"
                else
                    _installed_dir="$GLOBAL_DIR/.claude"
                fi
                if [[ -f "$_installed_dir/$rel" ]]; then
                    _save_base_version "$base_dir" "$rel" "$_installed_dir/$rel"
                fi
                ;;
            tracked_to_generated)
                # Now auto-regenerated; base is unnecessary.
                rm -f "$base_dir/$rel"
                ;;
            *)
                # Other transitions (untracked↔generated, etc.) — no base action.
                ;;
        esac
    done

    # Persist current policies to .cco/meta so future runs detect transitions.
    # Written directly (not via _generate_*_cco_meta) so it works in all modes.
    # Skipped in dry-run mode to avoid disk mutations.
    if [[ "$needs_policy_write" == "true" && "$dry_run" != "true" ]]; then
        # Remove existing policies section if present, then append fresh
        local tmp_meta
        tmp_meta=$(mktemp)
        # Remove old policies block (from "policies:" to next top-level key or EOF)
        # and strip trailing blank lines in a single awk pass (portable)
        awk '
            /^policies:/ { skip=1; next }
            skip && /^[^ ]/ { skip=0 }
            !skip { buf[++n] = $0 }
            END { while (n > 0 && buf[n] ~ /^[[:space:]]*$/) n--; for (i=1; i<=n; i++) print buf[i] }
        ' "$meta_file" > "$tmp_meta"
        # Append fresh policies
        {
            printf '\npolicies:\n'
            local _we _wr _wp
            for _we in "${policies_ref[@]}"; do
                _wr="${_we%:*}"
                _wp="${_we##*:}"
                _wr="${_wr#.claude/}"
                printf '  %s: %s\n' "$_wr" "$_wp"
            done
        } >> "$tmp_meta"
        mv "$tmp_meta" "$meta_file"
    fi
}
