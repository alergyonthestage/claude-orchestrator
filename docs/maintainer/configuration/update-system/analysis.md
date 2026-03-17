# Update System — Architecture Analysis v2

**Date**: 2026-03-17 (Revised)
**Scope**: Architecture-level — cross-cutting analysis
**Related**: `design.md` (definitive design, updated in parallel)

> This document establishes the resource taxonomy, change categories, and update
> semantics for claude-orchestrator. It is the analytical foundation for the update
> system design and for all future decisions about resource lifecycle.

---

## 1. Why This Matters

The update system determines whether cco remains **usable over time**. An orchestrator
that cannot propagate improvements to existing installations becomes a one-shot
scaffolding tool — users create projects, then drift from the framework.

The value proposition of cco depends on:

- **Easy maintenance**: maintainers update the framework, users discover improvements
- **Predictable behavior**: every resource has a clear owner and a defined lifecycle
- **User confidence**: `cco update` is safe, instant, and never modifies files
  without explicit user consent
- **User autonomy**: the framework suggests best practices but never forces them

---

## 2. Resource Taxonomy — Four Scopes

### 2.1 Scope Definitions

| Scope | Location | Ownership | Installed by | Updated by |
|-------|----------|-----------|-------------|------------|
| **Managed** | `defaults/managed/` → `/etc/claude-code/` | Framework (immutable) | `cco build` | `cco build` |
| **Global** | `defaults/global/` → `user-config/global/` | User (after install) | `cco init` | User (assisted by `cco update --sync`) |
| **Project** | `templates/project/*/` → `user-config/projects/<name>/` | User (after install) | `cco project create` | User (assisted by `cco update --sync`) |
| **Pack** | `user-config/packs/<name>/` | User or Remote | `cco pack create/install` | `cco pack update` (full replace) |

**Key change from earlier designs**: Global and Project files are **user-owned after
installation**. The framework provides defaults at creation time and offers discovery
and merge tools for updates, but never modifies user files automatically.

### 2.2 What Lives Where

```
Managed (immutable, Docker-baked)
├── Framework CLAUDE.md               — non-overridable instructions
├── managed-settings.json             — hooks, env, deny rules
└── init-workspace skill              — runtime CLAUDE.md population

Global (installed at cco init, user-owned after)
├── .claude/CLAUDE.md                 — workflow instructions (opinionated)
├── .claude/settings.json             — global Claude Code permissions (opinionated)
├── .claude/agents/{analyst,reviewer}  — framework agent specs (opinionated)
├── .claude/rules/{workflow,git,diagrams} — framework conventions (opinionated)
├── .claude/rules/language.md          — generated from saved preferences
├── .claude/skills/{analyze,commit,design,review} — framework skills (opinionated)
├── .claude/mcp.json                  — personal MCP servers
├── setup.sh                          — dotfiles bootstrap
└── setup-build.sh                    — build dependencies

Project (installed at cco project create, user-owned after)
├── project.yml                       — project configuration (user config)
├── .claude/CLAUDE.md                 — project context (user content)
├── .claude/settings.json             — project permissions (opinionated)
├── .claude/rules/language.md         — optional language override
├── setup.sh                          — runtime setup
├── secrets.env                       — secret variables
└── mcp-packages.txt                  — optional MCP packages

Pack (independent lifecycle)
├── pack.yml                          — pack manifest
├── knowledge/                        — knowledge files (read-only in projects)
├── rules/ agents/ skills/            — pack resources
```

---

## 3. Three Categories of Framework Changes

Every framework change falls into exactly one category. The category determines
the update mechanism.

### 3.1 Additive Changes (backward-compatible)

**What**: New optional fields, new config sections, new directories, new features.
**Constraint**: Must be backward-compatible. Existing configs without the new field
must continue to work with sensible defaults.
**User action**: None required. User adds new fields when needed, reading documentation.
**Update mechanism**: None — `cco update` does not act on these.

**Examples**:
- New `browser:` section in project.yml → code defaults to `enabled: false`
- New `github:` section in project.yml → code defaults to `enabled: false`
- New `docker.containers:` policy → code defaults to `project_only`

**Design rule**: Every new config field MUST have a default value in the code that
preserves the pre-existing behavior. The user should never be forced to update
their config to maintain current functionality.

**Notification**: Although additive changes require no action, users benefit from
knowing they exist. `cco update` reports additive changes from a structured
changelog so users discover new capabilities without reading docs proactively.
See section 8.7 for the notification mechanism.

