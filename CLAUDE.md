# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

claude-orchestrator manages isolated Claude Code sessions in Docker containers for multi-project, multi-repo development. It provides a CLI (`bin/cco`) to launch preconfigured sessions with repos mounted, context loaded, and agent teams ready.

**Current status**: v1 implemented, plus Auth & Secrets, Environment Extensibility, Docker Socket Toggle, Scope Hierarchy Refactor, sharing-repo distribution, Docker Socket Security (Go proxy with policy-based filtering), and the decentralized in-repo config model. Dockerfile, CLI, global config, project template, and all docs are in place.

**Config separation**: Three-tier managed scope hierarchy leveraging Claude Code's native resolution:
- `defaults/managed/` → baked into Docker image at `/etc/claude-code/` (Managed level — hooks, env, deny rules, framework instructions). Non-overridable.
- `defaults/global/.claude/` → copied once to `~/.cco/.claude/` on `cco init` (User level — agents, skills, rules, settings, preferences). User-owned, never overwritten.
- `templates/` → native templates for projects (`templates/project/base/`) and packs (`templates/pack/base/`). User templates in `~/.cco/templates/` take priority.
- `internal/` → framework-internal resources used directly at runtime (e.g., `internal/tutorial/`, `internal/config-editor/`). Not installed into the user's store.

**Config homes**: project config lives **in each repo**; everything personal lives in the **`~/.cco` store**; machine-local index/state/cache live in hidden XDG buckets (never hand-edited):
- `<repo>/.cco/` — per-project config committed inside the repo it serves: `project.yml` (logical names + machine-agnostic `url`/`ref` coordinates), its `claude/` tree, and `secrets.env` (gitignored).
- `~/.cco/` — the personal store: `.claude/` (global Claude config), `packs/` (knowledge packs), `templates/` (project templates). **No `manifest.yml`** — sharing discovery is structure-based.
- `~/.local/state/cco` (STATE) — machine-local index (logical name → absolute path), session transcripts, memory, update base/meta.
- `~/.cache/cco` (CACHE) — re-fetchable content (llms downloads) and generated overlays (`packs.md`, `workspace.yml`, `docker-compose.yml`).
- `~/.local/share/cco` (DATA) — internal-but-synced state: per-user tags registry, de-tokenized remotes registry, install provenance.

**Framework state**: Framework-managed metadata lives in STATE/CACHE/DATA (hidden, never hand-edited), keyed by project identity — never written into the committed `<repo>/.cco/` or `~/.cco/` trees. User-editable files (`project.yml`, the `claude/` tree) stay in the repo. Path resolution is handled by `lib/paths.sh` helpers.

## Build & Run Commands

```bash
cco init                     # First-time setup: ensure ~/.cco, scaffold <repo>/.cco/, build image
cco init --migrate <project> # Migrate a legacy project into the in-repo layout
cco join <project>           # Join a project whose <repo>/.cco/ already exists
cco build                    # Build Docker image
cco build --no-cache         # Rebuild (updates Claude Code)
cco build --claude-version x.y.z  # Pin Claude Code version
cco start <project>          # Start session for a project
cco start config-editor      # Launch the built-in config-editor session
cco new --repo <path>        # Start temporary session with repos
cco resolve <name>           # Resolve a logical name to an absolute path (clone-from-url if needed)
cco path <name>              # Print the resolved absolute path for a logical name
cco sync                     # Copy/refresh resolved config into place
cco list                     # List projects
cco list --tag <tag>         # List projects filtered by a per-user tag
cco tag add <project> <tag>  # Tag a project (per-user, in the DATA registry)
cco tag rm <project> <tag>   # Remove a tag from a project
cco pack install <url>       # Install a pack from a sharing repo
cco pack publish <n> [remote] # Publish a pack to a sharing repo
cco pack export <name>       # Export a pack as a .tar.gz archive
cco pack import <archive>    # Import a pack from a .tar.gz archive
cco pack update <name>       # Update a pack from its source
cco template install <url>   # Install a template from a sharing repo
cco template publish <n> [remote] # Publish a template to a sharing repo
cco template export <name>   # Export a template as an archive
cco template import <archive> # Import a template from an archive
cco template list            # List available templates (native + user)
cco template show <name>     # Show template details
cco template remove <name>   # Remove a user template
cco project export <name>    # Export a project (projects share via their own code-repo remote)
cco project import <archive> # Import an exported project
cco project show <name>      # Show project roles, referenced-by, repo-centric view
cco remote add <n> <url>     # Register a sharing-repo remote
cco remote add <n> <url> --token <t>  # Register with auth token
cco remote remove <name>     # Unregister a remote
cco remote list              # Show all registered remotes
cco remote set-token <n> <t> # Save auth token for a remote
cco remote remove-token <n>  # Remove saved token
cco llms install <url>       # Install framework documentation (llms.txt)
cco llms list                # List installed llms entries
cco llms show <name>         # Show llms entry details
cco llms update [name]       # Re-download from source (--all for all)
cco llms rename <old> <new>  # Rename an llms entry (updates YAML refs)
cco llms remove <name>       # Remove an llms entry
cco config save [msg] [--yes] # Commit ~/.cco changes with secret detection
cco config push              # Push ~/.cco to its remote (multi-PC sync)
cco config pull              # Pull ~/.cco from its remote
cco update                   # Migrations + discovery (framework + remote) + changelog
cco update --diff [scope]    # Summary (no scope) or full diffs (scoped)
cco update --diff --all      # Full diffs for all scopes
cco update --sync [scope]    # Interactively sync config from framework defaults
cco update --news            # Show new features and examples
cco update --offline         # Skip remote source checks
cco update --no-cache        # Force fresh remote version check
cco update --dry-run         # Preview pending migrations without running
cco clean                    # Remove .bak files from update
cco clean --tmp              # Remove .tmp/ dirs (dry-run artifacts)
cco clean --generated        # Remove generated compose/overlay artifacts
cco clean --all              # All cleanup categories (bak + tmp + generated)
cco stop [project]           # Stop session(s)
```

