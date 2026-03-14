# Sprint 5b — Design: Defaults, Templates & Update System

**Status**: Final — Revised 2026-03-14
**Original date**: 2026-03-13
**Scope**: Architecture-level

> This document is the single authoritative reference for the update system design.
> It incorporates decisions from Sprint 5b implementation and post-sprint analysis
> (session 2026-03-14).

---

## 1. Business Model — Resource Taxonomy

claude-orchestrator manages four distinct resource categories with different lifecycles
and ownership models.

| Category | Lifecycle | Ownership | Mutability |
|----------|-----------|-----------|------------|
| **Managed** | Baked in Docker image | Framework | Immutable (rebuilt with `cco build`) |
| **Defaults** | Copied once at `cco init` | Framework → User | User-owned after install; tracked for updates |
| **Templates (native)** | On-demand scaffolding | Framework (shipped) | Read-only source; output is tracked as project |
| **Templates (user)** | On-demand scaffolding | User | User manages both source and output |

### Key Distinctions

| Aspect | Defaults | Templates |
|--------|----------|-----------|
| **When used** | `cco init`, `cco update` | `cco project create`, `cco pack create` |
| **How many** | One set (global) | Multiple (base, tutorial, user-defined...) |
| **Tracked by update** | Yes — all tracked files 3-way merged | Native: yes. User: only with `--sync-templates` |
| **Relationship to user files** | 1:1 mapping (default → installed file) | 1:N mapping (template → many projects) |
| **Framework updates** | Propagated via `cco update` | Native: `cco update`. User: `cco update --sync-templates` |

---

## 2. Directory Structure Map

```
defaults/                              # Framework-managed configuration sources
├── managed/                           # Baked in Docker → /etc/claude-code/
│   ├── managed-settings.json          #   Hooks, env vars, deny rules (immutable)
│   ├── CLAUDE.md                      #   Framework-level instructions (immutable)
│   └── .claude/skills/init-workspace/ #   Managed skill (immutable)
│
└── global/                            # Copied to user-config/global/ at cco init
    ├── setup.sh                       #   Host dotfiles bootstrap
    ├── setup-build.sh                 #   Build dependencies
    └── .claude/
        ├── CLAUDE.md                  #   Global workflow instructions
        ├── settings.json              #   Global Claude Code permissions
        ├── mcp.json                   #   Personal MCP servers (user-owned)
        ├── agents/
        │   ├── analyst.md             #   Framework analyst agent spec
        │   └── reviewer.md            #   Framework reviewer agent spec
        ├── rules/
        │   ├── diagrams.md            #   Diagram conventions
        │   ├── git-practices.md       #   Git branch/commit conventions
        │   ├── workflow.md            #   Phase-based workflow rules
        │   └── language.md            #   Language prefs (generated from template)
        └── skills/
            ├── analyze/SKILL.md       #   /analyze skill
            ├── commit/SKILL.md        #   /commit skill
            ├── design/SKILL.md        #   /design skill
            └── review/SKILL.md        #   /review skill

templates/                             # Scaffolding blueprints (read-only sources)
├── project/
│   ├── base/                          # Default project template (no --template flag)
│   │   ├── project.yml                #   Project manifest template
│   │   ├── setup.sh                   #   Runtime setup script
│   │   ├── secrets.env                #   Secrets placeholder
│   │   ├── mcp-packages.txt           #   Optional MCP package list
│   │   ├── claude-state/              #   Session memory dir (empty)
│   │   └── .claude/
│   │       ├── CLAUDE.md              #   Project context scaffold (user fills)
│   │       ├── settings.json          #   Project permissions (minimal schema)
│   │       ├── rules/language.md      #   Language override scaffold (commented)
│   │       ├── agents/.gitkeep        #   Empty: project agents are user-defined
│   │       └── skills/.gitkeep        #   Empty: project skills are user-defined
│   │
│   └── tutorial/                      # Tutorial template (--template tutorial)
│       ├── project.yml
│       ├── setup.sh
│       ├── claude-state/
│       └── .claude/
│           ├── CLAUDE.md
│           ├── settings.json
│           ├── rules/tutorial-behavior.md
│           └── skills/
│               ├── setup-pack/SKILL.md
│               ├── setup-project/SKILL.md
│               └── tutorial/SKILL.md
│
└── pack/
    └── base/                          # Default pack template
        ├── pack.yml
        ├── knowledge/.gitkeep
        ├── skills/.gitkeep
        ├── agents/.gitkeep
        └── rules/.gitkeep
```

