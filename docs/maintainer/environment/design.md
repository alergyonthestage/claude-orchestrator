# Design: Environment Extensibility

> Version: 0.1.0
> Status: Design — pending implementation
> Related: [analysis](../analysis/environment-extensibility.md) | [architecture.md](./architecture.md) (ADR-12) | [auth-design.md](./auth-design.md)

---

## 1. Overview

Four complementary extension mechanisms that let users customize the container environment without modifying claude-orchestrator itself:

| Mechanism | Scope | When | What |
|-----------|-------|------|------|
| `global/setup.sh` | All projects | `cco build` | System packages, heavy deps |
| `projects/<name>/setup.sh` | Per project | `cco start` (entrypoint) | Lightweight runtime setup |
| `projects/<name>/mcp-packages.txt` | Per project | `cco start` (entrypoint) | npm MCP servers |
| `docker.image` in project.yml | Per project | `cco start` | Entirely custom Docker image |

---

## 2. Mechanism Details

### 2.1 Global Setup Script (build time)

**File**: `global/setup.sh`

Executed during `cco build` as a `RUN` step in the Dockerfile. Runs as root. Can install system packages, configure system settings, add repositories.

**Dockerfile change**:
```dockerfile
# ── User setup script (global) ────────────────────────────────────
# Optional user-provided script for system-level customizations.
# Runs as root during build. Install apt packages, system tools, etc.
ARG SETUP_SCRIPT_CONTENT=""
RUN if [ -n "$SETUP_SCRIPT_CONTENT" ]; then \
        echo "$SETUP_SCRIPT_CONTENT" | bash; \
    fi
```

**`bin/cco` change** — `cmd_build()`:
```bash
local build_args=()
if [[ -f "$GLOBAL_DIR/setup.sh" ]]; then
    local setup_content
    setup_content=$(cat "$GLOBAL_DIR/setup.sh")
    build_args+=(--build-arg "SETUP_SCRIPT_CONTENT=$setup_content")
    info "Including global/setup.sh in build"
fi
```

**Alternative approach** (simpler, uses COPY):
```dockerfile
COPY global/setup.sh /tmp/setup.sh
RUN if [ -f /tmp/setup.sh ] && [ -s /tmp/setup.sh ]; then bash /tmp/setup.sh; fi && rm -f /tmp/setup.sh
```

This requires that `global/setup.sh` is in the Docker build context. Since `cco build` runs from the orchestrator root, this works if we add `global/setup.sh` to the context. The COPY approach is simpler and more readable.

**Example** — `global/setup.sh`:
```bash
#!/bin/bash
# Install Chromium for Playwright MCP
apt-get update && apt-get install -y chromium && rm -rf /var/lib/apt/lists/*

# Install Terraform
curl -fsSL https://releases.hashicorp.com/terraform/1.7.0/terraform_1.7.0_linux_amd64.zip \
    -o /tmp/terraform.zip && unzip /tmp/terraform.zip -d /usr/local/bin/ && rm /tmp/terraform.zip
```

**Default**: `defaults/global/setup.sh` is an empty file with a header comment. Created by `cco init`.

### 2.2 Per-Project Setup Script (runtime)

**File**: `projects/<name>/setup.sh`

Executed by the entrypoint at container start, before Claude launches. Runs as root (entrypoint runs as root, drops to claude via gosu later).

**Compose mount**:
```yaml
volumes:
  - ./setup.sh:/workspace/.claude/setup.sh:ro   # if file exists
```

**Entrypoint change**:
```bash
# ── Project setup script (runtime) ───────────────────────────────
PROJECT_SETUP="/workspace/.claude/setup.sh"
if [ -f "$PROJECT_SETUP" ]; then
    echo "[entrypoint] Running project setup script..." >&2
    bash "$PROJECT_SETUP" 2>&1 >&2
    echo "[entrypoint] Project setup complete" >&2
fi
```

**Constraints**:
- Runs every `cco start` — should be idempotent
- Runs as root — can install packages, but increases startup time
- Should be fast — heavy installs belong in `global/setup.sh` or custom image

**Example** — `projects/ml-project/setup.sh`:
```bash
#!/bin/bash
# Install Python ML dependencies (lightweight, runtime-only)
pip3 install --quiet pandas numpy scikit-learn 2>/dev/null
```

