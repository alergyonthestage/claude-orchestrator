# Sprint 5b — Design: Defaults, Templates & Update System

**Status**: Draft — In Review
**Date**: 2026-03-13
**Scope**: Architecture-level

---

## 1. Business Model — Resource Taxonomy

claude-orchestrator manages four distinct resource categories. Today they are mixed under `defaults/`. This design separates them by **lifecycle** and **ownership**.

```
┌──────────────────────────────────────────────────────────────────────┐
│                     Resource Taxonomy                                │
├──────────────┬───────────────┬──────────────┬───────────────────────┤
│  Category    │  Lifecycle    │  Ownership   │  Mutability           │
├──────────────┼───────────────┼──────────────┼───────────────────────┤
│  Managed     │  Baked in     │  Framework   │  Immutable (Docker)   │
│              │  Docker image │              │                       │
├──────────────┼───────────────┼──────────────┼───────────────────────┤
│  Defaults    │  Copied once  │  Framework → │  User-owned after     │
│              │  at cco init  │  User        │  install. Tracked     │
│              │               │              │  for updates.         │
├──────────────┼───────────────┼──────────────┼───────────────────────┤
│  Templates   │  On-demand    │  Framework   │  Read-only source.    │
│  (native)    │  scaffolding  │  (shipped)   │  Output is user-owned │
├──────────────┼───────────────┼──────────────┼───────────────────────┤
│  Templates   │  On-demand    │  User        │  User manages both    │
│  (user)      │  scaffolding  │              │  source and output    │
└──────────────┴───────────────┴──────────────┴───────────────────────┘
```

### Key Distinctions

| Aspect | Defaults | Templates |
|--------|----------|-----------|
| **When used** | `cco init`, `cco update` | `cco project create`, `cco pack create` |
| **How many** | One set (global) | Multiple (project-base, tutorial, user-defined...) |
| **Tracked by update** | Yes — checksum in `.cco-meta` | No — source is a blueprint, output is tracked as project |
| **Relationship to user files** | 1:1 mapping (default → installed file) | 1:N mapping (template → many projects) |
| **Framework updates** | Propagated via `cco update` | New template versions available but don't affect existing projects |

---

## 2. Directory Reorganization

### 2.1 Current Structure (Problems)

```
defaults/
├── managed/      ← Framework infra (correct role, misleading parent name)
├── global/       ← User defaults (correct role, misleading parent name)
├── _template/    ← Project scaffold (underscore convention, single template)
└── tutorial/     ← Pre-built project (is it a default? a template? unclear)
```

**Problems:**
1. `defaults/` mixes two unrelated concepts (defaults vs templates)
2. `_template/` underscore prefix is arbitrary — no way to add more templates
3. `tutorial/` is semantically a template (pre-configured project), not a default
4. Pack creation has no template (inline heredoc in code)

### 2.2 Proposed Structure

```
defaults/                          # Framework-managed configuration sources
├── managed/                       # Baked in Docker → /etc/claude-code/
│   ├── managed-settings.json
│   ├── CLAUDE.md
│   └── .claude/skills/init-workspace/SKILL.md
│
└── global/                        # Copied to user-config/global/ at cco init
    ├── setup.sh
    ├── setup-build.sh
    └── .claude/
        ├── CLAUDE.md
        ├── settings.json
        ├── mcp.json
        ├── agents/{analyst,reviewer}.md
        ├── rules/{language,diagrams,git-practices,workflow}.md
        └── skills/{analyze,review,design,commit}/SKILL.md

templates/                         # Scaffolding blueprints (read-only sources)
├── project/                       # Project templates
│   ├── base/                      # Default template (used when no --template specified)
│   │   ├── project.yml
│   │   ├── setup.sh
│   │   ├── secrets.env
│   │   ├── mcp-packages.txt
│   │   ├── claude-state/
│   │   └── .claude/{CLAUDE.md,settings.json,rules/,agents/,skills/}
│   │
│   └── tutorial/                  # Tutorial template (installed at cco init)
│       ├── project.yml
│       ├── setup.sh
│       ├── claude-state/
│       └── .claude/{CLAUDE.md,settings.json,rules/,skills/}
│
└── pack/                          # Pack templates
    └── base/                      # Default pack template (minimal)
        ├── pack.yml
        └── {knowledge,skills,agents,rules}/.gitkeep
```