### 3.2 Opinionated Changes (suggestions)

**What**: Improvements to framework-provided rules, agent specs, skills, CLAUDE.md
workflow instructions — the methodology files that cco installs at init.
**Constraint**: Never forced on the user. Discovery + on-demand merge only.
**User action**: Review when interested, apply selectively.
**Update mechanism**: `cco update` discovers and reports; `cco update --sync` merges.

**Examples**:
- Improved `workflow.md` with better phase descriptions
- Updated `analyst.md` agent spec with new capabilities
- New section in global `CLAUDE.md` about error handling practices
- Bug fix in `commit/SKILL.md`

**Design rule**: These files are installed at `cco init` as the framework's
recommended starting point. After installation they belong to the user. The
framework can suggest updates, but the user decides.

### 3.3 Breaking Changes (mandatory)

**What**: Structural changes, schema incompatibilities, file renames, directory
reorganizations, bug fixes that require explicit data transformation.
**Constraint**: Must be handled automatically — the user should not need to
perform manual steps for the system to keep working.
**User action**: None — migrations run automatically.
**Update mechanism**: `cco update` runs pending migrations from `migrations/`.

**Examples**:
- `memory/` → `claude-state/` directory rename
- `setup.sh` split into `setup.sh` + `setup-build.sh`
- `.cco/base/` bootstrap for pre-Sprint-5b installations
- Schema version bumps in `.cco/meta`

**Design rule**: Migrations are idempotent, sequential, and explicit. Each migration
is a script in `migrations/{scope}/NNN_description.sh` with a `migrate()` function.
The migration runner tracks `schema_version` in `.cco/meta`.

**Scopes**: The migration runner supports four scopes: `global`, `project`, `pack`,
and `template`. All scopes use the same runner function (`_run_migrations`) and the
same convention. `cco update` runs global and project migrations automatically.
Pack and user-template migrations run during `cco pack update` and `cco update`
respectively. See section 8.8 for details.

### 3.4 Category Decision Guide

```
Is this change backward-compatible?
├── YES: Does old config work without modification?
│   ├── YES → ADDITIVE. Add default in code. Document the new field.
│   └── NO → BREAKING. Write a migration.
└── NO: Does something break without user action?
    ├── YES → BREAKING. Write a migration.
    └── NO: Is it a content improvement to an opinionated file?
        ├── YES → OPINIONATED. Update defaults/. cco update discovers it.
        └── NO → ADDITIVE. Document it.
```

---

## 4. File Lifecycle — Creation to Update

### 4.1 Global Files

```
cco init
  ├── Copy defaults/global/ → user-config/global/
  ├── Substitute language.md with user's language choices
  ├── Generate .cco/meta (schema_version, manifest hashes)
  └── Save .cco/base/ (base versions for future diff/merge)

User works...
  ├── Modifies rules, agents, skills as needed
  ├── Adds custom MCP servers, setup scripts
  └── Files are fully user-owned

cco update (after framework upgrade)
  ├── Run pending migrations (BREAKING changes)
  ├── Compare defaults/ vs .cco/base/ → find what framework changed
  ├── Compare user files vs .cco/base/ → find what user changed
  ├── Report: "N files have updates available"
  └── NO automatic file modifications

cco update --sync (user-initiated)
  ├── For each file with updates:
  │   ├── User unchanged + framework changed → offer: apply / skip
  │   ├── Both changed → offer: 3-way merge / .bak+replace / keep / skip
  │   └── User changed + framework unchanged → skip (no update available)
  └── User chooses per file
```

### 4.2 Project Files

```
cco project create <name> [--template config-editor]
  ├── Copy template files → user-config/projects/<name>/
  ├── Substitute {{PROJECT_NAME}}, {{DESCRIPTION}}
  ├── Generate .cco/meta (template name, schema_version)
  └── Save .cco/base/ (base versions of opinionated files)

User works...
  ├── Configures project.yml (repos, packs, docker, etc.)
  ├── Writes .claude/CLAUDE.md with project context
  └── Files are fully user-owned

cco update --project <name>
  ├── Run pending project migrations
  ├── Discover opinionated file updates (.claude/settings.json)
  └── Report available updates

cco update --sync <name>
  └── Merge/replace opinionated files on user request
```

### 4.3 Which Files Are Opinionated (discoverable)?

