# Vault File Classification

**Status**: Canonical reference
**Date**: 2026-03-31
**Scope**: Definitive classification of every file in the vault directory tree
**Related**: `analysis.md` (§8 resource matrix), `../update-system/design.md` (§3 policy map),
`../sharing/design.md` (§8 gitignore), `profile-isolation-design.md` (§2.2 sharing)

---

## 1. Purpose

This document is the **single source of truth** for how every file in the vault
(`user-config/`) directory is classified, tracked, and presented to users. It
consolidates information previously spread across four design documents and
defines UX visibility rules not covered elsewhere.

**Use this document when:**
- Adding a new file type to the vault
- Modifying gitignore patterns
- Changing vault save/diff output
- Implementing publish/install exclusions
- Designing profile sync behavior

---

## 2. Classification Taxonomy

Every file in the vault belongs to exactly one class:

| Class | Description | Committed | Gitignored | User-visible |
|-------|-------------|-----------|------------|-------------|
| **user-config** | User-owned content — the reason the vault exists | Yes | No | Yes |
| **framework-tracking** | Merge ancestors, origin tracking — needed for update system across machines | Yes | No | Filtered |
| **framework-metadata** | Schema version, file hashes, changelog markers — machine-regenerable state | No | Yes | No |
| **runtime-generated** | Created by `cco start`, cleaned by `cco clean` | No | Yes | No |
| **session-state** | Transcripts, credentials, temporary data | No | Yes | No |
| **machine-specific** | Per-PC paths, tokens, profile stash — does not travel between machines | No | Yes | No |
| **secrets** | Sensitive data that must never be committed | No | Yes | No |

### Why framework-tracking is committed but framework-metadata is not

**`.cco/base/`** (framework-tracking) stores the ancestor version of tracked files.
Without it, 3-way merge in `cco update --sync` cannot distinguish "user changed X"
from "framework changed X". It must be committed so all machines share the same
merge ancestor. Losing it degrades merge quality silently.

**`.cco/meta`** (framework-metadata) stores schema version, file hashes, changelog
markers, and policy state. This data is **machine-regenerable**: migrations are
idempotent (safe to re-run), hashes are recalculated from committed base files,
changelog markers are per-user (each machine shows notifications independently),
and `updated_at` timestamps would cause constant merge conflicts. The profile switch
system treats `.cco/meta` as local state (saved/restored alongside `claude-state`
and `local-paths.yml`).

---

## 3. Master Classification Table

### 3.1 Global Scope — `global/`

| File | Class | Committed | Update Policy | Profile Sharing |
|------|-------|-----------|---------------|-----------------|
| `global/.claude/CLAUDE.md` | user-config | Yes | opinionated | Always shared |
| `global/.claude/settings.json` | user-config | Yes | opinionated | Always shared |
| `global/.claude/mcp.json` | user-config | Yes | untracked | Always shared |
| `global/.claude/rules/*.md` | user-config | Yes | opinionated | Always shared |
| `global/.claude/agents/*.md` | user-config | Yes | opinionated | Always shared |
| `global/.claude/skills/*/` | user-config | Yes | opinionated | Always shared |
| `global/setup.sh` | user-config | Yes | copy-if-missing | Always shared |
| `global/setup-build.sh` | user-config | Yes | copy-if-missing | Always shared |
| `global/.claude/.cco/base/` | framework-tracking | Yes | — | Always shared |
| `global/.claude/.cco/meta` | framework-metadata | No | — | N/A (gitignored) |
| `global/claude-state/` | session-state | No | — | N/A (gitignored) |

### 3.2 Project Scope — `projects/<name>/`

| File | Class | Committed | Update Policy | Profile Sharing |
|------|-------|-----------|---------------|-----------------|
| `projects/*/project.yml` | user-config | Yes | untracked | Exclusive |
| `projects/*/.claude/CLAUDE.md` | user-config | Yes | opinionated | Exclusive |
| `projects/*/.claude/settings.json` | user-config | Yes | opinionated | Exclusive |
| `projects/*/.claude/rules/*.md` | user-config | Yes | untracked | Exclusive |
| `projects/*/.claude/agents/*.md` | user-config | Yes | untracked | Exclusive |
| `projects/*/.claude/skills/*/` | user-config | Yes | varies (*) | Exclusive |
| `projects/*/setup.sh` | user-config | Yes | copy-if-missing | Exclusive |
| `projects/*/mcp-packages.txt` | user-config | Yes | copy-if-missing | Exclusive |
| `projects/*/memory/` | user-config | Yes | — | Exclusive |
| `projects/*/.cco/source` | framework-tracking | Yes | — | Exclusive |
| `projects/*/.cco/source-url` | framework-tracking | Yes | — | Exclusive |
| `projects/*/.cco/base/` | framework-tracking | Yes | — | Exclusive |
| `projects/*/.cco/meta` | framework-metadata | No | — | N/A (gitignored) |
| `projects/*/.cco/docker-compose.yml` | runtime-generated | No | — | N/A (gitignored) |
| `projects/*/.cco/managed/` | runtime-generated | No | — | N/A (gitignored) |
| `projects/*/.tmp/` | runtime-generated | No | — | N/A (gitignored) |
| `projects/*/.cco/claude-state/` | session-state | No | — | N/A (gitignored) |
| `projects/*/rag-data/` | session-state | No | — | N/A (gitignored) |
| `projects/*/.cco/local-paths.yml` | machine-specific | No | — | N/A (gitignored) |
| `projects/*/.cco/project.yml.pre-save` | machine-specific | No | — | N/A (gitignored) |
| `projects/*/secrets.env` | secrets | No | copy-if-missing | N/A (gitignored) |