> Project config lives in each repo at `<repo>/.cco/` and is versioned with the repo's normal git — there is no `cco vault`. `cco config save/push/pull` versions and syncs only the personal store `~/.cco`.
 
The CLI is a single bash script at `bin/cco` with no dependencies beyond bash (3.2+), docker, and standard Unix tools (jq, sed, awk). Compatible with macOS default `/bin/bash` — no Homebrew bash required.

## Architecture

### Four-Tier Context Hierarchy

The orchestrator maps onto Claude Code's native settings resolution:

| Orchestrator Layer | Host Source | Container Path | Claude Code Scope | Overridable? |
|---|---|---|---|---|
| `defaults/managed/` | baked in image | `/etc/claude-code/` | Managed (highest priority) | No — baked in image |
| Global `.claude/` | `~/.cco/.claude/` | `~/.claude/` | User-level (always loaded) | Yes — user-owned |
| Project `.claude/` | `<repo>/.cco/claude/` | `/workspace/.claude/` | Project-level (always loaded) | Yes — per-project |
| Repo's own `.claude/` | `<repo>/.claude/` | `/workspace/<repo>/.claude/` | Nested (on-demand) | Yes — from repo |

The four `.claude` scopes differ by **reach** (ADR-0024): a repo's native `<repo>/.claude/` is cross-cutting (every project that mounts the repo, plus native Claude); the invoking repo's `<repo>/.cco/claude/` applies to **this** project across its repos with no cross-project leak; `~/.cco/.claude/` applies to all my projects; managed (`/etc/claude-code/`) sits on top. Managed settings (hooks, env vars, deny rules) have the highest priority and cannot be overridden. User and project settings are fully customizable.

### Docker-from-Docker

The host's Docker socket is mounted into the container. Claude can run `docker compose up` to create **sibling containers** on the host daemon — not nested containers. All sibling containers share a project-scoped network (`cc-<project-name>`).

### Session Startup Flow

`cco start` → read `project.yml` → validate repo paths → generate `docker-compose.yml` → `docker compose run --rm --service-ports claude` → entrypoint handles socket perms + tmux → `claude --dangerously-skip-permissions`

### Key Design Decisions

