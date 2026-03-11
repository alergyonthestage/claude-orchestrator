# Project Configuration Format (project.yml)

> Related: [cli.md](cli.md) | [context-hierarchy.md](context-hierarchy.md)

---

```yaml
# user-config/projects/<name>/project.yml

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
  - my-client-knowledge   # References user-config/packs/my-client-knowledge/pack.yml

# ── Docker options ───────────────────────────────────────────────────
docker:
  mount_socket: true        # Enable Docker-from-Docker (default: false)

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

  # Container access policy (requires mount_socket: true)
  containers:
    policy: allowlist         # project_only | allowlist | denylist | unrestricted
    allow:
      - "cc-my-saas-*"
      - "postgres-dev"
    create: true
    name_prefix: "cc-my-saas-"
    required_labels:
      cco.project: my-saas-platform

  # Mount restrictions (requires mount_socket: true)
  mounts:
    policy: project_only      # none | project_only | allowlist | any
    deny:
      - "/etc/shadow"

  # Security constraints (requires mount_socket: true)
  security:
    no_privileged: true
    no_sensitive_mounts: true
    drop_capabilities:
      - SYS_ADMIN
      - NET_ADMIN
    resources:
      memory: "4g"
      cpus: "4"
      max_containers: 10

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
| `repos` | ❌ | list | `[]` | Repositories to mount (empty allowed; a warning is shown at start) |
| `repos[].path` | ✅ | string | — | Absolute path on host (~ expanded) |
| `repos[].name` | ✅ | string | — | Directory name in /workspace/ |
| `extra_mounts` | ❌ | list | `[]` | Additional volume mounts |
| `extra_mounts[].source` | ✅ | string | — | Host path |
| `extra_mounts[].target` | ✅ | string | — | Container path |
| `extra_mounts[].readonly` | ❌ | bool | `true` | Mount as read-only (secure default; set `false` explicitly for writable mounts) |
| `packs` | ❌ | list | `[]` | Knowledge packs to activate (see Knowledge Packs section below) |
| `docker.ports` | ❌ | list | see defaults | Port mappings |
| `docker.env` | ❌ | map | `{}` | Environment variables |
| `docker.network` | ❌ | string | `cc-<name>` | Docker network name |
| `docker.image` | ❌ | string | `claude-orchestrator:latest` | Custom Docker image for this project |
| `docker.mount_socket` | ❌ | bool | `false` | Mount Docker socket (set true to enable Docker-from-Docker) |
| `docker.containers.policy` | ❌ | enum | `project_only` | Container access: `project_only` \| `allowlist` \| `denylist` \| `unrestricted` |
| `docker.containers.allow` | ❌ | list | `[]` | Glob patterns for allowlist policy |
| `docker.containers.deny` | ❌ | list | `[]` | Glob patterns for denylist policy |
| `docker.containers.create` | ❌ | bool | `true` | Allow creating new containers |
| `docker.containers.name_prefix` | ❌ | string | `cc-{name}-` | Enforced name prefix on create |
| `docker.containers.required_labels` | ❌ | map | `cco.project: {name}` | Labels injected on create |
| `docker.mounts.policy` | ❌ | enum | `project_only` | Mount restriction: `none` \| `project_only` \| `allowlist` \| `any` |
| `docker.mounts.allow` | ❌ | list | `[]` | Allowed paths for allowlist policy |
| `docker.mounts.deny` | ❌ | list | `[]` | Paths always denied |
| `docker.mounts.force_readonly` | ❌ | bool | `false` | Force all mounts read-only |
| `docker.security.no_privileged` | ❌ | bool | `true` | Block `--privileged` containers |
| `docker.security.no_sensitive_mounts` | ❌ | bool | `true` | Block `/proc`, `/sys` mounts |
| `docker.security.force_non_root` | ❌ | bool | `false` | Block root user in containers |
| `docker.security.drop_capabilities` | ❌ | list | `[SYS_ADMIN, NET_ADMIN]` | Linux capabilities to drop |
| `docker.security.resources.memory` | ❌ | string | `"4g"` | Max memory per container |
| `docker.security.resources.cpus` | ❌ | string | `"4"` | Max CPUs per container |
| `docker.security.resources.max_containers` | ❌ | int | `10` | Max simultaneous containers |
| `auth.method` | ❌ | string | `oauth` | Authentication method |
| `browser.enabled` | ❌ | bool | `false` | Activate browser automation ([guide](../user-guides/browser-automation.md)) |
| `browser.mode` | ❌ | string | `host` | Where Chrome runs (`host` only in v1) |
| `browser.cdp_port` | ❌ | int | `9222` | Chrome remote debugging port |
| `browser.mcp_args` | ❌ | list | `[]` | Extra CLI flags for chrome-devtools-mcp |

---

## Validation Rules

> **Policy**: Secure-by-default. See [ADR-13](../maintainer/architecture.md) and [NFR-4/NFR-5](../maintainer/spec.md).

### Booleans

All boolean fields (`browser.enabled`, `github.enabled`, `docker.mount_socket`, `extra_mounts[].readonly`) are parsed through a shared normalizer that:
- Trims leading/trailing whitespace
- Accepts (case-insensitive): `true`, `yes`, `on`, `1` → **true**
- Accepts (case-insensitive): `false`, `no`, `off`, `0` → **false**
- Rejects other values with a warning and falls back to the secure default

### Secure Defaults

When a security-relevant field is **omitted**, the default is always the most restrictive:

| Field | Default When Omitted | Rationale |
|-------|---------------------|-----------|
| `extra_mounts[].readonly` | `true` (read-only) | Extra mounts are reference material; writes require explicit opt-in |
| `browser.enabled` | `false` | Browser automation is an additional attack surface |
| `github.enabled` | `false` | GitHub access requires explicit opt-in |
| `docker.mount_socket` | `false` | Opt-in: Docker socket grants full host Docker API access (see [security analysis](../maintainer/docker-security/analysis.md)) |

### Field Validation

| Field | Format | Validated |
|-------|--------|-----------|
| `name` | `^[a-zA-Z0-9][a-zA-Z0-9_-]*$`, max 63 chars | At parse time |
| `repos[].path` | Valid path, `~` expanded, must exist on host | At start time |
| `repos[].name` | Required when `path` is present (no silent drops) | At parse time |
| `docker.ports[]` | `^[0-9]+:[0-9]+(/tcp\|/udp)?$` | At parse time |
| `docker.env` | `KEY: value` format, KEY matches `^[A-Za-z_][A-Za-z0-9_]*$` | At parse time |
| `browser.cdp_port` | Numeric, range 1–65535 | At parse time |
| `browser.mcp_args` | Values JSON-escaped before injection | At compose generation |
| `auth.method` | Enum: `oauth` \| `api_key` | At parse time |
| `docker.containers.policy` | Enum: `project_only` \| `allowlist` \| `denylist` \| `unrestricted` | At start time |
| `docker.mounts.policy` | Enum: `none` \| `project_only` \| `allowlist` \| `any` | At start time |

### Whitespace

All parsed values have leading and trailing whitespace trimmed. Indentation errors (wrong number of spaces) cause the field to be skipped — the parser emits a warning.

---

## Knowledge Packs

Knowledge packs bundle reusable documentation, skills, agents, and rules that can be shared across multiple projects without copying files.

**Pack definition** — `user-config/packs/<name>/pack.yml`:
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

# Skills — mounted to /workspace/.claude/skills/ (:ro) on cco start
skills:
  - deploy

# Agents — mounted to /workspace/.claude/agents/ (:ro, per file) on cco start
agents:
  - devops-specialist.md

# Rules — mounted to /workspace/.claude/rules/ (:ro, per file) on cco start
rules:
  - api-conventions.md
```