---

## 3. Complete File Classification Map

This is the definitive reference for every file managed by the update system.

### Legend

| Policy | Meaning | `cco update` action |
|--------|---------|---------------------|
| `tracked` | Framework owns the content | 3-way merge (user customizations preserved) |
| `user-owned` | User owns the content | Never touched after initial install |
| `generated` | Rebuilt from template + saved values | Regenerated (e.g., `language.md`) |
| `copy-if-missing` | Scaffold: written once if absent, then ignored | Written only if file doesn't exist |
| `immutable` | Baked in Docker image | Only changes on `cco build` |

### 3.1 Managed Scope (immutable)

> Not in the update system. Changes require `cco build`.

| File | Policy | Notes |
|------|--------|-------|
| `defaults/managed/CLAUDE.md` | `immutable` | Framework instructions, highest priority in Claude |
| `defaults/managed/managed-settings.json` | `immutable` | Hooks, env, deny rules — cannot be overridden |
| `defaults/managed/.claude/skills/init-workspace/SKILL.md` | `immutable` | Framework managed skill |

### 3.2 Global Scope — `cco update` (native)

> Source: `defaults/global/` → Installed: `user-config/global/`

| File | Policy | Tracked by `cco update`? | Notes |
|------|--------|--------------------------|-------|
| `.claude/CLAUDE.md` | `tracked` | ✅ always | Framework workflow instructions |
| `.claude/settings.json` | `tracked` | ✅ always | Global Claude Code permissions |
| `.claude/mcp.json` | `user-owned` | ❌ never | Personal MCP servers |
| `.claude/agents/analyst.md` | `tracked` | ✅ always | Framework agent spec |
| `.claude/agents/reviewer.md` | `tracked` | ✅ always | Framework agent spec |
| `.claude/rules/diagrams.md` | `tracked` | ✅ always | Framework diagram conventions |
| `.claude/rules/git-practices.md` | `tracked` | ✅ always | Framework git conventions |
| `.claude/rules/workflow.md` | `tracked` | ✅ always | Framework workflow rules |
| `.claude/rules/language.md` | `generated` | ✅ always | Regenerated from template + `.cco-meta` saved choices |
| `.claude/skills/analyze/SKILL.md` | `tracked` | ✅ always | Framework skill |
| `.claude/skills/commit/SKILL.md` | `tracked` | ✅ always | Framework skill |
| `.claude/skills/design/SKILL.md` | `tracked` | ✅ always | Framework skill |
| `.claude/skills/review/SKILL.md` | `tracked` | ✅ always | Framework skill |
| `setup.sh` | `user-owned` + `copy-if-missing` | ❌ never | Written once at init; user customizes |
| `setup-build.sh` | `user-owned` + `copy-if-missing` | ❌ never | Written once at init; user customizes |

### 3.3 Project Scope — `cco update --project` (native)

> Source: `templates/project/base/` (or resolved template for template-specific files)
> Installed: `user-config/projects/<name>/`

