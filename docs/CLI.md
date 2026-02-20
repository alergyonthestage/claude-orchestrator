# CLI Specification

> Version: 1.0.0
> Status: Draft — Pending Review
> Related: [SPEC.md](./SPEC.md) | [DOCKER.md](./DOCKER.md)

---

## 1. Overview

The CLI is a single bash script at `bin/cco` that orchestrates Docker sessions. It has no dependencies beyond `bash`, `docker`, and standard Unix tools (`sed`, `awk`, `jq`).

---

## 2. Installation

```bash
# Clone the repo
git clone <repo-url> ~/claude-orchestrator
cd ~/claude-orchestrator

# Initialize user config and build Docker image
cco init

# Add to PATH (if not done automatically)
# bash:
echo 'export PATH="$PATH:$HOME/claude-orchestrator/bin"' >> ~/.bashrc && source ~/.bashrc
# zsh:
# echo 'export PATH="$PATH:$HOME/claude-orchestrator/bin"' >> ~/.zshrc && source ~/.zshrc
```

---

## 3. Commands

### 3.0 `cco init`

Initialize user configuration by copying defaults. Required before first use.

```
Usage: cco init [--force]

Options:
  --force    Overwrite existing global/ config with defaults

Examples:
  cco init            # First-time setup
  cco init --force    # Reset global config to defaults
```

**Flow**:

```
1. COPY defaults/global/ → global/
   - If global/ exists: skip (warn user, suggest --force)
   - If --force: overwrite

2. CREATE projects/ directory (if needed)

3. PATH HINT
   - If cco is not in PATH, show the export command

4. BUILD Docker image
   - If Docker is running, run `cco build`
   - Otherwise, warn to run it later
```

---

### 3.1 `cco build`

Build or rebuild the Docker image.

```
Usage: cco build [--no-cache] [--mcp-packages "pkg1 pkg2"]

Options:
  --no-cache               Force rebuild without Docker cache (updates Claude Code)
  --mcp-packages "pkgs"    Pre-install MCP server npm packages in the image

Examples:
  cco build
  cco build --no-cache
  cco build --mcp-packages "@modelcontextprotocol/server-github"
```

MCP packages can also be listed in `global/mcp-packages.txt` (one per line) for automatic loading on every build.

---

### 3.2 `cco start <project>`

Start an interactive Claude Code session for a configured project.

```
Usage: cco start <project> [OPTIONS]

Arguments:
  project              Name of the project (directory under projects/)

Options:
  --teammate-mode <m>  Override display mode: tmux | auto
  --api-key            Use ANTHROPIC_API_KEY instead of OAuth
  --dry-run            Show the generated docker-compose without running
  --port <p>           Add extra port mapping (repeatable)
  --env <K=V>          Add extra environment variable (repeatable)

Examples:
  cco start my-saas
  cco start my-saas --teammate-mode auto
  cco start my-saas --port 9090:9090
  cco start my-saas --dry-run
```

**Flow**:

```
1. VALIDATE
   - Check projects/<project>/project.yml exists
   - Parse project.yml
   - Verify each repo path exists on host
   - Check Docker image exists (suggest `cco build` if not)

2. GENERATE docker-compose.yml
   - Read project.yml repos → generate volume mounts
   - Read project.yml ports → generate port mappings
   - Read project.yml auth → set auth volumes/env vars
   - If mcp.json exists → mount as /workspace/.mcp.json (Claude Code expands ${VAR} natively)
   - Mount global MCP config for entrypoint merge
   - Apply CLI overrides (--port, --env, --teammate-mode)
   - Write to projects/<project>/docker-compose.yml

3. CREATE directories (if needed)
   - projects/<project>/memory/  (for auto memory)

4. LAUNCH
   - Load global/secrets.env as runtime env vars
   - docker compose -f projects/<project>/docker-compose.yml \
       run --rm --service-ports claude
   
5. CLEANUP (after exit)
   - Container auto-removed (--rm)
   - Print summary: "Session ended. Changes are in your repos."
```

---

### 3.3 `cco new`

Start a temporary session without a project template.

```
Usage: cco new [OPTIONS]

Options:
  --repo <path>        Repository to mount (repeatable, at least one required)
  --name <name>        Temporary session name (default: "tmp-<timestamp>")
  --teammate-mode <m>  Override display mode
  --port <p>           Port mapping (repeatable)

Examples:
  cco new --repo ~/projects/my-experiment
  cco new --repo ~/projects/api --repo ~/projects/frontend
  cco new --repo ~/projects/app --port 3000:3000
```

**Flow**:

