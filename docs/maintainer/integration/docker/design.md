# Docker Specification

> Version: 1.0.0
> Status: v1.0 — Current
> Related: [architecture.md](../../architecture/architecture.md) | [spec.md](../../architecture/spec.md)

---

## 1. Docker Image

### 1.1 Dockerfile

```dockerfile
FROM node:22-bookworm

# ── System dependencies ──────────────────────────────────────────────
RUN apt-get update && apt-get install -y \
    git tmux jq ripgrep fzf curl wget \
    python3 python3-pip openssh-client socat less vim \
    && rm -rf /var/lib/apt/lists/*

# ── Locale (UTF-8 support) ──────────────────────────────────────────
RUN apt-get update && apt-get install -y locales \
    && sed -i 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# ── Docker CLI (for Docker-from-Docker) ──────────────────────────────
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
       https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y docker-ce-cli docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# ── GitHub CLI ─────────────────────────────────────────────────────
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) \
       signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
       https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# ── gosu (drop-in su replacement for Docker entrypoints) ─────────────
# gosu does a direct exec without creating a new session/pty, so TTY
# passthrough works correctly — unlike su/sudo which break stdin forwarding.
RUN arch="$(dpkg --print-architecture)" \
    && curl -fsSL "https://github.com/tianon/gosu/releases/download/1.17/gosu-${arch}" \
       -o /usr/local/bin/gosu \
    && chmod +x /usr/local/bin/gosu \
    && gosu nobody true

# ── Claude Code ──────────────────────────────────────────────────────
# Pin version for reproducible builds: cco build --claude-version 1.0.x
ARG CLAUDE_CODE_VERSION=latest
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}
ENV DISABLE_AUTOUPDATER=1

# ── MCP Server packages (optional pre-installation) ──────────────────
ARG MCP_PACKAGES=""
RUN if [ -n "$MCP_PACKAGES" ]; then npm install -g $MCP_PACKAGES; fi

# ── User setup script (global, build time) ─────────────────────────
# Custom system-level setup. Pass content via: cco build (auto-reads global/setup.sh)
ARG SETUP_SCRIPT_CONTENT=""
RUN if [ -n "$SETUP_SCRIPT_CONTENT" ]; then \
        printf '%s' "$SETUP_SCRIPT_CONTENT" > /tmp/setup.sh \
        && bash /tmp/setup.sh \
        && rm -f /tmp/setup.sh; \
    fi

# ── User setup ───────────────────────────────────────────────────────
# Pre-create docker group with placeholder GID (adjusted at runtime by entrypoint)
RUN groupadd -g 999 docker \
    && useradd -m -s /bin/bash claude \
    && mkdir -p /home/claude/.claude /workspace \
    && chown -R claude:claude /home/claude /workspace

# ── Config files ─────────────────────────────────────────────────────
COPY config/tmux.conf /home/claude/.tmux.conf
COPY config/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY config/hooks/ /usr/local/bin/cco-hooks/
RUN chown claude:claude /home/claude/.tmux.conf \
    && chmod +x /usr/local/bin/entrypoint.sh \
    && chmod +x /usr/local/bin/cco-hooks/*.sh

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

### 1.2 Entrypoint Script

The entrypoint handles Docker socket permissions, GitHub/git authentication, MCP server injection, project setup scripts, per-project MCP packages, and launches Claude Code via `gosu` with optional tmux wrapping.

```bash
#!/bin/bash
set -e

# ── Docker socket permissions ────────────────────────────────────────
# Match container's docker group GID to host's socket GID.
# The docker group is pre-created in the Dockerfile (GID 999 placeholder).
# Here we adjust its GID to match the host socket.
if [ -S /var/run/docker.sock ]; then
    SOCKET_GID=$(stat -c '%g' /var/run/docker.sock)
    if [ "$SOCKET_GID" != "0" ]; then
        if getent group docker > /dev/null 2>&1; then
            CURRENT_GID=$(getent group docker | cut -d: -f3)
            if [ "$CURRENT_GID" != "$SOCKET_GID" ]; then
                groupmod -g "$SOCKET_GID" docker
            fi
        else
            groupadd -g "$SOCKET_GID" docker
        fi
        usermod -aG docker claude
    else
        # Socket owned by root — add claude to root group (common on macOS)
        usermod -aG root claude
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
# We merge both global MCP (mounted as mcp-global.json) and project MCP
# (mounted as /workspace/.mcp.json) into ~/.claude.json.

# Merge global MCP servers (from global/.claude/mcp.json)
if [ -f "$MCP_GLOBAL" ]; then
    server_count=$(jq '.mcpServers | length' "$MCP_GLOBAL" 2>/dev/null || echo "0")
    if [ "$server_count" -gt 0 ]; then
        merged=$(jq -s '.[0] * {mcpServers: ((.[0].mcpServers // {}) + (.[1].mcpServers // {}))}' \
            "$CLAUDE_JSON" "$MCP_GLOBAL" 2>/dev/null) && echo "$merged" > "$CLAUDE_JSON"
        echo "[entrypoint] Merged $server_count global MCP server(s) into ~/.claude.json" >&2
    fi
fi