| File | Policy | Tracked by `cco update`? | Notes |
|------|--------|--------------------------|-------|
| `.claude/CLAUDE.md` | `user-owned` | ❌ never | User writes project context from scratch |
| `.claude/settings.json` | `tracked` | ✅ always (native) | Project permissions; always uses `base` as native source |
| `.claude/rules/language.md` | `copy-if-missing` | ❌ never | Optional project override; commented scaffold |
| `.claude/agents/` | `user-owned` | ❌ never | Project agents are user-defined |
| `.claude/skills/` | `user-owned` (or `tracked` if from template) | ⚠️ see note | User-defined; template-installed skills tracked with `--sync-templates` |
| `project.yml` | `tracked` | ✅ native only | 3-way merge against `base` template; see section 4.16 |
| `setup.sh` | `copy-if-missing` | ❌ never | Written once at project create |
| `secrets.env` | `copy-if-missing` | ❌ never | Written once; user fills secrets |
| `mcp-packages.txt` | `copy-if-missing` | ❌ never | Written once; user adds packages |

**Note on `.claude/skills/` in project scope:**
- A project created from `base` template: no skills → nothing to track
- A project created from `tutorial` template: has tutorial skills → tracked with `--sync-templates`
  (because `template_source: native`, and tutorial is a native template)
- A project created from a user template with custom skills → tracked with `--sync-templates`
  (because `template_source: user`)

### 3.4 Runtime-Generated Files (not in update system)

> Generated by `cco start`. Cleaned by `cco clean --generated`.

| File | Generated by | Cleaned by |
|------|-------------|------------|
| `user-config/projects/<name>/docker-compose.yml` | `cco start` | `cco clean --generated` |
| `user-config/projects/<name>/.managed/` | `cco start` | `cco start` (regenerated each run) |
| `user-config/projects/<name>/.tmp/` | `cco start --dry-run` | `cco clean --tmp` |
| `user-config/global/.claude/.cco-meta` | `cco init` / `cco update` | ❌ do not delete |
| `user-config/global/.claude/.cco-base/` | `cco init` / `cco update` | ❌ do not delete |
| `user-config/projects/<name>/.cco-meta` | `cco project create` / `cco update` | ❌ do not delete |
| `user-config/projects/<name>/.cco-base/` | `cco project create` / `cco update` | ❌ do not delete |

> **Warning**: `.cco-base/` is the ancestor for 3-way merge. Deleting it does not
> break anything immediately, but the next `cco update` will fall back to
> best-effort base reconstruction, potentially surfacing false conflicts.

---

## 4. Update System — 3-Way Merge Engine

### 4.1 Core Insight

The update system treats files as **line-level editable content**, not atomic units.
Using `git merge-file`, it performs 3-way merges that automatically apply framework
improvements while preserving user customizations.

### 4.2 Why 3-Way Merge (Not 2-Way Diff)

A 2-way diff (current vs new) cannot determine who changed what. Every difference
is ambiguous. A 3-way merge adds the **base** (ancestor) — the framework version
the user originally received — to disambiguate attribution:

| current vs base | new vs base | Attribution | Action |
|----------------|-------------|-------------|--------|
| Same | Changed | Framework updated | Auto-apply |
| Changed | Same | User customized | Preserve |
| Changed | Changed (same) | Both agree | Auto-apply |
| Changed | Changed (differently) | True conflict | Prompt user |

### 4.3 How `git merge-file` Works

```bash
git merge-file [--diff3] <current> <base> <new>
#                         ours     ancestor  theirs
```

- Modifies `<current>` in-place, merging changes from both sides
- Returns 0 if clean merge, >0 if conflicts remain
- Inserts standard conflict markers on conflicts
- No git repository required — operates on plain files

### 4.4 The Three Versions

| Version | Source | Storage |
|---------|--------|---------|
| **Current** (ours) | User's installed file | `user-config/.../<file>` |
| **Base** (ancestor) | Framework version at last install/update | `.cco-base/<file>` |
| **New** (theirs) | Current framework version | `defaults/global/.../<file>` or resolved template |

### 4.5 Base Version Storage — `.cco-base/`

A copy of each tracked file as delivered by the framework at install/update time.
Stored alongside `.cco-meta`:

