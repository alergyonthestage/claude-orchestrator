# Architecture & Design

> Version: 1.0.0
> Status: v1.0 — Current
> Related: [spec.md](./spec.md) | [docker.md](./docker/design.md) | [context.md](../reference/context-hierarchy.md)

---

## 1. System Overview

```
┌──────────────────────────────────────────────────────────────────────┐
│                        HOST (macOS + Docker Desktop)                  │
│                                                                      │
│   claude-orchestrator/           ~/projects/                         │
│   ├── bin/cco (CLI)              ├── backend-api/                    │
│   ├── defaults/                  │   └── .claude/  (repo context)    │
│   │   ├── global/.claude/        ├── frontend-app/                   │
│   │   └── _template/             │   └── .claude/                    │
│   ├── user-config/                └── shared-libs/                    │
│   │   ├── global/.claude/ (user)                                     │
│   │   └── projects/                                                  │
│   │       └── my-saas/                                               │
│   │           ├── project.yml                                        │
│   │           └── .claude/                                           │
│   └── Dockerfile                                                     │
│                                                                      │
│   Docker Socket (/var/run/docker.sock)                               │
│         │                                                            │
│         ▼                                                            │
│   ┌────────────────────────────────────────────────────────────┐     │
│   │               Claude Code Container                         │     │
│   │                                                             │     │
│   │   ~/.claude/           ← user-config/global/.claude/ (user)  │     │
│   │   /workspace/          ← WORKDIR                            │     │
│   │   ├── .claude/         ← project/.claude (mount)            │     │
│   │   ├── backend-api/     ← ~/projects/backend-api (mount)     │     │
│   │   ├── frontend-app/    ← ~/projects/frontend-app (mount)    │     │
│   │   └── shared-libs/     ← ~/projects/shared-libs (mount)     │     │
│   │                                                             │     │
│   │   /var/run/docker.sock ← host socket (mount)                │     │
│   │                                                             │     │
│   │   $ claude --dangerously-skip-permissions                   │     │
│   │                                                             │     │
│   │   Can run:                                                  │     │
│   │   - npm run dev (ports exposed to host)                     │     │
│   │   - docker compose up (creates sibling containers)          │     │
│   │   - git commit/push (via gh credential helper)               │     │
│   └──────────────┬─────────────────────────────────────────────┘     │
│                  │ docker compose up                                  │
│                  ▼                                                    │
│   ┌──────────────────────────────────────────┐                       │
│   │        Sibling Containers                 │                       │
│   │  (created by Claude via Docker socket)    │                       │
│   │                                           │                       │
│   │  ┌─────────┐ ┌───────┐ ┌───────────┐    │                       │
│   │  │ postgres │ │ redis │ │ nginx/app │    │                       │
│   │  │ :5432   │ │ :6379 │ │ :80/:443  │    │                       │
│   │  └─────────┘ └───────┘ └───────────┘    │                       │
│   └──────────────────────────────────────────┘                       │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 2. Key Architecture Decisions

### ADR-1: Docker as the Only Sandbox

**Context**: Claude Code offers native sandboxing (Seatbelt on macOS, bubblewrap on Linux). We need to decide whether to layer it with Docker.

**Decision**: Use Docker as the sole isolation mechanism. Disable native sandboxing.

**Rationale**:
- Docker provides filesystem and network isolation by design
- `--dangerously-skip-permissions` is safe within a container — the blast radius is the container
- Native sandboxing inside Docker requires `enableWeakerNestedSandbox`, which the docs explicitly state "considerably weakens security"
- No advantage in combining both; Docker alone is more secure than weakened native sandbox
- Git feature branches provide an additional safety net — any damage is reversible

**Consequences**:
- Container must NOT be run with `--privileged`
- Docker socket mount is the only intentional privilege escalation (see ADR-4)

---

### ADR-2: Workspace Layout — Flat Subdirectories

**Context**: Claude Code has one working directory. Multi-repo projects need a strategy.

**Decision**: WORKDIR = `/workspace`. Each repo is mounted as a direct subdirectory.

```
/workspace/              ← cwd, project-level .claude/ lives here
├── repo-alpha/          ← volume mount of real repo
│   └── .claude/         ← repo's own context (included in mount)
└── repo-beta/
    └── .claude/
