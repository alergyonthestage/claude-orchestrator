# Contributor Guide

This section contains the internal technical documentation of claude-orchestrator, intended for those developing or maintaining the project. Here you find design docs, technical analyses, architectural reviews, and implementation specifications.

---

## Directory Structure

Documentation is organized into five macro-areas by domain:

```
maintainer/
├── architecture/       Core system design, ADRs, requirements, security
├── configuration/      Config hierarchy, packs, sharing, environment
├── integration/        Docker, auth, browser MCP, agent teams
├── features/           Sprint-specific feature designs (templates, vault, worktree...)
└── decisions/          Roadmap, protocols, historical reviews
```

---

## Architecture — Core System Design

Foundation documents and architectural decisions.

- [architecture.md](architecture/architecture.md) — ADRs, system diagrams, data flows
- [spec.md](architecture/spec.md) — functional and non-functional requirements
- [security.md](architecture/security.md) — security review, threat model, hardening
- [testing.md](architecture/testing.md) — test strategy and coverage

---

## Configuration — Config Hierarchy & Sharing

Everything related to the four-tier configuration model, knowledge packs, and the Config Repo sharing system.

| Area | Design | Analysis |
|------|--------|----------|
| Scope & Context Hierarchy | [design](configuration/scope-hierarchy/design.md) | [analysis](configuration/scope-hierarchy/analysis.md) |
| Knowledge Packs | [design](configuration/packs/design.md) | — |
| Config Repo & Vault | [design](configuration/config-repo/design.md) | [analysis](configuration/config-repo/analysis.md) |
| Config Sharing | [design](configuration/config-repo/sharing-design.md) | [analysis](configuration/config-repo/sharing-analysis.md) |
| Environment Extensibility | [design](configuration/environment/design.md) | [analysis](configuration/environment/analysis.md) |

Additional: [implementation plan](configuration/config-repo/implementation-plan.md) (sharing)

---

## Integration — Infrastructure & External Services

Docker setup, authentication, browser automation, and agent team configuration.

| Area | Design | Analysis |
|------|--------|----------|
| Docker Infrastructure | [design](integration/docker/design.md) | — |
| Docker Security (Proxy) | [design](integration/docker-security/design.md) | [analysis](integration/docker-security/analysis.md) |
| Authentication & Secrets | [design](integration/auth/design.md) | [analysis](integration/auth/analysis.md) |
| Browser MCP | [design](integration/browser-mcp/design.md) | [analysis](integration/browser-mcp/analysis.md) |
| Agent Teams | — | [analysis](integration/agent-teams/analysis.md) |

---

## Features — Sprint Designs

Design and analysis documents for specific sprint features. Includes both completed and planned work.

| Feature | Design | Analysis | Status |
|---------|--------|----------|--------|
| Defaults & Templates (5b) | [design](features/defaults-templates-update/design.md) | [analysis](features/defaults-templates-update/analysis-v2.md) | Completed |
| Tutorial Project (5) | [design](features/tutorial-project/design.md) | [analysis](features/tutorial-project/analysis.md) | Completed |
| Update System | [design](features/update-system/design.md) | — | Completed |
| Multi-PC Vault (7) | — | [analysis](features/vault-multipc/analysis.md) | Planned |
| Git Worktree Isolation (10) | [design](features/worktree/design.md) | [analysis](features/worktree/analysis.md) | Planned |

---

## Decisions — Roadmap, Protocols & Reviews

Project-level decisions, planning, and historical snapshots.

- [roadmap.md](decisions/roadmap.md) — development plan, priorities, and feature progress
- [managed-integrations.md](decisions/managed-integrations.md) — 8-step protocol for adding new managed MCP servers

### Reviews

The [reviews/](decisions/reviews/) directory contains architectural and progress reviews:

- [24-02-2026](decisions/reviews/24-02-2026-architecture-review.md) — Architecture review
- [26-02-2026](decisions/reviews/26-02-2026-progress-review.md) — Progress review
- [Sprint 2-3 plan](decisions/reviews/sprint-2-3-implementation-plan.md) — Implementation plan

---

## Documentation Conventions

Maintainer documentation follows two conventions:

1. **Design doc** (`<area>/design.md`) — describes how something is built or will be built: overview, architecture, flows, implementation decisions, interfaces, edge cases. Primary reference for implementers.

2. **Analysis doc** (`<area>/analysis.md`) — documents technical investigations: problem analyzed, options considered with pros/cons, identified constraints, final recommendation. Reference for understanding *why* a certain direction was chosen.
