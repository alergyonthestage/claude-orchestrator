#!/usr/bin/env bash
# lib/remote.sh — Remote clone helper for Config Repo operations
#
# Provides: _supports_sparse_checkout(), _clone_config_repo(), _cleanup_clone()
# Dependencies: colors.sh
# Globals: none (standalone utility)

# Test if git sparse-checkout is supported.
# Returns 0 if supported, 1 otherwise.
_supports_sparse_checkout() {
    local test_dir
    test_dir=$(mktemp -d)
    git -C "$test_dir" init -q 2>/dev/null
    local rc=0
    git -C "$test_dir" sparse-checkout set "dummy" 2>/dev/null || rc=$?
    rm -rf "$test_dir"
    return $rc
}

# Build git auth URL and options for HTTPS token authentication.
# Injects the token into the URL (x-access-token:TOKEN@host) and disables
# the system credential helper to prevent macOS Keychain prompts.
# Sets: _GIT_AUTH_URL (URL with token) and _GIT_AUTH_OPTS (array of git -c flags).
# Usage: _build_git_auth <url> [<token>]
#        Then use: git "${_GIT_AUTH_OPTS[@]+"${_GIT_AUTH_OPTS[@]}"}" clone "$_GIT_AUTH_URL" ...
_build_git_auth() {
    local url="$1"
    local token="${2:-}"

    _GIT_AUTH_URL="$url"
    _GIT_AUTH_OPTS=()

    # Resolve effective token: explicit > GITHUB_TOKEN fallback
    local effective_token="$token"
    if [[ -z "$effective_token" && -n "${GITHUB_TOKEN:-}" && "$url" == *github.com* ]]; then
        effective_token="$GITHUB_TOKEN"
    fi

    if [[ -n "$effective_token" && "$url" == https://* ]]; then
        # Inject token into URL: https://host/... → https://x-access-token:TOKEN@host/...
        _GIT_AUTH_URL="${url/https:\/\//https://x-access-token:${effective_token}@}"
        # Disable credential helper to prevent macOS Keychain / IDE prompts
        _GIT_AUTH_OPTS=(-c "credential.helper=")
    fi
}

# Clone a config repo to a temporary directory.
# Usage: _clone_config_repo <url> [<ref>] [<token>]
# Outputs: path to the cloned directory
_clone_config_repo() {
    local url="$1"
    local ref="${2:-}"
    local token="${3:-}"
    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/cco-XXXXXX")

    # Strip @ref suffix from URL if present
    if [[ "$url" == *@* && -z "$ref" ]]; then
        ref="${url##*@}"
        url="${url%@*}"
    fi

    _build_git_auth "$url" "$token"

    # Primary: sparse-checkout (git 2.25+)
    if _supports_sparse_checkout; then
        git "${_GIT_AUTH_OPTS[@]+"${_GIT_AUTH_OPTS[@]}"}" clone --no-checkout --filter=blob:none \
            ${ref:+--branch "$ref"} "$_GIT_AUTH_URL" "$tmpdir" >/dev/null 2>&1 \
            || { rm -rf "$tmpdir"; die "Failed to clone $url"; }
        git -C "$tmpdir" checkout >/dev/null 2>&1 \
            || { rm -rf "$tmpdir"; die "Failed to checkout $url"; }
    else
        # Fallback: shallow clone
        git "${_GIT_AUTH_OPTS[@]+"${_GIT_AUTH_OPTS[@]}"}" clone --depth 1 \
            ${ref:+--branch "$ref"} "$_GIT_AUTH_URL" "$tmpdir" >/dev/null 2>&1 \
            || { rm -rf "$tmpdir"; die "Failed to clone $url"; }
    fi

    echo "$tmpdir"
}

# Clone a config repo for publishing (full clone, push-ready).
# Handles empty repos (first publish) by initializing with manifest.yml.
# Usage: _clone_for_publish <url> [<token>]
# Outputs: path to the cloned directory
_clone_for_publish() {
    local url="$1"
    local token="${2:-}"
    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/cco-pub-XXXXXX")

    _build_git_auth "$url" "$token"

    # Try full clone
    if git "${_GIT_AUTH_OPTS[@]+"${_GIT_AUTH_OPTS[@]}"}" clone "$_GIT_AUTH_URL" "$tmpdir" >/dev/null 2>&1; then
        echo "$tmpdir"
        return 0
    fi

    # Clone failed — might be an empty repo. Try init + remote setup.
    rm -rf "$tmpdir"
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/cco-pub-XXXXXX")
    git -C "$tmpdir" init -q
    git -C "$tmpdir" remote add origin "$_GIT_AUTH_URL"

    # Test if remote is accessible
    if git "${_GIT_AUTH_OPTS[@]+"${_GIT_AUTH_OPTS[@]}"}" -C "$tmpdir" ls-remote origin >/dev/null 2>&1; then
        # Remote exists but is empty — initialize
        manifest_init "$tmpdir"
        git -C "$tmpdir" add -A
        git -C "$tmpdir" commit -q -m "init: empty Config Repo"
        echo "$tmpdir"
        return 0
    fi

    rm -rf "$tmpdir"
    die "Failed to clone or access $url"
}

# Cleanup a temporary clone directory.
# Usage: _cleanup_clone "$tmpdir"
_cleanup_clone() {
    local tmpdir="$1"
    # Match cco-XXXXXX or cco-pub-XXXXXX suffix regardless of TMPDIR prefix
    [[ -d "$tmpdir" && "$(basename "$tmpdir")" == cco-* ]] && rm -rf "$tmpdir"
}