```
1. VALIDATE
   - At least one --repo is provided
   - Each repo path exists

2. GENERATE temporary docker-compose
   - Create temp dir: /tmp/cc-<name>/
   - Generate docker-compose.yml with:
     - Global config mounted (same as projects)
     - No project .claude/ (empty /workspace/.claude/)
     - Specified repos mounted as subdirectories
     - Auto memory in temp dir

3. LAUNCH
   - Same as `cco start` but with temp compose file

4. CLEANUP
   - Container removed
   - Temp dir preserved (memory may be useful)
   - Print path to temp dir for reference
```

---

### 3.4 `cco project create <name>`

Create a new project from the template.

```
Usage: cco project create <name> [OPTIONS]

Arguments:
  name                 Project name (lowercase, hyphens, no spaces)

Options:
  --repo <path>        Add a repo to the project (repeatable)
  --description <d>    Project description

Examples:
  cco project create my-saas --repo ~/projects/api --repo ~/projects/web
  cco project create experiment --description "Testing new auth flow"
```

**Flow**:

```
1. VALIDATE
   - Name is valid (lowercase, hyphens, no spaces)
   - projects/<name>/ does not already exist

2. COPY template
   - Copy defaults/_template/ → projects/<name>/

3. CONFIGURE
   - If --repo flags provided: write repos to project.yml
   - If --description provided: update project.yml and CLAUDE.md
   - Replace {{PROJECT_NAME}} and {{DESCRIPTION}} placeholders

4. CREATE directories
   - projects/<name>/memory/

5. PRINT
   - "Project created at projects/<name>/"
   - "Edit project.yml to configure repos and settings"
   - "Run: cco start <name>"
```

---

### 3.5 `cco project list`

List available projects with their status.

```
Usage: cco project list

Output:
  NAME           REPOS    STATUS
  my-saas        3        stopped
  experiment     1        running
  _template      -        (template)
```

**Implementation**:
- List directories under `projects/` (exclude `_template`)
- Parse each `project.yml` for repo count
- Check Docker for running containers (`cc-<name>`)

---

### 3.6 `cco stop [project]`

Stop a running session.

```
Usage: cco stop [project]

Arguments:
  project     Stop specific project session. If omitted, stop all.

Examples:
  cco stop my-saas
  cco stop              # Stop all running sessions
```

**Implementation**:
```bash
# Specific project
docker stop cc-<project>

# All sessions
docker ps --filter "name=cc-" -q | xargs docker stop
```

---

## 4. Project Configuration Format (project.yml)

```yaml
# projects/<name>/project.yml

name: my-saas-platform
description: "Main SaaS platform with API, frontend, and shared libraries"

# ── Repositories ─────────────────────────────────────────────────────
repos:
  - path: ~/projects/backend-api        # Absolute path on host
    name: backend-api                    # Mount name in /workspace/
    
  - path: ~/projects/frontend-app
    name: frontend-app
    
  - path: ~/projects/shared-libs
    name: shared-libs

# ── Extra mounts (optional) ─────────────────────────────────────────
extra_mounts:
  - source: ~/documents/api-specs
    target: /workspace/docs/api-specs
    readonly: true

# ── Docker options ───────────────────────────────────────────────────
docker:
  # Port mappings (host:container)
  ports:
    - "3000:3000"       # Frontend dev
    - "4000:4000"       # Backend API
    - "5432:5432"       # PostgreSQL
    - "6379:6379"       # Redis

  # Extra environment variables
  env:
    NODE_ENV: development
    DATABASE_URL: "postgresql://postgres:postgres@postgres:5432/myapp"

  # Network name for sibling containers
  network: cc-my-saas

# ── Authentication ───────────────────────────────────────────────────
auth:
  method: oauth         # "oauth" (default) | "api_key"
  # If api_key: reads from ANTHROPIC_API_KEY env var
```

### 4.1 Field Reference

| Field | Required | Type | Default | Description |
|-------|----------|------|---------|-------------|
| `name` | ✅ | string | — | Project identifier |
| `description` | ❌ | string | `""` | Human-readable description |
| `repos` | ✅ | list | — | Repositories to mount |
| `repos[].path` | ✅ | string | — | Absolute path on host (~ expanded) |
| `repos[].name` | ✅ | string | — | Directory name in /workspace/ |
| `extra_mounts` | ❌ | list | `[]` | Additional volume mounts |
| `extra_mounts[].source` | ✅ | string | — | Host path |
| `extra_mounts[].target` | ✅ | string | — | Container path |
| `extra_mounts[].readonly` | ❌ | bool | `false` | Mount as read-only |
| `docker.ports` | ❌ | list | see defaults | Port mappings |
| `docker.env` | ❌ | map | `{}` | Environment variables |
| `docker.network` | ❌ | string | `cc-<name>` | Docker network name |
| `auth.method` | ❌ | string | `oauth` | Authentication method |