# Merge project MCP servers (from <repo>/.cco/mcp.json mounted at /workspace/.mcp.json)
# This provides a reliable fallback: servers are in both .mcp.json (project scope)
# AND ~/.claude.json (user scope), so at least one mechanism will work.
if [ -f "$MCP_PROJECT" ]; then
    # .mcp.json uses {mcpServers: {...}} format
    server_count=$(jq '.mcpServers | length' "$MCP_PROJECT" 2>/dev/null || echo "0")
    if [ "$server_count" -gt 0 ]; then
        merged=$(jq -s '.[0] * {mcpServers: ((.[0].mcpServers // {}) + (.[1].mcpServers // {}))}' \
            "$CLAUDE_JSON" "$MCP_PROJECT" 2>/dev/null) && echo "$merged" > "$CLAUDE_JSON"
        echo "[entrypoint] Merged $server_count project MCP server(s) into ~/.claude.json" >&2
    fi
fi

# ── GitHub / Git authentication ───────────────────────────────────
# Authenticate gh CLI and configure git credential helper if GITHUB_TOKEN is set.
# This enables: git push (HTTPS), gh pr create, and MCP GitHub server.
if [ -n "${GITHUB_TOKEN:-}" ]; then
    echo "$GITHUB_TOKEN" | gosu claude gh auth login --with-token 2>&1 >&2 \
        && echo "[entrypoint] GitHub: authenticated gh CLI via GITHUB_TOKEN" >&2
    gosu claude gh auth setup-git 2>&1 >&2 \
        && echo "[entrypoint] GitHub: configured git credential helper" >&2
fi

# ── Project setup script (runtime) ───────────────────────────────
PROJECT_SETUP="/workspace/setup.sh"
if [ -f "$PROJECT_SETUP" ]; then
    echo "[entrypoint] Running project setup script..." >&2
    bash "$PROJECT_SETUP" 2>&1 >&2
    echo "[entrypoint] Project setup complete" >&2
fi

# ── Per-project MCP packages (runtime) ───────────────────────────
PROJECT_MCP_PACKAGES="/workspace/mcp-packages.txt"
if [ -f "$PROJECT_MCP_PACKAGES" ]; then
    pkg_count=$(grep -cv '^\s*$\|^\s*#' "$PROJECT_MCP_PACKAGES" 2>/dev/null || true)
    pkg_count=${pkg_count:-0}
    if [ "$pkg_count" -gt 0 ]; then
        echo "[entrypoint] Installing $pkg_count project MCP package(s)..." >&2
        grep -v '^\s*$\|^\s*#' "$PROJECT_MCP_PACKAGES" | \
            xargs gosu claude npm install -g 2>&1 >&2
        echo "[entrypoint] Project MCP packages installed" >&2
    fi
fi

# ── Debug: log env vars and auth state ────────────────────────────────
echo "[entrypoint] TEAMMATE_MODE=${TEAMMATE_MODE:-unset}" >&2
echo "[entrypoint] ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:+SET}" >&2

# ── Switch to claude user and launch ─────────────────────────────────
# gosu does exec directly without creating a new session, preserving
# TTY/stdin so Claude Code's interactive UI works correctly.
if [ "${TEAMMATE_MODE}" = "tmux" ] && [ -z "$TMUX" ]; then
    set +e
    gosu claude tmux new-session -s claude "claude --dangerously-skip-permissions $*"
    exit_code=$?
    set -e
    [ $exit_code -ne 0 ] && echo "[entrypoint] claude exited with code ${exit_code}" >&2
    exit $exit_code
else
    exec gosu claude claude --dangerously-skip-permissions "$@"
fi
```

**Key implementation choices**:
- **gosu** instead of `su` — `su` creates a new session/PTY that breaks stdin forwarding. `gosu` does a direct `exec`, preserving TTY passthrough.
- **MCP injection** — global and project MCP servers are merged into `~/.claude.json` via `jq -s`. This is the most reliable mechanism (vs `.mcp.json` which may need approval).
- **GitHub auth** — `GITHUB_TOKEN` env var drives `gh auth login --with-token` + `gh auth setup-git`, enabling HTTPS push and `gh` CLI commands.
- **Project setup** — optional `setup.sh` and `mcp-packages.txt` run at container startup for per-project customization.
- **Error handling** — tmux path captures exit code explicitly (tmux doesn't propagate it via `exec`).

### 1.3 tmux Configuration

```tmux
# config/tmux.conf

# ── Terminal ─────────────────────────────────────────────────────────
set -g default-terminal "tmux-256color"
set -ga terminal-overrides ",xterm-256color:Tc"

# ── Clipboard ────────────────────────────────────────────────────────
set -g set-clipboard on         # OSC 52: apps and tmux copy-mode → host clipboard
set -g allow-passthrough on     # DCS passthrough for iTerm2 inline images, etc.
set -as terminal-features ",xterm-256color:clipboard"

# ── Mouse ────────────────────────────────────────────────────────────
set -g mouse on

# ── Copy mode ────────────────────────────────────────────────────────
setw -g mode-keys vi
bind-key -T copy-mode-vi v send-keys -X begin-selection
bind-key -T copy-mode-vi C-v send-keys -X rectangle-toggle
bind-key -T copy-mode-vi y send-keys -X copy-selection-and-cancel
bind-key -T copy-mode-vi MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel

