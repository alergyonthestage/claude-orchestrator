# ADR-0009: Knowledge Packs — Copy vs Mount for Resources

> **Status**: superseded by [ADR-0014](./adr-0014-zero-duplication-pack-resource-delivery.md) (Zero-Duplication Pack Resource Delivery)

## Context

Knowledge Packs bundle documentation (knowledge), plus optional skills, agents, and
rules for project-level tooling. The knowledge files are large documents meant to
be read by Claude at runtime. Skills, agents, and rules are configuration files
that Claude Code expects at specific paths inside `.claude/`.

## Decision (original)

Use two different strategies for the two resource types:

- **Knowledge files** → mounted read-only as Docker volumes at
  `/workspace/.claude/packs/<name>/`
- **Skills, agents, rules** → copied into the project's `.claude/` at `cco start`
  time

## Why superseded

[ADR-0014](./adr-0014-zero-duplication-pack-resource-delivery.md) eliminates the
copy mechanism entirely. All pack resources (including skills, agents, and rules)
are now delivered via read-only Docker volume mounts. Individual file mounts (one
per rule/agent, one directory per skill) solve the Docker mount-shadowing problem
without physical copying. This eliminates `.pack-manifest`, stale copy risk, and
host filesystem pollution. See
[ADR-0014](./adr-0014-zero-duplication-pack-resource-delivery.md) for the current
design.
