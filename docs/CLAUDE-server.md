# CLAUDE.md - Server/Backend Guidelines

This file provides guidance to Claude Code (claude.ai/code) when working with the **server** portion of the `claude-orchestrator` project.

## Project Overview
`claude-orchestrator` manages isolated Claude Code sessions in Docker containers for multi-project, multi-repo development. It provides a CLI (`bin/cco`) to launch preconfigured sessions with repos mounted, context loaded, and agent teams ready.

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

## Architecture Principles
1. **Docker-from-Docker**: The host's Docker socket is mounted into the container. Sibling containers are created on the host daemon—not nested containers. Share a project-scoped network (`cc-<project-name>`).
2. **Three-Tier Context**:
   - `global/.claude/` -> `~/.claude/` (Global User Settings)
   - `projects/<name>/.claude/` -> `/workspace/.claude/` (Project-level Context)
   - Repo's own `.claude/` -> `/workspace/<repo>/.claude/` (Nested/Local Context)
3. **Docker IS the Sandbox**: No native sandboxing. `--dangerously-skip-permissions` is necessary and safe inside the isolated container.
4. **Auto Memory Isolation**: Each project gets its own memory directory mounted natively to avoid cross-contamination.

## Structure & File Responsibilities
- `bin/cco`: The source of truth for CLI logic (Bash).
- `Dockerfile`: Image definition (node base, gosu, tmux, docker).
- `config/entrypoint.sh`: Crucial for setting up user permissions, handling the Docker socket GID mismatch, and launching tmux.
- `project.yml`: The declarative source of truth for each project.
- `docker-compose.yml`: Auto-generated from `project.yml`. **DO NOT COMMIT** generated compose files.

## Code Style & Conventions
- **Bash Scripting**: 
  - Scripts must be Bash 4+ compatible.
  - Rely on standard Unix tools (`jq`, `sed`, `awk`).
  - Keep scripts modular but bundled where appropriate.
- **Docker**:
  - Container user is `claude` (non-root), part of the `docker` group.
  - Never use `network_mode: host` (fails on macOS Desktop). Rely on explicit port mappings.
- **Immutability**:
  - `global/` and `projects/` hold user state (gitignored).
  - `defaults/` holds tracked boilerplate/tool code.

## Key Rules for AI Execution
- When modifying the Docker setup, thoroughly test socket permissions (`/var/run/docker.sock`).
- Any new context layer must follow the hierarchy override precedence (Repo > Project > Global).
- Do not introduce binary dependencies in the CLI wrapper (`bin/cco`) unless absolutely necessary via `apt` inside the Dockerfile.
