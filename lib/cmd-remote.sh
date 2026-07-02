#!/usr/bin/env bash
# lib/cmd-remote.sh — Top-level remote management
#
# Provides: cmd_remote(), remote_get_url(), remote_get_token(),
#           remote_resolve_token_for_url(), remote_list_names()
# Dependencies: colors.sh, utils.sh
# Globals: PACKS_DIR (remotes registry → DATA/STATE via paths.sh helpers)

# M3 split (ADR-0016 D7): the url registry (name=url) lives in DATA, synced
# across the user's machines but de-tokenized; auth tokens (name=token) live in
# a separate STATE file (0600, never-sync), so no secret rides a synced file.
_remotes_file()       { _cco_remotes_file; }
_remotes_token_file() { _cco_remotes_token_file; }

# Upsert a token in the STATE token store (0600).
_remote_token_set() {
    local name="$1" token="$2"
    local tf; tf=$(_remotes_token_file)
    mkdir -p "$(dirname "$tf")"
    if [[ -f "$tf" ]] && grep -q "^${name}=" "$tf" 2>/dev/null; then
        local tmpf; tmpf=$(mktemp); grep -v "^${name}=" "$tf" > "$tmpf"; mv "$tmpf" "$tf"
    fi
    echo "${name}=${token}" >> "$tf"
    if ! chmod 600 "$tf" 2>/dev/null; then
        warn "Could not set permissions on $(basename "$tf") — file may be world-readable"
    fi
}

# Remove a token from the STATE token store. Returns 1 if none existed.
_remote_token_remove() {
    local name="$1"
    local tf; tf=$(_remotes_token_file)
    [[ -f "$tf" ]] || return 1
    grep -q "^${name}=" "$tf" 2>/dev/null || return 1
    local tmpf; tmpf=$(mktemp); grep -v "^${name}=" "$tf" > "$tmpf"; mv "$tmpf" "$tf"
    return 0
}

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

# Resolve a remote name to its stored token (STATE token store).
# Returns the token on stdout, or returns 1 if not found.
remote_get_token() {
    local name="$1"
    local tf; tf=$(_remotes_token_file)
    [[ ! -f "$tf" ]] && return 1
    local line
    line=$(grep -m1 "^${name}=" "$tf" 2>/dev/null) || return 1
    echo "${line#*=}"
}

