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
- `~/.cache/cco` (CACHE) — re-fetchable content (llms downloads) and the generated `docker-compose.yml` overlay.
- `~/.local/share/cco` (DATA) — internal-but-synced state: per-user tags registry, de-tokenized remotes registry, install provenance.

**Framework state**: Framework-managed metadata lives in STATE/CACHE/DATA (hidden, never hand-edited), keyed by project identity — never written into the committed `<repo>/.cco/` or `~/.cco/` trees. User-editable files (`project.yml`, the `claude/` tree) stay in the repo. Path resolution is handled by `lib/paths.sh` helpers.

## Build & Run Commands

```bash
cco init                     # First-time setup: ensure ~/.cco, scaffold <repo>/.cco/, build image
cco init --migrate <project> # Migrate a legacy project into the in-repo layout
cco join <project>           # Add the current repo to <project> as a member (Journey E)
cco build                    # Build Docker image
cco build --no-cache         # Rebuild + reset Claude Code install cache (fresh install next start)
cco build --claude-version x.y.z  # One-off channel/version override (latest|stable|x.y.z) for this build
cco start <project>          # Start session for a project
cco start config-editor      # Launch the built-in config-editor session
cco new --repo <path>        # Start temporary session with repos
cco resolve <name>           # Resolve repos/mounts to local paths (clone-from-url) + fetch missing referenced llms
cco path set|list            # Advanced: low-level index override (see 'cco resolve --help')
cco sync                     # Copy/refresh resolved config into place
cco list                     # Unified index of all resources (grouped by kind, with tags)
cco list <kind>              # One kind: projects|packs|templates|llms|remotes
cco list [<kind>] --tag <t>  # Filter by a per-user tag (globally or within a kind)
cco tag add <name> <tag>     # Tag a project/pack/template (per-user, DATA registry)
cco tag remove <name> <tag>  # Remove a tag (alias: cco tag rm)
cco pack install <url>       # Install a pack from a sharing repo
cco pack publish <n> [remote] # Publish a pack to a sharing repo
cco pack export <name>       # Export a pack as a .tar.gz archive
cco pack import <archive>    # Import a pack from a .tar.gz archive
cco pack update <name>       # Update a pack from its source
cco template install <url>   # Install a template from a sharing repo
cco template publish <n> [remote] # Publish a template to a sharing repo
cco template update <name>   # Update a template from its source (--all for all)
cco template validate [name] # Validate a template's structure (--all for all)
cco template export <name>   # Export a template as an archive
cco template import <archive> # Import a template from an archive
cco template show <name>     # Show template details (list via 'cco list templates')
cco template remove <name>   # Remove a user template (previews + confirms; -y to skip)
cco project export <name>    # Export a project (projects share via their own code-repo remote)
cco project import <archive> # Import an exported project
cco project rename [<old>] <new> # Rename a project, re-keying its identity across stores
cco project show <name>      # Show project roles, referenced-by, repo-centric view
cco remote add <n> <url>     # Register a sharing-repo remote
cco remote add <n> <url> --token <t>  # Register with auth token
cco remote remove <name>     # Unregister a remote
cco list remotes             # Show all registered remotes
cco remote set-token <n> <t> # Save auth token for a remote
cco remote remove-token <n>  # Remove saved token
cco llms install <url>       # Install framework documentation (llms.txt)
cco list llms                # List installed llms entries
cco llms show <name>         # Show llms entry details
cco llms update [name]       # Re-download from source (--all for all)
cco llms rename <old> <new>  # Rename an llms entry (updates YAML refs)
cco llms remove <name>       # Remove an llms entry
cco config save [-m <msg>]   # Commit ~/.cco changes with secret detection
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
- **Session access (capability model, ADR-0036 + ADR-0042 + ADR-0043 + ADR-0044 + ADR-0046 + ADR-0047 + ADR-0048)**: each session resolves three orthogonal knobs — `claude_access` (`none|repo|all`, default `repo`) over the `.claude` authoring trees, `cco_access` (`none|read-project|read-global|read-all|edit-project|edit-global|edit-all`, default `read-project`; symmetric read scoping — ADR-0042; bare `read` is a back-compat alias for `read-all`) over the `.cco`/framework config, and `show_host_paths` (default on). Precedence: CLI (`--claude-access`/`--cco-access`/`--show-host-paths`) > `project.yml` `access:` block > `~/.cco/access.yml` > preset. `--enable-config-edit` is a deprecated alias for `--cco-access edit-project`. When `cco_access != none` (i.e. any read/edit level — now the normal default), a **whitelisted `cco` runs in-container** (container-operator mode, `bin/cco` `_cco_operator_shim`): read verbs are scope-gated (personal-global `template`/`remote list` need `read-global+`; `cco list`/`cco docs` at any read level), path-free write verbs at edit levels; session/image lifecycle + path-resolving + network/credential verbs (`config push`/`pull`, `remote *-token`) stay host-only. `usage()` is scope-aware in operator mode (host-only verbs flagged). Beyond verb-gating, read-verb **output** is scoped via `lib/access-scope.sh` (ADR-0043) on a model **symmetric with the write side** on `{project, global, all}`: each level reads at its matching scope (`_cco_level_read_scope`/`_cco_level_write_scope` are the single source). `read-project` **and** `edit-project` → *project* scope: only the current project + its referenced packs/llms are shown (the CONFIG mount is likewise narrowed to referenced packs), everything else hidden with a count-only "hidden by access scope" notice on stderr. `read-global`/`edit-global` → *global*: the whole store is visible but **other projects stay hidden** (the sole `global`-vs-`all` difference — `read-global ≠ read-all`). `read-all`/`edit-all` → *all*. The host is never scoped (INV-A). The write side is gated by target tree: `_op_write` refuses (exit 2) a write verb whose target tree exceeds the session's `write_scope` (`edit-project` can no longer run global-store writes). `cco start` exports `PROJECT_NAME` + `CCO_PROJECT_PACKS`/`CCO_PROJECT_LLMS` (membership signals) + `CCO_CLAUDE_ACCESS`/`CCO_SHOW_HOST_PATHS`/`CCO_CONFIG_TARGETS` (F4/D9). Session identity is the compose `cco.project` label (not the `run --rm`-discarded container name); the in-container resolver resolves the current project from `/workspace/project.yml`. `cco whoami` reports the session's own access state. At `cco_access=none` cco is refused wholesale in-session (exit 2, R6). In-container `cco help` is filtered to runnable verbs (`--help --host` for the full flagged list); refusal exit codes follow 0/2/1 (success-or-degrade / policy refusal / error). A baked managed rule `cco-config-interaction.md` carries config-editing safety at edit levels + the read-project project-scoped-view awareness. Real secret files (`secrets.env`/`*.env`/`*.key`/`*.pem`) are masked from every config mount (only `*.example` visible); tokens/transcripts/memory never mount. Built-ins are presets: config-editor = **min-privilege by mode** (ADR-0044 §3 → **ADR-0048** WS-A refinement): cwd-in-project or repeatable `--project <name>` → **`(ro,rw,none)`** (edit the target project's `<repo>/.cco` + its repos, **read** the store to reference it — the targets are the `current` axis via `_env_is_current_project`; `~/.cco` is mounted **ro**); bare outside a project → **`(rw,none,none)`** (edit `~/.cco` only, project-less — Pc honestly `none`); `--all` / `--cco-access edit-all` → `edit-all` (every resolvable project's `<repo>/.cco`, no repos); `--repo <name>` adds one repo. Writing `~/.cco` from project mode is the explicit `--cco-access edit-global` `(rw,rw,none)`. Two config-editor floors: **`G ≥ ro`** (authoring tool always sees the store — an explicit narrower `--cco-access` is clamped up to `ro` with a notice) and **`claude_access` follows `G`** (`all` iff `G=rw`, else `repo` — global `.cco/.claude` authoring writable only when the store is; closes the C2 asymmetry). The `cco-config` (`~/.cco`) mount readonly follows `G` from a single source (`_config_editor_default_cco`). tutorial = `none`/`read-all` (ADR-0044 §2 — read-only teacher gets the whole cco world, no write risk). Resolution + mount generation live in `lib/cmd-start.sh` (`_start_resolve_access`, `_start_generate_compose`); output scoping in `lib/access-scope.sh`; the resolver guard/caller-context in `lib/paths.sh`. **The CLI is now dual-context (host + in-container agent); every verb must be environment-aware** — see `docs/maintainers/cli/design/design-cli-environment-awareness.md`. Operator-bucket mounts nest under `$HOME` XDG base dirs (`.local/state`, `.cache`, ...) regardless of `cco_access` level — see `docs/maintainers/environment/design/design-docker.md` §1.2.2 for the container ownership invariant this requires (pre-created/chowned base dirs, or a sibling write elsewhere under that base breaks with `EACCES`). **Unified `(G,Pc,Po)` model + privilege boundary (shipped, ADR-0046 + ADR-0047; requires `cco build`):** `cco_access` is an explicit `(G,Pc,Po)` triple — three config trees (global `~/.cco`, current project, other projects), each `none|ro|rw`. The named levels are **presets** (sugar for the symmetric triples); a granular `--cco-access global=…,current=…,others=…` (or an `access.cco` map in `project.yml`) sets the axes directly, with unspecified axes auto-promoted to the invariant floor (`Pc` never `none` while enabled **and a current project is in scope** — the conditional INV-2 floor, ADR-0048; a project-less session may carry `Pc=none`; `Po ≤ Pc`) and invariant-violating triples rejected. `edit-global` is **redefined** `(rw,rw,none)` — it now also writes the current project (was global-only), which is what unlocks config-editor's project mode. Two intents are granular-only (edit every project but not the store `(none,rw,rw)`; edit the store while reading all projects `(rw,rw,ro)`). Enforcement is a real **privilege boundary** ([ADR-0047](docs/maintainers/configuration/agent-cco-access/decisions/0047-config-access-enforcement.md)): the internal store (STATE index, DATA, CACHE internals) lives under a `cco-svc`-owned mode-0700 parent the agent user can't traverse, reached only via a setuid helper that enforces the resolved `(G,Pc,Po)` from a trusted `:ro` session descriptor (never argv/env, fail-closed) — so a `read-project` agent `cat`-ing the index gets `EACCES`; `access-scope.sh` output-scoping is demoted to defense-in-depth. Resolver + ladder in [ADR-0046](docs/maintainers/configuration/agent-cco-access/decisions/0046-unified-cco-access-model.md).

## Implementation Order

Per `docs/maintainers/environment/design/design-docker.md` (sezione directory structure):

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
- `lib/access-scope.sh` — Unified CLI environment & access-scope layer (ADR-0043): scopes read-verb OUTPUT in container-operator mode (`_env_in_scope`/`_env_note_hidden`/`_env_flush_hidden_notice`/`_env_require_visible`). Host-open; hidden ≠ absent (count-only stderr notice)
- `lib/cmd-config.sh` / `lib/cmd-sync.sh` — Personal-store versioning (`cco config save/push/pull` on `~/.cco`) and `cco sync` (copy resolved config into place)
- `lib/cmd-remote.sh` — Remote management: add, remove, list sharing-repo remotes
- `lib/remote.sh` — Remote clone helper: sparse-checkout, shallow fallback, token auth
- `Dockerfile` — Docker image (node:22-bookworm, gosu, tmux, docker CLI, cco-docker-proxy). Claude Code is NOT baked in — the entrypoint installs it natively at first start into a persistent CACHE mount that auto-updates in place (ADR-0039)
- `proxy/` — Go Docker socket proxy: filters API calls by container name/label, mount paths, security constraints
- `config/entrypoint.sh` — Container entrypoint: socket GID fix, Docker proxy startup, MCP merge, gosu, tmux/claude launch
- `config/tmux.conf` — tmux config for agent teams (colors, navigation, history)
- `config/hooks/session-context.sh` — SessionStart hook: injects repo list and MCP info into context
- `config/hooks/prompt-submit.sh` — UserPromptSubmit hook: per-prompt reminder to check rules, git status, existing docs
- `config/hooks/statusline.sh` — StatusLine hook: displays `[project] model | ctx XX% | $cost`
- `defaults/managed/` — Framework infrastructure: managed-settings.json (hooks, env, deny), CLAUDE.md (framework instructions), `.claude/rules/` (memory-policy, documentation-first), `.claude/skills/init-workspace/` (managed skill). Baked into Docker image at `/etc/claude-code/`.
- `defaults/global/.claude/` — User defaults: CLAUDE.md, settings.json, mcp.json, agents, skills, rules (copied once on init, user-owned)

**Documentation:**
- `docs/maintainers/foundation/analysis/spec.md` — requirements specification
- `docs/maintainers/foundation/design/architecture.md` — ADRs and system design
- `docs/maintainers/environment/design/design-docker.md` — Dockerfile, compose template, networking
- `docs/users/foundation/reference/context-hierarchy.md` — context hierarchy, settings, auto memory, subagents
- `docs/users/reference/cli.md` — CLI commands and `project.yml` format
- `docs/users/integration/guides/subagents.md` — analyst (haiku) and reviewer (sonnet) agent specs
- `docs/users/integration/guides/agent-teams.md` — tmux vs iTerm2 setup
- `docs/users/configuration/guides/project-setup.md` — project setup guide, repos vs extra_mounts, writing CLAUDE.md

## Conventions

- `<repo>/.cco/project.yml` is the source of truth for each project; `docker-compose.yml` is generated into CACHE and overlaid `:ro`, never committed.
- Project config lives in each repo at `<repo>/.cco/` (versioned with the repo). The personal store `~/.cco/` and the machine-local STATE/CACHE/DATA buckets hold user/internal data and are out-of-repo. `defaults/` is tracked (tool code). Managed files are baked in the Docker image; global defaults are copied once into `~/.cco/.claude/` on `cco init` and never overwritten.
- The generated `docker-compose.yml` goes to CACHE/STATE and is overlaid `:ro` — never written into the committed tree. The agent-facing **session-info surface is injected as the `CCO_SESSION_CONTEXT` env var** (base64), computed host-side by `lib/session-context.sh` and emitted by the SessionStart/SubagentStart hooks — **no file** (ADR-0042, retires the former `workspace.yml`/`packs.md`). It carries repos/packs/knowledge/llms/extra_mounts + an optional `path_map` (when `show_host_paths` is on) + the wrapped-cco access declaration. `<repo>/.cco/secrets.env` is gitignored; memory/transcripts live in STATE.
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
