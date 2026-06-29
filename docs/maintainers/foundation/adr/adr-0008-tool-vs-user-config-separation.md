# ADR-0008: Tool vs User Config Separation (Updated — Managed Scope)

> **Status**: accepted

> **Forward note (decentralized-config ADR-0028, 2026-06-27):** the user-defaults home is now
> **`~/.cco/.claude/`** (the `global/` wrapper was flattened away) — read every `~/.cco/global/`
> below as `~/.cco/.claude/`. The `defaults/global/` source path is unchanged.

## Context

`global/` and `projects/_template/` were tracked in git. When users customized
their global settings or CLAUDE.md, they had a dirty git state and couldn't do
`git pull` to update the tool without merge conflicts. The original
`_sync_system_files()` mechanism always overwrote agents, skills, rules, and
settings.json — preventing user customization.

## Decision

Three-tier defaults leveraging Claude Code's native Managed level:

- `defaults/managed/` — framework infrastructure (hooks, env, deny rules,
  framework CLAUDE.md), baked into Docker image at `/etc/claude-code/`
  (Managed level — non-overridable)
- `defaults/global/` — user defaults (agents, skills, rules, settings.json,
  CLAUDE.md, mcp.json), copied once by `cco init` to the personal store
  `~/.cco/global/` (User level — fully customizable)
- `templates/project/base/` — default project template, scaffolded by `cco init` /
  `cco join` when setting up a repo's `.cco/`
- Personal store `~/.cco/` (git-versioned, gitignored secrets) holds `global/`,
  `packs/`, `templates/`; per-project config lives in each `<repo>/.cco/`;
  machine-local data is in the hidden XDG buckets (STATE/CACHE/DATA)

### Mechanism

- `cco init` copies user defaults to `~/.cco/global/` on first setup; `--force`
  resets user defaults
- Managed files are baked into the Docker image via
  `COPY defaults/managed/ /etc/claude-code/` in the Dockerfile — updated only via
  `cco build`
- `_migrate_to_managed()` handles one-time migration from the old
  `_sync_system_files()` layout: removes `.system-manifest`, splits old unified
  settings.json into managed + user
- No more `_sync_system_files()` — agents, skills, rules, and settings are
  user-owned after initial copy

## Rationale

- `git pull` always works cleanly — no conflicts with user customizations
- Framework infrastructure (hooks, env vars) is guaranteed to be active via Claude
  Code's Managed level
- Users can freely customize agents, skills, rules, and settings without losing
  changes on restart
- Clear ownership: managed = framework (non-overridable), user = preferences
  (customizable)
- Multi-PC support: clone the tool repo on any machine, run `cco init`, done

## Consequences

- First-time setup requires `cco init` before `cco start`
- Managed settings updates require `cco build` (baked in image)
- User defaults (agents, skills, rules, settings, CLAUDE.md) are user-owned and
  never overwritten
- `cco init --force` resets user defaults in `~/.cco/global/` to defaults/global/
  templates
- Migration from the old centralized `user-config/` layout is automatic (eager
  global via `cco update`; lazy per-project via `cco init --migrate`)
