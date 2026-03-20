#!/usr/bin/env bash
# lib/update.sh — Update engine orchestrators
#
# Provides: _update_global(), _resolve_project_defaults_dir(), _update_project()
# Dependencies: colors.sh, utils.sh, update-hash-io.sh, update-merge.sh,
#               update-meta.sh, update-discovery.sh, update-sync.sh,
#               update-changelog.sh, update-remote.sh

# ── File Policies ─────────────────────────────────────────────────────
# Declarative classification of all managed files.
# Policies:
#   tracked    — 3-way merge on update (user customizations preserved)
#   untracked  — never touched after initial copy, not discovered for updates
#   generated  — regenerated from template + saved values (e.g., language.md)

GLOBAL_FILE_POLICIES=(
    ".claude/CLAUDE.md:tracked"
    ".claude/settings.json:tracked"
    ".claude/mcp.json:untracked"
    ".claude/agents/analyst.md:tracked"
    ".claude/agents/reviewer.md:tracked"
    ".claude/rules/documentation.md:tracked"
    ".claude/rules/git-practices.md:tracked"
    ".claude/rules/workflow.md:tracked"
    ".claude/rules/language.md:generated"
    ".claude/skills/analyze/SKILL.md:tracked"
    ".claude/skills/review/SKILL.md:tracked"
    ".claude/skills/design/SKILL.md:tracked"
    ".claude/skills/commit/SKILL.md:tracked"
    "setup.sh:untracked"
    "setup-build.sh:untracked"
)

# Note: only .claude/ files are tracked here. Root files (project.yml, setup.sh,
# secrets.env, mcp-packages.txt) are handled by PROJECT_ROOT_COPY_IF_MISSING —
# they are copied once if missing but never overwritten by the update system.
PROJECT_FILE_POLICIES=(
    ".claude/CLAUDE.md:tracked"
    ".claude/settings.json:tracked"
)

# Derived lists for _collect_file_changes().
# Global scope: _collect_file_changes operates on files relative to .claude/,
# so we strip the ".claude/" prefix from policy paths inside .claude/.
# Root files (setup.sh, etc.) are outside the scan scope — handled separately.
GLOBAL_UNTRACKED_FILES=()
GLOBAL_SPECIAL_FILES=()
PROJECT_UNTRACKED_FILES=()
for _p in "${GLOBAL_FILE_POLICIES[@]}"; do
    _rel="${_p%:*}"
    _pol="${_p##*:}"
    # Strip .claude/ prefix for files inside .claude/
    _rel="${_rel#.claude/}"
    case "$_pol" in
        untracked) GLOBAL_UNTRACKED_FILES+=("$_rel") ;;
        generated) GLOBAL_SPECIAL_FILES+=("$_rel") ;;
        # tracked files need no special list — they are the default,
        # discovered automatically by _collect_file_changes()
    esac
done
# Project scope: only untracked files need a filter list.
# No 'generated' files at project scope currently.
for _p in "${PROJECT_FILE_POLICIES[@]}"; do
    _rel="${_p%:*}"
    _rel="${_rel#.claude/}"
    [[ "${_p##*:}" == "untracked" ]] && PROJECT_UNTRACKED_FILES+=("$_rel")
done
unset _p _rel _pol

# Root files: copied from defaults if missing, never overwritten.
# Checked AFTER migrations run, so migration 005 can create setup-build.sh
# with migrated content before the copy-if-missing fallback kicks in.
GLOBAL_ROOT_COPY_IF_MISSING=("setup.sh" "setup-build.sh")
# Project root files: copied from template if missing, never overwritten
PROJECT_ROOT_COPY_IF_MISSING=("setup.sh" "secrets.env" "mcp-packages.txt")

# NOTE: _sed_i() and _sed_i_or_append() are defined in lib/utils.sh

# ── Orchestration ────────────────────────────────────────────────────