- **Leverage native Claude Code behavior**: The fundamental rule of claude-orchestrator is to leverage Claude Code's native features as much as possible, avoiding custom reimplementations. The orchestrator maps its configuration tiers directly onto Claude Code's native settings resolution (managed → user → project → nested). Reference: `.claude/docs/claude-code/llms.txt` contains the full Claude Code documentation index.
- **Docker IS the sandbox**: no native Claude Code sandboxing. `--dangerously-skip-permissions` is safe inside the container.
- **Flat workspace layout**: WORKDIR is `/workspace`, each repo is a direct subdirectory. No `--add-dir` needed.
- **Auto memory isolation**: each project's session transcripts and memory live in machine-local STATE (`<state>/cco/projects/<id>/`), mounted to `~/.claude/projects/-workspace` (transcripts) with `memory/` as a child mount at `~/.claude/projects/-workspace/memory`. Both are machine-local: transcripts and memory are **not synced** across machines in v1 (cross-PC memory sync is a future opt-in).
- **Agent teams**: tmux by default (works everywhere), iTerm2 optional via `--teammate-mode auto`.
- **Auth**: OAuth (credentials seeded from macOS Keychain to `~/.claude/.credentials.json`) by default, API key via env var as alternative. GitHub auth via `GITHUB_TOKEN` + `gh` CLI.

## Implementation Order

Per `docs/maintainer/integration/docker/design.md` (sezione directory structure):

1. **Docker**: `Dockerfile`, `config/entrypoint.sh`, `config/tmux.conf`, `config/hooks/`, `.dockerignore`
2. **Global Config**: managed files in `defaults/managed/` (baked in image), user defaults in `defaults/global/.claude/` (copied once on init)
3. **Project Template**: `templates/project/base/`
4. **CLI**: `bin/cco`
5. **Root Files**: `.gitignore`

## Key Files

**Implementation:**
- `bin/cco` — CLI entrypoint (dispatcher that sources `lib/*.sh` modules)
- `lib/cmd-pack.sh` — Pack management: create, install, update, export, list, show, remove, validate
- `lib/cmd-project-*.sh` — Project management split by subcommand: query (list/show), export/import, pack-ops, init/join (entry verbs)
- `lib/cmd-start.sh` — Session startup: decomposed into internal helpers (_start_resolve_project, _start_load_config, _start_generate_compose, etc.)
- `lib/cmd-template.sh` — Template management: list, show, create, remove + `_resolve_template()` and `_resolve_template_vars()`
- `lib/cmd-update.sh` — Update command: migrations + discovery, --diff, --sync
- `lib/cmd-clean.sh` — Clean .bak files: --project, --all, --tmp, --generated, --dry-run
- `lib/update*.sh` — Update engine split by responsibility: hash-io, merge, meta, discovery, sync, changelog, remote + orchestrator (update.sh)
- `lib/paths.sh` / index resolution — Maps logical names to absolute paths via the machine-local STATE index (subsumes the removed `@local` markers and per-repo `local-paths.yml`)
- `lib/cmd-config.sh` / `lib/cmd-sync.sh` — Personal-store versioning (`cco config save/push/pull` on `~/.cco`) and `cco sync` (copy resolved config into place)
- `lib/cmd-remote.sh` — Remote management: add, remove, list sharing-repo remotes
- `lib/remote.sh` — Remote clone helper: sparse-checkout, shallow fallback, token auth
- `Dockerfile` — Docker image (node:22-bookworm, Claude Code, gosu, tmux, docker CLI, cco-docker-proxy)
- `proxy/` — Go Docker socket proxy: filters API calls by container name/label, mount paths, security constraints
- `config/entrypoint.sh` — Container entrypoint: socket GID fix, Docker proxy startup, MCP merge, gosu, tmux/claude launch
- `config/tmux.conf` — tmux config for agent teams (colors, navigation, history)
- `config/hooks/session-context.sh` — SessionStart hook: injects repo list and MCP info into context
- `config/hooks/prompt-submit.sh` — UserPromptSubmit hook: per-prompt reminder to check rules, git status, existing docs
- `config/hooks/statusline.sh` — StatusLine hook: displays `[project] model | ctx XX% | $cost`
- `defaults/managed/` — Framework infrastructure: managed-settings.json (hooks, env, deny), CLAUDE.md (framework instructions), `.claude/rules/` (memory-policy, documentation-first), `.claude/skills/init-workspace/` (managed skill). Baked into Docker image at `/etc/claude-code/`.
- `defaults/global/.claude/` — User defaults: CLAUDE.md, settings.json, mcp.json, agents, skills, rules (copied once on init, user-owned)

**Documentation:**
- `docs/maintainer/architecture/spec.md` — requirements specification
- `docs/maintainer/architecture/architecture.md` — ADRs and system design
- `docs/maintainer/integration/docker/design.md` — Dockerfile, compose template, networking
- `docs/reference/context-hierarchy.md` — context hierarchy, settings, auto memory, subagents
- `docs/reference/cli.md` — CLI commands and `project.yml` format
- `docs/user-guides/advanced/subagents.md` — analyst (haiku) and reviewer (sonnet) agent specs
- `docs/user-guides/agent-teams.md` — tmux vs iTerm2 setup
- `docs/user-guides/project-setup.md` — project setup guide, repos vs extra_mounts, writing CLAUDE.md

