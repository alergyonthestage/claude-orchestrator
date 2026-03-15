#!/usr/bin/env bash
# lib/cmd-remote.sh — Top-level remote management
#
# Provides: cmd_remote(), remote_get_url(), remote_get_token(),
#           remote_resolve_token_for_url(), remote_list_names()
# Dependencies: colors.sh, utils.sh
# Globals: USER_CONFIG_DIR

_remotes_file() { _cco_remotes_file; }

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

# Resolve a remote name to its stored token.
# Returns the token on stdout, or returns 1 if not found.
remote_get_token() {
    local name="$1"
    local rf; rf=$(_remotes_file)
    [[ ! -f "$rf" ]] && return 1
    local line
    line=$(grep -m1 "^${name}\.token=" "$rf" 2>/dev/null) || return 1
    echo "${line#*=}"
}

# Resolve a token for a given URL by matching against registered remotes.
# Returns the token on stdout, or returns 1 if no match.
remote_resolve_token_for_url() {
    local url="$1"
    local rf; rf=$(_remotes_file)
    [[ ! -f "$rf" ]] && return 1
    # Normalize: strip trailing .git and /
    local norm_url="${url%.git}"; norm_url="${norm_url%/}"
    while IFS='=' read -r rname rurl; do
        [[ -z "$rname" || "$rname" == \#* || "$rname" == *.* ]] && continue
        local norm_rurl="${rurl%.git}"; norm_rurl="${norm_rurl%/}"
        if [[ "$norm_rurl" == "$norm_url" ]]; then
            remote_get_token "$rname" && return 0
        fi
    done < "$rf"
    return 1
}

# List all remote names (one per line).
remote_list_names() {
    local rf; rf=$(_remotes_file)
    [[ ! -f "$rf" ]] && return 0
    grep -v '^#' "$rf" | grep -v '^$' | grep -v '\.token=' | cut -d= -f1
}

# ── Subcommands ──────────────────────────────────────────────────────

_cmd_remote_add() {
    local name="" url="" token=""

    # Parse positional + options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --token)
                [[ -z "${2:-}" ]] && die "--token requires a value"
                token="$2"; shift 2 ;;
            -*)  die "Unknown option: $1" ;;
            *)
                if [[ -z "$name" ]]; then
                    name="$1"
                elif [[ -z "$url" ]]; then
                    url="$1"
                else
                    die "Unexpected argument: $1"
                fi
                shift ;;
        esac
    done

    if [[ -z "$name" || -z "$url" ]]; then
        die "Usage: cco remote add <name> <url> [--token <token>]"
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
        echo "# Format: name=url  |  name.token=token (optional)" >> "$rf"
    fi

    echo "${name}=${url}" >> "$rf"

    # Store token if provided
    if [[ -n "$token" ]]; then
        echo "${name}.token=${token}" >> "$rf"
        if ! chmod 600 "$rf" 2>/dev/null; then
            warn "Could not set permissions on $(basename "$rf") — file may be world-readable"
        fi
    fi

    # Sync with vault git if initialized
    if [[ -d "$USER_CONFIG_DIR/.git" ]]; then
        if ! git -C "$USER_CONFIG_DIR" remote get-url "$name" >/dev/null 2>&1; then
            git -C "$USER_CONFIG_DIR" remote add "$name" "$url" 2>/dev/null || true
        fi
    fi

    if [[ -n "$token" ]]; then
        ok "Added remote '$name' -> $url [token saved]"
    else
        ok "Added remote '$name' -> $url"
    fi
}