Only files that have a **framework source** in `defaults/` or `templates/project/base/`
AND are expected to evolve with the framework. All other files are purely user-owned.

**Global opinionated files** (source: `defaults/global/`):

| File | Why opinionated | Why not managed |
|------|-----------------|-----------------|
| `.claude/CLAUDE.md` | Framework workflow methodology | User adds project-wide instructions |
| `.claude/settings.json` | Framework permission baseline | User customizes permissions |
| `.claude/agents/analyst.md` | Framework agent spec | User tunes agent behavior |
| `.claude/agents/reviewer.md` | Framework agent spec | User tunes agent behavior |
| `.claude/rules/diagrams.md` | Framework diagram conventions | User may prefer different conventions |
| `.claude/rules/git-practices.md` | Framework git conventions | User may use different git workflow |
| `.claude/rules/workflow.md` | Framework dev workflow | User may prefer different phases |
| `.claude/skills/*/SKILL.md` | Framework skills | User may customize skill behavior |
| `.claude/rules/language.md` | Generated from preferences | Regenerated, not merged |

**Project opinionated files** (source: `templates/project/base/`):

| File | Why opinionated | Notes |
|------|-----------------|-------|
| `.claude/settings.json` | Framework permission baseline | Usually not customized; quick apply |

**Files NOT opinionated (purely user-owned)**:

| File | Why user-owned |
|------|----------------|
| `project.yml` | 100% user config (repos, packs, docker, ports, etc.) |
| `.claude/CLAUDE.md` (project) | Project-specific context, fully user-written |
| `.claude/mcp.json` | Personal MCP server config |
| `setup.sh`, `setup-build.sh` | Personal environment setup |
| `secrets.env` | Secret values |
| `mcp-packages.txt` | User's package list |

### 4.4 Why `project.yml` Is User-Owned (Not Tracked)

`project.yml` is modified by 100% of users — it contains repos, packs, docker
ports, auth config, etc. There is no meaningful "unchanged" state.

New config sections (browser, github, containers) are **additive** — the code
handles missing sections with sensible defaults. Users add fields when they need
the feature, reading the documentation.

Breaking schema changes (if ever needed) are handled by **migrations**, which
can surgically modify project.yml structure.

This approach requires:
1. Every new project.yml field has a code-level default
2. Schema documentation is kept up to date (`docs/reference/project-yaml.md`)
3. Breaking changes are rare and always have a migration

---

## 5. The Role of Templates

### 5.1 `templates/project/base/` — The Schema Reference

Despite living under `templates/`, base functions as the **canonical project schema**.
It defines:
- The project.yml structure (all available fields, comments, examples)
- The .claude/ directory structure (settings, rules, skills directories)
- The default files that every new project receives

**At creation time**: base is a template with `{{PLACEHOLDER}}` substitution.
**After creation**: the project is independent. base serves only as a reference
for `cco update` to compare opinionated files against.

### 5.2 Non-Base Native Templates

| Template | Location | Purpose | Relationship to base |
|----------|----------|---------|---------------------|
| `tutorial` | `internal/tutorial/` | Interactive cco learning | Internal resource, not a native template. Used directly at runtime, not installed in user-config |
| `config-editor` | `templates/project/config-editor/` | Config editor project | Independent; shares project.yml schema but has unique skills/rules/CLAUDE.md |
| `cco-develop` (future) | `templates/project/cco-develop/` | Framework maintainer template | Independent; pre-configured for cco self-development |

The tutorial was moved from `templates/project/tutorial/` to `internal/tutorial/`
because it is a framework-internal resource used directly at runtime, not a project
template that gets installed into user-config.

Non-base templates (like `config-editor`) are **completely independent** from base
— there is no inheritance mechanism. Each template is self-contained.

**Maintainer responsibility**: When base evolves (new project.yml fields, new
directory structure), the maintainer must update non-base templates to match.
The `cco update --diff` tool can assist with this — the maintainer can compare
a template's files against the updated base to identify needed changes.

### 5.3 User Templates

Users create templates via `cco template create my-preset --from projects/my-app`.
These live in `user-config/templates/` and are fully user-managed.

`cco update` never reads from or writes to user templates. If a user wants to
propagate their template changes to existing projects, they use the same
`cco update --diff` / `--sync` tool manually, pointing to the template as source.

### 5.4 Template Philosophy

