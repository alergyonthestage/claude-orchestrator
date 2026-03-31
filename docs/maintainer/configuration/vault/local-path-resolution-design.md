# Local Path Resolution — Design

**Status**: Implemented
**Date**: 2026-03-31
**Scope**: Unified path portability for vault sync AND publish/install
**Analysis**: `../sharing/analysis.md` §10 (portability problems)
**Related**: `design.md` (vault sync), `../sharing/publish-install-sync-design.md`
(FI-7), `../../reference/project-yaml.md` (schema)

---

## 1. Problem Statement

`project.yml` contains machine-specific paths:

```yaml
repos:
  - path: ~/Projects/backend-api
    name: backend-api
extra_mounts:
  - source: ~/documents/api-specs
    target: /workspace/docs/api-specs
```

These paths break when the project config reaches a different machine — whether
via vault push/pull (same user, different PCs) or publish/install (different
users entirely).

### 1.1 Current State

| Scenario | Handling | Gaps |
|----------|----------|------|
| **Vault push/pull** | None — paths committed as-is | Paths from PC-A don't exist on PC-B |
| **Publish** | `_reverse_template_repos()` → `{{REPO_*}}` variables + `url:` | Extra mounts not handled; `url:` only for repos |
| **Install** | `_resolve_template_vars()` prompts for `REPO_*` + `_resolve_repo_entries()` offers clone | Two separate functions; extra mounts not resolved; path written directly to project.yml |
| **`cco start`** | `warn` + skip if path missing | Silent skip is confusing; no recovery mechanism |

Two independent mechanisms solve the same fundamental problem (machine-specific
paths in a portable config) with different markers (`{{REPO_*}}` vs nothing),
different storage (project.yml direct vs nothing), and different coverage
(repos only vs nothing for extra mounts).

### 1.2 Requirements

| # | Requirement | Priority |
|---|-------------|----------|
| R1 | User writes real paths in project.yml (same UX as today) | Must |
| R2 | Paths are absent from vault remote and published templates | Must |
| R3 | Each PC maintains its own path configuration | Must |
| R4 | Transparent: user sees real paths in their working copy | Must |
| R5 | `cco start` blocks when a repo path is unresolved (no silent skip) | Must |
| R6 | Unified approach: same mechanism for vault sync and publish/install | Must |
| R7 | `url:` field available in all flows (vault, publish, install, start) | Should |

### 1.3 Scope

This design unifies path portability across ALL sharing mechanisms:
- **Vault push/pull** (same user, different PCs)
- **Publish/install** (different users via Config Repos)
- **`cco start`** (resolution point for all scenarios)

The existing `_reverse_template_repos()` and `_resolve_repo_entries()` are
superseded by the unified path resolution system.

---

## 2. Approach: Unified Transparent Path Resolution

### 2.1 Overview

Separate **what repos a project uses** (portable, committed/published) from
**where they live on THIS machine** (local, gitignored).

Core principle: **`project.yml` in any remote (vault or Config Repo) never
contains machine-specific paths.** All paths are resolved locally via
`.cco/local-paths.yml`.

Three mechanisms work together:

1. **vault save / project publish** sanitize `project.yml` — replace real
   paths with `@local` markers, preserve `url:` metadata, store real paths
   in `.cco/local-paths.yml`
2. **vault pull / project install** initialize the local config — write
   resolved paths to `.cco/local-paths.yml` (from prompt or auto-clone)
3. **cco start** resolves `@local` markers at runtime — reads from
   `.cco/local-paths.yml`, prompts if missing, offers clone if `url:` exists

### 2.2 Why unify

| Benefit | Details |
|---------|---------|
| Consistent UX | Same prompt flow whether the user pulled from vault or installed from Config Repo |
| Extra mounts covered | Both repos AND extra_mounts are handled everywhere (publish currently ignores extra_mounts) |
| Single resolution point | `cco start` is the universal resolver — no more split between `_resolve_template_vars` + `_resolve_repo_entries` |
| `url:` everywhere | The clone-from-URL capability works after vault pull too, not only after install |
| One codebase | Shared `lib/local-paths.sh` module replaces three separate path-handling codepaths |

