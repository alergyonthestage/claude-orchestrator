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

# Profile state — gitignored files stashed during profile switch
.cco/profile-state/

# Profile operation backups
.cco/backups/

# Profile operation log
.cco/profile-ops.log

# Machine-specific local path mappings
projects/*/.cco/local-paths.yml

# Temporary backup during vault save path extraction
projects/*/.cco/project.yml.pre-save
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

cmd_vault_save() {
    local message="" dry_run=false auto_yes=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) dry_run=true; shift ;;
            --yes|-y)  auto_yes=true; shift ;;
            --help)
                cat <<'EOF'
Usage: cco vault save [<message>] [--yes] [--dry-run]

Save your work: commit changes and propagate shared resources to all profiles.

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
                if [[ "$basename_file" == $pattern || "$ef" == *"$pattern" ]]; then
                    secret_files+=("$ef")
                    break
                fi
            done
        done
    done <<< "$status_output"

    if [[ ${#secret_files[@]} -gt 0 ]]; then
        error "Secret files detected — aborting vault save"
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

    # Step 1: Extract local paths, stage, commit, then restore
    # With real isolation, git add -A is safe on any branch (D20)
    _extract_local_paths "$vault_dir"
    git -C "$vault_dir" add -A
    git -C "$vault_dir" commit -q -m "vault: $message"
    _restore_local_paths "$vault_dir"

    local current_branch
    current_branch=$(git -C "$vault_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
    local profile
    profile=$(_get_active_profile)
    local file_count=$total

    ok "Saved on '$current_branch': vault: $message ($file_count files)"

    # Step 2-4: Shared sync (only if profiles exist)
    if ! _has_profiles; then
        return 0
    fi

    # Detect shared file changes in the commit
    local shared_changes
    shared_changes=$(_detect_shared_changes "$vault_dir")
    [[ -z "$shared_changes" ]] && return 0

    local shared_count
    shared_count=$(echo "$shared_changes" | grep -c . || true)

    if [[ -n "$profile" ]]; then
        # On a profile branch: sync to main, then to all other profiles
        _sync_shared_to_main "$vault_dir" "$current_branch"
        _sync_shared_to_all_profiles "$vault_dir"
    else
        # On main: sync to all profile branches
        _sync_shared_to_all_profiles "$vault_dir"
    fi

    local profile_count
    profile_count=$(_list_profile_branches | grep -c . || true)
    if [[ -n "$profile" ]]; then
        # On a profile: synced to main + (N-1) other profiles
        local other_profile_count=$((profile_count > 1 ? profile_count - 1 : 0))
        ok "Synced $shared_count shared file(s) to main and $other_profile_count other profile(s)"
    else
        # On main: synced to N profiles
        ok "Synced $shared_count shared file(s) to $profile_count profile(s)"
    fi
}

# Deprecated alias for vault save (backward compatible)
cmd_vault_sync() {
    warn "'vault sync' is deprecated. Use 'vault save' instead."
    cmd_vault_save "$@"
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
Auto-saves pending changes, pushes current branch and main.
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
    local default_branch
    default_branch=$(_vault_default_branch)

    # Step 1: Auto-save (commit + shared sync) if there are pending changes
    local status_output
    status_output=$(git -C "$vault_dir" status --porcelain 2>/dev/null)
    if [[ -n "$status_output" ]]; then
        cmd_vault_save "pre-push save" --yes || return 1
    fi

    # Step 2: Push current branch
    git -C "$vault_dir" push -u "$remote" "$branch"
    ok "Pushed '$branch' to $remote"

    # Step 3: Push main (shared resources) — only if we have profiles
    local profile
    profile=$(_get_active_profile)
    if [[ -n "$profile" ]] || _has_profiles; then
        if [[ "$branch" != "$default_branch" ]]; then
            git -C "$vault_dir" push "$remote" "$default_branch" -q 2>/dev/null && \
                ok "Pushed '$default_branch' to $remote (shared resources)" || \
                warn "Failed to push $default_branch to $remote"
        fi
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
Pulls current branch and main, then syncs shared resources.
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

    # Verify remote exists
    if ! git -C "$vault_dir" remote get-url "$remote" >/dev/null 2>&1; then
        die "Remote '$remote' not configured. Run 'cco vault remote add $remote <url>' first."
    fi

    local branch
    branch=$(git -C "$vault_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
    local default_branch
    default_branch=$(_vault_default_branch)
    local profile
    profile=$(_get_active_profile)

    # Step 1: Fetch all
    if ! git -C "$vault_dir" fetch "$remote" 2>/dev/null; then
        warn "Failed to fetch from $remote (network error?)"
    fi

    # Step 2: Pull current branch
    if git -C "$vault_dir" ls-remote --heads "$remote" "$branch" 2>/dev/null | grep -q .; then
        if ! git -C "$vault_dir" pull "$remote" "$branch"; then
            warn "Failed to pull '$branch' from $remote"
            return 1
        fi
        ok "Pulled '$branch' from $remote"
    else
        info "Branch '$branch' not found on remote. Push first with 'cco vault push'."
    fi

    # Step 3: Pull main (if we have profiles and not already on main)
    if [[ -n "$profile" ]] || _has_profiles; then
        if [[ "$branch" != "$default_branch" ]]; then
            if git -C "$vault_dir" ls-remote --heads "$remote" "$default_branch" 2>/dev/null | grep -q .; then
                git -C "$vault_dir" checkout "$default_branch" -q
                git -C "$vault_dir" pull "$remote" "$default_branch" -q 2>/dev/null && \
                    ok "Pulled '$default_branch' from $remote" || \
                    warn "Failed to pull $default_branch from $remote"
                git -C "$vault_dir" checkout "$branch" -q
            fi
        fi
    fi

    # Step 4: Sync shared from main → current profile
    if [[ -n "$profile" ]]; then
        _sync_shared_from_main "$vault_dir" "$branch"
    fi

    # Step 5: Resolve @local markers from local-paths.yml (best-effort, silent)
    _resolve_all_local_paths "$vault_dir"
}

# Validate .vault-profile against actual branch content
# Warns if projects/packs listed in .vault-profile don't exist on disk,
# or if projects/packs exist on disk but aren't listed.
_vault_status_validate_profile() {
    local vault_dir="$1" prof_projects="$2" prof_packs="$3"
    local warnings=()

    # Check projects listed in .vault-profile exist on disk
    if [[ -n "$prof_projects" ]]; then
        while IFS= read -r p; do
            [[ -z "$p" ]] && continue
            if [[ ! -d "$vault_dir/projects/$p" ]]; then
                warnings+=("Project '$p' listed in .vault-profile but not found on disk")
            fi
        done <<< "$prof_projects"
    fi

    # Check packs listed in .vault-profile exist on disk
    if [[ -n "$prof_packs" ]]; then
        while IFS= read -r p; do
            [[ -z "$p" ]] && continue
            if [[ ! -d "$vault_dir/packs/$p" ]]; then
                warnings+=("Pack '$p' listed in .vault-profile but not found on disk")
            fi
        done <<< "$prof_packs"
    fi

    # Check projects on disk that aren't in .vault-profile
    if [[ -d "$vault_dir/projects" ]]; then
        local dir
        for dir in "$vault_dir/projects"/*/; do
            [[ ! -d "$dir" ]] && continue
            local name
            name=$(basename "$dir")
            # Skip if already listed
            if [[ -n "$prof_projects" ]] && echo "$prof_projects" | grep -qxF "$name"; then
                continue
            fi
            # Check if it's tracked by git (not just gitignored remnant)
            if git -C "$vault_dir" ls-files --error-unmatch "projects/$name/project.yml" >/dev/null 2>&1; then
                warnings+=("Project '$name' exists on branch but not listed in .vault-profile")
            fi
        done
    fi

    if [[ ${#warnings[@]} -gt 0 ]]; then
        echo ""
        local w
        for w in "${warnings[@]}"; do
            warn "$w"
        done
        info "Fix with 'cco vault move' or edit .vault-profile manually, then 'cco vault save'."
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

        # Validate .vault-profile against actual branch content
        _vault_status_validate_profile "$vault_dir" "$proj_list" "$pack_list"
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

# ── Profile real isolation helpers ────────────────────────────────────

# Portable gitignored file patterns for projects
_PORTABLE_FILE_PATTERNS=("secrets.env" "*.env" "*.key" "*.pem")

# Check if a pack is exclusive (listed in any profile's sync.packs)
_is_exclusive_pack() {
    local pack_name="$1"
    local vault_dir="$USER_CONFIG_DIR"

    while IFS= read -r branch; do
        [[ -z "$branch" ]] && continue
        branch=$(echo "$branch" | sed 's/^[ *]*//')
        local _default_branch
        _default_branch=$(_vault_default_branch)
        [[ "$branch" == "$_default_branch" ]] && continue

        local profile_content
        profile_content=$(git -C "$vault_dir" show "$branch:.vault-profile" 2>/dev/null || true)
        [[ -z "$profile_content" ]] && continue

        if echo "$profile_content" | awk -v pack="$pack_name" '
            /^  packs:/ { in_pack=1; next }
            /^[^ ]/ { in_pack=0 }
            in_pack && /^    - / { sub(/^    - */, ""); if ($0 == pack) found=1 }
            END { exit (found ? 0 : 1) }
        '; then
            return 0
        fi
    done < <(git -C "$vault_dir" branch 2>/dev/null)

    return 1
}

# Stash portable gitignored files for exclusive projects during profile switch
# Args: vault_dir, profile_name
_stash_gitignored_files() {
    local vault_dir="$1" profile_name="$2"
    local profile_file="$vault_dir/.vault-profile"
    [[ ! -f "$profile_file" ]] && return 0

    local proj_list
    proj_list=$(yml_get_list "$profile_file" "sync.projects" 2>/dev/null || true)
    [[ -z "$proj_list" ]] && return 0

    while IFS= read -r proj; do
        [[ -z "$proj" ]] && continue
        local proj_dir="$vault_dir/projects/$proj"
        [[ ! -d "$proj_dir" ]] && continue

        local shadow_base="$vault_dir/.cco/profile-state/$profile_name/projects/$proj"

        # claude-state directory
        if [[ -d "$proj_dir/.cco/claude-state" ]]; then
            mkdir -p "$shadow_base/.cco"
            mv "$proj_dir/.cco/claude-state" "$shadow_base/.cco/claude-state"
        fi

        # .cco/meta file
        if [[ -f "$proj_dir/.cco/meta" ]]; then
            mkdir -p "$shadow_base/.cco"
            mv "$proj_dir/.cco/meta" "$shadow_base/.cco/meta"
        fi

        # .cco/local-paths.yml (machine-specific path mappings)
        if [[ -f "$proj_dir/.cco/local-paths.yml" ]]; then
            mkdir -p "$shadow_base/.cco"
            mv "$proj_dir/.cco/local-paths.yml" "$shadow_base/.cco/local-paths.yml"
        fi

        # Portable secret files (secrets.env, *.env, *.key, *.pem)
        for pattern in "${_PORTABLE_FILE_PATTERNS[@]}"; do
            # Use find for glob matching at project root level only
            while IFS= read -r fpath; do
                [[ -z "$fpath" ]] && continue
                local fname
                fname=$(basename "$fpath")
                mkdir -p "$shadow_base"
                mv "$fpath" "$shadow_base/$fname"
            done < <(find "$proj_dir" -maxdepth 1 -name "$pattern" -type f 2>/dev/null)
        done
    done <<< "$proj_list"
}

# Restore portable gitignored files for exclusive projects after profile switch
# Args: vault_dir, profile_name
_restore_gitignored_files() {
    local vault_dir="$1" profile_name="$2"
    local shadow_base="$vault_dir/.cco/profile-state/$profile_name"
    [[ ! -d "$shadow_base" ]] && return 0

    local profile_file="$vault_dir/.vault-profile"
    [[ ! -f "$profile_file" ]] && return 0

    local proj_list
    proj_list=$(yml_get_list "$profile_file" "sync.projects" 2>/dev/null || true)
    [[ -z "$proj_list" ]] && return 0

    while IFS= read -r proj; do
        [[ -z "$proj" ]] && continue
        local proj_dir="$vault_dir/projects/$proj"
        local shadow_proj="$shadow_base/projects/$proj"
        [[ ! -d "$shadow_proj" ]] && continue

        # claude-state directory
        if [[ -d "$shadow_proj/.cco/claude-state" ]]; then
            mkdir -p "$proj_dir/.cco"
            mv "$shadow_proj/.cco/claude-state" "$proj_dir/.cco/claude-state"
        fi

        # .cco/meta file
        if [[ -f "$shadow_proj/.cco/meta" ]]; then
            mkdir -p "$proj_dir/.cco"
            mv "$shadow_proj/.cco/meta" "$proj_dir/.cco/meta"
        fi

        # .cco/local-paths.yml (machine-specific path mappings)
        if [[ -f "$shadow_proj/.cco/local-paths.yml" ]]; then
            mkdir -p "$proj_dir/.cco"
            mv "$shadow_proj/.cco/local-paths.yml" "$proj_dir/.cco/local-paths.yml"
        fi

        # Portable secret files
        for pattern in "${_PORTABLE_FILE_PATTERNS[@]}"; do
            while IFS= read -r fpath; do
                [[ -z "$fpath" ]] && continue
                local fname
                fname=$(basename "$fpath")
                mkdir -p "$proj_dir"
                mv "$fpath" "$proj_dir/$fname"
            done < <(find "$shadow_proj" -maxdepth 1 -name "$pattern" -type f 2>/dev/null)
        done
    done <<< "$proj_list"
}

# Stash portable gitignored files for ALL projects on main
# On main there is no .vault-profile — all projects are exclusive to main.
# Args: vault_dir
_stash_gitignored_files_main() {
    local vault_dir="$1"
    [[ ! -d "$vault_dir/projects" ]] && return 0

    local _default_branch
    _default_branch=$(_vault_default_branch)

    local proj_name
    for proj_dir in "$vault_dir"/projects/*/; do
        [[ ! -d "$proj_dir" ]] && continue
        proj_name=$(basename "$proj_dir")

        local shadow_base="$vault_dir/.cco/profile-state/$_default_branch/projects/$proj_name"

        if [[ -d "$proj_dir/.cco/claude-state" ]]; then
            mkdir -p "$shadow_base/.cco"
            mv "$proj_dir/.cco/claude-state" "$shadow_base/.cco/claude-state"
        fi
        if [[ -f "$proj_dir/.cco/meta" ]]; then
            mkdir -p "$shadow_base/.cco"
            mv "$proj_dir/.cco/meta" "$shadow_base/.cco/meta"
        fi
        if [[ -f "$proj_dir/.cco/local-paths.yml" ]]; then
            mkdir -p "$shadow_base/.cco"
            mv "$proj_dir/.cco/local-paths.yml" "$shadow_base/.cco/local-paths.yml"
        fi
        for pattern in "${_PORTABLE_FILE_PATTERNS[@]}"; do
            while IFS= read -r fpath; do
                [[ -z "$fpath" ]] && continue
                local fname
                fname=$(basename "$fpath")
                mkdir -p "$shadow_base"
                mv "$fpath" "$shadow_base/$fname"
            done < <(find "$proj_dir" -maxdepth 1 -name "$pattern" -type f 2>/dev/null)
        done
    done
}

# Restore portable gitignored files for ALL projects on main
# Args: vault_dir
_restore_gitignored_files_main() {
    local vault_dir="$1"
    local _default_branch
    _default_branch=$(_vault_default_branch)
    local shadow_base="$vault_dir/.cco/profile-state/$_default_branch"
    [[ ! -d "$shadow_base/projects" ]] && return 0

    local proj_name
    for shadow_proj in "$shadow_base"/projects/*/; do
        [[ ! -d "$shadow_proj" ]] && continue
        proj_name=$(basename "$shadow_proj")
        local proj_dir="$vault_dir/projects/$proj_name"

        if [[ -d "$shadow_proj/.cco/claude-state" ]]; then
            mkdir -p "$proj_dir/.cco"
            mv "$shadow_proj/.cco/claude-state" "$proj_dir/.cco/claude-state"
        fi
        if [[ -f "$shadow_proj/.cco/meta" ]]; then
            mkdir -p "$proj_dir/.cco"
            mv "$shadow_proj/.cco/meta" "$proj_dir/.cco/meta"
        fi
        if [[ -f "$shadow_proj/.cco/local-paths.yml" ]]; then
            mkdir -p "$proj_dir/.cco"
            mv "$shadow_proj/.cco/local-paths.yml" "$proj_dir/.cco/local-paths.yml"
        fi
        for pattern in "${_PORTABLE_FILE_PATTERNS[@]}"; do
            while IFS= read -r fpath; do
                [[ -z "$fpath" ]] && continue
                local fname
                fname=$(basename "$fpath")
                mkdir -p "$proj_dir"
                mv "$fpath" "$proj_dir/$fname"
            done < <(find "$shadow_proj" -maxdepth 1 -name "$pattern" -type f 2>/dev/null)
        done
    done
}

# Known non-portable gitignored patterns that are safe to lose (regenerated by cco start).
# Everything NOT in this list is considered valuable and must be stashed before removal.
_SAFE_TO_REMOVE_PATTERNS=(
    '.cco/docker-compose.yml'
    '.cco/managed/*'
    '.cco/managed'
    '.tmp/*'
    '.tmp'
    '.cco/install-tmp/*'
    '.cco/install-tmp'
    'rag-data/*'
    'rag-data'
)

# Check if a relative path matches known safe-to-remove patterns.
# Returns 0 if safe, 1 if not.
_is_safe_to_remove() {
    local rel="$1"
    for pattern in "${_SAFE_TO_REMOVE_PATTERNS[@]}"; do
        # Exact match or glob match
        if [[ "$rel" == $pattern ]]; then
            return 0
        fi
    done
    return 1
}

# List files in a directory that are NOT known-safe patterns.
# These should have been stashed before removal. If any are found,
# the caller should NOT proceed with rm -rf.
# Args: dir
# Outputs: one line per unaccounted file (empty = safe to remove)
_list_unaccounted_files() {
    local dir="$1"
    [[ ! -d "$dir" ]] && return 0

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        local rel="${file#$dir/}"
        _is_safe_to_remove "$rel" || echo "$rel"
    done < <(find "$dir" -type f 2>/dev/null)
}

# Safe removal: verify no valuable files remain, then force-remove.
# If unaccounted files are found, logs a warning and skips removal.
# Args: vault_dir, resource_path (e.g., "projects/cave-auth"), context_label
_safe_remove_resource_dir() {
    local vault_dir="$1"
    local resource_path="$2"
    local context="${3:-removal}"
    local target_dir="$vault_dir/$resource_path"

    [[ ! -d "$target_dir" ]] && return 0

    local unaccounted
    unaccounted=$(_list_unaccounted_files "$target_dir")
    if [[ -n "$unaccounted" ]]; then
        warn "Unaccounted files in $resource_path/ after $context — skipping cleanup:"
        echo "$unaccounted" | sed 's/^/    /' >&2
        info "These files were not stashed. They remain on disk for manual review."
        return 1
    fi

    _force_remove_dir "$target_dir"
}

# Force-remove a directory, handling Docker Desktop mount point stubs on macOS.
# Normal rm may fail on directories created by Docker (owned by root).
# Falls back to Docker-based cleanup if available.
# Args: path_to_remove
_force_remove_dir() {
    local target_path="$1"
    [[ ! -d "$target_path" ]] && return 0

    rm -rf "$target_path" 2>/dev/null || true
    [[ ! -d "$target_path" ]] && return 0

    # Docker stubs survive normal rm — use Docker itself to clean
    if command -v docker >/dev/null 2>&1; then
        local parent_dir base_name
        parent_dir=$(dirname "$target_path")
        base_name=$(basename "$target_path")
        docker run --rm -v "$parent_dir:/mnt" alpine rm -rf "/mnt/$base_name" 2>/dev/null || true
    fi
}

# Clean non-portable remnants for exclusive projects (regenerated by cco start)
# Args: vault_dir
_clean_nonportable_remnants() {
    local vault_dir="$1"
    local profile_file="$vault_dir/.vault-profile"
    [[ ! -f "$profile_file" ]] && return 0

    local proj_list
    proj_list=$(yml_get_list "$profile_file" "sync.projects" 2>/dev/null || true)
    [[ -z "$proj_list" ]] && return 0

    while IFS= read -r proj; do
        [[ -z "$proj" ]] && continue
        local proj_dir="$vault_dir/projects/$proj"
        [[ ! -d "$proj_dir" ]] && continue
        rm -f "$proj_dir/.cco/docker-compose.yml"
        rm -rf "$proj_dir/.cco/managed/"
        rm -rf "$proj_dir/.tmp/"
    done <<< "$proj_list"
}

# Check that no Docker sessions are active (blocks branch-switching operations: D8, D31)
# Uses label filter (new containers) with name filter fallback (pre-label containers)
_check_no_active_sessions() {
    local running
    running=$(docker ps --filter "label=cco.project" --format "{{.Names}}" 2>/dev/null || true)
    # Fallback: match by container name convention (cc-*), same as cco stop
    if [[ -z "$running" ]]; then
        running=$(docker ps --filter "name=cc-" --format "{{.Names}}" 2>/dev/null || true)
    fi
    if [[ -n "$running" ]]; then
        echo -e "${RED}✗${NC} Cannot perform this operation while Docker sessions are active." >&2
        echo "  Running:" >&2
        echo "$running" | sed 's/^/    - /' >&2
        echo "  Stop sessions with 'cco stop' first." >&2
        return 1
    fi
}

# Check that a specific project doesn't have an active Docker session
# Uses label filter (new containers) with name filter fallback (pre-label containers)
# Args: project_name
_check_project_not_active() {
    local project_name="$1"
    local running
    running=$(docker ps --filter "label=cco.project=$project_name" --format "{{.Names}}" 2>/dev/null || true)
    # Fallback: match by container name convention (cc-<project_name>)
    if [[ -z "$running" ]]; then
        running=$(docker ps --filter "name=cc-${project_name}" --format "{{.Names}}" 2>/dev/null || true)
    fi
    if [[ -n "$running" ]]; then
        echo -e "${RED}✗${NC} Cannot modify project '$project_name' while its Docker session is active." >&2
        echo "  Running: $running" >&2
        echo "  Stop the session with 'cco stop $project_name' first." >&2
        return 1
    fi
}

# Auto-resolve framework-managed file changes that should not block operations.
# Handles two cases:
#   1. Deleted .gitkeep files — restored silently (D32)
#   2. New/modified files in memory/ — auto-committed (D33, framework-managed)
# Args: vault_dir
_auto_resolve_framework_changes() {
    local vault_dir="$1"
    local resolved=false

    # Step 1: Restore deleted .gitkeep files (D32)
    local deleted
    deleted=$(git -C "$vault_dir" diff --name-only --diff-filter=D 2>/dev/null | grep '\.gitkeep$' || true)
    if [[ -n "$deleted" ]]; then
        while IFS= read -r file; do
            [[ -z "$file" ]] && continue
            mkdir -p "$(dirname "$vault_dir/$file")"
            touch "$vault_dir/$file"
        done <<< "$deleted"
    fi

    # Step 2: Auto-commit memory/ changes (D33 — framework-managed auto-memory)
    local memory_changes
    memory_changes=$(git -C "$vault_dir" status --porcelain 2>/dev/null | grep '/memory/' || true)
    if [[ -n "$memory_changes" ]]; then
        # Stage all memory/ paths (new, modified, deleted)
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local file="${line:3}"
            # Handle directory entries (trailing /) by adding the dir
            if [[ "$file" == */ ]]; then
                git -C "$vault_dir" add -- "$file" 2>/dev/null || true
            else
                git -C "$vault_dir" add -- "$file" 2>/dev/null || true
            fi
        done <<< "$memory_changes"
        local staged
        staged=$(git -C "$vault_dir" diff --cached --name-only 2>/dev/null)
        if [[ -n "$staged" ]]; then
            git -C "$vault_dir" commit -q -m "vault: auto-save memory"
            resolved=true
        fi
    fi
}

# Backward-compatible alias
_restore_missing_gitkeep() {
    _auto_resolve_framework_changes "$@"
}

# Append to profile operations log
# Args: vault_dir, message...
_vault_log_op() {
    local vault_dir="$1"; shift
    local log_file="$vault_dir/.cco/profile-ops.log"
    mkdir -p "$(dirname "$log_file")"
    echo "$(date +%Y-%m-%dT%H:%M:%S) $*" >> "$log_file"
}

# List all profile branch names (excludes default branch)
_list_profile_branches() {
    local vault_dir="$USER_CONFIG_DIR"
    local default_branch
    default_branch=$(_vault_default_branch)

    while IFS= read -r branch; do
        [[ -z "$branch" ]] && continue
        branch=$(echo "$branch" | sed 's/^[ *]*//')
        [[ "$branch" == "$default_branch" ]] && continue
        # Only include branches that have .vault-profile
        if git -C "$vault_dir" show "$branch:.vault-profile" >/dev/null 2>&1; then
            echo "$branch" 2>/dev/null || true
        fi
    done < <(git -C "$vault_dir" branch 2>/dev/null)
}

# Check if any profile branches exist
_has_profiles() {
    local first
    first=$(_list_profile_branches | head -1)
    [[ -n "$first" ]]
}

# Detect shared file changes in a commit
# Args: vault_dir
# Outputs list of shared files that changed in the latest commit
_detect_shared_changes() {
    local vault_dir="$1"
    local shared_paths=()
    while IFS= read -r p; do
        [[ -n "$p" ]] && shared_paths+=("$p")
    done < <(_list_shared_paths "$vault_dir")

    [[ ${#shared_paths[@]} -eq 0 ]] && return 0

    # Compare HEAD commit with its parent for shared paths
    git -C "$vault_dir" diff HEAD~1 HEAD --name-only -- \
        ${shared_paths[@]+"${shared_paths[@]}"} 2>/dev/null || true
}

# Check if a project/pack name exists on any branch other than the specified one.
# Returns 0 if a conflict is found (name exists elsewhere), 1 if unique.
# Args: vault_dir, resource_type (project|pack), name, exclude_branch
# Outputs: the conflicting branch name (if any)
_name_exists_on_other_branch() {
    local vault_dir="$1" resource_type="$2" name="$3" exclude_branch="$4"
    local default_branch
    default_branch=$(_vault_default_branch)

    local resource_path
    if [[ "$resource_type" == "project" ]]; then
        resource_path="projects/$name"
    else
        resource_path="packs/$name"
    fi

    # Check default branch
    if [[ "$exclude_branch" != "$default_branch" ]]; then
        if [[ -n "$(git -C "$vault_dir" ls-tree "$default_branch" -- "$resource_path/" 2>/dev/null)" ]]; then
            echo "$default_branch"
            return 0
        fi
    fi

    # Check profile branches
    while IFS= read -r branch; do
        [[ -z "$branch" ]] && continue
        [[ "$branch" == "$exclude_branch" ]] && continue
        if [[ -n "$(git -C "$vault_dir" ls-tree "$branch" -- "$resource_path/" 2>/dev/null)" ]]; then
            echo "$branch"
            return 0
        fi
    done < <(_list_profile_branches)

    return 1
}

# Sync shared resources from a source branch to main (local, with merge-base advancement)
# Args: vault_dir, source_branch
# Expects: caller is on source_branch
_sync_shared_to_main() {
    local vault_dir="$1" source_branch="$2"
    local default_branch
    default_branch=$(_vault_default_branch)

    # Collect shared paths
    local shared_paths=()
    while IFS= read -r p; do
        [[ -n "$p" ]] && shared_paths+=("$p")
    done < <(_list_shared_paths "$vault_dir")

    [[ ${#shared_paths[@]} -eq 0 ]] && return 0

    # Find shared files that differ between source and main
    local changed_files
    changed_files=$(git -C "$vault_dir" diff "$default_branch" "$source_branch" \
        --name-only -- ${shared_paths[@]+"${shared_paths[@]}"} 2>/dev/null || true)

    [[ -z "$changed_files" ]] && return 0

    # Switch to main
    git -C "$vault_dir" checkout "$default_branch" -q

    # Compute merge-base for direction detection
    local merge_base
    merge_base=$(git -C "$vault_dir" merge-base "$default_branch" "$source_branch" 2>/dev/null || true)

    local synced=0
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue

        if [[ -n "$merge_base" ]]; then
            local on_main on_source
            on_main=$(git -C "$vault_dir" diff "$merge_base" "$default_branch" \
                --name-only -- "$file" 2>/dev/null || true)
            on_source=$(git -C "$vault_dir" diff "$merge_base" "$source_branch" \
                --name-only -- "$file" 2>/dev/null || true)

            if [[ -n "$on_main" && -n "$on_source" ]]; then
                # Both changed — conflict (multi-PC scenario only)
                _resolve_shared_conflict "$vault_dir" "$file" "$source_branch" "$default_branch"
                ((synced++)) || true
            elif [[ -n "$on_source" ]]; then
                # Only source changed — auto-copy
                git -C "$vault_dir" checkout "$source_branch" -- "$file"
                ((synced++)) || true
            fi
            # Only main changed or neither → no action
        else
            # No merge-base — fall back to copying from source
            git -C "$vault_dir" checkout "$source_branch" -- "$file"
            ((synced++)) || true
        fi
    done <<< "$changed_files"

    # Commit synced changes + merge-base advancement
    if [[ $synced -gt 0 ]]; then
        git -C "$vault_dir" add -A -- ${shared_paths[@]+"${shared_paths[@]}"}
        git -C "$vault_dir" commit -q -m "sync: shared from '$source_branch'" 2>/dev/null || true

        # Merge-base advancement: git merge -s ours makes future syncs
        # only compare changes since this sync point (§8.5)
        git -C "$vault_dir" merge -s ours "$source_branch" -q \
            -m "sync: merge-base with '$source_branch'" 2>/dev/null || true
    fi

    # Return to source branch
    git -C "$vault_dir" checkout "$source_branch" -q

    return 0
}

# Sync shared resources from main to a target branch (local, with merge-base advancement)
# Args: vault_dir, target_branch
# Expects: caller is already on target_branch
_sync_shared_from_main() {
    local vault_dir="$1" target_branch="$2"
    local default_branch
    default_branch=$(_vault_default_branch)

    # Collect shared paths
    local shared_paths=()
    while IFS= read -r p; do
        [[ -n "$p" ]] && shared_paths+=("$p")
    done < <(_list_shared_paths "$vault_dir")

    [[ ${#shared_paths[@]} -eq 0 ]] && return 0

    # Find shared files that differ between target and main
    local changed_files
    changed_files=$(git -C "$vault_dir" diff "$target_branch" "$default_branch" \
        --name-only -- ${shared_paths[@]+"${shared_paths[@]}"} 2>/dev/null || true)

    [[ -z "$changed_files" ]] && return 0

    # Compute merge-base for direction detection
    local merge_base
    merge_base=$(git -C "$vault_dir" merge-base "$default_branch" "$target_branch" 2>/dev/null || true)

    local synced=0
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue

        if [[ -n "$merge_base" ]]; then
            local on_main on_target
            on_main=$(git -C "$vault_dir" diff "$merge_base" "$default_branch" \
                --name-only -- "$file" 2>/dev/null || true)
            on_target=$(git -C "$vault_dir" diff "$merge_base" "$target_branch" \
                --name-only -- "$file" 2>/dev/null || true)

            if [[ -n "$on_main" && -n "$on_target" ]]; then
                # Both changed — conflict (multi-PC scenario only)
                _resolve_shared_conflict "$vault_dir" "$file" "$default_branch" "$target_branch"
                ((synced++)) || true
            elif [[ -n "$on_main" ]]; then
                # Only main changed — auto-copy
                git -C "$vault_dir" checkout "$default_branch" -- "$file"
                ((synced++)) || true
            fi
            # Only target changed or neither → no action
        else
            # No merge-base — fall back to copying from main
            git -C "$vault_dir" checkout "$default_branch" -- "$file"
            ((synced++)) || true
        fi
    done <<< "$changed_files"

    # Commit synced changes + merge-base advancement
    if [[ $synced -gt 0 ]]; then
        git -C "$vault_dir" add -A -- ${shared_paths[@]+"${shared_paths[@]}"}
        git -C "$vault_dir" commit -q -m "sync: shared from main" 2>/dev/null || true

        # Merge-base advancement (§8.5)
        git -C "$vault_dir" merge -s ours "$default_branch" -q \
            -m "sync: merge-base with main" 2>/dev/null || true
    fi

    return 0
}

# Propagate shared resources from main to all profile branches
# Args: vault_dir
# Expects: caller is on any branch (will return to it)
_sync_shared_to_all_profiles() {
    local vault_dir="$1"
    local original_branch
    original_branch=$(git -C "$vault_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)

    local profiles=()
    while IFS= read -r p; do
        [[ -n "$p" ]] && profiles+=("$p")
    done < <(_list_profile_branches)

    [[ ${#profiles[@]} -eq 0 ]] && return 0

    local synced_count=0
    for profile_branch in "${profiles[@]}"; do
        [[ "$profile_branch" == "$original_branch" ]] && continue

        git -C "$vault_dir" checkout "$profile_branch" -q 2>/dev/null || {
            warn "Failed to checkout profile branch '$profile_branch' for sync"
            continue
        }

        _sync_shared_from_main "$vault_dir" "$profile_branch" && {
            ((synced_count++)) || true
        }
    done

    # Return to original branch
    git -C "$vault_dir" checkout "$original_branch" -q
    return 0
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

Manage vault profiles for workspace isolation.

Commands:
  create <name>      Create a new profile (branch from main)
  list               List all profiles
  show               Show current profile details
  switch <name>      Switch to another profile (alias: vault switch)
  rename <new-name>  Rename current profile
  delete <name>      Delete a profile (moves resources to main)
  move <type> <name> <target>  Move a resource (alias: vault move)
  remove <type> <name>         Remove a resource (alias: vault remove)

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

    # Auto-restore framework infrastructure files (D32)
    _restore_missing_gitkeep "$vault_dir"

    # Working tree must be clean
    local status_output
    status_output=$(git -C "$vault_dir" status --porcelain 2>/dev/null)
    [[ -n "$status_output" ]] && die "You have uncommitted changes. Run 'cco vault save' first."

    # No active Docker sessions — profile create involves branch checkout (D31)
    _check_no_active_sessions || return 1

    # Create branch from main (§6.7)
    local default_branch
    default_branch=$(_vault_default_branch)

    # Stash departing profile's gitignored files before checkout (§5.3)
    local departing_profile
    departing_profile=$(_get_active_profile)
    if [[ -n "$departing_profile" ]]; then
        _stash_gitignored_files "$vault_dir" "$departing_profile"
    else
        # On main: stash all projects (exclusive to main)
        _stash_gitignored_files_main "$vault_dir"
    fi

    git -C "$vault_dir" checkout -b "$name" "$default_branch" -q

    # Remove all projects from new branch — they belong to main (§6.7)
    # Each project is exclusive to one branch; new profiles start empty.
    if [[ -d "$vault_dir/projects" ]] && \
       [[ -n "$(ls -A "$vault_dir/projects/" 2>/dev/null)" ]]; then
        git -C "$vault_dir" rm -r --quiet projects/ 2>/dev/null || true
        # Verify all valuable files were stashed, then clean remnants
        for _proj_dir in "$vault_dir"/projects/*/; do
            [[ ! -d "$_proj_dir" ]] && continue
            _safe_remove_resource_dir "$vault_dir" "projects/$(basename "$_proj_dir")" "profile create" || true
        done
        # Remove projects/ dir if fully empty (may have stubs)
        _force_remove_dir "$vault_dir/projects" 2>/dev/null || true
        mkdir -p "$vault_dir/projects"
    fi

    _write_vault_profile "$name"
    git -C "$vault_dir" add -A
    git -C "$vault_dir" commit -q -m "vault: create profile '$name'"

    ok "Profile '$name' created (shared resources only)"
    info "Use 'cco vault move project <name> $name' to assign projects."
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
    local main_projects=0 main_packs=0 main_templates=0
    # Count projects on main by checking git tree (works from any branch)
    main_projects=$(git -C "$vault_dir" ls-tree "$(_vault_default_branch)" -- projects/ 2>/dev/null | grep -c . || true)
    [[ -d "$vault_dir/packs" ]] && main_packs=$(find "$vault_dir/packs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    [[ -d "$vault_dir/templates" ]] && main_templates=$(find "$vault_dir/templates" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    local main_marker="  "
    [[ "$current_branch" == "$(_vault_default_branch)" ]] && main_marker="* "
    echo -e "  ${main_marker}${BOLD}Main:${NC} ${main_projects} project(s), ${main_packs} pack(s), ${main_templates} template(s), global"
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
        local default_branch
        default_branch=$(_vault_default_branch)
        echo -e "${BOLD}Branch:${NC} $default_branch (main)"
        echo ""

        # Projects on main
        echo -e "  ${BOLD}Projects:${NC}"
        local has_main_projects=false
        if [[ -d "$vault_dir/projects" ]]; then
            local dir
            for dir in "$vault_dir/projects"/*/; do
                [[ ! -d "$dir" ]] && continue
                has_main_projects=true
                echo "    - $(basename "$dir")"
            done
        fi
        if ! $has_main_projects; then
            echo "    (none)"
        fi

        # Shared resources
        echo ""
        local main_packs=0 main_templates=0
        [[ -d "$vault_dir/packs" ]] && main_packs=$(find "$vault_dir/packs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
        [[ -d "$vault_dir/templates" ]] && main_templates=$(find "$vault_dir/templates" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
        echo -e "  ${BOLD}Shared:${NC} global, $main_templates template(s), $main_packs pack(s)"

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
        return 0
    fi

    local branch
    branch=$(git -C "$vault_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)

    echo -e "${BOLD}Profile:${NC} $profile"
    echo "  Branch: $branch"

    # Sync state with default branch (local comparison)
    local default_branch
    default_branch=$(_vault_default_branch)
    local behind ahead
    behind=$(git -C "$vault_dir" rev-list --count "HEAD..$default_branch" 2>/dev/null || echo "?")
    ahead=$(git -C "$vault_dir" rev-list --count "$default_branch..HEAD" 2>/dev/null || echo "?")
    if [[ "$behind" == "0" && "$ahead" == "0" ]] 2>/dev/null; then
        echo "  Shared sync: up-to-date with $default_branch"
    elif [[ "$behind" != "?" && "$ahead" != "?" ]]; then
        echo "  Shared sync: $ahead ahead, $behind behind $default_branch"
    else
        echo "  Shared sync: unknown"
    fi

    # Exclusive projects — show actual disk state with .vault-profile validation
    local prof_projects prof_packs
    prof_projects=$(_profile_projects)
    prof_packs=$(_profile_packs)

    echo ""
    echo -e "  ${BOLD}Exclusive projects:${NC}"
    local has_projects=false

    # Show projects listed in .vault-profile
    if [[ -n "$prof_projects" ]]; then
        while IFS= read -r p; do
            [[ -z "$p" ]] && continue
            has_projects=true
            if [[ -d "$vault_dir/projects/$p" ]]; then
                echo "    - $p"
            else
                echo -e "    - $p ${YELLOW}(missing from disk)${NC}"
            fi
        done <<< "$prof_projects"
    fi

    # Show projects on disk not in .vault-profile
    if [[ -d "$vault_dir/projects" ]]; then
        local dir
        for dir in "$vault_dir/projects"/*/; do
            [[ ! -d "$dir" ]] && continue
            local pname
            pname=$(basename "$dir")
            if [[ -n "$prof_projects" ]] && echo "$prof_projects" | grep -qxF "$pname"; then
                continue
            fi
            if git -C "$vault_dir" ls-files --error-unmatch "projects/$pname/project.yml" >/dev/null 2>&1; then
                has_projects=true
                echo -e "    - $pname ${YELLOW}(not in .vault-profile)${NC}"
            fi
        done
    fi

    if ! $has_projects; then
        echo "    (none)"
    fi

    # Exclusive packs
    echo ""
    echo -e "  ${BOLD}Exclusive packs:${NC}"
    local has_excl_packs=false
    if [[ -n "$prof_packs" ]]; then
        while IFS= read -r p; do
            [[ -z "$p" ]] && continue
            has_excl_packs=true
            if [[ -d "$vault_dir/packs/$p" ]]; then
                echo "    - $p"
            else
                echo -e "    - $p ${YELLOW}(missing from disk)${NC}"
            fi
        done <<< "$prof_packs"
    fi
    if ! $has_excl_packs; then
        echo "    (none)"
    fi

    # Shared resources
    echo ""
    echo -e "  ${BOLD}Shared (from $default_branch):${NC}"
    echo "    - global/"
    local template_count=0
    [[ -d "$vault_dir/templates" ]] && template_count=$(find "$vault_dir/templates" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    echo "    - templates/ ($template_count template(s))"
    local total_packs=0 exclusive_pack_count=0
    if [[ -d "$vault_dir/packs" ]]; then
        total_packs=$(find "$vault_dir/packs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
        if [[ -n "$prof_packs" ]]; then
            exclusive_pack_count=$(echo "$prof_packs" | grep -c . || true)
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
Usage: cco vault switch <name>

Switch to another vault profile.
Requires a clean working tree (run 'cco vault save "message"' first).
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

    [[ -z "$name" ]] && die "Usage: cco vault switch <name>"

    _check_vault

    local vault_dir="$USER_CONFIG_DIR"
    local current_branch
    current_branch=$(git -C "$vault_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
    local default_branch
    default_branch=$(_vault_default_branch)

    # Allow "main"/"master" as target
    if [[ "$name" == "main" || "$name" == "master" ]]; then
        name="$default_branch"
    fi

    if [[ "$name" == "$current_branch" ]]; then
        info "Already on profile '$name'"
        return 0
    fi

    # Auto-restore framework infrastructure files (D32)
    _restore_missing_gitkeep "$vault_dir"

    # Check 1: Clean working tree (D7 — explicit saves, no auto-commit)
    local status_output
    status_output=$(git -C "$vault_dir" status --porcelain 2>/dev/null)
    if [[ -n "$status_output" ]]; then
        local dirty_count
        dirty_count=$(echo "$status_output" | grep -c . || true)
        die "You have uncommitted changes ($dirty_count files).
  Run 'cco vault save \"message\"' to save your work first."
    fi

    # Check 2: No active Docker sessions (D8)
    _check_no_active_sessions || return 1

    # Check 3: Target exists
    if ! git -C "$vault_dir" rev-parse --verify "$name" >/dev/null 2>&1; then
        die "Profile '$name' not found. Run 'cco vault profile list' to see available profiles."
    fi

    # Step 1-2: Stash portable gitignored files for departing branch
    local current_profile
    current_profile=$(_get_active_profile)
    if [[ -n "$current_profile" ]]; then
        _stash_gitignored_files "$vault_dir" "$current_profile"
        _clean_nonportable_remnants "$vault_dir"
    else
        # On main: stash all projects (exclusive to main)
        _stash_gitignored_files_main "$vault_dir"
    fi

    # Step 4: git checkout target
    if ! git -C "$vault_dir" checkout "$name" -q 2>/dev/null; then
        # Rollback: restore stashed files if checkout failed
        if [[ -n "$current_profile" ]]; then
            _restore_gitignored_files "$vault_dir" "$current_profile"
        else
            _restore_gitignored_files_main "$vault_dir"
        fi
        die "Failed to switch to '$name'. Working tree restored."
    fi

    # Step 5: Clean ghost directories (empty dirs left after git checkout)
    find "$vault_dir/projects" -type d -empty -delete 2>/dev/null || true

    # Step 6: Restore portable gitignored files for arriving branch
    if [[ "$name" == "$default_branch" ]]; then
        _restore_gitignored_files_main "$vault_dir"
    else
        local target_profile
        target_profile=$(yml_get "$vault_dir/.vault-profile" "profile" 2>/dev/null || true)
        if [[ -n "$target_profile" ]]; then
            _restore_gitignored_files "$vault_dir" "$target_profile"
        fi
    fi

    # Step 7: Resolve @local markers from restored local-paths.yml
    _resolve_all_local_paths "$vault_dir"

    # Log operation
    _vault_log_op "$vault_dir" "SWITCH ${current_branch}→${name}"

    # Output
    if [[ "$name" == "$default_branch" ]]; then
        local main_proj_count=0
        if [[ -d "$vault_dir/projects" ]]; then
            main_proj_count=$(find "$vault_dir/projects" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
        fi
        if [[ $main_proj_count -gt 0 ]]; then
            ok "Switched to main ($main_proj_count project(s) + shared resources)"
        else
            ok "Switched to main (shared resources only)"
        fi
    else
        local excl_proj_count=0
        local proj_list
        proj_list=$(_profile_projects)
        if [[ -n "$proj_list" ]]; then
            excl_proj_count=$(echo "$proj_list" | grep -c . || true)
        fi
        ok "Switched to profile '$name'"
        info "$excl_proj_count exclusive project(s) available"
    fi
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

    # Auto-resolve framework infrastructure files (D32/D33)
    _auto_resolve_framework_changes "$vault_dir"

    # Working tree must be clean
    local status_output
    status_output=$(git -C "$vault_dir" status --porcelain 2>/dev/null)
    if [[ -n "$status_output" ]]; then
        die "You have uncommitted changes. Run 'cco vault save' first."
    fi

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

    # Rename shadow directory if it exists
    if [[ -d "$vault_dir/.cco/profile-state/$old_name" ]]; then
        mv "$vault_dir/.cco/profile-state/$old_name" "$vault_dir/.cco/profile-state/$new_name"
    fi

    # Update remote if exists
    if git -C "$vault_dir" remote get-url origin >/dev/null 2>&1; then
        info "Remote tracking updated. Push with: cco vault push"
    fi

    # Log
    _vault_log_op "$vault_dir" "RENAME profile ${old_name}→${new_name}"

    ok "Profile renamed from '$old_name' to '$new_name'"
}

cmd_vault_profile_delete() {
    local name="" auto_yes=false force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes|-y) auto_yes=true; shift ;;
            --force|-f) force=true; shift ;;
            --help)
                cat <<'EOF'
Usage: cco vault profile delete <name> [--yes] [--force]

Delete a vault profile. Requires the profile to be empty (no exclusive
projects or packs). Use --force to delete anyway and move resources to main.
Cannot delete the currently active profile.

Options:
  --yes, -y     Skip confirmation prompt
  --force, -f   Allow deleting non-empty profiles (moves resources to main)
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

    # Verify branch exists
    if ! git -C "$vault_dir" rev-parse --verify "$name" >/dev/null 2>&1; then
        die "Profile '$name' not found"
    fi

    # Auto-restore framework infrastructure files (D32)
    _restore_missing_gitkeep "$vault_dir"

    # Working tree must be clean (§6.9)
    local status_output
    status_output=$(git -C "$vault_dir" status --porcelain 2>/dev/null)
    [[ -n "$status_output" ]] && die "You have uncommitted changes. Run 'cco vault save' first."

    # No active Docker sessions — profile delete may involve branch operations (D31)
    _check_no_active_sessions || return 1

    # Read exclusive resources from the profile branch (§6.6)
    local profile_content
    profile_content=$(git -C "$vault_dir" show "$name:.vault-profile" 2>/dev/null || true)

    local excl_projects="" excl_packs=""
    if [[ -n "$profile_content" ]]; then
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
    fi

    local proj_count=0 pack_count=0
    [[ -n "$excl_projects" ]] && proj_count=$(echo "$excl_projects" | grep -c . || true)
    [[ -n "$excl_packs" ]] && pack_count=$(echo "$excl_packs" | grep -c . || true)

    # Block delete of non-empty profiles unless --force
    if [[ $proj_count -gt 0 || $pack_count -gt 0 ]] && ! $force; then
        error "Profile '$name' has $proj_count project(s) and $pack_count pack(s)."
        echo "  Move resources first, or use --force to delete and move them to main." >&2
        if [[ -n "$excl_projects" ]]; then
            echo "  Projects:" >&2
            while IFS= read -r _p; do
                [[ -n "$_p" ]] && echo "    - $_p" >&2
            done <<< "$excl_projects"
        fi
        if [[ -n "$excl_packs" ]]; then
            echo "  Packs:" >&2
            while IFS= read -r _p; do
                [[ -n "$_p" ]] && echo "    - $_p" >&2
            done <<< "$excl_packs"
        fi
        return 1
    fi

    # Confirmation
    if ! $auto_yes; then
        if [[ ! -t 0 ]]; then
            die "Profile delete requires interactive confirmation (use --yes to skip)"
        fi
        echo "" >&2
        if [[ $proj_count -gt 0 || $pack_count -gt 0 ]]; then
            echo "Deleting profile '$name' (--force: moving resources to main):" >&2
            if [[ -n "$excl_projects" ]]; then
                echo "  Projects ($proj_count):" >&2
                while IFS= read -r _p; do
                    [[ -n "$_p" ]] && echo "    - $_p" >&2
                done <<< "$excl_projects"
            fi
            if [[ -n "$excl_packs" ]]; then
                echo "  Packs ($pack_count):" >&2
                while IFS= read -r _p; do
                    [[ -n "$_p" ]] && echo "    - $_p" >&2
                done <<< "$excl_packs"
            fi
        else
            echo "Deleting empty profile '$name'." >&2
        fi
        printf "\nProceed? [y/N] " >&2
        local reply
        read -r reply
        if [[ ! "$reply" =~ ^[Yy]$ ]]; then
            info "Aborted"
            return 0
        fi
    fi

    local _default_branch
    _default_branch=$(_vault_default_branch)
    local moved=0

    # Step 2: Move exclusive resources to main
    local -a move_paths=()
    if [[ -n "$excl_projects" ]]; then
        while IFS= read -r proj; do
            [[ -z "$proj" ]] && continue
            if git -C "$vault_dir" ls-tree "$name" -- "projects/$proj/" >/dev/null 2>&1 && \
               [[ -n "$(git -C "$vault_dir" ls-tree "$name" -- "projects/$proj/" 2>/dev/null)" ]]; then
                move_paths+=("projects/$proj/")
                ((moved++)) || true
            fi
        done <<< "$excl_projects"
    fi
    if [[ -n "$excl_packs" ]]; then
        while IFS= read -r pack; do
            [[ -z "$pack" ]] && continue
            if git -C "$vault_dir" ls-tree "$name" -- "packs/$pack/" >/dev/null 2>&1 && \
               [[ -n "$(git -C "$vault_dir" ls-tree "$name" -- "packs/$pack/" 2>/dev/null)" ]]; then
                move_paths+=("packs/$pack/")
                ((moved++)) || true
            fi
        done <<< "$excl_packs"
    fi

    if [[ $moved -gt 0 ]]; then
        if ! git -C "$vault_dir" checkout "$_default_branch" -q 2>/dev/null; then
            die "Failed to checkout '$_default_branch' — profile delete aborted. No changes made."
        fi
        for rpath in ${move_paths[@]+"${move_paths[@]}"}; do
            git -C "$vault_dir" checkout "$name" -- "$rpath" 2>/dev/null || true
        done
        git -C "$vault_dir" add -A -- ${move_paths[@]+"${move_paths[@]}"} 2>/dev/null || true
        if ! git -C "$vault_dir" diff --cached --quiet 2>/dev/null; then
            git -C "$vault_dir" commit -q -m "vault: rescue resources from deleted profile '$name'"
        fi
        ok "Moved $moved resource(s) to main"

        # Step 3: Move portable gitignored files from shadow dir while still on default branch.
        # The rescued projects' tracked files are on this branch — shadow files must land here.
        if [[ -n "$excl_projects" ]]; then
            while IFS= read -r proj; do
                [[ -z "$proj" ]] && continue
                local shadow_proj="$vault_dir/.cco/profile-state/$name/projects/$proj"
                [[ ! -d "$shadow_proj" ]] && continue
                local proj_dir="$vault_dir/projects/$proj"

                if [[ -d "$shadow_proj/.cco/claude-state" ]]; then
                    mkdir -p "$proj_dir/.cco"
                    mv "$shadow_proj/.cco/claude-state" "$proj_dir/.cco/claude-state"
                fi
                if [[ -f "$shadow_proj/.cco/meta" ]]; then
                    mkdir -p "$proj_dir/.cco"
                    mv "$shadow_proj/.cco/meta" "$proj_dir/.cco/meta"
                fi
                for pattern in "${_PORTABLE_FILE_PATTERNS[@]}"; do
                    while IFS= read -r fpath; do
                        [[ -z "$fpath" ]] && continue
                        local fname
                        fname=$(basename "$fpath")
                        mkdir -p "$proj_dir"
                        mv "$fpath" "$proj_dir/$fname"
                    done < <(find "$shadow_proj" -maxdepth 1 -name "$pattern" -type f 2>/dev/null)
                done
            done <<< "$excl_projects"
        fi
    fi
    # Always restore original branch
    git -C "$vault_dir" checkout "$current_branch" -q

    # Step 4: Delete the profile branch
    git -C "$vault_dir" branch -D "$name" -q 2>/dev/null

    # Delete remote branch if exists
    if git -C "$vault_dir" remote get-url origin >/dev/null 2>&1; then
        git -C "$vault_dir" push origin --delete "$name" -q 2>/dev/null || true
    fi

    # Step 5: Clean up shadow directory
    rm -rf "$vault_dir/.cco/profile-state/$name/"

    # Step 6: Log
    _vault_log_op "$vault_dir" "DELETE profile $name (moved $moved resources to main)"

    ok "Deleted profile '$name'"
}

# ── Profile resource management (real isolation) ─────────────────────

# Deprecated: use 'vault move' instead
cmd_vault_profile_add() {
    local resource_type="${1:-}"
    if [[ "$resource_type" == "--help" || -z "$resource_type" ]]; then
        cat <<'EOF'
Usage: cco vault move <project|pack> <name> <target>

'vault profile add' is deprecated. Use 'vault move' instead.
EOF
        return 0
    fi
    warn "'vault profile add' is deprecated. Use 'vault move' instead."
    cmd_vault_profile_move "$@"
}

# vault remove <project|pack> <name> — delete from current branch (§6.3-6.4)
cmd_vault_profile_remove() {
    local resource_type="${1:-}"
    local name=""
    local auto_yes=false

    if [[ "$resource_type" == "--help" || -z "$resource_type" ]]; then
        cat <<'EOF'
Usage: cco vault remove <project|pack> <name> [--yes]

Remove a project or pack from the current branch.
If this is the last copy, a backup is created in .cco/backups/.

Options:
  --yes, -y   Skip confirmation prompt
EOF
        return 0
    fi

    # Parse remaining args after resource_type
    shift  # consume resource_type
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes|-y) auto_yes=true; shift ;;
            --help)
                cat <<'EOF'
Usage: cco vault remove <project|pack> <name> [--yes]
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

    [[ -z "$name" ]] && die "Usage: cco vault remove <project|pack> <name>"
    [[ "$resource_type" != "project" && "$resource_type" != "pack" ]] && \
        die "Resource type must be 'project' or 'pack'"

    _check_vault

    local vault_dir="$USER_CONFIG_DIR"
    local current_branch
    current_branch=$(git -C "$vault_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
    local resource_path
    if [[ "$resource_type" == "project" ]]; then
        resource_path="projects/$name"
    else
        resource_path="packs/$name"
    fi

    [[ ! -d "$vault_dir/$resource_path" ]] && die "$(echo "$resource_type" | awk '{print toupper(substr($0,1,1)) substr($0,2)}') '$name' not found on current branch"

    # Block removing a shared pack from a profile (it would be re-synced from main)
    local default_branch
    default_branch=$(_vault_default_branch)
    if [[ "$resource_type" == "pack" && "$current_branch" != "$default_branch" ]]; then
        local profile
        profile=$(_get_active_profile)
        if [[ -n "$profile" ]]; then
            local prof_packs
            prof_packs=$(_profile_packs)
            if [[ -z "$prof_packs" ]] || ! echo "$prof_packs" | grep -qxF "$name"; then
                die "Pack '$name' is shared (lives on main). Remove it from main instead:
  cco vault switch main && cco vault remove pack $name"
            fi
        fi
    fi

    # Auto-restore framework infrastructure files (D32)
    _restore_missing_gitkeep "$vault_dir"

    # Working tree must be clean
    local status_output
    status_output=$(git -C "$vault_dir" status --porcelain 2>/dev/null)
    [[ -n "$status_output" ]] && die "You have uncommitted changes. Run 'cco vault save' first."

    # Block if the specific project has an active Docker session (D31)
    if [[ "$resource_type" == "project" ]]; then
        _check_project_not_active "$name" || return 1
    fi

    # Check if project/pack exists on other branches
    local other_branches=""
    while IFS= read -r branch; do
        [[ -z "$branch" ]] && continue
        branch=$(echo "$branch" | sed 's/^[ *]*//')
        [[ "$branch" == "$current_branch" ]] && continue
        if git -C "$vault_dir" ls-tree "$branch" -- "$resource_path/" >/dev/null 2>&1 && \
           [[ -n "$(git -C "$vault_dir" ls-tree "$branch" -- "$resource_path/" 2>/dev/null)" ]]; then
            other_branches+="$branch "
        fi
    done < <(git -C "$vault_dir" branch 2>/dev/null)

    local is_last_copy=false
    [[ -z "$other_branches" ]] && is_last_copy=true

    # Count tracked files
    local tracked_count
    tracked_count=$(git -C "$vault_dir" ls-tree -r --name-only HEAD -- "$resource_path/" 2>/dev/null | grep -c . || true)

    # Confirmation
    if ! $auto_yes; then
        if [[ ! -t 0 ]]; then
            die "Remove requires interactive confirmation (use --yes to skip)"
        fi
        echo "" >&2
        if $is_last_copy; then
            warn "Removing $resource_type '$name' from '$current_branch':"
            echo "  Tracked files: $tracked_count file(s) (will be deleted)" >&2
            echo "  !! THIS IS THE LAST COPY — no other branch has this $resource_type !!" >&2
            echo "  A backup will be created at .cco/backups/" >&2
        else
            echo "Removing $resource_type '$name' from '$current_branch':" >&2
            echo "  Tracked files: $tracked_count file(s) (will be deleted)" >&2
            echo "  This $resource_type also exists on: $other_branches" >&2
        fi
        printf "\nProceed? [y/N] " >&2
        local reply
        read -r reply
        if [[ ! "$reply" =~ ^[Yy]$ ]]; then
            info "Aborted"
            return 0
        fi
    fi

    # Backup if last copy
    if $is_last_copy; then
        mkdir -p "$vault_dir/.cco/backups"
        local backup_name="${resource_type}-${name}-$(date +%Y%m%d-%H%M%S).tar.gz"
        tar czf "$vault_dir/.cco/backups/$backup_name" \
            -C "$vault_dir" "$resource_path/" 2>/dev/null || true
        ok "Backup saved to .cco/backups/$backup_name"
    fi

    # git rm tracked files
    git -C "$vault_dir" rm -r "$resource_path/" -q 2>/dev/null || true

    # Update .vault-profile if on a profile branch
    local profile
    profile=$(_get_active_profile)
    if [[ -n "$profile" ]]; then
        if [[ "$resource_type" == "project" ]]; then
            _profile_remove_from_list "projects" "$name"
        else
            _profile_remove_from_list "packs" "$name"
        fi
        git -C "$vault_dir" add -A -- .vault-profile
    fi

    if ! git -C "$vault_dir" diff --cached --quiet 2>/dev/null; then
        git -C "$vault_dir" commit -q -m "vault: remove $resource_type '$name' from ${profile:-$current_branch}"
    fi

    # Force-remove: vault remove is an explicit deletion (backup already created)
    _force_remove_dir "$vault_dir/$resource_path"

    # Clean shadow directory entry for this resource
    if [[ -n "$profile" && "$resource_type" == "project" ]]; then
        rm -rf "$vault_dir/.cco/profile-state/$profile/projects/$name/"
    fi

    # Clean shared pack copies from profiles when removing from main
    local default_branch
    default_branch=$(_vault_default_branch)
    if [[ "$resource_type" == "pack" && "$current_branch" == "$default_branch" ]]; then
        # Branch switching required — check no Docker sessions active (D31)
        _check_no_active_sessions || return 1
        while IFS= read -r pb; do
            [[ -z "$pb" ]] && continue
            if [[ -n "$(git -C "$vault_dir" ls-tree "$pb" -- "$resource_path/" 2>/dev/null)" ]]; then
                git -C "$vault_dir" checkout "$pb" -q
                git -C "$vault_dir" rm -r "$resource_path/" -q 2>/dev/null || true
                if ! git -C "$vault_dir" diff --cached --quiet 2>/dev/null; then
                    git -C "$vault_dir" commit -q -m "vault: remove shared pack '$name' (deleted from main)"
                fi
            fi
        done < <(_list_profile_branches)
        git -C "$vault_dir" checkout "$current_branch" -q
    fi

    # Log
    _vault_log_op "$vault_dir" "REMOVE $resource_type $name from ${profile:-$current_branch}"

    ok "Removed $resource_type '$name' from ${profile:-$current_branch}"
}

# vault move <project|pack> <name> <target> — real git move (§6.1-6.2)
cmd_vault_profile_move() {
    local resource_type="${1:-}"
    local name=""
    local target=""
    local auto_yes=false

    if [[ "$resource_type" == "--help" || -z "$resource_type" ]]; then
        cat <<'EOF'
Usage: cco vault move <project|pack> <name> <target> [--yes]

Move a project or pack from the current branch to <target>.
The resource is copied to the target branch and removed from the source.

Options:
  --yes, -y   Skip confirmation prompt
EOF
        return 0
    fi

    shift  # consume resource_type

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --to) target="$2"; shift 2 ;;  # --to accepted as alias
            --yes|-y) auto_yes=true; shift ;;
            --help)
                cat <<'EOF'
Usage: cco vault move <project|pack> <name> <target> [--yes]
EOF
                return 0
                ;;
            -*) die "Unknown option: $1" ;;
            *)
                if [[ -z "$name" ]]; then
                    name="$1"; shift
                elif [[ -z "$target" ]]; then
                    target="$1"; shift
                else
                    die "Unexpected argument: $1"
                fi
                ;;
        esac
    done

    [[ -z "$name" ]] && die "Usage: cco vault move <project|pack> <name> <target>"
    [[ -z "$target" ]] && die "Missing target. Usage: cco vault move <project|pack> <name> <target>"
    [[ "$resource_type" != "project" && "$resource_type" != "pack" ]] && \
        die "Resource type must be 'project' or 'pack'"

    _check_vault

    local vault_dir="$USER_CONFIG_DIR"
    local default_branch
    default_branch=$(_vault_default_branch)
    local current_branch
    current_branch=$(git -C "$vault_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)

    # Normalize target
    if [[ "$target" == "main" || "$target" == "master" ]]; then
        target="$default_branch"
    fi

    local resource_path
    if [[ "$resource_type" == "project" ]]; then
        resource_path="projects/$name"
    else
        resource_path="packs/$name"
    fi

    local type_label
    type_label=$(echo "$resource_type" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')

    # Auto-detect source branch: find where the resource is authoritative.
    # For packs: shared packs exist on ALL branches (synced). The authoritative
    # source is main unless the pack is exclusive to a profile (listed in .vault-profile).
    local source_branch=""
    if [[ "$resource_type" == "pack" ]]; then
        # Check if pack is exclusive to a profile branch
        while IFS= read -r _branch; do
            [[ -z "$_branch" ]] && continue
            local _vp
            _vp=$(git -C "$vault_dir" show "$_branch:.vault-profile" 2>/dev/null || true)
            if [[ -n "$_vp" ]] && echo "$_vp" | awk -v res="$name" '
                /^  packs:/ { in_list=1; next }
                /^[^ ]/ { in_list=0 }
                in_list && /^    - / { sub(/^    - */, ""); if ($0 == res) found=1 }
                END { exit (found ? 0 : 1) }
            '; then
                source_branch="$_branch"
                break
            fi
        done < <(_list_profile_branches)
        # If not exclusive to any profile, source is main (shared)
        if [[ -z "$source_branch" ]] && \
           [[ -n "$(git -C "$vault_dir" ls-tree "$default_branch" -- "$resource_path/" 2>/dev/null)" ]]; then
            source_branch="$default_branch"
        fi
    else
        # For projects: find which branch has tracked files
        if [[ -n "$(git -C "$vault_dir" ls-tree HEAD -- "$resource_path/" 2>/dev/null)" ]]; then
            source_branch="$current_branch"
        elif [[ -n "$(git -C "$vault_dir" ls-tree "$default_branch" -- "$resource_path/" 2>/dev/null)" ]]; then
            source_branch="$default_branch"
        else
            while IFS= read -r _branch; do
                [[ -z "$_branch" ]] && continue
                if [[ -n "$(git -C "$vault_dir" ls-tree "$_branch" -- "$resource_path/" 2>/dev/null)" ]]; then
                    source_branch="$_branch"
                    break
                fi
            done < <(_list_profile_branches)
        fi
    fi

    [[ -z "$source_branch" ]] && die "$type_label '$name' not found on any branch"
    [[ "$source_branch" == "$target" ]] && die "$type_label '$name' is already on '$target'"

    # Auto-restore framework infrastructure files (D32)
    _restore_missing_gitkeep "$vault_dir"

    # Working tree must be clean
    local status_output
    status_output=$(git -C "$vault_dir" status --porcelain 2>/dev/null)
    [[ -n "$status_output" ]] && die "You have uncommitted changes. Run 'cco vault save' first."

    # No active Docker sessions — move involves branch switching (D31)
    _check_no_active_sessions || return 1

    # Verify target branch exists
    if [[ "$target" != "$default_branch" ]]; then
        if ! git -C "$vault_dir" rev-parse --verify "$target" >/dev/null 2>&1; then
            die "Profile '$target' not found"
        fi
    fi

    # Switch to source branch if needed
    if [[ "$current_branch" != "$source_branch" ]]; then
        git -C "$vault_dir" checkout "$source_branch" -q
    fi

    # Count tracked files for summary
    local tracked_count
    tracked_count=$(git -C "$vault_dir" ls-tree -r --name-only HEAD -- "$resource_path/" 2>/dev/null | grep -c . || true)

    # Step 1: Detect if target already has this resource (§6.1)
    local target_has_resource=false conflict_detected=false
    if git -C "$vault_dir" ls-tree "$target" -- "$resource_path/" >/dev/null 2>&1 && \
       [[ -n "$(git -C "$vault_dir" ls-tree "$target" -- "$resource_path/" 2>/dev/null)" ]]; then
        target_has_resource=true
        local diff_output
        diff_output=$(git -C "$vault_dir" diff "$target" "$source_branch" -- "$resource_path/" 2>/dev/null || true)
        [[ -n "$diff_output" ]] && conflict_detected=true
    fi

    # Step 2: Confirmation (includes conflict info)
    if ! $auto_yes; then
        if [[ ! -t 0 ]]; then
            die "Move requires interactive confirmation (use --yes to skip)"
        fi
        echo "" >&2
        echo "Moving $resource_type '$name':" >&2
        echo "  From: $source_branch → To: $target" >&2
        echo "  Tracked files: $tracked_count file(s)" >&2
        if $conflict_detected; then
            warn "$resource_type '$name' already exists on '$target' with different content."
            printf "\n  This will overwrite the target version. Proceed? [y/N] " >&2
        else
            printf "\nProceed? [y/N] " >&2
        fi
        local reply
        read -r reply
        if [[ ! "$reply" =~ ^[Yy]$ ]]; then
            # Return to original branch if we switched away
            if [[ "$current_branch" != "$source_branch" ]]; then
                git -C "$vault_dir" checkout "$current_branch" -q
            fi
            info "Aborted"
            return 0
        fi
    elif $conflict_detected; then
        # --yes mode: warn about conflict but proceed
        warn "$resource_type '$name' already exists on '$target' — overwriting (--yes)."
    fi

    # Step 3: Copy tracked files to target
    git -C "$vault_dir" checkout "$target" -q
    git -C "$vault_dir" checkout "$source_branch" -- "$resource_path/"

    # Update .vault-profile on target (if target is a profile, not main)
    if [[ "$target" != "$default_branch" ]]; then
        _profile_add_to_list "${resource_type}s" "$name"
        git -C "$vault_dir" add -A -- "$resource_path/" .vault-profile
    else
        git -C "$vault_dir" add -A -- "$resource_path/"
    fi
    if ! git -C "$vault_dir" diff --cached --quiet 2>/dev/null; then
        git -C "$vault_dir" commit -q -m "vault: add $resource_type '$name' (moved from $source_branch)"
    fi
    git -C "$vault_dir" checkout "$source_branch" -q

    # Step 4: Move portable gitignored files to target shadow directory (projects only)
    if [[ "$resource_type" == "project" ]]; then
        # Use actual branch name as shadow key (consistent with stash/restore helpers)
        local shadow_base="$vault_dir/.cco/profile-state/$target/projects/$name"

        # Determine source shadow directory (files may be stashed there during switch/create)
        local source_shadow_name
        if [[ "$source_branch" == "$default_branch" ]]; then
            source_shadow_name="$default_branch"
        else
            source_shadow_name="$source_branch"
        fi
        local source_shadow="$vault_dir/.cco/profile-state/$source_shadow_name/projects/$name"

        # Move from disk (if present)
        if [[ -d "$vault_dir/$resource_path/.cco/claude-state" ]]; then
            mkdir -p "$shadow_base/.cco"
            mv "$vault_dir/$resource_path/.cco/claude-state" "$shadow_base/.cco/claude-state"
        fi
        if [[ -f "$vault_dir/$resource_path/.cco/meta" ]]; then
            mkdir -p "$shadow_base/.cco"
            mv "$vault_dir/$resource_path/.cco/meta" "$shadow_base/.cco/meta"
        fi
        for pattern in "${_PORTABLE_FILE_PATTERNS[@]}"; do
            while IFS= read -r fpath; do
                [[ -z "$fpath" ]] && continue
                mkdir -p "$shadow_base"
                mv "$fpath" "$shadow_base/$(basename "$fpath")"
            done < <(find "$vault_dir/$resource_path" -maxdepth 1 -name "$pattern" -type f 2>/dev/null)
        done

        # Also move from source's shadow directory (files stashed during profile create/switch)
        if [[ -d "$source_shadow" ]]; then
            # claude-state
            if [[ -d "$source_shadow/.cco/claude-state" && ! -d "$shadow_base/.cco/claude-state" ]]; then
                mkdir -p "$shadow_base/.cco"
                mv "$source_shadow/.cco/claude-state" "$shadow_base/.cco/claude-state"
            fi
            # .cco/meta
            if [[ -f "$source_shadow/.cco/meta" && ! -f "$shadow_base/.cco/meta" ]]; then
                mkdir -p "$shadow_base/.cco"
                mv "$source_shadow/.cco/meta" "$shadow_base/.cco/meta"
            fi
            # secret/portable files
            for pattern in "${_PORTABLE_FILE_PATTERNS[@]}"; do
                while IFS= read -r fpath; do
                    [[ -z "$fpath" ]] && continue
                    local fname
                    fname=$(basename "$fpath")
                    if [[ ! -f "$shadow_base/$fname" ]]; then
                        mkdir -p "$shadow_base"
                        mv "$fpath" "$shadow_base/$fname"
                    fi
                done < <(find "$source_shadow" -maxdepth 1 -name "$pattern" -type f 2>/dev/null)
            done
            # Clean source shadow
            rm -rf "$source_shadow"
        fi
    fi

    # Step 5: Remove tracked files from source
    git -C "$vault_dir" rm -r "$resource_path/" -q 2>/dev/null || true

    # Update .vault-profile on source (remove from list if applicable)
    local profile
    profile=$(_get_active_profile)
    if [[ -n "$profile" ]]; then
        if [[ "$resource_type" == "project" ]]; then
            _profile_remove_from_list "projects" "$name"
        else
            _profile_remove_from_list "packs" "$name"
        fi
        git -C "$vault_dir" add -A -- .vault-profile
    fi
    if ! git -C "$vault_dir" diff --cached --quiet 2>/dev/null; then
        git -C "$vault_dir" commit -q -m "vault: remove $resource_type '$name' (moved to $target)"
    fi

    # Step 6: Verify all valuable files were stashed, then clean remnants
    _safe_remove_resource_dir "$vault_dir" "$resource_path" "vault move" || true

    # Step 7: Log
    _vault_log_op "$vault_dir" "MOVE $resource_type $name ${source_branch}→${target}"

    # Return to original branch if we switched away
    if [[ "$current_branch" != "$source_branch" ]]; then
        git -C "$vault_dir" checkout "$current_branch" -q
    fi

    ok "Moved $resource_type '$name' from '$source_branch' to '$target'"

    # Clean shared pack copies from other profiles when making exclusive (§6.2)
    # When a shared pack (on main) is moved to a profile, it becomes exclusive.
    # All other branches still have the synced copy — remove it from each.
    if [[ "$resource_type" == "pack" && "$source_branch" == "$default_branch" ]]; then
        local cleaned_profiles=""
        while IFS= read -r pb; do
            [[ -z "$pb" ]] && continue
            [[ "$pb" == "$target" ]] && continue
            if [[ -n "$(git -C "$vault_dir" ls-tree "$pb" -- "$resource_path/" 2>/dev/null)" ]]; then
                git -C "$vault_dir" checkout "$pb" -q
                git -C "$vault_dir" rm -r "$resource_path/" -q 2>/dev/null || true
                if ! git -C "$vault_dir" diff --cached --quiet 2>/dev/null; then
                    git -C "$vault_dir" commit -q -m "vault: remove shared pack '$name' (now exclusive to $target)"
                fi
                cleaned_profiles+="$pb "
            fi
        done < <(_list_profile_branches)
        # Return to the branch we should be on
        if [[ -n "$cleaned_profiles" ]]; then
            git -C "$vault_dir" checkout "$current_branch" -q
            info "Removed shared copies from: $cleaned_profiles"
        fi
    fi
}

# ── Shared resource sync helpers ──────────────────────────────────────

# List shared resource paths (everything NOT exclusive to ANY profile — §8.2)
_list_shared_paths() {
    local vault_dir="$1"
    local paths=("global/" "templates/" ".gitignore" "manifest.yml")

    # Shared packs: exclude packs that are exclusive to any profile
    if [[ -d "$vault_dir/packs" ]]; then
        for pack_dir in "$vault_dir"/packs/*/; do
            [[ ! -d "$pack_dir" ]] && continue
            local pack_name
            pack_name=$(basename "$pack_dir")
            if ! _is_exclusive_pack "$pack_name"; then
                paths+=("packs/$pack_name/")
            fi
        done
    fi

    printf '%s\n' "${paths[@]}"
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

    # Defensive: ensure .gitignore has profile-related entries (may be missing
    # if vault was init'd before profile isolation was added)
    local _gi="$USER_CONFIG_DIR/.gitignore"
    if [[ -f "$_gi" ]]; then
        local _gi_updated=false
        for _pattern in ".cco/profile-ops.log" ".cco/profile-state/" ".cco/backups/"; do
            if ! grep -qF "$_pattern" "$_gi" 2>/dev/null; then
                printf '\n# Profile operations\n%s\n' "$_pattern" >> "$_gi"
                _gi_updated=true
            fi
        done
        if $_gi_updated; then
            git -C "$USER_CONFIG_DIR" add .gitignore 2>/dev/null || true
            if ! git -C "$USER_CONFIG_DIR" diff --cached --quiet 2>/dev/null; then
                git -C "$USER_CONFIG_DIR" commit -q -m "vault: update .gitignore for profile operations"
            fi
        fi
    fi

    # Defensive: untrack profile-ops.log if it was committed before gitignore update
    if git -C "$USER_CONFIG_DIR" ls-files --error-unmatch .cco/profile-ops.log >/dev/null 2>&1; then
        git -C "$USER_CONFIG_DIR" rm --cached -q .cco/profile-ops.log 2>/dev/null || true
        if ! git -C "$USER_CONFIG_DIR" diff --cached --quiet 2>/dev/null; then
            git -C "$USER_CONFIG_DIR" commit -q -m "vault: untrack profile-ops.log (gitignored)"
        fi
    fi

    # Self-healing: restore shadow files if user did a direct git checkout.
    # When cco vault switch runs, it stashes portable files to .cco/profile-state/<branch>/.
    # If the user ran git checkout directly, the restore step was skipped.
    # Detect: shadow dir exists for current branch AND target files are missing on disk.
    local _current_branch
    _current_branch=$(git -C "$USER_CONFIG_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)
    local _default_branch
    _default_branch=$(_vault_default_branch)
    local _shadow_name
    if [[ "$_current_branch" == "$_default_branch" ]]; then
        _shadow_name="$_default_branch"
    else
        _shadow_name="$_current_branch"
    fi
    local _shadow_dir="$USER_CONFIG_DIR/.cco/profile-state/$_shadow_name"
    if [[ -d "$_shadow_dir/projects" ]]; then
        local _restored=false
        for _shadow_proj in "$_shadow_dir"/projects/*/; do
            [[ ! -d "$_shadow_proj" ]] && continue
            local _proj_name
            _proj_name=$(basename "$_shadow_proj")
            local _proj_dir="$USER_CONFIG_DIR/projects/$_proj_name"
            # Only restore if the project exists on this branch (tracked files present)
            if [[ ! -d "$_proj_dir" ]] || \
               [[ -z "$(git -C "$USER_CONFIG_DIR" ls-tree HEAD -- "projects/$_proj_name/" 2>/dev/null)" ]]; then
                continue
            fi
            # Restore claude-state
            if [[ -d "$_shadow_proj/.cco/claude-state" && ! -d "$_proj_dir/.cco/claude-state" ]]; then
                mkdir -p "$_proj_dir/.cco"
                mv "$_shadow_proj/.cco/claude-state" "$_proj_dir/.cco/claude-state"
                _restored=true
            fi
            # Restore .cco/meta
            if [[ -f "$_shadow_proj/.cco/meta" && ! -f "$_proj_dir/.cco/meta" ]]; then
                mkdir -p "$_proj_dir/.cco"
                mv "$_shadow_proj/.cco/meta" "$_proj_dir/.cco/meta"
                _restored=true
            fi
            # Restore portable files (secrets.env, *.env, *.key, *.pem)
            for _pattern in "${_PORTABLE_FILE_PATTERNS[@]}"; do
                while IFS= read -r _fpath; do
                    [[ -z "$_fpath" ]] && continue
                    local _fname
                    _fname=$(basename "$_fpath")
                    if [[ ! -f "$_proj_dir/$_fname" ]]; then
                        mkdir -p "$_proj_dir"
                        mv "$_fpath" "$_proj_dir/$_fname"
                        _restored=true
                    fi
                done < <(find "$_shadow_proj" -maxdepth 1 -name "$_pattern" -type f 2>/dev/null)
            done
        done
        if $_restored; then
            warn "Restored portable files from shadow (direct git checkout detected)"
        fi
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
  save [msg] [--yes]      Commit current state with secret detection
  diff                    Show uncommitted changes by category
  log [--limit N]         Show commit history
  restore <ref>           Restore config to a previous state
  status                  Show vault state and sync info

Profile operations (shortcuts):
  switch <name>           Switch to another profile
  move <type> <name> <target>  Move a resource between profiles
  remove <type> <name>    Remove a resource from current profile

Profile management:
  profile create <name>   Create a new vault profile
  profile list            List all profiles
  profile show            Show current profile details
  profile switch <name>   Switch to another profile (alias)
  profile rename <name>   Rename current profile
  profile delete <name>   Delete a profile

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
        save)    cmd_vault_save "$@" ;;
        sync)    cmd_vault_sync "$@" ;;
        diff)    cmd_vault_diff "$@" ;;
        log)     cmd_vault_log "$@" ;;
        restore) cmd_vault_restore "$@" ;;
        switch)  cmd_vault_profile_switch "$@" ;;
        move)    cmd_vault_profile_move "$@" ;;
        remove)  cmd_vault_profile_remove "$@" ;;
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
