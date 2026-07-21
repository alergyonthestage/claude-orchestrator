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

# Upsert a token in the STATE token store (0600). Returns 0 on success, 1 if any
# write failed.
#
# S2b-P: every mutation here used to be bare AND the tail statement was
# `if ! chmod …; then warn; fi`, which yields 0 on both branches — so the function
# returned 0 unconditionally, silently voiding store.sh's correctly-written
# `_remote_token_set … || return 1`. bin/cco dispatches every verb as
# `cmd_foo "$@" || _cco_rc=$?`, and a `||` context disables errexit for the entire
# call tree, so explicit propagation is the only mechanism that works. See
# docs/maintainers/engineering/analysis/false-success-class-audit.md §2.
#
# The chmod failure stays a WARN, deliberately: the token IS persisted, so the
# operation succeeded and only its confidentiality degraded. Returning non-zero
# there would make callers report — or roll back — a write that actually landed.
_remote_token_set() {
    local name="$1" token="$2"
    local tf; tf=$(_remotes_token_file)
    mkdir -p "$(dirname "$tf")" || return 1
    if [[ -f "$tf" ]] && grep -q "^${name}=" "$tf" 2>/dev/null; then
        # mktemp NEXT TO the target, as lib/store.sh's ops do — never a bare
        # mktemp: `mv` must be a same-filesystem rename, or it degrades to
        # copy+unlink across /tmp and can fail halfway through a secret file.
        local tmpf grc
        tmpf=$(mktemp "$tf.XXXXXX") || return 1
        grep -v "^${name}=" "$tf" > "$tmpf"; grc=$?
        [[ $grc -le 1 ]] || { rm -f "$tmpf" 2>/dev/null; return 1; }   # 0/1 = printed/empty; 2 = error
        mv "$tmpf" "$tf" || { rm -f "$tmpf" 2>/dev/null; return 1; }
    fi
    echo "${name}=${token}" >> "$tf" || return 1
    if ! chmod 600 "$tf" 2>/dev/null; then
        warn "Could not set permissions on $(basename "$tf") — file may be world-readable"
    fi
    return 0
}

# Remove a token from the STATE token store.
#
# Exit contract (S2b-P): 0 = removed · 1 = no token existed · 2 = the removal
# FAILED. The third code is the point of the fix: the write path used to be bare
# with an explicit `return 0`, so a failed removal reported success while the
# credential stayed on disk. Folding that failure into 1 instead would render it
# as "No token found" — trading the old lie for a new one — so absent and failed
# must stay distinguishable. A `die` from in here was rejected: store.sh's two
# cascades legitimately treat absence as a no-op, and `exit` cannot be caught by
# their `||`. ⇒ Callers that tolerate absence must test `-le 1`, never `|| true`.
_remote_token_remove() {
    local name="$1"
    local tf; tf=$(_remotes_token_file)
    [[ -f "$tf" ]] || return 1
    grep -q "^${name}=" "$tf" 2>/dev/null || return 1
    local tmpf grc
    tmpf=$(mktemp "$tf.XXXXXX") || return 2
    grep -v "^${name}=" "$tf" > "$tmpf"; grc=$?
    [[ $grc -le 1 ]] || { rm -f "$tmpf" 2>/dev/null; return 2; }
    mv "$tmpf" "$tf" || { rm -f "$tmpf" 2>/dev/null; return 2; }
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

    # Host-path/secret hygiene (CLI-surface review): the token store lives in
    # STATE (0600, never-sync) and is NOT mounted into a wrapped-cco session. In
    # a container `_remote_token_set` would write the token to an EPHEMERAL
    # container path (lost on exit) while `ok "[token saved]"` falsely claims it
    # persisted — a confusing partial write that also drops a plaintext secret on
    # the container FS. Refuse the token half here (mirrors host-only
    # `remote set-token`); registering the plain url stays allowed at edit level.
    if [[ -n "$token" ]] && _cco_container_operator; then
        die "'cco remote add --token' cannot persist a token in a container session — tokens are host-only (secrets stay off the container). Register the remote without --token here, then run 'cco remote set-token $name <token>' on your host."
    fi

    # The url registry lives in the confined DATA bucket, so the dup-check + append go
    # through lib/store.sh (INV-S6): behind the ADR-0047 boundary a raw grep/append
    # would read the registry empty and EACCES the write while still printing ✓.
    # _store_check refuses on an unreachable/unwritable store and reports whether the
    # name already exists (checked on the privileged side where it is true).
    # V5-03: the remedy must name a command the reader can actually run. After
    # D-V3-1 `cco remote remove` is host-only, so in a session it names an
    # impossible action — the very trap this cycle is closing elsewhere.
    _store_check remote-put "$name" "$url"
    if [[ "$_STORE_PRESENT" != no ]]; then
        if _cco_container_operator; then
            die "Remote '$name' already exists. Removing it is host-only (secrets stay off the container) — run 'cco remote remove $name' on your host, then re-add it here."
        fi
        die "Remote '$name' already exists. Remove it first with 'cco remote remove $name'."
    fi

    _store_apply remote-put "$name" "$url"

    # Store token (STATE token store, 0600) if provided. Reached on the host only —
    # the token half is refused above in a container session (secrets stay off it).
    # The url registry write has ALREADY landed, so a token failure must say which
    # store changed and which did not (the cmd-repo.sh idiom) — not just "failed".
    if [[ -n "$token" ]] && ! _remote_token_set "$name" "$token"; then
        die "Registered remote '$name' -> $url, but its token could NOT be saved — the STATE token store is not writable. The remote works unauthenticated; run 'cco remote set-token $name <token>' once that path is writable."
    fi

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

    # Existence is a fact of the plan, never a claude-side grep of the confined DATA
    # registry (INV-S6 / RC-13): behind the boundary the read is empty, so a raw grep
    # would report the WRONG `not found`. _store_check refuses on an unreachable/
    # unwritable store and reports whether the entry is present.
    _store_check remote-drop "$name"
    [[ "$_STORE_PRESENT" == yes ]] || die "Remote '$name' not found."

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

    # Remove from the url registry (DATA) + the token store (STATE) as one all-or-
    # nothing store op — never a false ✓ if the registry rewrite EACCES behind the
    # boundary.
    _store_apply remote-drop "$name"

    ok "Removed remote '$name'"
}

