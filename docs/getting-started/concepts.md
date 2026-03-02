# Key concepts

> The fundamental concepts of claude-orchestrator, explained briefly.

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

## Knowledge packs

Knowledge packs are reusable collections of documentation (conventions, business overview, guidelines) that can be activated across multiple projects without copying files.

A pack is defined in `global/packs/<name>/pack.yml` with a reference to a documentation directory on the host. At session startup, `cco start` mounts the directory read-only and generates a list of available files. Claude reads them on-demand when relevant to the current task. Packs can also contribute skills, agents, and rules at the project level.

Activation in `project.yml`:

```yaml
packs:
  - my-client-knowledge
```

Learn more: [project-setup.md](../user-guides/project-setup.md) (Configure a Pack section).

---

## Agent teams

Claude Code supports agent teams — multiple Claude instances working in parallel on different tasks, coordinated by a lead.

claude-orchestrator supports two display modes:

- **tmux** (default) — each teammate appears as a tmux pane inside the container. Works with any terminal, no host configuration needed.
- **iTerm2** (`--teammate-mode auto`) — uses native iTerm2 panes on macOS. Better UX but requires additional setup (Python API enabled, `it2` CLI on host).

The mode is configured in `global/.claude/settings.json` (`"teammateMode": "tmux"`) or via CLI flag (`--teammate-mode`).

Learn more: [agent-teams.md](../user-guides/agent-teams.md).

---

## Docker isolation

The Docker container is claude-orchestrator's isolation mechanism. Claude Code is launched with `--dangerously-skip-permissions`, which normally disables all security prompts. Inside the container this is safe because:

- Filesystem is isolated — Claude can only modify mounted repositories and container files
- Network is controlled — only explicitly mapped ports are reachable from the host
- Git feature branches provide an additional protection layer — every change is reversible
- Container is ephemeral (`--rm`) — everything not mounted is lost on exit

The only privileged access point is the Docker socket mounted from the host, which allows Claude to create sibling containers (e.g., postgres, redis) on the host Docker daemon.

Learn more: [architecture.md](../maintainer/architecture.md) (ADR-1: Docker as the Only Sandbox).

---

## Auto memory

Each project has its own isolated memory directory (`projects/<name>/claude-state/memory/`). Claude Code automatically saves notes and insights during sessions and reloads them in subsequent sessions.

The isolation ensures that information from one project doesn't "leak" into another. The `claude-state/` directory also contains session transcripts, necessary for the `/resume` command that allows you to resume a previous session even after a Docker image rebuild.

Learn more: [context-hierarchy.md](../reference/context-hierarchy.md) (Auto Memory section).

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