Non-negotiable: native templates are limited to templates that serve the framework
itself (learning, development, onboarding). Technology/stack templates are the
user's domain, managed via packs and user templates.

---

## 6. Global Defaults: Opinionated but Not Forced

### 6.1 What Global Defaults Represent

The files in `defaults/global/` represent cco's **opinionated methodology** —
a tested approach to AI-assisted development with structured workflow phases,
git practices, diagram conventions, and purpose-built agents and skills.

### 6.2 Why They Are in Global (Not Managed)

| Scope | Behavior | Right for methodology files? |
|-------|----------|------|
| **Managed** | Immutable, cannot be overridden | ❌ Too rigid — users must be able to customize |
| **Global** | Installed once, user-owned after | ✅ Suggestive — framework proposes, user disposes |

### 6.3 The Update Model for Opinionated Files

The framework's relationship with opinionated files follows this pattern:

1. **Install**: `cco init` copies framework defaults as the starting point
2. **Evolve**: User modifies files to match their preferences and workflow
3. **Discover**: `cco update` reports when the framework has improvements available
4. **Choose**: User reviews changes and decides what to integrate

The framework never modifies these files automatically. Even when the user hasn't
changed a file (SAFE_UPDATE scenario), the update is presented as a choice, not
an action. This is because:

- Users may prefer the version they have, even if unchanged
- Silent updates change behavior the user is accustomed to
- The user should always know exactly what `cco update` did (answer: migrations only)

### 6.4 Alternative Considered: Automatic SAFE_UPDATE

We considered automatically applying updates when the user hasn't modified a file
(SAFE_UPDATE). Arguments for:
- Bug fixes in agent specs or skills would be applied immediately
- Users who don't customize get improvements without thinking

Arguments against (decisive):
- User doesn't expect `cco update` to silently change rules/skills they rely on
- "Hasn't modified" doesn't mean "doesn't care" — the user may rely on current behavior
- Creates fear of running `cco update` ("what did it change this time?")
- Bug fixes that require immediate propagation should use **migrations** instead

**Decision**: No automatic file updates. Migrations for critical fixes, discovery
for improvements.

---

## 7. Shared Resources — Source Tracking and Update Policies

### 7.1 Resource Lifecycle by Source

| Resource | Created by | Updated by | `cco update` role |
|----------|-----------|------------|-------------------|
| Global config | `cco init` | User + `cco update --sync` | Migrations + discovery + additive notifications |
| Project (from base) | `cco project create` | User + `cco update --sync` | Migrations + discovery |
| Project (from native template) | `cco project create --template` | User + `cco update --sync` | Migrations + discovery (template-specific files) |
| Project (from remote) | `cco project install` | User | Migrations only (notify of remote updates) |
| Pack (local) | `cco pack create` | User directly | Migrations only |
| Pack (remote) | `cco pack install` | `cco pack update` (full replace) | Migrations only |
| Template (native) | Ships with cco | Maintainer (in repo) | N/A (maintainer runs migrations manually) |
| Template (user) | `cco template create` | User directly | Migrations only |

### 7.2 Source Tracking via `.cco/source`

Every resource with an authoritative source tracks its origin in `.cco/source`.
This file enables update discovery, version comparison, and source attribution.

```yaml
# .cco/source — auto-generated, do not edit
# Format: source is a string (URL, "local", or "native:<kind>/<name>")
type: pack                              # pack | project
source: https://github.com/team/config  # URL, "local", or "native:project/<name>"
path: packs/my-pack                     # subdirectory in source (remote only)
ref: main                               # branch/tag/commit (remote only)
installed: 2026-03-01                   # install date
updated: 2026-03-14                     # last update date (remote only)
```

The `source` field is a flat string: a URL for remote resources, `"local"` for
locally created resources, or `"native:<kind>/<name>"` for native template projects.
Additional fields (`path`, `ref`, `updated`) are present only for remote resources.

**Who creates `.cco/source`:**

| Resource | Created by | Source value |
|----------|-----------|-------------|
| Pack (remote) | `cco pack install` | Remote URL ✅ (already implemented) |
| Pack (local) | `cco pack create` | `source: local` ✅ (already implemented) |
| Project (from native template) | `cco project create --template` | `native:project/<template-name>` |
| Project (from remote) | `cco project install` | Remote URL |
| Project (from base) | `cco project create` | Not created (base is the default, tracked via `.cco/meta`) |

### 7.3 Update Policies by Resource Type

