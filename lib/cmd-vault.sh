#!/usr/bin/env bash
# lib/cmd-vault.sh — Vault commands for config versioning
#
# Provides: cmd_vault()
# Dependencies: colors.sh, utils.sh, manifest.sh
# Globals: USER_CONFIG_DIR

# ── Vault .gitignore template ─────────────────────────────────────────

_VAULT_GITIGNORE='# Secrets — never committed
secrets.env
*.env
.credentials.json
*.key
*.pem

# Runtime files — generated, not user config
projects/*/.cco/managed/
projects/*/.cco/docker-compose.yml
projects/*/.tmp/
projects/*/.cco/meta

# Session state — transient, large, personal
global/claude-state/
projects/*/.cco/claude-state/
projects/*/rag-data/

# Global meta
global/.claude/.cco/meta

# Legacy pack manifest (inside .claude/)
projects/*/.claude/.cco/pack-manifest

# Pack install temporary files
packs/*/.cco/install-tmp/

# Update sync artifacts — temporary review files
*.bak
*.new

# Internal tutorial runtime state
.cco/internal/

# Machine-specific remote config
.cco/remotes
'

# ── Secret patterns for pre-commit scan ───────────────────────────────

_VAULT_SECRET_PATTERNS=(
    'secrets.env'
    '*.env'
    '*.key'
    '*.pem'
    '.credentials.json'
    '.cco/remotes'
)

# ── Vault subcommands ─────────────────────────────────────────────────

cmd_vault_init() {
    local target=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                cat <<'EOF'
Usage: cco vault init [<path>]

Initialize a git repository in user-config/ (or the specified path)
for versioning your CCO configuration.
EOF
                return 0
                ;;
            -*) die "Unknown option: $1" ;;
            *)  target="$1"; shift ;;
        esac
    done

    target="${target:-$USER_CONFIG_DIR}"

    if [[ ! -d "$target" ]]; then
        mkdir -p "$target"
        ok "Created $target"
    fi

    if [[ -d "$target/.git" ]]; then
        warn "Vault already initialized at $target"
        return 0
    fi

    git -C "$target" init -q
    ok "Initialized git repository in $target"

    # Write .gitignore template
    printf '%s' "$_VAULT_GITIGNORE" > "$target/.gitignore"
    ok "Created .gitignore with secret exclusions"

    # Generate manifest.yml if missing
    manifest_init "$target"

    # Initial commit
    git -C "$target" add -A
    git -C "$target" commit -q -m "vault: initial commit"
    ok "Created initial commit"

    # Hint about remote
    echo ""
    info "Vault initialized. To back up to a remote:"
    echo "  cco vault remote add origin <url>"
    echo "  cco vault push"
}

cmd_vault_sync() {
    local message="" dry_run=false auto_yes=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) dry_run=true; shift ;;
            --yes|-y)  auto_yes=true; shift ;;
            --help)
                cat <<'EOF'
Usage: cco vault sync [<message>] [--yes] [--dry-run]

Commit the current state of your configuration with a pre-commit summary.

Options:
  --dry-run   Show summary only, do not commit
  --yes, -y   Skip confirmation prompt