```

**Rationale**:
- Claude Code discovers CLAUDE.md files recursively in subtrees — nested `.claude/` directories are loaded on-demand when Claude reads files there
- No `--add-dir` needed, no `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD` needed
- Clean hierarchy: `/workspace/.claude/CLAUDE.md` is project-level, subdirectories are repo-level
- Matches Claude Code's natural resolution order

**Consequences**:
- All repos appear as subdirectories of `/workspace`
- The project CLAUDE.md at `/workspace/.claude/CLAUDE.md` is the primary instruction file
- Repo CLAUDE.md files activate only when Claude reads files in that repo's directory

---

### ADR-3: Four-Tier Context Hierarchy (Updated — Managed Scope)

**Context**: Claude Code has a fixed precedence for settings and memory. We need to map our config to it. Claude Code's Managed level (`/etc/claude-code/`) provides non-overridable configuration.

**Decision**: Map orchestrator config to Claude Code's full native hierarchy:

| Orchestrator Layer | Container Path | Claude Code Scope | Loaded | Overridable? |
|---|---|---|---|---|
| `defaults/managed/` | `/etc/claude-code/` | Managed | Always at launch | No |
| `user-config/global/.claude/` | `~/.claude/` | User-level | Always at launch | Yes |
| `user-config/projects/<n>/.claude/` | `/workspace/.claude/` | Project-level | Always at launch | Yes |
| (repo's own `.claude/`) | `/workspace/<repo>/.claude/` | Nested | On-demand | Yes |

**Rationale**:
- Exact match with Claude Code's resolution order: managed → user → project → nested
- Managed level guarantees framework hooks and settings are always active
- Settings precedence works correctly: managed > user; project overrides user
- No hacks, symlinks, or custom scripts needed

**Consequences**:
- Framework infrastructure (hooks, env, deny rules) is in managed — always active, non-overridable
- User preferences (agents, skills, rules, settings) are in user level — fully customizable
- Repo-level `.claude/` files stay in the actual repos (not duplicated in orchestrator)
- The `user-config/global/.claude/` directory must NOT contain project-specific data

---

### ADR-4: Docker-from-Docker via Socket Mount

**Context**: Claude needs to run `docker compose up` for microservices and run dev servers with accessible ports.

**Decision**: Mount the host's Docker socket into the Claude container. This is "Docker-from-Docker" (DfD), NOT Docker-in-Docker (DinD).

```yaml
volumes:
  - /var/run/docker.sock:/var/run/docker.sock