# Resolve a token for a given URL by matching against the url registry.
# Returns the token on stdout, or returns 1 if no match.
remote_resolve_token_for_url() {
    local url="$1"
    local rf; rf=$(_remotes_file)
    [[ ! -f "$rf" ]] && return 1
    # Normalize: strip trailing .git and /
    local norm_url="${url%.git}"; norm_url="${norm_url%/}"
    while IFS='=' read -r rname rurl; do
        [[ -z "$rname" || "$rname" == \#* ]] && continue
        local norm_rurl="${rurl%.git}"; norm_rurl="${norm_rurl%/}"
        if [[ "$norm_rurl" == "$norm_url" ]]; then
            remote_get_token "$rname" && return 0
        fi
    done < "$rf"
    return 1
}

# Reverse-lookup a registered remote NAME for a given URL (F4 / ADR-0022 D1).
# This is how `cco pack publish` re-derives its default remote on demand, in
# place of a stored `publish_target`. Returns the name on stdout, or 1 if no
# registered remote matches the url.
remote_get_name_for_url() {
    local url="$1"
    local rf; rf=$(_remotes_file)
    [[ ! -f "$rf" ]] && return 1
    local norm_url="${url%.git}"; norm_url="${norm_url%/}"
    while IFS='=' read -r rname rurl; do
        [[ -z "$rname" || "$rname" == \#* ]] && continue
        local norm_rurl="${rurl%.git}"; norm_rurl="${norm_rurl%/}"
        if [[ "$norm_rurl" == "$norm_url" ]]; then
            printf '%s\n' "$rname"
            return 0
        fi
    done < "$rf"
    return 1
}

# List all remote names (one per line) from the url registry.
remote_list_names() {
    local rf; rf=$(_remotes_file)
    [[ ! -f "$rf" ]] && return 0
    grep -v '^#' "$rf" | grep -v '^$' | cut -d= -f1
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

    # Create url registry with header if new
    if [[ ! -f "$rf" ]]; then
        mkdir -p "$(dirname "$rf")"
        echo "# CCO sharing-repo remotes — name=url (DATA, de-tokenized; tokens in STATE)" > "$rf"
    fi

    echo "${name}=${url}" >> "$rf"

    # Store token (STATE token store, 0600) if provided
    [[ -n "$token" ]] && _remote_token_set "$name" "$token"

    if [[ -n "$token" ]]; then
        ok "Added remote '$name' -> $url [token saved]"
    else
        ok "Added remote '$name' -> $url"
    fi
}

_cmd_remote_remove() {
    local name="" yes=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes) yes=true; shift ;;
            -*) die "Unknown option: $1" ;;
            *)
                if [[ -z "$name" ]]; then name="$1"; shift
                else die "Unexpected argument: $1"; fi ;;
        esac
    done
    [[ -z "$name" ]] && die "Usage: cco remote remove <name>"

    local rf; rf=$(_remotes_file)

    if [[ ! -f "$rf" ]] || ! grep -q "^${name}=" "$rf" 2>/dev/null; then
        die "Remote '$name' not found."
    fi

    # ── Preview (ADR-0029 D2): the url registry entry + any saved token ────
    info "cco remote remove '$name' will delete its url registry entry and any saved token."

    # Warn about packs whose recorded upstream resolves to this remote (F4: the
    # default publish target is re-derived from the pack url, not stored —
    # ADR-0022 D1).
    if [[ -d "${PACKS_DIR:-}" ]]; then
        local -a affected=()
        local pack_dir
        for pack_dir in "$PACKS_DIR"/*/; do
            [[ ! -d "$pack_dir" ]] && continue
            local source_file
            source_file=$(_cco_pack_source "$pack_dir")
            [[ ! -f "$source_file" ]] && continue
            local purl rname
            purl=$(yml_get "$source_file" "url")
            [[ -z "$purl" || "$purl" == "local" ]] && continue
            if rname=$(remote_get_name_for_url "$purl") && [[ "$rname" == "$name" ]]; then
                affected+=("$(basename "$pack_dir")")
            fi
        done
        if [[ ${#affected[@]} -gt 0 ]]; then
            warn "Packs that publish to '$name': ${affected[*]}"
        fi
    fi

    _confirm_destructive "$yes" "Remove remote '$name'?" || { info "Aborted"; return 0; }

    # Remove from the url registry (DATA) and the token store (STATE)
    local tmpfile
    tmpfile=$(mktemp)
    grep -v "^${name}=" "$rf" > "$tmpfile"
    mv "$tmpfile" "$rf"
    _remote_token_remove "$name" || true

    ok "Removed remote '$name'"
}

_cmd_remote_set_token() {
    local name="${1:-}" token="${2:-}"

    [[ -z "$name" || -z "$token" ]] && die "Usage: cco remote set-token <name> <token>"

    local rf; rf=$(_remotes_file)

    # Verify remote exists in the url registry
    if [[ ! -f "$rf" ]] || ! grep -q "^${name}=" "$rf" 2>/dev/null; then
        die "Remote '$name' not found."
    fi

    _remote_token_set "$name" "$token"
    ok "Token saved for remote '$name'"
}

_cmd_remote_remove_token() {
    local name="${1:-}"
    [[ -z "$name" ]] && die "Usage: cco remote remove-token <name>"

    if ! _remote_token_remove "$name"; then
        die "No token found for remote '$name'."
    fi

    ok "Removed token for remote '$name'"
}

# Output scoping (ADR-0043): remotes are personal-global. The operator shim
# gates `remote list` behind read-global+, so whenever this runs every remote is
# in scope — no per-row filtering here (the compact `cco list` reads the DATA
# registry directly and scopes remotes there).
_cmd_remote_list() {
    local rf; rf=$(_remotes_file)

    if [[ ! -f "$rf" ]]; then
        echo "No remotes configured."
        info "Run 'cco remote add <name> <url>' to register a sharing repo."
        return 0
    fi

    local tf; tf=$(_remotes_token_file)
    local found=false
    echo -e "${BOLD}Remotes:${NC}"
    while IFS='=' read -r name url; do
        [[ -z "$name" || "$name" == \#* ]] && continue
        local token_tag=""
        if [[ -f "$tf" ]] && grep -q "^${name}=" "$tf" 2>/dev/null; then
            token_tag="  [token]"
        fi
        printf "  %-16s %s%s\n" "$name" "$url" "$token_tag"
        found=true
    done < "$rf"

    if ! $found; then
        echo "  (none)"
        info "Run 'cco remote add <name> <url>' to register a sharing repo."
    fi
}

# ── CLI command ──────────────────────────────────────────────────────

cmd_remote() {
    local subcmd="${1:-}"
    if [[ -z "$subcmd" || "$subcmd" == "--help" || "$subcmd" == "-h" ]]; then
        cat <<'EOF'
Usage: cco remote <command>

Manage named sharing repo remotes for publishing and installing.

Commands:
  add <name> <url>     Register a remote sharing repo
  remove <name>        Unregister a remote
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
                    --help|-h)
                        cat <<'EOF'
Usage: cco remote add <name> <url> [--token <token>]

Register a named remote sharing repo. Names must be lowercase
alphanumeric with hyphens. The url registry is synced across your
machines (de-tokenized); any token is stored separately, machine-local.

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
                    --help|-h)
                        cat <<'EOF'
Usage: cco remote remove <name> [-y]

Unregister a remote (removes its url entry and any saved token). Previews and
confirms first (ADR-0029 D2).

Options:
  -y, --yes   Skip the confirmation prompt
EOF
                        return 0
                        ;;
                    *) break ;;
                esac
            done
            _cmd_remote_remove "$@"
            ;;
        list)
            die "'cco remote list' was removed — use 'cco list remotes' (ADR-0029)." ;;
        set-token)
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --help|-h)
                        cat <<'EOF'
Usage: cco remote set-token <name> <token>

Save an auth token for a registered remote. The token is stored
machine-local (0600, never synced) and used automatically for HTTPS
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
                    --help|-h)
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
