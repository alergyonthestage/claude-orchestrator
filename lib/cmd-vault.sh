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
projects/*/docker-compose.yml
projects/*/.managed/
projects/*/.pack-manifest
projects/*/.cco-meta

# Session state — transient, large, personal
global/claude-state/
projects/*/claude-state/
projects/*/rag-data/

# Pack install temporary files
packs/*/.cco-install-tmp/

# Machine-specific remote config
.cco-remotes
'

# ── Secret patterns for pre-commit scan ───────────────────────────────

_VAULT_SECRET_PATTERNS=(
    'secrets.env'
    '*.env'
    '*.key'
    '*.pem'
    '.credentials.json'
    '.cco-remotes'
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
        for pattern in "${_VAULT_SECRET_PATTERNS[@]}"; do
            local basename_file
            basename_file=$(basename "$file")
            # Match exact name or glob pattern
            if [[ "$basename_file" == $pattern ]]; then
                secret_files+=("$file")
                break
            fi
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

    # Commit
    git -C "$vault_dir" add -A
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

    # Delegate to cco remote for add/remove (keeps .cco-remotes in sync)
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
    local remote="${1:-}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                cat <<'EOF'
Usage: cco vault push [<remote>]

Push vault commits to a remote (default: origin).
EOF
                return 0
                ;;
            -*) die "Unknown option: $1" ;;
            *)  remote="$1"; shift ;;
        esac
    done

    _check_vault
    remote="${remote:-origin}"

    local branch
    branch=$(git -C "$USER_CONFIG_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)
    git -C "$USER_CONFIG_DIR" push -u "$remote" "$branch"
    ok "Pushed to $remote/$branch"
}

cmd_vault_pull() {
    local remote="${1:-}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                cat <<'EOF'
Usage: cco vault pull [<remote>]

Pull vault updates from a remote (default: origin).
EOF
                return 0
                ;;
            -*) die "Unknown option: $1" ;;
            *)  remote="$1"; shift ;;
        esac
    done

    _check_vault
    remote="${remote:-origin}"
    git -C "$USER_CONFIG_DIR" pull "$remote"
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

    # Branch
    local branch
    branch=$(git -C "$vault_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
    echo "  Branch: $branch"

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

# ── Internal helpers ──────────────────────────────────────────────────

_check_vault() {
    if [[ ! -d "$USER_CONFIG_DIR/.git" ]]; then
        die "Vault not initialized. Run 'cco vault init' first."
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
        remote)  cmd_vault_remote "$@" ;;
        push)    cmd_vault_push "$@" ;;
        pull)    cmd_vault_pull "$@" ;;
        status)  cmd_vault_status "$@" ;;
        *)
            die "Unknown vault command: $subcmd. Run 'cco vault --help'."
            ;;
    esac
}