### 2.3 Alternatives Considered

| Approach | R1 | R2 | R3 | R4 | R6 | Complexity | Verdict |
|----------|----|----|----|----|-----|------------|---------|
| A: Save-time extraction only | Yes | Yes | Yes | Yes | No | High | Vault-only, doesn't cover publish |
| B: Env var `${VAR}` in YAML | No | Yes | Yes | No | Partial | Low | UX regression |
| C: Override-only (no sanitize) | Yes | **No** | Yes | Yes | Partial | Low | R2 violated |
| D: Git smudge/clean filters | Yes | Yes | Yes | Yes | No | High | Fragile in bash |
| E: Override + sanitize (vault only) | Yes | Yes | Yes | Yes | No | Medium | Superseded by F |
| **F: Unified @local + local-paths.yml** | **Yes** | **Yes** | **Yes** | **Yes** | **Yes** | **Medium** | **Selected** |

Approach F extends E to cover publish/install, replacing `{{REPO_*}}` with
`@local` and unifying the resolution chain.

---

## 3. Data Model

### 3.1 `.cco/local-paths.yml`

**Location**: `projects/<name>/.cco/local-paths.yml`
**Tracked**: No — gitignored (machine-specific)
**Created by**: `cco vault save` (auto-extracted), `cco project install`
(post-install resolution), `cco project resolve` (manual), or interactive
prompt on `cco start`

```yaml
# Machine-specific path mappings — auto-managed by cco
# Do not edit manually; use 'cco project resolve <name>' to update paths

repos:
  backend-api: ~/Projects/backend-api
  frontend-app: ~/dev/frontend-app

extra_mounts:
  /workspace/docs/api-specs: ~/documents/api-specs
```

**Key format**:
- **repos**: keyed by `name:` field (already required in project.yml)
- **extra_mounts**: keyed by `target:` path (the mount destination — analogous
  to `name:` for repos, as both identify the mount point under `/workspace/`)

### 3.2 `@local` marker

When paths are sanitized (vault save or publish), path values are replaced
with `@local`:

```yaml
# Committed/published version — portable
repos:
  - path: "@local"
    name: backend-api
    url: git@github.com:acme/backend-api.git
extra_mounts:
  - source: "@local"
    target: /workspace/docs/api-specs
    readonly: true
```

**Why `@local`**:
- Unambiguous — cannot be a real filesystem path
- Self-documenting — signals "resolve from local config"
- Grep-friendly — easy to detect programmatically
- Short — minimal noise in the committed file
- Universal — replaces both `{{REPO_*}}` (publish) and raw paths (vault)

### 3.3 `url:` field — portable metadata

The `url:` field on repo entries is **portable metadata that IS committed**.
It is NOT a path — it identifies the git repository for clone purposes.

```yaml
repos:
  - path: "@local"
    name: backend-api
    url: git@github.com:acme/backend-api.git   # committed — portable
```

**When `url:` is populated**:
- **vault save**: auto-extracted from `git remote get-url origin` (best-effort,
  same logic as current `_reverse_template_repos`)
- **project publish**: same extraction (already implemented)
- **project create**: not populated (user may not have pushed yet)
- **manual**: user can add `url:` to project.yml at any time

**When `url:` is used**:
- **cco start** prompt: if a repo path is missing and `url:` exists, offer
  auto-clone as an option
- **cco project resolve**: show URL as hint when asking for path
- **cco project install**: same clone offer as today

### 3.4 Extra mount identification

`target:` serves as the natural identifier for extra mounts (analogous to
`name:` for repos — both define the mount point). No new field needed.

If a future use case requires a human-friendly alias, an optional `name:`
field can be added (additive, backward compatible). The resolution logic
would check `name:` first, fall back to `target:`.

### 3.5 Vault .gitignore additions

```gitignore
# Machine-specific local path mappings
projects/*/.cco/local-paths.yml

# Temporary backup during vault save path extraction
projects/*/.cco/project.yml.pre-save
```

---

## 4. Flows

### 4.1 vault save — path extraction and sanitization