```
user-config/global/.claude/
├── .cco-meta                  # Manifest with hashes + metadata
├── .cco-base/                 # Ancestor versions for 3-way merge
│   ├── CLAUDE.md
│   ├── settings.json
│   ├── agents/analyst.md
│   ├── rules/workflow.md
│   └── skills/analyze/SKILL.md
└── CLAUDE.md                  # User's current version
...

user-config/projects/<name>/
├── .cco-meta
├── .cco-base/
│   ├── .claude/settings.json
│   └── project.yml
└── project.yml                # User's current version
```

**Lifecycle:**
- Created at `cco init` (global) and `cco project create` (project)
- Updated after each successful `cco update`
- Never modified by user (hidden, gitignored in vault)
- Size: mirrors tracked files only (~50KB total — negligible)

### 4.6 File Policies (Definitive)

```bash
GLOBAL_FILE_POLICIES=(
    ".claude/CLAUDE.md:tracked"
    ".claude/settings.json:tracked"
    ".claude/mcp.json:user-owned"
    ".claude/agents/analyst.md:tracked"
    ".claude/agents/reviewer.md:tracked"
    ".claude/rules/diagrams.md:tracked"
    ".claude/rules/git-practices.md:tracked"
    ".claude/rules/workflow.md:tracked"
    ".claude/rules/language.md:generated"
    ".claude/skills/analyze/SKILL.md:tracked"
    ".claude/skills/review/SKILL.md:tracked"
    ".claude/skills/design/SKILL.md:tracked"
    ".claude/skills/commit/SKILL.md:tracked"
    "setup.sh:user-owned"
    "setup-build.sh:user-owned"
)

PROJECT_FILE_POLICIES=(
    ".claude/CLAUDE.md:user-owned"
    ".claude/settings.json:tracked"         # always-native source (base template)
    ".claude/rules/language.md:user-owned"  # optional override; user writes it
    "project.yml:tracked"                   # 3-way merge; native baseline only
)

GLOBAL_ROOT_COPY_IF_MISSING=("setup.sh" "setup-build.sh")
PROJECT_ROOT_COPY_IF_MISSING=("setup.sh" "secrets.env" "mcp-packages.txt")
```

### 4.7 Change Detection Algorithm

For each `tracked` file:

```
installed  = user's current file
base       = .cco-base/<path>
new        = defaults/<path>  (or resolved template for template-specific files)

if installed doesn't exist and new exists:
    → NEW: copy from source, save to .cco-base/

elif hash(new) == hash(base):
    → NO_UPDATE: framework hasn't changed → skip

elif hash(installed) == hash(base):
    → SAFE_UPDATE: user hasn't modified, framework updated
    → copy new version, update .cco-base/

elif hash(installed) != hash(base) AND hash(new) != hash(base):
    → BOTH_CHANGED: 3-way merge needed
    → run git merge-file
    → if clean merge: auto-apply, update .cco-base/
    → if conflicts: prompt user (see section 4.9)

elif hash(installed) != hash(base) AND hash(new) == hash(base):
    → USER_MODIFIED: user changed, framework didn't → skip
```

### 4.8 Merge Resolution Modes

```bash
cco update                    # Default: 3-way merge, interactive conflict resolution
cco update --dry-run          # Preview changes without applying
cco update --force            # Overwrite everything (ignore user changes) + .bak
cco update --keep             # Keep all user versions (skip all conflicts)
cco update --replace          # Replace files with new version + .bak (no merge)
cco update --no-backup        # Disable automatic .bak creation
cco update --sync-templates   # Also update from user templates (see section 4.16)
```

### 4.9 Interactive Conflict Resolution

```
For each BOTH_CHANGED file (default mode):
  1. Create temp copies: /tmp/cco-merge/{current,base,new}
  2. Run: git merge-file --diff3 /tmp/cco-merge/current base new
  3. If exit code 0 (clean merge):
     → Create .bak of user's current file
     → Show diff summary
     → "Auto-merged rules/workflow.md (no conflicts). Apply? [Y/n]"
     → If yes: copy merged result, update .cco-base/ and manifest
  4. If exit code > 0 (conflicts remain):
     → Show conflict summary
     → Prompt:
       (M)erge — open in $EDITOR with conflict markers
       (K)eep   — keep your version unchanged (default if no TTY)
       (R)eplace — use new framework version + .bak
       (S)kip   — decide later
  5. If $EDITOR not set: offer K/R/S only
```

