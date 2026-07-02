# Project Configuration Format (project.yml)

> Related: [cli.md](../../reference/cli.md) | [context-hierarchy.md](../../foundation/reference/context-hierarchy.md)

---

```yaml
# <repo>/.cco/project.yml

name: my-saas-platform
description: "Main SaaS platform with API, frontend, and shared libraries"

# ── Repositories ─────────────────────────────────────────────────────
# Repos are referenced by logical name + an optional machine-agnostic
# coordinate (url/ref). Local paths live in the machine-local STATE index —
# set them with `cco resolve`, never here (keeps `git diff` truthful).
repos:
  - name: backend-api                    # Mount name in /workspace/
    url: git@github.com:org/backend-api.git   # optional bootstrap pointer for `cco resolve`
    ref: main                            # optional git ref
    description: "REST API service"      # optional; surfaced to the agent in the session context

  - name: frontend-app

  - name: shared-libs

# ── Extra mounts (optional) ─────────────────────────────────────────
extra_mounts:
  - name: api-specs                      # logical name; absolute path resolved from the index
    target: /workspace/docs/api-specs
    readonly: true
    description: "OpenAPI specs (reference)"   # optional; surfaced to the agent in the session context

# ── Knowledge Packs (optional) ───────────────────────────────────────
packs:
  - my-client-knowledge   # References ~/.cco/packs/my-client-knowledge/pack.yml

# ── Session access (optional; ADR-0036) ──────────────────────────────
# Per-project defaults for how much of your config a session can edit.
# Overridden by the CLI flags, overrides ~/.cco/access.yml. Omit to keep
# the safe defaults (repo / none / on).
access:
  claude: repo            # .claude authoring: none | repo (default) | all
  cco: none               # .cco framework config: none (default) | read |
                          #   edit-project | edit-global | edit-all
  show_host_paths: true   # host↔container path map in the session (default)

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
| `repos[].name` | ✅ | string | — | Logical repo name (directory name in /workspace/). Machine-agnostic identifier; the absolute host path is resolved per machine from the STATE index, never stored in `project.yml`. See [the local path index](../../../maintainers/configuration/decentralized-config/design.md#3-machine-agnostic-config--the-local-path-index) |
| `repos[].url` | ❌ | string | — | Git remote URL — machine-agnostic coordinate committed in the repo. Used by `cco resolve`/`cco start` to offer auto-clone when no local path is registered for the name |
| `repos[].ref` | ❌ | string | — | Git ref (branch/tag/commit) coordinate, paired with `url` |
| `repos[].description` | ❌ | string | — | Human-readable note surfaced to the agent in the session context (INV-3: `project.yml` is the single source for resource descriptions) |
| `extra_mounts` | ❌ | list | `[]` | Additional volume mounts |
| `extra_mounts[].name` | ✅ | string | — | Logical mount name; the absolute host path is resolved per machine from the STATE index. See [the local path index](../../../maintainers/configuration/decentralized-config/design.md#3-machine-agnostic-config--the-local-path-index) |
| `extra_mounts[].url` | ❌ | string | — | Git remote URL coordinate for a git-backed mount (optional); absent → local-only via the index |
| `extra_mounts[].target` | ❌ | string | `/workspace/<name>` | Container path |
| `extra_mounts[].readonly` | ❌ | bool | `true` | Mount as read-only (secure default; set `false` explicitly for writable mounts) |
| `extra_mounts[].description` | ❌ | string | — | Human-readable note surfaced to the agent in the session context (INV-3: `project.yml` is the single source for resource descriptions) |
| `packs` | ❌ | list | `[]` | Knowledge packs to activate (see Knowledge Packs section below) |
| `llms` | ❌ | list | `[]` | LLMs.txt framework docs to include (see LLMs.txt section below) |
| `access.claude` | ❌ | enum | `repo` | Session `.claude` authoring access: `none` \| `repo` \| `all` (ADR-0036; see [Session access](../../reference/cli.md#session-access-capability-model)) |
| `access.cco` | ❌ | enum | `none` | Session `.cco`/framework config access: `none` \| `read` \| `edit-project` \| `edit-global` \| `edit-all` |
| `access.show_host_paths` | ❌ | bool | `true` | Include the host↔container path map in the session |
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
| `browser.enabled` | ❌ | bool | `false` | Activate browser automation ([guide](../../integration/guides/browser-automation.md)) |
| `browser.mode` | ❌ | string | `host` | Where Chrome runs (`host` only in v1) |
| `browser.cdp_port` | ❌ | int | `9222` | Chrome remote debugging port |
| `browser.mcp_args` | ❌ | list | `[]` | Extra CLI flags for chrome-devtools-mcp |

---

## Validation Rules

> **Policy**: Secure-by-default. See [ADR-13](../../../maintainers/foundation/design/architecture.md) and [NFR-4/NFR-5](../../../maintainers/foundation/analysis/spec.md).

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
| `docker.mount_socket` | `false` | Opt-in: Docker socket grants full host Docker API access (see [security analysis](../../../maintainers/security/analysis/analysis-001-socket-security.md)) |

### Field Validation

| Field | Format | Validated |
|-------|--------|-----------|
| `name` | `^[a-zA-Z0-9][a-zA-Z0-9_-]*$`, max 63 chars | At parse time |
| `repos[].name` | Required logical name (no silent drops); resolved to an absolute host path via the STATE index | Index lookup at start time |
| `repos[].url` | Git remote URL coordinate (optional); used for clone-from-`url` resolution | At resolve/start time |
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

**Pack definition** — `~/.cco/packs/<name>/pack.yml`:
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
4. The `knowledge` section of `.claude/workspace.yml` is generated with the list of files and their descriptions:
   ```yaml
   knowledge:
     - path: /workspace/.claude/packs/my-client/backend-coding-conventions.md
       description: Read when writing backend code
     - path: /workspace/.claude/packs/my-client/business-overview.md
       description: Read for business context
   ```
5. `session-context.sh` (SessionStart hook) reads that section, renders the instructional preamble, and injects it into `additionalContext` automatically — **no CLAUDE.md edit needed**

**Name conflicts**: If two packs define the same agent, rule, or skill name, the last pack listed in `project.yml` wins. A warning is emitted. See [ADR-14](../../../maintainers/foundation/design/architecture.md) for the design rationale.

**Pack directory** — `~/.cco/packs/` (in the personal store, created by `cco init`):
```
~/.cco/
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

