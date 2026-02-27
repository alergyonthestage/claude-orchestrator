#!/usr/bin/env bash
# lib/auth.sh — Authentication helpers
#
# Provides: get_oauth_token()
# Dependencies: none
# Globals: none

# Extract OAuth token from macOS Keychain
# Returns the access token or empty string if not found
get_oauth_token() {
    if [[ "$(uname)" != "Darwin" ]]; then
        return
    fi
    local creds
    creds=$(security find-generic-password -s "Claude Code-credentials" -a "$(whoami)" -w 2>/dev/null) || return
    echo "$creds" | python3 -c "import sys,json; print(json.load(sys.stdin)['claudeAiOauth']['accessToken'])" 2>/dev/null || true
}
