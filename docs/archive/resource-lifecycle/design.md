# Resource Lifecycle — Design: .cco/ Directory Structure

> Framework state storage layout and changelog notification model.
>
> Date: 2026-03-15 (Sprint 8, migration 009)
> Status: Implemented
> Scope: Architecture (user-config layout) + Module (changelog system)
>
> Related: [Resource Lifecycle Analysis](analysis.md) — file policies,
> authorship models, template awareness

---

## Table of Contents

1. [Context](#1-context)
2. [.cco/ Directory Structure](#2-cco-directory-structure)
3. [Design Decisions](#3-design-decisions)
4. [Path Resolution Helpers](#4-path-resolution-helpers)
5. [Vault Integration](#5-vault-integration)
6. [Docker Compose Invocation](#6-docker-compose-invocation)
7. [Dry-Run Behavior](#7-dry-run-behavior)
8. [Changelog Dual-Tracker](#8-changelog-dual-tracker)
9. [Migration Strategy](#9-migration-strategy)
10. [Cross-References](#10-cross-references)

---

## 1. Context

### 1.1 Problem: User-Config Clutter

Framework-managed files (`.cco-meta`, `.cco-base/`, `.managed/`, `.cco-remotes`,
`.cco-source`, generated `docker-compose.yml`) were mixed with user-editable
files in the same directories. Users could not distinguish what they own from
what the framework manages.

This also hinders the future distribution model where `cco` is installed as a
global package (npm/github) with `CCO_USER_CONFIG_DIR=~/.cco-config` — users
would see framework internals in their personal config directory.

### 1.2 File Inventory (Pre-Consolidation)

**Framework-managed files** scattered across user-config:

| File | Location | Purpose | Vault status |
|------|----------|---------|-------------|
| `.cco-meta` | `global/.claude/`, `projects/*/` | Version tracking, manifest checksums | Gitignored |
| `.cco-base/` | `global/.claude/`, `projects/*/` | 3-way merge ancestor snapshot | **Tracked** |
| `.managed/` | `projects/*/` | Runtime MCPs (browser, GitHub, policy) | Gitignored |
| `docker-compose.yml` | `projects/*/` | Generated from project.yml | Gitignored |
| `claude-state/` | `projects/*/` | Session transcripts for /resume | Gitignored |
| `.tmp/` | `projects/*/` | Dry-run dump artifacts (opt-in) | Gitignored |
| `.pack-manifest` | `projects/*/.claude/` | Legacy pack tracking (pre-ADR-14) | Gitignored |
| `.cco-remotes` | `user-config/` root | Remote registry + auth tokens | Gitignored |
| `.cco-source` | `packs/*/` | Pack origin reference | **Tracked** |
| `.cco-install-tmp/` | `packs/*/` | Temporary pack install files | Gitignored |

**User-editable files** (remain at project root after consolidation):

| File | Location | Purpose |
|------|----------|---------|
| `CLAUDE.md`, `settings.json` | `global/.claude/` | Global Claude config |
| `rules/`, `agents/`, `skills/` | `global/.claude/` | Global definitions |
| `project.yml` | `projects/*/` | Project configuration |
| `.claude/` | `projects/*/` | Project-level Claude config |
| `setup.sh`, `mcp-packages.txt` | `projects/*/` | Project setup |
| `memory/` | `projects/*/` | Auto memory (vault-tracked) |
| `secrets.env` | `projects/*/` | Project secrets (gitignored) |
| Pack content files | `packs/*/` | Knowledge pack content |
| `manifest.yml` | `user-config/` root | Sharing manifest |

### 1.3 Options Evaluated

| Option | Description | Pro | Contra | Verdict |
|--------|------------|-----|--------|---------|
| **A** | **`.cco/` per scope level** | **Locality, simple vault rules** | Multiple .cco/ dirs | **Selected** |
| B | Single top-level `.cco/` with mirror | One hidden dir | Duplicated tree, complex paths | Rejected |
| C | Separate state directory (`CCO_STATE_DIR`) | Total separation | Two dirs to manage, vault complexity | Rejected |

### 1.4 Changelog Bug (Co-Shipped Fix)

`cco update` shows a "What's new" summary and suggests `cco update --news` for
details. Both modes updated the same `last_seen_changelog` tracker, so discovery
marked entries as "read" before the user could see the details via `--news`.
The dual-tracker fix was shipped in the same migration cycle (see [section 8](#8-changelog-dual-tracker)).

---

## 2. .cco/ Directory Structure

```
user-config/
├── .cco/                               # Top-level framework state
│   └── remotes                         # Remote registry (was .cco-remotes)
├── .vault-profile                      # Vault profile config (unchanged)
├── manifest.yml                        # User sharing manifest (unchanged)
├── .gitignore                          # Vault ignore rules (updated)
│
├── global/.claude/
│   ├── CLAUDE.md                       # User config
│   ├── settings.json                   # User config
│   ├── rules/, agents/, skills/        # User definitions
│   └── .cco/                           # Framework state
│       ├── meta                        # Was .cco-meta
│       └── base/                       # Was .cco-base/ (vault-tracked)
│
├── projects/<name>/
│   ├── project.yml                     # User config
│   ├── .claude/                        # User Claude config
│   ├── setup.sh, mcp-packages.txt      # User setup
│   ├── memory/                         # User memory (vault-tracked)
│   ├── secrets.env                     # User secrets (gitignored)
│   └── .cco/                           # Framework state
│       ├── meta                        # Was .cco-meta
│       ├── base/                       # Was .cco-base/ (vault-tracked)
│       ├── managed/                    # Was .managed/
│       ├── docker-compose.yml          # Was projects/*/docker-compose.yml
│       └── claude-state/               # Was projects/*/claude-state/ (gitignored)
│
├── packs/<name>/
│   ├── (pack content files)            # User content
│   └── .cco/                           # Framework state
│       ├── source                      # Was .cco-source (vault-tracked)
│       └── install-tmp/                # Was .cco-install-tmp/
│
└── templates/                          # User templates (unchanged)
```

**Principle**: user-editable files remain visible at the project/pack root.
Framework-managed state is hidden inside `.cco/`. Users can safely ignore
`.cco/` directories.

---

## 3. Design Decisions

**D1: Per-scope `.cco/` (Option A).**
State stays near its context. No mirrored directory tree. Each scope level
(top-level, global, project, pack) has its own `.cco/`.

**D2: Helper functions for all framework paths.**
Single source of truth for path resolution (`lib/paths.sh`). Enables future
layout changes without touching business logic.

**D3: `docker-compose.yml` moves inside `.cco/`.**
It is generated, not user-editable. Uses `docker compose --project-directory`
flag to preserve relative path resolution (see [section 6](#6-docker-compose-invocation)).

**D4: `.cco/base/` and `.cco/source` remain vault-tracked.**
Required for 3-way merge and pack update workflows. Vault `.gitignore`
selectively ignores other `.cco/` contents.

**D5: `.vault-profile` stays at user-config root (not moved).**
Reasons: (a) it is the vault branching root file, included explicitly in sync
paths; (b) it is informative to users (shows active profile); (c) moving it
into `.cco/` would require selective vault tracking at top level for minimal
benefit.

**D6: Pack migration included in same cycle.**
`.cco-source` had 24 references in `cmd-pack.sh`. Leaving packs unconsolidated
while migrating everything else would be inconsistent. The global migration
iterates `$PACKS_DIR/*/` directly.

**D7: `claude-state/` moves inside `.cco/`.**
Session transcripts are transparent to the user — managed entirely by Claude
Code for `/resume` functionality. Moving them inside `.cco/` keeps the project
root clean. Volume mount paths in generated compose change only on the host
side:
```yaml
# Before:
- ./claude-state:/home/claude/.claude/projects/-workspace
# After:
- ./.cco/claude-state:/home/claude/.claude/projects/-workspace
```
The `memory/` child mount stays unchanged:
```yaml
- ./memory:/home/claude/.claude/projects/-workspace/memory
```

**D8: `--dry-run` uses ephemeral staging; `.tmp/` removed from `.cco/`.**
`--dry-run` generates artifacts in a system temp directory (`mktemp -d`), shows
the recap in the terminal, then auto-cleans. For maintainer/debugging use cases,
`--dry-run --dump` writes to `$project_dir/.tmp/` (outside `.cco/`, for user
inspection). `cco start` (without `--dry-run`) auto-cleans `.tmp/` if present.

---

## 4. Path Resolution Helpers

`lib/paths.sh` provides a single source of truth. Each helper uses
`_cco_resolve_path()` which checks the new path first, falls back to the old
path for backward compatibility during migration rollout:

```bash
# ── Top-level ────────────────────────────────────────────────────────
_cco_remotes_file()    # → $USER_CONFIG_DIR/.cco/remotes

# ── Global scope ─────────────────────────────────────────────────────
_cco_global_meta()     # → $GLOBAL_DIR/.claude/.cco/meta
_cco_global_base_dir() # → $GLOBAL_DIR/.claude/.cco/base

# ── Project scope ($1 = project_dir) ────────────────────────────────
_cco_project_meta()          # → $1/.cco/meta
_cco_project_base_dir()      # → $1/.cco/base
_cco_project_managed()       # → $1/.cco/managed
_cco_project_compose()       # → $1/.cco/docker-compose.yml
_cco_project_claude_state()  # → $1/.cco/claude-state
_cco_project_source()        # → $1/.cco/source
_cco_project_pack_manifest() # → $1/.claude/.cco/pack-manifest

# ── Pack scope ($1 = pack_dir) ──────────────────────────────────────
_cco_pack_source()       # → $1/.cco/source
_cco_pack_install_tmp()  # → $1/.cco/install-tmp
```

All `lib/` modules use these helpers instead of hardcoded paths. Writes always
go to the new `.cco/` paths; reads try new first, then old (dual-read fallback).

---

## 5. Vault Integration

### 5.1 Vault .gitignore (Target State)

```gitignore
# Secrets — never committed
secrets.env
*.env
.credentials.json
*.key
*.pem

# Framework state inside .cco/ — selective tracking
# .cco/base/ and packs/.cco/source are NOT listed (vault-tracked)
.cco/remotes
global/.claude/.cco/meta
projects/*/.cco/meta
projects/*/.cco/managed/
projects/*/.cco/docker-compose.yml
projects/*/.cco/claude-state/
projects/*/.claude/.cco/pack-manifest
packs/*/.cco/install-tmp/

# Dry-run dump artifacts (outside .cco/, user-inspectable)
projects/*/.tmp/

# Global session state
global/claude-state/

# Project auxiliary data
projects/*/rag-data/
```

### 5.2 What Remains Vault-Tracked

- `global/.claude/.cco/base/` — merge ancestors for global config
- `projects/*/.cco/base/` — merge ancestors for project config
- `packs/*/.cco/source` — pack origin metadata

These are required for 3-way merge (base) and pack update (source) workflows.

---

## 6. Docker Compose Invocation

With the compose file inside `.cco/`, the `--project-directory` flag ensures
all relative paths resolve correctly:

```bash
# Before:
docker compose -f "$compose_file" run --rm --service-ports ... claude

# After:
docker compose -f "$compose_file" --project-directory "$project_dir" run --rm --service-ports ... claude
```

Volume path changes in generated compose:
```yaml
# Before:
- ./.managed:/workspace/.managed:ro
- ./claude-state:/home/claude/.claude/projects/-workspace

# After:
- ./.cco/managed:/workspace/.managed:ro
- ./.cco/claude-state:/home/claude/.claude/projects/-workspace
```

The container-side mount path (`/workspace/.managed`) is **intentionally
preserved unchanged**. `config/entrypoint.sh` references `/workspace/.managed`
in three places (MCP file discovery, browser.json merge). Since the
container-side path does not change, **`entrypoint.sh` requires no
modifications**.

The `memory/` child mount stays unchanged:
```yaml
- ./memory:/home/claude/.claude/projects/-workspace/memory
```

### Files Not Affected

- **`config/entrypoint.sh`**: Uses container-side paths (`/workspace/.managed`)
  which are unchanged.
- **`lib/cmd-new.sh`**: Generates its own `docker-compose.yml` for temporary
  sessions (`cco new --repo`). These are written to `$tmp_dir/` outside
  user-config. No changes needed.

---

## 7. Dry-Run Behavior

- **`--dry-run`** (default): Generates artifacts in a system temp directory
  (`mktemp -d`), shows the recap in the terminal, then **auto-deletes** the
  temp dir. No persistent files left behind.

- **`--dry-run --dump`**: Generates artifacts in `$project_dir/.tmp/` (outside
  `.cco/`, for user inspection). Persists until cleaned.

- **`cco start`** (without `--dry-run`): Auto-cleans `$project_dir/.tmp/` if
  it exists. Starting a session implies the dry-run output was reviewed.

- **`cco clean --tmp`**: Available for explicit cleanup.

The staging tree inside `.tmp/` mirrors the project layout using path helpers,
so generated files use `.cco/managed/`, `.cco/docker-compose.yml`, etc.
regardless of whether staging is ephemeral or persistent.

---

## 8. Changelog Dual-Tracker

### 8.1 Problem

Both `cco update` (discovery) and `cco update --news` (details) updated
`last_seen_changelog`. Discovery marked entries as "read" before the user
could see them via `--news`.

### 8.2 Solution

Two fields in `.cco/meta`:

```yaml
last_seen_changelog: 2    # Updated by discovery + news
last_read_changelog: 2    # Updated by news only
```

| Field | Updated by | Purpose |
|-------|-----------|---------|
| `last_seen_changelog` | discovery + news | Prevents repeated summary in `cco update` |
| `last_read_changelog` | news only | Tracks what user has read in detail |

### 8.3 Behavioral Rules

**Discovery mode** (`cco update`):
1. Show entries where `id > last_seen_changelog`
2. Update `last_seen_changelog` to latest id
3. Show "Run `--news` for details" hint **only if** `last_read_changelog < latest_id`

**News mode** (`cco update --news`):
1. Show entries where `id > last_read_changelog`
2. Update **both** `last_read_changelog` AND `last_seen_changelog` to latest id

### 8.4 Scenario Matrix

| Scenario | Discovery shows? | Hint shown? | News shows? |
|----------|-----------------|-------------|-------------|
| Fresh install, new entries exist | Yes (summary) | Yes | Yes (details) |
| After discovery only | No (already seen) | Yes (not read) | Yes (details) |
| After news only | No (news updated both) | No | No (already read) |
| After discovery then news | No | No | Yes (then no after read) |
| After news then discovery | No | No | No |
| New entries after both read | Yes (new ones) | Yes | Yes (new ones) |

### 8.5 Backward Compatibility

If `last_read_changelog` is missing from `.cco/meta` (pre-migration), the
reader function returns 0. On next `cco update` or `--news`, the field is
written automatically. No migration required.

---

## 9. Migration Strategy

### 9.1 Overview

Two migration scripts (`migrations/global/009_cco_dir_consolidation.sh` and
`migrations/project/009_cco_dir_consolidation.sh`), both run automatically
via `cco update`.

### 9.2 Idempotency

Both migrations use **guarded moves**: check that source exists AND target
does NOT exist before moving. This prevents `mv` of a directory onto an
existing directory (which would nest it inside, causing data corruption).

```bash
# Safe directory move pattern:
if [[ -d "$src" && ! -d "$dst" ]]; then
    mv "$src" "$dst"
fi
```

This handles:
- **First run**: source exists, target does not — move
- **Re-run**: source gone, target exists — no-op
- **Partial state**: source AND target both exist — skip (no data loss)

### 9.3 Global Migration (009)

Moves:
- `global/.claude/.cco-meta` → `global/.claude/.cco/meta`
- `global/.claude/.cco-base/` → `global/.claude/.cco/base/`
- `.cco-remotes` → `.cco/remotes`
- Each `packs/*/.cco-source` → `packs/*/.cco/source`
- Each `packs/*/.cco-install-tmp/` → `packs/*/.cco/install-tmp/`
- Updates vault `.gitignore` patterns

### 9.4 Project Migration (009)

Moves:
- `.cco-meta` → `.cco/meta`
- `.cco-base/` → `.cco/base/`
- `.managed/` → `.cco/managed/`
- `docker-compose.yml` → `.cco/docker-compose.yml`
- `claude-state/` → `.cco/claude-state/`
- `.claude/.pack-manifest` → `.claude/.cco/pack-manifest`
- Cleans stale `.tmp/` (now ephemeral)

### 9.5 Running-Session Safety

If a session is running during migration:
- Docker resolves volume mounts at container start time — the running container
  is unaffected.
- On Linux, `mv` on the same filesystem preserves the inode — bind mounts
  remain valid.
- Migration emits a warning if project containers are detected:
  `"Running sessions detected. Restart them after migration."`

### 9.6 Vault .gitignore Migration

The global migration replaces old gitignore patterns with new ones:

| Old pattern | New pattern |
|------------|-------------|
| `projects/*/.managed/` | `projects/*/.cco/managed/` |
| `projects/*/.cco-meta` | `projects/*/.cco/meta` |
| `projects/*/docker-compose.yml` | `projects/*/.cco/docker-compose.yml` |
| `projects/*/claude-state/` | `projects/*/.cco/claude-state/` |
| `packs/*/.cco-install-tmp/` | `packs/*/.cco/install-tmp/` |
| `.cco-remotes` | `.cco/remotes` |
| `projects/*/.pack-manifest` | `projects/*/.claude/.cco/pack-manifest` |
| (added) | `global/.claude/.cco/meta` |

---

## 10. Cross-References

| Topic | Document |
|-------|----------|
| File policies and update model | [Resource Lifecycle Analysis](analysis.md) |
| Update system mechanics | `../update-system/design.md` |
| Vault sync and profiles | `../vault/design.md` |
| Sharing and publish/install | `../sharing/design.md` |
| FI-7 publish/install sync | `../sharing/publish-install-sync-design.md` |
| Path helpers implementation | `lib/paths.sh` |
| Migration scripts | `migrations/global/009_cco_dir_consolidation.sh`, `migrations/project/009_cco_dir_consolidation.sh` |
