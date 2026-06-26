# ADR-0003: Four-Tier Context Hierarchy (Updated — Managed Scope)

> **Status**: accepted

## Context

Claude Code has a fixed precedence for settings and memory. We need to map our
config to it. Claude Code's Managed level (`/etc/claude-code/`) provides
non-overridable configuration.

## Decision

Map orchestrator config to Claude Code's full native hierarchy:

| Orchestrator Layer | Container Path | Claude Code Scope | Loaded | Overridable? |
|---|---|---|---|---|
| `defaults/managed/` | `/etc/claude-code/` | Managed | Always at launch | No |
| `~/.cco/global/.claude/` | `~/.claude/` | User-level | Always at launch | Yes |
| invoking repo's `<repo>/.cco/claude/` | `/workspace/.claude/` | Project-level | Always at launch | Yes |
| (repo's own `<repo>/.claude/`) | `/workspace/<repo>/.claude/` | Nested | On-demand | Yes |

## Rationale

- Exact match with Claude Code's resolution order: managed → user → project → nested
- Managed level guarantees framework hooks and settings are always active
- Settings precedence works correctly: managed > user; project overrides user
- No hacks, symlinks, or custom scripts needed

## Consequences

- Framework infrastructure (hooks, env, deny rules) is in managed — always active,
  non-overridable
- User preferences (agents, skills, rules, settings) are in user level — fully
  customizable
- Repo-level `.claude/` files stay in the actual repos (not duplicated in
  orchestrator)
- The `~/.cco/global/.claude/` directory must NOT contain project-specific data