```

**How it works**:
1. Docker CLI inside the Claude container sends commands to the HOST Docker daemon
2. `docker compose up` creates **sibling containers** on the host (not nested)
3. Sibling containers share the host's Docker network
4. Port mappings on sibling containers are accessible from macOS via `localhost:<port>`

**For dev servers inside the Claude container** (e.g., `npm run dev`):
- Use docker-compose port mapping: `ports: ["3000:3000"]`
- The dev server binds to `0.0.0.0:3000` inside the container
- Docker Desktop for Mac routes `localhost:3000` on macOS to the container

**For sibling containers** (postgres, redis, etc.):
- Created via `docker compose up` from within Claude container
- Use a shared Docker network so Claude container can reach them
- Port mappings make them accessible from macOS too

**Rationale**:
- DfD is simpler and more performant than DinD
- No `--privileged` flag needed (just socket access)
- Single Docker daemon = no image duplication, shared cache
- Standard pattern used by CI/CD tools (Jenkins, GitLab Runner)

**Risks**:
- Docker socket = root-equivalent access to host Docker daemon
- Acceptable for single-developer workstation
- Claude container could theoretically manipulate other containers on the host
- Mitigated by: developer oversight, feature branches, session isolation

**Consequences**:
- Docker CLI and docker-compose must be installed in the image
- Container user needs permission to access the socket (group `docker` or socket permissions)
- Shared Docker networks need consistent naming to avoid conflicts between projects

---

### ADR-5: Authentication Strategy

**Decision**: Support multiple auth mechanisms, layered per project.

| Method | Mechanism | Use Case |
|--------|-----------|----------|
| OAuth (default) | Credentials seeded from macOS Keychain to `global/claude-state/.credentials.json` | Pro/Team/Enterprise subscriptions |
| API Key | `ANTHROPIC_API_KEY` env var | Direct API access, CI/CD |
| GitHub auth | `GITHUB_TOKEN` env var → `gh auth login --with-token` + `gh auth setup-git` | git push (HTTPS), `gh pr create`, MCP GitHub server |
| Per-project secrets | `secrets.env` at global and project level, loaded as runtime `-e` flags | Service tokens (never written to docker-compose.yml) |

**Implementation**:
- **OAuth**: On macOS, the CLI extracts credentials from macOS Keychain (`Claude Code-credentials`) and seeds them to `user-config/global/claude-state/.credentials.json`. Inside the container, Claude Code reads from `~/.claude/.credentials.json` (the Linux plaintext location). The `~/.claude.json` file (mounted from `global/claude-state/claude.json`) stores preferences and MCP servers — NOT auth tokens.
- **API Key**: `ANTHROPIC_API_KEY` env var passed to container via `--env` or `.env` file.
- **GitHub**: `GITHUB_TOKEN` env var triggers `gh auth login --with-token` + `gh auth setup-git` in the entrypoint. This enables git push (HTTPS), `gh pr create`, and MCP GitHub server — all with a single token.
- **Secrets**: `secrets.env` at both global and project level, loaded as runtime `-e` flags (never written to `docker-compose.yml`).

**Why not just mount `~/.claude.json` read-write?**
The current model uses a shared writable `user-config/global/claude-state/claude.json` that is synced from host when host has more recent data (by comparing `numStartups`). This avoids race conditions from concurrent writes by host and container Claude Code instances (which previously caused JSON corruption — "control characters are not allowed" errors). The `claude.json` file stores only preferences and MCP server config; OAuth credentials are handled separately via `.credentials.json`.

---

### ADR-6: Claude State Isolation and Persistence

**Context**: Claude Code stores auto memory and session transcripts at `~/.claude/projects/<project>/`. Since we mount `user-config/global/.claude/` to `~/.claude/`, all projects would share the same state location. Additionally, the ephemeral container (`--rm`) loses all in-container data on exit, including session transcripts needed for `/resume`.

**Decision**: Each project gets a dedicated `claude-state/` directory, mounted to the full project state path. Memory lives inside it as `claude-state/memory/`.

```yaml
volumes:
  - ./claude-state:/home/claude/.claude/projects/-workspace
