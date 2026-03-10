# Documentation

## Where do I start?

| Profile | Start here |
|---|---|
| **New user** | [Getting Started](getting-started/) — overview → install → first project → concepts. Then run `cco start tutorial` for interactive guidance |
| **Configure a project** | [Project Setup](user-guides/project-setup.md) — repos, ports, packs, CLAUDE.md |
| **Share packs with my team** | [Sharing & Backup](user-guides/sharing.md) — vault, Config Repos, multi-machine sync |
| **Something isn't working** | [Troubleshooting](user-guides/troubleshooting.md) — Docker, auth, tmux, MCP, packs |
| **Looking for a command** | [CLI Reference](reference/cli.md) — all `cco` commands and flags |
| **Contribute to the project** | [Maintainer Guide](maintainer/README.md) — architecture, design docs, roadmap |

---

## Getting Started

Recommended path for new users — read in order.

| # | Document | Content |
|---|---|---|
| 1 | [overview.md](getting-started/overview.md) | What is claude-orchestrator, who is it for, how it works |
| 2 | [installation.md](getting-started/installation.md) | Prerequisites, setup, `cco init`, main commands |
| 3 | [first-project.md](getting-started/first-project.md) | Create and start your first project step-by-step |
| 4 | [concepts.md](getting-started/concepts.md) | Context hierarchy, knowledge packs, agent teams, memory, browser |

## User Guides

Operational guides for everyday use. Each guide covers one topic in depth.

| Document | Content |
|---|---|
| [project-setup.md](user-guides/project-setup.md) | Configure a project: repos, extra mounts, packs, CLAUDE.md, environment |
| [knowledge-packs.md](user-guides/knowledge-packs.md) | Create, configure, and manage reusable knowledge packs |
| [authentication.md](user-guides/authentication.md) | OAuth, API key, GitHub token, secrets management, Config Repo auth |
| [agent-teams.md](user-guides/agent-teams.md) | Agent teams: tmux mode, iTerm2 mode, copy-paste |
| [browser-automation.md](user-guides/browser-automation.md) | Browser automation via Chrome DevTools Protocol |
| [sharing.md](user-guides/sharing.md) | Vault backup, multi-machine sync, share packs and templates via Config Repos |
| [troubleshooting.md](user-guides/troubleshooting.md) | Common issues and solutions by category |

### Concepts & Best Practices

| Document | Content |
|---|---|
| [structured-agentic-development.md](user-guides/structured-agentic-development.md) | Why cco exists: structured development principles and how cco implements them |

### Advanced

| Document | Content |
|---|---|
| [advanced/subagents.md](user-guides/advanced/subagents.md) | Custom subagents: analyst, reviewer, and how to create your own |
| [advanced/custom-environment.md](user-guides/advanced/custom-environment.md) | Setup scripts, MCP packages, custom Docker images |

## Technical Reference

Precise specifications for CLI, configuration format, and context loading.

| Document | Content |
|---|---|
| [cli.md](reference/cli.md) | All `cco` commands, options, flags, and flows |
| [project-yaml.md](reference/project-yaml.md) | Complete `project.yml` field reference and pack.yml format |
| [context-hierarchy.md](reference/context-hierarchy.md) | Four-tier hierarchy, settings resolution, hooks, memory, loading lifecycle |

## Maintainer

Architecture, specifications, and roadmap for project contributors.

| Document | Content |
|---|---|
| [README.md](maintainer/README.md) | Contributor guide, code structure, documentation conventions |
| [architecture.md](maintainer/architecture.md) | Architectural decisions (ADR) and system design |
| [spec.md](maintainer/spec.md) | Functional and non-functional requirements |
| [roadmap.md](maintainer/roadmap.md) | Feature progress, planned sprints, declined proposals |

Design docs and analysis by area:

| Area | Documents |
|---|---|
| Scope hierarchy | [analysis](maintainer/scope-hierarchy/analysis.md), [design](maintainer/scope-hierarchy/design.md) |
| Authentication | [analysis](maintainer/auth/analysis.md), [design](maintainer/auth/design.md) |
| Knowledge packs | [design](maintainer/packs/design.md) |
| Environment | [analysis](maintainer/environment/analysis.md), [design](maintainer/environment/design.md) |
| Docker | [design](maintainer/docker/design.md) |
| Agent teams | [analysis](maintainer/agent-teams/analysis.md) |
| Worktree (future) | [analysis](maintainer/future/worktree/analysis.md), [design](maintainer/future/worktree/design.md) |
| Browser MCP | [analysis](maintainer/browser-mcp/analysis.md), [design](maintainer/browser-mcp/design.md) |
| Config Repo | [design](maintainer/config-repo/design.md), [sharing design](maintainer/config-repo/sharing-design.md) |
| Update system | [design](maintainer/update-system/design.md) |
| Reviews | [24-02-2026](maintainer/reviews/24-02-2026-architecture-review.md), [26-02-2026](maintainer/reviews/26-02-2026-progress-review.md), [sprint plan](maintainer/reviews/sprint-2-3-implementation-plan.md) |
