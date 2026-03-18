# Update System — Base Tracking Bug Analysis

**Date**: 2026-03-18
**Scope**: Update system — base version tracking for project-scoped files
**Status**: Analysis complete
**Related**: `design.md` (update system design), `../../decisions/framework-improvements.md` (FI-7)

---

## 1. Problem Statement

`cco update --diff` reports false positives for **every project** with customized
CLAUDE.md files. All projects show `BASE_MISSING` status and display diffs comparing
user-written content against the raw template with unresolved `{{PLACEHOLDER}}` markers.

### Symptoms

```
ℹ Project 'cave-auth': opinionated updates available:
ℹ   1 file(s) with missing base (BASE_MISSING)
```

The diff output shows:

```diff
--- your version
+++ new default
-# Project: cave-auth
+# Project: {{PROJECT_NAME}}

 ## Overview
+{{DESCRIPTION}}
-Cave Auth è il sistema di autenticazione centralizzato...
```

This occurs for **all** projects created via `cco project create` from the base template.

### Impact

- Users see spurious update notifications on every `cco update`
- `cco update --sync` would offer to replace customized CLAUDE.md with the raw template
- Trust in the update system is undermined — users learn to ignore notifications
- `cco project publish` warns about "unapplied framework defaults" (false alarm)

---

## 2. Root Cause

Two co-occurring bugs, one historical and one latent.

### Bug A (primary): CLAUDE.md became tracked without a migration

CLAUDE.md was changed from `untracked` to `tracked` in `PROJECT_FILE_POLICIES`
on 2026-03-17 (commit `ac81cc4`). All existing projects were created **before**
this change (earliest: 2026-03-13), so their `.cco/base/` never included
CLAUDE.md — `_save_all_base_versions` only copies files matching the policy list
that was active at creation time.

**No migration was added** to seed `.cco/base/CLAUDE.md` for existing projects
when the policy changed. This is why all projects show `BASE_MISSING`.

Evidence: every project's `.cco/base/` contains only `settings.json` (which was
always tracked), never `CLAUDE.md`:

```
cave-auth/.cco/base/       → settings.json only
caveresistance-server/.cco/base/ → settings.json only
claude-orchestrator/.cco/base/   → settings.json only
marius/.cco/base/                → settings.json only
testing/.cco/base/               → settings.json only
```

### Bug B (latent): Base saved from raw template instead of interpolated copy

In `lib/cmd-project.sh`, the project creation flow is:

1. **Line 64**: Copy raw template (with `{{PLACEHOLDER}}`) to project directory
2. **Lines 66-87**: Interpolate placeholders via `sed` in the copied files
3. **Line 211**: Save base versions — **from the raw template directory, not the interpolated copy**

```bash
# cmd-project.sh:211 — BUG: $defaults_dir points to raw template
_save_all_base_versions "$project_dir/.cco/base" "$defaults_dir" "project"
```

The `$defaults_dir` variable resolves to `templates/project/base/.claude/` which
contains `{{PROJECT_NAME}}`, `{{DESCRIPTION}}`, etc. The base should reflect the
**interpolated** state of the file as delivered to the user.

This bug is **latent** — it hasn't been observed yet because Bug A masks it. All
current projects predate the policy change, so CLAUDE.md was never saved to base
at all. But for any project created **after** the policy change, the base would
contain raw placeholders, causing incorrect three-way merge behavior.

### Combined effect

`base_hash` is empty (CLAUDE.md not in `.cco/base/`) → `_collect_file_changes`
falls into the `BASE_MISSING` branch (update.sh:613-620) → compares raw template
hash against installed hash → always different → false positive for every project.

---

## 3. Affected Flows

### 3.1 `cco project create` (all templates with placeholders)

| Template | Placeholders in CLAUDE.md | Affected? |
|----------|--------------------------|-----------|
| `project/base` | `{{PROJECT_NAME}}`, `{{DESCRIPTION}}`, `cc-{{PROJECT_NAME}}` | **Yes** |
| `project/config-editor` | `{{PROJECT_NAME}}` (description hardcoded) | **Yes** |
| `internal/tutorial` | None (all hardcoded) | No |
| User templates | Depends on content | If they use `{{...}}` in tracked files |

### 3.2 `cco project install` (remote)