Each resource type has a defined update policy based on how users interact with it:

| Resource | Update policy | Rationale |
|----------|--------------|-----------|
| Pack (remote) | **Full replace** | Source is authoritative. Users who need to modify should `cco pack internalize` first |
| Pack (local) | **User-managed** | No external source. User edits directly |
| Project (from native template) | **Discovery + merge** | Template-specific opinionated files discovered; user chooses per file via `--sync` |
| Project (from remote) | **Notify only** | Remote may have updates; user informed but must act manually |
| Project (from base) | **Discovery + merge** | Only base opinionated files (settings.json) — see section 4.3 |

### 7.4 Native Template Projects — Discovery of Template-Specific Files

Projects created from non-base native templates (e.g., tutorial) have opinionated
files that come from the template, not from base. These files should be discoverable
when the maintainer updates the template.

**Mechanism:**

At `cco project create --template tutorial`:
1. Copy template files to `user-config/projects/<name>/`
2. Create `.cco/source` with `source: native:project/tutorial`
3. Create `.cco/meta` with `template: tutorial` and schema_version
4. Save `.cco/base/` with base versions of template-specific opinionated files

At `cco update --project <name>`:
1. Read `.cco/source` → determine source is `native:project/tutorial`
2. Run pending project migrations (from `migrations/project/`)
3. Discover opinionated file updates:
   - Base files (settings.json) → compared against `templates/project/base/`
   - Template-specific files (tutorial skills, rules) → compared against `internal/tutorial/`
4. Report available updates

**Which tutorial files are opinionated (discoverable)?**

| File | Policy | Rationale |
|------|--------|-----------|
| `.claude/skills/tutorial/SKILL.md` | opinionated | Framework tutorial skill — evolves with cco |
| `.claude/skills/setup-project/SKILL.md` | opinionated | Framework helper skill |
| `.claude/skills/setup-pack/SKILL.md` | opinionated | Framework helper skill |
| `.claude/rules/tutorial-behavior.md` | opinionated | Framework behavior rules |
| `.claude/settings.json` | opinionated | From base (shared) |
| `.claude/CLAUDE.md` | untracked | User writes project context |
| `project.yml` | untracked | User configures repos, packs, docker |

### 7.5 Pack Update — Full Replace with Internalization Escape

`cco pack update` is a separate system:
- Full-replace from remote source (no merge — source is authoritative)
- Tracked via `.cco/source` (URL, path, ref, timestamps)
- Affects all projects using the pack (packs are shared, mounted read-only)
- `cco update` runs pending pack migrations but does NOT trigger pack updates

**If a user has modified a remote pack:**
The user should `cco pack internalize <name>` before updating. This converts the
pack to local (removes `.cco/source`), making it fully user-owned. The pack will
no longer receive remote updates. This is the intended escape hatch — the user
explicitly chooses between "receive updates" and "customize freely".

### 7.6 Remote-Installed Projects — Notify Only

Projects installed via `cco project install <url>` are heavily customized by users
(repos, docker, packs, etc.). The remote source is a starting point, not a
continuous source of truth.

`cco update` can check if the remote has newer commits than `installed_hash` in
`.cco/source` and notify:

```
Project 'my-app' (installed from github.com/team/config):
  ℹ Remote has updates since your install (2026-03-01).
  Review with: cco project install <url> --diff
```

No automatic merge or replace. The user manually reviews and decides.

### 7.7 Future: Pack Version Pinning

Currently `cco pack update` pulls HEAD of the stored ref. No version pinning or
lockfile exists. Acceptable for now; future enhancement could add version fields
in `pack.yml` and `.cco/source`.

---

## 8. `cco update` — Complete Behavior

### 8.1 Default: Migrations + Discovery

```
$ cco update

Running migrations...
  ✓ Migration 008: add template metadata to .cco/meta

Checking for updates...

Global config (defaults/global/):
  ↑ rules/workflow.md — framework has updates (you haven't modified)
  ↑ skills/analyze/SKILL.md — framework has updates (you haven't modified)
  ↑ CLAUDE.md — framework has updates (you also modified)
  ≡ agents/analyst.md — no framework changes

  3 updates available. Run 'cco update --diff' for details.
  Apply with 'cco update --sync'.

Project 'my-app':
  ≡ .claude/settings.json — no changes
  No updates available.
```

No files modified. No prompts. Instant.

### 8.2 Diff: See What Changed

