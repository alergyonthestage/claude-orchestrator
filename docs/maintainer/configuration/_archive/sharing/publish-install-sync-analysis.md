# FI-7 — Publish-Install Sync: Analysis

> **Date**: 2026-03-17
> **Status**: Analysis — approved
> **Scope**: Update chain, merge scenarios, publish safety, UX unification
> **Prerequisites**: [resource-lifecycle analysis](../resource-lifecycle/analysis.md), [update system design](../update-system/design.md), [sharing design](./design.md)

---

## 1. Problem Statement

The publish/install system is currently one-way: `cco project publish` exports,
`cco project install` imports. After installation there is no connection to the
source repository. Publishers who release updates have no way to notify consumers.

This gap means:

1. **No update path for installed resources** — `.cco/source` tracks the origin
   but nothing reads it for update purposes.
2. **No publish safety** — `cco project publish` pushes directly without review,
   risking leakage of local/personal content.
3. **No unified discovery** — `cco update` reports framework changes but is
   unaware of remote source updates.
4. **No guidance on update chain** — when framework defaults evolve, it is unclear
   whether the consumer or the publisher should apply them first.

---

## 2. Foundations Already in Place

Sprint 5c established the infrastructure that FI-7 builds on:

| Foundation | Location | What it provides |
|------------|----------|-----------------|
| `.cco/source` | Per-project/pack `.cco/source` | Origin URL, path, ref, install/update dates |
| `.cco/base/` | Per-scope `.cco/base/` directory | Last-seen version for 3-way merge ancestor |
| `_collect_file_changes()` | `lib/update.sh` | Source-agnostic diff engine |
| `_interactive_sync()` | `lib/update.sh` | Merge UI: Apply/Merge/Replace/Keep/Skip/Diff/New |
| File policies | `lib/update.sh` | tracked/untracked/generated per file |
| `cco pack update` | `lib/cmd-pack.sh` | Full-replace update from remote source |
| Template variable resolution | `lib/cmd-project.sh` | `{{VAR}}` substitution and reverse-template |

---

## 3. Update Chain Analysis

### 3.1 The Three Actors

| Actor | Role | Update source |
|-------|------|---------------|
| **Framework** | Provides defaults, migrations, opinionated files | `defaults/`, `templates/project/base/` |
| **Publisher** | Creates/customizes projects, publishes to Config Repo | Config Repo (git remote) |
| **Consumer** | Installs from Config Repo, may customize locally | Publisher's Config Repo |

### 3.2 The Trust Chain

For an installed project, the intended update chain is:

```
Framework defaults → Publisher's project → Consumer's installation
```

Each layer may customize the previous one. The publisher integrates framework
changes into their project context. The consumer receives the publisher's
curated version and may add further local customizations.

### 3.3 Two Axes of Update

| Axis | Direction | Mechanism | Scope |
|------|-----------|-----------|-------|
| **Vertical** (framework) | Framework → User | `cco update --sync` | defaults → installed files |
| **Horizontal** (publisher) | Publisher → Consumer | `cco project update` | Config Repo → installed project |

For **local projects** (created via `cco project create`, no `.cco/source` or
`source: local`), only the vertical axis exists. Framework updates are applied
directly.

For **installed projects** (created via `cco project install`, `.cco/source`
points to remote), both axes exist. The question is: should the consumer apply
framework updates directly, or wait for the publisher?

### 3.4 Decision: Source-Aware Framework Sync

For projects with a remote `.cco/source`, `cco update --sync` **excludes
opinionated framework files** and delegates to the publisher chain:

- Migrations (structural, schema-breaking) are **always applied** regardless of
  source — they are mandatory for compatibility.
- Opinionated file updates (rules, skills, agents, CLAUDE.md template changes)
  are **reported but not applied** — the publisher is expected to integrate
  these and publish an updated version.
- The consumer is informed of the situation and can use `--local` to override.

