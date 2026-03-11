# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

claude-orchestrator manages isolated Claude Code sessions in Docker containers for multi-project, multi-repo development. It provides a CLI (`bin/cco`) to launch preconfigured sessions with repos mounted, context loaded, and agent teams ready.

**Current status**: v1 implemented, plus Auth & Secrets, Environment Extensibility, Docker Socket Toggle, Scope Hierarchy Refactor, Config Repo sharing, and Docker Socket Security (Go proxy with policy-based filtering). Dockerfile, CLI, global config, project template, and all docs are in place.

**Config separation**: Three-tier managed scope hierarchy leveraging Claude Code's native resolution:
- `defaults/managed/` → baked into Docker image at `/etc/claude-code/` (Managed level — hooks, env, deny rules, framework instructions). Non-overridable.
- `defaults/global/.claude/` → copied once to `user-config/global/.claude/` on `cco init` (User level — agents, skills, rules, settings, preferences). User-owned, never overwritten.
- `defaults/_template/` → scaffolded per project (Project level). Per-project overrides.

**User config directory**: `user-config/` is the unified root for all user data:
- `user-config/global/` — global Claude config (.claude/)
- `user-config/projects/` — per-project configurations
- `user-config/packs/` — knowledge packs
- `user-config/templates/` — project templates
- `user-config/manifest.yml` — manifest for sharing via Config Repos

## Build & Run Commands

```bash
cco init                     # First-time setup: copy defaults, build image
cco build                    # Build Docker image
cco build --no-cache         # Rebuild (updates Claude Code)
cco build --claude-version x.y.z  # Pin Claude Code version
cco start <project>          # Start session for a project
cco new --repo <path>        # Start temporary session with repos
cco project create <name>    # Scaffold new project from template
cco project install <url>    # Install project template from Config Repo
cco project list             # List projects
cco pack install <url>       # Install packs from a remote Config Repo
cco pack update <name>       # Update a pack from its remote source
cco pack export <name>       # Export a pack as .tar.gz archive
cco manifest refresh         # Regenerate manifest.yml from packs/ and templates/
cco manifest validate        # Cross-check manifest.yml vs disk
cco remote add <n> <url>     # Register a Config Repo remote
cco remote add <n> <url> --token <t>  # Register with auth token
cco remote remove <name>     # Unregister a remote
cco remote list              # Show all registered remotes
cco remote set-token <n> <t> # Save auth token for a remote
cco remote remove-token <n>  # Remove saved token
cco pack publish <n> [remote] # Publish pack to a Config Repo
cco pack internalize <name>  # Convert source-referencing pack to self-contained
cco project publish <n> <r>  # Publish project template to Config Repo
cco project add-pack <p> <k> # Add a pack to a project
cco project remove-pack <p> <k> # Remove a pack from a project
cco vault init               # Initialize git-backed config versioning
cco vault sync [msg]         # Commit config changes with secret detection
cco vault diff               # Show uncommitted changes by category
cco vault log                # Show commit history
cco vault status             # Show vault state
cco stop [project]           # Stop session(s)
```
 
The CLI is a single bash script at `bin/cco` with no dependencies beyond bash (3.2+), docker, and standard Unix tools (jq, sed, awk). Compatible with macOS default `/bin/bash` — no Homebrew bash required.

## Architecture

### Four-Tier Context Hierarchy

The orchestrator maps onto Claude Code's native settings resolution:

| Orchestrator Layer | Container Path | Claude Code Scope | Overridable? |
|---|---|---|---|
| `defaults/managed/` | `/etc/claude-code/` | Managed (highest priority) | No — baked in image |
| `global/.claude/` | `~/.claude/` | User-level (always loaded) | Yes — user-owned |
| `projects/<name>/.claude/` | `/workspace/.claude/` | Project-level (always loaded) | Yes — per-project |
| Repo's own `.claude/` | `/workspace/<repo>/.claude/` | Nested (on-demand) | Yes — from repo |

Managed settings (hooks, env vars, deny rules) have the highest priority and cannot be overridden. User and project settings are fully customizable.

### Docker-from-Docker

The host's Docker socket is mounted into the container. Claude can run `docker compose up` to create **sibling containers** on the host daemon — not nested containers. All sibling containers share a project-scoped network (`cc-<project-name>`).

### Session Startup Flow

`cco start` → read `project.yml` → validate repo paths → generate `docker-compose.yml` → `docker compose run --rm --service-ports claude` → entrypoint handles socket perms + tmux → `claude --dangerously-skip-permissions`

### Key Design Decisions

- **Leverage native Claude Code behavior**: The fundamental rule of claude-orchestrator is to leverage Claude Code's native features as much as possible, avoiding custom reimplementations. The orchestrator maps its configuration tiers directly onto Claude Code's native settings resolution (managed → user → project → nested). Reference: `.claude/docs/claude-code/llms.txt` contains the full Claude Code documentation index.
- **Docker IS the sandbox**: no native Claude Code sandboxing. `--dangerously-skip-permissions` is safe inside the container.
- **Flat workspace layout**: WORKDIR is `/workspace`, each repo is a direct subdirectory. No `--add-dir` needed.
- **Auto memory isolation**: each project's `claude-state/` dir is mounted to `~/.claude/projects/-workspace` so projects don't share memory or session transcripts.
- **Agent teams**: tmux by default (works everywhere), iTerm2 optional via `--teammate-mode auto`.
- **Auth**: OAuth (credentials seeded from macOS Keychain to `~/.claude/.credentials.json`) by default, API key via env var as alternative. GitHub auth via `GITHUB_TOKEN` + `gh` CLI.