# ── Status bar ───────────────────────────────────────────────────────
set -g status-style "bg=#1a1b26,fg=#a9b1d6"
set -g status-left "#[fg=#7aa2f7,bold] #{session_name} "
set -g status-left-length 30
set -g status-right "#[fg=#565f89] %H:%M "

# ── Pane borders ─────────────────────────────────────────────────────
set -g pane-border-style "fg=#3b4261"
set -g pane-active-border-style "fg=#7aa2f7"
set -g pane-border-indicators colour

# ── Navigation ───────────────────────────────────────────────────────
bind -n M-Left select-pane -L
bind -n M-Right select-pane -R
bind -n M-Up select-pane -U
bind -n M-Down select-pane -D

# ── History ──────────────────────────────────────────────────────────
set -g history-limit 50000

# ── Quality of life ──────────────────────────────────────────────────
set -g escape-time 0
set -g focus-events on
set -g base-index 1
setw -g pane-base-index 1
```

Key settings for clipboard:
- `set-clipboard on` — enables OSC 52 passthrough from applications and tmux copy-mode to the host terminal's clipboard
- `allow-passthrough on` — enables DCS passthrough for iTerm2 inline images and similar sequences
- `terminal-features clipboard` — explicit clipboard capability (works even when outer TERM is not `xterm*`)
- `MouseDragEnd1Pane copy-pipe-and-cancel` — auto-copies selection on mouse release (no manual `y` press needed)

See [agent-teams guide](../../../user-guides/agent-teams.md) §2.4 for copy-paste usage and host terminal compatibility.

---

## 2. Docker Compose

### 2.1 Base Template

Each project gets a `docker-compose.yml` generated from the invoking repo's `<repo>/.cco/project.yml`, written to machine-local STATE (never committed). Here is the annotated structure:

```yaml
# <state>/cco/projects/<id>/docker-compose.yml
# AUTO-GENERATED from project.yml — edits will be overwritten on next `cco start`

services:
  claude:
    image: claude-orchestrator:latest
    build:
      context: ../../                          # repo root (for Dockerfile)
      dockerfile: Dockerfile
    container_name: cc-${PROJECT_NAME}
    stdin_open: true                           # -i (interactive)
    tty: true                                  # -t (terminal)

    # ── Environment ──────────────────────────────────────────────────
    environment:
      - PROJECT_NAME=${PROJECT_NAME}
      - TEAMMATE_MODE=${TEAMMATE_MODE:-tmux}
      # Agent teams
      - CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
      # Disable auto memory directory issues (we mount it explicitly)
      # Auth via API key (if not using OAuth)
      # - ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}

    # ── Volumes ──────────────────────────────────────────────────────
    # All host sources are ABSOLUTE, resolved by cco start:
    #   GLOBAL = ~/.cco/global   STATE = ~/.local/state/cco   CACHE = ~/.cache/cco
    #   REPO   = invoking repo's path (from the STATE index)   ID = project.yml name
    volumes:
      # --- Auth & credentials (seeded into STATE) ---
      - ${STATE}/cco/claude.json:/home/claude/.claude.json
      - ${STATE}/cco/.credentials.json:/home/claude/.claude/.credentials.json

      # --- Global config → user-level (~/.claude/) ---
      - ${GLOBAL}/.claude/settings.json:/home/claude/.claude/settings.json:ro
      - ${GLOBAL}/.claude/CLAUDE.md:/home/claude/.claude/CLAUDE.md:ro
      - ${GLOBAL}/.claude/rules:/home/claude/.claude/rules:ro
      - ${GLOBAL}/.claude/agents:/home/claude/.claude/agents:ro
      - ${GLOBAL}/.claude/skills:/home/claude/.claude/skills:ro
      - ${GLOBAL}/.claude/mcp.json:/home/claude/.claude/mcp-global.json:ro

      # --- Project config (invoking repo's .cco/) ---
      - ${REPO}/.cco/claude:/workspace/.claude
      - ${REPO}/.cco/project.yml:/workspace/.claude/project.yml
      # Generated overlays from CACHE, layered :ro onto /workspace/.claude
      - ${CACHE}/cco/projects/${ID}/.claude/packs.md:/workspace/.claude/packs.md:ro
      - ${CACHE}/cco/projects/${ID}/.claude/workspace.yml:/workspace/.claude/workspace.yml:ro

      # --- Claude state: session transcripts + auto memory (STATE) ---
      - ${STATE}/cco/projects/${ID}/claude-state:/home/claude/.claude/projects/-workspace
      - ${STATE}/cco/projects/${ID}/session/memory:/home/claude/.claude/projects/-workspace/memory

      # --- Repositories ---
      # (generated from project.yml repos list, resolved via the STATE index)
      # - /Users/user/projects/backend-api:/workspace/backend-api
      # - /Users/user/projects/frontend-app:/workspace/frontend-app

      # --- Git config ---
      - ${HOME}/.gitconfig:/home/claude/.gitconfig:ro

      # --- Conditional mounts (added by cco start when files exist) ---
      # - ${REPO}/.cco/setup.sh:/workspace/setup.sh:ro
      # - ${REPO}/.cco/mcp-packages.txt:/workspace/mcp-packages.txt:ro

      # --- (conditional) Docker socket (Docker-from-Docker) ---
      # Omitted when docker.mount_socket: false in project.yml
      - /var/run/docker.sock:/var/run/docker.sock

    # ── Ports ────────────────────────────────────────────────────────
    # Common dev server ports. Customize in project.yml.
    ports:
      - "3000:3000"     # Frontend dev server
      - "3001:3001"     # Backend dev server
      - "4000:4000"     # GraphQL
      - "5173:5173"     # Vite
      - "8000:8000"     # Python/Django
      - "8080:8080"     # Generic

    # ── Network ──────────────────────────────────────────────────────
    networks:
      - cc-${PROJECT_NAME}

    working_dir: /workspace