EOF
                return 0
                ;;
            -*)  die "Unknown option: $1" ;;
            *)   message="$1"; shift ;;
        esac
    done

    _check_vault

    local vault_dir="$USER_CONFIG_DIR"

    # Check for changes
    local status_output
    status_output=$(git -C "$vault_dir" status --porcelain 2>/dev/null)
    if [[ -z "$status_output" ]]; then
        ok "Nothing to commit — vault is up to date"
        return 0
    fi

    # Secret detection — scan for files that should never be committed
    local secret_files=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local file="${line:3}"
        # Directory entries: expand to individual files so we match
        # against actual unignored contents (not assumed by path prefix).
        # git status --porcelain never lists ignored files, so if .gitignore
        # covers a secret pattern, the file won't appear here.
        local expanded_files=("$file")
        if [[ "$file" == */ ]]; then
            expanded_files=()
            while IFS= read -r subfile; do
                [[ -n "$subfile" ]] && expanded_files+=("${subfile:3}")
            done < <(git -C "$vault_dir" status --porcelain -uall -- "$file" 2>/dev/null)
        fi
        for ef in ${expanded_files[@]+"${expanded_files[@]}"}; do
            for pattern in "${_VAULT_SECRET_PATTERNS[@]}"; do
                local basename_file
                basename_file=$(basename "$ef")
                # Match exact name, glob pattern on basename, or path suffix
                if [[ "$basename_file" == $pattern || "$ef" == *"$pattern" ]]; then
                    secret_files+=("$ef")
                    break
                fi
            done
        done
    done <<< "$status_output"

    if [[ ${#secret_files[@]} -gt 0 ]]; then
        error "Secret files detected — aborting vault sync"
        for f in "${secret_files[@]}"; do
            echo "  - $f" >&2
        done
        echo "" >&2
        info "These files should be excluded by .gitignore."
        info "Check your vault .gitignore at: $vault_dir/.gitignore"
        return 1
    fi

    # Categorize changes
    local packs_count=0 projects_count=0 global_count=0 templates_count=0 other_count=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local file="${line:3}"
        case "$file" in
            packs/*)     packs_count=$((packs_count + 1)) ;;
            projects/*)  projects_count=$((projects_count + 1)) ;;
            global/*)    global_count=$((global_count + 1)) ;;
            templates/*) templates_count=$((templates_count + 1)) ;;
            *)           other_count=$((other_count + 1)) ;;
        esac
    done <<< "$status_output"

    # Display summary
    echo -e "${BOLD}Changes to commit:${NC}"
    [[ $packs_count -gt 0 ]]     && echo "  packs:     $packs_count file(s)"
    [[ $projects_count -gt 0 ]]  && echo "  projects:  $projects_count file(s)"
    [[ $global_count -gt 0 ]]    && echo "  global:    $global_count file(s)"
    [[ $templates_count -gt 0 ]] && echo "  templates: $templates_count file(s)"
    [[ $other_count -gt 0 ]]     && echo "  other:     $other_count file(s)"

    local total=$((packs_count + projects_count + global_count + templates_count + other_count))
    echo "  total:     $total file(s)"

    if $dry_run; then
        echo ""
        ok "Dry run complete — no changes committed"
        return 0
    fi

    # Confirmation prompt
    if ! $auto_yes; then
        if [[ -t 0 ]]; then
            printf "\nProceed? [Y/n] " >&2
            local reply
            read -r reply
            if [[ "$reply" =~ ^[Nn]$ ]]; then
                info "Aborted"
                return 0
            fi
        fi
    fi

    # Default message
    if [[ -z "$message" ]]; then
        message="snapshot $(date +%Y-%m-%d)"
    fi

    # Commit — profile-scoped staging if active profile
    local profile
    profile=$(_get_active_profile)

    if [[ -n "$profile" ]]; then
        # With profile: stage only profile-declared paths
        local -a paths=()

        # Shared resources (always staged)
        paths+=("global/" "templates/" ".gitignore" "manifest.yml" ".vault-profile")

        # Profile-exclusive resources
        local proj_list pack_list
        proj_list=$(_profile_projects)
        pack_list=$(_profile_packs)

        if [[ -n "$proj_list" ]]; then
            while IFS= read -r p; do
                [[ -n "$p" ]] && paths+=("projects/$p/")
            done <<< "$proj_list"
        fi
        if [[ -n "$pack_list" ]]; then
            while IFS= read -r p; do
                [[ -n "$p" ]] && paths+=("packs/$p/")
            done <<< "$pack_list"
        fi

        # Shared packs (not in profile's exclusive list)
        if [[ -d "$vault_dir/packs" ]]; then
            for pack_dir in "$vault_dir"/packs/*/; do
                [[ ! -d "$pack_dir" ]] && continue
                local pack_name
                pack_name=$(basename "$pack_dir")
                local is_exclusive=false
                if [[ -n "$pack_list" ]]; then
                    while IFS= read -r ep; do
                        [[ "$ep" == "$pack_name" ]] && is_exclusive=true && break
                    done <<< "$pack_list"
                fi
                if ! $is_exclusive; then
                    paths+=("packs/$pack_name/")
                fi
            done
        fi

        git -C "$vault_dir" add -A -- "${paths[@]}"

        # Check if anything was actually staged (changes may be outside profile scope)
        if git -C "$vault_dir" diff --cached --quiet 2>/dev/null; then
            info "No changes in profile scope — nothing to commit"
            return 0
        fi
    else
        # Without profile: stage everything (backward compatible)
        git -C "$vault_dir" add -A
    fi

    git -C "$vault_dir" commit -q -m "vault: $message"
    ok "Committed: vault: $message"
}

cmd_vault_diff() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                cat <<'EOF'
Usage: cco vault diff

Show uncommitted changes in the vault, grouped by category.
EOF
                return 0
                ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    _check_vault

    local vault_dir="$USER_CONFIG_DIR"
    local status_output
    status_output=$(git -C "$vault_dir" status --short 2>/dev/null)

    if [[ -z "$status_output" ]]; then
        ok "No uncommitted changes"
        return 0
    fi

    # If a profile is active, filter diff output to profile-scoped paths
    local profile
    profile=$(_get_active_profile)
    if [[ -n "$profile" ]]; then
        local proj_list pack_list
        proj_list=$(_profile_projects)
        pack_list=$(_profile_packs)

        local filtered_output=""
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local file="${line:3}"
            local in_scope=false
            case "$file" in
                global/*|templates/*|.gitignore|manifest.yml|.vault-profile)
                    in_scope=true ;;
                projects/*)
                    if [[ -n "$proj_list" ]]; then
                        local proj_name="${file#projects/}"
                        proj_name="${proj_name%%/*}"
                        while IFS= read -r p; do
                            [[ "$p" == "$proj_name" ]] && in_scope=true && break
                        done <<< "$proj_list"
                    fi
                    ;;
                packs/*)
                    # Both exclusive (owned by this profile) and shared packs are in scope
                    in_scope=true
                    ;;
            esac
            if $in_scope; then
                filtered_output+="$line"$'\n'
            fi
        done <<< "$status_output"

        if [[ -z "$filtered_output" ]]; then
            ok "No uncommitted changes in profile scope"
            return 0
        fi
        status_output="$filtered_output"
    fi

    # Group by category
    local packs="" projects="" global_files="" templates="" other=""
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local file="${line:3}"
        case "$file" in
            packs/*)     packs+="$line"$'\n' ;;
            projects/*)  projects+="$line"$'\n' ;;
            global/*)    global_files+="$line"$'\n' ;;
            templates/*) templates+="$line"$'\n' ;;
            *)           other+="$line"$'\n' ;;
        esac
    done <<< "$status_output"

    if [[ -n "$packs" ]]; then
        echo -e "${BOLD}Packs:${NC}"
        printf '%s' "$packs" | sed 's/^/  /'
    fi
    if [[ -n "$projects" ]]; then
        echo -e "${BOLD}Projects:${NC}"
        printf '%s' "$projects" | sed 's/^/  /'
    fi
    if [[ -n "$global_files" ]]; then
        echo -e "${BOLD}Global:${NC}"
        printf '%s' "$global_files" | sed 's/^/  /'
    fi
    if [[ -n "$templates" ]]; then
        echo -e "${BOLD}Templates:${NC}"
        printf '%s' "$templates" | sed 's/^/  /'
    fi
    if [[ -n "$other" ]]; then
        echo -e "${BOLD}Other:${NC}"
        printf '%s' "$other" | sed 's/^/  /'
    fi
}

cmd_vault_log() {
    local limit=20

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --limit)
                [[ -z "${2:-}" ]] && die "--limit requires a number"
                limit="$2"; shift 2
                ;;
            --help)
                cat <<'EOF'
Usage: cco vault log [--limit N]

Show vault commit history (default: last 20 commits).
EOF
                return 0
                ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    _check_vault
    git -C "$USER_CONFIG_DIR" log --oneline -n "$limit"
}

cmd_vault_restore() {
    local ref=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                cat <<'EOF'
Usage: cco vault restore <ref>

Restore configuration to a previous state (does not move HEAD).
EOF
                return 0
                ;;
            -*) die "Unknown option: $1" ;;
            *)
                if [[ -z "$ref" ]]; then
                    ref="$1"; shift
                else
                    die "Unexpected argument: $1"
                fi
                ;;
        esac
    done

    [[ -z "$ref" ]] && die "Usage: cco vault restore <ref>"

    _check_vault

    local vault_dir="$USER_CONFIG_DIR"

    # Verify ref exists
    if ! git -C "$vault_dir" rev-parse --verify "$ref" >/dev/null 2>&1; then
        die "Invalid ref: $ref"
    fi

    # Show what would change
    local diff_output
    diff_output=$(git -C "$vault_dir" diff --stat "$ref" -- . 2>/dev/null || true)
    if [[ -z "$diff_output" ]]; then
        ok "No differences from $ref — nothing to restore"
        return 0
    fi

    echo -e "${BOLD}Files that would be restored from $ref:${NC}"
    echo "$diff_output" | sed 's/^/  /'

    # Confirmation
    if [[ -t 0 ]]; then
        printf "\nRestore these files? [y/N] " >&2
        local reply
        read -r reply
        if [[ ! "$reply" =~ ^[Yy]$ ]]; then
            info "Aborted"
            return 0
        fi
    else
        die "Restore requires interactive confirmation (tty)"
    fi

    git -C "$vault_dir" checkout "$ref" -- .
    ok "Restored files from $ref"
}

cmd_vault_remote() {
    local subcmd="${1:-}"
    [[ -z "$subcmd" ]] && die "Usage: cco vault remote add <name> <url>"
    shift

    # Handle --help before vault check
    if [[ "$subcmd" == "--help" ]]; then
        cat <<'EOF'
Usage: cco vault remote <add|remove> <name> [<url>]

Manage vault git remotes.
Note: 'cco remote' is the preferred way to manage remotes.
EOF
        return 0
    fi

    _check_vault

    # Delegate to cco remote for add/remove (keeps .cco/remotes in sync)
    case "$subcmd" in
        add)    _cmd_remote_add "$@" ;;
        remove) _cmd_remote_remove "$@" ;;
        *)
            # Pass through to git remote for other subcommands
            git -C "$USER_CONFIG_DIR" remote "$subcmd" "$@"
            ;;
    esac
}

cmd_vault_push() {
    local remote=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                cat <<'EOF'
Usage: cco vault push [<remote>]

Push vault commits to a remote (default: origin).
With an active profile, also syncs shared resources to the default branch.
EOF
                return 0
                ;;
            -*) die "Unknown option: $1" ;;
            *)  remote="$1"; shift ;;
        esac
    done

    _check_vault
    remote="${remote:-origin}"

    local vault_dir="$USER_CONFIG_DIR"
    local branch
    branch=$(git -C "$vault_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)

    # Step 1: Push current branch
    git -C "$vault_dir" push -u "$remote" "$branch"
    ok "Pushed to $remote/$branch"

    # Step 2: If on a profile branch, sync shared resources to default branch
    local profile
    profile=$(_get_active_profile)
    if [[ -n "$profile" ]]; then
        _sync_shared_to_default "$vault_dir" "$remote" "$branch"
    fi
}

cmd_vault_pull() {
    local remote=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                cat <<'EOF'
Usage: cco vault pull [<remote>]

Pull vault updates from a remote (default: origin).
With an active profile, also syncs shared resources from the default branch.
EOF
                return 0
                ;;
            -*) die "Unknown option: $1" ;;
            *)  remote="$1"; shift ;;
        esac
    done

    _check_vault
    remote="${remote:-origin}"

    local vault_dir="$USER_CONFIG_DIR"
    local profile
    profile=$(_get_active_profile)

    if [[ -n "$profile" ]]; then
        # With profile: fetch first, then pull, then sync shared
        if ! git -C "$vault_dir" fetch "$remote" 2>/dev/null; then
            warn "Failed to fetch from $remote (network error?)"
        fi
    fi

    # Verify remote exists
    if ! git -C "$vault_dir" remote get-url "$remote" >/dev/null 2>&1; then
        die "Remote '$remote' not configured. Run 'cco vault remote add $remote <url>' first."
    fi

    # Pull current branch (verify branch exists on remote first)
    local branch
    branch=$(git -C "$vault_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
    if ! git -C "$vault_dir" ls-remote --heads "$remote" "$branch" 2>/dev/null | grep -q .; then
        info "Branch '$branch' not found on remote. Push first with 'cco vault push'."
        return 0
    fi
    if ! git -C "$vault_dir" pull "$remote" "$branch"; then
        warn "Failed to pull '$branch' from $remote"
        return 1
    fi

    # If on a profile branch, sync shared resources from default branch
    if [[ -n "$profile" ]]; then
        _sync_shared_from_default "$vault_dir" "$remote"
    fi
}

cmd_vault_status() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                cat <<'EOF'
Usage: cco vault status

Show vault initialization state, remote sync status, and uncommitted changes.
EOF
                return 0
                ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    local vault_dir="$USER_CONFIG_DIR"

    # Check initialized
    if [[ ! -d "$vault_dir/.git" ]]; then
        echo -e "${BOLD}Vault:${NC} not initialized"
        info "Run 'cco vault init' to enable versioning"
        return 0
    fi

    echo -e "${BOLD}Vault:${NC} initialized at $vault_dir"

    # Branch and profile
    local branch
    branch=$(git -C "$vault_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)

    local profile
    profile=$(_get_active_profile)
    if [[ -n "$profile" ]]; then
        echo "  Profile: $profile (branch: $branch)"

        # Shared sync state
        local default_branch
        default_branch=$(_vault_default_branch)
        local behind_count ahead_count
        behind_count=$(git -C "$vault_dir" rev-list --count "HEAD..$default_branch" 2>/dev/null || echo "?")
        ahead_count=$(git -C "$vault_dir" rev-list --count "$default_branch..HEAD" 2>/dev/null || echo "?")
        if [[ "$behind_count" == "0" && "$ahead_count" == "0" ]] 2>/dev/null; then
            echo "  Shared sync: up-to-date with $default_branch"
        elif [[ "$behind_count" != "?" && "$ahead_count" != "?" ]]; then
            echo "  Shared sync: $ahead_count ahead, $behind_count behind $default_branch"
        else
            echo "  Shared sync: unknown"
        fi

        # Exclusive resource counts
        local excl_proj_count=0 excl_pack_count=0
        local proj_list pack_list
        proj_list=$(_profile_projects)
        pack_list=$(_profile_packs)
        if [[ -n "$proj_list" ]]; then
            excl_proj_count=$(echo "$proj_list" | grep -c . || true)
        fi
        if [[ -n "$pack_list" ]]; then
            excl_pack_count=$(echo "$pack_list" | grep -c . || true)
        fi
        echo "  Exclusive: $excl_proj_count project(s), $excl_pack_count pack(s)"
    else
        echo "  Branch: $branch"
    fi

    # Remotes
    local remotes
    remotes=$(git -C "$vault_dir" remote -v 2>/dev/null | head -4)
    if [[ -n "$remotes" ]]; then
        echo -e "  ${BOLD}Remotes:${NC}"
        echo "$remotes" | sed 's/^/    /'
    else
        echo "  Remotes: (none)"
    fi

    # Uncommitted changes
    local status_output
    status_output=$(git -C "$vault_dir" status --porcelain 2>/dev/null)
    if [[ -z "$status_output" ]]; then
        echo "  Changes: none (clean)"
    else
        local count
        count=$(echo "$status_output" | grep -c . || true)
        echo "  Changes: $count uncommitted file(s)"
    fi

    # Commits
    local commit_count
    commit_count=$(git -C "$vault_dir" rev-list --count HEAD 2>/dev/null || echo "0")
    echo "  Commits: $commit_count"
}

# ── Profile management ───────────────────────────────────────────────

VAULT_PROFILE_FILE="$USER_CONFIG_DIR/.vault-profile"

# Get active profile name (empty string if on main / no profile)
_get_active_profile() {
    local branch default_branch
    branch=$(git -C "$USER_CONFIG_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)
    default_branch=$(_vault_default_branch)
    if [[ "$branch" != "$default_branch" ]] && [[ -f "$VAULT_PROFILE_FILE" ]]; then
        yml_get "$VAULT_PROFILE_FILE" "profile"
    fi
}

# Validate profile name: lowercase, hyphens, numbers, no spaces
_validate_profile_name() {
    local name="$1"
    if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
        die "Invalid profile name '$name': must be lowercase letters, numbers, and hyphens only"
    fi
    if [[ "$name" == "main" || "$name" == "master" ]]; then
        die "Cannot use '$name' as a profile name (reserved for shared resources)"
    fi
}

# Write .vault-profile file
_write_vault_profile() {
    local name="$1"
    local profile_file="$USER_CONFIG_DIR/.vault-profile"
    local projects_yaml="" packs_yaml=""

    # Read existing lists if file exists
    if [[ -f "$profile_file" ]]; then
        projects_yaml=$(yml_get_list "$profile_file" "sync.projects" 2>/dev/null || true)
        packs_yaml=$(yml_get_list "$profile_file" "sync.packs" 2>/dev/null || true)
    fi

    {
        echo "# Vault profile — tracked on this branch"
        echo "# Defines which resources are exclusive to this profile"
        echo "profile: $name"
        echo "sync:"
        echo "  projects:"
        if [[ -n "$projects_yaml" ]]; then
            while IFS= read -r p; do
                [[ -n "$p" ]] && echo "    - $p"
            done <<< "$projects_yaml"
        else
            echo "    []"
        fi
        echo "  packs:"
        if [[ -n "$packs_yaml" ]]; then
            while IFS= read -r p; do
                [[ -n "$p" ]] && echo "    - $p"
            done <<< "$packs_yaml"
        else
            echo "    []"
        fi
    } > "$profile_file"
}

# Auto-commit pending changes (used before branch switches)
_vault_auto_commit() {
    local vault_dir="$USER_CONFIG_DIR"
    local status_output
    status_output=$(git -C "$vault_dir" status --porcelain 2>/dev/null)
    if [[ -n "$status_output" ]]; then
        # Secret detection — scan changed files for secret patterns before staging
        local secret_found=false
        local -a safe_files=()
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local file="${line:3}"
            local is_secret=false
            local basename_file
            basename_file=$(basename "$file")
            for pattern in "${_VAULT_SECRET_PATTERNS[@]}"; do
                if [[ "$basename_file" == $pattern || "$file" == *"$pattern" ]]; then
                    is_secret=true
                    break
                fi
            done
            if $is_secret; then
                secret_found=true
                warn "Secret file detected in auto-commit, skipping: $file"
            else
                safe_files+=("$file")
            fi
        done <<< "$status_output"

        if $secret_found && [[ ${#safe_files[@]} -eq 0 ]]; then
            warn "Auto-commit skipped: only secret files detected"
            return 0
        fi

        if $secret_found; then
            # Stage only non-secret files
            git -C "$vault_dir" add -A -- "${safe_files[@]}"
        else
            git -C "$vault_dir" add -A
        fi
        git -C "$vault_dir" commit -q -m "vault: auto-save before branch change"
        info "Auto-committed pending changes"
    fi
}

# List profile-exclusive projects from .vault-profile
_profile_projects() {
    [[ -f "$VAULT_PROFILE_FILE" ]] || return 0
    yml_get_list "$VAULT_PROFILE_FILE" "sync.projects" 2>/dev/null || true
}

# List profile-exclusive packs from .vault-profile
_profile_packs() {
    [[ -f "$VAULT_PROFILE_FILE" ]] || return 0
    yml_get_list "$VAULT_PROFILE_FILE" "sync.packs" 2>/dev/null || true
}

# Add an item to a list in .vault-profile (projects or packs)
_profile_add_to_list() {
    local list_name="$1" item="$2"
    local profile_file="$VAULT_PROFILE_FILE"
    [[ ! -f "$profile_file" ]] && die "No active profile"

    local profile_name
    profile_name=$(yml_get "$profile_file" "profile")

    # Read current lists
    local projects packs
    projects=$(yml_get_list "$profile_file" "sync.projects" 2>/dev/null || true)
    packs=$(yml_get_list "$profile_file" "sync.packs" 2>/dev/null || true)

    # Add item to the appropriate list
    if [[ "$list_name" == "projects" ]]; then
        # Check not already present
        if [[ -n "$projects" ]] && echo "$projects" | grep -qxF "$item"; then
            return 0  # already present
        fi
        if [[ -n "$projects" ]]; then
            projects="$projects"$'\n'"$item"
        else
            projects="$item"
        fi
    elif [[ "$list_name" == "packs" ]]; then
        if [[ -n "$packs" ]] && echo "$packs" | grep -qxF "$item"; then
            return 0
        fi
        if [[ -n "$packs" ]]; then
            packs="$packs"$'\n'"$item"
        else
            packs="$item"
        fi
    fi

    # Rewrite the file
    {
        echo "# Vault profile — tracked on this branch"
        echo "# Defines which resources are exclusive to this profile"
        echo "profile: $profile_name"
        echo "sync:"
        echo "  projects:"
        if [[ -n "$projects" ]]; then
            while IFS= read -r p; do
                [[ -n "$p" ]] && echo "    - $p"
            done <<< "$projects"
        else
            echo "    []"
        fi
        echo "  packs:"
        if [[ -n "$packs" ]]; then
            while IFS= read -r p; do
                [[ -n "$p" ]] && echo "    - $p"
            done <<< "$packs"
        else
            echo "    []"
        fi
    } > "$profile_file"
}

# Remove an item from a list in .vault-profile
_profile_remove_from_list() {
    local list_name="$1" item="$2"
    local profile_file="$VAULT_PROFILE_FILE"
    [[ ! -f "$profile_file" ]] && die "No active profile"

    local profile_name
    profile_name=$(yml_get "$profile_file" "profile")

    local projects packs
    projects=$(yml_get_list "$profile_file" "sync.projects" 2>/dev/null || true)
    packs=$(yml_get_list "$profile_file" "sync.packs" 2>/dev/null || true)

    if [[ "$list_name" == "projects" ]]; then
        projects=$(echo "$projects" | grep -vxF "$item" || true)
    elif [[ "$list_name" == "packs" ]]; then
        packs=$(echo "$packs" | grep -vxF "$item" || true)
    fi

    {
        echo "# Vault profile — tracked on this branch"
        echo "# Defines which resources are exclusive to this profile"
        echo "profile: $profile_name"
        echo "sync:"
        echo "  projects:"
        if [[ -n "$projects" ]]; then
            while IFS= read -r p; do
                [[ -n "$p" ]] && echo "    - $p"
            done <<< "$projects"
        else
            echo "    []"
        fi
        echo "  packs:"
        if [[ -n "$packs" ]]; then
            while IFS= read -r p; do
                [[ -n "$p" ]] && echo "    - $p"
            done <<< "$packs"
        else
            echo "    []"
        fi
    } > "$profile_file"
}

cmd_vault_profile() {
    local subcmd="${1:-}"
    if [[ -z "$subcmd" || "$subcmd" == "--help" ]]; then
        cat <<'EOF'
Usage: cco vault profile <command>

Manage vault profiles for multi-PC selective sync.

Commands:
  create <name>      Create a new profile (branch from main)
  list               List all profiles
  show               Show current profile details
  switch <name>      Switch to another profile
  rename <new-name>  Rename current profile
  delete <name>      Delete a profile (moves resources to main)
  add <type> <name>  Add a project/pack to current profile
  remove <type> <n>  Remove a project/pack from current profile
  move <type> <name> --to <target>  Move a resource between profiles

Run 'cco vault profile <command> --help' for command-specific options.
EOF
        return 0
    fi
    shift

    case "$subcmd" in
        create) cmd_vault_profile_create "$@" ;;
        list)   cmd_vault_profile_list "$@" ;;
        show)   cmd_vault_profile_show "$@" ;;
        switch) cmd_vault_profile_switch "$@" ;;
        rename) cmd_vault_profile_rename "$@" ;;
        delete) cmd_vault_profile_delete "$@" ;;
        add)    cmd_vault_profile_add "$@" ;;
        remove) cmd_vault_profile_remove "$@" ;;
        move)   cmd_vault_profile_move "$@" ;;
        *)      die "Unknown profile command: $subcmd. Run 'cco vault profile --help'." ;;
    esac
}

cmd_vault_profile_create() {
    local name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                cat <<'EOF'
Usage: cco vault profile create <name>

Create a new vault profile. This creates a git branch from main and
writes a .vault-profile configuration file.

A profile is a work context (e.g., org-a, personal) — not a machine identity.
Any machine can use any profile by switching to it.
EOF
                return 0
                ;;
            -*) die "Unknown option: $1" ;;
            *)
                if [[ -z "$name" ]]; then
                    name="$1"; shift
                else
                    die "Unexpected argument: $1"
                fi
                ;;
        esac
    done

    [[ -z "$name" ]] && die "Usage: cco vault profile create <name>"

    _check_vault
    _validate_profile_name "$name"

    local vault_dir="$USER_CONFIG_DIR"

    # Check branch doesn't already exist
    if git -C "$vault_dir" rev-parse --verify "$name" >/dev/null 2>&1; then
        die "Profile '$name' already exists"
    fi

    # Auto-commit pending changes
    _vault_auto_commit

    # Create branch from default branch (main or master)
    local default_branch
    default_branch=$(_vault_default_branch)
    git -C "$vault_dir" checkout -b "$name" "$default_branch" -q
    _write_vault_profile "$name"
    git -C "$vault_dir" add -A -- .vault-profile
    git -C "$vault_dir" commit -q -m "vault: create profile '$name'"

    ok "Profile '$name' created"
    info "Use 'cco vault profile add project <name>' to add resources"
}

cmd_vault_profile_list() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                cat <<'EOF'
Usage: cco vault profile list

List all vault profiles with their resource counts.
EOF
                return 0
                ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    _check_vault

    local vault_dir="$USER_CONFIG_DIR"
    local current_branch
    current_branch=$(git -C "$vault_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)

    # Collect branches that have .vault-profile
    local has_profiles=false

    echo -e "${BOLD}Vault profiles:${NC}"

    while IFS= read -r branch; do
        [[ -z "$branch" ]] && continue
        branch=$(echo "$branch" | sed 's/^[ *]*//')
        local _default_branch
        _default_branch=$(_vault_default_branch)
        [[ "$branch" == "$_default_branch" ]] && continue

        # Check if branch has .vault-profile
        if git -C "$vault_dir" show "$branch:.vault-profile" >/dev/null 2>&1; then
            has_profiles=true
            local marker="  "
            [[ "$branch" == "$current_branch" ]] && marker="* "

            # Count resources from .vault-profile on that branch
            local proj_count=0 pack_count=0
            local profile_content
            profile_content=$(git -C "$vault_dir" show "$branch:.vault-profile" 2>/dev/null || true)
            if [[ -n "$profile_content" ]]; then
                proj_count=$(echo "$profile_content" | grep -c '^\s*- ' 2>/dev/null || true)
                # More precise: count under projects section
                proj_count=$(echo "$profile_content" | awk '
                    /^  projects:/ { in_proj=1; next }
                    /^  packs:/ { in_proj=0; in_pack=1; next }
                    /^[^ ]/ { in_proj=0; in_pack=0 }
                    in_proj && /^    - / { pc++ }
                    in_pack && /^    - / { kc++ }
                    END { print pc+0 }
                ')
                pack_count=$(echo "$profile_content" | awk '
                    /^  packs:/ { in_pack=1; next }
                    /^[^ ]/ { in_pack=0 }
                    in_pack && /^    - / { kc++ }
                    END { print kc+0 }
                ')
            fi

            local active_label=""
            [[ "$branch" == "$current_branch" ]] && active_label=" (active)"

            printf "  %s%-20s %d project(s), %d pack(s)%s\n" \
                "$marker" "$branch" "$proj_count" "$pack_count" "$active_label"
        fi
    done < <(git -C "$vault_dir" branch 2>/dev/null)

    if ! $has_profiles; then
        echo "  (no profiles — vault uses main branch only)"
        echo ""
        info "Create a profile with: cco vault profile create <name>"
    fi

    # Show main summary
    echo ""
    local main_packs=0 main_templates=0
    [[ -d "$vault_dir/packs" ]] && main_packs=$(find "$vault_dir/packs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    [[ -d "$vault_dir/templates" ]] && main_templates=$(find "$vault_dir/templates" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    echo -e "  ${BOLD}Main (shared):${NC} global, ${main_templates} template(s), ${main_packs} pack(s)"
}

cmd_vault_profile_show() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                cat <<'EOF'
Usage: cco vault profile show

Show details of the current active profile.
EOF
                return 0
                ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    _check_vault

    local vault_dir="$USER_CONFIG_DIR"
    local profile
    profile=$(_get_active_profile)

    if [[ -z "$profile" ]]; then
        echo -e "${BOLD}Profile:${NC} (none — on main branch)"
        echo "  All resources are shared. Create a profile for selective sync."
        return 0
    fi

    local branch
    branch=$(git -C "$vault_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)

    echo -e "${BOLD}Profile:${NC} $profile"
    echo "  Branch: $branch"

    # Sync state with default branch
    local default_branch
    default_branch=$(_vault_default_branch)
    local behind ahead
    behind=$(git -C "$vault_dir" rev-list --count "HEAD..origin/$default_branch" 2>/dev/null || echo "?")
    ahead=$(git -C "$vault_dir" rev-list --count "origin/$default_branch..HEAD" 2>/dev/null || echo "?")
    if [[ "$behind" == "0" && "$ahead" == "0" ]] 2>/dev/null; then
        echo "  Sync state: up-to-date with main"
    elif [[ "$behind" != "?" && "$ahead" != "?" ]]; then
        echo "  Sync state: $ahead ahead, $behind behind main"
    else
        echo "  Sync state: unknown (no remote tracking)"
    fi

    # Exclusive projects
    local projects
    projects=$(_profile_projects)
    if [[ -n "$projects" ]]; then
        echo ""
        echo -e "  ${BOLD}Exclusive projects:${NC}"
        while IFS= read -r p; do
            [[ -n "$p" ]] && echo "    - $p"
        done <<< "$projects"
    fi

    # Exclusive packs
    local packs
    packs=$(_profile_packs)
    if [[ -n "$packs" ]]; then
        echo ""
        echo -e "  ${BOLD}Exclusive packs:${NC}"
        while IFS= read -r p; do
            [[ -n "$p" ]] && echo "    - $p"
        done <<< "$packs"
    fi

    # Shared resources
    echo ""
    echo -e "  ${BOLD}Shared (from main):${NC}"
    echo "    - global/"
    local template_count=0 pack_count=0
    [[ -d "$vault_dir/templates" ]] && template_count=$(find "$vault_dir/templates" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    echo "    - templates/ ($template_count template(s))"
    # Count shared packs (not in profile's exclusive list)
    local exclusive_packs
    exclusive_packs=$(_profile_packs)
    local total_packs=0 exclusive_pack_count=0
    if [[ -d "$vault_dir/packs" ]]; then
        total_packs=$(find "$vault_dir/packs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
        if [[ -n "$exclusive_packs" ]]; then
            exclusive_pack_count=$(echo "$exclusive_packs" | grep -c . || true)
        fi
    fi
    local shared_packs=$((total_packs - exclusive_pack_count))
    echo "    - packs/ ($shared_packs shared pack(s))"

    # Uncommitted changes
    echo ""
    local status_output
    status_output=$(git -C "$vault_dir" status --porcelain 2>/dev/null)
    if [[ -z "$status_output" ]]; then
        echo "  Uncommitted changes: none"
    else
        local count
        count=$(echo "$status_output" | grep -c . || true)
        echo "  Uncommitted changes: $count file(s)"
    fi
}

cmd_vault_profile_switch() {
    local name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                cat <<'EOF'
Usage: cco vault profile switch <name>

Switch to another vault profile. Auto-commits pending changes before switching.
Use 'main' to switch back to the shared branch (no profile).
EOF
                return 0
                ;;
            -*) die "Unknown option: $1" ;;
            *)
                if [[ -z "$name" ]]; then
                    name="$1"; shift
                else
                    die "Unexpected argument: $1"
                fi
                ;;
        esac
    done

    [[ -z "$name" ]] && die "Usage: cco vault profile switch <name>"

    _check_vault

    local vault_dir="$USER_CONFIG_DIR"
    local current_branch
    current_branch=$(git -C "$vault_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)

    if [[ "$name" == "$current_branch" ]]; then
        info "Already on profile '$name'"
        return 0
    fi

    # Verify target branch exists
    if ! git -C "$vault_dir" rev-parse --verify "$name" >/dev/null 2>&1; then
        die "Profile '$name' not found. Run 'cco vault profile list' to see available profiles."
    fi

    # Auto-commit pending changes
    _vault_auto_commit

    git -C "$vault_dir" checkout "$name" -q
    ok "Switched to profile '$name'"
}

cmd_vault_profile_rename() {
    local new_name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                cat <<'EOF'
Usage: cco vault profile rename <new-name>

Rename the current active profile.
EOF
                return 0
                ;;
            -*) die "Unknown option: $1" ;;
            *)
                if [[ -z "$new_name" ]]; then
                    new_name="$1"; shift
                else
                    die "Unexpected argument: $1"
                fi
                ;;
        esac
    done

    [[ -z "$new_name" ]] && die "Usage: cco vault profile rename <new-name>"

    _check_vault

    local profile
    profile=$(_get_active_profile)
    [[ -z "$profile" ]] && die "No active profile. Switch to a profile first."

    _validate_profile_name "$new_name"

    local vault_dir="$USER_CONFIG_DIR"

    # Check new name doesn't exist
    if git -C "$vault_dir" rev-parse --verify "$new_name" >/dev/null 2>&1; then
        die "Branch '$new_name' already exists"
    fi

    local old_name="$profile"

    # Rename branch
    git -C "$vault_dir" branch -m "$old_name" "$new_name" -q

    # Update .vault-profile
    _write_vault_profile "$new_name"
    git -C "$vault_dir" add -A -- .vault-profile
    git -C "$vault_dir" commit -q -m "vault: rename profile '$old_name' to '$new_name'"

    # Update remote if exists
    if git -C "$vault_dir" remote get-url origin >/dev/null 2>&1; then
        info "Remote tracking updated. Push with: cco vault push"
    fi

    ok "Profile renamed from '$old_name' to '$new_name'"
}

cmd_vault_profile_delete() {
    local name="" auto_yes=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes|-y) auto_yes=true; shift ;;
            --help)
                cat <<'EOF'
Usage: cco vault profile delete <name> [--yes]

Delete a vault profile. Moves all exclusive resources to main first.
Cannot delete the currently active profile.

Options:
  --yes, -y   Skip confirmation prompt
EOF
                return 0
                ;;
            -*) die "Unknown option: $1" ;;
            *)
                if [[ -z "$name" ]]; then
                    name="$1"; shift
                else
                    die "Unexpected argument: $1"
                fi
                ;;
        esac
    done

    [[ -z "$name" ]] && die "Usage: cco vault profile delete <name>"

    _check_vault

    local vault_dir="$USER_CONFIG_DIR"
    local current_branch
    current_branch=$(git -C "$vault_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)

    if [[ "$name" == "$current_branch" ]]; then
        die "Cannot delete active profile. Switch to another profile or main first."
    fi

    # Verify branch exists and has .vault-profile
    if ! git -C "$vault_dir" rev-parse --verify "$name" >/dev/null 2>&1; then
        die "Profile '$name' not found"
    fi

    # Confirmation
    if ! $auto_yes; then
        if [[ -t 0 ]]; then
            warn "All exclusive resources will be moved to main."
            printf "Delete profile '$name'? [y/N] " >&2
            local reply
            read -r reply
            if [[ ! "$reply" =~ ^[Yy]$ ]]; then
                info "Aborted"
                return 0
            fi
        else
            die "Profile delete requires interactive confirmation (use --yes to skip)"
        fi
    fi

    # Read exclusive resources from the profile branch
    local profile_content
    profile_content=$(git -C "$vault_dir" show "$name:.vault-profile" 2>/dev/null || true)

    if [[ -n "$profile_content" ]]; then
        # Get exclusive project and pack names
        local excl_projects excl_packs
        excl_projects=$(echo "$profile_content" | awk '
            /^  projects:/ { in_proj=1; next }
            /^  packs:/ { in_proj=0 }
            /^[^ ]/ { in_proj=0 }
            in_proj && /^    - / { sub(/^    - */, ""); print }
        ')
        excl_packs=$(echo "$profile_content" | awk '
            /^  packs:/ { in_pack=1; next }
            /^[^ ]/ { in_pack=0 }
            in_pack && /^    - / { sub(/^    - */, ""); print }
        ')

        # Move exclusive resources to default branch
        # Strategy: checkout default branch once, copy all resources from profile
        # branch, commit, then return. We must commit BEFORE checking back out,
        # otherwise the checkout resets the index and loses staged additions.
        local _default_branch
        _default_branch=$(_vault_default_branch)
        local moved=0

        # Collect resource paths to move
        local -a move_paths=()
        if [[ -n "$excl_projects" ]]; then
            while IFS= read -r proj; do
                [[ -z "$proj" ]] && continue
                if git -C "$vault_dir" ls-tree "$name" -- "projects/$proj/" >/dev/null 2>&1; then
                    move_paths+=("projects/$proj/")
                    ((moved++)) || true
                fi
            done <<< "$excl_projects"
        fi
        if [[ -n "$excl_packs" ]]; then
            while IFS= read -r pack; do
                [[ -z "$pack" ]] && continue
                if git -C "$vault_dir" ls-tree "$name" -- "packs/$pack/" >/dev/null 2>&1; then
                    move_paths+=("packs/$pack/")
                    ((moved++)) || true
                fi
            done <<< "$excl_packs"
        fi

        if [[ $moved -gt 0 ]]; then
            git -C "$vault_dir" checkout "$_default_branch" -q
            # Copy each resource from the profile branch
            for rpath in "${move_paths[@]}"; do
                git -C "$vault_dir" checkout "$name" -- "$rpath" 2>/dev/null || true
            done
            git -C "$vault_dir" add -A -- "${move_paths[@]}" 2>/dev/null || true
            # Commit on default branch; skip if nothing was actually staged
            if ! git -C "$vault_dir" diff --cached --quiet 2>/dev/null; then
                git -C "$vault_dir" commit -q -m "vault: move resources from deleted profile '$name'"
            fi
        fi
        # ALWAYS restore original branch regardless of whether resources were moved
        git -C "$vault_dir" checkout "$current_branch" -q
    fi

    # Delete branch
    git -C "$vault_dir" branch -D "$name" -q 2>/dev/null

    # Delete remote branch if exists
    if git -C "$vault_dir" remote get-url origin >/dev/null 2>&1; then
        git -C "$vault_dir" push origin --delete "$name" -q 2>/dev/null || true
    fi

    ok "Profile '$name' deleted"
}

# ── Profile resource management (add/remove/move) ───────────────────

# Design note: profile add/remove/move update .vault-profile tracking only.
# Git-level isolation (git rm from source branch) is NOT enforced — resources
# remain on all branches. Selective sync is handled at commit/push/pull time
# by scoping operations to the profile's declared paths.

cmd_vault_profile_add() {
    local resource_type="${1:-}"
    local name="${2:-}"

    if [[ "$resource_type" == "--help" || -z "$resource_type" ]]; then
        cat <<'EOF'
Usage: cco vault profile add <project|pack> <name>

Assign an existing project or pack to the current profile (marks it as exclusive).
Note: isolation is tracking-only via .vault-profile — the resource is NOT git rm-ed
from the default branch. Use 'vault sync' to commit profile-scoped changes.
EOF
        return 0
    fi

    [[ -z "$name" ]] && die "Usage: cco vault profile add <project|pack> <name>"
    [[ "$resource_type" != "project" && "$resource_type" != "pack" ]] && \
        die "Resource type must be 'project' or 'pack'"

    _check_vault

    local profile
    profile=$(_get_active_profile)
    [[ -z "$profile" ]] && die "No active profile. Switch to a profile first."

    local vault_dir="$USER_CONFIG_DIR"
    local resource_path
    if [[ "$resource_type" == "project" ]]; then
        resource_path="projects/$name"
        [[ ! -d "$vault_dir/$resource_path" ]] && die "Project '$name' not found"
        _profile_add_to_list "projects" "$name"
    else
        resource_path="packs/$name"
        [[ ! -d "$vault_dir/$resource_path" ]] && die "Pack '$name' not found"
        _profile_add_to_list "packs" "$name"
    fi

    # Stage and commit (skip if nothing actually changed)
    git -C "$vault_dir" add -A -- "$resource_path/" .vault-profile
    if ! git -C "$vault_dir" diff --cached --quiet 2>/dev/null; then
        git -C "$vault_dir" commit -q -m "vault: add $resource_type '$name' to profile '$profile'"
    fi

    ok "Added $resource_type '$name' to profile '$profile'"
}

cmd_vault_profile_remove() {
    local resource_type="${1:-}"
    local name="${2:-}"

    if [[ "$resource_type" == "--help" || -z "$resource_type" ]]; then
        cat <<'EOF'
Usage: cco vault profile remove <project|pack> <name>

Unassign a project or pack from the current profile (makes it shared again).
Note: isolation is tracking-only via .vault-profile — the resource remains on disk.
EOF
        return 0
    fi

    [[ -z "$name" ]] && die "Usage: cco vault profile remove <project|pack> <name>"
    [[ "$resource_type" != "project" && "$resource_type" != "pack" ]] && \
        die "Resource type must be 'project' or 'pack'"

    _check_vault

    local profile
    profile=$(_get_active_profile)
    [[ -z "$profile" ]] && die "No active profile. Switch to a profile first."

    if [[ "$resource_type" == "project" ]]; then
        _profile_remove_from_list "projects" "$name"
    else
        _profile_remove_from_list "packs" "$name"
    fi

    local vault_dir="$USER_CONFIG_DIR"
    git -C "$vault_dir" add -A -- .vault-profile
    git -C "$vault_dir" commit -q -m "vault: remove $resource_type '$name' from profile '$profile'"

    ok "Removed $resource_type '$name' from profile '$profile'"
    info "The resource is now shared (on the default branch)."
}

cmd_vault_profile_move() {
    local resource_type="${1:-}"
    local name=""
    local target=""

    if [[ "$resource_type" == "--help" || -z "$resource_type" ]]; then
        cat <<'EOF'
Usage: cco vault profile move <project|pack> <name> --to <profile|main>

Move a project or pack to a different profile or to the default branch (main).
EOF
        return 0
    fi

    shift  # consume resource_type

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --to) target="$2"; shift 2 ;;
            --help)
                cat <<'EOF'
Usage: cco vault profile move <project|pack> <name> --to <profile|main>
EOF
                return 0
                ;;
            -*) die "Unknown option: $1" ;;
            *)
                if [[ -z "$name" ]]; then
                    name="$1"; shift
                else
                    die "Unexpected argument: $1"
                fi
                ;;
        esac
    done

    [[ -z "$name" ]] && die "Usage: cco vault profile move <project|pack> <name> --to <target>"
    [[ -z "$target" ]] && die "Missing --to <target>"
    [[ "$resource_type" != "project" && "$resource_type" != "pack" ]] && \
        die "Resource type must be 'project' or 'pack'"

    _check_vault

    local vault_dir="$USER_CONFIG_DIR"
    local default_branch
    default_branch=$(_vault_default_branch)
    local current_branch
    current_branch=$(git -C "$vault_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)

    local resource_path
    if [[ "$resource_type" == "project" ]]; then
        resource_path="projects/$name"
    else
        resource_path="packs/$name"
    fi

    [[ ! -d "$vault_dir/$resource_path" ]] && die "$(echo "$resource_type" | awk '{print toupper(substr($0,1,1)) substr($0,2)}') '$name' not found"

    # Determine if target is default branch or a profile
    local target_is_default=false
    if [[ "$target" == "$default_branch" || "$target" == "main" || "$target" == "master" ]]; then
        target_is_default=true
        target="$default_branch"
    fi

    if ! $target_is_default; then
        # Verify target branch exists
        if ! git -C "$vault_dir" rev-parse --verify "$target" >/dev/null 2>&1; then
            die "Profile '$target' not found"
        fi
    fi

    # Auto-commit pending changes
    _vault_auto_commit

    local profile
    profile=$(_get_active_profile)

    if [[ -n "$profile" ]]; then
        # Remove from current profile's list
        if [[ "$resource_type" == "project" ]]; then
            _profile_remove_from_list "projects" "$name"
        else
            _profile_remove_from_list "packs" "$name"
        fi
        git -C "$vault_dir" add -A -- .vault-profile
        git -C "$vault_dir" commit -q -m "vault: remove $resource_type '$name' from profile '$profile'" 2>/dev/null || true
    fi

    if $target_is_default; then
        # Moving to default branch — copy resource from current branch, stage on default
        git -C "$vault_dir" checkout "$default_branch" -q
        # Checkout directory tree from source branch to ensure files exist on target
        git -C "$vault_dir" checkout "$current_branch" -- "$resource_path/" 2>/dev/null || true
        git -C "$vault_dir" add -A -- "$resource_path/" 2>/dev/null || true
        if ! git -C "$vault_dir" diff --cached --quiet 2>/dev/null; then
            git -C "$vault_dir" commit -q -m "vault: add $resource_type '$name' (moved from profile)"
        fi
        git -C "$vault_dir" checkout "$current_branch" -q
        ok "Moved $resource_type '$name' to $default_branch (shared)"
    else
        # Moving to another profile — copy resource from current branch
        git -C "$vault_dir" checkout "$target" -q
        git -C "$vault_dir" checkout "$current_branch" -- "$resource_path/" 2>/dev/null || true
        git -C "$vault_dir" add -A -- "$resource_path/" 2>/dev/null || true
        _profile_add_to_list "${resource_type}s" "$name"
        git -C "$vault_dir" add -A -- .vault-profile
        if ! git -C "$vault_dir" diff --cached --quiet 2>/dev/null; then
            git -C "$vault_dir" commit -q -m "vault: add $resource_type '$name' to profile '$target'"
        fi
        git -C "$vault_dir" checkout "$current_branch" -q
        ok "Moved $resource_type '$name' to profile '$target'"
    fi
}

