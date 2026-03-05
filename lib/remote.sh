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
    git -C "$test_dir" sparse-checkout set "dummy" 2>/dev/null
    local rc=$?
    rm -rf "$test_dir"
    return $rc
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

    # Auth: set token for HTTPS if provided
    local -a git_opts=()
    if [[ -n "$token" ]]; then
        git_opts+=(-c "http.extraHeader=Authorization: Bearer $token")
    elif [[ -n "${GITHUB_TOKEN:-}" && "$url" == *github.com* ]]; then
        git_opts+=(-c "http.extraHeader=Authorization: Bearer $GITHUB_TOKEN")
    fi

    # Primary: sparse-checkout (git 2.25+)
    if _supports_sparse_checkout; then
        git "${git_opts[@]+"${git_opts[@]}"}" clone --no-checkout --filter=blob:none \
            ${ref:+--branch "$ref"} "$url" "$tmpdir" >/dev/null 2>&1 \
            || { rm -rf "$tmpdir"; die "Failed to clone $url"; }
        git -C "$tmpdir" checkout >/dev/null 2>&1 \
            || { rm -rf "$tmpdir"; die "Failed to checkout $url"; }
    else
        # Fallback: shallow clone
        git "${git_opts[@]+"${git_opts[@]}"}" clone --depth 1 \
            ${ref:+--branch "$ref"} "$url" "$tmpdir" >/dev/null 2>&1 \
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

    local -a git_opts=()
    if [[ -n "$token" ]]; then
        git_opts+=(-c "http.extraHeader=Authorization: Bearer $token")
    elif [[ -n "${GITHUB_TOKEN:-}" && "$url" == *github.com* ]]; then
        git_opts+=(-c "http.extraHeader=Authorization: Bearer $GITHUB_TOKEN")
    fi

    # Try full clone
    if git "${git_opts[@]+"${git_opts[@]}"}" clone "$url" "$tmpdir" >/dev/null 2>&1; then
        echo "$tmpdir"
        return 0
    fi

    # Clone failed — might be an empty repo. Try init + remote setup.
    rm -rf "$tmpdir"
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/cco-pub-XXXXXX")
    git -C "$tmpdir" init -q
    git -C "$tmpdir" remote add origin "$url"

    # Test if remote is accessible
    if git "${git_opts[@]+"${git_opts[@]}"}" -C "$tmpdir" ls-remote origin >/dev/null 2>&1; then
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
