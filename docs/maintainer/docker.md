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
    git \
    tmux \
    jq \
    ripgrep \
    fzf \
    curl \
    wget \
    python3 \
    python3-pip \
    openssh-client \
    socat \
    less \
    vim \
    && rm -rf /var/lib/apt/lists/*

# ── Docker CLI (for Docker-from-Docker) ──────────────────────────────
# Install Docker CLI only (no daemon). Used to control host Docker via socket.
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
       https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y docker-ce-cli docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# ── Claude Code ──────────────────────────────────────────────────────
RUN npm install -g @anthropic-ai/claude-code@latest

# ── User setup ───────────────────────────────────────────────────────
# Create claude user. Add to group with GID matching host's docker socket.
# The actual GID is set at runtime via entrypoint (see entrypoint.sh).
RUN useradd -m -s /bin/bash claude \
    && mkdir -p /home/claude/.claude /workspace \
    && chown -R claude:claude /home/claude /workspace

# ── Config files ─────────────────────────────────────────────────────
COPY config/tmux.conf /home/claude/.tmux.conf
COPY config/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chown claude:claude /home/claude/.tmux.conf \
    && chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

### 1.2 Entrypoint Script

The entrypoint handles Docker socket permissions and launches Claude Code with optional tmux wrapping.

```bash
#!/bin/bash
# config/entrypoint.sh

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
# Use exec + gosu/su to maintain PID 1 and signal handling
if [ "${TEAMMATE_MODE}" = "tmux" ] && [ -z "$TMUX" ]; then
    # Start tmux session, then run claude inside it
    exec su claude -c "tmux new-session -s claude 'claude --dangerously-skip-permissions $*'"
else
    exec su claude -c "claude --dangerously-skip-permissions $*"
fi
```

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
      # --- Auth ---
      - ${HOME}/.claude.json:/home/claude/.claude.json
      
      # --- Global config → user-level (~/.claude/) ---
      # Paths are absolute, resolved by cco CLI from GLOBAL_DIR
      - ${GLOBAL_DIR}/.claude/settings.json:/home/claude/.claude/settings.json:ro
      - ${GLOBAL_DIR}/.claude/CLAUDE.md:/home/claude/.claude/CLAUDE.md:ro
      - ${GLOBAL_DIR}/.claude/rules:/home/claude/.claude/rules:ro
      - ${GLOBAL_DIR}/.claude/agents:/home/claude/.claude/agents:ro
      - ${GLOBAL_DIR}/.claude/skills:/home/claude/.claude/skills:ro
      
      # --- Project config → project-level (/workspace/.claude/) ---
      - ./.claude:/workspace/.claude
      
      # --- Claude state: auto memory + session transcripts ---
      - ./claude-state:/home/claude/.claude/projects/-workspace
      
      # --- Repositories ---
      # (generated from project.yml repos list)
      # - /Users/user/projects/backend-api:/workspace/backend-api
      # - /Users/user/projects/frontend-app:/workspace/frontend-app
      
      # --- Git config ---
      - ${HOME}/.gitconfig:/home/claude/.gitconfig:ro
      - ${HOME}/.ssh:/home/claude/.ssh:ro
      
      # --- Docker socket (Docker-from-Docker) ---
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
HOST                                    CONTAINER                  PURPOSE
─────────────────────────────────────────────────────────────────────────────
~/.claude.json                       → /home/claude/.claude.json   Auth (rw)
$GLOBAL_DIR/.claude/settings.json    → ~/.claude/settings.json     Global settings (ro)
$GLOBAL_DIR/.claude/CLAUDE.md        → ~/.claude/CLAUDE.md         Global instructions (ro)
$GLOBAL_DIR/.claude/rules/           → ~/.claude/rules/            Global rules (ro)
$GLOBAL_DIR/.claude/agents/          → ~/.claude/agents/           Global subagents (ro)
$GLOBAL_DIR/.claude/skills/          → ~/.claude/skills/           Global skills (ro)
projects/<n>/.claude/                → /workspace/.claude/         Project context (rw)
projects/<n>/memory/                 → ~/.claude/projects/         Auto memory (rw)
                                       workspace/memory/
~/projects/repo-x/                   → /workspace/repo-x/          Repository (rw)
~/.gitconfig                         → ~/.gitconfig                 Git config (ro)
~/.ssh/                              → ~/.ssh/                      SSH keys (ro)
/var/run/docker.sock                 → /var/run/docker.sock         Docker socket
```

**Read-only vs Read-write**:
- `ro`: Config that should not be modified by the agent (global settings, git config)
- `rw` (default): Repos (Claude writes code), project .claude/ (Claude may update), memory (Claude writes), `~/.claude.json` (Claude Code updates session metadata on every startup — must be writable)

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
# or just rebuild the npm layer:
docker build --no-cache --target=claude-code -t claude-orchestrator:latest .
```

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
- Auto memory persists in `projects/<n>/memory/`
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
