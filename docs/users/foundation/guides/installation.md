# Installation and Quick Start

> From zero to working session in minutes.

---

## Prerequisites

| Requirement | Notes |
|-----------|------|
| **macOS or Linux** | Windows not supported (WSL2 not tested) |
| **Docker Desktop** (macOS) or **Docker Engine** (Linux) | Must be running |
| **Bash 3.2+** | macOS includes bash 3.2 (`/bin/bash`) — sufficient for the CLI |
| **jq** | `brew install jq` (macOS) / `apt install jq` (Linux) |
| **Claude Code account** | Pro, Team, Enterprise, or API key |

---

## Setup

```bash
# 1. Clone the repo
git clone <repo-url> ~/claude-orchestrator
cd ~/claude-orchestrator

# 2. Add the CLI to PATH
# zsh (macOS default):
echo 'export PATH="$PATH:$HOME/claude-orchestrator/bin"' >> ~/.zshrc
source ~/.zshrc

# bash:
# echo 'export PATH="$PATH:$HOME/claude-orchestrator/bin"' >> ~/.bashrc
# source ~/.bashrc
#
# macOS note: Terminal.app loads ~/.bash_profile, not ~/.bashrc.
# If using bash on macOS, either add the export to ~/.bash_profile,
# or add this line to ~/.bash_profile to load .bashrc:
#   [[ -f ~/.bashrc ]] && source ~/.bashrc

# 3. Build the Docker image
cco build
```

> **Tip**: Run `cco start tutorial` to start the interactive tutorial. It helps you
> learn cco concepts, set up your first project, create knowledge packs, and
> customize your default rules and workflow — all through guided conversation.

`cco init` is the entry point for a project (see below). The first time you run
it inside a repo, it also seeds your **personal store** at `~/.cco/` from the
framework defaults (agents, skills, rules, settings → `~/.cco/.claude/`).
This global-ensure is idempotent — it runs once and is a no-op afterwards.

---

## Quick use

```bash
# Initialize a project — run inside the repo it serves
cd ~/projects/my-app
cco init                                  # scaffolds <repo>/.cco/ + registers the project

# Configure the project (config lives inside the repo, under .cco/)
vim ~/projects/my-app/.cco/project.yml        # repos, ports, auth
vim ~/projects/my-app/.cco/claude/CLAUDE.md   # instructions for Claude

# Start a session
cco start my-app

# Tip: in the first session, use /init-workspace to automatically
# generate a detailed CLAUDE.md based on the codebase
```

To work on a project someone has already shared (its `<repo>/.cco/` is committed
in the repo), clone the repo and register it:

```bash
git clone <repo-url> ~/projects/my-app
cd ~/projects/my-app
cco join my-app                           # register an existing <repo>/.cco/
cco start my-app
```

To migrate a project from a legacy central installation into its repo, use
`cco init --migrate <project>`.

For temporary sessions without creating a project:

```bash
cco new --repo ~/projects/experiment
cco new --repo ~/projects/api --repo ~/projects/frontend --port 3000:3000
```

---

## Main commands

| Command | Description |
|---------|-------------|
| `cco build` | Build the Docker image |
| `cco build --no-cache` | Full rebuild (updates Claude Code) |
| `cco init` | Scaffold `<repo>/.cco/` in the current repo (+ ensures `~/.cco` on first use) |
| `cco join <project>` | Register an existing `<repo>/.cco/` (shared by a teammate) |
| `cco init --migrate <project>` | Migrate a project from a legacy central install into its repo |
| `cco start <project>` | Start session for a configured project |
| `cco new --repo <path>` | Temporary session with specific repositories |
| `cco list [<kind>]` | List all resources (projects, packs, templates, llms, remotes); narrow with a kind |
| `cco update` | Run migrations + discover available config updates |
| `cco update --sync` | Interactively sync config from framework defaults |
| `cco clean` | Remove .bak files from update |
| `cco stop [project]` | Stop running session(s) |

For the complete CLI reference, see [cli.md](../../reference/cli.md).

---

## Project configuration

Each project's config lives **inside the repo it serves**, under `<repo>/.cco/`,
and is committed with the code so teammates get the same setup. It contains:

- **`project.yml`** — repositories to mount, ports, environment variables, authentication method
- **`claude/CLAUDE.md`** — Claude-specific instructions
- **`claude/settings.json`** — override global settings (optional)
- **`claude/agents/`** — project-specific subagents (optional)
- **`secrets.env`** — credentials and tokens (gitignored, per user)

Personal, cross-project resources live in your store at `~/.cco/`
(`.claude/`, `packs/`, `templates/`). Machine-local state (the
name→path index, transcripts, memory, caches) lives in hidden XDG directories
(`~/.local/state/cco`, `~/.cache/cco`, `~/.local/share/cco`) and is never hand-edited.

For the complete `project.yml` format, see [project-yaml.md](../../configuration/reference/project-yaml.md).

---

## First-run troubleshooting

| Problem | Solution |
|---------|----------|
| Docker daemon not running | Start Docker Desktop (macOS) or `sudo systemctl start docker` (Linux) |
| Image build fails | `cco build --no-cache` — check internet connection and Docker disk space |
| Port conflict | `cco start my-app --port 3001:3000` to remap |
| Image not found | Run `cco build` |

For more troubleshooting, see [troubleshooting.md](../../troubleshooting.md).

---

## Next steps

- [Your first project](first-project.md) — step-by-step tutorial
- [Key concepts](concepts.md) — context hierarchy, knowledge packs, agent teams
- [Knowledge packs](../../packs/guides/knowledge-packs.md) — reusable cross-project documentation
- [Configuration management](../../configuration/guides/configuration-management.md) — git on `.cco/`, `cco config`, sharing, updates