### 4.10 Backup Policy

Automatic `.bak` creation is the default safety net.

| Scenario | `.bak` created? |
|----------|----------------|
| SAFE_UPDATE (user unchanged) | No |
| BOTH_CHANGED → auto-merge (clean) | **Yes** |
| BOTH_CHANGED → conflict resolution | **Yes** |
| `--replace` mode | **Yes** |
| `--force` mode | **Yes** |
| `--keep` mode | No |
| `--no-backup` flag | No |

### 4.11 Diff Preview Summary

Before applying any changes:

```
Global config update:

  ✓ rules/workflow.md — auto-merged (3 lines added, framework update)
  ✓ skills/analyze/SKILL.md — safe update (you haven't modified)
  + agents/debugger.md — new file
  ≡ rules/git-practices.md — you modified, no framework change (preserved)
  ? settings.json — both changed, needs merge

  2 auto-updates, 1 new file, 1 merge needed, 1 preserved

Proceed? [Y/n]
```

For `--dry-run`: same summary, no changes applied.

### 4.12 `.cco-meta` Schema

```yaml
# Auto-generated by cco — do not edit
schema_version: 8
created_at: 2026-01-15T10:00:00Z
updated_at: 2026-03-14T10:00:00Z

# Template origin (projects only)
template: base               # base | tutorial | <user-template-name>
template_source: native      # native | user

# Language preferences (global only)
languages:
  communication: Italian
  documentation: English
  code_comments: English

# Manifest: sha256 of each tracked file at last install/update
manifest:
  .claude/CLAUDE.md: a1b2c3d4...
  .claude/settings.json: e5f6g7h8...
  .claude/rules/workflow.md: i9j0k1l2...
  project.yml: m3n4o5p6...          # projects only
```

### 4.13 `project.yml` Tracking — Native Baseline

`project.yml` is `tracked` with a **native baseline**: the "new" version for
3-way merge always comes from `templates/project/base/project.yml`, regardless
of which template created the project.

**Rationale:**
- `project.yml` schema evolution (new sections like `github:`, `browser:`,
  `docker.containers:`) is driven by the framework, not by the project template
- The base template is the canonical schema reference
- User's content (repos, packs, enabled flags) is preserved by 3-way merge

**Template var handling:**
`project.yml` contains `{{PROJECT_NAME}}` and `{{DESCRIPTION}}` in the template.
After project creation, these are substituted — the installed file has real values.
For update purposes, the "new" version is the base template with substitutions
applied from `.cco-meta` metadata. This follows the same pattern as `language.md`.

**Coexistence with migrations:**
Schema additions that are content-only (new commented sections, new optional keys)
are handled by 3-way merge — no migration needed. Migrations remain for structural
changes (renamed keys, moved files, incompatible schema changes).

| Change Type | Mechanism |
|-------------|-----------|
| New optional section in project.yml | 3-way merge (update template, auto-propagated) |
| Renamed key in project.yml | Migration (surgical, explicit) |
| New tracked file added to policy | Migration (bootstrap `.cco-base/` entry) + 3-way merge going forward |
| Removed file | Migration |

### 4.14 Template-Aware Update Source

Each project records the template used at creation in `.cco-meta`:

```yaml
template: tutorial
template_source: native   # native = ships with cco; user = user-config/templates/
```

`_update_project()` resolves the update source based on this metadata:

```
1. Read template + template_source from .cco-meta
2. For always-native files (.claude/settings.json, project.yml):
   → always use templates/project/base/ as source (native baseline)
3. For template-specific files (skills, rules, CLAUDE.md from template):
   → if template_source == native: use templates/project/<template>/ as source
     → updated automatically by cco update
   → if template_source == user: use user-config/templates/project/<template>/ as source
     → updated ONLY with --sync-templates flag
4. Fallback: if template not found, skip template-specific files with warning
```

