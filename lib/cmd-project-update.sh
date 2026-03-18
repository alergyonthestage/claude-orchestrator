#!/usr/bin/env bash
# lib/cmd-project-update.sh — Update and internalize installed projects
#
# Provides: cmd_project_update(), _update_single_project(), cmd_project_internalize()
# Dependencies: colors.sh, utils.sh, yaml.sh, remote.sh, paths.sh, update.sh
# NOTE: _resolve_template_vars() is defined in cmd-project-create.sh
# Globals: PROJECTS_DIR, NATIVE_TEMPLATES_DIR, USER_CONFIG_DIR

cmd_project_update() {
    local name="" force=false dry_run=false update_all=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)     update_all=true; shift ;;
            --force)   force=true; shift ;;
            --dry-run) dry_run=true; shift ;;
            --help)
                cat <<'EOF'
Usage: cco project update <name> [--force] [--dry-run]
       cco project update --all [--dry-run]

Check for and apply updates from the remote source of an installed project.
Uses 3-way merge to preserve your local customizations.

Options:
  --all       Update all installed projects
  --force     Replace all files without interactive merge (.bak saved)
  --dry-run   Show what would change without modifying files
EOF
                return 0
                ;;
            -*)  die "Unknown option: $1" ;;
            *)
                if [[ -z "$name" ]]; then
                    name="$1"; shift
                else
                    die "Unexpected argument: $1"
                fi
                ;;
        esac
    done

    check_global

    if $update_all; then
        local updated=0
        local -a failed_projects=()
        for project_dir in "$PROJECTS_DIR"/*/; do
            [[ ! -d "$project_dir" ]] && continue
            [[ ! -f "$project_dir/project.yml" ]] && continue
            if _is_installed_project "$project_dir"; then
                local proj_name
                proj_name=$(basename "$project_dir")
                info "Checking project '$proj_name'..."
                # Isolate errors: run in subshell so die() does not abort the loop
                if ( _update_single_project "$proj_name" "$force" "$dry_run" ); then
                    updated=$((updated + 1))
                else
                    warn "Failed to update '$proj_name'"
                    failed_projects+=("$proj_name")
                fi
            fi
        done
        if [[ $updated -eq 0 && ${#failed_projects[@]} -eq 0 ]]; then
            info "No projects with remote sources found."
        fi
        if [[ ${#failed_projects[@]} -gt 0 ]]; then
            error "Failed to update ${#failed_projects[@]} project(s): ${failed_projects[*]}"
            return 1
        fi
        return 0
    fi

    [[ -z "$name" ]] && die "Usage: cco project update <name> [--force] [--dry-run]"
    [[ ! -d "$PROJECTS_DIR/$name" ]] && die "Project '$name' not found."

    _update_single_project "$name" "$force" "$dry_run"
}

_update_single_project() {
    local name="$1"
    local force="${2:-false}"
    local dry_run="${3:-false}"

    local project_dir="$PROJECTS_DIR/$name"
    local source_file
    source_file=$(_cco_project_source "$project_dir")

    if ! _is_installed_project "$project_dir"; then
        die "Project '$name' is local — no remote source to update from. Use 'cco update --sync $name' for framework updates."
    fi

    local source_url="$_INSTALLED_SOURCE_URL"
    local source_ref="$_INSTALLED_SOURCE_REF"
    local source_path="$_INSTALLED_SOURCE_PATH"
    local installed_commit="$_INSTALLED_SOURCE_COMMIT"

    # Vault snapshot offer — use git commit with .gitignore respected (no -A)
    if [[ -d "$USER_CONFIG_DIR/.git" && "$dry_run" != "true" ]]; then
        if [[ -t 0 ]]; then
            printf "Create vault snapshot before updating? [Y/n] " >&2
            local reply
            read -r reply < /dev/tty
            if [[ ! "$reply" =~ ^[Nn]$ ]]; then
                # Stage only tracked + new gitignore-respecting files (git add . respects .gitignore)
                (cd "$USER_CONFIG_DIR" && git add --ignore-errors . && git diff --cached --quiet 2>/dev/null || git commit -q -m "vault: snapshot before project update ($name)") 2>/dev/null || true
                ok "Vault snapshot created."
            fi
        fi
    fi

    # Auto-resolve token from registered remote
    local token=""
    token=$(remote_resolve_token_for_url "$source_url" 2>/dev/null) || true

    info "Fetching $source_url${source_ref:+ (ref: $source_ref)}..."
    local tmpdir
    tmpdir=$(_clone_config_repo "$source_url" "$source_ref" "$token")
    trap "_cleanup_clone '$tmpdir'" EXIT

    # Compare versions
    local remote_head
    remote_head=$(git -C "$tmpdir" rev-parse HEAD 2>/dev/null) || true
    if [[ -n "$installed_commit" && "$remote_head" == "$installed_commit" ]]; then
        ok "Project '$name' is already up to date."
        _cleanup_clone "$tmpdir"
        trap - EXIT
        return 0
    fi

    # Locate remote project directory
    local remote_dir="$tmpdir"
    if [[ -n "$source_path" ]]; then
        remote_dir="$tmpdir/$source_path"
    fi

    if [[ ! -d "$remote_dir" ]]; then
        _cleanup_clone "$tmpdir"
        trap - EXIT
        die "Remote path '$source_path' not found in cloned repo."
    fi

    # Resolve template variables in fetched version (same as install)
    _resolve_template_vars "$remote_dir" "$name" "PROJECT_NAME=$name" 2>/dev/null || true

    # Set up paths for 3-way merge
    local installed_dir="$project_dir/.claude"
    local base_dir
    base_dir=$(_cco_project_base_dir "$project_dir")
    local remote_claude_dir="$remote_dir/.claude"

    if [[ ! -d "$remote_claude_dir" ]]; then
        warn "No .claude/ directory in remote project template."
        _cleanup_clone "$tmpdir"
        trap - EXIT
        return 0
    fi

    # Collect file changes (3-way: remote vs base vs installed)
    local changes
    changes=$(_collect_file_changes "$remote_claude_dir" "$installed_dir" "$base_dir" "project")

    local actionable
    actionable=$(echo "$changes" | grep -cvE '^(NO_UPDATE|USER_MODIFIED|$)' || true)

    local sync_applied=0
    if [[ $actionable -eq 0 ]]; then
        ok "Project '$name' files are up to date (remote has same content)."
        # Still update metadata (commit hash may differ)
        sync_applied=1  # No actionable changes means everything is in sync
    else
        local scope_label="Project '$name' (publisher update)"
        if [[ "$dry_run" == "true" ]]; then
            _show_discovery_summary "$changes" "$scope_label"
            _cleanup_clone "$tmpdir"
            trap - EXIT
            return 0
        fi

        local auto_action=""
        [[ "$force" == "true" ]] && auto_action="replace"

        _interactive_sync "$changes" "$remote_claude_dir" "$installed_dir" "$base_dir" "false" "$auto_action" "$scope_label"
        sync_applied=$_SYNC_FILES_APPLIED
    fi

    # Update .cco/base/ and .cco/source metadata only if at least one file
    # was applied/merged/kept. If the user skipped everything, base and commit
    # should stay unchanged so skipped files are flagged again on next update.
    if [[ "$dry_run" != "true" && $sync_applied -gt 0 ]]; then
        _save_all_base_versions "$base_dir" "$remote_claude_dir" "project"

        # Update .cco/source metadata
        yml_set "$source_file" "commit" "$remote_head"
        yml_set "$source_file" "updated" "$(date +%Y-%m-%d)"

        # Read version field if publisher provides one
        if [[ -f "$remote_dir/.cco/source" ]]; then
            local new_version
            new_version=$(yml_get "$remote_dir/.cco/source" "version" 2>/dev/null)
            [[ -n "$new_version" ]] && yml_set "$source_file" "version" "$new_version"
        fi

        # Update remote cache in .cco/meta
        local meta_file
        meta_file=$(_cco_project_meta "$project_dir")
        yml_set "$meta_file" "remote_cache.commit" "$remote_head"
        yml_set "$meta_file" "remote_cache.checked" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

        local short_old="${installed_commit:0:7}"
        local short_new="${remote_head:0:7}"
        [[ -z "$short_old" ]] && short_old="unknown"
        ok "Updated project '$name' (${short_old} -> ${short_new})"
    elif [[ "$dry_run" != "true" && $sync_applied -eq 0 ]]; then
        # User skipped everything — only update remote cache so we don't
        # re-clone on every run, but keep base/commit unchanged
        local meta_file
        meta_file=$(_cco_project_meta "$project_dir")
        yml_set "$meta_file" "remote_cache.commit" "$remote_head"
        yml_set "$meta_file" "remote_cache.checked" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        info "All files skipped — base versions unchanged. Skipped files will be flagged again on next update."
    fi

    _cleanup_clone "$tmpdir"
    trap - EXIT
}

# ── Project Internalize ───────────────────────────────────────────────

cmd_project_internalize() {
    local name="" yes_mode=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes)  yes_mode=true; shift ;;
            --help)
                cat <<'EOF'
Usage: cco project internalize <name> [--yes]

Disconnect a project from its remote source, converting it to a local project.
After internalizing, framework updates apply directly via 'cco update --sync'.

Options:
  --yes     Skip confirmation prompt
EOF
                return 0
                ;;
            -*)  die "Unknown option: $1" ;;
            *)
                if [[ -z "$name" ]]; then
                    name="$1"; shift
                else
                    die "Unexpected argument: $1"
                fi
                ;;
        esac
    done

    [[ -z "$name" ]] && die "Usage: cco project internalize <name>"

    local project_dir="$PROJECTS_DIR/$name"
    [[ ! -d "$project_dir" ]] && die "Project '$name' not found."

    if ! _is_installed_project "$project_dir"; then
        ok "Project '$name' is already local."
        return 0
    fi

    local source_url="$_INSTALLED_SOURCE_URL"

    # Confirm (required unless --yes)
    if [[ "$yes_mode" != "true" ]]; then
        if [[ -t 0 ]]; then
            printf "This will disconnect '%s' from %s.\n" "$name" "$source_url" >&2
            printf "You will no longer receive publisher updates.\n" >&2
            printf "Framework updates will apply directly via 'cco update --sync'.\n" >&2
            printf "Continue? [y/N] " >&2
            local reply
            read -r reply < /dev/tty
            [[ ! "$reply" =~ ^[Yy]$ ]] && die "Aborted."
        else
            die "Non-interactive mode: use --yes to confirm internalization."
        fi
    fi

    local source_file
    source_file=$(_cco_project_source "$project_dir")

    # Update .cco/source — source: local must be first line for format detection
    {
        printf 'source: local\n'
        printf '# previously installed from: %s\n' "$source_url"
    } > "$source_file"

    # Update .cco/base/ to framework base template (for future cco update --sync)
    local base_dir
    base_dir=$(_cco_project_base_dir "$project_dir")
    rm -rf "$base_dir"
    mkdir -p "$base_dir"
    _save_all_base_versions "$base_dir" "$NATIVE_TEMPLATES_DIR/project/base/.claude" "project"

    # Clear remote cache and override marker from .cco/meta
    local meta_file
    meta_file=$(_cco_project_meta "$project_dir")
    if [[ -f "$meta_file" ]]; then
        yml_remove "$meta_file" "remote_cache"
        yml_remove "$meta_file" "local_framework_override"
    fi

    ok "Project '$name' is now local. Framework updates will apply directly via 'cco update --sync'."
}
