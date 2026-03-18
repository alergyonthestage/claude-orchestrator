# lib/update-remote.sh — Remote Config Repo version checking and cache

# Default cache TTL for remote version checks (seconds)
REMOTE_CACHE_TTL=3600  # 1 hour

# ── Remote Version Check ──────────────────────────────────────────────

# Check if a project has a remote source (installed from Config Repo).
# Returns 0 (true) if installed from remote, 1 (false) if local.
# Sets _INSTALLED_SOURCE_URL, _INSTALLED_SOURCE_REF, _INSTALLED_SOURCE_PATH,
#      _INSTALLED_SOURCE_COMMIT on success.
_is_installed_project() {
    local project_dir="$1"
    local source_file
    source_file=$(_cco_project_source "$project_dir")

    _INSTALLED_SOURCE_URL=""
    _INSTALLED_SOURCE_REF=""
    _INSTALLED_SOURCE_PATH=""
    _INSTALLED_SOURCE_COMMIT=""

    [[ ! -f "$source_file" ]] && return 1

    # Check format: old format is single line (native:project/...), new format is YAML
    local first_line
    first_line=$(head -1 "$source_file")
    case "$first_line" in
        http://*|https://*)
            # Old single-line bare URL format (pre-FI-7) — use directly
            # Don't call yml_get: bare URL is not key: value YAML
            _INSTALLED_SOURCE_URL="$first_line"
            ;;
        source:*)
            # YAML format
            _INSTALLED_SOURCE_URL=$(yml_get "$source_file" "source")
            ;;
        native:*|user:*|local)
            # Local/native source — not a remote install
            return 1
            ;;
        *)
            # Unknown — try YAML
            _INSTALLED_SOURCE_URL=$(yml_get "$source_file" "source")
            ;;
    esac

    [[ -z "$_INSTALLED_SOURCE_URL" || "$_INSTALLED_SOURCE_URL" == "local" ]] && return 1

    _INSTALLED_SOURCE_REF=$(yml_get "$source_file" "ref")
    _INSTALLED_SOURCE_PATH=$(yml_get "$source_file" "path")
    _INSTALLED_SOURCE_COMMIT=$(yml_get "$source_file" "commit")
    return 0
}

# Check if a cached remote version is still fresh.
# Returns 0 if fresh (within TTL), 1 if stale.
_cache_fresh() {
    local checked_time="$1"
    local ttl="${2:-$REMOTE_CACHE_TTL}"

    [[ -z "$checked_time" ]] && return 1

    local checked_epoch now_epoch
    # Parse ISO8601 timestamp to epoch (portable)
    if date -d "$checked_time" +%s >/dev/null 2>&1; then
        checked_epoch=$(date -d "$checked_time" +%s)
    elif date -j -f "%Y-%m-%dT%H:%M:%SZ" "$checked_time" +%s >/dev/null 2>&1; then
        checked_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$checked_time" +%s)
    else
        return 1  # Can't parse — treat as stale
    fi
    now_epoch=$(date +%s)

    local age=$(( now_epoch - checked_epoch ))
    [[ $age -lt $ttl ]]
}

# Check if a remote source has updates available.
# Echoes: "update_available", "up_to_date", or "unreachable"
_check_remote_update() {
    local source_file="$1"
    local meta_file="$2"
    local cache_mode="${3:-default}"  # default | force

    local source_url source_ref installed_commit
    source_url=$(yml_get "$source_file" "source")
    source_ref=$(yml_get "$source_file" "ref")
    installed_commit=$(yml_get "$source_file" "commit")

    # If no installed commit recorded, we can't compare — report as update available
    if [[ -z "$installed_commit" ]]; then
        echo "unknown"
        return 0
    fi

    # Check cache (unless force refresh)
    if [[ "$cache_mode" != "force" ]]; then
        local cached_commit cached_time
        cached_commit=$(yml_get "$meta_file" "remote_cache.commit" 2>/dev/null)
        cached_time=$(yml_get "$meta_file" "remote_cache.checked" 2>/dev/null)

        if [[ -n "$cached_commit" ]] && _cache_fresh "$cached_time"; then
            if [[ "$cached_commit" != "$installed_commit" ]]; then
                echo "update_available"
            else
                echo "up_to_date"
            fi
            return 0
        fi
    fi

    # Fetch remote HEAD hash (lightweight — no clone)
    local remote_head
    # Auto-resolve token and build auth URL via remote.sh helper
    local token=""
    token=$(remote_resolve_token_for_url "$source_url" 2>/dev/null) || true
    _build_git_auth "$source_url" "$token"

    remote_head=$(git "${_GIT_AUTH_OPTS[@]+"${_GIT_AUTH_OPTS[@]}"}" ls-remote "$_GIT_AUTH_URL" "${source_ref:-HEAD}" 2>/dev/null | head -1 | cut -f1)
    if [[ -z "$remote_head" ]]; then
        echo "unreachable"
        return 0
    fi

    # Update cache
    mkdir -p "$(dirname "$meta_file")"
    yml_set "$meta_file" "remote_cache.commit" "$remote_head"
    yml_set "$meta_file" "remote_cache.checked" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # Compare
    if [[ "$remote_head" != "$installed_commit" ]]; then
        echo "update_available"
    else
        echo "up_to_date"
    fi
}