**Migration 008** (project scope): adds `template: base` and `template_source: native`
to `.cco-meta` for existing projects that predate this field.

### 4.15 User Templates: `--sync-templates` Flag

`cco update` by default operates on **framework sources only** (defaults/ and
native templates). This covers the most common use case: "I updated cco, pull
improvements."

To propagate changes from user-authored templates to existing projects, use
`--sync-templates`:

```bash
cco update --sync-templates                  # global + all projects, incl. user template files
cco update --project myapp --sync-templates  # single project
cco update --all --sync-templates            # explicit all-projects variant
```

**Behavioral matrix:**

| Command | Global config | Native template projects | User template projects |
|---------|--------------|--------------------------|------------------------|
| `cco update` | ✅ all tracked | ✅ native files + template-specific | ⚠️ native files only |
| `cco update --sync-templates` | ✅ all tracked | ✅ native files + template-specific | ✅ native files + template-specific |
| `cco update --project <name>` | ❌ | depends on project | ⚠️ native files only |
| `cco update --project <name> --sync-templates` | ❌ | depends on project | ✅ all tracked |

> "Native files only" for user template projects means: `.claude/settings.json`
> and `project.yml` are still updated (they always use the native `base` baseline).
> Only files that came specifically from the user template (custom skills, custom
> rules in `.claude/`) are skipped without `--sync-templates`.

**Why separate?** The two operations have different triggers:
- `cco update` = "the framework shipped improvements, receive them" (triggered by `cco` upgrade)
- `cco update --sync-templates` = "I updated my template, push changes to projects" (triggered by user template edit)

Mixing them by default would make `cco update` unpredictably touch user-authored
content without explicit intent.

### 4.16 Vault Integration Fix

The vault pre-update prompt must NOT block the merge flow. Correct integration:

```bash
# Run BEFORE collecting changes (not after), in background/non-blocking:
if _vault_is_initialized && [[ "$dry_run" != "true" ]] && [[ "$mode" == "interactive" ]]; then
    if _prompt_yn "Vault detected. Commit current state before updating?" "Y"; then
        cmd_vault_sync "pre-update snapshot" </dev/tty >/dev/tty 2>/dev/tty || warn "Vault snapshot failed, continuing..."
    fi
fi
# Then proceed unconditionally to merge
_collect_file_changes ...
_apply_file_changes ...
```

Key constraints:
- Vault I/O must be explicitly redirected to/from `/dev/tty`
- Failure is non-fatal (`|| warn ... `)
- Merge proceeds regardless of vault result
- Skipped with `--force`, `--keep`, `--dry-run`

---

## 5. Template System

### 5.1 CLI Interface

```bash
cco project create my-app                          # Uses base template
cco project create my-app --template tutorial      # Uses tutorial template
cco project create my-app --template my-preset     # Uses user template

cco pack create my-pack                            # Uses base template
cco pack create my-pack --template my-preset       # Uses user template

cco template list                                  # List all templates (native + user)
cco template list --project                        # Project templates only
cco template list --pack                           # Pack templates only
cco template show <name>                           # Show template details
cco template create <name> --project               # Create empty user project template
cco template create <name> --pack                  # Create empty user pack template
cco template create <name> --from <project>        # Create template from existing project
cco template remove <name>                         # Remove user template
```

### 5.2 Template Resolution

```
For --template <name> (or default "base"):
1. user-config/templates/<kind>/<name>/    ← User templates (priority)
2. <repo>/templates/<kind>/<name>/         ← Native templates (fallback)
3. Error if not found
```

### 5.3 Template Metadata

```yaml
# templates/project/tutorial/template.yml
name: tutorial
description: Interactive tutorial for learning claude-orchestrator
author: claude-orchestrator
tags: [tutorial, learning, onboarding]
variables:
  - name: PROJECT_NAME
    required: true
  - name: DESCRIPTION
    default: ""
  - name: CCO_REPO_ROOT
    source: env
```