### 2.3 User Config — Template Storage

Users can create their own templates in `user-config/templates/`:

```
user-config/
├── global/                        # Global defaults (from cco init)
├── projects/                      # Installed projects
├── packs/                         # Installed packs
└── templates/                     # User-defined templates (NEW)
    ├── project/                   # User project templates
    │   └── my-preset/             # Example: pre-configured project with packs and settings
    │       ├── project.yml
    │       ├── setup.sh
    │       └── .claude/...
    └── pack/                      # User pack templates
        └── my-pack-preset/        # Example: template for domain-specific packs
            ├── pack.yml
            └── knowledge/...
```

### 2.4 Template Resolution Order

When `cco project create --template <name>`:

```
1. user-config/templates/project/<name>/     ← User templates (priority)
2. <repo>/templates/project/<name>/          ← Native templates (fallback)
```

If `--template` is omitted → use `base/` template.

### 2.5 Migration Path

| Old Path | New Path | Change |
|----------|----------|--------|
| `defaults/managed/` | `defaults/managed/` | Unchanged |
| `defaults/global/` | `defaults/global/` | Unchanged |
| `defaults/_template/` | `templates/project/base/` | Moved + renamed |
| `defaults/tutorial/` | `templates/project/tutorial/` | Moved |
| _(new)_ | `templates/pack/base/` | New — pack template |

**Code changes required** (~15 references):
- `bin/cco`: Update `TEMPLATE_DIR` → `TEMPLATES_DIR` (already exists as variable)
- `lib/cmd-project.sh`: Use template resolution logic
- `lib/cmd-pack.sh`: Use pack template instead of inline heredoc
- `Dockerfile`: No change (only copies `defaults/managed/`)
- Tests: Update paths

---

## 3. Template System

### 3.1 CLI Interface

```bash
# Project templates
cco project create my-app                          # Uses base template
cco project create my-app --template tutorial      # Uses tutorial template
cco project create my-app --template my-preset     # Uses user template

# Pack templates
cco pack create my-pack                            # Uses base template
cco pack create my-pack --template my-preset       # Uses user template

# Template management
cco template list                                  # List all templates
cco template list --project                        # List project templates only
cco template list --pack                           # List pack templates only
cco template show <name>                           # Show template details
cco template create <name> --project               # Create user project template
cco template create <name> --pack                  # Create user pack template
cco template create <name> --from <project>        # Create template from existing project
cco template remove <name>                         # Remove user template
```

### 3.2 Template Resolution

```bash
# Pseudo-code for template resolution
resolve_template() {
    local kind="$1"    # "project" or "pack"
    local name="$2"    # template name or empty for "base"

    name="${name:-base}"

    # 1. User templates (priority)
    if [[ -d "$TEMPLATES_DIR/$kind/$name" ]]; then
        echo "$TEMPLATES_DIR/$kind/$name"
        return 0
    fi

    # 2. Native templates (fallback)
    if [[ -d "$REPO_ROOT/templates/$kind/$name" ]]; then
        echo "$REPO_ROOT/templates/$kind/$name"
        return 0
    fi

    die "Template '$name' not found for $kind"
}
```

### 3.3 Template Metadata

Templates include a `template.yml` for discoverability and variable declaration:

```yaml
# templates/project/tutorial/template.yml
name: tutorial
description: Interactive tutorial for learning claude-orchestrator
author: claude-orchestrator
tags: [tutorial, learning, onboarding]
variables:
  - name: PROJECT_NAME
    description: Name of the project
    required: true
  - name: DESCRIPTION
    description: Short project description
    default: ""
  - name: CCO_REPO_ROOT
    description: Path to cco repository on host
    source: env    # Resolved from environment variable
  - name: CCO_USER_CONFIG_DIR
    description: Path to user config directory
    source: env
```