## Implementation Order

Per `docs/maintainer/docker/design.md` (sezione directory structure):

1. **Docker**: `Dockerfile`, `config/entrypoint.sh`, `config/tmux.conf`, `config/hooks/`, `.dockerignore`
2. **Global Config**: managed files in `defaults/managed/` (baked in image), user defaults in `defaults/global/.claude/` (copied once on init)
3. **Project Template**: `defaults/_template/`
4. **CLI**: `bin/cco`
5. **Root Files**: `.gitignore`

## Key Files

**Implementation:**
- `bin/cco` — CLI entrypoint (dispatcher that sources `lib/*.sh` modules)
- `lib/cmd-pack.sh` — Pack management: create, install, update, export, list, show, remove, validate
- `lib/cmd-project.sh` — Project management: create, install, list, show, validate
- `lib/cmd-vault.sh` — Config versioning: init, sync, diff, log, status (git-backed)
- `lib/manifest.sh` — manifest.yml lifecycle: init, refresh, validate, show
- `lib/cmd-remote.sh` — Remote management: add, remove, list Config Repo remotes (.cco-remotes)
- `lib/remote.sh` — Remote clone helper: sparse-checkout, shallow fallback, token auth
- `Dockerfile` — Docker image (node:22-bookworm, Claude Code, gosu, tmux, docker CLI, cco-docker-proxy)
- `proxy/` — Go Docker socket proxy: filters API calls by container name/label, mount paths, security constraints
- `config/entrypoint.sh` — Container entrypoint: socket GID fix, Docker proxy startup, MCP merge, gosu, tmux/claude launch
- `config/tmux.conf` — tmux config for agent teams (colors, navigation, history)
- `config/hooks/session-context.sh` — SessionStart hook: injects repo list and MCP info into context
- `config/hooks/statusline.sh` — StatusLine hook: displays `[project] model | ctx XX% | $cost`
- `defaults/managed/` — Framework infrastructure: managed-settings.json (hooks, env, deny), CLAUDE.md (framework instructions), `.claude/skills/init-workspace/` (managed skill). Baked into Docker image at `/etc/claude-code/`.
- `defaults/global/.claude/` — User defaults: CLAUDE.md, settings.json, mcp.json, agents, skills, rules (copied once on init, user-owned)

**Documentation:**
- `docs/maintainer/spec.md` — requirements specification
- `docs/maintainer/architecture.md` — ADRs and system design
- `docs/maintainer/docker/design.md` — Dockerfile, compose template, networking
- `docs/reference/context-hierarchy.md` — context hierarchy, settings, auto memory, subagents
- `docs/reference/cli.md` — CLI commands and `project.yml` format
- `docs/user-guides/advanced/subagents.md` — analyst (haiku) and reviewer (sonnet) agent specs
- `docs/user-guides/agent-teams.md` — tmux vs iTerm2 setup
- `docs/user-guides/project-setup.md` — project setup guide, repos vs extra_mounts, writing CLAUDE.md

## Conventions

- `project.yml` is the source of truth for each project; `docker-compose.yml` is generated from it and should not be committed.
- `user-config/` is gitignored (user data). `defaults/` is tracked (tool code). Managed files are baked in the Docker image; global defaults are copied once on `cco init` and never overwritten.
- Generated files: `projects/*/docker-compose.yml`, `projects/*/memory/`, `.env`.
- Container user is `claude` (non-root), with docker group for socket access.
- Entrypoint must handle Docker socket GID mismatch between host and container.
- macOS Docker Desktop: never use `network_mode: host` (refers to Linux VM, not macOS). Always use port mappings.
- bash 3.2 compatibility: always guard empty arrays with `[[ ${#arr[@]} -gt 0 ]]` or `${arr[@]+"${arr[@]}"}` when `set -u` is active.

## Migrations

When a feature changes the structure of user-facing config files (`project.yml`, `global/.claude/*`), **a migration is required** so that `cco update` propagates the change to existing installations. The update system (`lib/update.sh`) only tracks files inside `.claude/` directories; root-level files like `project.yml` are not covered by the manifest.

**Rules:**
- New sections/fields in `project.yml` → create `migrations/project/NNN_description.sh`
- New sections/fields in global config → create `migrations/global/NNN_description.sh`
- Template changes (`defaults/_template/`, `defaults/global/`) only affect new projects/inits; existing ones need a migration
- Every migration must be **idempotent** (safe to run multiple times) and return 0 on success
- Migration files define `MIGRATION_ID=N` and `MIGRATION_DESC="..."`, plus a `migrate()` function receiving the target directory
- IDs must be sequential (check `migrations/{scope}/` for the current max)
- `cco update` runs pending migrations automatically when `schema_version < latest`

**Checklist for config changes:**
1. Update `defaults/_template/` (or `defaults/global/`) with the new structure
2. Create migration script in `migrations/{scope}/`
3. Test: `cco update --project <name>` applies the migration
4. Verify idempotency: running update again produces no changes