```
cmd_vault_save()
│
├─ (existing) Secret detection, change categorization, confirmation
│
├─ NEW: _extract_local_paths()
│   │
│   └─ For each project in projects/*/:
│       │
│       ├─ Read project.yml
│       ├─ Extract repos: name → path mapping (skip @local entries)
│       ├─ Extract extra_mounts: target → source mapping (skip @local)
│       ├─ Extract url: from git remotes (best-effort, same as publish)
│       ├─ Write/update .cco/local-paths.yml
│       ├─ Copy project.yml → .cco/project.yml.pre-save (backup)
│       ├─ Replace path:/source: values with "@local" in project.yml
│       └─ Inject url: fields if not already present
│
├─ (existing) git add -A + git commit
│
├─ NEW: _restore_local_paths()
│   │
│   └─ For each project with .cco/project.yml.pre-save:
│       ├─ Restore project.yml from backup
│       └─ Remove .cco/project.yml.pre-save
│
└─ (existing) Shared sync (profiles)
```

**url: injection during save**: vault save extracts `url:` from git remotes
(same logic as `_reverse_template_repos`) and writes it into the committed
project.yml alongside `@local`. The working copy is restored from backup, so
the user's project.yml is unchanged. The URL is portable metadata that helps
other PCs clone the repo.

**Safety mechanism**: The backup `.cco/project.yml.pre-save` is written BEFORE
any modification. If the process crashes:
- Next `cco vault save` detects the backup and restores before proceeding
- Next `cco start` detects `@local` markers and resolves from `local-paths.yml`
- The user is never left with unusable paths

**Edge cases**:
- Project with no repos and no extra_mounts: skipped
- Path already `@local` (never pulled on this PC): left as-is
- Mixed: some repos have real paths, some have `@local`: only real paths are
  extracted; `@local` entries are preserved

### 4.2 vault pull — post-pull path resolution

```
cmd_vault_pull()
│
├─ (existing) fetch, pull current branch, pull main, shared sync
│
└─ NEW: _resolve_all_local_paths()
    │
    └─ For each project in projects/*/:
        └─ _resolve_project_paths(project_dir)
            │
            ├─ Read project.yml
            ├─ For each entry with @local:
            │   ├─ Check .cco/local-paths.yml for mapping
            │   ├─ If found → substitute in project.yml working copy
            │   └─ If not found → leave @local (resolved at cco start)
            │
            └─ (silent, best-effort — no prompts)
```

Post-pull resolution is best-effort and silent. If `local-paths.yml` exists,
paths are restored. If it doesn't (first pull on a new PC), paths remain as
`@local` — the interactive prompt happens at `cco start` time.

### 4.3 vault switch — post-switch path resolution

Same as vault pull. After restoring gitignored files from shadow directory:

```
cmd_vault_profile_switch()
│
├─ (existing) Stash gitignored files, checkout, restore
│
└─ NEW: _resolve_all_local_paths()
```

`local-paths.yml` is a gitignored file preserved by the shadow directory
mechanism (`_stash_gitignored_files` / `_restore_gitignored_files`). Each
profile on each PC has its own path mappings.

### 4.4 project publish — sanitization (replaces `_reverse_template_repos`)

```
cmd_project_publish()
│
├─ (existing) Validation, secret scan, migration check
│
├─ CHANGED: _sanitize_project_paths() replaces _reverse_template_repos()
│   │
│   ├─ Read project.yml from published copy (in tmpdir)
│   ├─ Extract url: from git remotes (best-effort)
│   ├─ Replace path: values with "@local"
│   ├─ Replace source: values with "@local" (extra_mounts — NEW)
│   └─ Inject url: fields for repos
│
└─ (existing) Publish to Config Repo
```

Key differences from current `_reverse_template_repos()`:
- Uses `@local` instead of `{{REPO_BACKEND_API}}`
- Handles extra_mounts too (current code ignores them)
- Shares sanitization logic with vault save

### 4.5 project install — post-install resolution (replaces two-function flow)

