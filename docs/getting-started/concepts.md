# Key concepts

> The fundamental concepts of claude-orchestrator, explained briefly.

---

## Knowledge packs

Knowledge packs are reusable collections of documentation — client overviews, architecture specs, coding conventions, runbooks — that can be activated across multiple projects without copying files.

A pack is defined in `user-config/packs/<name>/pack.yml` with a reference to a documentation directory on the host. At session startup, `cco start` mounts the directory read-only and generates a list of available files. Claude reads them on-demand when relevant to the current task. Packs can also contribute skills, agents, and rules at the project level.

Activation in `project.yml`:

```yaml
packs:
  - my-client-knowledge
```

Knowledge packs are most valuable when:
- You work with the same client or codebase across multiple projects
- Your team shares architecture docs or conventions
- You want to activate documentation selectively per project without duplicating files

A typical pack might include: API overview, data model, coding conventions, deployment runbook — all mounted read-only, available to Claude on demand.

Learn more: [project-setup.md](../user-guides/project-setup.md) (Configure a Pack section).

---

## Framework Documentation (llms.txt)

The [llms.txt standard](https://llmstxt.org/) provides a way for frameworks to expose their documentation in LLM-friendly format. claude-orchestrator can install these files and serve them to Claude during sessions, ensuring code is written against current APIs.

Install with `cco llms install <url>`, reference in `project.yml` or `pack.yml` via `llms:`, and keep updated with `cco llms update --all`.

---

## Context hierarchy

claude-orchestrator organizes configuration across four levels, from highest to lowest priority:

| Level | Path in container | Contains | Modifiable? |
|---------|-------------------|---------------|---------------|
| **Managed** | `/etc/claude-code/` | Hooks, environment variables, deny rules | No (baked in image) |
| **User** | `~/.claude/` | Preferences, agents, skills, rules | Yes |
| **Project** | `/workspace/.claude/` | Project-specific instructions and config | Yes |
| **Repo** | `/workspace/<repo>/.claude/` | Context for single repository | Yes (lives in repo) |

Higher levels take precedence. This means managed hooks are always active and cannot be disabled, while project settings override global settings. Each level automatically loads `CLAUDE.md`, `settings.json`, `rules/*.md`, and `agents/*.md` files present in its directory.

For the complete reference, see [context-hierarchy.md](../reference/context-hierarchy.md).

---

## Team sharing

claude-orchestrator makes Claude Code environments reproducible and shareable across a team.

A project is a directory (`projects/<name>/`) containing:
- `project.yml` — repos, ports, environment, packs to activate
- `.claude/CLAUDE.md` — instructions, conventions, workflow
- `.claude/rules/`, `.claude/agents/`, `.claude/skills/` — project-level tooling
- `setup.sh`, `mcp-packages.txt` — runtime setup

Commit this directory to a shared repository and every teammate runs `cco start <project>` to get the same environment: same repos mounted, same instructions, same rules and agents.

**What's shared (committable today):**
- Project repositories and mount paths
- `CLAUDE.md` (instructions, rules, workflow)
- Agents, skills, and rules at the project level
- Port mappings and environment variables

**What stays local (never commit):**
- `secrets.env` — credentials and tokens, per user
- `.cco/claude-state/` — session transcripts, per user

**Sharing packs and project templates (Config Repos):**
- Knowledge packs and project templates can be shared via git using Config Repos
- `cco pack install <url>` imports packs from any Config Repo
- `cco project install <url>` imports project templates
- `cco manifest refresh` generates a `manifest.yml` manifest to export your own packs and templates
- Push your `user-config/` to a remote with `cco vault push` to share your full configuration

**What stays local (user preferences):**
- Claude authentication (OAuth or API key)
- `~/.claude/settings.json` — user-level preferences

This makes claude-orchestrator useful not just as a personal productivity tool, but as a team-wide standard for how Claude interacts with your codebase.

Learn more: [Configuration Management guide](../user-guides/configuration-management.md).

---

## Auto memory

Each project has its own isolated memory directory (`projects/<name>/memory/`). Claude Code automatically saves notes and insights during sessions and reloads them in subsequent sessions.

The isolation ensures that information from one project doesn't "leak" into another. The `.cco/claude-state/` directory also contains session transcripts, necessary for the `/resume` command that allows you to resume a previous session even after a Docker image rebuild.

Learn more: [context-hierarchy.md](../reference/context-hierarchy.md) (Auto Memory section).

---

## Agent teams

Claude Code supports agent teams — multiple Claude instances working in parallel on different tasks, coordinated by a lead.

claude-orchestrator supports two display modes:

- **tmux** (default) — each teammate appears as a tmux pane inside the container. Works with any terminal, no host configuration needed.
- **iTerm2** (`--teammate-mode auto`) — uses native iTerm2 panes on macOS. Better UX but requires additional setup (Python API enabled, `it2` CLI on host).

The mode is configured in `user-config/global/.claude/settings.json` (`"teammateMode": "tmux"`) or via CLI flag (`--teammate-mode`).

Learn more: [agent-teams.md](../user-guides/agent-teams.md).

---

## Docker isolation

The Docker container is claude-orchestrator's isolation mechanism. Claude Code is launched with `--dangerously-skip-permissions`, which normally disables all security prompts. Inside the container this is safe because:

- Filesystem is isolated — Claude can only modify mounted repositories and container files
- Network is controlled — only explicitly mapped ports are reachable from the host
- Git feature branches provide an additional protection layer — every change is reversible
- Container is ephemeral (`--rm`) — everything not mounted is lost on exit

The only privileged access point is the Docker socket mounted from the host, which allows Claude to create sibling containers (e.g., postgres, redis) on the host Docker daemon.

Learn more: [architecture.md](../maintainer/architecture/architecture.md) (ADR-1: Docker as the Only Sandbox).

---

## Browser automation

Claude can control a real Chrome browser running on your host. The browser is visible on your screen while Claude navigates pages, clicks buttons, fills forms, takes screenshots, and reads content.

This is enabled per-project via `project.yml`:

```yaml
browser:
  enabled: true
```

Then launch Chrome with `cco chrome start` and start your session. Claude gains access to browser tools (navigate, click, fill, screenshot, and more) via the Chrome DevTools Protocol.

Learn more: [browser-automation.md](../user-guides/browser-automation.md).

---

## Skills and agents

**Skills** are user-invocable commands (e.g., `/analyze`, `/commit`, `/review`) that perform specific tasks with predefined instructions. Each skill is a directory with a `SKILL.md` file that defines its behavior and available tools.

**Agents** are specialized profiles (e.g., analyst, reviewer) that Claude can instantiate as subagents with specific models and permissions. They are defined as `.md` files in the `agents/` directory.

Both exist at three levels:

| Level | Skills | Agents |
|---------|-------|-------|
| Managed | `/etc/claude-code/.claude/skills/` (e.g., `/init-workspace`) | Not used |
| User | `~/.claude/skills/` (e.g., `/analyze`, `/design`, `/review`, `/commit`) | `~/.claude/agents/` |
| Project | `/workspace/.claude/skills/` | `/workspace/.claude/agents/` |

Knowledge packs can add skills and agents at the project level.

Learn more: [context-hierarchy.md](../reference/context-hierarchy.md) (Skills and Subagents sections).

---

## Next steps

- [Your first project](first-project.md) — step-by-step tutorial
- [Project setup](../user-guides/project-setup.md) — advanced configuration guide
- [CLI reference](../reference/cli.md) — all available commands