**Variable resolution order:**
1. `--var KEY=VALUE` CLI flags (explicit)
2. Interactive prompt (if TTY available)
3. `source: env` → resolved from environment
4. `default:` value from template.yml
5. Error if `required: true` and no value found

Templates without `template.yml` work fine — directory name is the identifier, and `{{VAR}}` placeholders are resolved via the existing sed substitution (backward compatible).

### 3.4 `--from` Flag: Template from Existing Resource

```bash
cco template create my-preset --from projects/my-app
```

**Flow:**
1. Copy project directory to `user-config/templates/project/my-preset/`
2. Strip runtime state (`claude-state/`, `.cco-meta`, `secrets.env` contents)
3. Optionally replace project-specific values with `{{PLACEHOLDERS}}`
4. Generate `template.yml` with metadata

---

## 4. Update System Redesign — Git-Based 3-Way Merge

### 4.1 Core Insight

The current update system treats files as **atomic units**: a file is either replaced entirely or kept entirely. This forces users into all-or-nothing choices and loses customizations.

A better approach: **line-level 3-way merge** using `git merge-file`. This command works on **individual files without requiring a git repository**, making it independent from vault.

### 4.2 Why 3-Way Merge (Not 2-Way Diff)

A 2-way diff (current vs new) sees that two versions differ, but **cannot determine who changed what**. Every difference becomes a potential conflict because there is no common ancestor to disambiguate.

A 3-way merge adds the **base** (ancestor) version — the framework version the user originally received. This allows the algorithm to attribute each change:

| current vs base | new vs base | Attribution | Action |
|----------------|-------------|-------------|--------|
| Same | Changed | Framework updated | Auto-apply framework change |
| Changed | Same | User customized | Preserve user change |
| Changed | Changed (same way) | Both agree | Auto-apply (identical change) |
| Changed | Changed (differently) | True conflict | Prompt user |

**Example**: `mount_socket: true` in user's file, `mount_socket: false` in new framework.
- **2-way**: Is this a user preference or an old default? Unknown → conflict.
- **3-way**: Base had `true` → user didn't change it → framework changed it → auto-apply `false`.

Without the base, merge is reduced to "your version or theirs" — no automatic resolution possible.

### 4.3 How `git merge-file` Works

```bash
git merge-file [--diff3] <current> <base> <new>
#                         ours     ancestor  theirs
```

- **current** (ours): the user's file with customizations
- **base** (ancestor): the framework version the user originally received
- **new** (theirs): the updated framework version

The command modifies `<current>` in-place, merging changes from both sides. If conflicts exist, it inserts standard conflict markers and returns a non-zero exit code.

**Key properties:**
- No git repository needed — operates on plain files
- Standard 3-way merge algorithm (same as `git merge`)
- Returns 0 if clean merge, >0 if conflicts remain
- Conflict markers are human-readable and editor-compatible
- Available everywhere git is installed (always true for cco — Docker image includes git)

### 4.4 The Three Versions Problem

For 3-way merge to work, we need three versions of each file:

| Version | Source | Current Availability |
|---------|--------|---------------------|
| **Current** (ours) | User's installed file | Always available |
| **Base** (ancestor) | Framework version at time of last install/update | **Not stored today** — only hash in `.cco-meta` |
| **New** (theirs) | Updated framework version in `defaults/` | Always available |

**The missing piece**: We have the hash of the base version (in `.cco-meta` manifest), but not the actual file content. We need the base content to perform 3-way merge.

### 4.5 Approach: Base Version Storage

**Option A: Store base files in `.cco-base/`**

Store a copy of each framework file as it was at install/update time:

```
user-config/global/
├── .claude/
│   ├── .cco-meta              # Manifest with hashes
│   ├── .cco-base/             # Base versions for 3-way merge (NEW)
│   │   ├── CLAUDE.md
│   │   ├── settings.json
│   │   ├── rules/workflow.md
│   │   └── ...
│   ├── CLAUDE.md              # User's current version
│   ├── settings.json
│   └── ...
```

- Pro: Simple, self-contained, no external dependencies
- Pro: Works offline, no git repo needed
- Pro: Base is always available even if user reinstalls git
- Con: Doubles storage for tracked files (~50KB total — negligible)
- Con: Another hidden directory to maintain