All sections are optional. A knowledge-only pack needs only the `knowledge:` section.

**How it works** — on every `cco start`:
1. Name conflicts across packs are detected (warning emitted if same filename in agents/rules/skills)
2. The `knowledge.source` directory is mounted at `/workspace/.claude/packs/<name>/` (read-only)
3. Pack rules, agents, and skills are mounted into `/workspace/.claude/` via per-file (rules, agents) or per-directory (skills) read-only Docker volume mounts
4. `.claude/packs.md` is generated with an instructional list of files and their descriptions:
   ```
   The following knowledge files provide project-specific conventions and context.
   Read the relevant files BEFORE starting any implementation, review, or design task.

   - /workspace/.claude/packs/my-client/backend-coding-conventions.md — Read when writing backend code
   - /workspace/.claude/packs/my-client/business-overview.md — Read for business context
   ```
5. `session-context.sh` (SessionStart hook) injects `packs.md` into `additionalContext` automatically — **no CLAUDE.md edit needed**

**Name conflicts**: If two packs define the same agent, rule, or skill name, the last pack listed in `project.yml` wins. A warning is emitted. See [ADR-14](../maintainer/architecture.md) for the design rationale.

**Pack directory** — `user-config/packs/` (gitignored from orchestrator repo, created by `cco init`):
```
user-config/
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