```

The identifier `-workspace` comes from Claude Code encoding the absolute working directory path by replacing each `/` with `-`. Since WORKDIR is `/workspace`, the encoded identifier is `-workspace`.

**Rationale**:
- Auto memory is useful and should not be disabled
- Project-specific insights should not leak across projects
- Session transcripts (needed for `/resume`) must survive container restarts and image rebuilds
- A single broad mount covers both memory and transcript storage

**Consequences**:
- Each project directory includes a `claude-state/` folder with `memory/` inside
- The mount target path depends on how Claude Code derives the project identifier
- Existing projects with a `memory/` dir are auto-migrated to `claude-state/memory/` on next `cco start`

---

### ADR-7: Display Mode for Agent Teams

**Decision**: Support both tmux and iTerm2 modes. User chooses via global settings or CLI flag.

**tmux mode** (recommended default):
- tmux is installed in the Docker image
- Agent teams create split panes inside the container's tmux session
- Works in ANY terminal emulator
- No host-side configuration needed

**iTerm2 mode**:
- Requires `it2` CLI installed on host
- Requires Python API enabled in iTerm2 settings
- Provides native iTerm2 panes (not inside tmux)
- More polished UX but more setup

**Configuration**:
```json
// user-config/global/.claude/settings.json
{
  "teammateMode": "tmux"   // or "auto" for iTerm2 detection
}
```

**CLI override**:
```bash
cco start my-project --teammate-mode tmux
cco start my-project --teammate-mode auto  # iTerm2 if available
```

---

## 3. Component Design

### 3.1 Docker Image

See [DOCKER.md](./docker/design.md) for full specification.

**Key aspects**:
- Base: `node:22-bookworm`
- Installs: Claude Code, git, tmux, docker CLI, docker-compose, dev tools
- Non-root user: `claude` (with docker group for socket access)
- Entrypoint: wrapper script that starts tmux (if configured) then launches Claude

### 3.2 CLI (`bin/cco`)

See [CLI.md](../reference/cli.md) for full specification.

**Key aspects**:
- Single bash script, no external dependencies
- Reads `project.yml`, generates docker-compose, runs container
- Supports: start, new, project create/list, build, stop

### 3.3 Context & Settings

See [CONTEXT.md](../reference/context-hierarchy.md) for full specification.

**Key aspects**:
- Three-tier hierarchy matching Claude Code native scopes
- Modular rules in `.claude/rules/` at each level
- Auto memory isolated per project

### 3.4 Subagents

See [SUBAGENTS.md](../user-guides/advanced/subagents.md) for full specification.

**Key aspects**:
- Two default subagents: analyst (haiku, read-only) and reviewer (sonnet, read-only)
- Defined in `user-config/global/.claude/agents/`
- Projects can add their own in `user-config/projects/<n>/.claude/agents/`
- Documentation for creating new subagents

---

## 4. Data Flow

### 4.1 Session Startup Flow

```
User runs: cco start my-saas
         │
         ▼
┌─────────────────────────┐
│  1. Read project.yml     │
│     - repos list         │
│     - auth method        │
│     - docker options     │
└────────┬────────────────┘
         │
         ▼
┌─────────────────────────┐
│  2. Validate repos       │
│     - Check paths exist  │
│     - Check git status   │
└────────┬────────────────┘
         │
         ▼
┌─────────────────────────┐
│  3. Generate compose     │
│     - Volume mounts      │
│     - Port mappings      │
│     - Environment vars   │
│     - Network config     │
└────────┬────────────────┘
         │
         ▼
┌─────────────────────────┐
│  4. docker compose run   │
│     --rm --service-ports │
│     claude               │
└────────┬────────────────┘
         │
         ▼
┌─────────────────────────┐
│  5. Entrypoint script    │
│     - Start tmux (opt.)  │
│     - Launch claude      │
│       --dangerously-     │
│       skip-permissions   │
└────────┬────────────────┘
         │
         ▼