---

## 5. Generated docker-compose.yml

The CLI generates `docker-compose.yml` from `project.yml`. The generated file includes a header comment:

```yaml
# AUTO-GENERATED by cco CLI from project.yml
# Manual edits will be overwritten on next `cco start`
# To customize, edit project.yml instead

services:
  claude:
    image: claude-orchestrator:latest
    container_name: cc-my-saas-platform
    stdin_open: true
    tty: true
    environment:
      - PROJECT_NAME=my-saas-platform
      - TEAMMATE_MODE=tmux
      - CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
      - NODE_ENV=development
      - DATABASE_URL=postgresql://postgres:postgres@postgres:5432/myapp
    volumes:
      # Auth
      - ~/.claude.json:/home/claude/.claude.json:ro
      # Global config
      - ../../global/.claude/settings.json:/home/claude/.claude/settings.json:ro
      - ../../global/.claude/CLAUDE.md:/home/claude/.claude/CLAUDE.md:ro
      - ../../global/.claude/rules:/home/claude/.claude/rules:ro
      - ../../global/.claude/agents:/home/claude/.claude/agents:ro
      - ../../global/.claude/skills:/home/claude/.claude/skills:ro
      # Project config
      - ./.claude:/workspace/.claude
      # Auto memory
      - ./memory:/home/claude/.claude/projects/workspace/memory
      # Repositories
      - ~/projects/backend-api:/workspace/backend-api
      - ~/projects/frontend-app:/workspace/frontend-app
      - ~/projects/shared-libs:/workspace/shared-libs
      # Extra mounts
      - ~/documents/api-specs:/workspace/docs/api-specs:ro
      # Git
      - ~/.gitconfig:/home/claude/.gitconfig:ro
      - ~/.ssh:/home/claude/.ssh:ro
      # Docker socket
      - /var/run/docker.sock:/var/run/docker.sock
    ports:
      - "3000:3000"
      - "4000:4000"
      - "5432:5432"
      - "6379:6379"
    networks:
      - cc-my-saas
    working_dir: /workspace

networks:
  cc-my-saas:
    name: cc-my-saas
    driver: bridge
```

---

## 6. Error Handling

| Scenario | Behavior |
|----------|----------|
| Project not found | `Error: Project 'foo' not found. Run 'cco project list' to see available projects.` |
| Repo path doesn't exist | `Error: Repository path ~/projects/foo does not exist.` |
| Docker image not built | `Error: Docker image 'claude-orchestrator:latest' not found. Run 'cco build' first.` |
| Docker not running | `Error: Docker daemon is not running. Start Docker Desktop.` |
| Port conflict | `Error: Port 3000 is already in use. Stop the conflicting service or use --port to remap.` |
| Project already exists | `Error: Project 'foo' already exists at projects/foo/` |

---

## 7. MCP Server Configuration

### 7.1 Project MCP (`mcp.json`)

Each project can include a `mcp.json` file using Claude Code's native `.mcp.json` format:

```json
{
  "mcpServers": {
    "github": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": {
        "GITHUB_TOKEN": "${GITHUB_TOKEN}"
      }
    }
  }
}
```

The `${VAR}` placeholders are expanded **natively by Claude Code** inside the container. The env vars must be available in the container environment via `global/secrets.env`, `project.yml` `docker.env`, or `--env` CLI flags.

**Important**: If a `${VAR}` reference in `mcp.json` cannot be resolved (env var not set), Claude Code will fail to parse the entire file and show "No MCP servers configured".

### 7.2 Global MCP (`global/.claude/mcp.json`)

MCP servers defined here are available in all projects. The entrypoint merges them into `~/.claude.json` at container startup.

### 7.3 Secrets (`global/secrets.env`)

```bash
# global/secrets.env — gitignored
GITHUB_TOKEN=ghp_...
LINEAR_API_KEY=lin_api_...
```

Loaded by `cco start` and `cco new` as runtime `-e` flags. Never written to `docker-compose.yml`.

---

## 8. Shell Completion (Future)

Bash/Zsh completion for:
- `cco start <TAB>` → list project names
- `cco project create <TAB>` → suggest name patterns
- `cco stop <TAB>` → list running sessions

Not in v1 scope but trivial to add later.