# ── Shared resource sync helpers ──────────────────────────────────────

# List shared resource paths (everything NOT exclusive to current profile)
_list_shared_paths() {
    local vault_dir="$1"
    local paths=("global/" "templates/" ".gitignore" "manifest.yml")

    # Shared packs (not in profile's exclusive list)
    local exclusive_packs
    exclusive_packs=$(_profile_packs)
    if [[ -d "$vault_dir/packs" ]]; then
        for pack_dir in "$vault_dir"/packs/*/; do
            [[ ! -d "$pack_dir" ]] && continue
            local pack_name
            pack_name=$(basename "$pack_dir")
            local is_exclusive=false
            if [[ -n "$exclusive_packs" ]]; then
                while IFS= read -r ep; do
                    [[ "$ep" == "$pack_name" ]] && is_exclusive=true && break
                done <<< "$exclusive_packs"
            fi
            if ! $is_exclusive; then
                paths+=("packs/$pack_name/")
            fi
        done
    fi

    printf '%s\n' "${paths[@]}"
}

# Sync shared resources from profile branch to default branch (push direction)
_sync_shared_to_default() {
    local vault_dir="$1" remote="$2" profile_branch="$3"
    local default_branch
    default_branch=$(_vault_default_branch)

    # Find shared files that differ between profile and default branch
    local shared_paths=()
    while IFS= read -r p; do
        [[ -n "$p" ]] && shared_paths+=("$p")
    done < <(_list_shared_paths "$vault_dir")

    [[ ${#shared_paths[@]} -eq 0 ]] && return 0

    local changed_files
    changed_files=$(git -C "$vault_dir" diff "$default_branch" --name-only -- \
        "${shared_paths[@]}" 2>/dev/null || true)

    [[ -z "$changed_files" ]] && return 0

    local file_count
    file_count=$(echo "$changed_files" | grep -c . || true)

    # Stash uncommitted work
    local stashed=false
    if [[ -n "$(git -C "$vault_dir" status --porcelain 2>/dev/null)" ]]; then
        git -C "$vault_dir" stash -q
        stashed=true
    fi

    # Checkout default branch
    git -C "$vault_dir" checkout "$default_branch" -q

    # Pull latest default branch
    if ! git -C "$vault_dir" pull "$remote" "$default_branch" -q 2>/dev/null; then
        warn "Failed to pull $default_branch from $remote (network error or merge conflict)"
        # Return to profile branch before aborting
        git -C "$vault_dir" checkout "$profile_branch" -q 2>/dev/null || true
        if $stashed; then
            git -C "$vault_dir" stash pop -q 2>/dev/null || true
        fi
        return 1
    fi

    # Copy shared files from profile branch
    # Hoist merge-base outside the per-file loop (W4)
    local merge_base
    merge_base=$(git -C "$vault_dir" merge-base "$default_branch" "$profile_branch" 2>/dev/null || true)

    local synced=0
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue

        # Check if file was also modified on default branch
        local modified_on_default=false
        if [[ -n "$merge_base" ]]; then
            local default_diff
            default_diff=$(git -C "$vault_dir" diff "$merge_base" "$default_branch" --name-only -- "$file" 2>/dev/null || true)
            [[ -n "$default_diff" ]] && modified_on_default=true
        fi

        if $modified_on_default; then
            # Both sides modified — interactive conflict resolution
            _resolve_shared_conflict "$vault_dir" "$file" "$profile_branch" "$default_branch"
        else
            # Only profile changed — copy from profile
            git -C "$vault_dir" checkout "$profile_branch" -- "$file" 2>/dev/null || true
        fi
        ((synced++)) || true
    done <<< "$changed_files"

    if [[ $synced -gt 0 ]]; then
        git -C "$vault_dir" add -A -- "${shared_paths[@]}"
        git -C "$vault_dir" commit -q -m "sync: shared resources from profile '$profile_branch'" 2>/dev/null || true
        if ! git -C "$vault_dir" push "$remote" "$default_branch" -q 2>/dev/null; then
            warn "Failed to push shared resources to $remote/$default_branch"
        fi
    fi

    # Return to profile branch
    git -C "$vault_dir" checkout "$profile_branch" -q
    if $stashed; then
        if ! git -C "$vault_dir" stash pop -q 2>/dev/null; then
            warn "Failed to restore stashed changes — use 'git stash list' in vault dir to recover"
        fi
    fi

    [[ $synced -gt 0 ]] && ok "Shared resources synced to $default_branch ($synced file(s))"
}

# Sync shared resources from default branch to profile branch (pull direction)
_sync_shared_from_default() {
    local vault_dir="$1" remote="$2"
    local default_branch
    default_branch=$(_vault_default_branch)

    # Find shared files that differ between default and profile
    local shared_paths=()
    while IFS= read -r p; do
        [[ -n "$p" ]] && shared_paths+=("$p")
    done < <(_list_shared_paths "$vault_dir")

    [[ ${#shared_paths[@]} -eq 0 ]] && return 0

    local changed_files
    changed_files=$(git -C "$vault_dir" diff "HEAD" "origin/$default_branch" --name-only -- \
        "${shared_paths[@]}" 2>/dev/null || true)

    [[ -z "$changed_files" ]] && return 0

    local profile_branch
    profile_branch=$(git -C "$vault_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)

    # Stash uncommitted work before modifying files
    local stashed=false
    if [[ -n "$(git -C "$vault_dir" status --porcelain 2>/dev/null)" ]]; then
        git -C "$vault_dir" stash -q
        stashed=true
    fi

    # Hoist merge-base outside the per-file loop (W4)
    local merge_base
    merge_base=$(git -C "$vault_dir" merge-base HEAD "origin/$default_branch" 2>/dev/null || true)

    local synced=0
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue

        # Check if file was also modified locally
        local modified_locally=false
        if [[ -n "$merge_base" ]]; then
            local local_diff
            local_diff=$(git -C "$vault_dir" diff "$merge_base" HEAD --name-only -- "$file" 2>/dev/null || true)
            [[ -n "$local_diff" ]] && modified_locally=true
        fi

        if $modified_locally; then
            # Both sides modified — interactive conflict resolution
            _resolve_shared_conflict "$vault_dir" "$file" "origin/$default_branch" "$profile_branch"
        else
            # Only default changed — copy from default
            git -C "$vault_dir" checkout "origin/$default_branch" -- "$file" 2>/dev/null || true
        fi
        ((synced++)) || true
    done <<< "$changed_files"

    if [[ $synced -gt 0 ]]; then
        git -C "$vault_dir" add -A -- "${shared_paths[@]}"
        git -C "$vault_dir" commit -q -m "sync: shared resources from $default_branch" 2>/dev/null || true
        ok "Synced $synced shared resource(s) from $default_branch"
    fi

    # Restore stashed work
    if $stashed; then
        if ! git -C "$vault_dir" stash pop -q 2>/dev/null; then
            warn "Failed to restore stashed changes — use 'git stash list' in vault dir to recover"
        fi
    fi
}

# Interactive conflict resolution for a shared resource file
# $1=vault_dir $2=file $3=source_ref (theirs) $4=target_ref (ours)
_resolve_shared_conflict() {
    local vault_dir="$1" file="$2" source_ref="$3" target_ref="$4"

    if [[ ! -t 0 ]]; then
        warn "Shared resource conflict in $file — skipped (non-interactive)"
        warn "  Run 'cco vault pull' interactively to resolve"
        return 0
    fi

    echo "" >&2
    echo -e "${BOLD}Shared resource conflict: $file${NC}" >&2
    echo "  Modified locally AND on the other branch" >&2
    echo "" >&2
    echo "  [L] Keep local version" >&2
    echo "  [R] Keep remote version" >&2
    echo "  [M] 3-way merge (may produce conflict markers)" >&2
    echo "  [D] Show diff" >&2
    echo "" >&2

    while true; do
        printf "  Choice [L/R/M/D]: " >&2
        local choice
        read -r choice
        case "$choice" in
            [Ll])
                # Keep local — no action needed
                info "Keeping local version of $file"
                return 0
                ;;
            [Rr])
                # Take remote version
                git -C "$vault_dir" checkout "$source_ref" -- "$file" 2>/dev/null || true
                info "Using remote version of $file"
                return 0
                ;;
            [Mm])
                # 3-way merge using git merge-file
                local tmpdir
                tmpdir=$(mktemp -d)
                local merge_base
                merge_base=$(git -C "$vault_dir" merge-base HEAD "$source_ref" 2>/dev/null || true)
                if [[ -n "$merge_base" ]]; then
                    git -C "$vault_dir" show "$merge_base:$file" > "$tmpdir/base" 2>/dev/null || echo "" > "$tmpdir/base"
                else
                    echo "" > "$tmpdir/base"
                fi
                git -C "$vault_dir" show "$source_ref:$file" > "$tmpdir/theirs" 2>/dev/null || echo "" > "$tmpdir/theirs"
                local current_file="$vault_dir/$file"
                if git merge-file "$current_file" "$tmpdir/base" "$tmpdir/theirs" 2>/dev/null; then
                    info "Merged $file cleanly"
                else
                    warn "Merged $file with conflict markers — edit manually"
                fi
                rm -rf "$tmpdir"
                return 0
                ;;
            [Dd])
                # Show diff
                echo "" >&2
                diff "$vault_dir/$file" <(git -C "$vault_dir" show "$source_ref:$file" 2>/dev/null) 2>/dev/null | head -50 >&2 || true
                echo "" >&2
                ;;
            *)
                echo "  Invalid choice. Use L, R, M, or D." >&2
                ;;
        esac
    done
}

# ── Internal helpers ──────────────────────────────────────────────────

_check_vault() {
    if [[ ! -d "$USER_CONFIG_DIR/.git" ]]; then
        die "Vault not initialized. Run 'cco vault init' first."
    fi
}

# Get the default branch name (main or master)
_vault_default_branch() {
    local vault_dir="$USER_CONFIG_DIR"
    # Check if 'main' branch exists
    if git -C "$vault_dir" rev-parse --verify main >/dev/null 2>&1; then
        echo "main"
    elif git -C "$vault_dir" rev-parse --verify master >/dev/null 2>&1; then
        echo "master"
    else
        # Fallback: whatever HEAD points to
        git -C "$vault_dir" rev-parse --abbrev-ref HEAD 2>/dev/null
    fi
}

# ── Main command router ───────────────────────────────────────────────

cmd_vault() {
    local subcmd="${1:-}"
    if [[ -z "$subcmd" || "$subcmd" == "--help" ]]; then
        cat <<'EOF'
Usage: cco vault <command>

Git-backed versioning and backup for your configuration.

Commands:
  init                    Initialize vault (git repo in user-config/)
  sync [msg] [--yes]      Commit current state with secret detection
  diff                    Show uncommitted changes by category
  log [--limit N]         Show commit history
  restore <ref>           Restore config to a previous state
  status                  Show vault state and sync info

Profiles (multi-PC selective sync):
  profile create <name>   Create a new vault profile
  profile list             List all profiles
  profile show             Show current profile details
  profile switch <name>   Switch to another profile
  profile rename <name>   Rename current profile
  profile delete <name>   Delete a profile
  profile add <type> <name>   Add a resource to the current profile
  profile remove <type> <name> Remove a resource from the current profile

Remote backup:
  remote add <n> <url>    Add a git remote
  remote remove <n>       Remove a git remote
  push [<remote>]         Push to remote (default: origin)
  pull [<remote>]         Pull from remote (default: origin)

Run 'cco vault <command> --help' for command-specific options.
EOF
        return 0
    fi
    shift

    case "$subcmd" in
        init)    cmd_vault_init "$@" ;;
        sync)    cmd_vault_sync "$@" ;;
        diff)    cmd_vault_diff "$@" ;;
        log)     cmd_vault_log "$@" ;;
        restore) cmd_vault_restore "$@" ;;
        profile) cmd_vault_profile "$@" ;;
        remote)  cmd_vault_remote "$@" ;;
        push)    cmd_vault_push "$@" ;;
        pull)    cmd_vault_pull "$@" ;;
        status)  cmd_vault_status "$@" ;;
        *)
            die "Unknown vault command: $subcmd. Run 'cco vault --help'."
            ;;
    esac
}
