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
| **Update role** | Opinionated files: discoverable, on-demand merge | Base: opinionated source. Non-base/user: not discoverable |
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
│   │   ├── project.yml                #   Project configuration template
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
changes use explicit migrations. See `analysis.md` section 4.4.

**Note on `.claude/skills/` in project scope:**
For **base projects**, project-level skills are user-defined and not discovered.
For **native template projects** (tutorial), template-provided skills ARE discovered
because they have a framework source in `templates/project/<name>/`. The project's
`.cco-source` (`native:project/tutorial`) tells the update engine where to look.
User-added skills (not from the template) remain user-owned and undiscovered.

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
| `user-config/projects/<name>/.cco-source` | `cco project create --template` / `cco project install` | ❌ do not delete |
| `user-config/packs/<name>/.cco-meta` | `cco pack create` / `cco pack install` | ❌ do not delete |
| `user-config/packs/<name>/.cco-source` | `cco pack install` | ❌ do not delete |
| `user-config/templates/<name>/.cco-meta` | `cco template create` | ❌ do not delete |

> **Warning**: `.cco-base/` is the ancestor for 3-way merge. Deleting it does not
> break anything immediately, but `cco update --apply` will fall back to
> best-effort base reconstruction, potentially surfacing false conflicts.

---

## 4. Update System — Migrations + Discovery + On-Demand Merge

### 4.1 Core Principle

`cco update` does **three things**:
1. **Migrations**: Run pending migration scripts (automatic, structural changes)
2. **Discovery**: Compare framework sources against `.cco-base/` to find available opinionated file updates
3. **Notifications**: Report additive changes (new features, new config fields) from `changelog.yml`

It **never modifies user files** (except via migrations, which are structural).
Content changes happen only via `cco update --apply`, where the user explicitly
chooses what to integrate.

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

