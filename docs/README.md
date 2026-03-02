# Documentation

## Where do I start?

| Profile | Path |
|---|---|
| **I'm new, where do I start?** | [getting-started/](getting-started/) — Overview → installation → first project → concepts |
| **I need to configure a project** | [user-guides/](user-guides/) — Project setup, knowledge packs, authentication, agent teams |
| **I have a problem** | [user-guides/troubleshooting.md](user-guides/troubleshooting.md) |
| **I'm looking for a specific command** | [reference/cli.md](reference/cli.md) |
| **I want to contribute** | [maintainer/README.md](maintainer/README.md) |

---

## Getting Started

Recommended path for beginners, read in order.

| Document | Content |
|---|---|
| [overview.md](getting-started/overview.md) | What is claude-orchestrator, what is it for, how does it fit |
| [installation.md](getting-started/installation.md) | Requirements, installation, `cco init` |
| [first-project.md](getting-started/first-project.md) | Create and start your first project step-by-step |
| [concepts.md](getting-started/concepts.md) | Context hierarchy, knowledge packs, agent teams, memory |

## User guides

Operational guides for everyday use.

| Document | Content |
|---|---|
| [project-setup.md](user-guides/project-setup.md) | Configure a project: repos, mounts, CLAUDE.md, project.yml |
| [knowledge-packs.md](user-guides/knowledge-packs.md) | Create and activate reusable knowledge packs |
| [agent-teams.md](user-guides/agent-teams.md) | Configure agent teams with tmux and iTerm2 |
| [authentication.md](user-guides/authentication.md) | OAuth, API key, GitHub token, secrets management |
| [browser-automation.md](user-guides/browser-automation.md) | Browser automation: setup, usage, troubleshooting |
| [troubleshooting.md](user-guides/troubleshooting.md) | Common issues and solutions |
| [advanced/subagents.md](user-guides/advanced/subagents.md) | Custom subagents (analyst, reviewer) |
| [advanced/custom-environment.md](user-guides/advanced/custom-environment.md) | Setup scripts, extra packages, custom images |

## Technical reference

Reference documentation for CLI, configuration, and architecture.

| Document | Content |
|---|---|
| [cli.md](reference/cli.md) | All `cco` commands, options, and flags |
| [project-yaml.md](reference/project-yaml.md) | Complete `project.yml` format |
| [context-hierarchy.md](reference/context-hierarchy.md) | Four-tier hierarchy, settings resolution, memory |

## Maintainer

Architecture, specifications, and roadmap for project contributors.

| Document | Content |
|---|---|
| [README.md](maintainer/README.md) | Contributor guide, code structure |
| [architecture.md](maintainer/architecture.md) | Architectural decisions (ADR) and system design |
| [spec.md](maintainer/spec.md) | Requirements specification |
| [roadmap.md](maintainer/roadmap.md) | Planned features and future improvements |

Design docs and analysis by area:

| Area | Documents |
|---|---|
| Scope hierarchy | [analysis](maintainer/scope-hierarchy/analysis.md), [design](maintainer/scope-hierarchy/design.md) |
| Authentication | [analysis](maintainer/auth/analysis.md), [design](maintainer/auth/design.md) |
| Knowledge packs | [design](maintainer/packs/design.md) |
| Environment | [analysis](maintainer/environment/analysis.md), [design](maintainer/environment/design.md) |
| Docker | [design](maintainer/docker/design.md) |
| Agent teams | [analysis](maintainer/agent-teams/analysis.md) |
| Worktree | [analysis](maintainer/future/worktree/analysis.md), [design](maintainer/future/worktree/design.md) |
| Browser MCP | [analysis](maintainer/browser-mcp/analysis.md), [design](maintainer/browser-mcp/design.md) |
| Update system | [design](maintainer/update-system/design.md) |
| Reviews | [24-02-2026](maintainer/reviews/24-02-2026-architecture-review.md), [26-02-2026](maintainer/reviews/26-02-2026-progress-review.md), [sprint plan](maintainer/reviews/sprint-2-3-implementation-plan.md) |
