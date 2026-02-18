#!/bin/bash
set -e

# ── Docker socket permissions ────────────────────────────────────────
# Match container's docker group GID to host's socket GID
if [ -S /var/run/docker.sock ]; then
    SOCKET_GID=$(stat -c '%g' /var/run/docker.sock)
    if [ "$SOCKET_GID" != "0" ]; then
        # Create or modify docker group to match host GID
        if getent group docker > /dev/null 2>&1; then
            groupmod -g "$SOCKET_GID" docker
        else
            groupadd -g "$SOCKET_GID" docker
        fi
        usermod -aG docker claude
    else
        # Socket owned by root — add claude to root group (common on macOS)
        usermod -aG root claude
    fi
fi

# ── Switch to claude user and launch ─────────────────────────────────
# gosu does exec directly without creating a new session, preserving
# TTY/stdin so Claude Code's interactive UI works correctly.
if [ "${TEAMMATE_MODE}" = "tmux" ] && [ -z "$TMUX" ]; then
    exec gosu claude tmux new-session -s claude "claude --dangerously-skip-permissions $*"
else
    exec gosu claude claude --dangerously-skip-permissions "$@"
fi
