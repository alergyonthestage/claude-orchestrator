# Update System Design (Pre-Sprint-5b)

> **⚠️ SUPERSEDED — DO NOT USE**: This document describes the original checksum +
> auto-apply design (pre-Sprint-5b). The definitive design — discovery-only default,
> `--apply` for interactive merge, 7-status discovery algorithm — is in
> [`../defaults-templates-update/design.md`](../defaults-templates-update/design.md).
>
> The old `--force`/`--keep`/`--replace` flags described here are now hidden
> backward-compatible aliases. The auto-apply behavior no longer exists.

## Problem

Today there is no update mechanism. The only options are:

| Scenario | Mechanism | Problem |
|----------|-----------|---------|
| New global defaults | `cco init --force` | **Destructive** — deletes `global/` and recopy everything |
| New project template structure | None | User must apply manually |
| Legacy migration | `_migrate_to_managed()` | One-shot with marker file, not extensible |
| Updated packs | `cco start` (manifest) | Works but only for pack→project resources |

### What `init --force` destroys

`rm -rf "$GLOBAL_DIR"` deletes:
- `global/packs/` — user packs, unrecoverable
- `global/claude-state/` — session transcripts, credentials, memory
- `global/.claude/mcp.json` — custom MCP configuration
- All user customizations (modified agents, rules, skills)

### Main requirement

Update projects and global scope **without deleting and redoing**, preserving:
- History and chat sessions (`claude-state/`)
- User CLAUDE.md (global and project)
- `mcp.json`, `secrets.env`, `project.yml`
- User packs (`global/packs/`)

## File Classification by Ownership

### Global (`defaults/global/` → `global/`)

| File | Owner | Safe to update? | Strategy |
|------|-------|-----------------|----------|
| `.claude/settings.json` | Framework | Yes | Always overwrite |
| `.claude/rules/language.md` | Framework | Yes (with care) | Regenerate from saved choices |
| `.claude/rules/*.md` (others) | Framework | Caution | Checksum: overwrite if unchanged |
| `.claude/agents/*.md` | Framework | Caution | Checksum: overwrite if unchanged |
| `.claude/skills/*/SKILL.md` | Framework | Caution | Checksum: overwrite if unchanged |
| `.claude/CLAUDE.md` | Framework | Caution | Checksum: overwrite if unchanged |
| `.claude/mcp.json` | **User** | Never | Don't touch |
| `setup.sh` | **User** | Never | Don't touch |

### Project (`templates/project/base/` → `projects/<name>/`)

| File | Owner | Safe to update? | Strategy |
|------|-------|-----------------|----------|
| `.claude/settings.json` | Framework | Yes | Overwrite |
| `.gitkeep` files | Framework | Yes | Ignore |
| `project.yml` | **User** | Never | Don't touch |
| `.claude/CLAUDE.md` | **User** | Never | Don't touch |
| `.claude/rules/language.md` | **User** | Never | Don't touch |
| `setup.sh` | **User** | Caution | Copy only if missing |
| `mcp-packages.txt` | **User** | Caution | Copy only if missing |
| `secrets.env` | **User** | Caution | Copy only if missing |

## Architecture: Hybrid Checksum + Migrations

### Why Hybrid

| Criterion | Checksum Only | Migrations Only | **Hybrid** |
|-----------|---------------|-----------------|-----------|
| File content updates | Automatic | One function per file | Automatic |
| Detects user edits | Yes | Must reimplement | Yes |
| Structural changes | No | Yes | Yes |
| File rename/removal | No | Yes | Yes |
| Schema changes | No | Yes | Yes |
| Maintenance | Minimal | High | Medium |

### Modules and Files

Three new files following existing project patterns:

| File | Role | Reference Pattern |
|------|------|-------------------|
| `lib/update.sh` | Engine: checksum, manifest I/O, diff, migration runner | Like `packs.sh` (reusable logic separate from command) |
| `lib/cmd-update.sh` | Command: option parsing, orchestration, user interaction | Like `cmd-init.sh`, `cmd-project.sh` |
| `migrations/{global,project}/*.sh` | Individual migration scripts | New pattern, documented below |

The migration runner lives in `update.sh` (not separate file) because it's tightly coupled to engine (both read/write `.cco-meta`) and not reused elsewhere.

### Relationship: init / update

These are separate commands with different semantics:

| Aspect | `cco init` | `cco update` |
|--------|-----------|-------------|
| Purpose | Initial setup / factory reset | Incremental merge |
| `--force` | `rm -rf global/` → recopy everything from defaults | Overwrites only framework-managed files, preserves user files |
| Destructiveness | High — deletes mcp.json, claude-state/, packs | Low — never touches user-owned files |
| Creates `.cco-meta` | Yes, on first init | Yes, if missing (retrocompat) |
| Runs migrations | Yes (schema_version = latest, no pending migrations) | Yes (all pending ones) |