_cmd_remote_remove() {
    local name="${1:-}"
    [[ -z "$name" ]] && die "Usage: cco remote remove <name>"

    local rf; rf=$(_remotes_file)

    if [[ ! -f "$rf" ]] || ! grep -q "^${name}=" "$rf" 2>/dev/null; then
        die "Remote '$name' not found."
    fi

    # Warn about packs with publish_target pointing to this remote
    if [[ -d "${PACKS_DIR:-}" ]]; then
        local -a affected=()
        for pack_dir in "$PACKS_DIR"/*/; do
            [[ ! -d "$pack_dir" ]] && continue
            local source_file="$pack_dir/.cco/source"
            [[ ! -f "$source_file" ]] && continue
            local target
            target=$(grep '^publish_target:' "$source_file" 2>/dev/null \
                | sed 's/^publish_target: *//' | tr -d '"'"'")
            if [[ "$target" == "$name" ]]; then
                affected+=("$(basename "$pack_dir")")
            fi
        done
        if [[ ${#affected[@]} -gt 0 ]]; then
            warn "Packs with publish_target '$name': ${affected[*]}"
        fi
    fi

    # Remove from .cco/remotes (both url and token lines)
    local tmpfile
    tmpfile=$(mktemp)
    grep -v "^${name}=" "$rf" | grep -v "^${name}\.token=" > "$tmpfile"
    mv "$tmpfile" "$rf"

    # Sync with vault git if initialized
    if [[ -d "$USER_CONFIG_DIR/.git" ]]; then
        git -C "$USER_CONFIG_DIR" remote remove "$name" 2>/dev/null || true
    fi

    ok "Removed remote '$name'"
}

_cmd_remote_set_token() {
    local name="${1:-}" token="${2:-}"

    [[ -z "$name" || -z "$token" ]] && die "Usage: cco remote set-token <name> <token>"

    local rf; rf=$(_remotes_file)

    # Verify remote exists
    if [[ ! -f "$rf" ]] || ! grep -q "^${name}=" "$rf" 2>/dev/null; then
        die "Remote '$name' not found."
    fi

    # Remove old token if any
    if grep -q "^${name}\.token=" "$rf" 2>/dev/null; then
        local tmpfile; tmpfile=$(mktemp)
        grep -v "^${name}\.token=" "$rf" > "$tmpfile"
        mv "$tmpfile" "$rf"
    fi

    echo "${name}.token=${token}" >> "$rf"
    if ! chmod 600 "$rf" 2>/dev/null; then
        warn "Could not set permissions on $(basename "$rf") — file may be world-readable"
    fi
    ok "Token saved for remote '$name'"
}

_cmd_remote_remove_token() {
    local name="${1:-}"
    [[ -z "$name" ]] && die "Usage: cco remote remove-token <name>"

    local rf; rf=$(_remotes_file)

    if [[ ! -f "$rf" ]] || ! grep -q "^${name}\.token=" "$rf" 2>/dev/null; then
        die "No token found for remote '$name'."
    fi

    local tmpfile; tmpfile=$(mktemp)
    grep -v "^${name}\.token=" "$rf" > "$tmpfile"
    mv "$tmpfile" "$rf"

    ok "Removed token for remote '$name'"
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
        [[ -z "$name" || "$name" == \#* || "$name" == *.* ]] && continue
        local token_tag=""
        if grep -q "^${name}\.token=" "$rf" 2>/dev/null; then
            token_tag="  [token]"
        fi
        printf "  %-16s %s%s\n" "$name" "$url" "$token_tag"
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
  set-token <n> <tok>  Save auth token for a remote
  remove-token <name>  Remove saved token for a remote

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
Usage: cco remote add <name> <url> [--token <token>]

Register a named remote Config Repo. Names must be lowercase
alphanumeric with hyphens. If vault is initialized, the remote
is also added to the vault's git config.

Use --token to save an auth token for HTTPS repos.
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
        set-token)
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --help)
                        cat <<'EOF'
Usage: cco remote set-token <name> <token>

Save an auth token for a registered remote. The token is stored
in .cco/remotes (gitignored) and used automatically for HTTPS
operations (install, update, publish).
EOF
                        return 0
                        ;;
                    *) break ;;
                esac
            done
            _cmd_remote_set_token "$@"
            ;;
        remove-token)
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --help)
                        cat <<'EOF'
Usage: cco remote remove-token <name>

Remove the saved auth token for a remote.
EOF
                        return 0
                        ;;
                    *) break ;;
                esac
            done
            _cmd_remote_remove_token "$@"
            ;;
        *)
            die "Unknown remote command: $subcmd. Run 'cco remote --help'."
            ;;
    esac
}
