# .cco/ Directory Consolidation & Changelog Dual-Tracker

**Status**: Implemented (Sprint 8, migration 009, 2026-03-15)
**Scope**: Module (update system) + Architecture (user-config layout)

> Two related improvements to user-config hygiene and the changelog notification system.
> Designed to be implemented together as they share the same migration cycle.

---

## Table of Contents

1. [Problem Statement](#1-problem-statement)
2. [Analysis: Changelog Bug](#2-analysis-changelog-bug)
3. [Analysis: User-Config Clutter](#3-analysis-user-config-clutter)
4. [Design: Changelog Dual-Tracker](#4-design-changelog-dual-tracker)
5. [Design: .cco/ Directory Consolidation](#5-design-cco-directory-consolidation)
6. [Migration Strategy](#6-migration-strategy)
7. [Impact Analysis](#7-impact-analysis)
8. [Implementation Plan](#8-implementation-plan)
9. [Test Plan](#9-test-plan)

---

## 1. Problem Statement

### 1.1 Changelog bug

`cco update` shows a "What's new" summary and suggests `cco update --news` for details.
When the user runs `--news`, it reports "No new features since last check." Both modes
update the same `last_seen_changelog` tracker, so discovery marks entries as "read" before
the user gets to see the details.

```
$ cco update
  ℹ What's new in cco:
  ℹ   + Vault profiles for multi-PC selective sync
  ℹ   + Memory is now vault-tracked, separated from claude-state
  ℹ   Run 'cco update --news' for details and examples.

$ cco update --news
  ✓ No new features since last check.    ← BUG
```

### 1.2 User-config clutter

Framework-managed files (`.cco-meta`, `.cco-base/`, `.managed/`, `.cco-remotes`,
`.cco-source`, generated `docker-compose.yml`) are mixed with user-editable files in
the same directories. Users cannot distinguish what they own vs what the framework manages.

This also hinders the future distribution model where `cco` is installed as a global
package (npm/github) with `CCO_USER_CONFIG_DIR=~/.cco-config` — users would see
framework internals in their personal config directory.

---

## 2. Analysis: Changelog Bug

### 2.1 Current architecture

- **Changelog source**: `changelog.yml` (repo root) — sequential entries with `id`, `date`,
  `title`, `description`
- **Tracking**: `last_seen_changelog` field in `global/.claude/.cco-meta`
- **Discovery mode** (`cco update`): `_show_changelog_summary()` shows entries where
  `id > last_seen_changelog`, displays one-line titles
- **News mode** (`cco update --news`): `_show_changelog_news()` shows entries where
  `id > last_seen_changelog`, displays full details

### 2.2 Root cause

In `lib/update.sh:1193-1218`, `_update_changelog_notifications()` updates
`last_seen_changelog` for **both** modes:

```bash
# Update last_seen_changelog in .cco-meta (if not dry-run)
if [[ "$dry_run" != "true" && -f "$meta_file" ]]; then
    local latest_id
    latest_id=$(_latest_changelog_id)
    if [[ "$latest_id" -gt "$last_seen" ]]; then
        _sed_i "$meta_file" "^last_seen_changelog: .*" "last_seen_changelog: $latest_id"
    fi
fi
```

After discovery runs, `last_seen_changelog` is already at `latest_id`. When `--news`
runs next, `_show_changelog_news()` finds no entries with `id > last_seen_changelog`.

### 2.3 Options evaluated

| Option | Description | Pro | Contra | Verdict |
|--------|------------|-----|--------|---------|
| A | Only update in news mode | Simple | Spam if user ignores --news | Rejected |
| B | Two generic trackers | Precise | Unclear semantics | Rejected |
| C | Discovery updates after N views | Anti-spam | Magic number, arbitrary | Rejected |
| **D** | **Discovery updates `last_seen`, news updates `last_read` + `last_seen`** | **Zero spam, news always works** | **Two fields in meta** | **Selected** |

---

## 3. Analysis: User-Config Clutter

### 3.1 Current file inventory

Framework-managed files scattered across user-config:

| File | Location | Purpose | Vault status |
|------|----------|---------|-------------|
| `.cco-meta` | `global/.claude/`, `projects/*/` | Version tracking, manifest checksums | Gitignored |
| `.cco-base/` | `global/.claude/`, `projects/*/` | 3-way merge ancestor snapshot | **Tracked** |
| `.managed/` | `projects/*/` | Runtime MCPs (browser, GitHub, policy) | Gitignored |
| `docker-compose.yml` | `projects/*/` | Generated from project.yml | Gitignored |
| `claude-state/` | `projects/*/` | Session transcripts for /resume | Gitignored |
| `.tmp/` | `projects/*/` | Dry-run dump artifacts (opt-in) | Gitignored |
| `.pack-manifest` | `projects/*/.claude/` | Legacy pack tracking (pre-ADR-14) | Gitignored (*) |
| `.cco-remotes` | `user-config/` root | Remote registry + auth tokens | Gitignored |
| `.cco-source` | `packs/*/` | Pack origin reference | **Tracked** |
| `.cco-install-tmp/` | `packs/*/` | Temporary pack install files | Gitignored |

> (*) **Note**: `.pack-manifest` actually lives at `projects/*/.claude/.pack-manifest`
> (see `lib/packs.sh:13`), but the current vault `.gitignore` has the pattern
> `projects/*/.pack-manifest` (project root). This is a pre-existing gitignore bug —
> the pattern doesn't match the actual file location. The migration corrects this.

### 3.2 What the user actually edits

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

### 3.3 Options evaluated

| Option | Description | Pro | Contra | Verdict |
|--------|------------|-----|--------|---------|
| **A** | **`.cco/` per scope level** | **Locality, simple vault rules** | Multiple .cco/ dirs | **Selected** |
| B | Single top-level `.cco/` with mirror | One hidden dir | Duplicated tree, complex paths | Rejected |
| C | Separate state directory (`CCO_STATE_DIR`) | Total separation | Two dirs to manage, vault complexity | Rejected |

### 3.4 Constraint: vault tracking

`.cco-base/` (merge ancestors) and `.cco-source` (pack origin) must remain
**vault-tracked** for 3-way merge and pack update workflows. The vault `.gitignore`
must selectively ignore framework files within `.cco/` while tracking these two.

---

## 4. Design: Changelog Dual-Tracker

### 4.1 New fields in .cco-meta

```yaml
# In global/.claude/.cco-meta (after migration):
# In global/.claude/.cco/meta (after .cco/ consolidation):
last_seen_changelog: 2
last_read_changelog: 2
```

| Field | Updated by | Purpose |
|-------|-----------|---------|
| `last_seen_changelog` | discovery + news | Prevents repeated summary in `cco update` |
| `last_read_changelog` | news only | Tracks what user has read in detail |

### 4.2 Behavioral rules

**Discovery mode** (`cco update`):
1. Show entries where `id > last_seen_changelog`
2. Update `last_seen_changelog` → latest id
3. Show "Run `--news` for details" hint **only if** `last_read_changelog < latest_id`

**News mode** (`cco update --news`):
1. Show entries where `id > last_read_changelog`
2. Update **both** `last_read_changelog` AND `last_seen_changelog` → latest id

### 4.3 Scenario matrix

| Scenario | Discovery shows? | Hint shown? | News shows? |
|----------|-----------------|-------------|-------------|
| Fresh install (both 0), new entries exist | Yes (summary) | Yes | Yes (details) |
| After discovery only | No (already seen) | Yes (not read) | Yes (details) |
| After news only | No (news updated both) | No | No (already read) |
| After discovery then news | No | No | Yes (then no after read) |
| After news then discovery | No | No | No |
| New entries after both read | Yes (new ones) | Yes | Yes (new ones) |
| Partial read (seen 1-3, new 4-5 arrive) | `last_seen=5`, `last_read=3` after discovery | Yes (4-5 unread) | Yes (shows 4-5) |

### 4.4 Code changes in `lib/update.sh`

**Call graph** (for implementer clarity):
```
cmd_update()
  └─ _update_changelog_notifications(cmd_mode, dry_run)
       ├─ _show_changelog_summary(last_seen, last_read)   # discovery mode
       └─ _show_changelog_news(last_read)                  # news mode
```
`_show_changelog_summary` and `_show_changelog_news` are each called from exactly
one place: `_update_changelog_notifications()`. No other callers exist.

**New function** — `_read_last_read_changelog()`:
```bash
_read_last_read_changelog() {
    local meta_file="$1"
    [[ ! -f "$meta_file" ]] && echo "0" && return 0
    local val
    val=$(grep '^last_read_changelog:' "$meta_file" | awk '{print $2}')
    echo "${val:-0}"
}
```

**Modified function** — `_update_changelog_notifications()`:
```bash
_update_changelog_notifications() {
    local cmd_mode="$1"
    local dry_run="$2"
    local meta_file
    meta_file=$(_cco_global_meta)  # resolved via path helper (lib/paths.sh)

    local last_seen last_read latest_id
    last_seen=$(_read_last_seen_changelog "$meta_file")
    last_read=$(_read_last_read_changelog "$meta_file")
    latest_id=$(_latest_changelog_id)

    if [[ "$cmd_mode" == "news" ]]; then
        _show_changelog_news "$last_read"
        # News updates both trackers
        if [[ "$dry_run" != "true" && "$latest_id" -gt "$last_read" ]]; then
            _sed_i_or_append "$meta_file" "last_read_changelog" "$latest_id"
            _sed_i_or_append "$meta_file" "last_seen_changelog" "$latest_id"
        fi
    else
        _show_changelog_summary "$last_seen" "$last_read"
        # Discovery updates only last_seen
        if [[ "$dry_run" != "true" && "$latest_id" -gt "$last_seen" ]]; then
            _sed_i_or_append "$meta_file" "last_seen_changelog" "$latest_id"
        fi
    fi
}
```

> **Note**: The pseudocode uses `_sed_i_or_append` — a helper that updates a field
> in-place if it exists, or appends it if missing (for backward compatibility when
> `last_read_changelog` is absent from older meta files). This replaces the
> conceptual `_update_meta_field` from earlier drafts and follows the existing
> `_sed_i` pattern already in use throughout `lib/update.sh`.

**Modified function** — `_show_changelog_summary()`:
Add `last_read` parameter; only show hint if unread entries exist:
```bash
_show_changelog_summary() {
    local last_seen="$1"
    local last_read="$2"
    # ... existing logic to show entries where id > last_seen ...
    if [[ $shown -gt 0 && "$last_read" -lt "$latest_shown_id" ]]; then
        info "  Run 'cco update --news' for details and examples."
    fi
}
```

**Modified function** — `_generate_cco_meta()`:
Include `last_read_changelog` field in output.

### 4.5 Backward compatibility

If `last_read_changelog` is missing from `.cco-meta`, `_read_last_read_changelog()`
returns 0. On next `cco update` or `cco update --news`, the field is written
automatically by `_update_meta_field()`. No migration required.

---

## 5. Design: .cco/ Directory Consolidation

### 5.1 Target directory structure

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

### 5.2 Design decisions

**D1: Per-scope `.cco/` (Option A).**
State stays near its context. No mirrored directory tree.

**D2: Helper functions for all framework paths.**
Single source of truth for path resolution. Enables future layout changes without
touching business logic.

**D3: `docker-compose.yml` moves inside `.cco/`.**
It's generated, not user-editable. Uses `docker compose --project-directory` flag
to preserve relative path resolution:
```bash
docker compose -f "$compose_file" --project-directory "$project_dir" run ...
```

**D4: `.cco/base/` and `.cco/source` remain vault-tracked.**
Required for 3-way merge and pack update workflows. Vault `.gitignore` selectively
ignores other `.cco/` contents.

**D5: `.vault-profile` stays at user-config root (not moved).**
Reasons: (a) it's the vault branching root file, included explicitly in sync paths;
(b) it's informative to users (shows active profile); (c) moving it into `.cco/`
would require selective vault tracking at top level for minimal benefit.

**D6: Pack migration included in same cycle.**
`.cco-source` has 24 references in `cmd-pack.sh`. Leaving packs unconsolidated
while migrating everything else would be inconsistent. The global migration
iterates `$PACKS_DIR/*/` directly (no new migration scope needed).

**D7: `claude-state/` moves inside `.cco/`.**
Session transcripts are transparent to the user — managed entirely by Claude Code
for `/resume` functionality. The user never interacts with them directly. Moving
them inside `.cco/` makes the project root clean: only user-editable files remain
visible. The Docker volume mount changes only on the host side:
```yaml
# Before:
- ./claude-state:/home/claude/.claude/projects/-workspace
# After:
- ./.cco/claude-state:/home/claude/.claude/projects/-workspace
```
The child mount for `memory/` stays unchanged:
```yaml
- ./memory:/home/claude/.claude/projects/-workspace/memory
```

**D8: `--dry-run` uses ephemeral staging; `.tmp/` removed from `.cco/`.**
`--dry-run` generates artifacts in a system temp directory (`mktemp -d`), shows
the recap in the terminal, then auto-cleans. No persistent `.tmp/` directory.
For maintainer/debugging use cases, `--dry-run --dump` writes to a project-local
`.tmp/` directory (outside `.cco/`, since it's meant for user inspection).
`cco start` (without `--dry-run`) auto-cleans `.tmp/` if it exists — starting
a session implies the dry-run output was approved.

### 5.3 Path resolution helpers

New file `lib/paths.sh`, sourced by `bin/cco`:

```bash
# ── Top-level ────────────────────────────────────────────────────────
_cco_remotes_file()    { echo "$USER_CONFIG_DIR/.cco/remotes"; }

# ── Global scope ─────────────────────────────────────────────────────
_cco_global_meta()     { echo "$GLOBAL_DIR/.claude/.cco/meta"; }
_cco_global_base_dir() { echo "$GLOBAL_DIR/.claude/.cco/base"; }

# ── Project scope ($1 = project_dir) ────────────────────────────────
_cco_project_meta()      { echo "$1/.cco/meta"; }
_cco_project_base_dir()  { echo "$1/.cco/base"; }
_cco_project_managed()      { echo "$1/.cco/managed"; }
_cco_project_compose()      { echo "$1/.cco/docker-compose.yml"; }
_cco_project_claude_state() { echo "$1/.cco/claude-state"; }

# Note: pack-manifest lives inside .claude/, not project root
_cco_project_pack_manifest() { echo "$1/.claude/.cco/pack-manifest"; }

# ── Pack scope ($1 = pack_dir) ──────────────────────────────────────
_cco_pack_source()       { echo "$1/.cco/source"; }
_cco_pack_install_tmp()  { echo "$1/.cco/install-tmp"; }
```

### 5.4 Vault .gitignore (target state)

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

# Global session state (auth, preferences — not inside .cco/ at global level)
global/claude-state/

# Project auxiliary data
projects/*/rag-data/
```

**What's tracked (not gitignored):**
- `global/.claude/.cco/base/` — merge ancestors for global config
- `projects/*/.cco/base/` — merge ancestors for project config
- `packs/*/.cco/source` — pack origin metadata

> **Note**: The old `.gitignore` had no explicit entry for `global/.claude/.cco-meta`
> because `.cco-meta` was only gitignored via the `projects/*/.cco-meta` pattern.
> The global meta was effectively untracked because it was never `git add`-ed by
> `cco vault sync` (vault sync only stages declared paths). The new gitignore adds
> `global/.claude/.cco/meta` explicitly to prevent accidental inclusion.

### 5.5 docker-compose.yml invocation

Current (`lib/cmd-start.sh:647`):
```bash
docker compose -f "$compose_file" run --rm --service-ports ... claude
```

After (compose file inside `.cco/`):
```bash
docker compose -f "$compose_file" --project-directory "$project_dir" run --rm --service-ports ... claude
```

The `--project-directory` flag ensures all relative paths in the generated compose
(e.g., `./.cco/claude-state`, `./memory`, `./.cco/managed`) resolve relative to
`$project_dir`, not to the compose file's parent directory.

**Volume paths in generated compose** — changes needed:
```yaml
# Before:
- ./.managed:/workspace/.managed:ro
- ./claude-state:/home/claude/.claude/projects/-workspace

# After:
- ./.cco/managed:/workspace/.managed:ro
- ./.cco/claude-state:/home/claude/.claude/projects/-workspace
```

The `memory/` child mount stays unchanged (it's a user-visible directory):
```yaml
# Unchanged:
- ./memory:/home/claude/.claude/projects/-workspace/memory
```

The container-side mount path (`/workspace/.managed`) is **intentionally preserved
unchanged**. `config/entrypoint.sh` references `/workspace/.managed` in three places
(lines 135-157: MCP file discovery, browser.json merge). Since the container-side
path does not change, **`entrypoint.sh` requires no modifications**.

Complete before/after for the generated compose volume line:
```yaml
# Before:
- ./.managed:/workspace/.managed:ro

# After (with --project-directory resolving ./ from project_dir):
- ./.cco/managed:/workspace/.managed:ro
```

### 5.6 Dry-run behavior (redesigned)

**Current behavior**: `--dry-run` generates all artifacts in `$project_dir/.tmp/`
and keeps them for inspection. The user rarely inspects these files — the terminal
recap is sufficient. `.tmp/` accumulates across dry-runs until explicitly cleaned.

**New behavior**:

- **`--dry-run`** (default): Generates artifacts in a system temp directory
  (`mktemp -d`), shows the recap in the terminal, then **auto-deletes** the temp dir.
  No persistent files left behind. This is the common case.

- **`--dry-run --dump`**: Generates artifacts in `$project_dir/.tmp/` (outside `.cco/`,
  since it's explicitly for user inspection). Useful for maintainers and debugging.
  The `.tmp/` directory persists until cleaned.

- **`cco start`** (without `--dry-run`): Auto-cleans `$project_dir/.tmp/` if it exists.
  Starting a session implies the dry-run output was reviewed/approved.

- **`cco clean --tmp`**: Remains available for explicit cleanup.

The staging tree inside `.tmp/` mirrors the project layout using path helpers,
so generated files use `.cco/managed/`, `.cco/docker-compose.yml`, etc. regardless
of whether staging is ephemeral or persistent.

```bash
# In cmd-start.sh:
if [[ "$dry_run" == true ]]; then
    if [[ "$dump" == true ]]; then
        output_dir="$project_dir/.tmp"
        mkdir -p "$output_dir"
    else
        output_dir=$(mktemp -d)
        trap "rm -rf '$output_dir'" EXIT
    fi
else
    output_dir="$project_dir"
    # Auto-clean stale dry-run dump
    [[ -d "$project_dir/.tmp" ]] && rm -rf "$project_dir/.tmp"
fi
```

### 5.7 Files not affected

The following files are explicitly **not impacted** by this migration:

- **`config/entrypoint.sh`**: Uses container-side paths (`/workspace/.managed`)
  which are unchanged (see §5.5).
- **`lib/cmd-new.sh`**: Generates its own `docker-compose.yml` for temporary
  sessions (`cco new --repo`). These are written to `$tmp_dir/docker-compose.yml`
  in a temporary directory outside user-config. No `.managed/` or `.cco-meta`
  involved. No changes needed.

---

## 6. Migration Strategy

### 6.1 Overview

Two migration scripts, one per scope. Both run automatically via `cco update`.

### 6.2 Global migration: `migrations/global/009_cco_dir_consolidation.sh`

```bash
MIGRATION_ID=9
MIGRATION_DESC="Consolidate framework files into .cco/ directories"

migrate() {
    local target_dir="$1"   # global/.claude/

    mkdir -p "$target_dir/.cco"

    # Move .cco-meta → .cco/meta
    if [[ -f "$target_dir/.cco-meta" ]]; then
        mv "$target_dir/.cco-meta" "$target_dir/.cco/meta"
    fi

    # Move .cco-base/ → .cco/base/ (guarded: skip if target exists)
    if [[ -d "$target_dir/.cco-base" && ! -d "$target_dir/.cco/base" ]]; then
        mv "$target_dir/.cco-base" "$target_dir/.cco/base"
    fi

    # Top-level: .cco-remotes → .cco/remotes
    local user_config_dir
    user_config_dir=$(dirname "$(dirname "$target_dir")")  # up from global/.claude/
    if [[ -f "$user_config_dir/.cco-remotes" ]]; then
        mkdir -p "$user_config_dir/.cco"
        mv "$user_config_dir/.cco-remotes" "$user_config_dir/.cco/remotes"
    fi

    # Pack consolidation (iterate packs/ from user-config root)
    local packs_dir="$user_config_dir/packs"
    if [[ -d "$packs_dir" ]]; then
        for pack_dir in "$packs_dir"/*/; do
            [[ -d "$pack_dir" ]] || continue
            mkdir -p "$pack_dir/.cco"
            [[ -f "$pack_dir/.cco-source" && ! -f "$pack_dir/.cco/source" ]] && \
                mv "$pack_dir/.cco-source" "$pack_dir/.cco/source"
            [[ -d "$pack_dir/.cco-install-tmp" && ! -d "$pack_dir/.cco/install-tmp" ]] && \
                mv "$pack_dir/.cco-install-tmp" "$pack_dir/.cco/install-tmp"
        done
    fi

    # Update vault .gitignore if vault is initialized
    if [[ -f "$user_config_dir/.gitignore" ]]; then
        _migrate_vault_gitignore "$user_config_dir/.gitignore"
    fi

    return 0
}
```

### 6.3 Project migration: `migrations/project/009_cco_dir_consolidation.sh`

```bash
MIGRATION_ID=9
MIGRATION_DESC="Consolidate framework files into .cco/ directories"

migrate() {
    local target_dir="$1"   # projects/<name>/

    mkdir -p "$target_dir/.cco"

    # Move .cco-meta → .cco/meta
    [[ -f "$target_dir/.cco-meta" ]] && \
        mv "$target_dir/.cco-meta" "$target_dir/.cco/meta"

    # Move .cco-base/ → .cco/base/ (guarded)
    [[ -d "$target_dir/.cco-base" && ! -d "$target_dir/.cco/base" ]] && \
        mv "$target_dir/.cco-base" "$target_dir/.cco/base"

    # Move .managed/ → .cco/managed/ (guarded)
    [[ -d "$target_dir/.managed" && ! -d "$target_dir/.cco/managed" ]] && \
        mv "$target_dir/.managed" "$target_dir/.cco/managed"

    # Move docker-compose.yml → .cco/docker-compose.yml
    [[ -f "$target_dir/docker-compose.yml" ]] && \
        mv "$target_dir/docker-compose.yml" "$target_dir/.cco/docker-compose.yml"

    # Move claude-state/ → .cco/claude-state/ (guarded)
    [[ -d "$target_dir/claude-state" && ! -d "$target_dir/.cco/claude-state" ]] && \
        mv "$target_dir/claude-state" "$target_dir/.cco/claude-state"

    # Clean up stale .tmp/ (now ephemeral, not migrated)
    [[ -d "$target_dir/.tmp" ]] && rm -rf "$target_dir/.tmp"

    # Move .pack-manifest → .cco/pack-manifest (lives inside .claude/)
    [[ -f "$target_dir/.claude/.pack-manifest" ]] && \
        mv "$target_dir/.claude/.pack-manifest" "$target_dir/.claude/.cco/pack-manifest"

    return 0
}
```

### 6.4 Idempotency

Both migrations use **guarded moves**: check that source exists AND target does NOT
exist before moving. This prevents the edge case where `mv` of a directory onto an
existing directory would nest it inside (data corruption).

```bash
# Safe directory move pattern:
if [[ -d "$src" && ! -d "$dst" ]]; then
    mv "$src" "$dst"
fi
```

This handles:
- **First run**: source exists, target doesn't → move
- **Re-run**: source gone, target exists → no-op
- **Partial state** (e.g., migration 007 recreated `.cco-base/` after 009 already ran):
  source exists AND target exists → skip (no data loss). The stale source can be
  cleaned up manually or by a future migration.

### 6.5 Vault .gitignore migration

The global migration includes a helper `_migrate_vault_gitignore()` that replaces
old patterns with new ones. Uses `sed` in-place:

| Old pattern | New pattern |
|------------|-------------|
| `projects/*/.managed/` | `projects/*/.cco/managed/` |
| `projects/*/.tmp/` | `projects/*/.tmp/` (unchanged, stays outside `.cco/`) |
| `projects/*/.pack-manifest` | `projects/*/.cco/pack-manifest` |
| `projects/*/.cco-meta` | `projects/*/.cco/meta` |
| `projects/*/docker-compose.yml` | `projects/*/.cco/docker-compose.yml` |
| `projects/*/claude-state/` | `projects/*/.cco/claude-state/` |
| `packs/*/.cco-install-tmp/` | `packs/*/.cco/install-tmp/` |
| `.cco-remotes` | `.cco/remotes` |
| (add) | `global/.claude/.cco/meta` |
| `projects/*/.pack-manifest` | `projects/*/.claude/.cco/pack-manifest` (*) |

> (*) The `.pack-manifest` gitignore pattern was previously incorrect (matched project
> root instead of `.claude/` subdirectory). The migration fixes this by using the
> correct path: `projects/*/.claude/.cco/pack-manifest`.

### 6.6 Running-session safety

**Scenario**: A session is running (`cco start myapp` active in another terminal)
and the user runs `cco update` which triggers migration 009.

**Analysis**:
- **`docker-compose.yml` moved**: Safe. Docker resolves volume mounts at container
  start time. The running container already has its mounts. Moving the compose file
  does not affect the running session.
- **`.managed/` moved**: The running session's volumes point to the old host path
  (`projects/myapp/.managed/`). After migration, `.managed/` is at `.cco/managed/`.
  However, since the `mv` moves the actual directory (same filesystem), Docker's bind
  mount follows the inode — the mount remains valid on Linux. On macOS (Docker Desktop),
  the VM has its own filesystem view and may or may not track the move.
- **`claude-state/` moved**: Same inode-tracking behavior as `.managed/`. The running
  session writes transcripts to its mounted path. After migration, the host directory
  is at `.cco/claude-state/` but the mount still points to the original inode.
- **`cco stop` after migration**: `cco stop` cleans up managed files. If the session
  was started with old paths, `cco stop` (now using new paths) may fail to find
  `.cco/managed/.browser-port`. This is benign — the files are runtime artifacts
  that would be cleaned on next `cco start`.

**Recommendation**: Migration 009 should emit a warning if a project container is
running:
```bash
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^cc-"; then
    warn "Running sessions detected. Restart them after migration: cco stop && cco start <project>"
fi
```

---

## 7. Impact Analysis

### 7.1 Code changes by file

| File | Refs to change | Complexity | Notes |
|------|---------------|------------|-------|
| `lib/update.sh` | ~38 | High | .cco-meta and .cco-base throughout; changelog logic |
| `lib/cmd-start.sh` | ~30 | Medium | .managed paths + compose generation + docker invocation + claude-state mount + dry-run refactor |
| `lib/cmd-pack.sh` | ~24 | Medium | .cco-source references |
| `lib/cmd-remote.sh` | ~4 | Low | Already uses `_remotes_file()` helper |
| `lib/cmd-project.sh` | ~8 | Low | Meta and base references |
| `lib/cmd-init.sh` | ~10 | Low | Initial meta/base creation |
| `lib/cmd-stop.sh` | ~4 | Low | .managed cleanup paths |
| `lib/cmd-vault.sh` | ~5 | Low | Gitignore patterns + `_VAULT_SECRET_PATTERNS` (`.cco-remotes` → `.cco/remotes`) |
| `lib/cmd-template.sh` | ~5 | Low | .cco-source check + runtime artifact stripping (line ~278) |
| `lib/cmd-clean.sh` | ~3 | Low | .tmp and generated cleanup |
| `lib/cmd-chrome.sh` | ~3 | Low | .managed browser port |
| `lib/secrets.sh` | ~1 | Low | .managed reference |
| `lib/packs.sh` | ~1 | Low | `.pack-manifest` path (line 13: `.claude/.pack-manifest` → `.claude/.cco/pack-manifest`) |
| `config/entrypoint.sh` | 0 | — | No change: uses container-side paths (see §5.7) |
| `lib/cmd-new.sh` | 0 | — | No change: temp sessions outside user-config (see §5.7) |
| **lib/paths.sh** | **New** | Low | Path helpers |

### 7.2 Test changes

| Test file | Refs to change | Notes |
|-----------|---------------|-------|
| `tests/test_update.sh` | ~52 | Most impacted; meta/base paths + changelog tests |
| `tests/test_start_dry_run.sh` | ~44 | Compose output + managed paths |
| `tests/test_docker_security.sh` | ~35 | Policy in .managed |
| `tests/test_stop.sh` | ~26 | .managed cleanup |
| `tests/test_remote.sh` | ~28 | .cco-remotes path |
| `tests/test_pack_install.sh` | ~13 | .cco-source |
| `tests/test_merge.sh` | ~10 | .cco-base paths |
| `tests/test_pack_publish.sh` | ~5 | .cco-source |
| `tests/test_project_publish.sh` | ~7 | Exclude patterns |
| `tests/test_chrome.sh` | ~6 | .managed browser |
| `tests/test_managed_scope.sh` | ~3 | .managed |
| `tests/helpers.sh` | ~1 | Helper setup |

### 7.3 Migration files (existing, update references)

| Migration | Change needed |
|-----------|--------------|
| `migrations/project/003_managed_dir.sh` | No change (creates .managed if missing; migration 009 moves it) |
| `migrations/project/007_init_cco_meta_and_base.sh` | Update to create in `.cco/` if migration 009 already ran |
| `migrations/global/006_vault_gitignore_tmp.sh` | No change (pattern already migrated by 009) |
| `migrations/global/007_init_cco_base.sh` | Update to create in `.cco/` if migration 009 already ran |

Note: migrations run in order. Since 009 runs after 007, the old-path files created
by 007 are moved by 009. No circular dependency. However, on completely fresh installs
where only 009+ exists in schema, `cco init` should create files directly in `.cco/`
paths (handled by updating `cmd-init.sh`).

---

## 8. Implementation Plan

### Phase 1: Changelog dual-tracker (standalone, no migration)

1. Add `_read_last_read_changelog()` to `lib/update.sh`
2. Modify `_update_changelog_notifications()` with dual-tracker logic
3. Modify `_show_changelog_summary()` to accept and use `last_read` for hint
4. Modify `_generate_cco_meta()` to include `last_read_changelog`
5. Update tests in `tests/test_update.sh`
6. Update `changelog.yml` header comment

### Phase 2: Path helpers + dual-read layer + dry-run refactor

1. Create `lib/paths.sh` with all helper functions (including `_cco_project_claude_state`)
2. Each helper checks new path first, falls back to old path:
   ```bash
   _cco_project_meta() {
       local new="$1/.cco/meta"
       local old="$1/.cco-meta"
       if [[ -f "$new" ]]; then echo "$new"
       elif [[ -f "$old" ]]; then echo "$old"
       else echo "$new"  # default to new for writes
       fi
   }
   ```
3. Source `lib/paths.sh` from `bin/cco`
4. Update all lib/ files to use helpers instead of hardcoded paths
5. All **writes** go to new `.cco/` paths
6. All **reads** try new path first, then old path (backward compat during rollout)
7. Refactor `cmd-start.sh` dry-run: `mktemp -d` by default, `--dump` flag for persistent `.tmp/`
8. Add auto-clean of `.tmp/` in `cco start` (non-dry-run mode)
9. Update claude-state volume mount generation to use `.cco/claude-state`

### Phase 3: Migration scripts

1. Create `migrations/global/009_cco_dir_consolidation.sh`
2. Create `migrations/project/009_cco_dir_consolidation.sh`
3. Include vault `.gitignore` migration in global script
4. Include pack consolidation in global script
5. Test migration idempotency

### Phase 4: Cleanup + tests

1. Remove dual-read fallback from helpers (simplify to new-path only)
2. Update all tests to use new paths
3. Update `lib/cmd-project.sh` publish exclude patterns (`.cco/` instead of individual files)
4. Update `lib/cmd-project.sh` `_publish_pack_to_tmpdir()` cleanup paths
   (lines ~1223-1224: `.cco-source` → `.cco/source`, `.cco-install-tmp` → `.cco/install-tmp`)
5. Update `lib/cmd-template.sh` runtime artifact stripping (line ~278):
   replace individual `rm -rf` for `.cco-meta`, `.cco-base`, `.managed/`, etc.
   with `rm -rf "$target_dir/.cco"` (but preserve `.cco/base/` if needed in template)
6. Update `lib/cmd-vault.sh` `_VAULT_SECRET_PATTERNS` array: `.cco-remotes` → `.cco/remotes`
7. Update documentation references
8. Update `CLAUDE.md` (repo root)
9. Run full test suite

### Commit sequence

```
feat(update): add changelog dual-tracker (last_seen + last_read)
refactor(core): add lib/paths.sh with framework path helpers
refactor(update): use path helpers for meta and base references
refactor(start): use path helpers for managed, compose, and claude-state paths
refactor(start): refactor dry-run to use ephemeral staging with --dump opt-in
refactor(pack): use path helpers for source and install-tmp
refactor(remote): use _cco_remotes_file() from paths.sh
feat(migration): add global/009 and project/009 for .cco/ consolidation
test: update all tests for .cco/ directory structure
docs: update CLAUDE.md and reference docs for .cco/ layout
chore: add changelog entry for .cco/ consolidation
```

---

## 9. Test Plan

### 9.1 Changelog dual-tracker tests

| # | Scenario | Setup | Expected |
|---|----------|-------|----------|
| 1 | Fresh install, discovery | Both trackers at 0 | Summary shown, hint shown, `last_seen` updated |
| 2 | After discovery, news | `last_seen` at latest, `last_read` at 0 | Details shown, both updated |
| 3 | After news, discovery | Both at latest | Nothing shown |
| 4 | News first (before discovery) | Both at 0 | Details shown, both updated |
| 5 | After news-first, discovery | Both at latest | Nothing shown, no hint |
| 6 | New entry after both read | Both at N-1 | Discovery shows new, hint shown, news shows new |
| 7 | Missing `last_read_changelog` field | Only `last_seen` in meta | Defaults to 0, behaves like scenario 1 |
| 8 | Dry-run mode | Any state | Shows output, no tracker updates |

### 9.2 .cco/ consolidation tests

| # | Scenario | Expected |
|---|----------|----------|
| 1 | Migration on existing project (old layout) | All files moved to `.cco/`, old paths gone |
| 2 | Migration idempotency (run twice) | No errors, no changes on second run |
| 3 | Migration on fresh project (no old files) | `.cco/` created, empty where applicable |
| 4 | `cco start` generates compose in `.cco/` | File at `.cco/docker-compose.yml`, runs correctly |
| 5 | `cco start --dry-run` (default) | Recap shown in terminal, no persistent files, temp dir cleaned |
| 5b | `cco start --dry-run --dump` | Artifacts written to `.tmp/`, persist for inspection |
| 6 | `cco stop` cleans `.cco/managed/` | Browser/GitHub JSONs removed from `.cco/managed/` |
| 7 | `cco clean --generated` removes `.cco/docker-compose.yml` | Correct path cleaned |
| 8 | `cco start` auto-cleans `.tmp/` | Stale dry-run dump removed on real start |
| 9 | `cco pack install` writes `.cco/source` | Source file at new path |
| 10 | `cco pack update` reads `.cco/source` | Finds source at new path |
| 11 | `cco remote add/list` uses `.cco/remotes` | Reads/writes at new path |
| 12 | `cco vault sync` tracks `.cco/base/` | Base dirs committed, meta/managed ignored |
| 13 | `cco project publish` excludes `.cco/` internals | Only `.cco/base/` and `.cco/source` in archive |
| 14 | Vault `.gitignore` after migration | New patterns present, old patterns removed |
| 15 | `cco template create --project` strips `.cco/` | Runtime state excluded, `.cco/base/` preserved |
| 16 | `cco project publish` pack cleanup | `.cco/source` and `.cco/install-tmp` stripped from bundled packs |
| 17 | Migration with running session | Warning emitted, no crash |
| 18 | Migration idempotency with partial state | Target exists + source exists → skip safely |
| 19 | `cco vault sync` secret scan | `.cco/remotes` detected as secret, blocked from commit |
| 20 | `cco start` mounts claude-state from `.cco/` | Volume at `.cco/claude-state`, `/resume` works |
| 21 | Migration moves `claude-state/` to `.cco/claude-state/` | Transcripts preserved, old dir removed |