Remote-installed projects fall back to `templates/project/base/.claude` for
opinionated file comparison (`_resolve_project_defaults_dir`, update.sh:1798-1801).
Same bug applies: raw template with placeholders vs interpolated user content.

### 3.3 `cco update --diff` / `cco update --sync`

Both use `_collect_file_changes` which reads the base. With missing/raw base,
the classification is wrong:
- Should be `USER_MODIFIED` or `NO_UPDATE` → reports `BASE_MISSING` instead
- Three-way merge is impossible without a correct base

### 3.4 `cco project publish` (alignment check)

`cmd-project.sh:1091` calls `_collect_file_changes` before publishing. False
`BASE_MISSING` results trigger a warning that blocks the publish flow.

---

## 4. Template and Placeholder Inventory

### All placeholders across the system

| Placeholder | Used in | Source at creation | Recoverable at update? |
|---|---|---|---|
| `{{PROJECT_NAME}}` | base CLAUDE.md, base project.yml, config-editor CLAUDE.md, config-editor project.yml | CLI arg / directory name | **Yes** — always = directory name |
| `{{DESCRIPTION}}` | base CLAUDE.md, base project.yml | `--description` flag or interactive prompt | **Partial** — stored in `project.yml`, but often stale (`TODO: Add project description`) while CLAUDE.md is rewritten by agents |
| `{{CCO_REPO_ROOT}}` | config-editor project.yml, tutorial project.yml | Runtime path | **Yes** — always available |
| `{{CCO_USER_CONFIG_DIR}}` | config-editor project.yml, tutorial project.yml | Runtime path | **Yes** — always available |
| `{{COMM_LANG}}` etc. | global `language.md` | `.cco/meta` | **Yes** — already handled (generated file policy) |
| `{{PACK_NAME}}` | pack `pack.yml` | CLI arg / directory name | **Yes** — packs are not update-tracked |

### Key insight: `{{DESCRIPTION}}` is user content, not framework structure

The description placeholder exists only in the base template. After creation, the
user (or `/init-workspace`) replaces the entire Overview section with rich,
project-specific content. The original placeholder value becomes irrelevant.

This means `{{DESCRIPTION}}` **cannot be reliably re-interpolated** at update time:
- `project.yml` stores it, but it's often `"TODO: Add project description"`
- CLAUDE.md content diverges completely from the original value
- It's semantically user content, not framework scaffolding

### How `_resolve_project_defaults_dir` picks the comparison target

```
.cco/source absent     → templates/project/base/.claude  (raw, with placeholders)
native:project/<name>  → templates/project/<name>/.claude (may have placeholders)
user:template/<name>   → user-config/templates/project/<name>/.claude
source:https://...     → templates/project/base/.claude   (fallback to base)
```

In all cases where the resolved directory contains `{{PLACEHOLDER}}` in tracked
files, the diff produces false positives.

---

## 5. Approaches Evaluated

### Path A: Fix base tracking (save interpolated base)

Fix `_save_all_base_versions` to save from the interpolated project directory
instead of the raw template. Add migration for existing projects.

- **Pro**: Correct by construction; three-way merge works for all future updates
- **Pro**: Covers all template types uniformly
- **Con**: Existing projects need a migration to create synthetic base
- **Feasibility**: High

### Path B: Interpolate templates at update-time

Before diffing, resolve `{{PLACEHOLDER}}` in the template with known values.

- **Pro**: No persistent state needed
- **Con**: `{{DESCRIPTION}}` value is often stale/wrong — can't produce correct interpolation
- **Con**: Custom/user templates may have arbitrary placeholders
- **Con**: Structurally complex (would need a "semantic diff" that ignores user-content regions)
- **Feasibility**: Low (for a general solution); partial feasibility for `{{PROJECT_NAME}}` only

### Path C (recommended): Path A + minimal safety net from Path B

Fix base tracking (Path A) plus a lightweight guard that interpolates `{{PROJECT_NAME}}`
in the template before hashing during `_collect_file_changes`. This catches edge
cases where base might be absent or corrupted.

- **Pro**: Correct base tracking + defense in depth
- **Pro**: Safety net is ~5 lines, no complexity burden
- **Con**: Negligible — `PROJECT_NAME` is always available
- **Feasibility**: High

---

## 6. Decision

**Proceed with Path C** (Path A + safety net). See `base-tracking-fix-design.md`
for the implementation design.
