# Customizing the Environment

> Guide to extension mechanisms for customizing the development environment in the container.

---

## Overview

claude-orchestrator offers five complementary mechanisms to customize the container environment without modifying the framework itself:

| Mechanism | Scope | When | What |
|-----------|-------|------|------|
| `global/setup-build.sh` | All projects | `cco build` (build time) | System packages, heavy dependencies |
| `global/setup.sh` | All projects | `cco start` (runtime) | Dotfiles, aliases, tmux config, light tools |
| `projects/<name>/setup.sh` | Single project | `cco start` (runtime) | Light setup, per-project dependencies |
| `projects/<name>/mcp-packages.txt` | Single project | `cco start` (runtime) | npm packages for MCP servers |
| `docker.image` in project.yml | Single project | `cco start` | Fully custom Docker image |

---

## Global Build-Time Setup

**File**: `user-config/global/setup-build.sh`

Executed once during `cco build` as a step in the Dockerfile. Runs as **root**. Changes are baked into the Docker image and available in all projects with zero startup cost.

### When to Use It

- Installation of apt packages needed in all projects
- System tools (Terraform, kubectl, Chromium, etc.)
- Heavy dependencies that require significant download time

### Valid Operations

- `apt-get update && apt-get install -y <packages>`
- Downloading and installing binary tools
- Adding apt repositories
- Compiling from source

### Invalid Operations (use `setup.sh` instead)

- Modifying `~/.tmux.conf`, `~/.bashrc`, `~/.vimrc` (overwritten by mounts at runtime)
- Setting shell aliases or functions
- Any user-level configuration

### Example

```bash
#!/bin/bash
# user-config/global/setup-build.sh

# Install Chromium for Playwright MCP
apt-get update && apt-get install -y chromium && rm -rf /var/lib/apt/lists/*

# Install Terraform
curl -fsSL https://releases.hashicorp.com/terraform/1.7.0/terraform_1.7.0_linux_amd64.zip \
    -o /tmp/terraform.zip && unzip /tmp/terraform.zip -d /usr/local/bin/ && rm /tmp/terraform.zip
```

### Notes

- Changes require `cco build` to take effect
- Runs as root — full system access
- The `claude` user does not exist yet at this stage (created later in Dockerfile)
- Files written to `/home/claude/` during build may be overwritten by volume mounts at runtime

---

## Global Runtime Setup

**File**: `user-config/global/setup.sh`

Executed at every `cco start`, **before** the project setup script. Runs as user `claude` inside the container.

### When to Use It

- Dotfiles and user configuration (`~/.tmux.conf`, `~/.bashrc`, `~/.vimrc`)
- Shell aliases and functions
- tmux keybindings
- Lightweight pip/npm packages needed in all projects
- git config overrides

### Valid Operations

- Writing/appending to dotfiles in `~/.` or `/home/claude/`
- `tmux` commands (e.g., `tmux bind-key ...`)
- `pip3 install --user <lightweight-package>`
- `npm install -g <small-package>`
- `git config --global <key> <value>`

### Invalid Operations (use `setup-build.sh` instead)

- `apt-get install` (requires root — this script runs as `claude`)
- Heavy downloads or compilations
- System-level configuration

### Example

```bash
#!/bin/bash
# user-config/global/setup.sh

# Add tmux keybinding for all projects
tmux bind-key C-a send-prefix 2>/dev/null || true

# Shell aliases (append only if not already present)
grep -q 'alias ll=' ~/.bashrc 2>/dev/null || echo 'alias ll="ls -la"' >> ~/.bashrc

# Git config
git config --global rerere.enabled true
```

### Notes

- Executed **at every `cco start`** — must be idempotent
- Runs as user `claude` (not root) — cannot install system packages
- Executes before the project `setup.sh`, so project config can override global
- If the file doesn't exist, it is simply ignored

---

## Per-Project Setup Script

**File**: `projects/<name>/setup.sh`

Executed by the entrypoint at every container startup (`cco start`), after the global runtime setup. Runs as user `claude`.

### When to Use It

- Light dependencies specific to a project
- Setup that doesn't justify a full image rebuild
- Installation of Python packages, Ruby gems, or other non-apt tools

### Example

```bash
#!/bin/bash
# projects/ml-project/setup.sh

# Install Python ML dependencies
pip3 install --quiet pandas numpy scikit-learn 2>/dev/null

# Create project-specific symlinks
ln -sf /workspace/shared-libs/bin/lint /usr/local/bin/project-lint
```

### Notes