# Update global config
_update_global() {
    local cmd_mode="$1"       # discovery | diff | sync | news
    local dry_run="$2"
    local no_backup="${3:-false}"
    local auto_action="${4:-}"  # "" | replace | keep | skip
    local diff_mode="${5:-full}"  # summary | full (for --diff mode)
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
            fi

            # Always refresh meta/base paths after migrations — migration 009
            # moves .cco-meta → .cco/meta within the same directory, so the
            # directory-level check above won't catch it.
            meta_file=$(_cco_global_meta)
            base_dir=$(_cco_global_base_dir)
        fi
    fi

    # --news mode: only changelog (handled by caller), skip discovery
    [[ "$cmd_mode" == "news" ]] && return 0

    # Phase 1.5: Handle policy transitions for global scope.
    # In dry-run mode, detects transitions but skips disk writes.
    _handle_policy_transitions "$GLOBAL_DIR" "$meta_file" "$base_dir" "$defaults_dir" "global" "$dry_run"

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
            if [[ "$diff_mode" == "summary" ]]; then
                _show_file_diffs_summary "$changes" "Global"
            else
                _show_file_diffs "$changes" "$defaults_dir" "$installed_dir" "$base_dir" "Global"
            fi
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
                _interactive_sync "$changes" "$defaults_dir" "$installed_dir" "$base_dir" "$no_backup" "$auto_action" "Global" ""
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
            # Use manifest entries from _interactive_sync
            {
                echo "$_UPDATE_MANIFEST_ENTRIES"
                echo "$special_entries"
            } | _generate_cco_meta \
                "$meta_file" "$new_schema" "$created" \
                "$comm_lang" "$docs_lang" "$code_lang" "$last_seen" "$last_read"

            # Note: .cco/base/ is saved per-file inside _interactive_sync
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
                    [[ "$policy" == "untracked" ]] && continue
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
    source_file=$(_cco_project_source "$project_dir")
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
            # Check internal projects first (e.g., tutorial moved to internal/)
            local internal_dir="$REPO_ROOT/internal/$tmpl_name/.claude"
            local tmpl_dir="$NATIVE_TEMPLATES_DIR/project/$tmpl_name/.claude"
            if [[ -d "$internal_dir" ]]; then
                echo "$internal_dir"
            elif [[ -d "$tmpl_dir" ]]; then
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
        source:*)
            # YAML format (FI-7+): "source: https://..." or "source: local"
            # Remote-installed or internalized project: use base template
            echo "$fallback"
            ;;
        http://*|https://*)
            # Legacy bare URL format (pre-FI-7): direct URL as first line
            # Remote-installed project: use base template for opinionated files
            echo "$fallback"
            ;;
        *)
            # Unknown format — warn and fall back to base
            warn "Unknown .cco/source format in project '$(basename "$project_dir")': $source_line"
            warn "  Falling back to base template for discovery."
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
    local offline_mode="${6:-false}"
    local cache_mode="${7:-default}"
    local local_override="${8:-false}"
    local diff_mode="${9:-full}"  # summary | full (for --diff mode)
    local pname
    pname="$(basename "$project_dir")"
    local meta_file
    meta_file=$(_cco_project_meta "$project_dir")
    local installed_dir="$project_dir/.claude"
    local base_dir
    base_dir=$(_cco_project_base_dir "$project_dir")

    # Check if project is installed from a remote source
    local is_installed=false
    local source_display=""
    if _is_installed_project "$project_dir"; then
        is_installed=true
        # Extract short display name from URL
        source_display="$_INSTALLED_SOURCE_URL"
        source_display="${source_display#https://}"
        source_display="${source_display#http://}"
        source_display="${source_display%.git}"
    fi

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
                error "Project '$pname' migrations failed. Run 'cco update' again after resolving the issue."
                return 1
            fi

            # Refresh meta/base paths — migration 009 moves .cco-meta → .cco/meta
            meta_file=$(_cco_project_meta "$project_dir")
            base_dir=$(_cco_project_base_dir "$project_dir")
        fi
    fi

    # Check if project was removed by a migration (e.g., tutorial → internal)
    if [[ ! -d "$project_dir" ]]; then
        return 0
    fi

    # --news mode: skip discovery for projects
    [[ "$cmd_mode" == "news" ]] && return 0

    # ── Source-aware sync (Phase 2) ──────────────────────────────────
    # For installed projects with --sync (without --local), skip opinionated
    # files and delegate to the publisher chain.
    if [[ "$is_installed" == "true" && "$cmd_mode" == "sync" && "$local_override" != "true" ]]; then
        echo ""
        info "Project '$pname' is installed from $source_display."
        info "Framework opinionated updates are managed by the publisher."
        info "  -> Run 'cco project update $pname' to check for publisher updates."
        info "  -> Use '--local' to apply framework defaults directly."
        return 0
    fi

    # Phase 1.5: Handle policy transitions (untracked↔tracked↔generated).
    # Must run BEFORE _collect_file_changes so bases are seeded/removed as needed.
    # In dry-run mode, detects transitions but skips disk writes.
    _handle_policy_transitions "$project_dir" "$meta_file" "$base_dir" "$defaults_dir" "project" "$dry_run"

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

    # ── Remote discovery ─────────────────────────────────────────────
    # In discovery mode, check remote sources for installed projects
    local remote_status=""
    if [[ "$is_installed" == "true" && "$offline_mode" != "true" && "$cmd_mode" == "discovery" ]]; then
        local source_file
        source_file=$(_cco_project_source "$project_dir")
        remote_status=$(_check_remote_update "$source_file" "$meta_file" "$cache_mode")
    fi

    # Also count framework changes for installed projects (informational)
    local fw_actionable=0
    if [[ "$is_installed" == "true" && $actionable -gt 0 ]]; then
        fw_actionable=$actionable
        # If --local was previously used, suppress the framework changes note
        local local_override_marker=""
        local_override_marker=$(yml_get "$meta_file" "local_framework_override" 2>/dev/null)
        if [[ "$local_override_marker" == "true" ]]; then
            fw_actionable=0
        fi
    fi

    # For installed projects in discovery mode, fw_actionable is informational
    # but we still need to report it. "Up to date" = no migrations, no actionable
    # changes, no remote status, AND no framework changes worth mentioning.
    local has_anything=false
    [[ $pending_migrations -gt 0 ]] && has_anything=true
    [[ ${#root_missing[@]} -gt 0 ]] && has_anything=true
    [[ -n "$remote_status" && "$remote_status" != "up_to_date" ]] && has_anything=true
    if [[ "$is_installed" == "true" ]]; then
        [[ $fw_actionable -gt 0 ]] && has_anything=true
    else
        [[ $actionable -gt 0 ]] && has_anything=true
    fi

    if [[ "$has_anything" != "true" ]]; then
        ok "Project '$pname' config is up to date."
        return 0
    fi

    local scope_label="Project '$pname'"
    if [[ "$is_installed" == "true" ]]; then
        scope_label="Project '$pname' (from $source_display)"
    fi

    # Phase 3: Route based on cmd_mode
    case "$cmd_mode" in
        discovery)
            if [[ "$is_installed" == "true" ]]; then
                # For installed projects, show remote status prominently
                case "$remote_status" in
                    update_available)
                        info "  Publisher update available"
                        info "    -> run 'cco project update $pname' to review"
                        ;;
                    unknown)
                        info "  Version tracking not initialized — run 'cco project update $pname' to check"
                        ;;
                    unreachable)
                        warn "  Remote unreachable — skipping remote check"
                        ;;
                    up_to_date)
                        ok "  Publisher version: up to date"
                        ;;
                esac
                if [[ $fw_actionable -gt 0 ]]; then
                    info "  $fw_actionable framework default(s) also updated (managed by publisher)"
                fi
            else
                _show_discovery_summary "$changes" "$scope_label"
            fi
            ;;
        diff)
            if [[ "$diff_mode" == "summary" ]]; then
                _show_file_diffs_summary "$changes" "$scope_label"
            else
                _show_file_diffs "$changes" "$defaults_dir" "$installed_dir" "$base_dir" "$scope_label"
            fi
            ;;
        sync)
            if [[ "$dry_run" == "true" ]]; then
                _show_discovery_summary "$changes" "$scope_label"
            else
                if [[ "$is_installed" == "true" && "$local_override" == "true" ]]; then
                    info "Applying framework defaults directly (--local escape hatch)."
                    yml_set "$meta_file" "local_framework_override" "true"
                fi
                _interactive_sync "$changes" "$defaults_dir" "$installed_dir" "$base_dir" "$no_backup" "$auto_action" "$scope_label" "$project_dir"
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
            source_file=$(_cco_project_source "$project_dir")
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

            # Note: .cco/base/ is saved per-file inside _interactive_sync
            # (only for Apply/Keep/Merge/Replace, not Skip)
        else
            # Discovery/diff mode: only update schema_version (from migrations)
            if [[ $pending_migrations -gt 0 ]]; then
                local current_manifest=""
                local entry rel policy
                for entry in "${PROJECT_FILE_POLICIES[@]}"; do
                    rel="${entry%:*}"
                    policy="${entry##*:}"
                    [[ "$policy" == "untracked" ]] && continue
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
