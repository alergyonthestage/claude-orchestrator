# Contributor Guide

This section contains the internal technical documentation of claude-orchestrator, intended for those developing or maintaining the project. Here you find design docs, technical analyses, architectural reviews, and implementation specifications.

---

## Functional Areas Map

Each area of the project has one or both types of document:

- **Design doc** — describes how a component is (or will be) built: architecture, decisions, flows, interfaces
- **Analysis doc** — technical investigation: options evaluated, constraints, recommendations

| Area | Design | Analysis |
|------|--------|----------|
| Scope & Context Hierarchy | [scope-hierarchy/design.md](scope-hierarchy/design.md) | [scope-hierarchy/analysis.md](scope-hierarchy/analysis.md) |
| Authentication & Secrets | [auth/design.md](auth/design.md) | [auth/analysis.md](auth/analysis.md) |
| Environment Extensibility | [environment/design.md](environment/design.md) | [environment/analysis.md](environment/analysis.md) |
| Docker Infrastructure | [docker/design.md](docker/design.md) | — |
| Agent Teams | — | [agent-teams/analysis.md](agent-teams/analysis.md) |
| Knowledge Packs | [packs/design.md](packs/design.md) | — |
| Git Worktree Isolation | [future/worktree/design.md](future/worktree/design.md) | [future/worktree/analysis.md](future/worktree/analysis.md) |
| Browser MCP | [browser-mcp/design.md](browser-mcp/design.md) | [browser-mcp/analysis.md](browser-mcp/analysis.md) |
| Update System | [update-system/design.md](update-system/design.md) | — |

---

## Core Documents

These three documents form the core of project documentation:

- [architecture.md](architecture.md) — ADR (Architecture Decision Records), system diagrams, data flows, and security considerations
- [spec.md](spec.md) — functional and non-functional requirements specification
- [roadmap.md](roadmap.md) — development plan, priorities, and feature progress

---

## Reviews

The [reviews/](reviews/) directory contains architectural and progress reviews conducted during development. Each review documents the project state at a certain date, decisions made, and agreed next steps.

---

## Documentation Organization

Maintainer documentation follows two conventions:

1. **Design doc** (`<area>/design.md`) — describe how something is built or will be built. They contain: overview, architecture, flows, implementation decisions, interfaces, edge cases. They are the primary reference for implementers.

2. **Analysis doc** (`<area>/analysis.md`) — document technical investigations. They contain: problem analyzed, options considered with pros/cons, identified constraints, final recommendation. They are the reference for understanding *why* a certain direction was chosen.

Areas in `future/` concern features not yet implemented. Design docs in this directory are approved proposals not yet realized.