```
cmd_project_install()
│
├─ (existing) Clone Config Repo, copy template, resolve non-path vars
│
├─ CHANGED: _resolve_template_vars() no longer handles REPO_* variables
│   │  Template vars like {{DESCRIPTION}}, {{PROJECT_NAME}} are still
│   │  resolved here. @local markers are left untouched.
│
├─ NEW: _resolve_installed_paths()
│   │
│   └─ For each repo/mount with @local:
│       ├─ If url: exists → offer clone (same as current _resolve_repo_entries)
│       ├─ Prompt: (c) Clone / (p) Specify path / (s) Skip / (q) Exit
│       ├─ Save resolved path to .cco/local-paths.yml
│       └─ Write resolved path to project.yml working copy
│
├─ (existing) Auto-install packs, write .cco/source
│
└─ info "Run: cco start $project_name"
```

The install-time prompt is more aggressive than start-time because the user
is actively setting up: all unresolved repos are prompted immediately (no
deferred resolution).

### 4.6 cco start — unified resolution chain

```
_start_resolve_paths()  [cmd-start.sh, NEW pre-compose step]
│
└─ For each repo from yml_get_repos():
    │
    ├─ Step 1: expand_path(path)
    │
    ├─ Step 2: Is path "@local" or legacy "{{REPO_*}}"?
    │   │
    │   ├─ Yes → _resolve_entry(project_dir, "repos", name)
    │   │   ├─ Read .cco/local-paths.yml → lookup by name
    │   │   ├─ If found and path exists → return resolved path
    │   │   ├─ If found but path doesn't exist → fall through to prompt
    │   │   └─ If not found → fall through to prompt
    │   │
    │   └─ No → check if expanded path exists
    │       ├─ Exists → use it
    │       └─ Doesn't exist → fall through to prompt
    │
    ├─ Step 3: Interactive prompt
    │   │
    │   ├─ Show: "Repository 'backend-api' not found"
    │   │   (if url: present): "  URL: git@github.com:acme/backend-api.git"
    │   │
    │   ├─ Options (TTY):
    │   │   (c) Clone to <suggested_path>     [only if url: present]
    │   │   (p) Specify path: ___________
    │   │   (s) Skip this repository
    │   │   (q) Exit
    │   │
    │   ├─ Non-TTY: abort with error + instruction to run cco project resolve
    │   │
    │   ├─ If cloned/specified → validate exists → save to .cco/local-paths.yml
    │   └─ Write resolved path to project.yml working copy
    │
    └─ Step 4: generate mount line (or skip if user chose 's')

    (same flow for extra_mounts, keyed by target)
```

**Clone target path**: when offering clone, suggest a path based on:
1. Sibling of other resolved repos (if any exist in local-paths.yml)
2. Default `~/Projects/<name>` (or `~/projects/<name>` on Linux)
3. User can override with (p) Specify path

**Skip behavior**: session starts without skipped repos. Warning shown. Skip
is NOT persisted — next `cco start` prompts again.

**Legacy `{{REPO_*}}`**: the resolution chain recognizes both `@local` (new)
and `{{REPO_*}}` patterns (legacy from pre-unification published templates).
Legacy markers are treated identically to `@local` for resolution. Over time,
re-publishing supersedes them.

### 4.7 `cco project resolve` — manual path configuration

New subcommand for explicit path management:

```
Usage: cco project resolve <project> [options]

Configure local paths for a project's repositories and mounts.

Without flags: interactive mode — shows all entries and prompts for unresolved.
With flags: set specific paths non-interactively.

Options:
  --repo <name> <path>      Set local path for a repository
  --mount <target> <path>   Set local path for an extra mount
  --show                    Show current path mappings (no changes)
  --reset                   Remove all local overrides (re-prompt on next start)

Examples:
  cco project resolve myapp                          # Interactive
  cco project resolve myapp --repo backend ~/dev/be  # Direct
  cco project resolve myapp --show                   # Status
```

**Interactive mode output**:

```
Project: myapp

  Repos:
    backend-api      ~/Projects/backend-api    ✓ exists
    frontend-app     @local (not configured)   ✗ needs path

  Extra mounts:
    /workspace/docs  ~/documents/api-specs     ✓ exists

  Enter path for 'frontend-app' [or press Enter to skip]: ~/dev/frontend
  ✓ Saved: frontend-app → ~/dev/frontend

  All paths resolved.
```