**Rationale**: applying framework defaults directly on an installed project
bypasses the publisher's curation. The publisher may have intentionally
customized certain defaults for their project's context. If the consumer
applies generic defaults, they overwrite those customizations and create a fork
that will conflict when the publisher releases their next update.

### 3.5 The `--local` Escape Hatch

`cco update --sync <project> --local` forces framework file updates on an
installed project, treating it as if it were local. Use cases:

- Publisher is inactive or has abandoned the project
- Consumer has decided to diverge from the publisher
- Consumer wants framework improvements immediately and accepts merge risk

When `--local` is used:
- Framework files are offered for interactive merge (same UI as local projects)
- `.cco/base/` remains anchored to the publisher's version (not updated to
  framework defaults) — this preserves the ability to receive publisher updates
  later
- A marker is written to `.cco/meta`: `local_framework_override: true` — this
  prevents the discovery from repeatedly suggesting `--local` on subsequent runs
- The consumer's modifications (including `--local` changes) are treated as local
  customizations during future `cco project update` runs

**Impact on future publisher updates**: When the publisher releases a version
that integrates the same framework changes, the 3-way merge handles it:
- If both applied the same change → auto-resolved (identical lines)
- If the publisher customized differently → conflict → interactive merge
- The consumer can choose the publisher's version (Replace) or keep their own

---

## 4. Complete Scenario Matrix

### Scenario 1 — No local changes, publisher updates

```
Publisher v1 ──→ Publisher v2
     ↓                ↓
Consumer installs    cco project update → clean apply
```

- **base** = publisher v1 (in `.cco/base/`)
- **theirs** = publisher v2 (fetched from remote)
- **ours** = consumer's files (identical to base)
- Result: clean apply, zero conflicts

### Scenario 2 — Consumer has customizations, publisher updates

```
Publisher v1 ──→ Publisher v2
     ↓
Consumer installs → Consumer customizes locally
                  → cco project update → 3-way merge
```

- **base** = publisher v1
- **theirs** = publisher v2
- **ours** = consumer's modified files
- Result: 3-way merge preserves consumer's customizations, integrates publisher
  changes. Conflicts on same-line edits → interactive merge (A/M/R/K/S/D/N).

### Scenario 3 — Consumer uses `--local`, then publisher updates

```
Framework v1 ──→ Framework v2
     ↓
Publisher v1 ──→ (not yet updated) ──→ Publisher v2 (integrates Fw v2)
     ↓
Consumer installs → Consumer --local (applies Fw v2 directly)
                  → cco project update → 3-way merge
```

- **base** = publisher v1 (unchanged — `--local` does not update base)
- **theirs** = publisher v2
- **ours** = consumer's files (with framework v2 applied via `--local`)
- Result: 3-way merge. If publisher integrated the same changes → auto-resolve.
  If publisher customized differently → conflict → interactive merge.

### Scenario 4 — Consumer customizes + uses `--local` + publisher updates

Same mechanics as scenario 3, but with more files potentially in conflict.
The interactive merge handles file-by-file.

### Scenario 5 — Publisher inactive (abandoned project)

Consumer uses `--local` repeatedly. The project de facto becomes local with an
orphaned remote source.

Explicit resolution: `cco project internalize <name>` removes `.cco/source`,
converting the project to local. From that point `cco update --sync` treats it
as a local project with full framework tracking.

### Scenario 6 — Publisher removes or renames files

- File in base but not in theirs → offered for removal: (D)elete / (K)eep
- File renamed → appears as delete + new → consumer decides independently
- New file in theirs not in base → offered as (N)ew addition

### Scenario 7 — Consumer adds files not in publisher

- File only in ours, not in base or theirs → ignored by merge (purely local)
- No conflict, no action needed

### Scenario 8 — Pack updates (full-replace)

Packs use full-replace semantics (not 3-way merge). If a consumer modifies a
pack, the update overwrites changes. To preserve modifications:
- `cco pack internalize <name>` before modifying (disconnects from source)
- Or fork the pack in the Config Repo

This is intentional: packs are mounted read-only in containers, so
customization should happen via fork, not in-place editing.

