# Docker Specification

> Version: 1.0.0
> Status: v1.0 — Current
> Related: [architecture.md](./architecture.md) | [spec.md](./spec.md)

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
ENV CLAUDE_CODE_DISABLE_AUTOUPDATE=1

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
RUN useradd -m -s /bin/bash claude \
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

# Merge project MCP servers (from projects/<name>/mcp.json mounted at /workspace/.mcp.json)
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
set -g default-terminal "screen-256color"
set -ga terminal-overrides ",xterm-256color:Tc"

# ── Mouse ────────────────────────────────────────────────────────────
set -g mouse on

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

---

## 2. Docker Compose

### 2.1 Base Template

Each project gets a `docker-compose.yml` generated from `project.yml`. Here is the annotated structure:

```yaml
# projects/<project-name>/docker-compose.yml
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
    volumes:
      # --- Auth & credentials ---
      - ${GLOBAL_DIR}/claude-state/claude.json:/home/claude/.claude.json
      - ${GLOBAL_DIR}/claude-state/.credentials.json:/home/claude/.claude/.credentials.json
      
      # --- Global config → user-level (~/.claude/) ---
      # Paths are absolute, resolved by cco CLI from GLOBAL_DIR
      - ${GLOBAL_DIR}/.claude/settings.json:/home/claude/.claude/settings.json:ro
      - ${GLOBAL_DIR}/.claude/CLAUDE.md:/home/claude/.claude/CLAUDE.md:ro
      - ${GLOBAL_DIR}/.claude/rules:/home/claude/.claude/rules:ro
      - ${GLOBAL_DIR}/.claude/agents:/home/claude/.claude/agents:ro
      - ${GLOBAL_DIR}/.claude/skills:/home/claude/.claude/skills:ro
      - ${GLOBAL_DIR}/.claude/mcp.json:/home/claude/.claude/mcp-global.json:ro

      # --- Project config ---
      - ./.claude:/workspace/.claude
      - ./project.yml:/workspace/project.yml:ro
      
      # --- Claude state: auto memory + session transcripts ---
      - ./claude-state:/home/claude/.claude/projects/-workspace
      
      # --- Repositories ---
      # (generated from project.yml repos list)
      # - /Users/user/projects/backend-api:/workspace/backend-api
      # - /Users/user/projects/frontend-app:/workspace/frontend-app
      
      # --- Git config ---
      - ${HOME}/.gitconfig:/home/claude/.gitconfig:ro

      # --- Conditional mounts (added by cco start when files exist) ---
      # - ./setup.sh:/workspace/setup.sh:ro
      # - ./mcp-packages.txt:/workspace/mcp-packages.txt:ro

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

```
HOST                                    CONTAINER                       PURPOSE
──────────────────────────────────────────────────────────────────────────────────
global/claude-state/claude.json      → ~/.claude.json                   Auth state (rw)
global/claude-state/.credentials.json→ ~/.claude/.credentials.json      OAuth credentials (rw)
$GLOBAL_DIR/.claude/settings.json    → ~/.claude/settings.json          Global settings (ro)
$GLOBAL_DIR/.claude/CLAUDE.md        → ~/.claude/CLAUDE.md              Global instructions (ro)
$GLOBAL_DIR/.claude/rules/           → ~/.claude/rules/                 Global rules (ro)
$GLOBAL_DIR/.claude/agents/          → ~/.claude/agents/                Global subagents (ro)
$GLOBAL_DIR/.claude/skills/          → ~/.claude/skills/                Global skills (ro)
$GLOBAL_DIR/.claude/mcp.json         → ~/.claude/mcp-global.json        Global MCP config (ro)
projects/<n>/.claude/                → /workspace/.claude/              Project context (rw)
projects/<n>/project.yml             → /workspace/project.yml           Project config (ro)
projects/<n>/claude-state/           → ~/.claude/projects/-workspace/   Memory + transcripts (rw)
~/projects/repo-x/                   → /workspace/repo-x/               Repository (rw)
~/.gitconfig                         → ~/.gitconfig                      Git config (ro)
projects/<n>/setup.sh                → /workspace/setup.sh              Project setup (conditional, ro)
projects/<n>/mcp-packages.txt        → /workspace/mcp-packages.txt      MCP packages (conditional, ro)
/var/run/docker.sock                 → /var/run/docker.sock              Docker socket (conditional)
```

**Read-only vs Read-write**:
- `ro`: Config that should not be modified by the agent (global settings, git config)
- `rw` (default): Repos (Claude writes code), project .claude/ (Claude may update), memory (Claude writes)
- **`~/.claude.json`**: Mounted read-write from `global/claude-state/claude.json`. Shared across all projects. On macOS, OAuth tokens live in Keychain — this file holds other Claude state.

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

```
┌─────────────────────────────────────────────────┐
│  macOS Host                                      │
│  localhost:3000 ─────────► Claude container:3000 │
│  localhost:5432 ─────────► Postgres container    │
│                                                  │
│  ┌────────────────────────────────────────────┐  │
│  │  Docker Network: cc-my-saas               │  │
│  │                                            │  │
│  │  ┌────────────┐    ┌────────────────────┐ │  │
│  │  │  claude     │◄──►│  postgres:5432     │ │  │
│  │  │  :3000     │    │  redis:6379        │ │  │
│  │  │  :8080     │    │  nginx:80          │ │  │
│  │  └────────────┘    └────────────────────┘ │  │
│  └────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────┘
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

The Dockerfile uses `ARG CLAUDE_CODE_VERSION=latest` — when no version is specified, the latest is installed. `CLAUDE_CODE_DISABLE_AUTOUPDATE=1` prevents Claude Code from self-updating inside the container.

---

## 5. Container Lifecycle

### 5.1 Start

```bash
# Via CLI
cco start my-project

# Equivalent docker command
docker compose -f projects/my-project/docker-compose.yml \
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
- Auto memory persists in `projects/<n>/claude-state/memory/`
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
