# Project Configuration Format (project.yml)

> Related: [cli.md](cli.md) | [context-hierarchy.md](context-hierarchy.md)

---

```yaml
# projects/<name>/project.yml

name: my-saas-platform
description: "Main SaaS platform with API, frontend, and shared libraries"

# ── Repositories ─────────────────────────────────────────────────────
repos:
  - path: ~/projects/backend-api        # Absolute path on host
    name: backend-api                    # Mount name in /workspace/

  - path: ~/projects/frontend-app
    name: frontend-app

  - path: ~/projects/shared-libs
    name: shared-libs

# ── Extra mounts (optional) ─────────────────────────────────────────
extra_mounts:
  - source: ~/documents/api-specs
    target: /workspace/docs/api-specs
    readonly: true

# ── Knowledge Packs (optional) ───────────────────────────────────────
packs:
  - my-client-knowledge   # References global/packs/my-client-knowledge/pack.yml

# ── Docker options ───────────────────────────────────────────────────
docker:
  # Port mappings (host:container)
  ports:
    - "3000:3000"       # Frontend dev
    - "4000:4000"       # Backend API
    - "5432:5432"       # PostgreSQL
    - "6379:6379"       # Redis

  # Extra environment variables
  env:
    NODE_ENV: development
    DATABASE_URL: "postgresql://postgres:postgres@postgres:5432/myapp"

  # Network name for sibling containers
  network: cc-my-saas

# ── Authentication ───────────────────────────────────────────────────
auth:
  method: oauth         # "oauth" (default) | "api_key"
  # If api_key: reads from ANTHROPIC_API_KEY env var

# ── Browser Automation (optional) ──────────────────────────────────
browser:
  enabled: true           # Activate chrome-devtools-mcp (default: false)
  mode: host              # "host" (default, only supported mode)
  cdp_port: 9222          # Chrome remote debugging port (default: 9222)
  mcp_args: []            # Extra flags for chrome-devtools-mcp
```

---

## Field Reference

| Field | Required | Type | Default | Description |
|-------|----------|------|---------|-------------|
| `name` | ✅ | string | — | Project identifier |
| `description` | ❌ | string | `""` | Human-readable description |
| `repos` | ✅ | list | — | Repositories to mount |
| `repos[].path` | ✅ | string | — | Absolute path on host (~ expanded) |
| `repos[].name` | ✅ | string | — | Directory name in /workspace/ |
| `extra_mounts` | ❌ | list | `[]` | Additional volume mounts |
| `extra_mounts[].source` | ✅ | string | — | Host path |
| `extra_mounts[].target` | ✅ | string | — | Container path |
| `extra_mounts[].readonly` | ❌ | bool | `false` | Mount as read-only |
| `packs` | ❌ | list | `[]` | Knowledge packs to activate (see Knowledge Packs section below) |
| `docker.ports` | ❌ | list | see defaults | Port mappings |
| `docker.env` | ❌ | map | `{}` | Environment variables |
| `docker.network` | ❌ | string | `cc-<name>` | Docker network name |
| `docker.image` | ❌ | string | `claude-orchestrator:latest` | Custom Docker image for this project |
| `docker.mount_socket` | ❌ | bool | `true` | Mount Docker socket (set false to disable Docker-from-Docker) |
| `auth.method` | ❌ | string | `oauth` | Authentication method |
| `browser.enabled` | ❌ | bool | `false` | Activate browser automation ([guide](../user-guides/browser-automation.md)) |
| `browser.mode` | ❌ | string | `host` | Where Chrome runs (`host` only in v1) |
| `browser.cdp_port` | ❌ | int | `9222` | Chrome remote debugging port |
| `browser.mcp_args` | ❌ | list | `[]` | Extra CLI flags for chrome-devtools-mcp |

---

## Knowledge Packs

Knowledge packs bundle reusable documentation, skills, agents, and rules that can be shared across multiple projects without copying files.

**Pack definition** — `global/packs/<name>/pack.yml`:
```yaml
name: my-client

# Knowledge files — mounted from source, injected into context automatically
knowledge:
  source: ~/documents/my-client-knowledge  # host dir to mount (read-only)
  files:
    - path: backend-coding-conventions.md
      description: "Read when writing backend code, APIs, or DB logic"
    - path: business-overview.md
      description: "Read for business context and product understanding"
    - testing-guidelines.md              # short form: no description

# Skills — copied to /workspace/.claude/skills/ on cco start
skills:
  - deploy

# Agents — copied to /workspace/.claude/agents/ on cco start
agents:
  - devops-specialist.md

# Rules — copied to /workspace/.claude/rules/ on cco start
rules:
  - api-conventions.md
```

All sections are optional. A knowledge-only pack needs only the `knowledge:` section.

**How it works** — on every `cco start`:
1. Stale files from the previous `.pack-manifest` are cleaned
2. Name conflicts across packs are detected (warning emitted if same filename in agents/rules/skills)
3. The `knowledge.source` directory is mounted at `/workspace/.packs/<name>/` (read-only)
4. `.claude/packs.md` is generated with an instructional list of files and their descriptions:
   ```
   The following knowledge files provide project-specific conventions and context.
   Read the relevant files BEFORE starting any implementation, review, or design task.

   - /workspace/.packs/my-client/backend-coding-conventions.md — Read when writing backend code
   - /workspace/.packs/my-client/business-overview.md — Read for business context
   ```
5. `session-context.sh` (SessionStart hook) injects `packs.md` into `additionalContext` automatically — **no CLAUDE.md edit needed**
6. Skills, agents, and rules are copied from `global/packs/<name>/` into `projects/<n>/.claude/`
7. A `.pack-manifest` file is written tracking all copied files (used for cleanup on next start)

**Name conflicts**: If two packs define the same agent, rule, or skill name, the last pack listed in `project.yml` wins. A warning is emitted. See [ADR-9](../maintainer/architecture.md) for the design rationale.

**Pack directory** — `global/packs/` (gitignored, created by `cco init`):
```
global/
  packs/
    my-client/
      pack.yml
      knowledge/        # optional: omit knowledge.source to use this dir
        overview.md
      skills/
        deploy/
          SKILL.md
      agents/
        specialist.md
      rules/
        conventions.md
```