---

## 5. Implementation Details

### 5.1 Module structure — `lib/local-paths.sh`

All path resolution logic lives in a single new module. This replaces the
path-handling code currently spread across three files:

```
lib/local-paths.sh (NEW)
├─ _local_paths_get(file, section, key)       # Read path from local-paths.yml
├─ _local_paths_set(file, section, key, val)  # Write path to local-paths.yml
├─ _sanitize_project_paths(project_yml)       # Replace real paths with @local, inject url:
├─ _resolve_project_paths(project_dir)        # Restore @local → real paths from local-paths.yml
├─ _resolve_entry(project_dir, section, key)  # Resolve single entry (with prompt fallback)
├─ _extract_local_paths(vault_dir)            # Pre-commit: extract all projects
├─ _restore_local_paths(vault_dir)            # Post-commit: restore from backup
├─ _resolve_all_local_paths(vault_dir)        # Post-pull/switch: resolve all projects
└─ _prompt_for_path(name, url, suggested)     # Interactive TTY prompt with clone option
```

### 5.2 Functions superseded

| Current function | File | Replaced by |
|------------------|------|-------------|
| `_reverse_template_repos()` | `cmd-project-publish.sh` | `_sanitize_project_paths()` |
| `_resolve_repo_entries()` | `cmd-project-install.sh` | `_resolve_entry()` loop in install flow |
| `_resolve_template_vars()` (REPO_* handling) | `cmd-project-create.sh` | `_resolve_entry()` — template vars still handle non-path variables |

`_reverse_template_repos()` and `_resolve_repo_entries()` are fully replaced.
`_resolve_template_vars()` keeps handling `{{DESCRIPTION}}`, `{{PROJECT_NAME}}`,
etc. — only the `REPO_*` case is removed.

### 5.3 YAML manipulation

The sanitize and restore operations modify `path:` and `source:` values in
`project.yml`. Since the project uses custom AWK-based YAML parsing (not a
full YAML library), the replacement must be line-oriented and safe.

**Sanitize** (replace real path with `@local`, inject url:):

Uses the same AWK pattern as current `_reverse_template_repos()` but:
- Produces `@local` instead of `{{REPO_*}}`
- Also processes the `extra_mounts:` section
- Injects `url:` for repos where git remote is available

**Restore** (replace `@local` with real path from local-paths.yml):

Reads `local-paths.yml` to build name → path map, iterates through
`project.yml` matching repo names and mount targets to substitute `@local`.

This is safe because:
- `path:` under `repos:` and `source:` under `extra_mounts:` have a
  predictable indentation pattern (2-space indent for list items)
- The replacement is value-only (key and indentation preserved)
- Comments on the same line are lost (acceptable — machine-specific values)

### 5.4 `local-paths.yml` read/write helpers

```bash
# Write a name→path entry to local-paths.yml
# _local_paths_set <local_paths_file> <section> <key> <value>
_local_paths_set "$lp_file" "repos" "backend-api" "~/Projects/backend-api"

# Read a path by name from local-paths.yml
# _local_paths_get <local_paths_file> <section> <key>
path=$(_local_paths_get "$lp_file" "repos" "backend-api")
```

The file format is simple flat YAML (one level of nesting), parseable with
the existing `yml_get()` or lightweight AWK.

### 5.5 Backup safety (vault save only)

```bash
_extract_local_paths() {
    for project_dir in "$vault_dir"/projects/*/; do
        local project_yml="$project_dir/project.yml"
        local local_paths="$project_dir/.cco/local-paths.yml"
        local backup="$project_dir/.cco/project.yml.pre-save"

        [[ -f "$project_yml" ]] || continue

        # Recover from interrupted save
        if [[ -f "$backup" ]]; then
            warn "Restoring project.yml from interrupted save: $(basename "$project_dir")"
            cp "$backup" "$project_yml"
            rm -f "$backup"
        fi

        # Extract and check if any paths need sanitizing
        local has_real_paths=false
        # ... (parse repos and extra_mounts, check for non-@local paths)

        if $has_real_paths; then
            cp "$project_yml" "$backup"
            _write_local_paths "$project_yml" "$local_paths"
            _sanitize_project_paths "$project_yml"
        fi
    done
}

_restore_local_paths() {
    for project_dir in "$vault_dir"/projects/*/; do
        local backup="$project_dir/.cco/project.yml.pre-save"
        [[ -f "$backup" ]] || continue
        cp "$backup" "$project_dir/project.yml"
        rm -f "$backup"
    done
}
```

