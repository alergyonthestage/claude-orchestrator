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
| **Defaults** | Copied once at `cco init` | Framework → User | User-owned after install |
| **Templates (native)** | On-demand scaffolding | Framework (shipped) | Read-only source; output is user-owned |
| **Templates (user)** | On-demand scaffolding | User | User manages both source and output |

### Key Distinctions

| Aspect | Defaults | Templates |
|--------|----------|-----------|
| **When used** | `cco init`, `cco update --apply` | `cco project create`, `cco pack create` |
| **How many** | One set (global) | Multiple (base, tutorial, user-defined...) |
| **Update role** | Opinionated files: discoverable, on-demand merge | Base: opinionated source. Non-base/user: not tracked |
| **Relationship to user files** | 1:1 mapping (default → installed file) | 1:N mapping (template → many projects) |
| **Framework updates** | Discovery via `cco update`; apply via `--apply` | Base: `cco update`. Non-base/user: not auto-updated |

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

| Policy | Meaning | `cco update` behavior |
|--------|---------|----------------------|
| `opinionated` | Framework provides defaults; user owns after install | Discovery: reported as available. Applied only via `--apply` |
| `user-owned` | User owns the content entirely | Never touched — not even discovered |
| `generated` | Rebuilt from template + saved values | Regenerated on `--apply` (e.g., `language.md`) |
| `copy-if-missing` | Scaffold: written once if absent, then ignored | Written only if file doesn't exist |
| `immutable` | Baked in Docker image | Only changes on `cco build` |

### 3.1 Managed Scope (immutable)

> Not in the update system. Changes require `cco build`.

| File | Policy | Notes |
|------|--------|-------|
| `defaults/managed/CLAUDE.md` | `immutable` | Framework instructions, highest priority in Claude |
| `defaults/managed/managed-settings.json` | `immutable` | Hooks, env, deny rules — cannot be overridden |
| `defaults/managed/.claude/skills/init-workspace/SKILL.md` | `immutable` | Framework managed skill |

### 3.2 Global Scope — `cco update`

> Source: `defaults/global/` → Installed: `user-config/global/`

| File | Policy | Discoverable? | Notes |
|------|--------|---------------|-------|
| `.claude/CLAUDE.md` | `opinionated` | ✅ | Framework workflow instructions |
| `.claude/settings.json` | `opinionated` | ✅ | Global Claude Code permissions |
| `.claude/mcp.json` | `user-owned` | ❌ | Personal MCP servers |
| `.claude/agents/analyst.md` | `opinionated` | ✅ | Framework agent spec |
| `.claude/agents/reviewer.md` | `opinionated` | ✅ | Framework agent spec |
| `.claude/rules/diagrams.md` | `opinionated` | ✅ | Framework diagram conventions |
| `.claude/rules/git-practices.md` | `opinionated` | ✅ | Framework git conventions |
| `.claude/rules/workflow.md` | `opinionated` | ✅ | Framework workflow rules |
| `.claude/rules/language.md` | `generated` | ✅ | Regenerated from template + `.cco-meta` saved choices |
| `.claude/skills/analyze/SKILL.md` | `opinionated` | ✅ | Framework skill |
| `.claude/skills/commit/SKILL.md` | `opinionated` | ✅ | Framework skill |
| `.claude/skills/design/SKILL.md` | `opinionated` | ✅ | Framework skill |
| `.claude/skills/review/SKILL.md` | `opinionated` | ✅ | Framework skill |
| `setup.sh` | `user-owned` + `copy-if-missing` | ❌ | Written once at init; user customizes |
| `setup-build.sh` | `user-owned` + `copy-if-missing` | ❌ | Written once at init; user customizes |

### 3.3 Project Scope — `cco update --project`

> Source: `templates/project/base/` → Installed: `user-config/projects/<name>/`

