# Design: Environment Extensibility

> Version: 0.1.0
> Status: Implemented (Sprint 4b, 2026-02-26)
> Related: [analysis](../analysis/analysis-001-environment.md) | [architecture.md](../../foundation/design/architecture.md) (ADR-12) | [auth-design.md](../../integration/auth/design/design-auth.md)

---

## 1. Overview

Four complementary extension mechanisms that let users customize the container environment without modifying claude-orchestrator itself:

| Mechanism | Host source | When | What |
|-----------|-------------|------|------|
| Global setup — `setup-build.sh` (build) / `setup.sh` (runtime) | `~/.cco/` | `cco build` (root) / `cco start` entrypoint (as `claude`) | All-project system deps at build; lightweight runtime config at start |
| Per-project setup — `setup.sh` | `<repo>/.cco/setup.sh` → `/workspace/setup.sh` | `cco start` entrypoint (as `claude`) | Lightweight per-project runtime setup |
| Per-project MCP — `mcp-packages.txt` | `<repo>/.cco/mcp-packages.txt` → `/workspace/mcp-packages.txt` | `cco start` entrypoint (as `claude`) | npm MCP servers, per project |
| `docker.image` in `project.yml` | image reference | `cco start` | Entirely custom Docker image |

> The host source for per-project extension files is `<repo>/.cco/` (the
> committed per-repo config dir of the decentralized model), **not** a central
> `projects/<name>/` directory. The container execution paths are
> `/workspace/setup.sh` and `/workspace/mcp-packages.txt` (workspace root),
> **not** under `/workspace/.claude/`.

---

## 2. Mechanism Details

### 2.1 Global Setup Scripts (all projects)

The global mechanism has two execution phases, kept in two separate files in
the personal store `~/.cco/`:

- **`setup-build.sh`** — runs **once at `cco build`, as root**. For heavy,
  system-level setup (apt packages, compilers, binary tools). Baked into the
  image, so it adds no per-start cost.
- **`setup.sh`** — runs **at every `cco start`, as user `claude`** (via the
  entrypoint). For lightweight runtime config that must apply to all projects
  (dotfiles, shell aliases, tmux keybindings, `git config --global`).

Both default templates ship in `defaults/global/` and are seeded into `~/.cco/`
by `cco init`.

#### Build-time (`setup-build.sh`)

Executed during `cco build` as a `RUN` step in the Dockerfile, as root.

**Dockerfile** (`Dockerfile`):
```dockerfile
# ── User setup script (global, build time) ─────────────────────────
# Heavy system-level setup (apt packages, compilers). Runs once during
# `cco build` as root. Lightweight runtime config belongs in setup.sh.
ARG SETUP_BUILD_SCRIPT_CONTENT=""
RUN if [ -n "$SETUP_BUILD_SCRIPT_CONTENT" ]; then \
        printf '%s' "$SETUP_BUILD_SCRIPT_CONTENT" > /tmp/setup-build.sh \
        && bash /tmp/setup-build.sh \
        && rm -f /tmp/setup-build.sh; \
    fi
```

**`cco build`** (`lib/cmd-build.sh`) reads the script and passes its content as
a build arg (it also accepts a pre-migration `setup.sh` for backward compat,
with a warning):
```bash
cfg_dir="$(_cco_config_dir)"   # ~/.cco
if [[ -f "$cfg_dir/setup-build.sh" ]]; then
    setup_build_file="$cfg_dir/setup-build.sh"
fi
if [[ -n "$setup_build_file" ]]; then
    setup_content=$(cat "$setup_build_file")
    build_args+=(--build-arg "SETUP_BUILD_SCRIPT_CONTENT=$setup_content")
fi
```

**Example** — `setup-build.sh`:
```bash
#!/bin/bash
# Install Chromium for Playwright MCP
apt-get update && apt-get install -y chromium && rm -rf /var/lib/apt/lists/*

# Install Terraform
curl -fsSL https://releases.hashicorp.com/terraform/1.7.0/terraform_1.7.0_linux_amd64.zip \
    -o /tmp/terraform.zip && unzip /tmp/terraform.zip -d /usr/local/bin/ && rm /tmp/terraform.zip
```

#### Runtime (`setup.sh`)

Mounted into the container and executed by the entrypoint at every start, as
the `claude` user, before the per-project setup script.

**Compose mount** (`lib/cmd-start.sh`) — host source `~/.cco/setup.sh`:
```yaml
volumes:
  - ~/.cco/setup.sh:/home/claude/global-setup.sh:ro   # if file exists
```

**Entrypoint** (`config/entrypoint.sh`):
```bash
# ── Global runtime setup script ──────────────────────────────────
GLOBAL_SETUP="/home/claude/global-setup.sh"
if [ -f "$GLOBAL_SETUP" ]; then
    gosu claude bash "$GLOBAL_SETUP" 2>&1 >&2
fi
```