```
$ cco update --diff

Global: rules/workflow.md
  Status: framework updated, you haven't modified
  Framework changes:
    + Added "## Error Handling" section (lines 45-60)
    + Updated "## Implementation Phase" with testing guidance

Global: CLAUDE.md
  Status: both you and framework modified
  Your changes: custom instructions in "## Communication Style"
  Framework changes: new "## Security Practices" section

  Run 'cco update --diff CLAUDE.md' for full 3-way diff.
```

### 8.3 Sync: On-Demand Merge

```
$ cco update --sync

Global: rules/workflow.md (framework updated, you haven't modified)
  (A)pply update  (S)kip  (D)iff → A
  ✓ Applied. Backup: rules/workflow.md.bak

Global: skills/analyze/SKILL.md (framework updated, you haven't modified)
  (A)pply update  (S)kip  (D)iff → A
  ✓ Applied.

Global: CLAUDE.md (both modified — merge needed)
  (M)erge 3-way  (R)eplace + .bak  (K)eep yours  (S)kip  (D)iff → M
  Auto-merged (no conflicts).
  ✓ Applied. Backup: CLAUDE.md.bak

3 files updated.
```

### 8.4 Sync Specific File

```
$ cco update --sync rules/workflow.md
  ✓ Applied rules/workflow.md. Backup: rules/workflow.md.bak
```

### 8.5 The `.cco/base/` and `.cco/meta` Role

These internal files are essential for the discovery and merge tools:

- **`.cco/base/`**: Stores the framework version of each opinionated file at the
  time of last install or apply. This is the "ancestor" for 3-way merge and the
  baseline for diff comparison.
- **`.cco/meta`**: Stores schema version (for migrations), template name
  (informational), language preferences (for language.md generation), and
  manifest hashes (for change detection).

Both are auto-generated. Users never edit them. They survive `cco update` and
are only modified by `cco init`, `cco project create`, and `cco update --sync`.

### 8.6 Utility for Maintainers and Users Alike

The `--diff` and `--sync` tools are not limited to global/project updates.
The same 3-way merge engine can be used by:

- **Maintainers**: Compare base template changes against non-base templates
  to propagate schema improvements (e.g., update tutorial's project.yml after
  base project.yml evolves)
- **Users**: Compare their own templates against updated base to keep
  `user-config/templates/` current
- **Teams**: Share config improvements across team members' installations

The merge engine is a **general-purpose tool**, not a single-purpose update mechanism.

### 8.7 Additive Change Notifications

`cco update` reports all three change categories — not just opinionated and breaking.
Additive changes (new features, new config fields) are reported so users discover
capabilities without reading docs proactively.

**Mechanism**: A structured changelog file `changelog.yml` in the cco repo:

```yaml
# changelog.yml — structured list of user-visible changes
- id: 12
  type: additive
  date: 2026-03-14
  summary: "New 'rag:' section in project.yml for semantic search"
  docs: "docs/reference/project-yaml.md#rag"
  example: |
    rag:
      enabled: true
      provider: local-rag

- id: 11
  type: additive
  date: 2026-03-10
  summary: "New 'docker.containers:' policy in project.yml"
  docs: "docs/reference/project-yaml.md#docker-containers"
```

**Tracking**: `.cco/meta` stores `last_seen_changelog: <id>` and
`last_read_changelog: <id>`. `cco update` compares against the latest entry and
reports unseen changes. Discovery updates `last_seen_changelog` only;
`cco update --news` updates both:

```
$ cco update

Running migrations...
  (none pending)

What's new in cco:
  + project.yml: new 'rag:' section (semantic search over project files)
  + project.yml: new 'docker.containers:' policy field
  Run 'cco update --news' for details and examples.

Checking for updates...
  ↑ rules/workflow.md — framework has updates
  1 update available. Run 'cco update --diff' for details.
```

**Maintainer workflow**: When adding an additive change, append an entry to
`changelog.yml` with an incremented `id`. The entry is shown once to each user.

### 8.8 Migration Scopes

The migration runner (`_run_migrations`) supports four scopes with a uniform
convention:

```
migrations/
├── global/         # Run by: cco update (always)
│   └── NNN_description.sh
├── project/        # Run by: cco update (per project)
│   └── NNN_description.sh
├── pack/           # Run by: cco update (per pack) + cco pack update
│   └── NNN_description.sh
└── template/       # Run by: cco update (user templates only)
    └── NNN_description.sh
```

