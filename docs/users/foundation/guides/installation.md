# Installation and Quick Start

> From zero to working session in minutes.

---

## Prerequisites

| Requirement | Notes |
|-----------|------|
| **macOS or Linux** | Windows not supported (WSL2 not tested) |
| **Node.js 18+** | Only to install the CLI via `npm install -g` — `cco` itself is Bash and shells out to Docker |
| **Docker Desktop** (macOS) or **Docker Engine** (Linux) | Must be running |
| **Bash 3.2+** | macOS includes bash 3.2 (`/bin/bash`) — sufficient for the CLI |
| **jq** | `brew install jq` (macOS) / `apt install jq` (Linux) |
| **Claude Code account** | Pro, Team, Enterprise, or API key |

---

## Setup

Install the CLI from npm, then build the Docker image:

```bash
# 1. Install the cco CLI globally
npm install -g @claude-orchestrator/cco

# 2. Build the Docker image
cco build
```

That's it — `cco` is now on your PATH (npm links it for you). Verify with
`cco --version` (or `cco --help`).

> **Tip**: Run `cco start tutorial` to start the interactive tutorial. It helps you
> learn cco concepts, set up your first project, create knowledge packs, and
> customize your default rules and workflow — all through guided conversation.

### Install from source (contributors / maintainers)

If you're hacking on cco itself, run it straight from a clone instead of npm:

```bash
git clone https://github.com/alergyonthestage/claude-orchestrator.git ~/claude-orchestrator
cd ~/claude-orchestrator

# Put the CLI on your PATH
# zsh (macOS default):
echo 'export PATH="$PATH:$HOME/claude-orchestrator/bin"' >> ~/.zshrc && source ~/.zshrc
# bash:
# echo 'export PATH="$PATH:$HOME/claude-orchestrator/bin"' >> ~/.bashrc && source ~/.bashrc
# macOS note: Terminal.app loads ~/.bash_profile, not ~/.bashrc — add the export
# there, or source ~/.bashrc from it: [[ -f ~/.bashrc ]] && source ~/.bashrc

cco build
```

See [CONTRIBUTING.md](../../../../CONTRIBUTING.md) for the full development and
release workflow.

### Keeping cco up to date

cco has two independent update tracks:

```bash
# Upgrade the cco engine (CLI + framework defaults), then apply migrations:
npm update -g @claude-orchestrator/cco && cco update
```

- `npm update -g @claude-orchestrator/cco` upgrades the **engine**.
- `cco update` runs **migrations + config discovery** for your projects — it does
  *not* upgrade the engine, but after an upgrade it prints the exact command for
  your install method.
- Claude Code itself auto-updates in place via the native installer (no rebuild).

> **Browse the docs offline:** `cco docs` lists the bundled user guides for your
> installed version; `cco docs <topic>` opens one (e.g. `cco docs reference/cli`).

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
in the repo), clone the repo and start it — cwd-first resolution registers it,
no separate step:

```bash
git clone <repo-url> ~/projects/my-app
cd ~/projects/my-app
cco start my-app                          # cwd-first resolution registers it automatically
```

(For a multi-repo project, run `cco resolve --scan <dir>` once to bind every
member's path first.) Use `cco join <project>` only to add the **current** repo as
a new member of an existing project.

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
| `cco build --no-cache` | Full rebuild + reset the Claude Code install cache (fresh install next start; Claude Code otherwise auto-updates in place) |
| `cco init` | Scaffold `<repo>/.cco/` in the current repo (+ ensures `~/.cco` on first use) |
| `cco join <project>` | Add the current repo to `<project>` as a member (Journey E) |
| `cco init --migrate <project>` | Migrate a project from a legacy central install into its repo |
| `cco start <project>` | Start a project (cwd-first: registers a freshly-cloned repo automatically) |
| `cco resolve --scan <dir>` | Discover/bind projects under `<dir>` into the index |
| `cco new --repo <path>` | Temporary session with specific repositories |
| `cco list [<kind>]` | List all resources (projects, packs, templates, llms, remotes); narrow with a kind |
| `cco update` | Run migrations + discover available config updates (prints how to upgrade the engine) |
| `cco update --sync` | Interactively sync config from framework defaults |
| `cco docs [<topic>]` | Browse the bundled user docs offline, matched to your installed version |
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
