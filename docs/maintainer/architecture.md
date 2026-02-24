# Architecture & Design

> Version: 1.0.0
> Status: v1.0 — Current
> Related: [spec.md](./spec.md) | [docker.md](./docker.md) | [context.md](../reference/context.md)

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
│   ├── global/.claude/ (user)     └── shared-libs/                    │
│   ├── projects/ (user)                                               │
│   │   └── my-saas/                                                   │
│   │       ├── project.yml                                            │
│   │       └── .claude/                                               │
│   └── Dockerfile                                                     │
│                                                                      │
│   Docker Socket (/var/run/docker.sock)                               │
│         │                                                            │
│         ▼                                                            │
│   ┌────────────────────────────────────────────────────────────┐     │
│   │               Claude Code Container                         │     │
│   │                                                             │     │
│   │   ~/.claude/           ← global/.claude/ (user config)      │     │
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
│   │   - git commit/push (via mounted SSH keys)                  │     │
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

### ADR-3: Three-Tier Context Hierarchy

**Context**: Claude Code has a fixed precedence for settings and memory. We need to map our config to it.

**Decision**: Map orchestrator config to Claude Code's native hierarchy:

| Orchestrator Layer | Container Path | Claude Code Scope | Loaded |
|---|---|---|---|
| `global/.claude/` | `~/.claude/` | User-level | Always at launch |
| `projects/<n>/.claude/` | `/workspace/.claude/` | Project-level | Always at launch |
| (repo's own `.claude/`) | `/workspace/<repo>/.claude/` | Nested | On-demand |

**Rationale**:
- Exact match with Claude Code's resolution order: user → project → nested
- Settings precedence works correctly: project overrides global
- No hacks, symlinks, or custom scripts needed

**Consequences**:
- Global settings must use lower-precedence keys that projects can override
- Repo-level `.claude/` files stay in the actual repos (not duplicated in orchestrator)
- The `global/.claude/` directory must NOT contain project-specific data

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

**Decision**: Support two auth methods, configurable per project.

| Method | Mechanism | Use Case |
|--------|-----------|----------|
| OAuth (default) | Extract token from macOS Keychain, inject via `CLAUDE_CODE_OAUTH_TOKEN` env var | Pro/Team/Enterprise subscriptions |
| API Key | `ANTHROPIC_API_KEY` env var | Direct API access, CI/CD |

**Implementation**:
- CLI checks `project.yml` for `auth.method` (default: `oauth`)
- OAuth: CLI extracts the access token from macOS Keychain (`Claude Code-credentials`) at launch and passes it to the container via `CLAUDE_CODE_OAUTH_TOKEN`. The `~/.claude.json` file is mounted read-only as a seed (`.claude.json.seed`); the entrypoint copies it to a writable location for account metadata.
- API Key: passes env var to container via `--env` or `.env` file

**Why not just mount `~/.claude.json` read-write?**
Claude Code stores OAuth tokens in the macOS Keychain, not in `~/.claude.json` (which only contains account metadata). The container has no access to the host Keychain, so the CLI must extract and inject the token at runtime. Additionally, mounting the file read-write causes race conditions: both host and container Claude Code instances write to the file concurrently, leading to JSON corruption ("control characters are not allowed" errors). The seed-and-copy approach isolates each environment's writes.

---

### ADR-6: Claude State Isolation and Persistence

**Context**: Claude Code stores auto memory and session transcripts at `~/.claude/projects/<project>/`. Since we mount `global/.claude/` to `~/.claude/`, all projects would share the same state location. Additionally, the ephemeral container (`--rm`) loses all in-container data on exit, including session transcripts needed for `/resume`.

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
// global/.claude/settings.json
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

See [DOCKER.md](./docker.md) for full specification.

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

See [CONTEXT.md](../reference/context.md) for full specification.

**Key aspects**:
- Three-tier hierarchy matching Claude Code native scopes
- Modular rules in `.claude/rules/` at each level
- Auto memory isolated per project

### 3.4 Subagents

See [SUBAGENTS.md](../guides/subagents.md) for full specification.

**Key aspects**:
- Two default subagents: analyst (haiku, read-only) and reviewer (sonnet, read-only)
- Defined in `global/.claude/agents/`
- Projects can add their own in `projects/<n>/.claude/agents/`
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
         ├── Load ~/.claude/settings.json                    (global settings)
         ├── Load ~/.claude/CLAUDE.md                        (global instructions)
         ├── Load ~/.claude/rules/*.md                       (global rules)
         │
         ├── Load /workspace/.claude/settings.json           (project settings — overrides global)
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
| SSH keys mounted in container | Read-only mount; keys never leave host filesystem |
| OAuth token in container | Read-only mount; container is ephemeral |
| Claude modifies repos | Feature branches; git provides full history and rollback |
| Sibling containers access | Shared Docker network is scoped per project |

---

### ADR-8: Tool vs User Config Separation

**Context**: `global/` and `projects/_template/` were tracked in git. When users customized their global settings or CLAUDE.md, they had a dirty git state and couldn't do `git pull` to update the tool without merge conflicts.

**Decision**: Separate tool code (tracked) from user data (gitignored):
- `defaults/global/` and `defaults/_template/` — tracked in git, shipped with the tool
- `global/` and `projects/` — gitignored, created by `cco init`, owned by the user

**Mechanism**: `cco init` copies defaults to user locations on first setup. `--force` resets to defaults.

**Rationale**:
- `git pull` always works cleanly — no conflicts with user customizations
- Multi-PC support: clone the tool repo on any machine, run `cco init`, done
- Clear ownership boundary: tool updates don't touch user config
- Users can version their `global/` and `projects/` separately (e.g., in a dotfiles repo)

**Consequences**:
- First-time setup requires `cco init` before `cco start`
- `cmd_start`, `cmd_new`, and `cmd_project_create` check for `global/` and fail with a helpful message if missing
- Template for `cco project create` comes from `defaults/_template/`, not `projects/_template/`
- Updating defaults after a tool update requires manual diffing or `cco init --force`

---

## 6. Limitations and Trade-offs

| Limitation | Impact | Workaround |
|------------|--------|------------|
| Docker Desktop Mac networking | No true `host` networking; port mapping required | Explicit port ranges in project config |
| Auto memory path derivation | Depends on Claude Code internal logic | May need testing; mount path may need adjustment |
| tmux inside Docker | No native clipboard integration with macOS | Use iTerm2 mode or manual copy |
| Container ephemeral by default | Session transcripts lost on container removal | `claude-state/` mount persists transcripts; `/resume` works across rebuilds |
| Single Docker daemon | All projects share the daemon | Use distinct network names per project |