Templates without `template.yml` work fine — `{{VAR}}` placeholders resolved via
sed substitution (backward compatible).

### 5.4 User Config — Template Storage

```
user-config/
├── global/                         # Global defaults
├── projects/                       # Installed projects
├── packs/                          # Installed packs
└── templates/                      # User-defined templates
    ├── project/
    │   └── my-preset/              # User project template
    └── pack/
        └── my-pack-preset/         # User pack template
```

---

## 6. `cco clean` — Cleanup Command

### 6.1 Final Behavior

```bash
cco clean                          # Remove .bak files (global + all projects)
cco clean --tmp                    # Remove .tmp/ dirs (dry-run artifacts)
cco clean --generated              # Remove docker-compose.yml (generated by cco start)
cco clean --all                    # --bak + --tmp + --generated
cco clean --project <name>         # Scope to specific project only
cco clean --all --project <name>   # All categories, single project
cco clean --dry-run                # Preview any combination without deleting
```

### 6.2 What Each Category Cleans

| Flag | Target | Location |
|------|--------|----------|
| (default) | `*.bak` files | global `.claude/` + all project dirs |
| `--tmp` | `.tmp/` directories | `user-config/projects/<name>/.tmp/` |
| `--generated` | `docker-compose.yml` | `user-config/projects/<name>/docker-compose.yml` |

> **`.cco-base/` is NOT cleaned** by any `cco clean` variant. It is the
> 3-way merge ancestor and must not be deleted in normal operations. Future
> `cco clean --reset` (not yet implemented) would handle full state reset.

### 6.3 `.tmp/` Details

`cco start --dry-run` writes all generated files to `<project_dir>/.tmp/`:
- `docker-compose.yml`
- `.managed/` (policy.json, browser config, etc.)

The directory is recreated fresh on each dry-run (`rm -rf` + `mkdir`), so
`.tmp/` always contains the most recent dry-run output. `cco clean --tmp`
removes the directory entirely, which is appropriate after inspection.

---

## 7. Template vs Pack — Clear Boundaries

| Aspect | Template | Pack |
|--------|----------|------|
| **Purpose** | Scaffold new resources | Reusable knowledge/config |
| **Cardinality** | 1 template → N projects | 1 pack → N projects (shared) |
| **Installation** | `project create --template` | `pack install` + reference in project.yml |
| **After install** | Template recorded in `.cco-meta`; output tracked as project | Pack remains; updates via `pack update` |
| **Content** | Full project structure with placeholders | Knowledge, rules, skills, agents |
| **Update mechanism** | Native: `cco update`. User: `cco update --sync-templates` | `cco pack update` from source |

---

## 8. Command Reference — `cco update`

```
SYNOPSIS
    cco update [OPTIONS]
    cco update --project <name> [OPTIONS]
    cco update --all [OPTIONS]

OPTIONS
    (no flags)              Update global config + all projects (native sources only)
    --project <name>        Update a specific project only (+ global)
    --all                   Explicitly update global + all projects
    --sync-templates        Also update files from user-authored templates
                            (projects with template_source: user)
    --dry-run               Show what would change without applying
    --force                 Overwrite all user modifications (creates .bak)
    --keep                  Preserve all user modifications (skip conflicts)
    --replace               Replace changed files entirely (creates .bak, no merge)
    --no-backup             Disable .bak creation (combine with any mode)

SOURCES
    Global config           defaults/global/
    Project native files    templates/project/base/          (always-native: settings.json, project.yml)
    Project template files  templates/project/<template>/    (if template_source: native)
                            user-config/templates/project/<template>/  (if template_source: user, requires --sync-templates)

WHAT cco update DOES NOT TOUCH
    mcp.json                user-owned, personal MCP servers
    project/.claude/CLAUDE.md  user-owned, project context
    project/setup.sh        copy-if-missing, only written at project create
    project/secrets.env     copy-if-missing
    project/mcp-packages.txt   copy-if-missing
    .cco-base/              never modified by clean or update (only overwritten by update itself)
    user-config/templates/  user template sources; only read with --sync-templates
```