| File | Policy | Discoverable? | Notes |
|------|--------|---------------|-------|
| `.claude/CLAUDE.md` | `user-owned` | ❌ | User writes project context from scratch |
| `.claude/settings.json` | `opinionated` | ✅ | Project permissions; source is always `base` template |
| `.claude/rules/language.md` | `copy-if-missing` | ❌ | Optional project override; commented scaffold |
| `.claude/agents/` | `user-owned` | ❌ | Project agents are user-defined |
| `.claude/skills/` | `user-owned` | ❌ | User-defined or template-installed; not discovered |
| `project.yml` | `user-owned` | ❌ | 100% user config; new fields are additive (code defaults) |
| `setup.sh` | `copy-if-missing` | ❌ | Written once at project create |
| `secrets.env` | `copy-if-missing` | ❌ | Written once; user fills secrets |
| `mcp-packages.txt` | `copy-if-missing` | ❌ | Written once; user adds packages |

**Note on `project.yml`**: Modified by 100% of users (repos, packs, docker, ports).
New config sections are additive — code defaults handle missing fields. Schema-breaking
changes use explicit migrations. See `analysis-v2.md` section 4.4.

**Note on `.claude/skills/` in project scope:**
Project-level skills (from tutorial template, user templates, or manually added)
are not discovered by `cco update`. They are outside the base template and have no
framework "new version" to compare against. Future `cco template sync` may handle this.

### 3.4 Runtime-Generated Files (not in update system)

> Generated by `cco start`. Cleaned by `cco clean --generated`.

| File | Generated by | Cleaned by |
|------|-------------|------------|
| `user-config/projects/<name>/docker-compose.yml` | `cco start` | `cco clean --generated` |
| `user-config/projects/<name>/.managed/` | `cco start` | `cco start` (regenerated each run) |
| `user-config/projects/<name>/.tmp/` | `cco start --dry-run` | `cco clean --tmp` |
| `user-config/global/.claude/.cco-meta` | `cco init` / `cco update --apply` | ❌ do not delete |
| `user-config/global/.claude/.cco-base/` | `cco init` / `cco update --apply` | ❌ do not delete |
| `user-config/projects/<name>/.cco-meta` | `cco project create` / `cco update --apply` | ❌ do not delete |
| `user-config/projects/<name>/.cco-base/` | `cco project create` / `cco update --apply` | ❌ do not delete |

> **Warning**: `.cco-base/` is the ancestor for 3-way merge. Deleting it does not
> break anything immediately, but `cco update --apply` will fall back to
> best-effort base reconstruction, potentially surfacing false conflicts.

---

## 4. Update System — Migrations + Discovery + On-Demand Merge

### 4.1 Core Principle

`cco update` does **two things**:
1. **Migrations**: Run pending migration scripts (automatic, structural changes)
2. **Discovery**: Compare framework sources against `.cco-base/` to find available updates

It **never modifies user files**. File changes happen only via `cco update --apply`,
where the user explicitly chooses what to integrate.

### 4.2 The Three Versions (for discovery and merge)

| Version | Source | Storage |
|---------|--------|---------|
| **Current** (ours) | User's installed file | `user-config/.../<file>` |
| **Base** (ancestor) | Framework version at last install/apply | `.cco-base/<file>` |
| **New** (theirs) | Current framework version | `defaults/global/.../<file>` or `templates/project/base/` |

### 4.3 Base Version Storage — `.cco-base/`

A copy of each opinionated file as delivered by the framework at install/apply time.
Stored alongside `.cco-meta`:

```
user-config/global/.claude/
├── .cco-meta                  # Manifest with hashes + metadata
├── .cco-base/                 # Ancestor versions for diff/merge
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
│   └── .claude/settings.json
└── project.yml                # User's current version (user-owned, not in .cco-base/)
```

**Lifecycle:**
- Created at `cco init` (global) and `cco project create` (project)
- Updated after each successful `cco update --apply` (per file)
- Never modified by user (hidden, gitignored in vault)
- Size: mirrors opinionated files only (~50KB total — negligible)

### 4.4 File Policies (Definitive)