# ── Networks ─────────────────────────────────────────────────────────
# Named network for this project. Sibling containers (postgres, redis, etc.)
# launched by Claude via docker compose will join this network.
networks:
  cc-${PROJECT_NAME}:
    name: cc-${PROJECT_NAME}
    driver: bridge
```

### 2.2 Volume Mount Strategy

All host SOURCES are **host-absolute** (resolved by `cco start`). `<repo>` is the invoking
repo's path (from the STATE index); `<state>`/`<cache>` are the XDG buckets
(`~/.local/state/cco`, `~/.cache/cco`); `<id>` is the project identity (`project.yml` `name`).
Container (target) paths are the fixed entrypoint contract and are **unchanged**.

```
HOST (host-absolute source)                          CONTAINER (fixed)                 PURPOSE
─────────────────────────────────────────────────────────────────────────────────────────────────
<state>/cco/claude.json                  → ~/.claude.json                   Auth state (rw)
<state>/cco/.credentials.json            → ~/.claude/.credentials.json      OAuth credentials (rw)
~/.cco/global/.claude/settings.json      → ~/.claude/settings.json          Global settings (ro)
~/.cco/global/.claude/CLAUDE.md          → ~/.claude/CLAUDE.md              Global instructions (ro)
~/.cco/global/.claude/rules/             → ~/.claude/rules/                 Global rules (ro)
~/.cco/global/.claude/agents/            → ~/.claude/agents/                Global subagents (ro)
~/.cco/global/.claude/skills/            → ~/.claude/skills/                Global skills (ro)
~/.cco/global/.claude/mcp.json           → ~/.claude/mcp-global.json        Global MCP config (ro)
<repo>/.cco/claude/                       → /workspace/.claude/              Project context (rw)
<cache>/cco/projects/<id>/.claude/packs.md     → /workspace/.claude/packs.md      Generated overlay (ro)
<cache>/cco/projects/<id>/.claude/workspace.yml → /workspace/.claude/workspace.yml Generated overlay (ro)
<repo>/.cco/project.yml                   → /workspace/.claude/project.yml   Project config (rw, /init-workspace)
<state>/cco/projects/<id>/claude-state/   → ~/.claude/projects/-workspace/   Session transcripts (rw)
<state>/cco/projects/<id>/session/memory/ → ~/.claude/projects/-workspace/memory/  Auto memory (rw)
~/projects/repo-x/                        → /workspace/repo-x/               Repository (rw)
~/.gitconfig                              → ~/.gitconfig                     Git config (ro)
<repo>/.cco/setup.sh                      → /workspace/setup.sh              Project setup (conditional, ro)
<repo>/.cco/mcp-packages.txt              → /workspace/mcp-packages.txt      MCP packages (conditional, ro)
/var/run/docker.sock                      → /var/run/docker.sock             Docker socket (conditional)
```

Pack and llms resources are mounted `:ro` from `~/.cco/packs/<name>/` (or the optional
project-local `<repo>/.cco/packs/<name>/`) and from CACHE (`<cache>/cco/llms/<name>/`) as
individual file/dir overlays into `/workspace/.claude/` — see §6.3 and ADR-0005.

**Read-only vs Read-write**:
- `ro`: Config that should not be modified by the agent (global settings, git config, generated overlays)
- `rw` (default): Repos (Claude writes code), the invoking repo's `.cco/claude/` (Claude may update), memory + transcripts in STATE (Claude writes)
- **`~/.claude.json`**: Seeded read-write from STATE (`<state>/cco/claude.json`). Shared across all projects. On macOS, OAuth tokens live in Keychain — this file holds other Claude state.

---

## 3. Networking

### 3.1 macOS Docker Desktop Networking Model

Docker Desktop for Mac runs Docker inside a Linux VM. This has implications:

| Feature | Behavior on macOS |
|---------|-------------------|
| `network_mode: host` | Refers to the Linux VM, NOT macOS. **Don't use.** |
| Port mapping (`-p 3000:3000`) | Routes macOS localhost → container. **Use this.** |
| `host.docker.internal` | Resolves to macOS host IP from inside any container. |
| Container-to-container | Use shared Docker network with service discovery. |

### 3.2 Networking Strategy

```mermaid
graph TB
    subgraph HOST ["macOS Host"]
        L3000["localhost:3000"]
        L5432["localhost:5432"]

        subgraph NET ["Docker Network: cc-my-saas"]
            CLAUDE["claude<br/>:3000 :8080"]
            SERVICES["postgres:5432<br/>redis:6379<br/>nginx:80"]
            CLAUDE <-->|"Docker DNS"| SERVICES
        end
    end

    L3000 -->|"port mapping"| CLAUDE
    L5432 -->|"port mapping"| SERVICES