# Rename a remote: re-key its url-registry entry (DATA/remotes) and migrate its
# saved token (STATE/remotes-token) if present. Non-destructive (the url + token
# are preserved under the new key). Usage: _cmd_remote_rename <old> <new> [-y]
_cmd_remote_rename() {
    local old="" new="" yes=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes) yes=true; shift ;;
            -*) die "Unknown option: $1. Run 'cco remote rename --help'." ;;
            *)  if [[ -z "$old" ]]; then old="$1"
                elif [[ -z "$new" ]]; then new="$1"
                else die "Unexpected argument: $1"; fi
                shift ;;
        esac
    done
    [[ -z "$old" || -z "$new" ]] && die "Usage: cco remote rename <old> <new>"
    [[ "$old" == "$new" ]] && die "Old and new names are the same ('$old') — nothing to rename."
    _rename_validate remote "$new"

    # Existence + collision are facts of the plan, never a claude-side grep of the
    # confined DATA registry (INV-S6 / RC-13). _store_check refuses on an unreachable/
    # unwritable store and reports whether <old> is present and <new> collides.
    _store_check remote-rekey "$old" "$new"
    [[ "$_STORE_PRESENT" == yes ]]  || die "Remote '$old' not found."
    [[ "$_STORE_COLLISION" == no ]] || die "Remote '$new' already exists. Choose a different name."

    local has_token=false
    remote_get_token "$old" >/dev/null 2>&1 && has_token=true
    local -a bullets=("url registry key: $old → $new (url preserved)")
    [[ "$has_token" == true ]] && bullets+=("saved auth token migrated to '$new'")
    _rename_preview_confirm "$yes" "Rename remote '$old' → '$new'" "${bullets[@]}" \
        || { info "Aborted — nothing changed."; return 0; }

    # Re-key the url registry (DATA) + migrate the token (STATE) as one all-or-nothing
    # store op — the url is preserved under the new key.
    _store_apply remote-rekey "$old" "$new"

    ok "Renamed remote '$old' → '$new'."
}

_cmd_remote_set_token() {
    local name="${1:-}" token="${2:-}"

    [[ -z "$name" || -z "$token" ]] && die "Usage: cco remote set-token <name> <token>"

    local rf; rf=$(_remotes_file)

    # Verify remote exists in the url registry
    if [[ ! -f "$rf" ]] || ! grep -q "^${name}=" "$rf" 2>/dev/null; then
        die "Remote '$name' not found."
    fi

    _remote_token_set "$name" "$token" \
        || die "Could not save the token for remote '$name' — the STATE token store is not writable. Nothing was changed."
    ok "Token saved for remote '$name'"
}

_cmd_remote_remove_token() {
    local name="${1:-}"
    [[ -z "$name" ]] && die "Usage: cco remote remove-token <name>"

    # Split absent (rc 1) from a FAILED removal (rc ≥2). Collapsing them would
    # report a revocation as "No token found" while the credential is still on
    # disk — the failure mode this whole stage exists to close.
    local trc=0
    _remote_token_remove "$name" || trc=$?
    case "$trc" in
        0) ;;
        1) die "No token found for remote '$name'." ;;
        *) die "Could not remove the token for remote '$name' — the STATE token store is not writable. The token is STILL on disk; re-run once that path is writable." ;;
    esac

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
  rename <old> <new>   Rename a remote (re-keys url + token)
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
        rename)
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --help|-h)
                        cat <<'EOF'
Usage: cco remote rename <old> <new> [-y]

Rename a registered remote, re-keying its url-registry entry and migrating any
saved auth token. The url and token are preserved under the new name.

Options:
  -y, --yes   Skip the confirmation prompt
EOF
                        return 0
                        ;;
                    *) break ;;
                esac
            done
            _cmd_remote_rename "$@"
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
