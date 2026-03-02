# Customizing the Environment

> Guide to extension mechanisms for customizing the development environment in the container.

---

## Overview

claude-orchestrator offers four complementary mechanisms to customize the container environment without modifying the framework itself:

| Mechanism | Scope | When | What |
|-----------|-------|------|------|
| `global/setup.sh` | All projects | `cco build` (build time) | System packages, heavy dependencies |
| `projects/<name>/setup.sh` | Single project | `cco start` (runtime) | Light setup, per-project dependencies |
| `projects/<name>/mcp-packages.txt` | Single project | `cco start` (runtime) | npm packages for MCP servers |
| `docker.image` in project.yml | Single project | `cco start` | Fully custom Docker image |

---

## Global Setup Script

**File**: `global/setup.sh`

The global setup script is executed during `cco build` as a step in the Dockerfile. It runs as root and can install system packages, configure apt repositories, and add global tools.

### When to Use It

- Installation of apt packages needed in all projects
- System tools (Terraform, kubectl, Chromium, etc.)
- Heavy dependencies that require significant download time

### Example

```bash
#!/bin/bash
# global/setup.sh

# Install Chromium for Playwright MCP
apt-get update && apt-get install -y chromium && rm -rf /var/lib/apt/lists/*

# Install Terraform
curl -fsSL https://releases.hashicorp.com/terraform/1.7.0/terraform_1.7.0_linux_amd64.zip \
    -o /tmp/terraform.zip && unzip /tmp/terraform.zip -d /usr/local/bin/ && rm /tmp/terraform.zip
```

### Notes

- The script is included in the Docker image: changes require a `cco build` to take effect
- Runs as root — full system access
- The file is created empty (with comments) by `cco init`
- Dependencies installed here are available in all projects

---

## Per-Project Setup Script

**File**: `projects/<name>/setup.sh`

Executed by the entrypoint at every container startup (`cco start`), before launching Claude. Runs as root.

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
- Runs as root — can install packages, but increases startup time
- For heavy dependencies, prefer `global/setup.sh` or a custom image
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

## Decision Matrix

Which mechanism to use based on your needs:

| Need | Recommended Mechanism | Rationale |
|---|---|---|
| apt package for all projects | `global/setup.sh` | Single rebuild, fast startup |
| apt package for one project (light) | `projects/<name>/setup.sh` | No rebuild needed |
| apt package for one project (heavy) | Custom image | Zero startup penalty |
| npm MCP server for all projects | `global/mcp-packages.txt` | Pre-installed at build |
| npm MCP server for one project | `projects/<name>/mcp-packages.txt` | Runtime, no rebuild |
| pip/gem dependencies for one project | `projects/<name>/setup.sh` | Runtime installation |
| Completely different toolchain | `docker.image` in project.yml | Full control |

### General Rule

- **Build time** (global setup, custom image): for heavy or frequently-used dependencies — upfront cost, immediate startup
- **Runtime** (per-project setup, per-project mcp-packages): for light or experimental dependencies — no rebuild, but slower startup

---

## File Layout

```
global/
  setup.sh                 # Global script (build time)
  mcp-packages.txt         # Global MCP packages (build time)

projects/<name>/
  setup.sh                 # Per-project script (runtime)
  mcp-packages.txt         # Per-project MCP packages (runtime)
  project.yml              # docker.image for custom image
```

All these files are optional. If not present, they are simply ignored.