elif base doesn't exist:
    → BASE_MISSING: .cco-base/ entry absent (pre-bootstrap or deleted)
    → Fallback: treat installed as base (assume user hasn't modified)
    → Reconstruct .cco-base/ from current installed file
    → Compare reconstructed base vs new → if different: UPDATE_AVAILABLE
    → Note: may produce false UPDATE_AVAILABLE if user modified the file,
      but this is the safest fallback (user can Skip or Keep)
```

Discovery is **read-only**. No files are modified. No prompts are shown.
The BASE_MISSING fallback reconstructs `.cco-base/` only during `--apply`
(when the user confirms), not during discovery.

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

**Conflict resolution flow** (when `git merge-file` returns >0):

1. Conflicting sections are shown inline in the terminal
2. User chooses an action:
   - **(M)erge** [default]: file is written with conflict markers + `.bak` backup.
     User resolves markers manually in their editor of choice.
   - **(E)dit**: same as Merge, but also opens `$EDITOR` immediately (only shown
     if `$EDITOR` is set and available).
   - **(R)eplace**: overwrite with framework version + `.bak`
   - **(K)eep**: keep user version unchanged
   - **(S)kip**: defer to next run
3. After M/E: `.cco-base/` is always updated (the user has dealt with the
   merge). If conflict markers remain, `cco start` blocks until resolved —
   that's the safety net, not the update system.
4. Once the user resolves markers manually, the next `cco update` sees the
   file as `USER_MODIFIED` (resolved version ≠ base) — a clean state.
   No infinite loop: the base is up-to-date, so no re-merge is triggered.

**Pre-start safety check**: `cco start` scans both global and project `.claude/`
directories for unresolved conflict markers (`<<<<<<<` in `.md` and `.json` files).
If any are found, the session is blocked with an error listing the affected files.
This prevents launching a session with broken config files.

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

### 4.9 Command Modes

```bash
# Discovery (default — read-only, no file changes except migrations)
cco update                    # Migrations + discovery + additive notifications
cco update --project <name>   # Scope to specific project (+ global)
cco update --all              # Scope to global + all projects (default if no --project)

# Inspection
cco update --diff             # Show detailed diffs for all available updates
cco update --diff <file>      # Show 3-way diff for a specific file

# Application (interactive — modifies files on user confirmation)
cco update --apply            # Interactive per-file: apply/merge/replace/keep/skip
cco update --apply <file>     # Apply a specific file update only
cco update --no-backup        # Disable .bak creation (combine with --apply)

# Preview
cco update --dry-run          # Show pending migrations without running them + discovery
```

**Flag semantics:**
- `--all` and `--project <name>` control **scope** (which projects to check)
- `--diff` and `--apply` control **action** (inspect vs modify)
- `--dry-run` prevents migrations from running (shows them as pending) and
  performs discovery as usual. Useful to preview what `cco update` would do
  before running it.

**Per-file path resolution** (`--apply <file>` / `--diff <file>`):
The `<file>` argument is matched against opinionated file paths in all scopes
(global + projects in scope). If ambiguous (e.g., `settings.json` exists in
global and project), the user is prompted to disambiguate. Full path syntax
`global:settings.json` or `project/myapp:settings.json` resolves unambiguously.

**Flag composition rules:**
- `--diff` and `--apply` respect the same scope as discovery (`--project`/`--all`)
- `--diff --project myapp` shows diffs for global + myapp opinionated files
- `--apply --project myapp` prompts for global + myapp files
- `--apply --dry-run` is an error (conflicting intent). Use `--diff` to preview.
- `--diff` without scope flags uses the default scope (global + all projects)

**Non-interactive fallback**: When stdin is not a TTY (e.g., CI), `--apply`
defaults to **(S)kip** for all files (safest choice). No silent modifications.

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

# Last seen changelog entry (global only — for additive change notifications)
last_seen_changelog: 12

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

**Variants by scope:**
- **Global**: Full schema (languages, last_seen_changelog, manifest)
- **Project**: `schema_version`, `template`, `manifest` (no languages, no changelog)
- **Pack**: `schema_version`, `manifest` only
- **User template**: `schema_version` only

Note: `template` is informational — it records which template was used at creation
for user reference and future `cco template sync` (not yet implemented).

### 4.12 Update Source Resolution

`_update_project()` resolves the update source based on the project's origin:

**For base projects** (no `--template` flag, or `.cco-source` absent):
- Source: `templates/project/base/`
- Discovers: `.claude/settings.json` only

**For native template projects** (`.cco-source` with `native:project/<name>`):
- Source: `templates/project/<name>/` (e.g., `templates/project/tutorial/`)
- Discovers: template-specific opinionated files (skills, rules) + base files (settings.json)
- Base files are compared against `templates/project/base/` (schema source)
- Template files are compared against `templates/project/<name>/` (content source)

**For user template projects** (`.cco-source` absent, `.cco-meta` has `template: <user-name>`):
- Source: `templates/project/base/` only (base opinionated files)
- User template files are not discovered — future `cco template sync`

**For remote-installed projects** (`.cco-source` with remote URL):
- Source: `templates/project/base/` for opinionated files
- Remote changes: notify only (see analysis.md section 7.6)

**Missing source fallback**: If `.cco-source` references a native template that
no longer exists (e.g., `native:project/tutorial` but `templates/project/tutorial/`
was removed), `cco update` emits a warning and falls back to base-only discovery:
```
⚠ Template 'tutorial' referenced by project 'my-tutorial' not found.
  Falling back to base template for discovery.
```

### 4.13 User Template Propagation — Future Command

User template changes are NOT propagated by `cco update`. This is a non-negotiable
boundary: `cco update` means "bring me framework improvements", not "sync my
personal templates".

A future `cco template sync <project-name>` command will handle user template
propagation using the same diff/merge engine. Design deferred to a future sprint.

See `analysis.md` section 5 for full template philosophy.

### 4.14 Additive Change Notifications (`changelog.yml`)

`cco update` reports new features from a structured changelog so users discover
capabilities without reading docs proactively.

**File**: `changelog.yml` in the cco repo root:

```yaml
# changelog.yml — user-visible additive changes
- id: 12
  type: additive
  date: 2026-03-14
  summary: "New 'rag:' section in project.yml for semantic search"
  docs: "docs/reference/project-yaml.md#rag"
  example: |
    rag:
      enabled: true
      provider: local-rag
```

**Tracking**: `.cco-meta` (global only) stores `last_seen_changelog: <id>`.
`cco update` compares against the latest entry in `changelog.yml` and reports
unseen changes. After reporting, updates `last_seen_changelog`.

**Output**: Shown between migrations and discovery in the `cco update` output:

```
What's new in cco:
  + project.yml: new 'rag:' section (semantic search)
  Run 'cco update --news' for details and examples.
```

**Location**: `<repo-root>/changelog.yml` — shipped in the cco repo, read by
the host-side CLI (not inside Docker). `cco update` runs on the host, so no
Docker mount needed.

**Fallback**: If `changelog.yml` does not exist or is empty, notifications are
silently skipped (no error). This ensures backward compatibility when updating
from a version that predates the changelog mechanism.

**`--news` and seen tracking**: Both the default `cco update` and `cco update --news`
update `last_seen_changelog` after reporting. Running `--news` immediately after
`cco update` shows the same entries with full details (examples, docs links)
but does not re-show the summary on the next `cco update`.

**Maintainer workflow**: Append entry with incremented `id` when adding an
additive change. The entry is shown once to each user.

### 4.15 Migration Scopes

The migration runner supports four scopes:

```
migrations/
├── global/       # cco update (always)
├── project/      # cco update (per project)
├── pack/         # cco update (per pack with .cco-meta)
└── template/     # cco update (user templates with .cco-meta)
```

**Execution order in `cco update`:**
1. Global migrations — always (affect `user-config/global/`)
2. Pack migrations — always (iterate `user-config/packs/*/` with `.cco-meta`)
3. User template migrations — always (iterate `user-config/templates/*/` with `.cco-meta`)
4. Project migrations — per project in scope (controlled by `--project`/`--all`)
5. Additive notifications — always (from `changelog.yml`)
6. Discovery — per project in scope (opinionated files)

**Important**: Migration scope is absolute for global/pack/template — they always
run regardless of `--project` or `--all` flags, because these are shared resources.
Only project migrations and discovery are limited by scope flags.

**Pack `.cco-meta` initialization:**
- `cco pack create` and `cco pack install` create `.cco-meta` with
  `schema_version: 0` and manifest hashes
- Bootstrap migration for existing packs: a global migration iterates
  `user-config/packs/*/` and creates `.cco-meta` where missing

**Native templates** (`templates/project/*/`, `templates/pack/*/`):
Maintained by the maintainer directly in the repo. NOT migrated by `cco update`.
The maintainer:
1. Updates the native template files directly (commit to repo)
2. Creates a migration in `migrations/project/` for existing user projects
3. `cco update` runs the migration on existing projects automatically

### 4.16 Source Tracking (`.cco-source`)

Resources with an authoritative source track their origin:

```yaml
# .cco-source — auto-generated, do not edit
# Remote resource (pack or project installed from URL)
type: pack
source: https://github.com/team/config  # remote URL
path: packs/my-pack                     # subdirectory in source repo
ref: main                               # branch/tag/commit
installed: 2026-03-01                   # install date
updated: 2026-03-14                     # last update date
```

```yaml
# .cco-source — auto-generated, do not edit
# Local resource (pack created locally)
type: pack
source: local                           # string "local" — no remote
installed: 2026-03-01
```

```yaml
# .cco-source — auto-generated, do not edit
# Native template project (created from a cco-shipped template)
type: project
source: native:project/tutorial         # native template reference
installed: 2026-03-14
```

**Format notes**: The `source` field is a string (not a mapping). For remote
resources it is a URL, for local resources the literal string `"local"`, and
for native template resources the string `"native:<kind>/<name>"`. Additional
fields (`path`, `ref`, `updated`, `publish_target`) are present only for
remote resources.

**Created by:**
- `cco pack install` → remote URL (already implemented)
- `cco pack create` → `source: local` (already implemented)
- `cco project create --template <native>` → `native:project/<name>` (new)
- `cco project install <url>` → remote URL (new)

**Used by:**
- `cco update` → resolve update source for native template projects
- `cco update` → notify of remote updates for installed projects
- `cco pack update` → pull from remote source (already implemented)

### 4.17 Maintainer Rules for Migrations

When writing migrations, maintainers MUST follow these rules:

1. **If a migration renames/moves an opinionated file**: also update the
   corresponding entry in `.cco-base/` so future discovery works correctly
2. **If a migration changes project.yml structure**: update `templates/project/base/project.yml`
   AND all non-base native templates (tutorial, etc.)
3. **Post-migration warning**: if the change affects user templates, emit a
   warning so users know to review their `user-config/templates/`
4. **Idempotency**: every migration MUST be safe to run multiple times
5. **Sequential IDs**: check `migrations/{scope}/` for the current max before
   assigning an ID

### 4.18 Maintainer Change Checklist

When making changes to claude-orchestrator, classify the change and follow the
corresponding procedure. This checklist consolidates the rules from §4.14, §4.15,
and §4.17 into a single operational reference.

#### Step 1 — Classify the change

| Change Type | Definition | Examples |
|-------------|-----------|----------|
| **Additive** | New optional feature or config field; existing installations work without changes | New CLI subcommand, new optional `project.yml` field, new vault capability |
| **Opinionated** | Improvement to framework rules, agents, or skills | Better workflow rule, updated agent spec, new skill |
| **Breaking** | Structural change requiring transformation of existing files | Renamed config key, moved file, schema format change |

#### Step 2 — Execute the procedure

**Additive changes:**
1. Add code-level default so existing installations work without changes
2. Update `templates/project/base/` for new projects
3. Append entry to `changelog.yml` (repo root) with next sequential `id`:
   ```yaml
   - id: <next_id>
     date: "YYYY-MM-DD"
     type: additive
     title: "Short description"
     description: "Details about the new feature and how to use it"
   ```
4. Users are notified via `cco update` (summary) or `cco update --news` (details)

**Opinionated changes:**
1. Update the source file in `defaults/global/`
2. Users discover via `cco update --diff`, apply via `cco update --apply`
3. No migration needed — the discovery engine handles it automatically

**Breaking changes:**
1. Create migration in `migrations/{scope}/NNN_description.sh` (see §4.17)
2. Update base template AND all non-base native templates
3. If migration moves an opinionated file, also update `.cco-base/`
4. Test: `cco update --project <name>` — verify migration runs and is idempotent
5. If the change affects `project.yml` structure, update all template `project.yml` files

#### Step 3 — Verify

- [ ] Existing installations handle the change gracefully (additive: code defaults; breaking: migration)
- [ ] New installations get the right defaults (templates updated)
- [ ] `cco update` reports the change appropriately (changelog / discovery / migration)
- [ ] Idempotency: running `cco update` twice produces the same result

### 4.19 Vault Integration

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

**Scope behavior**: `--project <name>` limits cleanup to that project's directory
only. Global `.bak` files are NOT cleaned when `--project` is specified. Use
`cco clean` (no `--project`) to clean both global and all project directories.

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
    (no flags)              Migrations + discovery + additive notifications
    --diff                  Show detailed diffs for available updates
    --diff <file>           Show 3-way diff for a specific file
    --apply                 Interactive per-file merge/replace/keep/skip
    --apply <file>          Apply a specific file update
    --news                  Show full details of additive changes (examples, docs)

OPTIONS
    --project <name>        Scope to specific project (+ global)
    --all                   Scope to global + all projects (default if no --project)
    --no-backup             Disable .bak creation (combine with --apply)
    --dry-run               Show pending migrations without running + discovery

SOURCES
    Global config           defaults/global/
    Project (base)          templates/project/base/          (.claude/settings.json)
    Project (native tpl)    templates/project/<name>/        (template-specific files)
    Additive changes        changelog.yml                    (structured notifications)

MIGRATION SCOPES
    global                  Run on user-config/global/
    project                 Run on each project in scope
    pack                    Run on each pack with .cco-meta
    template                Run on each user template with .cco-meta

WHAT cco update DOES (automatically)
    Migrations              Run pending scripts from migrations/{scope}/
    Discovery               Compare framework sources against .cco-base/ for updates
    Notifications           Report new features from changelog.yml

WHAT cco update DOES NOT DO (automatically)
    File modifications      Never — requires explicit --apply (except migrations)
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

11. **Update source resolution** *(revised, 2026-03-14)*: Base projects use
    `templates/project/base/`. Native template projects (tutorial) use the
    template's own directory for template-specific files + base for shared
    files. Source resolved via `.cco-source`.

12. **`--sync-templates` removed** *(revised, 2026-03-14)*: User template
    propagation is NOT a flag on `cco update`. Deferred to future
    `cco template sync` command.

13. **`cco update` = migrations + discovery + notifications** *(revised, 2026-03-14)*:
    No automatic file modifications. Discovery is read-only. File changes
    require explicit `--apply`. Additive changes reported via `changelog.yml`.

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

18. **Additive change notifications** *(new, 2026-03-14)*: `cco update` reports
    new features from `changelog.yml`. Tracked via `last_seen_changelog` in
    `.cco-meta`. Users discover capabilities without reading docs proactively.

19. **Migration scopes extended** *(new, 2026-03-14)*: Four scopes: `global`,
    `project`, `pack`, `template`. Pack and user-template migrations run
    during `cco update`. Native templates maintained by maintainer directly.

20. **Source tracking for all origin-aware resources** *(new, 2026-03-14)*:
    `.cco-source` extended to native template projects and remote-installed
    projects. Enables update discovery and remote change notification.

21. **`cco project create` initializes `.cco-meta`/`.cco-base` immediately**
    *(fix, 2026-03-14)*: Not deferred to bootstrap migration. Created at
    project creation time alongside `.cco-source` for non-base templates.

22. **`--dry-run` shows pending migrations** *(clarification, 2026-03-14)*:
    `--dry-run` does NOT run migrations — it lists them as pending. Discovery
    runs normally. This lets users preview what `cco update` would do.

23. **Non-interactive fallback** *(clarification, 2026-03-14)*: When stdin is
    not a TTY, `--apply` defaults to (S)kip for all files. No silent changes
    in non-interactive environments.