```

**Key rules**:
1. Claude container and sibling containers join the same named network (`cc-<project>`)
2. Container-to-container communication uses Docker DNS (service names)
3. macOS access uses port mappings defined in docker-compose
4. Claude reaches macOS host services via `host.docker.internal`

### 3.3 Sibling Container Management

When Claude runs `docker compose up` for infrastructure:

1. The docker-compose file SHOULD specify the project's network as external:
   ```yaml
   networks:
     default:
       external: true
       name: cc-my-saas
   ```

2. This ensures sibling containers join the same network as the Claude container

3. The CLAUDE.md project instructions should include guidance on using the project network:
   ```markdown
   When running docker compose for infrastructure, use the network `cc-<project-name>`.
   Set it as external in the docker-compose file.
   ```

### 3.4 Port Allocation

Default port ranges in docker-compose, customizable per project:

| Range | Purpose |
|-------|---------|
| 3000-3099 | Frontend dev servers |
| 4000-4099 | API servers |
| 5173 | Vite |
| 5432 | PostgreSQL |
| 6379 | Redis |
| 8000-8099 | Python/Go servers |
| 8080-8099 | Generic HTTP |
| 27017 | MongoDB |

Projects specify needed ports in `project.yml` under `docker.ports`.

---

## 4. Image Build

### 4.1 Build Command

```bash
# From repo root
docker build -t claude-orchestrator:latest .

# Or via CLI
cco build
```

### 4.2 Build Caching

The Dockerfile is ordered for optimal layer caching:
1. System packages (changes rarely)
2. Docker CLI (changes rarely)
3. Claude Code npm install (changes with updates)
4. User setup and config (changes when config changes)

### 4.3 Updating Claude Code

To update Claude Code in the image:
```bash
cco build --no-cache
```

To pin a specific version for reproducible builds:
```bash
cco build --claude-version 1.0.5
```

The Dockerfile uses `ARG CLAUDE_CODE_VERSION=latest` — when no version is specified, the latest is installed. `DISABLE_AUTOUPDATER=1` prevents Claude Code from self-updating inside the container.

---

## 5. Container Lifecycle

### 5.1 Start

```bash
# Via CLI
cco start my-project

# Equivalent docker command
docker compose -f projects/my-project/.cco/docker-compose.yml \
  --project-directory projects/my-project \
  run --rm --service-ports claude
```

The `--rm` flag ensures the container is removed after exit.
The `--service-ports` flag ensures port mappings are active.

### 5.2 During Session

- Container runs Claude Code interactively
- User interacts via terminal (stdin/stdout attached)
- Claude creates files, runs commands, manages git — all inside mounted volumes
- Changes are immediately visible on host (volume mounts)

### 5.3 Stop

- User exits Claude Code (Ctrl+C, `/exit`, or closing terminal)
- Container is removed (`--rm`)
- All file changes persist via volume mounts
- Auto memory persists in STATE (`<state>/cco/projects/<id>/session/memory/`)
- Session transcripts persist in STATE (`<state>/cco/projects/<id>/claude-state/`)
- Git commits persist in the repos

### 5.4 Cleanup

```bash
# Stop all running sessions
cco stop

# Remove project network
docker network rm cc-my-project