**Default**: `defaults/_template/setup.sh` is an empty file with a header comment.

### 2.3 Per-Project MCP Packages (runtime)

**File**: `projects/<name>/mcp-packages.txt`

npm packages installed globally at container start. Extends the existing `global/mcp-packages.txt` mechanism to per-project scope.

**Compose mount**:
```yaml
volumes:
  - ./mcp-packages.txt:/workspace/.claude/mcp-packages.txt:ro   # if file exists
```

**Entrypoint change**:
```bash
# ── Per-project MCP packages (runtime) ───────────────────────────
PROJECT_MCP_PACKAGES="/workspace/.claude/mcp-packages.txt"
if [ -f "$PROJECT_MCP_PACKAGES" ]; then
    pkg_count=$(grep -cv '^\s*$\|^\s*#' "$PROJECT_MCP_PACKAGES" 2>/dev/null || echo "0")
    if [ "$pkg_count" -gt 0 ]; then
        echo "[entrypoint] Installing $pkg_count project MCP package(s)..." >&2
        grep -v '^\s*$\|^\s*#' "$PROJECT_MCP_PACKAGES" | \
            xargs gosu claude npm install -g 2>&1 >&2
        echo "[entrypoint] Project MCP packages installed" >&2
    fi
fi
```

**Example** — `projects/devops-toolkit/mcp-packages.txt`:
```
@anthropic/mcp-server-playwright
@modelcontextprotocol/server-postgres
```

**Default**: `defaults/_template/mcp-packages.txt` is an empty file with a header comment.

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
docker build -t claude-orchestrator-devops:latest -f projects/devops-toolkit/Dockerfile .
```

This is the most powerful option — full control, zero startup penalty.

---

## 3. Decision Matrix

When to use which mechanism:

| Need | Use | Why |
|------|-----|-----|
| apt package for all projects | `global/setup.sh` | One rebuild, fast startup |
| apt package for one project | Custom image OR `projects/<name>/setup.sh` | Custom image if heavy; setup.sh if lightweight |
| npm MCP server for all projects | `global/mcp-packages.txt` (existing) | Pre-installed at build |
| npm MCP server for one project | `projects/<name>/mcp-packages.txt` | Runtime install, no rebuild |
| pip/gem for one project | `projects/<name>/setup.sh` | Runtime install |
| Completely different toolchain | `docker.image` in project.yml | Full control |

---

## 4. File Layout

```
defaults/
├── global/
│   ├── setup.sh              ← NEW (empty template)
│   └── mcp-packages.txt      ← EXISTS
└── _template/
    ├── setup.sh              ← NEW (empty template)
    ├── mcp-packages.txt      ← NEW (empty template)
    └── secrets.env           ← NEW (empty template, see auth-design.md)

global/                        ← user copy (gitignored)
├── setup.sh
├── mcp-packages.txt
└── secrets.env

projects/<name>/               ← user copy (gitignored)
├── setup.sh
├── mcp-packages.txt
├── secrets.env
└── project.yml               ← docker.image field (optional)
```

---

## 5. Implementation Checklist

- [ ] `Dockerfile`: Add `COPY` + `RUN` for `global/setup.sh`
- [ ] `config/entrypoint.sh`: Add project setup.sh execution
- [ ] `config/entrypoint.sh`: Add project mcp-packages.txt installation
- [ ] `bin/cco`: Parse `docker.image` from project.yml, use in compose generation
- [ ] `bin/cco`: Mount `setup.sh` and `mcp-packages.txt` if they exist
- [ ] `defaults/global/setup.sh`: Create empty template with comments
- [ ] `defaults/_template/setup.sh`: Create empty template with comments
- [ ] `defaults/_template/mcp-packages.txt`: Create empty template with comments
- [ ] `defaults/_template/secrets.env`: Create empty template with comments
- [ ] `defaults/_template/project.yml`: Add `docker.image` and `docker.mount_ssh_keys` (commented)
- [ ] `bin/test`: Tests for custom image in dry-run compose
- [ ] `bin/test`: Tests for setup.sh and mcp-packages.txt mount presence
- [ ] Documentation: Update [cli.md](../reference/cli.md), [project-setup.md](../guides/project-setup.md), [docker.md](./docker.md)
