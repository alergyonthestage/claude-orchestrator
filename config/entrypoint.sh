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

# ── cco internal-store privilege boundary (ADR-0047) ─────────────────
# Lock down the privileged root that confines the internal store BEFORE claude ever
# gets control (mirrors the docker-socket chmod-first pattern above — lock first, so
# the boundary holds even if a later step fails). The store buckets (STATE index, DATA
# registries, CACHE internals) are bind-mounted UNDER this root at leaf paths; because
# the root is mode 0700 and owned by the login-less cco-svc uid on the REAL container
# FS, the claude user (agent shell + wrapped cco) cannot traverse it → EACCES, closing
# the S1/S1b cat-the-index leak. The sole crossing is the setuid cco-svc-helper, which
# elevates to cco-svc and runs the scope-aware `cco __store`. On macOS Docker Desktop
# chown/chmod on bind-mount CONTENT is not DAC-enforced (fakeowner), but the kernel
# checks path traversal on the real PARENT inode — this 0700 real-FS parent (ADR-0047
# §8 Test B). Idempotent + self-healing even against an image built before Phase II.
CCO_INTERNAL_ROOT=/var/lib/cco-internal
if getent passwd cco-svc >/dev/null 2>&1; then
    install -d -o cco-svc -g cco-svc -m 0700 "$CCO_INTERNAL_ROOT"
    # Re-assert ownership + mode unconditionally (defence in depth): the root must be
    # 0700 cco-svc regardless of how the image or a prior run left it.
    chown cco-svc:cco-svc "$CCO_INTERNAL_ROOT"
    chmod 0700 "$CCO_INTERNAL_ROOT"
    # Per-bucket PARENTS, owned by cco-svc. Docker materialises any missing mountpoint
    # ancestor itself, as root:root 0755 — and cco-svc can then traverse and read it but
    # NOT create in it, so any sibling write under such a parent fails EACCES. That is
    # the design-docker.md §1.2.2 hazard, and v3 R1 was its first real instance (the
    # index bind's parent). Re-asserting them here is idempotent and applies whether or
    # not the corresponding bind exists in this session. Non-recursive on purpose: the
    # children are bind mounts and their ownership belongs to the host.
    for _b in state/cco share/cco cache/cco; do
        install -d -o cco-svc -g cco-svc -m 0700 "$CCO_INTERNAL_ROOT/$_b" 2>/dev/null || true
        chown cco-svc:cco-svc "$CCO_INTERNAL_ROOT/$_b" 2>/dev/null || true
        chmod 0700 "$CCO_INTERNAL_ROOT/$_b" 2>/dev/null || true
    done
    unset _b
    # XDG façade: $HOME/.local/{state,share,cache}/cco → the confined root. Both native
    # paths and a direct `cat ~/.local/state/cco/index` resolve INTO the 0700 parent and
    # hit EACCES (Test B layout). The elevated cco reaches the real leaves via CCO_*_HOME
    # (injected by the helper); these symlinks are the claude-visible dead end. cco no
    # longer mounts under the shared ~/.local/state | ~/.cache bases, which also removes
    # the design-docker.md §1.2.2 native-installer sibling-EACCES collision.
    gosu claude mkdir -p /home/claude/.local/state /home/claude/.local/share /home/claude/.cache 2>/dev/null || true
    ln -sfn "$CCO_INTERNAL_ROOT/state/cco" /home/claude/.local/state/cco
    ln -sfn "$CCO_INTERNAL_ROOT/share/cco" /home/claude/.local/share/cco
    ln -sfn "$CCO_INTERNAL_ROOT/cache/cco" /home/claude/.cache/cco
    _log "Internal-store boundary: $CCO_INTERNAL_ROOT locked (0700 cco-svc); XDG symlinks in place"
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

# Merge global MCP servers (from ~/.cco/.claude/mcp.json, mounted as mcp-global.json)
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