## Conventions

- `<repo>/.cco/project.yml` is the source of truth for each project; `docker-compose.yml` is generated into CACHE and overlaid `:ro`, never committed.
- Project config lives in each repo at `<repo>/.cco/` (versioned with the repo). The personal store `~/.cco/` and the machine-local STATE/CACHE/DATA buckets hold user/internal data and are out-of-repo. `defaults/` is tracked (tool code). Managed files are baked in the Docker image; global defaults are copied once into `~/.cco/.claude/` on `cco init` and never overwritten.
- Generated files (`docker-compose.yml`, `packs.md`, `workspace.yml`) go to CACHE/STATE and are overlaid `:ro` — never written into the committed tree. `<repo>/.cco/secrets.env` is gitignored; memory/transcripts live in STATE.
- Container user is `claude` (non-root), with docker group for socket access.
- Entrypoint must handle Docker socket GID mismatch between host and container.
- macOS Docker Desktop: never use `network_mode: host` (refers to Linux VM, not macOS). Always use port mappings.
- bash 3.2 compatibility: always guard empty arrays with `[[ ${#arr[@]} -gt 0 ]]` or `${arr[@]+"${arr[@]}"}` when `set -u` is active.

## Update System & Migrations

The update system has three categories of changes:
- **Additive**: New optional config fields → add code-level defaults. Notified via `changelog.yml`.
- **Opinionated**: Improvements to framework rules/agents/skills → discovered by `cco update`, applied via `--sync`.
- **Breaking**: Structural changes, renames, schema incompatibilities → explicit migration scripts.

Migration scopes: `global`, `project`, `pack`, `template`. All run automatically by `cco update`.

**`project.yml` is user-owned**: New optional sections are additive (code handles missing fields with defaults). Schema-breaking changes use migrations. `cco update` does not track or merge `project.yml`.

**All installed files are user-owned** after `cco init`/`cco join`. The framework provides defaults at creation time and offers discovery + on-demand merge tools, but never modifies user files automatically.

**Rules:**
- New optional config field → add default in code; update `templates/project/base/project.yml` for new projects
- Renamed/moved keys in `project.yml` → create `migrations/project/NNN_description.sh`
- New sections/fields in global config (breaking) → create `migrations/global/NNN_description.sh`
- Improvements to opinionated files → update `defaults/global/`; `cco update` discovers them
- Native template-specific files (tutorial skills/rules) → discoverable via `.cco/source`
- User template-specific files → not auto-updated by `cco update`; refresh a
  template from its recorded source on demand with `cco template update <name>`
- Every migration must be **idempotent** (safe to run multiple times) and return 0 on success
- Migration files define `MIGRATION_ID=N` and `MIGRATION_DESC="..."`, plus a `migrate()` function receiving the target directory
- IDs must be sequential (check `migrations/{scope}/` for the current max)
- `cco update` runs pending migrations automatically when `schema_version < latest`

**`changelog.yml`** (repo root): tracks additive changes for user notification. Each entry has `id` (sequential integer), `date`, `type: additive`, `title`, and `description`. Users see new entries via `cco update` (summary) or `cco update --news` (details). Tracking: `last_seen_changelog` and `last_read_changelog` in global `.cco/meta`. Discovery updates `last_seen` only; `--news` updates both.

**Checklist for config changes:**
1. Classify the change: additive, opinionated, or breaking
2. Additive: add code-level default + update base template + append entry to `changelog.yml`
3. Opinionated: update `defaults/global/`; users discover via `cco update --diff`, apply via `--sync`
4. Breaking: create migration in `migrations/{scope}/`, update base template AND non-base native templates
5. If migration moves an opinionated file: also update `.cco/base/` in the migration
6. Test: `cco update --project <name>` runs migrations; verify idempotency
7. Non-base native templates: update directly in `templates/project/<name>/`, create migration for existing users
8. Policy change in `*_FILE_POLICIES`: transitions between `tracked`/`untracked`/`generated` are handled automatically by the update engine (no migration needed). But adding a NEW file to the policy list or renaming/moving a file still requires a migration.