**Changes to `cmd-init.sh`:**
- After `cp -r` of defaults, calls `_generate_cco_meta()` to create `.cco-meta` with hash of all copied files and `schema_version` = latest
- Language choices are saved in the `languages:` section of `.cco-meta`
- `_migrate_to_managed()` removed from direct call — replaced by migration system

**Hint on `cco start`:**
- `cmd-start.sh` checks if `.cco-meta` exists in global scope
- If `schema_version < latest`, prints: `ℹ Updates available. Run 'cco update' to apply.`
- Does not run update automatically

### Update Algorithm (Detail)

Auto-discovery of managed files. Scans `defaults/` excluding user-owned files:

```bash
GLOBAL_USER_FILES=("mcp.json" "setup.sh")        # Never touch
GLOBAL_SPECIAL_FILES=("rules/language.md")         # Regenerate from saved choices
# Everything else from defaults → framework-managed
```

For each managed file (not user-owned, not special):

```
installed_hash = hash(installed_file)   # or "" if not exists
manifest_hash  = hash from .cco-meta   # or "" if new file
default_hash   = hash(default_file)     # from defaults/ directory

if installed_hash == "" and default_hash != "":
    → NEW: copy from defaults
elif manifest_hash == default_hash:
    → NO_UPDATE: default hasn't changed since last version
elif installed_hash == manifest_hash:
    → SAFE_UPDATE: user hasn't modified, framework updated → overwrite
elif installed_hash != manifest_hash and default_hash != manifest_hash:
    → CONFLICT: both user and framework modified → resolve
elif installed_hash != manifest_hash and default_hash == manifest_hash:
    → USER_MODIFIED: user modified, framework hasn't updated → skip
```

For `language.md`: regenerated from template with language choices saved in `.cco-meta`, then treated as separate managed file (hash updated in manifest).

For files in manifest but no longer in defaults: flagged as "removed from defaults", not deleted (user may have customized them).

### Dry-Run Strategy

Two-phase approach (like `cmd-start.sh --dry-run`):

```
Phase 1: COLLECT (always runs, read-only)
  - Scan files, compute hashes, detect changes
  - Count pending migrations

Phase 2: APPLY (skipped if --dry-run)
  - Execute file updates
  - Run migrations
  - Update .cco-meta
```

For `--dry-run`:
- File changes: shows list of files to update/add/remove with status
- Migrations: shows "N migrations pending" with descriptions
- Ends with `ℹ Dry run complete. No changes made.`

## The `.cco-meta` File

One per each updatable scope. YAML-like format (parsed with AWK).

### `global/.claude/.cco-meta`

```yaml
# Auto-generated by cco — do not edit
schema_version: 1
created_at: 2026-01-15T10:00:00Z
updated_at: 2026-02-27T14:30:00Z

languages:
  communication: Italian
  documentation: Italian
  code_comments: English

manifest:
  CLAUDE.md: <sha256>
  settings.json: <sha256>
  rules/diagrams.md: <sha256>
  rules/git-practices.md: <sha256>
  rules/language.md: <sha256-post-substitution>
  rules/workflow.md: <sha256>
  agents/analyst.md: <sha256>
  agents/reviewer.md: <sha256>
  skills/analyze/SKILL.md: <sha256>
  skills/commit/SKILL.md: <sha256>
  skills/design/SKILL.md: <sha256>
  skills/review/SKILL.md: <sha256>
```

### Parsing and Writing

**Reading**: AWK-based, dedicated functions for three sections (header, languages, manifest).

**Writing**: Complete generation from scratch with `printf` (like docker-compose.yml in cmd-start.sh). No in-place editing — full rewrite on each update.

```bash
_generate_cco_meta() {
    local meta_file="$1" schema="$2" created="$3"
    local comm_lang="$4" docs_lang="$5" code_lang="$6"
    # Manifest entries from stdin as "path\thash" lines

    {
        printf '# Auto-generated by cco — do not edit\n'
        printf 'schema_version: %d\n' "$schema"
        printf 'created_at: %s\n' "$created"
        printf 'updated_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '\nlanguages:\n'
        printf '  communication: %s\n' "$comm_lang"
        printf '  documentation: %s\n' "$docs_lang"
        printf '  code_comments: %s\n' "$code_lang"
        printf '\nmanifest:\n'
        while IFS=$'\t' read -r path hash; do
            [[ -z "$path" ]] && continue
            printf '  %s: %s\n' "$path" "$hash"
        done
    } > "$meta_file"
}
```

## Migrations

Bash functions in `migrations/`, executed in order by `schema_version`.

```
migrations/
├── global/
│   └── 001_managed_scope.sh
└── project/
    └── 001_memory_to_claude_state.sh
```

### Conventions

**Naming**: `NNN_descriptive_name.sh` (3 zero-padded digits)

**File structure**:
```bash
#!/usr/bin/env bash
# Migration: <brief description>

MIGRATION_ID=1
MIGRATION_DESC="Managed scope migration"

# $1 = target directory (global_dir/.claude or project_dir)
# Must be idempotent (safe to run multiple times)
# Return 0 on success, non-zero on failure
migrate() {
    local target_dir="$1"
    # ... migration logic ...
}
```

