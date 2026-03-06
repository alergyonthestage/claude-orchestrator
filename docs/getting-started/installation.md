# Installation and Quick Start

> From zero to working session in minutes.

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
1. Copies user defaults to `user-config/global/.claude/` (agents, skills, rules, settings)
2. Creates the `user-config/projects/` directory
3. Runs `cco build` to build the Docker image

---

## Quick use

```bash
# Create a project
cco project create my-app --repo ~/projects/my-app

# Configure the project
vim user-config/projects/my-app/project.yml         # repos, ports, auth
vim user-config/projects/my-app/.claude/CLAUDE.md   # instructions for Claude

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
| `cco start <project>` | Start session for a configured project |
| `cco new --repo <path>` | Temporary session with specific repositories |
| `cco project create <name>` | Create a new project from template |
| `cco project list` | List available projects |
| `cco stop [project]` | Stop running session(s) |

For the complete CLI reference, see [cli.md](../reference/cli.md).

---

## Project configuration

Each project lives in `user-config/projects/<name>/` and contains:

- **`project.yml`** — repositories to mount, ports, environment variables, authentication method
- **`.claude/CLAUDE.md`** — Claude-specific instructions
- **`.claude/settings.json`** — override global settings (optional)
- **`.claude/agents/`** — project-specific subagents (optional)

For the complete `project.yml` format, see [project-yaml.md](../reference/project-yaml.md).

---

## First-run troubleshooting

| Problem | Solution |
|---------|----------|
| Docker daemon not running | Start Docker Desktop (macOS) or `sudo systemctl start docker` (Linux) |
| Image build fails | `cco build --no-cache` — check internet connection and Docker disk space |
| Port conflict | `cco start my-app --port 3001:3000` to remap |
| Image not found | Run `cco build` (should happen automatically during `cco init`) |

For more troubleshooting, see [troubleshooting.md](../user-guides/troubleshooting.md).

---

## Next steps

- [Your first project](first-project.md) — step-by-step tutorial
- [Key concepts](concepts.md) — context hierarchy, knowledge packs, agent teams
- [Knowledge packs](../user-guides/knowledge-packs.md) — reusable cross-project documentation
- [Sharing & backup](../user-guides/sharing.md) — version your config, share packs with your team