---

## 5. Unified Discovery

### 5.1 Current State

`cco update` reports:
- Pending migrations (global + all projects)
- Framework file changes (defaults vs installed)
- Changelog notifications (additive changes)

It does **not** check remote sources.

### 5.2 Proposed Enhancement

`cco update` becomes the single entry point for "what's new?":

```
$ cco update

Global config:
  ✓ No pending migrations
  ℹ 2 files updated in defaults (run 'cco update --sync' to review)

Project 'local-app' (local):
  ✓ No pending migrations
  ℹ 1 file updated in defaults (run 'cco update --sync local-app' to review)

Project 'team-service' (installed from github.com/team/config):
  ✓ 1 migration applied
  ℹ Publisher update available (3 files changed, 2 new)
    → run 'cco project update team-service' to review
  ℹ 2 framework defaults also updated (managed by publisher)

Pack 'react-guidelines' (installed from github.com/team/config):
  ℹ Update available (v1.2 → v1.3)
    → run 'cco pack update react-guidelines' to review

Changelog:
  2 new features since last check (run 'cco update --news' for details)
```

Key aspects:
- Each project is labeled with its type: `(local)` or `(installed from ...)`
- For installed projects, framework updates are noted as "managed by publisher"
- Action commands are specific: `cco update --sync` for framework, `cco project
  update` for publisher, `cco pack update` for packs

### 5.3 Network Access Policy

Remote version checks require network access (git fetch). Policy:

- **Default (`cco update`)**: check remotes. Most users run `cco update`
  intentionally and expect a complete picture. The fetch is shallow
  (single commit) and fast.
- **`--offline` flag**: skip remote checks entirely. For air-gapped environments
  or when the user only wants framework status.
- **Cache**: remote HEAD hash is cached in `.cco/meta` with a timestamp.
  Subsequent `cco update` calls within a configurable TTL (default: 1 hour)
  reuse the cached value. `--no-cache` forces a fresh fetch.
- **Failure handling**: if a remote is unreachable, warn and continue. Never
  block the entire update process for a network issue.

---

## 6. Publish Safety Analysis

### 6.1 Risks

1. **Local content leakage**: personal paths, usernames, private notes in
   CLAUDE.md or rules
2. **Unintentional modifications**: debug/test changes left in files
3. **Regression**: overwriting a previous published change without awareness
4. **Schema mismatch**: publishing a project with outdated schema forces
   consumers to deal with migrations the publisher should have run

### 6.2 Pre-Publish Checks

The publish pipeline requires the following checks in order:

| # | Check | Severity | Action on failure |
|---|-------|----------|-------------------|
| 1 | **Migration check** | Blocking | Project must have `schema_version == latest`. Error: "Run `cco update` first." |
| 2 | **Framework alignment** | Warning | Report pending framework file updates. Non-blocking — publisher may intentionally diverge. |
| 3 | **Secret scan** | Blocking | Reuse vault's secret detection patterns. Block if `.env`, `*.key`, credentials patterns found in publishable files. |
| 4 | **Publish-ignore** | Filter | Apply `.cco/publish-ignore` exclusions (gitignore syntax). Exclude matched files from the publish set. |
| 5 | **Reverse-template** | Transform | Replace local paths with `{{VAR}}` placeholders. Already implemented. |
| 6 | **Diff review** | Interactive | Show per-file diff vs last published version. Publisher confirms each file. |
| 7 | **Confirmation** | Interactive | Final prompt before push. |

### 6.3 `.cco/publish-ignore`

Optional file in the project directory, gitignore syntax:

```
# Don't publish local notes
.claude/rules/local-*.md
.claude/rules/personal-*.md
memory/
*.local
```

Files matching these patterns are excluded from the publish set. The file
itself is also excluded (never published).

### 6.4 Diff Review UX

