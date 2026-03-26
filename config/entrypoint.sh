#!/bin/bash
set -e

# Debug logging: only show [entrypoint] info messages when CCO_DEBUG=1
# WARNING and FATAL messages are always shown regardless of debug mode.
_log() { if [ "${CCO_DEBUG:-}" = "1" ]; then echo "[entrypoint] $*" >&2; fi; }

# Cleanup background processes on exit
_cleanup() {
    [ -n "${PROXY_PID:-}" ] && kill "$PROXY_PID" 2>/dev/null || true
}
trap _cleanup EXIT

# ── Docker socket permissions ────────────────────────────────────────
# Match container's docker group GID to host's socket GID.
# The docker group is pre-created in the Dockerfile (GID 999 placeholder).
# Here we adjust its GID to match the host socket, ensuring Docker-from-Docker works.
if [ -S /var/run/docker.sock ]; then
    SOCKET_GID=$(stat -c '%g' /var/run/docker.sock)
    if [ "$SOCKET_GID" != "0" ]; then
        # Adjust docker group GID to match host socket
        if getent group docker > /dev/null 2>&1; then
            CURRENT_GID=$(getent group docker | cut -d: -f3)
            if [ "$CURRENT_GID" != "$SOCKET_GID" ]; then
                groupmod -g "$SOCKET_GID" docker 2>&1 >&2 \
                    || echo "[entrypoint] WARNING: failed to set docker group GID to $SOCKET_GID" >&2
            fi
        else
            groupadd -g "$SOCKET_GID" docker 2>&1 >&2 \
                || echo "[entrypoint] WARNING: failed to create docker group with GID $SOCKET_GID" >&2
        fi
        usermod -aG docker claude 2>&1 >&2
        _log "Docker socket: GID=$SOCKET_GID, claude added to docker group"
    else
        # Socket owned by root — add claude to root group (common on macOS)
        usermod -aG root claude 2>&1 >&2
        _log "Docker socket: GID=0 (root-owned), claude added to root group"
    fi
else
    _log "Docker socket: not mounted"
fi

# ── Docker socket proxy ─────────────────────────────────────────────
# When a policy file is present, start the filtering proxy between Claude
# and the real Docker socket. The proxy runs as root (socket access);
# Claude only sees the filtered proxy socket via DOCKER_HOST.
if [ -S /var/run/docker.sock ] && [ -f /etc/cco/policy.json ]; then
    # Lock down the real socket FIRST — before starting the proxy.
    # This ensures the claude user can never access the unfiltered socket,
    # even if the proxy fails to start.
    chmod 600 /var/run/docker.sock

    /usr/local/bin/cco-docker-proxy \
        -listen /var/run/docker-proxy.sock \
        -upstream /var/run/docker.sock \
        -policy /etc/cco/policy.json \
        -log-denied >> /var/log/cco-proxy.log 2>&1 &
    PROXY_PID=$!

    # Wait for proxy socket to appear (max 3s)
    _proxy_wait=0
    while [ ! -S /var/run/docker-proxy.sock ] && [ "$_proxy_wait" -lt 30 ]; do
        sleep 0.1
        _proxy_wait=$((_proxy_wait + 1))
    done

    if [ -S /var/run/docker-proxy.sock ]; then
        # Proxy socket: accessible to claude user
        # Verify docker group exists before chown (should always exist — pre-created in Dockerfile)
        if getent group docker > /dev/null 2>&1; then
            chown claude:docker /var/run/docker-proxy.sock
        else
            echo "[entrypoint] WARNING: docker group missing, proxy socket owned by claude:claude" >&2
            chown claude:claude /var/run/docker-proxy.sock
        fi
        chmod 660 /var/run/docker-proxy.sock
        # Point Docker CLI to proxy
        export DOCKER_HOST="unix:///var/run/docker-proxy.sock"
        _log "Docker socket proxy: active (policy=$(jq -r .containers.policy /etc/cco/policy.json 2>/dev/null))"
    else
        echo "[entrypoint] FATAL: Docker socket proxy did not start — Docker access disabled" >&2
        kill "$PROXY_PID" 2>/dev/null || true
        # Real socket already locked (chmod 600 above) — no Docker access possible
    fi