**When each scope runs:**

| Scope | Trigger | Target directory | `.cco/meta` location |
|-------|---------|-----------------|---------------------|
| `global` | `cco update` | `user-config/global/.claude/` | `user-config/global/.claude/.cco/meta` |
| `project` | `cco update` (per project) | `user-config/projects/<name>/` | `user-config/projects/<name>/.cco/meta` |
| `pack` | `cco update` (per pack) | `user-config/packs/<name>/` | `user-config/packs/<name>/.cco/meta` |
| `template` | `cco update` (user templates) | `user-config/templates/<name>/` | `user-config/templates/<name>/.cco/meta` |

**Native templates** (`templates/project/*/`, `templates/pack/*/`):
These are part of the cco repo and updated by the maintainer directly. They do
NOT run through `_run_migrations`. The maintainer's workflow is:

1. Create a migration in `migrations/project/` for existing user projects
2. Update the native template files directly (commit to repo)
3. New projects created after the update receive the new structure automatically
4. `cco update` runs the migration on existing projects

**Important rule for maintainers**: If a migration renames or moves an opinionated
file, it MUST also update the corresponding entry in `.cco/base/` so that future
discovery works correctly.

**Pack `.cco/meta` initialization**: Packs currently lack `.cco/meta`. A bootstrap
migration (or `cco pack create`/`cco pack install` update) adds it. The `.cco/meta`
for packs omits the `languages:` section (not relevant) and contains only
`schema_version` and `manifest`.

**User template `.cco/meta`**: Same as packs — added by `cco template create` or
bootstrap migration. Contains `schema_version` only. User templates rarely need
migrations, but the mechanism is available.

**Post-migration warning for user templates**: When a migration changes project
structure, `cco update` warns if user templates may need updating:

```
⚠ Migration 009 changed project.yml structure.
  Your user template 'my-preset' may need manual review.
  Run 'cco template show my-preset' to inspect.
```

---

## 9. `cco clean` — Cleanup Command

### 9.1 Categories

| Flag | Target | Location |
|------|--------|----------|
| (default) | `*.bak` files | global + all project dirs |
| `--tmp` | `.tmp/` directories | `user-config/projects/<name>/.tmp/` (dry-run artifacts) |
| `--generated` | `.cco/docker-compose.yml` | `user-config/projects/<name>/` (regenerated by `cco start`) |
| `--all` | All of the above | Combined |

`.cco/base/` is NEVER cleaned — it is the merge ancestor and must be preserved.

### 9.2 Scoping

```bash
cco clean                          # .bak files (global + all projects)
cco clean --tmp                    # .tmp/ dirs (all projects)
cco clean --generated              # .cco/docker-compose.yml (all projects)
cco clean --all                    # everything
cco clean --project <name>         # scope to one project
cco clean --dry-run                # preview any combination
```

---

## 10. Decisions — Non-Negotiable

### D1: `cco update` = migrations + discovery

`cco update` runs pending migrations (automatic) and reports available file updates
(discovery). It NEVER modifies user files automatically.

### D2: All installed files are user-owned

After `cco init` or `cco project create`, all files belong to the user. The
framework provides defaults at creation time and offers tools to merge improvements,
but never forces changes.

### D3: Three categories of changes

Every framework change is classified as **additive** (backward-compatible, no
action), **opinionated** (discovery + on-demand merge), or **breaking** (automatic
migration). No other category exists.

### D4: Additive changes require code-level defaults

New config fields MUST have defaults in the code. Users should never be forced to
update their config files to maintain existing functionality.

### D5: Opinionated updates are opt-in

The `cco update --sync` tool offers merge/replace/keep/skip per file. The user
explicitly chooses. No silent updates, even for unmodified files.

### D6: Breaking changes use explicit migrations

Structural changes, schema incompatibilities, and critical bug fixes that require
data transformation are handled by idempotent migration scripts.

### D7: `project.yml` is user-owned

`project.yml` is 100% user config. New optional fields are additive (code defaults).
Schema-breaking changes use migrations. No tracking or merge.

### D8: Packs have their own update path

`cco pack update` is independent. Full-replace from source. Users who customize
packs should `cco pack internalize` first. `cco update` runs pack migrations only.

### D9: Native templates are minimal

Only templates serving the framework itself (learning, development). Technology/stack
templates are the user's domain via packs and user templates.