# ── Claude Code native install / re-pin (ADR-0039) ───────────────────
# The image no longer bakes the binary (npm + DISABLE_AUTOUPDATER retired).
# Install it here, as the claude user, into the persistent bind-mounted
# ~/.local/{bin,share/claude} (host CACHE) so it survives restarts and
# auto-updates IN PLACE. Reinstall when the binary is absent OR the requested
# channel/version (CLAUDE_CODE_VERSION) differs from the installed one recorded
# in the marker — this makes `cco build --claude-version X` / the config knob
# actually switch versions, while NOT reinstalling on every start (a bare channel
# string like `latest` is not comparable to `claude --version`, so we compare the
# stored request marker instead of the binary's version).
CLAUDE_BIN="/home/claude/.local/bin/claude"
CLAUDE_MARKER="/home/claude/.local/bin/.cco-claude-channel"
CLAUDE_REQ="${CLAUDE_CODE_VERSION:-latest}"

# The bind-mounted dirs may be owned by the host uid — ensure claude owns them
# before installing/writing (macOS Docker Desktop: chown is a no-op, hence || true).
# .local/state and .cache are included even though nothing is installed there
# directly by this block: when cco_access != none, cco nests bind mounts under
# them (.local/state/cco/index, .cache/cco/llms — ADR-0036 D4), which makes the
# container runtime auto-create the parent as a root-owned mount point before
# this script runs — blocking the installer's own mkdir of the sibling
# .local/state/claude / .cache/claude dirs unless we reclaim ownership here.
# The Dockerfile now pre-creates these XDG bases claude-owned too (belt and
# suspenders — see its "User setup" comment for the same rationale); this stays
# so runtime start-up self-heals even against an image built before that.
mkdir -p /home/claude/.local/bin /home/claude/.local/share/claude \
    /home/claude/.local/state /home/claude/.cache
chown claude:claude \
    /home/claude/.local \
    /home/claude/.local/bin \
    /home/claude/.local/share/claude \
    /home/claude/.local/state \
    /home/claude/.cache 2>/dev/null || true

_installed_req=""
if [ -f "$CLAUDE_MARKER" ]; then
    _installed_req="$(cat "$CLAUDE_MARKER" 2>/dev/null || true)"
fi

if [ ! -x "$CLAUDE_BIN" ] || [ "$_installed_req" != "$CLAUDE_REQ" ]; then
    echo "[entrypoint] Installing Claude Code ('$CLAUDE_REQ') via native installer (one-time per cache)..." >&2
    # Clear the launcher path first. `claude install` refuses to overwrite a
    # launcher it does not own ("was not created by the native installer") and
    # exits non-zero, which used to make this a FATAL with no way out: the stale
    # file lives in the shared CACHE mount, so ANY session that once left a
    # foreign launcher there (an npm-era wrapper, a `claude migrate-installer`
    # result, a dangling symlink into a wiped share/claude/versions) poisoned the
    # install for every project until `cco build --no-cache`. We only reach this
    # branch when we have already decided to (re)install, so whatever sits at the
    # launcher path is destined to be replaced — removing it is not a data loss,
    # and the real install lives in share/claude/versions either way.
    if [ -e "$CLAUDE_BIN" ] || [ -L "$CLAUDE_BIN" ]; then
        _log "Clearing existing launcher at $CLAUDE_BIN before install"
        rm -rf "$CLAUDE_BIN"
    fi
    if gosu claude env CLAUDE_REQ="$CLAUDE_REQ" bash -c \
        'curl -fsSL https://claude.ai/install.sh | bash -s "$CLAUDE_REQ"'; then
        echo "$CLAUDE_REQ" | gosu claude tee "$CLAUDE_MARKER" >/dev/null
        _log "Claude Code installed: $CLAUDE_REQ"
    else
        echo "[entrypoint] FATAL: Claude Code install failed (channel/version='$CLAUDE_REQ')." >&2
        echo "[entrypoint] Network access is required at first start (installer fetch)." >&2
        echo "[entrypoint] If the install cache is corrupt, reset it from the host:" >&2
        echo "[entrypoint]   cco build --no-cache" >&2
        exit 1
    fi
else
    _log "Claude Code present ('$_installed_req'); auto-updater keeps it current"
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