**Option B: Use git object store (requires vault)**

Store base versions as git blobs, referenced by hash from `.cco-meta`:

```bash
# Store: git hash-object -w <file> → returns SHA
# Retrieve: git cat-file blob <sha> > /tmp/base_version
```

- Pro: No duplicate files on disk
- Pro: Leverages existing git infrastructure
- Con: Requires vault to be initialized (not optional anymore)
- Con: More complex retrieval logic

**Option C: Reconstruct base from defaults git history**

Use `git log` on the cco repository to find the version of defaults that matches the manifest hash:

- Pro: No additional storage
- Con: Extremely fragile — depends on cco repo being available and unmodified
- Con: Slow — requires git log traversal

**Recommended: Option A (`.cco-base/`)**

The storage cost is negligible (~50KB for all tracked files). It's self-contained, works without vault, and the implementation is trivial: after every install/update, copy the framework version to `.cco-base/`.

### 4.6 Updated File Policies

Replace the current multi-list approach with a single, declarative classification:

```bash
# File update policies
# Format: "relative_path:policy"
#
# Policies:
#   tracked    — 3-way merge on update (user customizations preserved)
#   user-owned — never touched after initial copy
#   generated  — regenerated from template + saved values (e.g., language.md)

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
    ".claude/settings.json:tracked"
    ".claude/rules/language.md:user-owned"
    "project.yml:tracked"
    "setup.sh:user-owned"
    "secrets.env:user-owned"
    "mcp-packages.txt:tracked"
)
```

Note: `root-tracked` policy is no longer needed. With 3-way merge, **all tracked files use the same mechanism** regardless of location. The distinction between `.claude/` files and root files disappears.

### 4.7 Updated Algorithm

For each `tracked` file:

```
installed  = user's current file
base       = .cco-base/<path>  (framework version at last install/update)
new        = defaults/<path>   (current framework version)

installed_hash = hash(installed)
base_hash      = hash from .cco-meta manifest (or hash(base))
new_hash       = hash(new)

if installed doesn't exist and new exists:
    → NEW: copy from defaults, save to .cco-base/

elif new_hash == base_hash:
    → NO_UPDATE: framework hasn't changed

elif installed_hash == base_hash:
    → SAFE_UPDATE: user hasn't modified, framework updated
    → copy new version, update .cco-base/

elif installed_hash != base_hash AND new_hash != base_hash:
    → BOTH_CHANGED: 3-way merge needed
    → run git merge-file
    → if clean merge: auto-apply, update .cco-base/
    → if conflicts: show to user for resolution

elif installed_hash != base_hash AND new_hash == base_hash:
    → USER_MODIFIED: user changed, framework didn't → skip
```

### 4.8 Merge Resolution Modes

```bash
cco update                    # Default: 3-way merge with auto-backup
cco update --dry-run          # Preview changes without applying
cco update --force            # Overwrite everything (ignore user changes)
cco update --keep             # Keep all user versions (skip all updates)
cco update --replace          # Replace files with new version + create .bak (no merge)
cco update --no-backup        # Disable automatic .bak creation
```

#### Backup Policy

**Automatic `.bak` creation** is the default safety net. Whenever `cco update` modifies a user file (auto-merge, conflict resolution, or replace), it creates a `.bak` copy of the user's original version BEFORE applying changes. This ensures the user can always recover their previous version.

| Scenario | `.bak` created? | Rationale |
|----------|----------------|-----------|
| SAFE_UPDATE (user unchanged) | No | Original matches base — no user work to preserve |
| BOTH_CHANGED → auto-merge (clean) | **Yes** | User had customizations; merged result may need review |
| BOTH_CHANGED → conflict resolution | **Yes** | User explicitly choosing; backup is safety net |
| `--replace` mode | **Yes** | User's file replaced entirely; .bak is the only copy |
| `--force` mode | **Yes** | Destructive; backup is critical |
| `--keep` mode | No | File not modified |
| `--no-backup` flag | No | User explicitly opts out |

