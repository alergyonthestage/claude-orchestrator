#!/usr/bin/env bash
# lib/cmd-remote.sh — Top-level remote management
#
# Provides: cmd_remote(), remote_get_url(), remote_list_names()
# Dependencies: colors.sh, utils.sh
# Globals: USER_CONFIG_DIR

_remotes_file() { echo "$USER_CONFIG_DIR/.cco-remotes"; }

# ── Public helpers (used by other commands) ──────────────────────────

# Resolve a remote name to its URL.
# Returns the URL on stdout, or returns 1 if not found.
remote_get_url() {
    local name="$1"
    local rf; rf=$(_remotes_file)
    [[ ! -f "$rf" ]] && return 1
    local line
    line=$(grep -m1 "^${name}=" "$rf" 2>/dev/null) || return 1
    echo "${line#*=}"
}

# List all remote names (one per line).
remote_list_names() {
    local rf; rf=$(_remotes_file)
    [[ ! -f "$rf" ]] && return 0
    grep -v '^#' "$rf" | grep -v '^$' | cut -d= -f1
}

# ── Subcommands ──────────────────────────────────────────────────────

_cmd_remote_add() {
    local name="${1:-}" url="${2:-}"

    if [[ -z "$name" || -z "$url" ]]; then
        die "Usage: cco remote add <name> <url>"
    fi

    # Validate name: lowercase, alphanumeric, hyphens
    if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
        die "Invalid remote name '$name'. Use lowercase letters, numbers, and hyphens."
    fi

    # Validate URL: must contain : or /
    if [[ "$url" != *:* && "$url" != */* ]]; then
        die "Invalid URL '$url'. Expected a git URL or path."
    fi

    local rf; rf=$(_remotes_file)

    # Check for duplicates
    if [[ -f "$rf" ]] && grep -q "^${name}=" "$rf" 2>/dev/null; then
        die "Remote '$name' already exists. Remove it first with 'cco remote remove $name'."
    fi

    # Create file with header if new
    if [[ ! -f "$rf" ]]; then
        echo "# CCO Config Repo remotes" > "$rf"
        echo "# Format: name=url" >> "$rf"
    fi

    echo "${name}=${url}" >> "$rf"

    # Sync with vault git if initialized
    if [[ -d "$USER_CONFIG_DIR/.git" ]]; then
        if ! git -C "$USER_CONFIG_DIR" remote get-url "$name" >/dev/null 2>&1; then
            git -C "$USER_CONFIG_DIR" remote add "$name" "$url" 2>/dev/null || true
        fi
    fi

    ok "Added remote '$name' -> $url"
}

_cmd_remote_remove() {
    local name="${1:-}"
    [[ -z "$name" ]] && die "Usage: cco remote remove <name>"

    local rf; rf=$(_remotes_file)

    if [[ ! -f "$rf" ]] || ! grep -q "^${name}=" "$rf" 2>/dev/null; then
        die "Remote '$name' not found."
    fi

    # Remove from .cco-remotes
    local tmpfile
    tmpfile=$(mktemp)
    grep -v "^${name}=" "$rf" > "$tmpfile"
    mv "$tmpfile" "$rf"

    # Sync with vault git if initialized
    if [[ -d "$USER_CONFIG_DIR/.git" ]]; then
        git -C "$USER_CONFIG_DIR" remote remove "$name" 2>/dev/null || true
    fi

    ok "Removed remote '$name'"
}

_cmd_remote_list() {
    local rf; rf=$(_remotes_file)

    if [[ ! -f "$rf" ]]; then
        echo "No remotes configured."
        info "Run 'cco remote add <name> <url>' to register a Config Repo."
        return 0
    fi

    local found=false
    echo -e "${BOLD}Remotes:${NC}"
    while IFS='=' read -r name url; do
        [[ -z "$name" || "$name" == \#* ]] && continue
        printf "  %-16s %s\n" "$name" "$url"
        found=true
    done < "$rf"

    if ! $found; then
        echo "  (none)"
        info "Run 'cco remote add <name> <url>' to register a Config Repo."
    fi
}

# ── CLI command ──────────────────────────────────────────────────────

cmd_remote() {
    local subcmd="${1:-}"
    if [[ -z "$subcmd" || "$subcmd" == "--help" ]]; then
        cat <<'EOF'
Usage: cco remote <command>

Manage named Config Repo remotes for publishing and installing.

Commands:
  add <name> <url>     Register a remote Config Repo
  remove <name>        Unregister a remote
  list                 Show all registered remotes

Run 'cco remote <command> --help' for command-specific options.
EOF
        return 0
    fi
    shift

    case "$subcmd" in
        add)
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --help)
                        cat <<'EOF'
Usage: cco remote add <name> <url>

Register a named remote Config Repo. Names must be lowercase
alphanumeric with hyphens. If vault is initialized, the remote
is also added to the vault's git config.
EOF
                        return 0
                        ;;
                    *) break ;;
                esac
            done
            _cmd_remote_add "$@"
            ;;
        remove)
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --help)
                        cat <<'EOF'
Usage: cco remote remove <name>

Unregister a remote. Also removes from vault git config if initialized.
EOF
                        return 0
                        ;;
                    *) break ;;
                esac
            done
            _cmd_remote_remove "$@"
            ;;
        list)
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --help)
                        cat <<'EOF'
Usage: cco remote list

Show all registered Config Repo remotes.
EOF
                        return 0
                        ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            _cmd_remote_list
            ;;
        *)
            die "Unknown remote command: $subcmd. Run 'cco remote --help'."
            ;;
    esac
}
