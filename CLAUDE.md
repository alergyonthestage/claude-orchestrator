# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

claude-orchestrator manages isolated Claude Code sessions in Docker containers for multi-project, multi-repo development. It provides a CLI (`bin/cco`) to launch preconfigured sessions with repos mounted, context loaded, and agent teams ready.

**Current status**: v1 implemented. Dockerfile, CLI, global config, project template, and all docs are in place.

**Config separation**: `defaults/system/` contains system-managed files (skills, agents, rules, settings.json) that are always synced to `global/.claude/`. `defaults/global/` contains user defaults (CLAUDE.md, mcp.json, language.md) copied once on `cco init`. User config lives in `global/` and `projects/` (gitignored).

## Build & Run Commands

```bash
cco init                     # First-time setup: copy defaults, build image
cco build                    # Build Docker image
cco build --no-cache         # Rebuild (updates Claude Code)
cco build --claude-version x.y.z  # Pin Claude Code version
cco start <project>          # Start session for a project
cco new --repo <path>        # Start temporary session with repos
cco project create <name>    # Scaffold new project from template
cco project list             # List projects
cco stop [project]           # Stop session(s)
```
 
The CLI is a single bash script at `bin/cco` with no dependencies beyond bash (3.2+), docker, and standard Unix tools (jq, sed, awk). Compatible with macOS default `/bin/bash` — no Homebrew bash required.

## Architecture

### Three-Tier Context Hierarchy

The orchestrator maps onto Claude Code's native settings resolution:

| Orchestrator Layer | Container Mount | Claude Code Scope |
|---|---|---|
| `global/.claude/` | `~/.claude/` | User-level (always loaded) |
| `projects/<name>/.claude/` | `/workspace/.claude/` | Project-level (always loaded) |
| Repo's own `.claude/` | `/workspace/<repo>/.claude/` | Nested (on-demand) |

Project settings override global settings per Claude Code's precedence.

### Docker-from-Docker

The host's Docker socket is mounted into the container. Claude can run `docker compose up` to create **sibling containers** on the host daemon — not nested containers. All sibling containers share a project-scoped network (`cc-<project-name>`).

### Session Startup Flow

`cco start` → read `project.yml` → validate repo paths → generate `docker-compose.yml` → `docker compose run --rm --service-ports claude` → entrypoint handles socket perms + tmux → `claude --dangerously-skip-permissions`

### Key Design Decisions

- **Docker IS the sandbox**: no native Claude Code sandboxing. `--dangerously-skip-permissions` is safe inside the container.
- **Flat workspace layout**: WORKDIR is `/workspace`, each repo is a direct subdirectory. No `--add-dir` needed.
- **Auto memory isolation**: each project's `memory/` dir is mounted to `~/.claude/projects/workspace/memory/` so projects don't share memory.
- **Agent teams**: tmux by default (works everywhere), iTerm2 optional via `--teammate-mode auto`.
- **Auth**: OAuth (`~/.claude.json` mounted read-only as seed, copied at startup) by default, API key via env var as alternative.

## Implementation Order

Per `docs/maintainer/directory-structure.md`:

1. **Docker**: `Dockerfile`, `config/entrypoint.sh`, `config/tmux.conf`, `config/hooks/`, `.dockerignore`
2. **Global Config**: system files in `defaults/system/.claude/`, user defaults in `defaults/global/.claude/`, merged in `global/.claude/`
3. **Project Template**: `defaults/_template/`
4. **CLI**: `bin/cco`
5. **Root Files**: `.gitignore`

## Key Files

**Implementation:**
- `bin/cco` — CLI script (single bash file, all commands)
- `Dockerfile` — Docker image (node:22-bookworm, Claude Code, gosu, tmux, docker CLI)
- `config/entrypoint.sh` — Container entrypoint: socket GID fix, MCP merge, gosu, tmux/claude launch
- `config/tmux.conf` — tmux config for agent teams (colors, navigation, history)
- `config/hooks/session-context.sh` — SessionStart hook: injects repo list and MCP info into context
- `config/hooks/statusline.sh` — StatusLine hook: displays `[project] model | ctx XX% | $cost`
- `defaults/system/` — System-managed files: skills, agents, rules, settings.json (always synced to global/)
- `defaults/system/system.manifest` — Lists all system-managed file paths
- `defaults/global/.claude/` — User defaults: CLAUDE.md, mcp.json, language.md (copied once on init)

**Documentation:**
- `docs/maintainer/spec.md` — requirements specification
- `docs/maintainer/architecture.md` — ADRs and system design
- `docs/maintainer/docker.md` — Dockerfile, compose template, networking
- `docs/reference/context.md` — context hierarchy, settings, auto memory, subagents
- `docs/reference/cli.md` — CLI commands and `project.yml` format
- `docs/guides/subagents.md` — analyst (haiku) and reviewer (sonnet) agent specs
- `docs/guides/display-modes.md` — tmux vs iTerm2 setup
- `docs/guides/project-setup.md` — project setup guide, repos vs extra_mounts, writing CLAUDE.md

## Conventions

- `project.yml` is the source of truth for each project; `docker-compose.yml` is generated from it and should not be committed.
- `global/` and `projects/` are gitignored (user data). `defaults/` is tracked (tool code). System files in `defaults/system/` are always synced to `global/.claude/` on init/start/new.
- Generated files: `projects/*/docker-compose.yml`, `projects/*/memory/`, `.env`.
- Container user is `claude` (non-root), with docker group for socket access.
- Entrypoint must handle Docker socket GID mismatch between host and container.
- macOS Docker Desktop: never use `network_mode: host` (refers to Linux VM, not macOS). Always use port mappings.
