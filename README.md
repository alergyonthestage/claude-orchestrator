# claude-orchestrator

> Orchestrate Claude Code sessions in Docker for multi-project, multi-repo development.

## What Is This?

A repository that manages isolated Claude Code sessions in Docker containers. Each session comes pre-configured with your project context, agent teams, and development workflow — one command to start.

See [QUICK-START.md](QUICK-START.md) for setup and usage instructions.

## How It Works

```
Host                                Docker Container
───────────────────────────────────────────────────────
defaults/              (tool code, tracked in git)
global/.claude/        ──mount──► ~/.claude/              (user config, gitignored)
global/packs/<name>/   ──mount──► /workspace/.packs/<n>/  (knowledge packs, gitignored)
projects/my-app/.claude/ ──mount──► /workspace/.claude/   (project context, gitignored)
~/projects/backend/    ──mount──► /workspace/backend/     (your repo, read-write)
~/projects/frontend/   ──mount──► /workspace/frontend/    (your repo, read-write)
Docker socket          ──mount──► Docker socket            (run containers from inside)

                                  $ claude --dangerously-skip-permissions
                                  (interactive session with full context)

Setup: git clone → cco init → cco project create → cco start
```

## Key Design Decisions

- **Docker isolation**: No native sandboxing — Docker IS the sandbox. `--dangerously-skip-permissions` is safe inside the container.
- **Docker-from-Docker**: Docker socket mounted so Claude can run `docker compose` for infrastructure. Creates sibling containers on the host daemon, not nested.
- **Three-tier context**: global → project → repo, mapped to Claude Code's user → project → nested hierarchy. No hacks or symlinks needed.
- **Knowledge packs**: reusable document bundles (conventions, business overviews, guidelines) defined once in `global/packs/` and activated per-project. Source of truth stays in your knowledge repo; no file copying.
- **Agent teams**: tmux by default (works everywhere), iTerm2 optional (native panes on macOS).
- **Workflow**: Analysis → Design → Implementation → Documentation, all manual transitions.
- **Auto memory isolation**: each project gets its own memory directory, so insights don't leak across projects.

## Requirements

- macOS or Linux
- Docker Desktop (macOS) or Docker Engine (Linux)
- Bash 4+
- Claude Code account (Pro/Team/Enterprise or API key)

## Documentation

| Document | Contents |
|----------|----------|
| [QUICK-START.md](QUICK-START.md) | Setup and usage guide |
| [docs/SPEC.md](docs/SPEC.md) | Requirements specification |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Architecture decisions and system design |
| [docs/DOCKER.md](docs/DOCKER.md) | Docker image, compose, networking |
| [docs/CONTEXT.md](docs/CONTEXT.md) | Context hierarchy and settings management |
| [docs/CLI.md](docs/CLI.md) | CLI commands specification |
| [docs/SUBAGENTS.md](docs/SUBAGENTS.md) | Custom subagents and creation guide |
| [docs/DISPLAY-MODES.md](docs/DISPLAY-MODES.md) | Agent teams display: tmux vs iTerm2 |
| [docs/PROJECT-SETUP.md](docs/PROJECT-SETUP.md) | Project setup guide, repos vs extra_mounts vs packs |
| [docs/ROADMAP.md](docs/ROADMAP.md) | Planned features and future enhancements |
| [docs/DIRECTORY-STRUCTURE.md](docs/DIRECTORY-STRUCTURE.md) | File inventory and implementation order |