(*) Project skills: `untracked` for base template projects; `opinionated` for native
template projects (e.g., tutorial) where `.cco/source` identifies the template source.

### 3.3 Pack Scope — `packs/<name>/`

| File | Class | Committed | Update Policy | Profile Sharing |
|------|-------|-----------|---------------|-----------------|
| `packs/*/.claude/` | user-config | Yes | opinionated | Shared or exclusive |
| `packs/*/.cco/source` | framework-tracking | Yes | — | With pack |
| `packs/*/.cco/source-url` | framework-tracking | Yes | — | With pack |
| `packs/*/.cco/meta` | framework-metadata | Yes (*) | — | With pack |
| `packs/*/.cco/base/` | framework-tracking | Yes | — | With pack |
| `packs/*/.cco/install-tmp/` | runtime-generated | No | — | N/A (gitignored) |

(*) Pack `.cco/meta` is committed (not gitignored) — unlike project/global meta.
This is because pack meta travels with the pack and is needed for update detection
when packs are shared across profiles.

### 3.4 Template Scope — `templates/<name>/`

| File | Class | Committed | Update Policy | Profile Sharing |
|------|-------|-----------|---------------|-----------------|
| `templates/*/` (all files) | user-config | Yes | untracked | Always shared |
| `templates/*/.cco/meta` | framework-metadata | Yes | — | Always shared |

### 3.5 Vault Root

| File | Class | Committed | Profile Sharing |
|------|-------|-----------|-----------------|
| `.gitignore` | user-config | Yes | Always shared |
| `manifest.yml` | user-config | Yes | Always shared |
| `.vault-profile` | user-config | Yes | Per-branch |
| `.cco/remotes` | machine-specific | No | N/A (gitignored) |
| `.cco/internal/` | runtime-generated | No | N/A (gitignored) |
| `.cco/profile-state/` | machine-specific | No | N/A (gitignored) |
| `.cco/backups/` | machine-specific | No | N/A (gitignored) |
| `.cco/profile-ops.log` | machine-specific | No | N/A (gitignored) |

---

## 4. Per-Operation Behavior Matrix

### 4.1 `cco vault save` — What gets committed

| Class | Included in commit | Shown in summary |
|-------|--------------------|-----------------|
| user-config | Yes | Yes — categorized (packs/projects/global/templates) |
| framework-tracking | Yes | Yes — as "metadata" (`.cco/base/`, `.cco/source`) |
| framework-metadata | No (gitignored) | No |
| runtime-generated | No (gitignored) | No |
| session-state | No (gitignored) | No |
| machine-specific | No (gitignored) | No |
| secrets | No (gitignored) | No (warned if staged) |

**UX rule**: The change summary should distinguish user content from framework
tracking files. Framework-tracking files (`.cco/base/`, `.cco/source`) are
committed but are internal bookkeeping — users don't need to review them.

### 4.2 `cco vault diff` — What users see

| Class | Shown in diff output |
|-------|---------------------|
| user-config | Yes — grouped by category |
| framework-tracking | Filtered — shown under separate "Framework" heading |
| Others | Not shown (gitignored) |

**UX rule**: Framework-tracking files should not be mixed with user changes.
They should either be hidden entirely or shown in a clearly separate section.

### 4.3 `cco vault push/pull` — What travels between machines

| Class | Travels | Notes |
|-------|---------|-------|
| user-config | Yes | The core content |
| framework-tracking | Yes | Needed for correct merge on remote machines |
| framework-metadata | No | Machine-regenerable; migrations are idempotent |
| runtime-generated | No | Regenerated by `cco start` |
| session-state | No | Machine-local |
| machine-specific | No | Per-PC by definition |
| secrets | No | Never committed |