---

## LLMs.txt — Framework Documentation

Projects and packs can reference installed llms.txt files via the `llms:` section.
These are official framework documentation files (following the [llms.txt standard](https://llmstxt.org/))
that are served to coding agents during sessions.

### Schema

```yaml
# In project.yml or pack.yml — each entry carries a coordinate (url is the
# re-fetch source, like a repo's url). url is MANDATORY (ADR-0017 D1).
llms:
  - name: svelte
    url: https://svelte.dev/llms.txt          # MANDATORY — the re-fetch coordinate
  - name: shadcn-svelte
    url: https://shadcn-svelte.com/llms.txt
    description: "Component index — WebFetch for details"   # optional override
    variant: index                            # optional: full | medium | small | index
```

| Field | Required | Type | Default | Description |
|-------|----------|------|---------|-------------|
| `llms[].name` | ✅ | string | — | Name matching the cached `~/.cache/cco/llms/<name>/` directory |
| `llms[].url` | ✅ | string | — | Source URL — the machine-agnostic coordinate that keeps the doc re-fetchable when the project/pack is shared or moved to another machine (ADR-0017 D1). A url-less entry is a share-readiness gap flagged by `cco pack`/`project validate` |
| `llms[].description` | ❌ | string | Auto from H1 | Override description shown to the agent |
| `llms[].variant` | ❌ | string | Auto (full > medium > small > index) | Force a specific file variant |

> A bare short-form entry (`- svelte`, name only) is **legacy/incomplete**: it carries no coordinate, so a teammate (or you on a fresh machine) cannot re-fetch it. `cco update` backfills the url into installed packs from a previously-installed source where possible; otherwise `validate` flags the gap and you add the url.

### How It Works

1. Install llms files with `cco llms install <url>` (content cached per-machine in `~/.cache/cco/llms/`)
2. Reference them in `project.yml` or `pack.yml` via the `llms:` section (with the `url` coordinate)
3. On a machine where a referenced llms is not installed, `cco resolve` fetches it from the `url`
   (and `cco start` warns if it is still missing); the content is re-fetchable, never committed
4. At `cco start`, directories are mounted read-only at `/workspace/.claude/llms/<name>/`
5. The file list is written to the `llms` section of `.claude/workspace.yml` and injected into the agent's context
6. A managed rule (`use-official-docs.md`) guides the agent to consult docs before writing code

### Resolution

When both a project and its packs reference the same llms name, the project's
`description:` and `variant:` overrides take precedence. Each llms directory is
mounted only once regardless of how many times it's referenced.
