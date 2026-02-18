# claude-orchestrator

> Orchestrate Claude Code sessions in Docker for multi-project, multi-repo development.

## What Is This?

A repository that manages isolated Claude Code sessions in Docker containers. Each session comes pre-configured with your project context, agent teams, and development workflow — one command to start.

## Quick Start

```bash
# 1. Clone and enter
git clone <repo-url> ~/claude-orchestrator
cd ~/claude-orchestrator

# 2. Add CLI to PATH
echo 'export PATH="$PATH:$HOME/claude-orchestrator/bin"' >> ~/.zshrc
source ~/.zshrc

# 3. Build the Docker image
cc build

# 4. Create your first project
cc project create my-app --repo ~/projects/my-app

# 5. Edit project config
vim projects/my-app/project.yml
vim projects/my-app/.claude/CLAUDE.md

# 6. Start a session
cc start my-app
```

## How It Works

```
Host                              Docker Container
─────────────────────────────────────────────────────
global/.claude/        ──mount──► ~/.claude/         (global settings, agents, rules)
projects/my-app/.claude/ ──mount──► /workspace/.claude/ (project context)
~/projects/backend/    ──mount──► /workspace/backend/  (your repo, read-write)
~/projects/frontend/   ──mount──► /workspace/frontend/ (your repo, read-write)
Docker socket          ──mount──► Docker socket        (run containers from inside)
                                  
                                  $ claude --dangerously-skip-permissions
                                  (interactive session with full context)
```

## Commands

| Command | Description |
|---------|-------------|
| `cc start <project>` | Start a session for a configured project |
| `cc new --repo <path>` | Start a temporary session with specific repos |
| `cc project create <n>` | Create a new project from template |
| `cc project list` | List available projects |
| `cc build` | Build/rebuild the Docker image |
| `cc stop [project]` | Stop running session(s) |

## Documentation

| Document | Contents |
|----------|----------|
| [docs/SPEC.md](docs/SPEC.md) | Requirements specification |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Architecture decisions and system design |
| [docs/DOCKER.md](docs/DOCKER.md) | Docker image, compose, networking |
| [docs/CONTEXT.md](docs/CONTEXT.md) | Context hierarchy and settings management |
| [docs/CLI.md](docs/CLI.md) | CLI commands specification |
| [docs/SUBAGENTS.md](docs/SUBAGENTS.md) | Custom subagents and creation guide |
| [docs/DISPLAY-MODES.md](docs/DISPLAY-MODES.md) | Agent teams display: tmux vs iTerm2 |
| [docs/DIRECTORY-STRUCTURE.md](docs/DIRECTORY-STRUCTURE.md) | File inventory and implementation order |

## Key Design Decisions

- **Docker isolation**: No native sandboxing — Docker IS the sandbox. `--dangerously-skip-permissions` is safe.
- **Docker-from-Docker**: Docker socket mounted so Claude can run `docker compose` for infrastructure.
- **Three-tier context**: global → project → repo, mapped to Claude Code's user → project → nested hierarchy.
- **Agent teams**: tmux by default (works everywhere), iTerm2 optional (native panes on macOS).
- **Workflow**: Analysis → Design → Implementation → Documentation, all manual transitions.

## Requirements

- macOS or Linux
- Docker Desktop (macOS) or Docker Engine (Linux)
- Bash 4+
- Claude Code account (Pro/Team/Enterprise or API key)