### D10: Managed scope is immutable

Changes require `cco build`. No runtime update mechanism.

### D11: The merge tool is general-purpose

`--diff` and `--sync` can compare any source against any target. Useful for
maintainers (template propagation), users (template updates), and teams (config sharing).

### D12: Additive changes are notified

`cco update` reports new features and config fields from `changelog.yml` so users
discover capabilities without reading docs proactively. Notification only — no
action required.

### D13: All resources with a source track it in `.cco/source`

Remote packs, native template projects, and remote-installed projects track their
origin. This enables update discovery, version comparison, and source attribution.

### D14: Native template project files are discoverable

Projects from native templates (tutorial, cco-develop) discover template-specific
opinionated file updates, not just base files. The source template path is recorded
in `.cco/source` and `.cco/base/` stores template-specific base versions.

### D15: Migrations run on all scopes

The migration runner supports `global`, `project`, `pack`, and `template` scopes.
`cco update` runs migrations on all applicable scopes automatically. Native
templates are maintained by the maintainer directly (not migrated by `cco update`).

### D16: `cco project create` initializes `.cco/meta` and `.cco/base` immediately

Not deferred to a bootstrap migration. Both files are created at project creation
time, alongside `.cco/source` for non-base template projects.

---

## 11. Alternatives Evaluated

### A1: Automatic 3-way merge (rejected)

The Sprint 5b implementation used automatic SAFE_UPDATE (overwrite if user hasn't
modified) and interactive merge for BOTH_CHANGED files. This was rejected because:

- Users don't expect `cco update` to silently change files they rely on
- "Hasn't modified" ≠ "doesn't care about current behavior"
- Interactive prompts during update make the command feel threatening
- Bug fixes needing immediate propagation should be migrations, not file updates

### A2: Tracking project.yml with 3-way merge (rejected)

project.yml was proposed as `tracked` with template variable substitution for the
"new" version. This was rejected because:

- 100% of project.yml files are modified by users (repos, docker, packs, etc.)
- YAML 3-way merge is fragile — reordered sections, reformatted values, removed
  comments all cause false conflicts
- New project.yml fields are additive (code defaults) — no merge needed
- Schema-breaking changes are rare and better handled by explicit migrations

### A3: Template inheritance / cascade updates (rejected)

A propagation chain `defaults/ → templates/ → user-config/` was considered, where
updating base would cascade to tutorial and user templates. Rejected because:

- Adds a layer of indirection that makes the system less predictable
- Native templates are few (2-3) — maintainer updates them manually
- User templates are user-owned and should never be auto-modified
- Complexity doesn't justify the benefit

### A4: `--sync-templates` flag on cco update (rejected)

A flag to propagate user template changes to projects was proposed, then replaced
by a future `cco template sync` command. Rejected as a flag because:

- Conflates framework updates with user template propagation
- Different trust levels (framework vs user-authored content)
- A dedicated command gives clearer semantics

### A5: Structured database for config (deferred indefinitely)

Storing config in a structured format (instead of YAML/MD files) was discussed.
This would enable semantic merge instead of text-based merge. Deferred because:

- Loses the human-readable, git-diffable file format that is core to cco
- Requires a UI for editing (cco is a CLI tool, files are edited in any editor)
- The simplified update model (migrations + discovery) doesn't need semantic merge
- Would require a complete architectural rewrite

---

## 12. Open Questions (Deferred)

### Q1: ~~Template update notifications~~ → RESOLVED (D14)

Projects from native templates now discover template-specific opinionated file
updates via `.cco/source` + `.cco/base/`. See section 7.4.

### Q2: Pack version pinning

Should packs support version/commit pinning for reproducibility? Deferred.

### Q3: `cco template sync` command

Future command to propagate user template changes to projects using the same
diff/merge engine. Deferred — requires template-to-project file mapping design.

### Q4: ~~Project install source tracking~~ → RESOLVED (D13)

`cco project install <url>` now saves `.cco/source` with the remote URL.
`cco update` can notify when the remote has newer commits. See section 7.6.

### Q5: `cco update --news` detail command

Should `cco update --news` show full details of additive changes (examples,
docs links), or just summaries? UX decision deferred to implementation.

### Q6: Pack migration scope bootstrap

How to bootstrap `.cco/meta` for existing packs that predate migration support?
A global migration can iterate `user-config/packs/*/` and create `.cco/meta`
files with `schema_version: 0`.
