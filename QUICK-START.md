# Quick Start

## Setup

```bash
# 1. Clone the repo
git clone <repo-url> ~/claude-orchestrator
cd ~/claude-orchestrator

# 2. Add the CLI to PATH
# bash:
echo 'export PATH="$PATH:$HOME/claude-orchestrator/bin"' >> ~/.bashrc
source ~/.bashrc

# zsh:
# echo 'export PATH="$PATH:$HOME/claude-orchestrator/bin"' >> ~/.zshrc
# source ~/.zshrc

# 3. Initialize user config and build the Docker image
cco init
```

## Usage

```bash
# Create a project
cco project create my-app --repo ~/projects/my-app

# Configure the project
vim projects/my-app/project.yml         # repos, ports, auth
vim projects/my-app/.claude/CLAUDE.md   # instructions for Claude

# Start a session
cco start my-app

# Tip: on the first session, use /init to auto-generate
# a detailed CLAUDE.md based on the codebase
```

For temporary sessions without creating a project:

```bash
cco new --repo ~/projects/experiment
cco new --repo ~/projects/api --repo ~/projects/frontend --port 3000:3000
```

## Commands

| Command | Description |
|---------|-------------|
| `cco init` | Initialize user config from defaults |
| `cco build` | Build the Docker image |
| `cco build --no-cache` | Full rebuild (updates Claude Code) |
| `cco start <project>` | Start session for a configured project |
| `cco start <project> --dry-run` | Show the generated docker-compose without running |
| `cco new --repo <path>` | Temporary session with specific repos |
| `cco project create <name>` | Create a new project from template |
| `cco project list` | List available projects |
| `cco stop [project]` | Stop running session(s) |

## Project Configuration

Each project lives in `projects/<name>/` and contains:

- **`project.yml`** — repos to mount, ports, environment variables, authentication method
- **`.claude/CLAUDE.md`** — project-specific instructions for Claude
- **`.claude/settings.json`** — global settings overrides (optional)
- **`.claude/agents/`** — project-specific subagents (optional)

For the full `project.yml` format see [docs/reference/cli.md](docs/reference/cli.md#4-project-configuration-format-projectyml).

## Knowledge Packs

Packs let you share cross-project documentation (conventions, business overviews, guidelines) without copying files.

```bash
# 1. Define a pack in global/packs/<name>/pack.yml
cat > global/packs/my-client/pack.yml << 'EOF'
name: my-client
source: ~/documents/my-client-knowledge   # directory with your docs
target: /workspace/.packs/my-client

files:
  - backend-conventions.md
  - business-overview.md
  - testing-guidelines.md
EOF

# 2. Activate the pack in project.yml
# packs:
#   - my-client

# 3. Add once to the project's CLAUDE.md
echo "@.claude/packs.md" >> projects/my-app/.claude/CLAUDE.md

# 4. On the next cco start, .claude/packs.md is auto-regenerated
cco start my-app
```

`cco start` mounts the source directory read-only in the container and generates `packs.md` with `@import` directives for each listed file. Files stay in your knowledge repo — zero duplication.

For details see [docs/reference/cli.md §4.2](docs/reference/cli.md) and [docs/guides/project-setup.md](docs/guides/project-setup.md).

## Additional Options

```bash
# Override agent teams display mode
cco start my-app --teammate-mode auto    # iTerm2 native (requires setup)
cco start my-app --teammate-mode tmux    # default, works everywhere

# Use API key instead of OAuth
cco start my-app --api-key

# Extra ports and environment variables
cco start my-app --port 9090:9090 --env DEBUG=true
```

## Documentation

For more details see [docs/](docs/) (organized in `guides/`, `reference/`, `maintainer/`):

**User Guides**
- [project-setup.md](docs/guides/project-setup.md) — Project setup, repos vs extra_mounts vs packs, writing CLAUDE.md
- [subagents.md](docs/guides/subagents.md) — Custom subagents
- [display-modes.md](docs/guides/display-modes.md) — Display modes: tmux vs iTerm2

**Reference**
- [cli.md](docs/reference/cli.md) — Commands and `project.yml` format (incl. §4.2 Knowledge Packs)
- [context.md](docs/reference/context.md) — Context hierarchy and settings

**Maintainer**
- [architecture.md](docs/maintainer/architecture.md) — Architecture and design decisions
- [docker.md](docs/maintainer/docker.md) — Docker image, compose, networking
- [roadmap.md](docs/maintainer/roadmap.md) — Planned features