**Rules:**
- Each file defines `MIGRATION_ID` (integer), `MIGRATION_DESC` (string), `migrate()` (function)
- `migrate()` receives target directory as first argument
- Must be **idempotent** — safe to run multiple times
- Use `info()`, `warn()`, `ok()` for output (available because `colors.sh` is already loaded)
- Return 0 = success, non-zero = failure
- No `down()/rollback` — not needed for CLI tool
- No direct access to global variables (`GLOBAL_DIR`, etc.) — receives everything via argument (exception: `DEFAULTS_DIR` for template file access)

**Schema version**: Computed dynamically from highest `MIGRATION_ID` found in `migrations/{scope}/` directory. No need to maintain as constant.

### Migration Runner

`_run_migrations()` in `lib/update.sh`:
1. Reads `schema_version` from `.cco-meta`
2. Scans `migrations/{scope}/*.sh` ordering by name (natural order via NNN prefix)
3. For each file with `MIGRATION_ID > schema_version`: source the file, call `migrate()`
4. After each successful migration, updates `schema_version` in `.cco-meta`
5. If a migration fails: stop, report error, don't update `schema_version`

### Porting Legacy Migrations

| Legacy | New | Scope | ID |
|--------|-----|-------|----|
| `_migrate_to_managed()` in `secrets.sh` | `migrations/global/001_managed_scope.sh` | global | 1 |
| `migrate_memory_to_claude_state()` in `secrets.sh` | `migrations/project/001_memory_to_claude_state.sh` | project | 1 |

Original functions are marked as deprecated in `secrets.sh` but maintained for backward compatibility with installations that haven't yet run `cco update`.

## Command `cco update`

```
cco update                    # Update global defaults
cco update --project <name>   # A specific project
cco update --all              # Global + all projects
cco update --dry-run          # Show what would change
cco update --force            # Overwrite even modified files
cco update --keep             # Always keep user version
cco update --backup           # Backup .bak + overwrite (no prompt)
```

Default: `--interactive` (shows diff, user chooses for each conflict).

### Interactive Conflict Options

- **Keep (K)**: keeps user file, updates hash in manifest
- **Update (U)**: overwrites with new default
- **Backup (B)**: backup `.bak` + overwrite
- **Skip (S)**: doesn't touch anything, doesn't update hash (re-flagged at next update)

### Backward Compatibility (Without `.cco-meta`)

First run: `schema_version: 0`, runs all migrations, generates manifest with current hashes (without overwriting), informs user. From second update, system works normally.

### Handling `language.md`

Language choices are saved in `.cco-meta` → `languages:`. On update, template is regenerated with saved choices. If `.cco-meta` is missing, values are extracted from current file via pattern matching.

## Impact on Existing Commands

### `cmd-init.sh`
- After `cp -r` of defaults, generates `.cco-meta` with hash of all copied files
- Saves language choices in `languages:` section
- `schema_version` = latest (no pending migrations on fresh install)
- On pre-existing installations (without `.cco-meta`), runs pending migrations

### `cmd-start.sh`
- Checks if `.cco-meta` exists in global scope
- If `schema_version < latest`, prints hint: `ℹ Updates available. Run 'cco update' to apply.`
- Does not run update automatically
- Maintains direct call to `migrate_memory_to_claude_state()` for backward compatibility

### `secrets.sh`
- `_migrate_to_managed()` and `migrate_memory_to_claude_state()` marked as deprecated
- Maintained for backward compatibility
- Functions `load_secrets_file()` and `load_global_secrets()` unchanged

## Test Plan

### New Helpers in `tests/helpers.sh`
- `create_cco_meta()` — creates `.cco-meta` with specified content
- `modify_managed_file()` — modifies managed file to simulate user edit
- `assert_output_not_contains()` — asserts CCO_OUTPUT doesn't contain pattern

### Test Scenarios (`tests/test_update.sh`)

1. `test_update_first_run_no_meta` — generates `.cco-meta`, runs migrations
2. `test_update_no_changes` — everything updated, nothing to do
3. `test_update_framework_changed` — default modified, user file unchanged → update
4. `test_update_user_modified` — user file modified → preserve
5. `test_update_force_overwrites` — `--force` overwrites even modified files
6. `test_update_keep_preserves` — `--keep` keeps user version
7. `test_update_backup_creates_bak` — `--backup` creates .bak + overwrite
8. `test_update_new_file_added` — new file in defaults → copied
9. `test_update_dry_run` — no changes, informative output
10. `test_update_migrations_run_in_order` — migrations run in order
11. `test_update_migration_failure_stops` — failure stops execution
12. `test_update_init_creates_cco_meta` — init generates .cco-meta correctly
13. `test_update_language_preserved` — language.md regenerated with saved choices
14. `test_update_help` — --help shows usage text