# Remove sibling containers (if Claude left them running)
docker compose -f /path/to/infra/docker-compose.yml down
```

---

## 6. Directory Structure & File Inventory

### 6.1 Complete File Tree

```
claude-orchestrator/
│
├── docs/                                   # ── Documentation ──────────────
│   ├── README.md                           # Documentation index
│   ├── getting-started/
│   │   ├── overview.md                    # What it is, how it works
│   │   ├── installation.md                # Setup and usage guide
│   │   ├── first-project.md               # Step-by-step first project
│   │   └── concepts.md                    # Key concepts
│   ├── user-guides/
│   │   ├── project-setup.md               # Project setup guide
│   │   ├── agent-teams.md                 # tmux vs iTerm2 setup
│   │   └── advanced/
│   │       └── subagents.md               # Custom subagents guide
│   ├── reference/
│   │   ├── cli.md                         # CLI commands & project.yml format
│   │   └── context-hierarchy.md           # Context hierarchy & settings
│   └── maintainer/
│       ├── spec.md                        # Requirements specification
│       ├── architecture.md               # Architecture & design decisions
│       ├── docker/design.md              # This file (incl. directory structure)
│       └── roadmap.md                     # Planned features
│
├── Dockerfile                              # Docker image definition
├── .dockerignore                           # Exclude docs, .git from build context
├── .gitignore                              # Ignore user config, secrets
├── README.md                               # Project overview
├── docs/getting-started/installation.md    # Setup and usage guide
├── CLAUDE.md                               # Claude Code guidance for this repo
│
├── config/                                 # ── Docker Config ──────────────
│   ├── entrypoint.sh                       # Container entrypoint script
│   ├── tmux.conf                           # tmux config for agent teams
│   └── hooks/
│       ├── session-context.sh             # SessionStart hook: injects repo/MCP context
│       ├── subagent-context.sh            # SubagentStart hook: condensed context for subagents
│       ├── precompact.sh                  # PreCompact hook: guides context compaction
│       └── statusline.sh                  # StatusLine hook: shows model/context/cost
│
├── bin/                                    # ── CLI ────────────────────────
│   └── cco                                 # Main CLI script (bash)
│
├── defaults/                               # ── TOOL DEFAULTS (tracked) ────
│   ├── managed/                            # Framework infrastructure (baked in Docker image → /etc/claude-code/)
│   │   ├── managed-settings.json           # Hooks, env vars, deny rules, statusLine (non-overridable)
│   │   ├── CLAUDE.md                       # Framework instructions (Docker env, workspace, agent teams)
│   │   └── .claude/skills/
│   │       └── init-workspace/SKILL.md     # /init-workspace skill (managed, non-overridable)
│   ├── global/                             # User defaults (copied once by cco init → ~/.claude/)
│   │   └── .claude/
│   │       ├── CLAUDE.md                   # Global workflow instructions
│   │       ├── settings.json               # User preferences (allow rules, attribution, teammateMode)
│   │       ├── mcp.json                    # Empty MCP server list (user populates)
│   │       ├── rules/
│   │       │   ├── workflow.md             # Development workflow phases
│   │       │   ├── git-practices.md        # Git conventions
│   │       │   ├── documentation.md         # Documentation conventions (diagrams, structure, tracking)
│   │       │   └── language.md             # Language preferences (with {{LANG}} vars)
│   │       ├── agents/
│   │       │   ├── analyst.md              # Analysis specialist (haiku, read-only)
│   │       │   └── reviewer.md             # Code review specialist (sonnet, read-only)
│   │       └── skills/
│   │           ├── analyze/SKILL.md        # /analyze skill
│   │           ├── commit/SKILL.md         # /commit skill
│   │           ├── design/SKILL.md         # /design skill
│   │           └── review/SKILL.md         # /review skill
│
├── templates/                              # ── NATIVE TEMPLATES (tracked) ──
│   ├── project/
│   │   └── base/                           # Default project template (scaffolds a repo's .cco/)
│   │       ├── project.yml                 # Project metadata & config (logical names + coordinates)
│   │       └── claude/
│   │           ├── CLAUDE.md               # Project instructions template ({{PLACEHOLDERS}})
│   │           ├── settings.json           # Project settings template (empty, overrides go here)
│   │           ├── rules/
│   │           │   └── language.md         # Language override (commented out by default)
│   │           ├── agents/.gitkeep         # Project-specific agents
│   │           └── skills/.gitkeep         # Project-specific skills
│   └── pack/
│       └── base/                           # Default pack template (used by cco pack create)
│
├── internal/                               # ── FRAMEWORK-INTERNAL (tracked) ──
│   ├── tutorial/                           # Interactive tutorial (cco start tutorial)
│   └── config-editor/                      # Built-in config editor (cco start config-editor)
│
│   ════════════════════════════════════════════════════════════════════════
│   The blocks below are NOT in the tool repo — they live in the user's
│   environment (host home + each repo + hidden XDG buckets):
│   ════════════════════════════════════════════════════════════════════════
│
├── <each repo>/                            # ── PER-PROJECT CONFIG (committed in-repo) ──
│   ├── .claude/                            # Repo-native Claude config (cross-cutting)
│   └── .cco/                               # Hosts ONE project's config (machine-agnostic only)
│       ├── .gitignore                      # ignores secrets.env (+ secret patterns); !secrets.env.example
│       ├── project.yml                     # Source of truth: logical names + url/ref coordinates (no paths)
│       ├── secrets.env.example             # Committed skeleton
│       ├── secrets.env                     # GITIGNORED — real values (only in-repo exception)
│       ├── mcp.json                        # Optional project-level MCP servers
│       ├── setup.sh / mcp-packages.txt     # Optional project runtime setup
│       ├── claude/                         # COMMITTED + (copy-)synced → /workspace/.claude
│       │   ├── CLAUDE.md, settings.json
│       │   ├── rules/ · agents/ · skills/
│       └── packs/<name>/                   # OPTIONAL project-local pack (authored OR cache of a referenced pack)
│
├── ~/.cco/                                 # ── PERSONAL STORE (git-versioned, ~/.cco/.git) ──
│   ├── global/.claude/                     # Global Claude config (copied once on cco init from defaults/global/)
│   │   ├── settings.json · CLAUDE.md · mcp.json
│   │   └── rules/ · agents/ · skills/
│   ├── packs/<name>/                       # Authored knowledge packs (pack.yml + .md; embeds llms coordinates)
│   ├── templates/<name>/                   # Authored project/pack templates
│   ├── secrets.env                         # GITIGNORED global secrets · secrets.env.example committed
│   ├── languages                           # Language preference datum (regenerates language.md)
│   └── setup.sh / setup-build.sh / mcp-packages.txt   # Global setup scripts
│                                           # NO manifest.yml (removed, ADR-0012)
│
└── (hidden XDG buckets — per machine, never committed, never hand-edited)
    ├── STATE  ~/.local/state/cco           # index (name→abs-path + project→members), seeded auth,
    │   ├── index                           #   remotes-token (0600), changelog markers
    │   ├── projects/<id>/                   #   keyed by project identity <id> = project.yml name
    │   │   ├── claude-state/                #   session transcripts
    │   │   ├── session/memory/              #   auto memory (machine-local, no sync v1 — ADR-0009)
    │   │   ├── update/{meta,base/}          #   3-way merge ancestor + hashes/schema_version
    │   │   └── docker-compose.yml           #   generated by cco start (not committed)
    │   └── global/update/{meta,base/}       #   global-scope update artifacts
    ├── CACHE  ~/.cache/cco                  # regenerable: generated overlays + downloads
    │   ├── llms/<name>/                     #   llms content downloads (re-fetchable)
    │   ├── installed/                       #   sharing-repo clones for install/update
    │   └── projects/<id>/                    #   generated overlays → :ro into /workspace/.claude
    │       ├── .claude/{packs.md,workspace.yml}
    │       └── managed/{browser,github,policy}.json
    └── DATA   ~/.local/share/cco            # internal-but-synced (required, never team)
        ├── tags.yml                         #   per-user tag registry (packs/projects/templates → tags)
        ├── remotes                          #   de-tokenized sharing-repo endpoint registry (name→url)
        └── {projects,packs,templates}/<id>/source   # upstream coordinate (url/ref) only