┌─────────────────────────┐
│  6. Claude Code UI       │
│     - Loads ~/.claude/   │
│     - Loads /workspace/  │
│       .claude/           │
│     - User works         │
└─────────────────────────┘
```

### 4.2 Context Resolution at Launch

```
Claude Code startup in /workspace:
         │
         ├── Load /etc/claude-code/managed-settings.json     (managed — non-overridable)
         ├── Load /etc/claude-code/CLAUDE.md                 (managed instructions)
         │
         ├── Load ~/.claude/settings.json                    (user settings — merged with managed)
         ├── Load ~/.claude/CLAUDE.md                        (user instructions)
         ├── Load ~/.claude/rules/*.md                       (user rules)
         │
         ├── Load /workspace/.claude/settings.json           (project settings — overrides user)
         ├── Load /workspace/.claude/CLAUDE.md               (project instructions)
         │   OR /workspace/CLAUDE.md
         ├── Load /workspace/.claude/rules/*.md              (project rules)
         │
         │   [ON-DEMAND when Claude reads files in subdirs]
         ├── Load /workspace/repo-x/.claude/CLAUDE.md        (repo instructions)
         ├── Load /workspace/repo-x/.claude/rules/*.md       (repo rules)
         └── Load /workspace/repo-x/subdir/CLAUDE.md         (subdir instructions)
```

### 4.3 Network Flow: Dev Server

```
1. Claude runs: npm run dev (in container, port 3000)
2. Server binds to 0.0.0.0:3000 inside container
3. docker-compose port mapping: "3000:3000"
4. Docker Desktop routes localhost:3000 on macOS → container:3000
5. Developer opens browser → localhost:3000 ✓
```

### 4.4 Network Flow: Docker-from-Docker

```
1. Claude runs: docker compose -f infra/docker-compose.yml up
2. Docker CLI in container → host Docker daemon (via socket)
3. Host daemon creates postgres, redis, nginx containers
4. Shared network "project-net" connects all containers
5. Claude container reaches postgres via: postgres:5432 (docker DNS)
6. macOS reaches postgres via: localhost:5432 (port mapping)
```

---

## 5. Security Considerations

| Risk | Mitigation |
|------|------------|
| Docker socket = root on host Docker | Single-developer workstation; developer reviews all changes |
| `--dangerously-skip-permissions` | Container isolation limits blast radius |
| GitHub auth via `GITHUB_TOKEN` | Fine-grained PAT scoped per project; SSH keys not mounted by default |
| OAuth token in container | Read-only mount; container is ephemeral |
| Claude modifies repos | Feature branches; git provides full history and rollback |
| Sibling containers access | Shared Docker network is scoped per project |

---

### ADR-8: Tool vs User Config Separation (Updated — Managed Scope)

**Context**: `global/` and `projects/_template/` were tracked in git. When users customized their global settings or CLAUDE.md, they had a dirty git state and couldn't do `git pull` to update the tool without merge conflicts. The original `_sync_system_files()` mechanism always overwrote agents, skills, rules, and settings.json — preventing user customization.

**Decision**: Three-tier defaults leveraging Claude Code's native Managed level:
- `defaults/managed/` — framework infrastructure (hooks, env, deny rules, framework CLAUDE.md), baked into Docker image at `/etc/claude-code/` (Managed level — non-overridable)
- `defaults/global/` — user defaults (agents, skills, rules, settings.json, CLAUDE.md, mcp.json), copied once by `cco init` (User level — fully customizable)
- `defaults/_template/` — project template, scaffolded by `cco project create`
- `user-config/` — gitignored, owned by the user (contains `global/`, `projects/`, `packs/`, `templates/`)

**Mechanism**:
- `cco init` copies user defaults to `user-config/global/` on first setup; `--force` resets user defaults
- Managed files are baked into the Docker image via `COPY defaults/managed/ /etc/claude-code/` in the Dockerfile — updated only via `cco build`
- `_migrate_to_managed()` handles one-time migration from the old `_sync_system_files()` layout: removes `.system-manifest`, splits old unified settings.json into managed + user
- No more `_sync_system_files()` — agents, skills, rules, and settings are user-owned after initial copy

**Rationale**:
- `git pull` always works cleanly — no conflicts with user customizations
- Framework infrastructure (hooks, env vars) is guaranteed to be active via Claude Code's Managed level
- Users can freely customize agents, skills, rules, and settings without losing changes on restart
- Clear ownership: managed = framework (non-overridable), user = preferences (customizable)
- Multi-PC support: clone the tool repo on any machine, run `cco init`, done

**Consequences**:
- First-time setup requires `cco init` before `cco start`
- Managed settings updates require `cco build` (baked in image)
- User defaults (agents, skills, rules, settings, CLAUDE.md) are user-owned and never overwritten
- `cco init --force` resets user defaults to defaults/global/ templates
- Migration from old layout is automatic on first `cco init` after update

### ADR-9: Knowledge Packs — Copy vs Mount for Resources

**Context**: Knowledge Packs bundle documentation (knowledge), plus optional skills, agents, and rules for project-level tooling. The knowledge files are large documents meant to be read by Claude at runtime. Skills, agents, and rules are configuration files that Claude Code expects at specific paths inside `.claude/`.

**Decision**: Use two different strategies for the two resource types:
- **Knowledge files** → mounted read-only as Docker volumes at `/workspace/.packs/<name>/`
- **Skills, agents, rules** → copied into `projects/<name>/.claude/` at `cco start` time

**Rationale**:
- Docker volume mounts cannot merge multiple sources into one target directory. If two packs both define agents, they can't both mount to `.claude/agents/` — the second mount would shadow the first. Copying avoids this limitation entirely.
- Knowledge files are read-only reference material — mounting `:ro` is natural and prevents accidental writes.
- Skills/agents/rules need to live under `.claude/` where Claude Code discovers them. Copying into the project directory integrates seamlessly with the four-tier context hierarchy (ADR-3).
- A `.pack-manifest` file tracks which files were copied. On each `cco start`, stale files from the previous manifest are cleaned before fresh copies — preventing ghost resources when packs evolve.

**Consequences**:
- Copied files become stale if the pack changes between sessions. This is acceptable: `cco start` always refreshes copies. The manifest-based cleanup ensures removed resources don't persist.
- Name conflicts between packs (e.g., two packs defining `agents/reviewer.md`) result in last-wins overwrite. A warning is emitted to the user. Pack order in `project.yml` determines precedence.
- Pack content is injected into the session via `session-context.sh` hook, not via `@import` in CLAUDE.md. This keeps project CLAUDE.md clean and makes pack presence transparent to the user.

---

### ADR-10: Git Worktree Isolation

**Context**: Repos are bind-mounted directly from host to container. Host and container share the same git state. Concurrent git operations (user on host + Claude in container) can conflict. Users need the ability to work on a branch while Claude works on another.

**Decision**: Provide opt-in worktree isolation. When enabled (`--worktree` flag or `worktree: true` in project.yml), repos are mounted at `/git-repos/` (hidden from Claude) and the entrypoint creates worktrees at `/workspace/` on a dedicated branch (`cco/<project>`).

**Rationale**:
- Worktrees created inside the container have consistent paths — the `.git` file references `/git-repos/<repo>/.git/worktrees/...` which is valid inside the container
- Commits are stored in the host repo's object store (via bind mount) and survive container stop
- Claude sees `/workspace/<repo>` as a normal repo — zero behavior change
- Branch `cco/<project>` persists on host, enabling session resume
- Default behavior (no `--worktree`) is unchanged — zero risk for existing users
- Post-session cleanup runs in `cmd_start()` after `docker compose run` returns, eliminating the need for `cco stop`

**Consequences**:
- Worktree directory is ephemeral (lost on container stop), but commits persist
- `session-context.sh` must check for `.git` as file or directory (`[ -e ]` not `[ -d ]`)
- Docker-compose generation has two volume modes: direct mount (default) or `/git-repos/` mount (worktree)
- Multiple projects cannot use `--worktree` on the same repo simultaneously with the same branch

**Design doc**: [worktree-design.md](./future/worktree/design.md) | **Analysis**: [worktree-isolation.md](./future/worktree/analysis.md)

---

### ADR-11: External Service Authentication via Tokens

**Status: Implemented**

**Context**: Container sessions need to push to GitHub, create PRs, and interact with external services via MCP servers. SSH keys mounted from the host fail due to UID mismatch and `:ro` permissions. `gh` CLI is not installed. There's no standardized way to provide service tokens.

**Decision**: Use fine-grained GitHub PAT (`GITHUB_TOKEN`) as the primary auth mechanism. Install `gh` CLI in the Dockerfile. Configure git credential helper via `gh auth setup-git` in the entrypoint. Remove SSH key mount from the default compose template (opt-in via `docker.mount_ssh_keys`). Support per-project `secrets.env` that overrides global values.

**Rationale**:
- One token handles git push (HTTPS), `gh` CLI, and MCP GitHub — no separate auth per tool
- Fine-grained PATs can be scoped to specific repos and permissions (principle of least privilege)
- SSH keys grant access to ALL repos — over-permissive for agent use
- Per-project secrets enable different token scopes per project
- `secrets.env` values are passed as runtime `-e` flags — never written to `docker-compose.yml`

**Consequences**:
- Users must create a GitHub PAT and save it in `secrets.env`
- SSH-only remotes (non-GitHub) require explicit opt-in
- `gh` CLI adds ~50 MB to the Docker image
- Existing SSH key mount is removed from default — breaking change for users relying on it (but it was broken anyway)

**Design doc**: [auth-design.md](./auth/design.md) | **Analysis**: [authentication-and-secrets.md](./auth/analysis.md)

---

### ADR-12: Environment Extensibility

**Status: Implemented**

**Context**: The Docker image is built once and shared across all projects. Some projects need additional system packages, npm packages, or runtime configuration. The only extension mechanism is `--mcp-packages` for global npm packages. Users have no way to customize the environment per project without editing the Dockerfile.

**Decision**: Provide four complementary extension mechanisms:
1. `user-config/global/setup.sh` — executed during `cco build` for system-level packages (all projects)
2. `user-config/projects/<name>/setup.sh` — executed at container start for per-project runtime setup
3. `user-config/projects/<name>/mcp-packages.txt` — per-project npm MCP packages (runtime install)
4. `docker.image` in project.yml — use a completely custom Docker image per project

**Rationale**:
- Build-time setup (1) handles heavy dependencies without per-session startup cost
- Runtime setup (2, 3) enables per-project customization without image rebuild
- Custom image (4) gives full control for projects with complex needs
- All four are opt-in with no impact on default behavior

**Consequences**:
- `user-config/global/setup.sh` requires `cco build` after changes
- Runtime setup scripts (2, 3) increase container startup time proportionally to install size
- Custom images must be maintained by the user, but can extend the base image
- Template files are created by `cco init` and `cco project create`

**Design doc**: [environment-design.md](./environment/design.md) | **Analysis**: [environment-extensibility.md](./environment/analysis.md)

---

## 6. ADR: Managed Integrations — `.managed/` Convention

**Date**: 2026-03-03
**Status**: Accepted

**Context**: claude-orchestrator provides integrations that the framework controls
(Browser MCP, future: GitHub MCP, RAG). These integrations generate config files at
runtime and were previously mixed into the project root alongside user files
(`browser-mcp.json`, `.browser-port`). This created ambiguity about what is
user-owned vs framework-managed.

**Decision**: Framework-generated integration files are written to
`user-config/projects/<name>/.managed/` and mounted read-only at `/workspace/.managed/` in the
container. User files (`mcp.json`, `.claude/`, `project.yml`) remain at the project
root. The entrypoint merges all `*.json` files in `/workspace/.managed/` into
`~/.claude.json` via a generic loop — adding a new integration requires no entrypoint
change.

**Rationale**:
- Clear visual separation: everything in `.managed/` is framework-owned
- Users cannot accidentally edit managed config (`.managed/` is gitignored, mounted `:ro`)
- New integrations follow a documented 8-step protocol without modifying existing code
- The generic entrypoint loop means zero entrypoint changes per new integration

**Consequences**:
- `.managed/` is always gitignored (migration 003 adds it automatically)
- `cco stop <project>` cleans up files in `.managed/` (not the directory itself)
- `cco chrome` reads the effective port from `.managed/.browser-port`
- Conflict warning in entrypoint if a managed server key overrides a user-configured one

**See also**: [managed-integrations.md](./managed-integrations.md)

---

## 7. Limitations and Trade-offs

| Limitation | Impact | Workaround |
|------------|--------|------------|
| Docker Desktop Mac networking | No true `host` networking; port mapping required | Explicit port ranges in project config |
| Auto memory path derivation | Depends on Claude Code internal logic | May need testing; mount path may need adjustment |
| tmux inside Docker | No native clipboard integration with macOS | Use iTerm2 mode or manual copy |
| Container ephemeral by default | Session transcripts lost on container removal | `claude-state/` mount persists transcripts; `/resume` works across rebuilds |
| Single Docker daemon | All projects share the daemon | Use distinct network names per project |