**Defaults**: `defaults/global/setup.sh` and `defaults/global/setup-build.sh`
are empty templates with header comments, seeded into `~/.cco/` by `cco init`.

The global scripts are **seeded and read at the same location** — the personal
store top level `~/.cco/`. `cco init` copies `setup.sh`, `setup-build.sh`, and
`mcp-packages.txt` into `~/.cco/` (`lib/cmd-init.sh`, `cfg="$(_cco_config_dir)"`);
`cco start` mounts the runtime `setup.sh` from `~/.cco/setup.sh`, and `cco build`
reads `setup-build.sh` and `mcp-packages.txt` from `~/.cco/` as well. (An earlier
build-time mismatch — `cco build` reading from the old `~/.cco/global/` — was
fixed; the `global/` wrapper is gone entirely after the ADR-0028 flatten, and the
global `.claude/` itself now lives at `~/.cco/.claude/`.)

### 2.2 Per-Project Setup Script (runtime)

**Host source**: `<repo>/.cco/setup.sh` (the committed per-repo config dir).
**Container path**: `/workspace/setup.sh`.

Executed by the entrypoint at container start, before Claude launches. The
entrypoint runs as root but invokes the script via `gosu claude`, so it runs as
the **`claude`** user (not root).

**Compose mount** (`lib/cmd-start.sh`) — `project_dir` is `<repo>/.cco`:
```yaml
volumes:
  - <repo>/.cco/setup.sh:/workspace/setup.sh:ro   # if file exists
```

**Entrypoint** (`config/entrypoint.sh`):
```bash
# ── Project setup script (runtime) ───────────────────────────────
PROJECT_SETUP="/workspace/setup.sh"
if [ -f "$PROJECT_SETUP" ]; then
    _log "Running project setup script..."
    gosu claude bash "$PROJECT_SETUP" 2>&1 >&2
    _log "Project setup complete"
fi
```

**Constraints**:
- Runs every `cco start` — should be idempotent
- Runs as `claude` (not root) — for system packages use `setup-build.sh` or a custom image
- Should be fast — heavy installs belong in `setup-build.sh` or a custom image

**Example** — `<repo>/.cco/setup.sh`:
```bash
#!/bin/bash
# Install Python ML dependencies (lightweight, runtime-only)
pip3 install --quiet pandas numpy scikit-learn 2>/dev/null
```

**Default**: `templates/project/base/setup.sh` is an empty file with a header
comment; `cco init` scaffolds it into `<repo>/.cco/setup.sh` (the template
`base/` root maps to `<repo>/.cco/`, `lib/cmd-init.sh:280`).

### 2.3 Per-Project MCP Packages (runtime)

**Host source**: `<repo>/.cco/mcp-packages.txt`.
**Container path**: `/workspace/mcp-packages.txt`.

npm packages installed globally at container start. Extends the global
`mcp-packages.txt` mechanism (pre-installed at `cco build`) to per-project,
runtime scope.

**Compose mount** (`lib/cmd-start.sh`) — `project_dir` is `<repo>/.cco`:
```yaml
volumes:
  - <repo>/.cco/mcp-packages.txt:/workspace/mcp-packages.txt:ro   # if file exists
```

**Entrypoint** (`config/entrypoint.sh`):
```bash
# ── Per-project MCP packages (runtime) ───────────────────────────
PROJECT_MCP_PACKAGES="/workspace/mcp-packages.txt"
if [ -f "$PROJECT_MCP_PACKAGES" ]; then
    pkg_count=$(grep -cv '^\s*$\|^\s*#' "$PROJECT_MCP_PACKAGES" 2>/dev/null || true)
    pkg_count=${pkg_count:-0}
    if [ "$pkg_count" -gt 0 ]; then
        _log "Installing $pkg_count project MCP package(s)..."
        grep -v '^\s*$\|^\s*#' "$PROJECT_MCP_PACKAGES" | \
            xargs gosu claude npm install -g 2>&1 >&2
        _log "Project MCP packages installed"
    fi
fi
```

**Example** — `<repo>/.cco/mcp-packages.txt`:
```
@anthropic/mcp-server-playwright
@modelcontextprotocol/server-postgres
```

**Default**: `templates/project/base/mcp-packages.txt` is an empty file with a
header comment; `cco init` scaffolds it into `<repo>/.cco/mcp-packages.txt`.

### 2.4 Custom Docker Image (per project)

**Field**: `docker.image` in `project.yml`

Allows a project to use a completely custom Docker image instead of `claude-orchestrator:latest`.

**project.yml**:
```yaml
docker:
  image: claude-orchestrator-devops:latest
```