### 4.4 `cco project publish` — What gets published

| Class | Published | Notes |
|-------|-----------|-------|
| user-config (except memory) | Yes | Core project template |
| user-config (memory/) | **No** | Personal, not shareable |
| framework-tracking | **No** | `.cco/` excluded entirely |
| secrets | **No** | `secrets.env` excluded |

Exclusion logic in `_copy_project_for_publish()`:
- Top-level excludes: `.cco`, `memory`, `secrets.env`
- Nested `.cco/` directories inside `.claude/` removed post-copy
- Additional patterns via `.cco/publish-ignore` (user-configurable)

### 4.5 `cco project install` — What gets installed

| Class | Installed | Notes |
|-------|-----------|-------|
| user-config | Yes | Project template content |
| framework-tracking | Created fresh | New `.cco/source`, `.cco/meta`, `.cco/base/` |
| machine-specific | Created on first use | `local-paths.yml` created by `cco start` or `cco project resolve` |
| secrets | Scaffolded | `secrets.env` via copy-if-missing |

### 4.6 Profile Sync — Shared resource propagation

Shared resources are synced from main to profile branches (or vice versa) by
`_sync_shared_to_all_profiles()`. The shared path list is defined by
`_list_shared_paths()`:

| Path | Shared | Rationale |
|------|--------|-----------|
| `global/` | Always | Global config applies to all profiles |
| `templates/` | Always | Templates are shared infrastructure |
| `manifest.yml` | Always | Sharing manifest is vault-wide |
| `.gitignore` | Always | Vault structure is shared |
| `packs/<name>/` (shared) | Always | Default; non-exclusive packs |
| `packs/<name>/` (exclusive) | Never | Owned by one profile only |
| `projects/<name>/` | Never | Always exclusive to one profile |

---

## 5. Gitignore Reference

Canonical patterns for `_VAULT_GITIGNORE` in `lib/cmd-vault.sh`. Each pattern
is linked to its classification. When adding patterns, update this table.

```
# ── Secrets (class: secrets) ────────────────────────────────────
secrets.env
*.env
.credentials.json
*.key
*.pem

# ── Runtime-generated (class: runtime-generated) ────────────────
# Generated by cco start, regenerated each session
projects/*/.cco/managed/
projects/*/.cco/docker-compose.yml
projects/*/.tmp/

# ── Framework metadata (class: framework-metadata) ──────────────
# Machine-regenerable: schema version, file hashes, changelog markers.
# Migrations are idempotent; hashes recalculated from committed base.
# NOT committed so updated_at doesn't cause merge conflicts.
projects/*/.cco/meta
global/.claude/.cco/meta

# ── Session state (class: session-state) ─────────────────────────
# Transcripts, credentials, RAG data — large, personal, transient
global/claude-state/
projects/*/.cco/claude-state/
projects/*/rag-data/

# ── Machine-specific (class: machine-specific) ──────────────────
# Per-PC paths, remote tokens, profile operation state
projects/*/.cco/local-paths.yml
projects/*/.cco/project.yml.pre-save
.cco/remotes
.cco/profile-state/
.cco/backups/
.cco/profile-ops.log

# ── Internal / temporary (class: runtime-generated) ─────────────
.cco/internal/
packs/*/.cco/install-tmp/
projects/*/.claude/.cco/pack-manifest

# ── Update artifacts (class: runtime-generated) ─────────────────
*.bak
*.new
```

### What is NOT gitignored (and why)

| File | Class | Why it must be committed |
|------|-------|------------------------|
| `.cco/base/` | framework-tracking | Ancestor for 3-way merge. Without it, `cco update --sync` falls back to best-effort, surfacing false conflicts. |
| `.cco/source` | framework-tracking | Tracks where a project/pack was installed from. Needed for `cco project update` and template discovery. |
| `.cco/source-url` | framework-tracking | Remote URL for update checks. |
| `memory/` | user-config | Auto-memory files sync across machines via vault (design D33). Each machine's Claude sessions contribute to shared memory. |
| `packs/*/.cco/meta` | framework-metadata (*) | Exception: pack meta IS committed because it travels with the pack across profiles. |
| `templates/*/.cco/meta` | framework-metadata (*) | Exception: template meta IS committed for the same reason. |

---

## 6. UX Visibility Rules

### 6.1 `vault save` summary categories

The change summary groups committed files into user-meaningful categories:

| Category | Paths | Description |
|----------|-------|-------------|
| **Packs** | `packs/*` | Knowledge packs |
| **Projects** | `projects/*` (excluding `.cco/`) | Project configs, rules, memory |
| **Global** | `global/*` (excluding `.cco/`) | Global settings, agents, skills, rules |
| **Templates** | `templates/*` | Project and pack templates |
| **Metadata** | `*/.cco/base/*`, `*/.cco/source*`, `.gitignore`, `manifest.yml`, `.vault-profile` | Framework tracking and vault structure |

**Rules**:
- Framework-tracking files (`.cco/base/`, `.cco/source`) are counted under
  "Metadata", not mixed with user content categories
- The metadata count is shown separately and only when non-zero
- `.gitignore` and `manifest.yml` are vault infrastructure, grouped with metadata

### 6.2 `vault diff` display

- **User content** is grouped and shown by category (Packs, Projects, Global, Templates)
- **All `.cco/` internal files** are classified as "Metadata" and shown separately
  - This includes framework-tracking (`.cco/base/`, `.cco/source`) and any other
    `.cco/` file that might escape gitignore (defense-in-depth)
  - The `*/.cco/*` catch-all filter in the categorization code ensures no `.cco/`
    file appears under user-content categories
- Users should never wonder "did I accidentally edit `.cco/base/`?"
- **Local path normalization**: `vault diff` runs `_extract_local_paths` /
  `_restore_local_paths` before reading git status. Without this, `project.yml`
  always appears modified (real paths vs committed `@local` markers). This
  matches the normalization in `vault save` and prevents UX inconsistency
  (diff showing changes that save says don't exist).

### 6.3 Pre-commit messages

- "Nothing to commit — vault is up to date" when no real changes exist
  (virtual path diffs are eliminated by pre-extraction)
- Secret warning if `secrets.env` or credential files are staged
- Shared sync warning if Docker sessions prevent profile propagation
- Shared sync preview: when profiles exist and shared resources (global,
  templates, packs) are among the changes, vault save shows an informational
  line before the prompt indicating cross-profile propagation

---

## 7. Adding New File Types

When introducing a new file in the vault directory tree:

1. **Classify it** using the taxonomy in §2
2. **Add to the master table** in §3
3. **Add gitignore pattern** if class requires it (§5)
4. **Update `_VAULT_GITIGNORE`** in `lib/cmd-vault.sh`
5. **No migration required for pattern-only changes** (see §8 —
   `_ensure_vault_gitignore` self-heals every branch on next vault op).
   Migrations are still needed for schema-breaking moves/renames.
6. **Update per-operation tables** in §4 if the file has special behavior
7. **Update publish exclusions** in `_copy_project_for_publish()` if needed
8. **Update profile shared paths** in `_list_shared_paths()` if applicable
9. **Update this document** — it is the canonical reference

---

## 8. Runtime Invariants

Migrations that update `.gitignore` (006, 009, 012, 013) only touch the
currently checked-out branch. Profile branches created *before* a new
pattern was added never receive the pattern, and machine-specific files
like `projects/*/.cco/project.yml.pre-save` then surface as untracked
`??` entries on those branches forever.

To avoid repeating that class of problem, three runtime invariants run
at every vault operation (invoked from `_check_vault` and at specific
points in the profile-switch flow):

| Helper | Scope | Site | Purpose |
|---|---|---|---|
| `_ensure_vault_gitignore` | current branch | `_check_vault`, `cmd_vault_status`, `cmd_vault_profile_switch` (post-checkout) | Append any missing pattern from `_VAULT_GITIGNORE`. Respects user-commented patterns (never reverts a deliberate bypass). Silent commit if needed. |
| `_untrack_stale_pre_save` | current branch | same as above | `git rm --cached` any `project.yml.pre-save` tracked from pre-migration bugs. |
| `_normalize_committed_paths` | current branch | same as above | Upgrade legacy project.yml committed with real host paths to `@local`. Saves the real paths into `.cco/local-paths.yml` first so the PC keeps the mapping. Stages via `git hash-object -w` + `update-index`; the WORKING TREE is never touched (design: working=real, committed=`@local`). |
| `_clean_branch_ghost_projects` | current branch | `cmd_vault_profile_switch` (post-checkout) | Remove `projects/<X>/` directories whose content is entirely gitignored residue of another branch. Also prune orphan `.cco/profile-state/<branch>/` shadows. |

**Rule for new code**: if you introduce a machine-specific file class
whose presence must never be committed, add the pattern to
`_VAULT_GITIGNORE` and rely on `_ensure_vault_gitignore` to propagate
it — do not write a migration just for the pattern. For schema/path
renames, migrations are still needed.

**Design pointer**: the invariants codify the single-source-of-truth
principle from [coding-conventions](../../architecture/coding-conventions.md) —
gitignore patterns are defined once in `_VAULT_GITIGNORE` and every
branch derives from it.
