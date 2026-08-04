# ADR-0014: Zero-Duplication Pack Resource Delivery

> **Status**: accepted
> **Date**: 2026-03-11

Supersedes [ADR-0009](./adr-0009-knowledge-packs-copy-vs-mount-for-resources.md)
(Knowledge Packs — Copy vs Mount for Resources).

## Context

Pack resources (knowledge, rules, agents, skills) were physically copied from the
packs store into each project's `.claude/` directory at `cco start` time. This
caused file duplication across projects, risk of stale/divergent copies, and host
filesystem pollution. The fundamental value proposition of packs is reuse without
copy-paste.

## Decision

Pack resources are delivered to containers via read-only Docker volume mounts in
the generated `docker-compose.yml`, never copied to project directories. Each
resource type maps to the appropriate mount strategy:

- Knowledge dirs: one directory mount per pack → `/workspace/.claude/packs/<name>:ro`
- Rules: one file mount per rule → `/workspace/.claude/rules/<file>.md:ro`
  (Claude Code requires flat files)
- Agents: one file mount per agent → `/workspace/.claude/agents/<file>.md:ro`
  (flat files)
- Skills: one directory mount per skill → `/workspace/.claude/skills/<name>:ro`

The `packs.md` index file remains generated into the project's `.claude/` as it is
project-specific (lists only packs referenced in that project's `project.yml`).

> **Update (ADR-0041 R1, 2026-07-01):** the standalone `packs.md` index is no longer
> generated. Its content was folded into the unified session-info surface
> `/workspace/.claude/workspace.yml` (as the `knowledge` + `llms` sections). The
> zero-duplication *mount* mechanism this ADR establishes is unchanged; only the
> index-delivery detail is superseded. See
> [ADR-0041](../../configuration/decentralized-config/decisions/0041-unified-session-info-surface.md).

## Consequences

- Zero file duplication: the pack source in `~/.cco/packs/` (or the optional
  project-local `<repo>/.cco/packs/`) is the single source of truth
- Pack updates are immediately visible on next `cco start` (no stale copies)
- Project `.claude/` directories contain only project-owned files
- `.pack-manifest` tracking mechanism is eliminated
- Mount count in docker-compose.yml increases (N mounts per pack instead of 1 copy
  operation), but compose is generated so verbosity is irrelevant
- Read-only mounts prevent accidental in-container edits to pack resources