**Compose generation change** in `bin/cco`:
```bash
local docker_image
docker_image=$(yml_get "$project_yml" "docker.image")
[[ -z "$docker_image" ]] && docker_image="claude-orchestrator:latest"

cat <<YAML
services:
  claude:
    image: ${docker_image}
YAML
```

**User creates their own Dockerfile**:
```dockerfile
FROM claude-orchestrator:latest

# Heavy project-specific dependencies
RUN apt-get update && apt-get install -y \
    chromium ansible terraform kubectl \
    && rm -rf /var/lib/apt/lists/*

# Additional MCP servers
RUN npm install -g @anthropic/mcp-server-playwright
```

```bash
docker build -t claude-orchestrator-devops:latest -f <repo>/.cco/Dockerfile .
```

This is the most powerful option — full control, zero startup penalty.

---

## 3. Decision Matrix

When to use which mechanism:

| Need | Use | Why |
|------|-----|-----|
| apt package for all projects | `setup-build.sh` (global) | One rebuild, fast startup |
| dotfiles/aliases for all projects | `setup.sh` (global, runtime) | Applied each start, as `claude` |
| apt package for one project | Custom image OR `<repo>/.cco/setup.sh` | Custom image if heavy; setup.sh if lightweight |
| npm MCP server for all projects | global `mcp-packages.txt` | Pre-installed at build |
| npm MCP server for one project | `<repo>/.cco/mcp-packages.txt` | Runtime install, no rebuild |
| pip/gem for one project | `<repo>/.cco/setup.sh` | Runtime install |
| Completely different toolchain | `docker.image` in `project.yml` | Full control |

---

## 4. File Layout

Framework defaults and templates (in the orchestrator repo):

```
defaults/
└── global/
    ├── setup.sh              ← runtime template (empty, header only)
    ├── setup-build.sh        ← build-time template (empty, header only)
    └── mcp-packages.txt      ← global MCP list template
templates/
└── project/
    └── base/                 ← base/ root maps to <repo>/.cco/ at scaffold time
        ├── project.yml
        ├── setup.sh          ← per-project runtime setup template
        ├── mcp-packages.txt  ← per-project MCP list template
        ├── secrets.env       ← scaffolded as secrets.env.example (see auth-design.md)
        └── .claude/          ← becomes <repo>/.cco/claude/
```

User copies on the host:

```
~/.cco/                        ← personal store (cco init seeds these here)
├── setup.sh                   ← global runtime  → /home/claude/global-setup.sh
├── setup-build.sh             ← global build-time (see §2.1)
├── mcp-packages.txt           ← global MCP list (build-time pre-install)
└── .claude/                   ← global Claude config

<repo>/.cco/                    ← committed per-project config (in each repo)
├── project.yml                ← docker.image field (optional)
├── setup.sh                   ← per-project runtime → /workspace/setup.sh
├── mcp-packages.txt           ← per-project MCP    → /workspace/mcp-packages.txt
├── secrets.env                ← gitignored
└── claude/                    ← project Claude config
```

---

## 5. Implementation Checklist

- [x] `Dockerfile`: `ARG SETUP_BUILD_SCRIPT_CONTENT` + `RUN` for the global build-time script
- [x] `config/entrypoint.sh`: Run global runtime `setup.sh` (`/home/claude/global-setup.sh`, via `gosu claude`)
- [x] `config/entrypoint.sh`: Run per-project `setup.sh` (`/workspace/setup.sh`, via `gosu claude`)
- [x] `config/entrypoint.sh`: Install per-project `mcp-packages.txt` (`/workspace/mcp-packages.txt`)
- [x] `lib/cmd-build.sh`: Pass `setup-build.sh` content as `SETUP_BUILD_SCRIPT_CONTENT` build arg
- [x] `lib/cmd-start.sh`: Parse `docker.image` from `project.yml`, use in compose generation
- [x] `lib/cmd-start.sh`: Mount `<repo>/.cco/setup.sh` and `<repo>/.cco/mcp-packages.txt` if they exist
- [x] `defaults/global/setup.sh` and `defaults/global/setup-build.sh`: empty templates with comments
- [x] `templates/project/base/setup.sh`: empty template with comments
- [x] `templates/project/base/mcp-packages.txt`: empty template with comments
- [x] `templates/project/base/secrets.env`: empty template (scaffolded as `secrets.env.example`)
- [x] `templates/project/base/project.yml`: `docker.image` field (optional)
- [ ] `bin/test`: Tests for custom image in dry-run compose
- [ ] `bin/test`: Tests for setup.sh and mcp-packages.txt mount presence
- [ ] Documentation: Update [cli.md](../../../users/reference/cli.md), [project-setup.md](../../../users/configuration/guides/project-setup.md), [docker.md](design-docker.md)
