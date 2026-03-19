# Contributor Guide

This section contains the internal technical documentation of claude-orchestrator, intended for those developing or maintaining the project. Here you find design docs, technical analyses, architectural reviews, and implementation specifications.

---

## Directory Structure

Documentation is organized into six macro-areas by domain:

```
maintainer/
├── architecture/       Core system design, ADRs, requirements, security
├── configuration/      Config hierarchy, packs, sharing, update system, vault, environment
├── integration/        Docker, auth, browser MCP, agent teams, worktree
├── internal/          Internal resources (tutorial, future cco-develop)
├── decisions/          Roadmap, protocols, historical reviews
└── README.md           This file
```

---

## Architecture — Core System Design

Foundation documents and architectural decisions.

- [architecture.md](architecture/architecture.md) — ADRs, system diagrams, data flows
- [spec.md](architecture/spec.md) — functional and non-functional requirements
- [security.md](architecture/security.md) — security review, threat model, hardening
- [testing.md](architecture/testing.md) — test strategy and coverage

---

## Configuration — Config Lifecycle & Distribution

Everything related to the four-tier configuration model, knowledge packs, update system, vault, and sharing.

| Area | Design | Analysis | Status |
|------|--------|----------|--------|
| Scope & Context Hierarchy | [design](configuration/scope-hierarchy/design.md) | [analysis](configuration/scope-hierarchy/analysis.md) | Completed |
| Knowledge Packs | [design](configuration/packs/design.md) | — | Completed |
| Environment Extensibility | [design](configuration/environment/design.md) | [analysis](configuration/environment/analysis.md) | Completed |
| Sharing & Config Repo | [design](configuration/sharing/design.md) | [analysis](configuration/sharing/analysis.md) | Completed |
| Update System & Templates | [design](configuration/update-system/design.md) | [analysis](configuration/update-system/analysis.md) | Completed |
| Vault & Multi-PC Sync | [design](configuration/vault/design.md) | [analysis](configuration/vault/analysis.md) | Completed |

---

## Integration — Infrastructure & External Services

Docker setup, authentication, browser automation, agent teams, and git worktree isolation.

| Area | Design | Analysis | Status |
|------|--------|----------|--------|
| Docker Infrastructure | [design](integration/docker/design.md) | — | Completed |
| Docker Security (Proxy) | [design](integration/docker-security/design.md) | [analysis](integration/docker-security/analysis.md) | Phase A+B done |
| Authentication & Secrets | [design](integration/auth/design.md) | [analysis](integration/auth/analysis.md) | Completed |
| Browser MCP | [design](integration/browser-mcp/design.md) | [analysis](integration/browser-mcp/analysis.md) | Completed |
| Agent Teams | — | [analysis](integration/agent-teams/analysis.md) | Completed |
| Git Worktree Isolation | [design](integration/worktree/design.md) | [analysis](integration/worktree/analysis.md) | Planned (Sprint 10) |

---

## Internal — Framework-Internal Resources

Design and analysis documents for internal resources distributed with claude-orchestrator (learning, onboarding, development).

| Resource | Design | Analysis | Status |
|----------|--------|----------|--------|
| Tutorial Project | [design](internal/tutorial/design.md) | [analysis](internal/tutorial/analysis.md) | Completed (Sprint 5) |

Future: `cco-develop` template for framework maintainers.

---

## Decisions — Roadmap, Protocols & Reviews

Project-level decisions, planning, and historical snapshots.

- [roadmap.md](decisions/roadmap.md) — development plan, priorities, and feature progress
- [framework-improvements.md](decisions/framework-improvements.md) — framework improvement proposals and tracking
- [managed-integrations.md](decisions/managed-integrations.md) — 9-step protocol for adding new managed MCP servers

### Reviews

The [reviews/](decisions/reviews/) directory contains architectural and progress reviews:

- [24-02-2026](decisions/reviews/24-02-2026-architecture-review.md) — Architecture review
- [26-02-2026](decisions/reviews/26-02-2026-progress-review.md) — Progress review
- [Sprint 2-3 plan](decisions/reviews/sprint-2-3-implementation-plan.md) — Implementation plan
- [18-03-2026 comprehensive](decisions/reviews/18-03-2026-comprehensive-review.md) — Comprehensive review
- [18-03-2026 UX findings](decisions/reviews/18-03-2026-update-ux-findings.md) — Update UX findings
- [18-03-2026 messages audit](decisions/reviews/18-03-2026-update-ux-messages-audit.md) — Update UX messages audit

---

## Documentation Conventions

Maintainer documentation follows two conventions:

1. **Design doc** (`<area>/design.md`) — describes how something is built or will be built: overview, architecture, flows, implementation decisions, interfaces, edge cases. Primary reference for implementers.

2. **Analysis doc** (`<area>/analysis.md`) — documents technical investigations: problem analyzed, options considered with pros/cons, identified constraints, final recommendation. Reference for understanding *why* a certain direction was chosen.
