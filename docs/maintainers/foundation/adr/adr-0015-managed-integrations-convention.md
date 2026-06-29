# ADR-0015: Managed Integrations — `.cco/managed/` Convention

> **Status**: accepted
> **Date**: 2026-03-03

> Note: this decision was originally embedded in `architecture.md` as an unnumbered
> "ADR section 6". It is captured here as the next free number in the foundation
> ADR stream (after ADR-0014). The maintainer protocol/guide that builds on it
> lives at
> [managed-integrations.md](../../integration/guides/managed-integrations.md).

## Context

claude-orchestrator provides integrations that the framework controls (Browser MCP,
future: GitHub MCP, RAG). These integrations generate config files at runtime and
were previously mixed into the project root alongside user files (`browser-mcp.json`,
`.browser-port`). This created ambiguity about what is user-owned vs
framework-managed.

## Decision

Framework-generated integration files are written to the machine-local CACHE
(`<cache>/cco/projects/<id>/managed/`) and mounted read-only at
`/workspace/.managed/` in the container. User config files (`mcp.json`, `claude/`,
`project.yml`) live in the committed `<repo>/.cco/`. The entrypoint merges all
`*.json` files in `/workspace/.managed/` into `~/.claude.json` via a generic loop —
adding a new integration requires no entrypoint change.

## Rationale

- Clear separation: generated managed files are framework-owned and live in CACHE,
  never in the committed `<repo>/.cco/` tree (so they never pollute the truthful
  `git diff` or the sync)
- Users cannot accidentally edit managed config (CACHE is hidden, mounted `:ro`)
- New integrations follow a documented 8-step protocol without modifying existing
  code
- The generic entrypoint loop means zero entrypoint changes per new integration

## Consequences

- Generated managed files are regenerable CACHE (never committed)
- `cco stop <project>` cleans up the generated managed files (not the directory
  itself)
- `cco chrome` reads the effective port from
  `<cache>/cco/projects/<id>/managed/.browser-port`
- Conflict warning in entrypoint if a managed server key overrides a
  user-configured one

## See also

- [managed-integrations.md](../../integration/guides/managed-integrations.md) —
  maintainer protocol & guide for adding new managed integrations
