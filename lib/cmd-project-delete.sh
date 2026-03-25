#!/usr/bin/env bash
# lib/cmd-project-delete.sh — Delete a project from all locations
#
# Provides: cmd_project_delete()
# Dependencies: colors.sh, utils.sh, yaml.sh, cmd-vault.sh
# Globals: PROJECTS_DIR, USER_CONFIG_DIR

cmd_project_delete() {
    local name=""
    local auto_yes=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes|-y) auto_yes=true; shift ;;
            --help)
                cat <<'EOF'
Usage: cco project delete <name> [--yes]

Delete a project from disk entirely. When a vault is active, removes
the project from ALL branches (profiles and main).

Options:
  --yes, -y   Skip confirmation prompt

This action is irreversible. All project files, configuration, and
session state will be deleted.
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

    [[ -z "$name" ]] && die "Usage: cco project delete <name> [--yes]"

    local vault_active=false
    if [[ -d "$USER_CONFIG_DIR/.git" ]]; then
        vault_active=true
    fi

    if $vault_active; then
        _project_delete_with_vault "$name" "$auto_yes"
    else
        _project_delete_simple "$name" "$auto_yes"
    fi
}

# Delete project without vault — simple rm -rf
_project_delete_simple() {
    local name="$1" auto_yes="$2"
    local project_dir="$PROJECTS_DIR/$name"

    if [[ ! -d "$project_dir" ]]; then
        die "Project '$name' not found at projects/$name/"
    fi

    # Confirmation
    if ! $auto_yes; then
        if [[ -t 0 ]]; then
            warn "This will permanently delete project '$name' and all its files."
            printf "Delete project '%s'? [y/N] " "$name" >&2
            local reply
            read -r reply
            if [[ ! "$reply" =~ ^[Yy]$ ]]; then
                info "Aborted"
                return 0
            fi
        else
            die "Project delete requires interactive confirmation (use --yes to skip)"
        fi
    fi

    rm -rf "$project_dir"
    ok "Deleted project '$name'"
}

# Delete project with vault active — removes from all branches
_project_delete_with_vault() {
    local name="$1" auto_yes="$2"
    local vault_dir="$USER_CONFIG_DIR"
    local project_path="projects/$name"

    # Save current branch to restore later
    local original_branch
    original_branch=$(git -C "$vault_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)

    # Find all branches that contain this project
    local -a branches_with_project=()
    local -a branch_summaries=()
    local branch

    while IFS= read -r branch; do
        [[ -z "$branch" ]] && continue
        local file_count
        file_count=$(git -C "$vault_dir" ls-tree -r "$branch" -- "$project_path/" 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$file_count" -gt 0 ]]; then
            branches_with_project+=("$branch")
            branch_summaries+=("$branch: $file_count tracked files")
        fi
    done < <(git -C "$vault_dir" for-each-ref --format='%(refname:short)' refs/heads/)

    # Also check if project exists on disk (untracked/gitignored files)
    local has_disk_files=false
    if [[ -d "$vault_dir/$project_path" ]]; then
        has_disk_files=true
    fi

    if [[ ${#branches_with_project[@]} -eq 0 ]] && ! $has_disk_files; then
        die "Project '$name' not found on any branch or on disk"
    fi

    # Show summary
    echo "" >&2
    warn "Deleting project '$name' from ALL locations:"
    if [[ ${#branches_with_project[@]} -gt 0 ]]; then
        local summary
        for summary in "${branch_summaries[@]}"; do
            echo "    - Branch '$summary'" >&2
        done
    fi
    if $has_disk_files; then
        echo "    - Disk files (gitignored/untracked)" >&2
    fi
    echo "  This action is irreversible." >&2
    echo "" >&2

    # Confirmation
    if ! $auto_yes; then
        if [[ -t 0 ]]; then
            printf "Proceed? [y/N] " >&2
            local reply
            read -r reply
            if [[ ! "$reply" =~ ^[Yy]$ ]]; then
                info "Aborted"
                return 0
            fi
        else
            die "Project delete requires interactive confirmation (use --yes to skip)"
        fi
    fi

    # For each branch: checkout, git rm, update .vault-profile, commit
    for branch in "${branches_with_project[@]+"${branches_with_project[@]}"}"; do
        git -C "$vault_dir" checkout "$branch" -q 2>/dev/null

        # git rm the project directory
        git -C "$vault_dir" rm -r --quiet -- "$project_path/" 2>/dev/null || true

        # Update .vault-profile if it exists on this branch
        if [[ -f "$vault_dir/.vault-profile" ]]; then
            _profile_remove_from_list "projects" "$name"
            git -C "$vault_dir" add -- .vault-profile 2>/dev/null || true
        fi

        # Commit the removal
        git -C "$vault_dir" commit -q -m "vault: delete project '$name' from branch '$branch'" 2>/dev/null || true
    done

    # Delete gitignored/untracked files on disk
    if [[ -d "$vault_dir/$project_path" ]]; then
        rm -rf "$vault_dir/$project_path"
    fi

    # Clean shadow directory entries across all profiles
    local shadow_base="$vault_dir/.cco/profile-state"
    if [[ -d "$shadow_base" ]]; then
        local profile_dir
        for profile_dir in "$shadow_base"/*/; do
            [[ ! -d "$profile_dir" ]] && continue
            if [[ -d "${profile_dir}${project_path}" ]]; then
                rm -rf "${profile_dir}${project_path}"
            fi
        done
    fi

    # Return to original branch
    git -C "$vault_dir" checkout "$original_branch" -q 2>/dev/null || true

    ok "Deleted project '$name' from ${#branches_with_project[@]} branch(es)"
}