```

### 6.2 File Descriptions

#### Root Files

| File | Purpose | Notes |
|------|---------|-------|
| `Dockerfile` | Docker image definition | See §1.1 |
| `.dockerignore` | Exclude files from Docker build context | Excludes: `docs/`, `.git/` |
| `.gitignore` | Git ignore patterns | Ignores `.env`; per-repo `<repo>/.cco/.gitignore` ignores `secrets.env`. User config (`~/.cco`, STATE/CACHE/DATA) lives outside the tool repo |
| `README.md` | Project overview and documentation index | What it is, how it works, requirements |
| `docs/getting-started/installation.md` | Setup and usage guide | Clone, init, create project, start session |
| `CLAUDE.md` | Guidance for Claude Code when working on this repo | Commands, architecture, conventions |

#### config/

| File | Purpose | Notes |
|------|---------|-------|
| `entrypoint.sh` | Container entrypoint | Docker socket perms, MCP injection, gosu, tmux launch. See §1.2 |
| `tmux.conf` | tmux configuration | Colors, navigation, history, mouse. See §1.3 |
| `hooks/session-context.sh` | SessionStart hook | Discovers repos, counts MCP servers, injects context JSON |
| `hooks/subagent-context.sh` | SubagentStart hook | Condensed project context for subagents |
| `hooks/precompact.sh` | PreCompact hook | Guides context compaction (what to preserve) |
| `hooks/statusline.sh` | StatusLine hook | Reads session JSON, displays `[project] model \| ctx XX% \| $cost` |

#### bin/

| File | Purpose | Notes |
|------|---------|-------|
| `cco` | CLI entrypoint | Dispatcher (~100 lines) that sources `lib/*.sh` modules. See [cli.md](../../../reference/cli.md) |

#### defaults/managed/

Framework infrastructure files, baked into the Docker image at `/etc/claude-code/`. Non-overridable by users — this is Claude Code's Managed level. Updated only via `cco build`.

| File | Purpose | Notes |
|------|---------|-------|
| `managed-settings.json` | Framework settings | Hooks (SessionStart, SubagentStart, PreCompact), env vars, statusLine, deny rules |
| `CLAUDE.md` | Framework instructions | Docker environment, workspace layout, agent team behavior |
| `.claude/skills/init-workspace/SKILL.md` | `/init-workspace` skill | Initialize/refresh project CLAUDE.md. Managed: non-overridable, updated via `cco build` |

#### defaults/global/.claude/

User defaults, copied to `~/.cco/global/.claude/` once by `cco init`. User owns these files after the initial copy. Not overwritten unless `cco init --force` is used. This includes agents, skills, rules, and settings that users can freely customize.

| File | Purpose | Notes |
|------|---------|-------|
| `CLAUDE.md` | User-level instructions | Workflow, git practices, communication style |
| `settings.json` | User preferences | Allow rules, attribution, teammateMode, cleanup, MCP settings |
| `mcp.json` | Global MCP server list | Empty by default; user populates. See [context-hierarchy.md](../../../reference/context-hierarchy.md) §8 |
| `rules/workflow.md` | Workflow phase rules | Analysis, Design, Implementation, Documentation phases |
| `rules/git-practices.md` | Git conventions | Branch naming, conventional commits |
| `rules/documentation.md` | Documentation conventions | Mermaid diagrams, docs structure, project tracking |
| `rules/language.md` | Language preferences | Has `{{COMM_LANG}}`, `{{DOCS_LANG}}`, `{{CODE_LANG}}` placeholders, substituted by `cco init --lang` |
| `agents/analyst.md` | Analyst subagent | Haiku, read-only tools, user memory. See [subagents.md](../../../user-guides/advanced/subagents.md) §2.1 |
| `agents/reviewer.md` | Reviewer subagent | Sonnet, read-only tools, user memory. See [subagents.md](../../../user-guides/advanced/subagents.md) §2.2 |
| `skills/analyze/SKILL.md` | `/analyze` skill | Structured codebase exploration mode |
| `skills/commit/SKILL.md` | `/commit` skill | Conventional commit creation with confirmation |
| `skills/design/SKILL.md` | `/design` skill | Implementation planning mode |
| `skills/review/SKILL.md` | `/review` skill | Structured code review with checklist |

#### templates/project/base/

Default project template, used by `cco init` / `cco join` to scaffold a repo's `.cco/` config. User templates in `~/.cco/templates/` take priority over native templates with the same name.

Scaffolds into the target repo's `<repo>/.cco/`. The template's `claude/` tree becomes the project scope (`<repo>/.cco/claude/` → `/workspace/.claude/`). Session state (transcripts, memory) is not scaffolded here — it lives machine-local in STATE.

| File | Purpose | Notes |
|------|---------|-------|
| `project.yml` | Project config template | Logical names + url/ref coordinates, ports, auth, packs. See [cli.md](../../../reference/cli.md) §4 |
| `claude/CLAUDE.md` | Project instructions template | `{{PROJECT_NAME}}` and `{{DESCRIPTION}}` placeholders |
| `claude/settings.json` | Project settings template | Empty; project-specific overrides go here |
| `claude/rules/language.md` | Language override template | Commented out by default; uncomment to override global |
| `claude/agents/.gitkeep` | Placeholder | Project-specific agents |
| `claude/skills/.gitkeep` | Placeholder | Project-specific skills |
| `secrets.env.example` | Secrets skeleton | Committed; real `secrets.env` is gitignored (only in-repo exception) |

### 6.3 Generated Files (Not in Git)

These files are generated by the CLI or Claude Code and must not be committed:

All generated files live in the hidden machine-local buckets (STATE/CACHE), never in the committed `<repo>/.cco/` tree — so they never pollute the truthful `git diff` or the sync.

| File | Generated By | Purpose |
|------|-------------|---------|
| `<state>/cco/projects/<id>/docker-compose.yml` | `cco start` | Docker Compose config for the project session (STATE) |
| `<cache>/cco/projects/<id>/.claude/packs.md` | `cco start` | Instructional file list for activated knowledge packs; `:ro` overlay, injected via hook (CACHE) |
| ~~`.pack-manifest`~~ | ~~`cco start`~~ | Eliminated by ADR-14 — pack resources are now delivered via read-only Docker volume mounts, not copied |
| `<cache>/cco/projects/<id>/.claude/workspace.yml` | `cco start` | Structured project summary (repos, packs); `:ro` overlay read by `/init-workspace` skill (CACHE) |
| `<cache>/cco/projects/<id>/managed/*.json` | `cco start` | Framework-generated integration config (browser/github/policy), `:ro` overlay (CACHE) |
| `<state>/cco/projects/<id>/session/memory/*.md` | Claude Code | Auto memory files (project insights, patterns; machine-local, no sync v1) (STATE) |
| `<state>/cco/projects/<id>/claude-state/*.json` | Claude Code | Session transcripts (enables `/resume` across rebuilds) (STATE) |
| `.env` | User / secrets.env | Runtime secrets (not committed) |

### 6.4 Implementation Order

Recommended order for building the repo from scratch:

| Phase | Files | Depends On |
|-------|-------|------------|
| 1. Docker | `Dockerfile`, `config/entrypoint.sh`, `config/tmux.conf`, `config/hooks/*`, `.dockerignore` | Nothing |
| 2. Global Config | `defaults/managed/*`, `defaults/global/.claude/*` | Nothing |
| 3. Project Template | `templates/project/base/*` (all files) | Nothing |
| 4. CLI | `bin/cco` | Phases 1–3 (needs files to reference) |
| 5. Root Files | `README.md`, `CLAUDE.md`, `.gitignore` | Phases 1–4 |
| 6. Testing | Manual: `cco init` in a repo, start session, verify | Phases 1–5 |

### 6.5 Validation Checklist

After implementation (or after significant changes), verify:

- [ ] `cco build` creates the Docker image successfully
- [ ] `cco init` copies user defaults (agents, skills, rules, settings) to `~/.cco/global/` and initializes the personal store
- [ ] `cco init` (in a repo) scaffolds `<repo>/.cco/` and registers it in the STATE index
- [ ] `cco start` (from the repo) launches an interactive Claude Code session
- [ ] Claude sees global CLAUDE.md (ask: "What are your global instructions?")
- [ ] Claude sees project CLAUDE.md (ask: "What project are you working on?")
- [ ] Claude sees repo `.claude/` when reading repo files (if repo has one)
- [ ] Git operations work inside container (`git commit`, `git push`)
- [ ] Docker commands work inside container (`docker ps`, `docker compose up`)
- [ ] Port mapping works (run `npx serve` on port 3000, access from host browser)
- [ ] Agent teams create panes (visible in tmux or iTerm2)
- [ ] Auto memory persists across sessions (check `<state>/cco/projects/<id>/session/memory/`)
- [ ] `/resume` works after `cco build --no-cache` (session transcripts in `<state>/cco/projects/<id>/claude-state/`)
- [ ] Knowledge packs: `packs.md` is generated with correct instructional list on `cco start`
- [ ] Knowledge packs: `additionalContext` contains pack file list (check Claude's initial context)
- [ ] `workspace.yml` is generated at `<cache>/cco/projects/<id>/.claude/workspace.yml` on `cco start`
- [ ] SessionStart hook fires and injects context (visible in Claude's initial context)
- [ ] StatusLine shows project/model/context info
- [ ] `cco new --repo <path>` works for temporary sessions
- [ ] `cco stop` stops running sessions cleanly
- [ ] `cco list` lists available projects with status
