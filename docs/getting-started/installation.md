# Installation and Quick Start

> From zero to working session in ~15 minutes (Docker image build takes ~10 minutes on first run).

---

## Prerequisites

| Requirement | Notes |
|-----------|------|
| **macOS or Linux** | Windows not supported (WSL2 not tested) |
| **Docker Desktop** (macOS) or **Docker Engine** (Linux) | Must be running |
| **Bash 4+** | macOS includes bash 3.2 (`/bin/bash`) — sufficient for the CLI |
| **jq** | `brew install jq` (macOS) / `apt install jq` (Linux) |
| **Claude Code account** | Pro, Team, Enterprise, or API key |

---

## Setup

```bash
# 1. Clone the repo
git clone <repo-url> ~/claude-orchestrator
cd ~/claude-orchestrator

# 2. Add the CLI to PATH
# bash:
echo 'export PATH="$PATH:$HOME/claude-orchestrator/bin"' >> ~/.bashrc
source ~/.bashrc

# zsh:
# echo 'export PATH="$PATH:$HOME/claude-orchestrator/bin"' >> ~/.zshrc
# source ~/.zshrc

# 3. Initialize user configuration and build Docker image
cco init
```

`cco init` performs three operations:
1. Copies user defaults to `global/.claude/` (agents, skills, rules, settings)
2. Creates the `projects/` directory
3. Runs `cco build` to build the Docker image

---

## Quick use

```bash
# Create a project
cco project create my-app --repo ~/projects/my-app

# Configure the project
vim projects/my-app/project.yml         # repos, ports, auth
vim projects/my-app/.claude/CLAUDE.md   # instructions for Claude

# Start a session
cco start my-app

# Tip: in the first session, use /init-workspace to automatically
# generate a detailed CLAUDE.md based on the codebase
```

For temporary sessions without creating a project:

```bash
cco new --repo ~/projects/experiment
cco new --repo ~/projects/api --repo ~/projects/frontend --port 3000:3000
```

---

## Main commands

| Command | Description |
|---------|-------------|
| `cco init` | Initialize user configuration and build image |
| `cco build` | Build the Docker image |
| `cco build --no-cache` | Full rebuild (updates Claude Code) |
| `cco build --claude-version x.y.z` | Pin Claude Code to a specific version |
| `cco start <project>` | Start session for a configured project |
| `cco start <project> --dry-run` | Show generated docker-compose without running |
| `cco new --repo <path>` | Temporary session with specific repositories |
| `cco project create <name>` | Create a new project from template |
| `cco project list` | List available projects |
| `cco stop [project]` | Stop running session(s) |

---

## Project configuration

Each project lives in `projects/<name>/` and contains:

- **`project.yml`** — repositories to mount, ports, environment variables, authentication method
- **`.claude/CLAUDE.md`** — Claude-specific instructions
- **`.claude/settings.json`** — override global settings (optional)
- **`.claude/agents/`** — project-specific subagents (optional)

For the complete `project.yml` format, see [cli.md](../reference/cli.md).

---

## Knowledge packs

Packs allow you to share cross-project documentation (conventions, business overview, guidelines) and optionally skills/agents/rules without copying files.

```bash
# 1. Define a pack in global/packs/<name>/pack.yml
cat > global/packs/my-client/pack.yml << 'EOF'
name: my-client

knowledge:
  source: ~/documents/my-client-knowledge   # directory with documents
  files:
    - path: backend-conventions.md
      description: "Read when writing backend code or APIs"
    - path: business-overview.md
      description: "Read for business context and domain terminology"
    - testing-guidelines.md
EOF

# 2. Activate the pack in project.yml
# packs:
#   - my-client

# 3. Start — packs are automatically injected
cco start my-app
```

`cco start` mounts the source directory read-only, generates `packs.md` with the file list, and the `session-context.sh` hook injects it into `additionalContext` at startup. Original files remain in your directory — zero duplication.

---

## Additional options

```bash
# Override agent team mode
cco start my-app --teammate-mode auto    # Native iTerm2 (requires setup)
cco start my-app --teammate-mode tmux    # default, works everywhere

# Use API key instead of OAuth
cco start my-app --api-key

# Additional ports and environment variables
cco start my-app --port 9090:9090 --env DEBUG=true
```

---

## First-run troubleshooting

### Docker not running

```
Error: Docker daemon is not running. Start Docker Desktop.
```

Start Docker Desktop (macOS) or the Docker service (`sudo systemctl start docker` on Linux), then try again.

### Image build fails

```bash
# Retry with a clean build
cco build --no-cache
```

If the problem persists, check your internet connection (the image downloads `node:22-bookworm` and npm packages) and that Docker has enough disk space.

### Port conflict

```
Error: Port 3000 is already in use.
```

Another service is using the port. Stop it, or use a different port:

```bash
cco start my-app --port 3001:3000
```

### Docker image not found

```
Error: Docker image 'claude-orchestrator:latest' not found. Run 'cco build' first.
```

Run `cco build` to build the image. If you already ran `cco init`, the build should have been started automatically.

---

## Next steps

- [Your first project](first-project.md) — step-by-step tutorial
- [Key concepts](concepts.md) — context hierarchy, knowledge packs, agent teams
- [Overview](overview.md) — what is and how claude-orchestrator works