```
$ cco project publish myapp my-remote

✓ Migrations up to date (schema_version: 9)
⚠ 2 framework defaults have updates not yet applied
  (run 'cco update --sync myapp' to review — or continue)
  Continue? [Y/n]

✓ No secrets detected
✓ 1 file excluded by .cco/publish-ignore

Changes vs last published version (abc123f):
  M .claude/CLAUDE.md          (+12 -3)
  M .claude/rules/workflow.md  (+5 -1)
  A .claude/skills/deploy/     (NEW)
  D .claude/rules/old-rule.md  (REMOVED)

Review each file? [Y/n/publish-all]

  .claude/CLAUDE.md (+12 -3)
  (P)ublish / (S)kip / (D)iff / (A)bort: _
```

### 6.5 First Publish

When no previous published version exists (first publish), the diff review
shows all files as new. The migration and secret checks still apply.

---

## 7. Version Metadata

### 7.1 Purpose

Git commit hashes provide precise version comparison. Version labels provide
human-readable communication in discovery output and user guides.

### 7.2 Implementation

Optional `version:` field in `.cco/source`:

```yaml
source: https://github.com/team/config.git
path: templates/my-service
ref: main
version: "1.3.0"           # Human-readable, set by publisher
commit: abc123f             # Precise, set by install/update
installed: 2026-03-05
updated: 2026-03-17
```

The publisher sets `version` explicitly (e.g., via `pack.yml` or template
metadata). The `commit` field is always set automatically from the fetched
HEAD. Discovery uses `version` for display when available, falls back to
commit hash prefix.

### 7.3 No Enforcement

Version labels are informational only. The system uses commit hashes for
actual comparison. Publishers are not required to use semantic versioning
or any specific format.

---

## 8. `cco project internalize`

When a consumer wants to permanently disconnect from a remote source:

```bash
cco project internalize myapp
```

This command:
1. Removes `.cco/source` (or sets `source: local`)
2. Updates `.cco/base/` to use framework base template as the merge ancestor
3. The project is now fully local — `cco update --sync` applies framework
   updates directly

Use cases:
- Publisher abandoned the project
- Consumer wants to diverge permanently
- Project was installed as a starting point, not for ongoing sync

Note: `cco pack internalize` already exists with equivalent semantics.

---

## 9. UX Summary

### 9.1 Command Responsibilities

| Command | Scope | What it does |
|---------|-------|-------------|
| `cco update` | All | Unified discovery: migrations + framework changes + remote updates + changelog |
| `cco update --sync [scope]` | Framework | Interactive merge of framework file changes. On installed projects: applies migrations, reports but skips opinionated files |
| `cco update --sync <project> --local` | Framework (forced) | Applies framework files even on installed project (escape hatch) |
| `cco project update <name>` | Publisher → Consumer | Fetch remote, 3-way merge from publisher source |
| `cco project update --all` | Publisher → Consumer | Update all installed projects |
| `cco pack update <name>` | Publisher → Consumer | Fetch remote, full-replace from publisher source |
| `cco project publish <name> <remote>` | Consumer → Publisher | Push to Config Repo with safety checks |
| `cco project internalize <name>` | Source management | Disconnect from remote, convert to local |

### 9.2 User Mental Model

- **"What's new?"** → `cco update`
- **"Apply framework improvements"** → `cco update --sync`
- **"Get publisher's latest version"** → `cco project update <name>`
- **"Share my project"** → `cco project publish <name> <remote>`
- **"Stop receiving publisher updates"** → `cco project internalize <name>`

---

## 10. Cross-References

| Topic | Document |
|-------|----------|
| Resource lifecycle foundations | `../resource-lifecycle/analysis.md` |
| Update system design | `../update-system/design.md` |
| Config Repo / sharing design | `./design.md` |
| Vault profiles design | `../vault/design.md` |
| FI-7 in roadmap | `../../decisions/roadmap.md` § FI-7 |
| FI-7 overview | `../../decisions/framework-improvements.md` § FI-7 |
| FI-7 design | `./publish-install-sync-design.md` |
| User guide | `../../../user-guides/configuration-management.md` |
