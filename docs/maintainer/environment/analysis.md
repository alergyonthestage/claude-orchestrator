# Analysis: Environment Extensibility

> Date: 2026-02-24
> Status: Approved — proceed to implementation
> Related: [environment-design.md](./design.md) | [architecture.md](../architecture.md) (ADR-12) | [authentication-and-secrets.md](../auth/analysis.md)

---

## 1. Problem Statement

The Docker image is built once and shared across all projects. Some projects need additional tools, system packages, or runtime configuration that the base image doesn't include. Examples:

- MCP Playwright server → needs Chromium
- MCP PostgreSQL → needs `libpq-dev`
- A Python ML project → needs specific pip packages
- DevOps project → needs `terraform`, `ansible`, `kubectl`

Currently, the only extension mechanism is `--mcp-packages` / `global/mcp-packages.txt` for npm packages at build time. There's no way to:
- Install system packages (`apt-get`) without editing the Dockerfile
- Run project-specific setup (pip install, env config) at container start
- Use a different Docker image per project
- Install npm MCP packages per project (only global)

---

## 2. Extension Points Analyzed

### 2.1 Build Time vs Runtime

| Aspect | Build time (in Dockerfile) | Runtime (in entrypoint) |
|--------|---------------------------|------------------------|
| When | `cco build` | Every `cco start` |
| Speed | Fast at session start (pre-installed) | Slower start (installs each time) |
| Scope | Global (all projects share image) | Can be per-project |
| What works | `apt-get`, large binaries, system config | `pip install`, `npm install`, env config |
| What doesn't | Per-project customization | `apt-get` (needs root, slow, fragile) |

### 2.2 Options

#### Option A — Global setup script (build time)

A user-provided script executed during `cco build`:

```
global/
└── setup.sh     ← executed as RUN in Dockerfile
```

| Pro | Contra |
|-----|--------|
| Fast at runtime (pre-installed) | Requires `cco build` after changes |
| Can install system packages | Global only — all projects get everything |
| Simple mental model | |

#### Option B — Per-project setup script (runtime)

A script in the project directory, executed at container start:

```
projects/<name>/
└── setup.sh     ← executed in entrypoint before Claude launch
```

| Pro | Contra |
|-----|--------|
| Per-project customization | Slower startup |
| No rebuild needed | Can't install apt packages (no root in entrypoint after gosu) |
| | Actually CAN with entrypoint running as root before gosu |

#### Option C — Custom Docker image per project

Allow `project.yml` to specify a different image:

```yaml
docker:
  image: my-custom-orchestrator:latest
```

| Pro | Contra |
|-----|--------|
| Full control per project | User manages their own Dockerfile |
| Cleanest for heavy customization | More Docker knowledge required |
| No impact on base image | |

#### Option D — Per-project npm packages (runtime)

```
projects/<name>/
└── mcp-packages.txt     ← npm install -g at container start
```

| Pro | Contra |
|-----|--------|
| Per-project MCP packages | Slower startup (npm install) |
| No rebuild needed | Only npm packages, not system deps |

---

## 3. Recommendation

**Implement all four options** — they serve different needs and are complementary:

| Need | Solution | Effort |
|------|----------|--------|
| System packages for all projects | **A**: `global/setup.sh` in Dockerfile | Low |
| Lightweight per-project setup | **B**: `projects/<name>/setup.sh` in entrypoint | Low |
| Heavy per-project customization | **C**: `docker.image` in project.yml | Low |
| Per-project MCP npm packages | **D**: `projects/<name>/mcp-packages.txt` in entrypoint | Low |

### Priority order

1. **Option C** (custom image) — lowest effort, highest flexibility for power users
2. **Option A** (global setup.sh) — simple, handles the common case
3. **Option D** (per-project mcp-packages) — natural extension of existing mechanism
4. **Option B** (per-project setup.sh) — completes the picture

---

## 4. MCP Server Dependencies

### MCP GitHub (`@modelcontextprotocol/server-github`)

- **System deps**: None — pure npm package, uses REST API
- **Auth**: Reads `GITHUB_TOKEN` from environment
- **Install**: `npx` handles it on-demand, or pre-install via `mcp-packages.txt`
- **Does NOT require `gh` CLI** — completely independent

### Other common MCP servers

| MCP Server | npm package | System deps | Auth |
|-----------|-------------|-------------|------|
| GitHub | `@modelcontextprotocol/server-github` | None | `GITHUB_TOKEN` env |
| Fetch | `@anthropic/mcp-server-fetch` | None | None |
| PostgreSQL | `@modelcontextprotocol/server-postgres` | None (pure JS driver) | `DATABASE_URL` env |
| Filesystem | `@modelcontextprotocol/server-filesystem` | None | None (path-based) |
| Playwright | `@anthropic/mcp-server-playwright` | Chromium | None |
| Puppeteer | `@anthropic/mcp-server-puppeteer` | Chromium | None |

Most MCP servers are pure npm packages with no system dependencies. The notable exception is browser automation (Playwright/Puppeteer) which needs Chromium — a good use case for `global/setup.sh` or custom image.

### Interaction with authentication

MCP servers that need auth tokens read them from environment variables. The `secrets.env` mechanism (global + per-project) handles this naturally:

```bash
# global/secrets.env
GITHUB_TOKEN=github_pat_...

# projects/devops-toolkit/secrets.env
GITHUB_TOKEN=github_pat_different_scope_...
LINEAR_API_KEY=lin_api_...
```

No special MCP-specific auth mechanism needed — environment variables are the standard interface.