fi

# ── Ensure ~/.claude.json exists and is writable ─────────────────────
# Mounted from global/claude-state/claude.json (shared across all projects).
# Initialized on host by cmd_start before container starts.
# On macOS, OAuth tokens are stored in Keychain — not in ~/.claude.json —
# so seeding from host is not applicable. Login once from inside the container;
# Claude writes tokens here and they persist across all sessions.
CLAUDE_JSON="/home/claude/.claude.json"
MCP_GLOBAL="/home/claude/.claude/mcp-global.json"
MCP_PROJECT="/workspace/.mcp.json"

if [ ! -f "$CLAUDE_JSON" ]; then
    echo '{}' > "$CLAUDE_JSON"
fi
chown claude:claude "$CLAUDE_JSON"

# ── MCP server injection into ~/.claude.json ─────────────────────────
# Claude Code reads user-scope MCP from ~/.claude.json mcpServers key.
# This is the most reliable mechanism (vs .mcp.json which needs approval).
#
# mcpServers is rebuilt from scratch every session so that:
# - disabling a server in config actually removes it (no stale entries)
# - claude-state/claude.json stays free of configuration data
#
# Reset mcpServers to an empty object before merging from source files.
merged=$(jq '.mcpServers = {}' "$CLAUDE_JSON" 2>/dev/null) \
    && echo "$merged" > "$CLAUDE_JSON"

# Merge global MCP servers (from global/.claude/mcp.json)
if [ -f "$MCP_GLOBAL" ]; then
    server_count=$(jq '.mcpServers | length' "$MCP_GLOBAL" 2>/dev/null || echo "0")
    if [ "$server_count" -gt 0 ]; then
        merged=$(jq -s '.[0] * {mcpServers: ((.[0].mcpServers // {}) + (.[1].mcpServers // {}))}' \
            "$CLAUDE_JSON" "$MCP_GLOBAL" 2>/dev/null) && echo "$merged" > "$CLAUDE_JSON"
        _log "Merged $server_count global MCP server(s) into ~/.claude.json"
    fi
fi

# Merge project MCP servers (from projects/<name>/mcp.json mounted at /workspace/.mcp.json)
# This provides a reliable fallback: servers are in both .mcp.json (project scope)
# AND ~/.claude.json (user scope), so at least one mechanism will work.
if [ -f "$MCP_PROJECT" ]; then
    # .mcp.json uses {mcpServers: {...}} format
    server_count=$(jq '.mcpServers | length' "$MCP_PROJECT" 2>/dev/null || echo "0")
    if [ "$server_count" -gt 0 ]; then
        merged=$(jq -s '.[0] * {mcpServers: ((.[0].mcpServers // {}) + (.[1].mcpServers // {}))}' \
            "$CLAUDE_JSON" "$MCP_PROJECT" 2>/dev/null) && echo "$merged" > "$CLAUDE_JSON"
        _log "Merged $server_count project MCP server(s) into ~/.claude.json"
    fi
fi