The `--no-backup` flag can be combined with any mode to disable `.bak` creation:
```bash
cco update --no-backup         # Merge without backups
cco update --force --no-backup # Overwrite without backups
```

If vault is initialized and a pre-update snapshot was committed, `cco update` suggests `--no-backup` since vault already provides recovery:
```
ℹ Vault snapshot created. You can use --no-backup to skip .bak files.
```

#### Default Mode (3-way merge)

```
For each BOTH_CHANGED file:
  1. Create temp copies: /tmp/cco-merge/{current,base,new}
  2. Run: git merge-file --diff3 /tmp/cco-merge/current base new
  3. If exit code 0 (clean merge):
     → Create .bak of user's current file
     → Show diff of merged result vs current
     → "Auto-merged rules/workflow.md (no conflicts). Apply? [Y/n]"
     → If yes: copy merged result, update .cco-base/ and manifest
  4. If exit code > 0 (conflicts):
     → Show conflict summary
     → Options:
       (M)erge — open in $EDITOR with conflict markers for manual resolution
       (K)eep your version (no changes)
       (R)eplace with new default + create .bak
       (S)kip (decide later)
  5. If $EDITOR not set or not available:
     → Show conflict markers inline
     → Offer K/R/S (no edit option)
```

#### `--replace` Mode (Replace + Backup)

Alternative to merge. Replaces user files entirely with the new framework version, creating `.bak` of each original. Useful when:
- The file structure changed radically and merge produces poor results
- User prefers to manually port customizations from `.bak` to the new file
- Merge conflicts are too complex to resolve inline

```bash
cco update --replace                  # Replace all changed files + .bak
cco update --replace --project myapp  # Replace only for a specific project
```

Behavior per file:
```
For each BOTH_CHANGED or SAFE_UPDATE file:
  1. Copy current → current.bak
  2. Copy new framework version → current
  3. Update .cco-base/ and manifest
  User message: "↻ rules/workflow.md (replaced, backup → rules/workflow.md.bak)"
```

#### `.bak` File Cleanup

`.bak` files accumulate over updates. Cleanup via dedicated `cco clean` command (see section 6).
Vault: `.bak` files are gitignored in vault (not versioned).

### 4.9 Diff Preview

Before applying any changes, `cco update` shows a clear summary:

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

For `--dry-run`, show the same summary but don't apply.

### 4.10 .cco-meta Extension

```yaml
# Auto-generated by cco — do not edit
schema_version: 7
created_at: 2026-01-15T10:00:00Z
updated_at: 2026-03-13T14:30:00Z

# Source template (for projects)
template: base
template_source: native

languages:
  communication: Italian
  documentation: English
  code_comments: English

manifest:
  # All tracked files (both .claude/ and root)
  .claude/CLAUDE.md: a1b2c3d4...
  .claude/settings.json: e5f6g7h8...
  .claude/rules/workflow.md: i9j0k1l2...
  project.yml: m3n4o5p6...
  mcp-packages.txt: q7r8s9t0...
```

### 4.11 .cco-base/ Directory

Stored alongside `.cco-meta`, contains the framework version of each tracked file at the time of last install/update:

```
user-config/global/.claude/.cco-base/
├── CLAUDE.md
├── settings.json
├── agents/analyst.md
├── agents/reviewer.md
├── rules/diagrams.md
├── rules/git-practices.md
├── rules/workflow.md
├── skills/analyze/SKILL.md
├── skills/commit/SKILL.md
├── skills/design/SKILL.md
└── skills/review/SKILL.md

user-config/projects/<project-name>/.cco-base/
├── .claude/settings.json
├── project.yml
└── mcp-packages.txt
```

**Lifecycle:**
- Created at `cco init` (copy of each tracked file from defaults)
- Updated at `cco update` (overwritten with new framework version after successful merge)
- Never modified by user (hidden directory, gitignored in vault)
- Size: mirrors tracked files only (~50KB total)

### 4.12 Vault Integration (Optional)

Vault remains separate and optional. Single integration point:

```bash
# In update orchestration, before applying changes:
if _vault_is_initialized && [[ "$mode" == "merge" ]]; then
    if _prompt_yn "Vault detected. Commit current state before updating?" "Y"; then
        cmd_vault_sync "pre-update snapshot"
    fi
fi
```