```bash
# Opinionated: framework provides defaults; discovered by cco update;
# applied only via --apply. User-owned after install.
GLOBAL_OPINIONATED_FILES=(
    ".claude/CLAUDE.md"
    ".claude/settings.json"
    ".claude/agents/analyst.md"
    ".claude/agents/reviewer.md"
    ".claude/rules/diagrams.md"
    ".claude/rules/git-practices.md"
    ".claude/rules/workflow.md"
    ".claude/skills/analyze/SKILL.md"
    ".claude/skills/review/SKILL.md"
    ".claude/skills/design/SKILL.md"
    ".claude/skills/commit/SKILL.md"
)

# Generated: rebuilt from template + saved preferences
GLOBAL_GENERATED_FILES=(
    ".claude/rules/language.md"
)

# User-owned: never touched by cco update
GLOBAL_USER_OWNED=(
    ".claude/mcp.json"
    "setup.sh"
    "setup-build.sh"
)

# Project scope: only settings.json is opinionated
PROJECT_OPINIONATED_FILES=(
    ".claude/settings.json"
)

# Project user-owned: never touched by cco update
PROJECT_USER_OWNED=(
    "project.yml"
    ".claude/CLAUDE.md"
    ".claude/rules/language.md"
)

# Copy-if-missing: scaffold files written once at create, then ignored
GLOBAL_COPY_IF_MISSING=("setup.sh" "setup-build.sh")
PROJECT_COPY_IF_MISSING=("setup.sh" "secrets.env" "mcp-packages.txt")
```

### 4.5 Discovery Algorithm

For each opinionated file:

```
installed  = user's current file
base       = .cco-base/<path>
new        = defaults/<path>  (or templates/project/base/ for project scope)

if installed doesn't exist and new exists:
    → NEW_AVAILABLE: new file available from framework

elif hash(new) == hash(base):
    → NO_UPDATE: framework hasn't changed → skip

elif hash(installed) == hash(base):
    → UPDATE_AVAILABLE: user hasn't modified, framework updated
    → status: "framework has updates (you haven't modified)"

elif hash(installed) != hash(base) AND hash(new) != hash(base):
    → MERGE_AVAILABLE: both changed
    → status: "framework has updates (you also modified — merge needed)"

elif hash(installed) != hash(base) AND hash(new) == hash(base):
    → USER_MODIFIED: user changed, framework didn't → skip (nothing to offer)
```

Discovery is **read-only**. No files are modified. No prompts are shown.

### 4.6 On-Demand Merge (`--apply`)

When the user runs `cco update --apply`, each file with an available update is
presented interactively:

**For UPDATE_AVAILABLE (user hasn't modified):**

```
Global: rules/workflow.md (framework updated, you haven't modified)
  (A)pply update  (S)kip  (D)iff → _
```

Choosing (A)pply:
1. Creates `.bak` of current file
2. Copies new framework version
3. Updates `.cco-base/` with the new version

**For MERGE_AVAILABLE (both changed):**

```
Global: CLAUDE.md (both modified — merge needed)
  (M)erge 3-way  (R)eplace + .bak  (K)eep yours  (S)kip  (D)iff → _
```

- **(M)erge**: Runs `git merge-file --diff3` on temp copies. If clean merge:
  shows diff, asks for confirmation, creates `.bak`, applies. If conflicts:
  opens in `$EDITOR` (or falls back to K/R/S if no editor).
- **(R)eplace**: Creates `.bak` of current, copies framework version
- **(K)eep**: Keeps user's version, updates `.cco-base/` (acknowledges the
  framework version without applying it, so it won't be reported again)
- **(S)kip**: Defers decision (will be reported again next time)
- **(D)iff**: Shows the three-way diff for review, then re-prompts

**For NEW_AVAILABLE (new file from framework):**

```
Global: agents/debugger.md (new framework file)
  (A)dd file  (S)kip → _
```

### 4.7 How `git merge-file` Works

```bash
git merge-file [--diff3] <current> <base> <new>
#                         ours     ancestor  theirs
```

- Modifies `<current>` in-place, merging changes from both sides
- Returns 0 if clean merge, >0 if conflicts remain
- Inserts standard conflict markers on conflicts
- No git repository required — operates on plain files

### 4.8 `.cco-base/` Update Rules

`.cco-base/` is only updated by:
- `cco init` — saves initial framework versions
- `cco project create` — saves initial framework versions
- `cco update --apply` with **(A)pply**, **(M)erge**, or **(R)eplace** — saves the
  framework version that was applied
- `cco update --apply` with **(K)eep** — saves the framework version that was
  acknowledged (so the update is not reported again)

`.cco-base/` is NOT updated by:
- `cco update` (discovery only — read-only operation)
- `cco update --apply` with **(S)kip** — defers the decision
- Any other cco command

### 4.9 Apply Modes

```bash
cco update                    # Default: migrations + discovery report (no file changes)
cco update --diff             # Show detailed diffs for available updates
cco update --diff <file>      # Show 3-way diff for a specific file
cco update --apply            # Interactive per-file merge/replace/keep/skip
cco update --apply <file>     # Apply a specific file update
cco update --apply --all      # Apply all updates (still interactive per file)
cco update --dry-run          # Same as default (discovery is already read-only)
cco update --no-backup        # Disable .bak creation when used with --apply
```

### 4.10 Backup Policy

`.bak` files are created only during `--apply`:

| Action | `.bak` created? |
|--------|----------------|
| (A)pply update | **Yes** |
| (M)erge 3-way | **Yes** |
| (R)eplace + .bak | **Yes** |
| (K)eep yours | No |
| (S)kip | No |
| `--no-backup` flag | No |

### 4.11 `.cco-meta` Schema

```yaml
# Auto-generated by cco — do not edit
schema_version: 8
created_at: 2026-01-15T10:00:00Z
updated_at: 2026-03-14T10:00:00Z

# Template origin (projects only — informational, not used for update routing)
template: base               # base | tutorial | <user-template-name>

# Language preferences (global only)
languages:
  communication: Italian
  documentation: English
  code_comments: English

# Manifest: sha256 of each opinionated file at last install/apply
manifest:
  .claude/CLAUDE.md: a1b2c3d4...
  .claude/settings.json: e5f6g7h8...
  .claude/rules/workflow.md: i9j0k1l2...
```

Note: `template` is informational — it records which template was used at creation
for user reference and future `cco template sync` (not yet implemented). The update
source for opinionated files is always `templates/project/base/` for all projects.

### 4.12 Update Source: Always Base Template

`_update_project()` always uses `templates/project/base/` as its source for
opinionated files, regardless of which template created the project:

1. **Base defines the schema**: settings.json permissions
2. **All projects share the same schema**: whether created from base, tutorial, or
   a user template, the underlying project structure is the same
3. **Template-specific files have no base equivalent**: tutorial skills, user custom
   rules, etc. are not present in base and therefore cannot be compared

**Consequence**: Files that exist only in non-base templates (e.g., tutorial skills)
are never discovered by `cco update`. They are the maintainer's or user's responsibility.

### 4.13 User Template Propagation — Future Command

User template changes are NOT propagated by `cco update`. This is a non-negotiable
boundary: `cco update` means "bring me framework improvements", not "sync my
personal templates".

A future `cco template sync <project-name>` command will handle user template
propagation using the same diff/merge engine. Design deferred to a future sprint.

See `analysis-v2.md` section 5 for full template philosophy.

### 4.14 Vault Integration

The vault pre-update prompt must NOT block the discovery/apply flow:

```bash
# Run BEFORE merge operations, in background/non-blocking:
if _vault_is_initialized && [[ "$mode" == "apply" ]]; then
    if _prompt_yn "Vault detected. Commit current state before applying?" "Y"; then
        cmd_vault_sync "pre-update snapshot" </dev/tty >/dev/tty 2>/dev/tty || warn "Vault snapshot failed, continuing..."
    fi
fi
# Then proceed unconditionally to apply
```

Key constraints:
- Vault I/O must be explicitly redirected to/from `/dev/tty`
- Failure is non-fatal (`|| warn ...`)
- Apply proceeds regardless of vault result
- Vault prompt only shown for `--apply` (not for discovery)

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
> diff/merge ancestor and must not be deleted in normal operations.

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
| **After install** | Template recorded in `.cco-meta`; output is user-owned | Pack remains; updates via `pack update` |
| **Content** | Full project structure with placeholders | Knowledge, rules, skills, agents |
| **Update mechanism** | Opinionated files via `cco update --apply`. Non-base: manual | `cco pack update` from source |

---

## 8. Command Reference — `cco update`

```
SYNOPSIS
    cco update [OPTIONS]
    cco update --project <name> [OPTIONS]
    cco update --all [OPTIONS]

MODES
    (no flags)              Migrations + discovery report (no file changes)
    --diff                  Show detailed diffs for available updates
    --diff <file>           Show 3-way diff for a specific file
    --apply                 Interactive per-file merge/replace/keep/skip
    --apply <file>          Apply a specific file update
    --apply --all           Apply all updates (still interactive per file)

OPTIONS
    --project <name>        Scope to specific project (+ global)
    --all                   Explicitly scope to global + all projects
    --no-backup             Disable .bak creation (combine with --apply)
    --dry-run               Same as default (discovery is already read-only)

SOURCES
    Global config           defaults/global/
    Project opinionated     templates/project/base/          (.claude/settings.json)

WHAT cco update DOES (automatically)
    Migrations              Run pending scripts from migrations/{global,project}/
    Discovery               Compare framework sources against .cco-base/ for updates

WHAT cco update DOES NOT DO (automatically)
    File modifications      Never — requires explicit --apply
    Template sync           Never — future cco template sync command
    Pack updates            Never — use cco pack update

WHAT cco update --apply DOES NOT TOUCH
    mcp.json                user-owned, personal MCP servers
    project.yml             user-owned, 100% user config
    project/.claude/CLAUDE.md  user-owned, project context
    project/setup.sh        copy-if-missing, only written at project create
    project/secrets.env     copy-if-missing
    project/mcp-packages.txt   copy-if-missing
    .cco-base/              only overwritten by --apply itself (not by clean or other commands)
    user-config/templates/  never read by cco update (user domain)
```

---

## 9. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Breaking existing installs | Users can't start sessions | Migration 007 bootstraps `.cco-base/`; migration 008 adds template metadata |
| `git merge-file` not available | Merge fails | Always in Docker image; on host, detected at startup with helpful error |
| Conflict markers in YAML/JSON | Broken config | Post-merge validation; warn if markers remain |
| Vault prompt blocking apply | Apply exits without merging | Fix: explicit TTY redirect + non-fatal error handling (section 4.14) |
| User confused by discovery output | Runs --apply without understanding | Clear messaging: "N updates available. Run --diff for details." |

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

6. **Vault integration**: Optional pre-apply snapshot. Vault is user versioning,
   not framework versioning. Must not block apply flow (see section 4.14).

7. **3-way merge (not 2-way)**: Base version is essential to disambiguate
   "who changed what". Without it, every difference is ambiguous.

8. **Automatic `.bak` backup**: Created whenever user files are modified
   via `--apply`. Disabled only with explicit `--no-backup`.

9. **`cco clean` command**: Dedicated cleanup command. Categories: `.bak` (default),
   `--tmp` (dry-run artifacts), `--generated` (docker-compose.yml).
   `.cco-base/` excluded — it is the merge ancestor.

10. **Template `--from` with interactive templatization**: Interactive prompt
    to replace project-specific values with `{{PLACEHOLDER}}` variables.

11. **Update source is always base template** *(revised, 2026-03-14)*: `.cco-meta`
    records `template` (informational only). Update always uses
    `templates/project/base/` as the source. Template-specific files
    are not discovered — they have no base equivalent.

12. **`--sync-templates` removed** *(revised, 2026-03-14)*: User template
    propagation is NOT a flag on `cco update`. Deferred to future
    `cco template sync` command.

13. **`cco update` = migrations + discovery** *(revised, 2026-03-14)*: No
    automatic file modifications. Discovery is read-only. File changes
    require explicit `--apply`. Even unmodified files are not silently updated.

14. **`project.yml` is user-owned** *(revised, 2026-03-14)*: Removed from
    tracked/opinionated files. 100% user config — new fields are additive
    (code defaults), schema changes use migrations.

15. **`cco clean --tmp`** *(new, 2026-03-14)*: Removes `<project>/.tmp/`
    directories created by `cco start --dry-run`.

16. **`cco clean --generated`** *(new, 2026-03-14)*: Removes `docker-compose.yml`
    from project directories. Regenerated by `cco start`, so safe to delete.

17. **Vault prompt bug** *(identified 2026-03-14)*: Current implementation
    redirects vault prompt I/O in a way that breaks subsequent interactive
    prompts. Fix: explicit `/dev/tty` redirect; non-fatal error handling.