- Executed **at every `cco start`** — must be idempotent
- Runs as user `claude` — can install user-level packages, but not system packages
- For heavy dependencies, prefer `global/setup-build.sh` or a custom image
- If the file doesn't exist, it is simply ignored

---

## Per-Project MCP Packages

**File**: `projects/<name>/mcp-packages.txt`

npm packages installed globally at container startup. Useful for MCP servers specific to a project.

### When to Use It

- MCP servers needed only for a specific project
- When you don't want to include the package in the base image

### Example

```
# projects/devops-toolkit/mcp-packages.txt
@anthropic/mcp-server-playwright
@modelcontextprotocol/server-postgres
```

### Notes

- One package per line; empty lines and comments (`#`) are ignored
- Installed at every `cco start` (slows startup if many packages)
- For packages used in all projects, prefer `global/mcp-packages.txt` (installed at build time with `cco build`)

### Comparison with Global mcp-packages.txt

| File | Installed When | Available In |
|------|---|---|
| `global/mcp-packages.txt` | `cco build` (build time) | All projects |
| `projects/<name>/mcp-packages.txt` | `cco start` (runtime) | That project only |

---

## Custom Docker Image

**Field**: `docker.image` in `project.yml`

Allows a project to use a completely customized Docker image instead of `claude-orchestrator:latest`.

### When to Use It

- Very heavy dependencies that would slow down `setup.sh` too much
- Completely different toolchain (e.g., project with Go stack + Kubernetes)
- Maximum environment control, zero startup penalty

### Configuration

```yaml
# projects/devops-toolkit/project.yml
name: devops-toolkit

docker:
  image: claude-orchestrator-devops:latest
```

### Building the Custom Image

Start from the claude-orchestrator base image to maintain compatibility with entrypoint, hooks, and configuration:

```dockerfile
# projects/devops-toolkit/Dockerfile
FROM claude-orchestrator:latest

# Heavy project-specific dependencies
RUN apt-get update && apt-get install -y \
    chromium ansible terraform kubectl \
    && rm -rf /var/lib/apt/lists/*

# Additional MCP servers
RUN npm install -g @anthropic/mcp-server-playwright
```

Build:

```bash
docker build -t claude-orchestrator-devops:latest \
  -f projects/devops-toolkit/Dockerfile .
```

### Notes

- Always use `FROM claude-orchestrator:latest` as the base to maintain compatibility
- After a `cco build` of the base image, rebuild your custom images as well
- The custom image receives the same mounts and environment variables as the base image

---

## Execution Order

Setup mechanisms execute in this order at `cco start`:

1. Docker socket GID fix (entrypoint)
2. MCP server injection (entrypoint)
3. GitHub authentication (entrypoint)
4. **Global runtime setup** (`global/setup.sh`) — as user `claude`
5. **Project setup** (`projects/<name>/setup.sh`) — as user `claude`
6. **Project MCP packages** (`projects/<name>/mcp-packages.txt`)
7. Launch Claude

This means project setup can override global setup when needed.

---

## Decision Matrix

Which mechanism to use based on your needs:

| Need | Recommended Mechanism | Rationale |
|---|---|---|
| apt package for all projects | `global/setup-build.sh` | Single rebuild, fast startup |
| tmux config / dotfiles for all projects | `global/setup.sh` | Applies at every start, no rebuild |
| Shell aliases for all projects | `global/setup.sh` | Runtime, user-level |
| apt package for one project (light) | `projects/<name>/setup.sh` | No rebuild needed |
| apt package for one project (heavy) | Custom image | Zero startup penalty |
| npm MCP server for all projects | `global/mcp-packages.txt` | Pre-installed at build |
| npm MCP server for one project | `projects/<name>/mcp-packages.txt` | Runtime, no rebuild |
| pip/gem dependencies for one project | `projects/<name>/setup.sh` | Runtime installation |
| Completely different toolchain | `docker.image` in project.yml | Full control |

### General Rule

- **Build time** (`setup-build.sh`, custom image, `global/mcp-packages.txt`): for heavy or system-level dependencies — upfront cost, instant startup
- **Runtime** (`setup.sh`, per-project setup, per-project mcp-packages): for lightweight or user-level config — no rebuild, but runs each session

---

## File Layout

```
user-config/global/
  setup-build.sh             # Global script (build time, root)
  setup.sh                   # Global script (runtime, user claude)
  mcp-packages.txt           # Global MCP packages (build time)

projects/<name>/
  setup.sh                   # Per-project script (runtime, user claude)
  mcp-packages.txt           # Per-project MCP packages (runtime)
  project.yml                # docker.image for custom image
```

All these files are optional. If not present, they are simply ignored.
