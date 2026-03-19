# Documentation

## Where do I start?

| Profile | Start here |
|---|---|
| **New user** | [Getting Started](getting-started/) — overview → install → first project → concepts. Then run `cco start tutorial` for interactive guidance |
| **Configure a project** | [Project Setup](user-guides/project-setup.md) — repos, ports, packs, CLAUDE.md |
| **Share packs with my team** | [Configuration Management](user-guides/configuration-management.md) — vault, Config Repos, sharing, updates |
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
| [configuration-management.md](user-guides/configuration-management.md) | Vault, profiles, Config Repos, sharing, publishing, installing, updates |
| [troubleshooting.md](user-guides/troubleshooting.md) | Common issues and solutions by category |
| [configuring-rules.md](user-guides/configuring-rules.md) | Writing and organizing Claude rules across scopes |
| [development-workflow.md](user-guides/development-workflow.md) | Structured development workflow with cco |

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
| [README.md](maintainer/README.md) | Contributor guide, documentation conventions |
| [architecture.md](maintainer/architecture/architecture.md) | Architectural decisions (ADR) and system design |
| [spec.md](maintainer/architecture/spec.md) | Functional and non-functional requirements |
| [roadmap.md](maintainer/decisions/roadmap.md) | Feature progress, planned sprints, declined proposals |

Design docs and analysis by area:

| Area | Documents |
|---|---|
| **Configuration** | |
| Scope hierarchy | [analysis](maintainer/configuration/scope-hierarchy/analysis.md), [design](maintainer/configuration/scope-hierarchy/design.md) |
| Knowledge packs | [design](maintainer/configuration/packs/design.md) |
| Environment | [analysis](maintainer/configuration/environment/analysis.md), [design](maintainer/configuration/environment/design.md) |
| Sharing & Config Repo | [analysis](maintainer/configuration/sharing/analysis.md), [design](maintainer/configuration/sharing/design.md) |
| Update System & Templates | [analysis](maintainer/configuration/update-system/analysis.md), [design](maintainer/configuration/update-system/design.md) |
| Vault & Multi-PC Sync | [analysis](maintainer/configuration/vault/analysis.md), [design](maintainer/configuration/vault/design.md) |
| **Integration** | |
| Docker | [design](maintainer/integration/docker/design.md) |
| Docker Security | [analysis](maintainer/integration/docker-security/analysis.md), [design](maintainer/integration/docker-security/design.md) |
| Authentication | [analysis](maintainer/integration/auth/analysis.md), [design](maintainer/integration/auth/design.md) |
| Browser MCP | [analysis](maintainer/integration/browser-mcp/analysis.md), [design](maintainer/integration/browser-mcp/design.md) |
| Agent teams | [analysis](maintainer/integration/agent-teams/analysis.md) |
| Worktree isolation | [analysis](maintainer/integration/worktree/analysis.md), [design](maintainer/integration/worktree/design.md) |
| **Internal** | |
| Tutorial Project | [analysis](maintainer/internal/tutorial/analysis.md), [design](maintainer/internal/tutorial/design.md) |
| **Decisions** | |
| Framework Improvements | [framework-improvements](maintainer/decisions/framework-improvements.md) |
| Managed Integrations | [protocol](maintainer/decisions/managed-integrations.md) |
| Reviews | [18-03-2026 comprehensive](maintainer/decisions/reviews/18-03-2026-comprehensive-review.md), [18-03-2026 UX findings](maintainer/decisions/reviews/18-03-2026-update-ux-findings.md), [18-03-2026 UX audit](maintainer/decisions/reviews/18-03-2026-update-ux-messages-audit.md), [24-02-2026](maintainer/decisions/reviews/24-02-2026-architecture-review.md), [26-02-2026](maintainer/decisions/reviews/26-02-2026-progress-review.md), [sprint plan](maintainer/decisions/reviews/sprint-2-3-implementation-plan.md) |