---

## 9. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Breaking existing installs | Users can't start sessions | Migration 007 bootstraps `.cco-base/`; migration 008 adds template metadata |
| `git merge-file` not available | Merge fails | Always in Docker image; on host, detected at startup with helpful error |
| False conflicts on first run | Unnecessary prompts | Best-effort base reconstruction in migration 007; clean on second run |
| Vault prompt blocking merge | Update exits without merging | Fix: explicit TTY redirect + non-fatal error handling (section 4.16) |
| User template drift | `--sync-templates` produces unexpected merges | Vault snapshot recommended before `--sync-templates`; `.bak` always created |
| Conflict markers in YAML/JSON | Broken config | Post-merge validation; warn if markers remain |
| Missing user template on `--sync-templates` | Cannot resolve source | Skip with warning; log template name so user can fix |

---

## 10. Decisions Log

1. **Template variables**: Formalized via `template.yml` with `variables:` section.
   Backward compatible with existing `{{VAR}}` sed substitution.

2. **Pack base template**: Minimal scaffold with correct directory structure.

3. **`cco template validate`**: Deferred. Good to have but not blocking.

4. **Merge engine**: `git merge-file` — works without git repository, standard
   3-way merge, always available in Docker image.

5. **Base version storage**: `.cco-base/` alongside `.cco-meta` — simple,
   self-contained, no vault dependency.

6. **Vault integration**: Optional pre-update snapshot. Vault is user versioning,
   not framework versioning. Must not block merge flow (see section 4.16).

7. **3-way merge (not 2-way)**: Base version is essential to disambiguate
   "who changed what". Without it, every difference is ambiguous.

8. **Automatic `.bak` backup**: Created whenever user files are modified.
   Disabled only with explicit `--no-backup`.

9. **`--replace` mode**: Available per-file (option R in conflict prompt) and
   as global flag. Creates `.bak`.

10. **`cco clean` command**: Dedicated cleanup command. Categories: `.bak` (default),
    `--tmp` (dry-run artifacts), `--generated` (docker-compose.yml).
    `.cco-base/` excluded — it is the merge ancestor.

11. **Template `--from` with interactive templatization**: Interactive prompt
    to replace project-specific values with `{{PLACEHOLDER}}` variables.

12. **`project.yml` as `tracked`** *(new, 2026-03-14)*: Added to
    `PROJECT_FILE_POLICIES` as `tracked`. Update source is always the native
    `base` template (never user templates) for consistent schema propagation.
    Template vars substituted from `.cco-meta` at merge time.

13. **Template-aware update source** *(new, 2026-03-14)*: `.cco-meta` records
    `template` and `template_source` (native/user). `_update_project()` resolves
    the update source from these fields. Template-specific files (skills, rules
    from non-base templates) use the stored template as their update source.

14. **`--sync-templates` flag** *(new, 2026-03-14)*: Separates native framework
    updates (`cco update`) from user template propagation (`cco update --sync-templates`).
    Without the flag, projects with `template_source: user` are updated for
    native-baseline files only. With the flag, user template source is also read.
    Rationale: different trigger conditions, different intent, prevents accidental
    propagation of in-progress template edits.

15. **`cco clean --tmp`** *(new, 2026-03-14)*: Removes `<project>/.tmp/`
    directories created by `cco start --dry-run`. These are intentionally
    persistent (for user inspection) but should be cleanable on demand.

16. **`cco clean --generated`** *(new, 2026-03-14)*: Removes `docker-compose.yml`
    from project directories. Regenerated by `cco start`, so safe to delete.
    `.managed/` is excluded (regenerated automatically on each start).

17. **Vault prompt bug** *(identified 2026-03-14)*: Current implementation
    redirects vault prompt I/O in a way that breaks subsequent interactive merge
    prompts. Fix: explicit `/dev/tty` redirect for vault commands; non-fatal
    error handling; unconditional continuation to merge phase.