- Only triggers if vault is initialized
- Only in interactive/merge mode (skipped with `--force`, `--keep`, `--backup`)
- Default: Yes (safe to snapshot before destructive operations)

### 4.13 Migration System — Coexistence

The migration system remains for **structural changes** (renaming directories, moving files, changing schema). The 3-way merge handles **content updates** to existing files.

| Change Type | Mechanism | Example |
|-------------|-----------|---------|
| New section in project.yml | 3-way merge | Adding `browser:` section |
| Modified skill content | 3-way merge | Updating analyze/SKILL.md instructions |
| Renamed directory | Migration | `memory/` → `claude-state/` |
| New file type | Migration + 3-way merge | Migration creates `.cco-base/`, merge tracks going forward |
| Removed file | Migration | Cleaning up deprecated files |

**Key benefit**: Most updates no longer need explicit migrations. Adding a new commented section to `project.yml` just means updating the template — `cco update` will 3-way merge it into existing projects automatically.

### 4.14 Backward Compatibility

For existing installs without `.cco-base/`:

1. First `cco update` after this change detects missing `.cco-base/`
2. Attempts to reconstruct base from current defaults (best effort)
3. If installed_hash == manifest_hash → base = installed (user hasn't changed)
4. If installed_hash != manifest_hash → base = defaults (approximate, may cause false conflicts on first run)
5. Creates `.cco-base/` for future updates
6. From second update onward, 3-way merge works correctly

---

## 5. Template vs Pack — Clear Boundaries

| Aspect | Template | Pack |
|--------|----------|------|
| **Purpose** | Scaffold new resources | Reusable knowledge/config |
| **Cardinality** | 1 template → N projects | 1 pack → N projects (shared) |
| **Installation** | `project create --template` | `pack install` + reference in project.yml |
| **After install** | Template forgotten, project lives independently | Pack remains, updates propagated |
| **Content** | Full project/pack structure with placeholders | Knowledge, rules, skills, agents |
| **Update mechanism** | Not updated (output is tracked as project) | `pack update` from source |
| **Location (native)** | `templates/project/` or `templates/pack/` | _(not shipped — packs are user/community content)_ |
| **Location (user)** | `user-config/templates/` | `user-config/packs/` |

---

## 6. Command Changes Summary

### New Commands

| Command | Description |
|---------|-------------|
| `cco template list [--project\|--pack]` | List available templates (native + user) |
| `cco template show <name>` | Show template details and structure |
| `cco template create <name> --project\|--pack` | Create empty user template |
| `cco template create <name> --from <resource>` | Create template from existing project/pack (interactive templatization) |
| `cco template remove <name>` | Remove user template |
| `cco clean [--backups\|--tmp\|--generated\|--all]` | Remove generated/temporary files |

#### `cco clean` Details

```bash
cco clean                     # Interactive: show what can be cleaned, ask confirmation
cco clean --backups           # Remove .bak files from global + all projects
cco clean --tmp               # Remove .tmp/ directories (dry-run artifacts)
cco clean --generated         # Remove framework-generated files (.cco-base/, .cco-meta)
cco clean --all               # Remove all of the above
cco clean --project <name>    # Scope to a specific project
cco clean --dry-run           # Show what would be removed without deleting
```

### Modified Commands

| Command | Change |
|---------|--------|
| `cco project create` | Add `--template <name>` flag (default: `base`) |
| `cco pack create` | Add `--template <name>` flag (default: `base`); use template instead of inline heredoc |
| `cco update` | 3-way merge via `git merge-file`; track root files; `.cco-base/` storage; vault snapshot prompt; `--replace` and `--no-backup` flags |
| `cco init` | Create `user-config/templates/` directory; use `templates/` as source; generate `.cco-base/` |

### New Modules

| File | Description |
|------|-------------|
| `lib/cmd-template.sh` | Template CLI: list, show, create, remove |
| `lib/cmd-clean.sh` | Cleanup: backups, tmp, generated files |

---

## 7. Implementation Plan

### Phase 1: Directory Reorganization
1. Create `templates/` directory with `project/base/`, `project/tutorial/`, `pack/base/`
2. Move `defaults/_template/` → `templates/project/base/`
3. Move `defaults/tutorial/` → `templates/project/tutorial/`
4. Create `templates/pack/base/` with minimal pack template
5. Update `bin/cco` variables and template resolution
6. Update all references in `lib/*.sh`
7. Update tests
8. No user-facing migration needed (paths are in cco repo, not user-config)

### Phase 2: Template System
1. Implement `lib/cmd-template.sh` (list, show, create, remove)
2. Implement template resolution function (user → native fallback)
3. Add `--template` flag to `cco project create`
4. Add `--template` flag to `cco pack create` (replace inline heredoc)
5. Add `template.yml` with variable declarations to native templates
6. Implement `--from` flag for creating templates from existing resources
7. Create `user-config/templates/{project,pack}/` on `cco init`
8. Add tests

### Phase 3: Update System — 3-Way Merge
1. Implement `.cco-base/` storage (create on init, update on update)
2. Implement `_merge_file()` wrapper around `git merge-file`
3. Implement declarative file policies (replace GLOBAL_USER_FILES lists)
4. Extend `.cco-meta` to track root files and template source
5. Refactor `_collect_file_changes()` to use new algorithm
6. Refactor `_apply_file_changes()` with merge resolution
7. Implement diff preview summary
8. Add vault pre-update snapshot prompt
9. Add migration for `.cco-base/` bootstrap on existing installs
10. Update tests

### Phase 4: Documentation & Cleanup
1. Update `docs/maintainer/update-system/design.md`
2. Update CLAUDE.md with new structure
3. Update user-facing docs if needed

---

## 8. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Breaking existing installs | Users can't start sessions | Migration bootstraps `.cco-base/`; fallback for missing base |
| `git merge-file` not available | Merge fails | git is always in Docker image; on host, fallback to current checksum approach |
| False conflicts on first run | User sees unnecessary prompts | Best-effort base reconstruction; clean merge on second run |
| Template resolution ambiguity | Wrong template used | Clear priority (user > native); `--template` is explicit |
| .cco-meta schema change | Old cco can't read new format | Backward-compatible (new fields added, none removed) |
| Conflict markers left in config files | Broken YAML/JSON | Validate files after merge; warn if markers remain |

---

## 9. Decisions Log

1. **Template variables**: Formalized via `template.yml` with `variables:` section declaring name, description, required, default, and source. Backward compatible with existing `{{VAR}}` sed substitution.

2. **Pack base template**: Minimal, like project base. An empty scaffold with the correct directory structure.

3. **`cco template validate`**: Deferred to future sprint. Good to have but not blocking.

4. **Merge engine**: `git merge-file` — works on individual files without repository, standard 3-way merge, available everywhere git is installed.

5. **Base version storage**: `.cco-base/` directory alongside `.cco-meta` — simple, self-contained, no vault dependency.

6. **Vault integration**: Optional pre-update snapshot prompt. Vault is user versioning, not framework versioning.

7. **3-way merge (not 2-way)**: The base version is essential for disambiguating "who changed what". Without it, every difference between current and new is ambiguous. The base acts as arbiter — same role as merge-base in git.

8. **Automatic `.bak` backup**: Always created when user files are modified (auto-merge, conflict resolution, replace). Disabled only with explicit `--no-backup` flag. Safety net independent from vault.

9. **`--replace` mode**: Available as per-file option (R) during conflict resolution prompts. Replaces the file entirely with new framework version + creates `.bak`. Useful when merge produces poor results due to radical structure changes or heavy customizations. Also available as global flag `--replace` to apply to all files.

10. **`cco clean` command**: Dedicated cleanup command for `.bak` files, `.tmp/` directories, and framework-generated files. Replaces per-command cleanup flags.

11. **Template `--from` with interactive templatization**: When creating a template from an existing project/pack, interactive prompt asks which values to replace with `{{PLACEHOLDER}}` variables. Automatic detection of project-specific values (name, paths, descriptions) with user confirmation.