### 5.6 Integration points

| File | Function | Change |
|------|----------|--------|
| `lib/local-paths.sh` | (new module) | All path resolution helpers |
| `lib/cmd-vault.sh` | `cmd_vault_save()` | Call `_extract_local_paths` before `git add`, `_restore_local_paths` after commit |
| `lib/cmd-vault.sh` | `cmd_vault_pull()` | Call `_resolve_all_local_paths` after pull |
| `lib/cmd-vault.sh` | `cmd_vault_profile_switch()` | Call `_resolve_all_local_paths` after restore |
| `lib/cmd-start.sh` | (new `_start_resolve_paths()`) | Resolution chain before compose generation |
| `lib/cmd-project-publish.sh` | `cmd_project_publish()` | Replace `_reverse_template_repos` call with `_sanitize_project_paths` |
| `lib/cmd-project-install.sh` | `cmd_project_install()` | Replace `_resolve_repo_entries` with `_resolve_entry` loop; write to `local-paths.yml` |
| `lib/cmd-project-create.sh` | `_resolve_template_vars()` | Remove `REPO_*` handling (leave other vars) |
| `lib/cmd-project-query.sh` | (new subcommand) | `cco project resolve` |
| `lib/cmd-vault.sh` | `_VAULT_GITIGNORE` | Add `local-paths.yml` and `project.yml.pre-save` patterns |

### 5.7 Vault .gitignore additions

```gitignore
# Machine-specific local path mappings
projects/*/.cco/local-paths.yml

# Temporary backup during vault save path extraction
projects/*/.cco/project.yml.pre-save
```

---

## 6. Migration & Backward Compatibility

### 6.1 Existing vault users

No migration needed. The feature is additive:
- Existing project.yml files have real paths → `cco start` uses them directly
- First `cco vault save` extracts paths to `local-paths.yml` and sanitizes
- Other PCs pulling for the first time get `@local` markers → prompted at
  `cco start`

### 6.2 Existing published templates with `{{REPO_*}}`

Templates published before this change contain `{{REPO_BACKEND_API}}` instead
of `@local`. Backward compatibility:

- `_resolve_template_vars()` continues to handle `{{REPO_*}}` prompts during
  install (unchanged behavior for legacy templates)
- `cco start` resolution chain recognizes both `@local` and `{{REPO_*}}`
  patterns — both trigger the same lookup in `local-paths.yml` with prompt
  fallback
- Re-publishing a project updates it to `@local` format

No migration script needed — the legacy format continues to work indefinitely.

### 6.3 Users without vault

No impact. Without vault, `project.yml` is never committed, paths are always
real, and the resolution chain's first step (real path exists) always succeeds.

### 6.4 Vault .gitignore update

The `.gitignore` template (`_VAULT_GITIGNORE` in `cmd-vault.sh`) is updated
with the new patterns. For existing vaults, a global migration ensures the
patterns are added.

### 6.5 `cco start` blocking change

Today `cco start` warns and skips repos with non-existent paths. After this
change, it prompts interactively (or aborts non-interactively). This is a
behavior change, but an improvement — silent skips were confusing.

To preserve backward compatibility for scripted workflows, a `--skip-missing`
flag can suppress prompts and revert to warn-and-skip behavior.

---

## 7. Interaction with Existing Features

### 7.1 Profile switch

`local-paths.yml` is gitignored and project-scoped. During profile switch,
the shadow directory mechanism already stashes and restores gitignored files
per-profile. `local-paths.yml` benefits automatically — each profile on each
PC has its own path mappings.

### 7.2 `cco project create`

New projects are created with real paths on the local machine. The first
`cco vault save` extracts and sanitizes. No changes to `cmd_project_create`.

