# FI-7 — Publish-Install Sync: Design

> **Date**: 2026-03-17
> **Status**: Design — pending review
> **Scope**: Architecture-level
> **Analysis**: [analysis.md](./analysis.md)
> **Prerequisites**: [resource-lifecycle analysis](../resource-lifecycle/analysis.md), [update system design](../update-system/design.md), [sharing design](../sharing/design.md)

---

## Table of Contents

1. [Overview](#1-overview)
2. [Data Model Changes](#2-data-model-changes)
3. [Unified Discovery](#3-unified-discovery)
4. [Source-Aware Framework Sync](#4-source-aware-framework-sync)
5. [Project Update from Remote](#5-project-update-from-remote)
6. [Publish Safety Pipeline](#6-publish-safety-pipeline)
7. [Project Internalize](#7-project-internalize)
8. [CLI Interface](#8-cli-interface)
9. [Implementation Plan](#9-implementation-plan)
10. [Migration for Existing Users](#10-migration-for-existing-users)

---

## 1. Overview

FI-7 completes the user-config lifecycle by closing the publish-install loop.
After this feature, resources installed from Config Repos can receive updates,
and publishing includes safety checks to prevent accidental content leakage.

### 1.1 Design Principles

1. **Unified discovery, separated actions** — `cco update` is the single entry
   point for "what's new?". Actions are type-specific (`--sync` for framework,
   `cco project update` for publisher, `cco pack update` for packs).

2. **Respect the update chain** — for installed projects, the chain is
   Framework → Publisher → Consumer. Framework sync skips opinionated files on
   installed projects by default, delegating to the publisher.

3. **Escape hatches exist** — `--local` forces framework sync on installed
   projects. `internalize` disconnects from remote permanently. The system
   guides toward best practices but never blocks the user.

4. **Reuse existing infrastructure** — 3-way merge, `_collect_file_changes()`,
   `_interactive_sync()`, remote clone helpers are all reused. No new merge
   engine needed.

5. **Safety by default** — publish requires migration check, secret scan, and
   diff review. The user must explicitly confirm each published file.

---

## 2. Data Model Changes

### 2.1 `.cco/source` — Enhanced Fields

Current format (unchanged):

```yaml
source: https://github.com/team/config.git
path: templates/my-service
ref: main
installed: 2026-03-05
```

New fields:

```yaml
source: https://github.com/team/config.git
path: templates/my-service
ref: main
installed: 2026-03-05
updated: 2026-03-17          # NEW: last update date
commit: abc123f              # NEW: commit hash of installed/updated version
version: "1.3.0"            # NEW: optional human-readable version from publisher
published: 2026-03-16        # NEW: last publish date (publisher-side only)
publish_commit: def456a      # NEW: commit hash of last published version
```

**Backward compatibility**: new fields are optional. Existing `.cco/source`
files without them work — the system treats missing `commit` as "unknown,
must fetch to compare".

### 2.2 `.cco/meta` — New Fields

```yaml
# Existing fields (unchanged)
schema_version: 9
last_seen_changelog: 5
last_read_changelog: 5

# New fields
remote_cache:                 # NEW: cached remote version info
  commit: abc123f
  checked: 2026-03-17T10:30:00Z
local_framework_override: false  # NEW: true if --local was used
```

### 2.3 `.cco/publish-ignore` — New File

Optional file in project directory. Gitignore syntax. Lists patterns to
exclude from publish. The file itself is never published.

```
# Example .cco/publish-ignore
.claude/rules/local-*.md
.claude/rules/personal-*.md
memory/
*.local
*.draft
```

### 2.4 `.cco/base/` — Semantic Clarification

No structural changes. Clarification of meaning by project type:

| Project type | `.cco/base/` contains | Updated by |
|-------------|----------------------|------------|
| Local | Framework defaults at install/last sync time | `cco update --sync` |
| Installed | Publisher's version at install/last update time | `cco project update` |

`--local` on an installed project does **not** update `.cco/base/`. The
consumer's framework changes are treated as local customizations relative
to the publisher's baseline.

---

## 3. Unified Discovery

### 3.1 Discovery Flow

```
cco update
  │
  ├─ 1. Run pending migrations (global + all projects)
  │     Always runs. Blocking if migration fails.
  │
  ├─ 2. Framework file discovery (global + local projects)
  │     Compare defaults/ vs installed files via _collect_file_changes()
  │     Report: "N files updated in defaults"
  │
  ├─ 3. Remote source discovery (installed projects + packs)
  │     For each resource with .cco/source:
  │       - Check cache (TTL: 1 hour default)
  │       - If stale: shallow git fetch, compare HEAD hash vs .cco/source commit
  │       - Report: "Publisher update available" or "Up to date"
  │
  ├─ 4. Framework alignment report (installed projects only)
  │     For installed projects: note framework defaults that have changed
  │     but are managed by the publisher chain
  │
  └─ 5. Changelog notifications
        Show new additive changes since last seen
```

### 3.2 Output Format

```
$ cco update

Global config:
  ✓ No pending migrations
  ℹ 2 files updated in defaults
    → run 'cco update --sync global' to review

Project 'my-local-app' (local):
  ✓ No pending migrations
  ℹ 1 file updated in defaults
    → run 'cco update --sync my-local-app' to review

Project 'team-service' (from github.com/team/config):
  ✓ 1 migration applied
  ℹ Publisher update available (3 files changed, 2 new)
    → run 'cco project update team-service' to review
  ℹ 2 framework defaults also updated (managed by publisher)

Pack 'react-guidelines' (from github.com/team/config):
  ℹ Update available (v1.2 → v1.3)
    → run 'cco pack update react-guidelines'

Changelog:
  2 new features since last check
    → run 'cco update --news' for details
```

### 3.3 Network Access

| Flag | Behavior |
|------|----------|
| (default) | Check remotes, use cache if fresh (TTL: 1h) |
| `--offline` | Skip all remote checks |
| `--no-cache` | Force fresh remote fetch |

Failure handling: if a remote is unreachable, warn and continue. Example:

```
Pack 'deploy-patterns' (from github.com/team/config):
  ⚠ Remote unreachable (timeout) — skipping remote check
```

### 3.4 Remote Check Implementation

```bash
_check_remote_update() {
    local source_file="$1"   # path to .cco/source
    local meta_file="$2"     # path to .cco/meta

    # 1. Read source info
    local remote_url=$(yaml_get "$source_file" "source")
    local remote_path=$(yaml_get "$source_file" "path")
    local remote_ref=$(yaml_get "$source_file" "ref")
    local installed_commit=$(yaml_get "$source_file" "commit")

    # 2. Check cache
    local cached_commit=$(yaml_get "$meta_file" "remote_cache.commit")
    local cached_time=$(yaml_get "$meta_file" "remote_cache.checked")
    if _cache_fresh "$cached_time" "$REMOTE_CACHE_TTL"; then
        # Use cached value
        if [[ "$cached_commit" != "$installed_commit" ]]; then
            echo "update_available"
        else
            echo "up_to_date"
        fi
        return
    fi

    # 3. Shallow fetch to get current HEAD
    local remote_head
    remote_head=$(git ls-remote "$remote_url" "$remote_ref" 2>/dev/null | cut -f1)
    if [[ -z "$remote_head" ]]; then
        echo "unreachable"
        return
    fi

    # 4. Update cache
    yaml_set "$meta_file" "remote_cache.commit" "$remote_head"
    yaml_set "$meta_file" "remote_cache.checked" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # 5. Compare
    if [[ "$remote_head" != "$installed_commit" ]]; then
        echo "update_available"
    else
        echo "up_to_date"
    fi
}
```

Note: `git ls-remote` is lightweight (no clone, no fetch). It returns the
current HEAD hash for the specified ref. This is the cheapest possible
remote check.

---

## 4. Source-Aware Framework Sync

### 4.1 Behavior Change for `cco update --sync`

Current behavior: applies framework file changes to all projects uniformly.

New behavior: checks `.cco/source` before applying framework changes.

```
cco update --sync <project>
  │
  ├─ Is project local (no .cco/source or source: local)?
  │   YES → Apply framework changes as today (full sync)
  │
  └─ Is project installed (remote .cco/source)?
      │
      ├─ Was --local flag passed?
      │   YES → Apply framework changes (escape hatch)
      │         Set local_framework_override: true in .cco/meta
      │
      └─ NO → Skip opinionated files, report:
              "Project 'X' is installed from <remote>.
               Framework updates are managed by the publisher.
               → Run 'cco project update X' to check for publisher updates.
               → Use --local to apply framework defaults directly."
```

### 4.2 What Still Applies on Installed Projects

Even without `--local`, `cco update --sync` on installed projects:

1. **Runs migrations** — mandatory, structural changes
2. **Regenerates `generated` files** (e.g., `language.md`) — derived from user
   preferences, not publisher content
3. **Reports framework changes** — informational, not applied

### 4.3 `--local` Behavior

When `--local` is used on an installed project:

1. Framework defaults are offered for interactive merge (same UI as local projects)
2. `.cco/base/` is **not updated** — remains anchored to publisher's version
3. `.cco/meta` gets `local_framework_override: true`
4. Future `cco update` discovery does **not** re-suggest `--local` for
   already-overridden files (checks the override marker)
5. Future `cco project update` merges against the publisher's baseline —
   the consumer's `--local` changes are treated as local customizations

---

## 5. Project Update from Remote

### 5.1 Command: `cco project update <name>`

```bash
cco project update <name> [--force] [--dry-run]
cco project update --all [--dry-run]
```

### 5.2 Update Flow

```
cco project update myapp
  │
  ├─ 1. Validate: project exists, has remote .cco/source
  │     Error if source: local or no .cco/source
  │
  ├─ 2. Vault snapshot offer (if vault initialized)
  │     "Create vault snapshot before updating? [Y/n]"
  │
  ├─ 3. Fetch remote version
  │     Sparse checkout of the project path from the Config Repo
  │     Store in temp directory
  │
  ├─ 4. Compare versions
  │     If remote HEAD == installed commit → "Already up to date"
  │     Otherwise → proceed to merge
  │
  ├─ 5. Reverse-template the fetched version
  │     Apply same template variable resolution as install
  │
  ├─ 6. Collect file changes
  │     _collect_file_changes(remote_dir, base_dir, installed_dir)
  │     base = .cco/base/ (publisher's version at last install/update)
  │     theirs = fetched remote (new publisher version)
  │     ours = installed files (with consumer customizations)
  │
  ├─ 7. Interactive merge
  │     _interactive_sync() with all options:
  │     (A)pply / (M)erge / (R)eplace+.bak / (K)eep / (S)kip / (D)iff / (N)ew-file
  │
  ├─ 8. Update metadata
  │     .cco/source: update commit, updated date, version (if available)
  │     .cco/base/: update to the new remote version (for future merges)
  │     .cco/meta: update remote_cache
  │
  └─ 9. Summary
        "Updated 'myapp' from <remote> (abc123 → def456)"
        "3 files applied, 1 merged, 1 skipped"
```

### 5.3 `--force` Flag

Skips interactive merge. Replaces all files with remote version, saving
originals as `.bak`. Equivalent to `auto_action="replace"` in `_interactive_sync()`.

### 5.4 `--dry-run` Flag

Shows what would change without modifying any files. Equivalent to showing
the diff output from step 6 without proceeding to step 7.

### 5.5 `--all` Flag

Iterates all installed projects (those with remote `.cco/source`) and runs
the update flow for each. Skips projects that are already up to date.

### 5.6 Pack vs Project Update

| Aspect | `cco pack update` | `cco project update` |
|--------|-------------------|---------------------|
| Merge strategy | Full-replace | 3-way merge |
| User customizations | Lost (use internalize first) | Preserved via merge |
| Interactive | No (replace or skip) | Yes (per-file options) |
| `.cco/base/` update | Replaced entirely | Updated to new remote version |

Packs use full-replace because they are mounted read-only in containers.
Projects use 3-way merge because consumers are expected to customize them.

---

## 6. Publish Safety Pipeline

### 6.1 Command: `cco project publish <name> <remote>`

Enhanced with safety pipeline. The existing reverse-template and push logic
is preserved; new checks are added before the push.

### 6.2 Pipeline Steps

```
cco project publish myapp my-remote
  │
  ├─ 1. MIGRATION CHECK [blocking]
  │     Read schema_version from .cco/meta
  │     Compare with latest migration ID
  │     If behind: ERROR "Run 'cco update' first — project has pending
  │     migrations (schema: 7, latest: 9)"
  │
  ├─ 2. FRAMEWORK ALIGNMENT CHECK [warning]
  │     Run _collect_file_changes() for framework defaults
  │     If changes found: WARN "N framework defaults have updates.
  │     Run 'cco update --sync myapp' to review before publishing."
  │     Prompt: "Continue anyway? [y/N]"
  │
  ├─ 3. SECRET SCAN [blocking]
  │     Reuse vault's _detect_secrets() patterns
  │     Scan all publishable files for:
  │       - *.env, *.key, *.pem files
  │       - Patterns: API_KEY=, SECRET=, PASSWORD=, token strings
  │       - .credentials.json, .netrc
  │     If found: ERROR "Potential secrets detected in:
  │       .claude/rules/api-config.md — matches 'API_KEY=' pattern
  │     Remove secrets or add to .cco/publish-ignore"
  │
  ├─ 4. PUBLISH-IGNORE FILTER
  │     Read .cco/publish-ignore (if exists)
  │     Exclude matching files from publish set
  │     Report: "Excluding N files matching .cco/publish-ignore"
  │
  ├─ 5. REVERSE-TEMPLATE [existing]
  │     Replace local paths with {{VAR}} placeholders
  │     Already implemented in cmd-project.sh
  │
  ├─ 6. DIFF REVIEW [interactive]
  │     If previous published version exists (.cco/source has publish_commit):
  │       Show per-file diff vs last published version
  │     If first publish:
  │       Show all files as NEW
  │     Format:
  │       M .claude/CLAUDE.md         (+12 -3)
  │       A .claude/skills/deploy/    (NEW)
  │       D .claude/rules/old-rule.md (REMOVED)
  │
  ├─ 7. PER-FILE CONFIRMATION [interactive]
  │     For each changed file:
  │       (P)ublish / (S)kip / (D)iff / (A)bort
  │     Skipped files are excluded from this publish (not from future ones)
  │
  └─ 8. PUSH + UPDATE METADATA
        Push to remote Config Repo (existing logic)
        Update .cco/source: published date, publish_commit
        Report: "Published 'myapp' to my-remote (N files)"
```

### 6.3 Non-Interactive Publish

For CI/CD or scripted workflows:

```bash
cco project publish myapp my-remote --yes
```

Skips interactive prompts (steps 2 confirm, 7 per-file). Migration and secret
checks still block. Framework alignment warning is printed but not blocking.

---

## 7. Project Internalize

### 7.1 Command: `cco project internalize <name>`

Disconnects an installed project from its remote source, converting it to
a local project.

### 7.2 Flow

```
cco project internalize myapp
  │
  ├─ 1. Validate: project has remote .cco/source
  │     Error if already local
  │
  ├─ 2. Confirm
  │     "This will disconnect 'myapp' from github.com/team/config.
  │      You will no longer receive publisher updates.
  │      Framework updates will apply directly via 'cco update --sync'.
  │      Continue? [y/N]"
  │
  ├─ 3. Update .cco/source
  │     Set source: local
  │     Preserve install history as comment
  │
  ├─ 4. Update .cco/base/
  │     Replace with framework base template files
  │     (so future cco update --sync has correct ancestor)
  │
  ├─ 5. Clear remote cache
  │     Remove remote_cache from .cco/meta
  │     Remove local_framework_override if present
  │
  └─ 6. Report
        "Project 'myapp' is now local. Framework updates will apply directly."
```

---

## 8. CLI Interface

### 8.1 New Commands

```
cco project update <name> [--force] [--dry-run]
cco project update --all [--dry-run]
cco project internalize <name>
```

### 8.2 Modified Commands

```
cco update [--offline] [--no-cache]   # New flags for remote check control
cco update --sync <project> [--local] # New --local flag for installed projects
cco project publish <name> <remote> [--yes]  # Enhanced with safety pipeline
```

### 8.3 Help Text Updates

```
cco update --help
  ...
  --offline           Skip remote source checks (framework-only discovery)
  --no-cache          Force fresh remote version check (ignore cache)

cco update --sync --help
  ...
  --local             Apply framework defaults directly on installed projects
                      (bypasses publisher update chain)

cco project update --help
  Usage: cco project update <name> [--force] [--dry-run]
         cco project update --all [--dry-run]

  Check for and apply updates from the remote source of an installed project.
  Uses 3-way merge to preserve your local customizations.

  Options:
    --force           Replace all files without interactive merge (.bak saved)
    --dry-run         Show what would change without modifying files
    --all             Update all installed projects

cco project internalize --help
  Usage: cco project internalize <name>

  Disconnect a project from its remote source, converting it to a local project.
  After internalizing, framework updates apply directly via 'cco update --sync'.

cco project publish --help
  Usage: cco project publish <name> <remote> [--yes]

  Publish a project template to a Config Repo with safety checks:
  migration validation, secret scan, diff review, and per-file confirmation.

  Options:
    --yes             Skip interactive prompts (migration + secret checks still apply)
```

---

## 9. Implementation Plan

### 9.1 Phase 1 — Data Model & Discovery

1. Extend `.cco/source` parser to handle new fields (`commit`, `version`,
   `updated`, `published`, `publish_commit`)
2. Add `remote_cache` and `local_framework_override` to `.cco/meta` parser
3. Implement `_check_remote_update()` with cache
4. Integrate remote discovery into `cmd_update()` output
5. Add `--offline` and `--no-cache` flags to `cco update`

### 9.2 Phase 2 — Source-Aware Sync

1. Modify `_update_project()` to check `.cco/source` before applying
   opinionated files
2. Implement `--local` flag in `cmd_update()`
3. Add informational messages for installed projects in `--sync` mode

### 9.3 Phase 3 — Project Update from Remote

1. Implement `cmd_project_update()` in `lib/cmd-project.sh`
2. Integrate with `_collect_file_changes()` and `_interactive_sync()`
3. Handle `.cco/base/` and `.cco/source` updates post-merge
4. Add `--force`, `--dry-run`, `--all` flags
5. Add vault snapshot prompt

### 9.4 Phase 4 — Publish Safety

1. Implement migration check in `cmd_project_publish()`
2. Implement framework alignment warning
3. Integrate secret scan (reuse vault's `_detect_secrets()`)
4. Implement `.cco/publish-ignore` parsing
5. Implement diff review and per-file confirmation UI
6. Add `--yes` flag
7. Update `.cco/source` with publish metadata

### 9.5 Phase 5 — Project Internalize

1. Implement `cmd_project_internalize()` in `lib/cmd-project.sh`
2. Handle `.cco/source`, `.cco/base/`, `.cco/meta` transitions

### 9.6 Phase 6 — Testing & Documentation

1. Test suite: `tests/test_publish_install_sync.sh`
2. Update `docs/reference/cli.md` with new commands
3. Update `docs/user-guides/config-lifecycle.md` (user guide)
4. Update CLAUDE.md with new commands
5. Add changelog entries
6. Update roadmap: FI-7 status → implemented

---

## 10. Migration for Existing Users

### 10.1 Existing Installed Projects

Projects installed before FI-7 have `.cco/source` but no `commit` field.
On first `cco update` after the FI-7 migration:

1. Discovery detects missing `commit` field
2. Performs a fresh remote check to populate `commit`
3. Reports: "Initialized version tracking for project 'X'"

No migration script needed — handled gracefully by the discovery logic.

### 10.2 Changelog Entry

```yaml
- id: <next>
  date: "2026-03-XX"
  type: additive
  title: "Publish-install sync and project updates"
  description: |
    Installed projects can now receive updates from their source:
    - 'cco update' shows available updates from all sources (framework + remotes)
    - 'cco project update <name>' fetches and merges publisher updates
    - 'cco project publish' now includes safety checks (migration, secrets, diff review)
    - 'cco project internalize <name>' disconnects from remote source
    Run 'cco update' to see available updates for your installed projects.
```

---

## 11. Cross-References

| Topic | Document |
|-------|----------|
| FI-7 analysis | `./analysis.md` |
| Resource lifecycle foundations | `../resource-lifecycle/analysis.md` |
| Update system design | `../update-system/design.md` |
| Config Repo / sharing design | `../sharing/design.md` |
| Vault profiles design | `../vault/design.md` |
| FI-7 in roadmap | `../../decisions/roadmap.md` § FI-7 |
| User guide | `../../../user-guides/config-lifecycle.md` |