# Merge managed integration MCP configs (framework-managed, generated by cco start)
# Loop is generic — adding a new integration does not require changes here.
if [ -d "/workspace/.managed" ]; then
    for mcp_file in /workspace/.managed/*.json; do
        [ -f "$mcp_file" ] || continue
        # Warn if any managed server key conflicts with an already-merged server
        for key in $(jq -r '.mcpServers | keys[]?' "$mcp_file" 2>/dev/null); do
            existing=$(jq -r --arg k "$key" '.mcpServers[$k] // empty' "$CLAUDE_JSON" 2>/dev/null)
            if [ -n "$existing" ]; then
                echo "[entrypoint] WARNING: managed MCP '${key}' overrides user-configured server" >&2
            fi
        done
        server_count=$(jq '.mcpServers | length' "$mcp_file" 2>/dev/null || echo "0")
        if [ "$server_count" -gt 0 ]; then
            merged=$(jq -s '.[0] * {mcpServers: ((.[0].mcpServers // {}) + (.[1].mcpServers // {}))}' \
                "$CLAUDE_JSON" "$mcp_file" 2>/dev/null) && echo "$merged" > "$CLAUDE_JSON"
            _log "Merged ${server_count} managed MCP server(s) from $(basename "$mcp_file")"
        fi
    done
fi

# Browser CDP proxy: Chrome 145+ rejects non-localhost Host headers on CDP endpoints.
# socat forwards raw TCP so the Host header stays "localhost:<port>".
# Started only when the managed browser config is present.
if [ -f "/workspace/.managed/browser.json" ]; then
    cdp_port="${CDP_PORT:-9222}"
    socat TCP-LISTEN:"${cdp_port}",fork,bind=127.0.0.1,reuseaddr \
          TCP:host.docker.internal:"${cdp_port}" &
    _log "CDP proxy: localhost:${cdp_port} → host.docker.internal:${cdp_port}"
fi

# ── GitHub / Git authentication ───────────────────────────────────
# Authenticate gh CLI and configure git credential helper if GITHUB_TOKEN is set.
# This enables: git push (HTTPS), gh pr create, and MCP GitHub server.
if [ -n "${GITHUB_TOKEN:-}" ]; then
    echo "$GITHUB_TOKEN" | gosu claude gh auth login --with-token 2>&1 >&2 \
        && _log "GitHub: authenticated gh CLI via GITHUB_TOKEN"
    gosu claude gh auth setup-git 2>&1 >&2 \
        && _log "GitHub: configured git credential helper"
fi

# ── Global runtime setup script ──────────────────────────────────
# Lightweight config (dotfiles, aliases, tmux keybindings) applied to all projects.
# Heavy installs (apt packages) belong in setup-build.sh (runs at cco build).
GLOBAL_SETUP="/home/claude/global-setup.sh"
if [ -f "$GLOBAL_SETUP" ]; then
    _log "Running global runtime setup..."
    gosu claude bash "$GLOBAL_SETUP" 2>&1 >&2
    _log "Global runtime setup complete"
fi

# ── Project setup script (runtime) ───────────────────────────────
PROJECT_SETUP="/workspace/setup.sh"
if [ -f "$PROJECT_SETUP" ]; then
    _log "Running project setup script..."
    gosu claude bash "$PROJECT_SETUP" 2>&1 >&2
    _log "Project setup complete"
fi

# ── Per-project MCP packages (runtime) ───────────────────────────
PROJECT_MCP_PACKAGES="/workspace/mcp-packages.txt"
if [ -f "$PROJECT_MCP_PACKAGES" ]; then
    pkg_count=$(grep -cv '^\s*$\|^\s*#' "$PROJECT_MCP_PACKAGES" 2>/dev/null || true)
    pkg_count=${pkg_count:-0}
    if [ "$pkg_count" -gt 0 ]; then
        _log "Installing $pkg_count project MCP package(s)..."
        grep -v '^\s*$\|^\s*#' "$PROJECT_MCP_PACKAGES" | \
            xargs gosu claude npm install -g 2>&1 >&2
        _log "Project MCP packages installed"
    fi
fi

# ── Debug: log env vars and auth state ────────────────────────────────
_log "TEAMMATE_MODE=${TEAMMATE_MODE:-unset}"
_log "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:+SET}"

# ── Switch to claude user and launch ─────────────────────────────────
# gosu does exec directly without creating a new session, preserving
# TTY/stdin so Claude Code's interactive UI works correctly.
if [ "${TEAMMATE_MODE}" = "tmux" ] && [ -z "$TMUX" ]; then
    set +e
    tmux_args=$(printf '%q ' "$@")
    gosu claude tmux new-session -s claude "claude --dangerously-skip-permissions ${tmux_args% }"
    exit_code=$?
    set -e
    [ $exit_code -ne 0 ] && echo "[entrypoint] WARNING: claude exited with code ${exit_code}" >&2
    exit $exit_code
else
    exec gosu claude claude --dangerously-skip-permissions "$@"
fi