### 7.3 `cco project edit`

The planned `cco project edit` command (roadmap Quick Wins #10) opens
`project.yml` in `$EDITOR`. Before opening, resolve paths from
`local-paths.yml` so the user sees real paths. After saving, update
`local-paths.yml` if the user changed paths.

### 7.4 `cco project update` (from remote source)

When updating an installed project from its remote (`cco project update`),
the remote version has `@local` markers. The 3-way merge should treat
`path:` and `source:` fields specially: keep the local `@local` marker in the
merged result (paths are never merged from remote). The actual paths live in
`local-paths.yml` which is unaffected by the update.

### 7.5 Knowledge packs with external `source:`

Packs with `knowledge.source:` have a similar portability problem.
Pack internalization (copying files into the pack) is the current solution
for publish. The `@local` pattern could be extended to `pack.yml` source
fields in the future, but this is out of scope.

---

## 8. UX Flow Examples

### 8.1 Single PC (no vault, no sharing)

No change from today. User writes paths, `cco start` uses them directly.

### 8.2 Two PCs, vault sync

```
PC-A (MacBook):
  project.yml → repos: backend-api: ~/Projects/backend-api

  $ cco vault save "add project"
    → .cco/local-paths.yml created
    → committed project.yml: path: "@local", url: git@github.com:acme/be.git
    → working copy restored with real paths

  $ cco vault push

PC-B (Linux desktop):
  $ cco vault pull
    → project.yml has @local markers
    → .cco/local-paths.yml does not exist
    → paths remain as @local in working copy

  $ cco start myapp
    Repository 'backend-api' not found
      URL: git@github.com:acme/be.git
      (c) Clone to ~/Projects/backend-api
      (p) Specify path
      (s) Skip
      (q) Exit
    > c
    ✓ Cloned backend-api to ~/Projects/backend-api
    → .cco/local-paths.yml created
    → session starts
```

### 8.3 Publish and install (Config Repo)

```
Publisher:
  $ cco project publish myapp github
    → project.yml sanitized: path: "@local", url: injected
    → extra_mounts sanitized: source: "@local"
    → published to Config Repo

Consumer:
  $ cco project install github --pick myapp
    → Template copied, non-path {{VARS}} resolved
    → Repo 'backend-api' not found
        URL: git@github.com:acme/be.git
        (c) Clone to ~/Projects/backend-api
        (p) Specify path
        (s) Skip
        (q) Exit
    > p
    > ~/my-repos/backend-api
    ✓ Saved: backend-api → ~/my-repos/backend-api
    → .cco/local-paths.yml created
    → Run: cco start myapp
```

### 8.4 Pre-configuring paths on new PC

```
$ cco vault pull
$ cco project resolve myapp
  Repos:
    backend-api    @local    ✗ needs path
    frontend-app   @local    ✗ needs path
  Enter path for 'backend-api': ~/dev/backend-api
  ✓ Saved
  Enter path for 'frontend-app': ~/dev/frontend-app
  ✓ Saved
  All paths resolved.

$ cco start myapp
  → all paths resolved from .cco/local-paths.yml → no prompts
```

### 8.5 Legacy template install

```
$ cco project install old-config-repo --pick legacy-project
  → project.yml has {{REPO_BACKEND_API}} (legacy format)
  → _resolve_template_vars() prompts: "REPO_BACKEND_API: "
  → user enters path → substituted into project.yml
  → _resolve_entry() saves to .cco/local-paths.yml
  → project works normally from here on
```

---

## 9. Future Extensions

### 9.1 Projects dir convention

A global `cco` setting for a default projects directory (e.g.,
`projects_dir: ~/Projects`) could auto-resolve paths by name:

```
backend-api → ~/Projects/backend-api (if exists)
```

This reduces prompts on new PCs where the user follows a consistent directory
structure. Evaluate based on user feedback.

### 9.2 Extra mount `url:` field

Currently `url:` is only supported on repo entries. Extra mounts could gain
a similar field for remote sources (e.g., a git repo containing API specs).
The resolution prompt would offer clone for mounts too. Low priority — mounts
are typically local-only resources.
