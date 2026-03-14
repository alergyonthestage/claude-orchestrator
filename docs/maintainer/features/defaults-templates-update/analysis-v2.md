# Update System — Architecture Analysis v2

**Date**: 2026-03-14
**Scope**: Architecture-level — cross-cutting analysis
**Supersedes**: `analysis.md` (Sprint 5b pre-implementation analysis)
**Related**: `design.md` (definitive design, updated in parallel)

> This document establishes the resource taxonomy, propagation model, and update
> semantics for claude-orchestrator. It is the analytical foundation for the update
> system design and for all future decisions about resource lifecycle.

---

## 1. Why This Matters

The update system determines whether cco remains **usable over time**. An orchestrator
that cannot propagate improvements to existing installations becomes a one-shot
scaffolding tool — users create projects, then drift from the framework. The value
proposition of cco depends on:

- **Easy maintenance**: maintainers update the framework, users receive improvements
- **Predictable propagation**: every resource has a clear owner and a defined update path
- **User confidence**: `cco update` is helpful, not scary — it never destroys work

The analysis below classifies every resource by ownership, lifecycle, and update
semantics, then maps out the propagation paths for each type of change.

---

## 2. Resource Taxonomy — Four Scopes

claude-orchestrator manages resources across four distinct scopes. Each scope has
different ownership semantics and update paths.

### 2.1 Scope Definitions

| Scope | Location | Ownership | Update trigger | Update mechanism |
|-------|----------|-----------|----------------|------------------|
| **Managed** | `defaults/managed/` → `/etc/claude-code/` | Framework (immutable) | `cco build` | Docker image rebuild |
| **Global** | `defaults/global/` → `user-config/global/` | Framework → User | `cco update` | 3-way merge |
| **Project** | `templates/project/base/` → `user-config/projects/<name>/` | Framework schema + User content | `cco update --project` | 3-way merge (schema files only) |
| **Pack** | `user-config/packs/<name>/` | User or Remote source | `cco pack update` | Full replace from source |

### 2.2 What Lives Where

```
Managed (immutable, Docker-baked)
├── Framework CLAUDE.md               — non-overridable instructions
├── managed-settings.json             — hooks, env, deny rules
└── init-workspace skill              — runtime CLAUDE.md population

Global (framework-tracked, user-customizable)
├── .claude/CLAUDE.md                 — workflow instructions
├── .claude/settings.json             — global Claude Code permissions
├── .claude/agents/{analyst,reviewer}  — framework agent specs
├── .claude/rules/{workflow,git,diagrams} — framework conventions
├── .claude/rules/language.md          — generated from saved preferences
├── .claude/skills/{analyze,commit,design,review} — framework skills
├── .claude/mcp.json                  — user-owned (personal MCP servers)
├── setup.sh                          — user-owned (dotfiles)
└── setup-build.sh                    — user-owned (build deps)

Project (per-project, mixed ownership)
├── .claude/settings.json             — tracked (framework permissions)
├── project.yml                       — tracked (framework schema + user content)
├── .claude/CLAUDE.md                 — user-owned (project context)
├── .claude/rules/language.md         — copy-if-missing (optional override)
├── setup.sh                          — copy-if-missing
├── secrets.env                       — copy-if-missing
└── mcp-packages.txt                  — copy-if-missing

Pack (independent lifecycle)
├── pack.yml                          — pack manifest
├── knowledge/                        — knowledge files (read-only in projects)
├── rules/                            — pack rules
├── agents/                           — pack agents
└── skills/                           — pack skills
```

---

## 3. The Role of `templates/project/base/`

### 3.1 Key Insight: Base Is Not a Template

Despite living under `templates/`, the base project template functions as
**project defaults** — it is the canonical schema reference for all projects.

| Aspect | Template behavior | Defaults behavior |
|--------|-------------------|-------------------|
| Used at creation | ✅ scaffold new projects | ✅ (also what templates do) |
| Used at update | ❌ templates are forgotten | ✅ **base IS the update source** |
| One-to-many | ✅ 1 template → N projects | ✅ 1 defaults → N projects |
| Framework-maintained | ✅ | ✅ |

`_update_project()` always resolves to `templates/project/base/` as its source,
regardless of which template was used to create the project. This means:

- **base** defines the project schema (project.yml structure, settings.json)
- **All projects** receive base schema updates via `cco update`
- **Template-specific files** (tutorial skills, user template custom rules) are
  not present in base and therefore not touched by update

### 3.2 Why Not Move Base to `defaults/project/`?

We considered creating `defaults/project/` to make this role explicit. We decided
against it because:

1. **Template substitution**: base contains `{{PROJECT_NAME}}` etc. — it IS a template
   at creation time, and the substitution machinery lives in the template system
2. **Consistency**: `templates/project/` is the single location for all project
   scaffolds; splitting would create confusion about where to add new templates
3. **The naming is fine**: the distinction is documented here and in design.md;
   the code behavior is clear

### 3.3 Consequence for Non-Base Templates

Native templates like `tutorial` and future templates like `cco-develop` are
**specializations** — they add domain-specific content on top of the base schema.

When the base schema evolves (e.g., new `browser:` section in project.yml):
- Projects created from **any** template receive the update (source: base)
- The tutorial template itself must be updated **by the maintainer** to include
  the new section — this is a framework maintenance task, not an update system concern

When a non-base template is improved (e.g., better tutorial skills):
- Existing projects created from that template do **NOT** automatically receive
  the improvement
- This is intentional: template-specific content is specialized; forcing updates
  would break user customizations
- `cco update` may **notify** the user that template updates are available (future)

---

## 4. Update Propagation — Case-by-Case Analysis

### Case 1A: Managed scope changes

**Trigger**: Maintainer updates `defaults/managed/`
**Propagation**: `cco build` rebuilds the Docker image; changes active at next `cco start`
**User action**: None — managed files are immutable and non-overridable
**Update system involvement**: None

### Case 1B: Global defaults changes

**Trigger**: Maintainer updates `defaults/global/.claude/`
**Propagation**: `cco update` performs 3-way merge on all tracked files
**User experience**:
- **Most files**: SAFE_UPDATE (user hasn't modified) → silent auto-apply
- **User-customized files**: 3-way merge attempts auto-resolution; prompts only
  on true conflicts (both sides changed the same lines)
- **User-owned files** (mcp.json, setup.sh): never touched

**Merge prompt frequency**: Low. Of 13 tracked global files, users typically
customize 1-3 (CLAUDE.md, maybe a rule or two). The rest pass through silently.
This keeps `cco update` fast and non-threatening.

### Case 1C: Project base template changes

**Trigger**: Maintainer updates `templates/project/base/`
**Propagation**: `cco update --project <name>` or `cco update --all`
**Affected files**: Only the tracked subset:
- `project.yml` — 3-way merge preserves user repos/packs/config while adding
  new framework sections
- `.claude/settings.json` — typically unchanged by users, silent update

**Template var handling**: The "new" version for project.yml comparison is the
base template with `{{PROJECT_NAME}}` and `{{DESCRIPTION}}` substituted from
`.cco-meta` metadata. This follows the same pattern as `language.md` generation.

**What about non-base template projects?** They receive the same base schema
updates. The fact that a project was created from `tutorial` or a user template
does not affect which schema files are updated — base is always the source for
schema files.

### Case 1D: Non-base native template changes

**Trigger**: Maintainer updates `templates/project/tutorial/` or similar
**Propagation**: NOT automatic — `cco update` does not touch these
**Rationale**:
- Template-specific files (skills, specialized CLAUDE.md, custom rules) are not
  in the base template and therefore have no "new" version to compare against
- Forcing updates on specialized content would break user customizations
- These are improvements, not critical schema changes

**User notification** (future, not in current sprint):
```
ℹ Template 'tutorial' has updates available.
  Run 'cco template sync tutorial' to review changes for projects using this template.
```

**Important**: Non-base template updates are a **framework maintenance** task.
When the maintainer updates `templates/project/tutorial/`, they should also
verify that existing tutorial projects remain functional. This is documented
in the maintainer workflow, not automated by the update system.

### Case 1E: Structural changes (new files, splits, renames)

**Trigger**: Feature requires new framework files or structural changes
**Mechanism**: Migrations (`migrations/{global,project}/NNN_*.sh`)
**Examples from history**:
- `memory/` → `claude-state/` (migration 001 project)
- `setup.sh` split into `setup.sh` + `setup-build.sh` (migration 005 global)
- `.cco-base/` bootstrap for pre-Sprint-5b installs (migration 007 global)
- `.managed/` directory creation (migration 003 project)

**Coexistence with 3-way merge**:

| Change type | Mechanism | Example |
|-------------|-----------|---------|
| Content update to existing file | 3-way merge | Updated comments in project.yml |
| New optional section in tracked file | 3-way merge | Adding `browser:` to project.yml template |
| File renamed/moved | Migration | `memory/` → `claude-state/` |
| New file type to be tracked | Migration (create) + merge (ongoing) | Future new tracked file |
| Schema-breaking change | Migration | Renamed key in project.yml |
| Removed file | Migration | Deprecated config file cleanup |

### Case 1F: Project CLAUDE.md skeleton update

**Trigger**: Maintainer improves the CLAUDE.md scaffold in `templates/project/base/`
**Propagation**: NOT automatic — project CLAUDE.md is `user-owned`
**Rationale**:
- Project CLAUDE.md is the **most personalized file** in a project. It contains
  the user's project context, architecture notes, and instructions.
- The template skeleton is just a starting guide (`## Repositories`, etc.)
- Merging framework skeleton changes into a heavily-customized CLAUDE.md would
  produce noise, not value

**How users receive improvements**:
1. **init-workspace skill** (managed scope): This skill runs inside the container
   and populates CLAUDE.md with runtime-discovered information (repos, packs,
   workspace structure). When the skill is updated, it takes effect at the next
   `cco start` — no explicit action needed.
2. **Changelog**: Maintainer documents skeleton improvements; users can manually
   adopt new sections if desired.

**Global CLAUDE.md** is different: it IS tracked and receives framework workflow
updates via 3-way merge. This is correct because the global CLAUDE.md contains
framework methodology (workflow phases, communication style), not user content.

---

## 5. Native Templates: Scope and Philosophy

### 5.1 Current native templates

| Template | Purpose | Files beyond base |
|----------|---------|-------------------|
| `base` | Default project scaffold | None (IS the reference) |
| `tutorial` | Interactive cco learning | 3 skills, 1 rule, specialized CLAUDE.md |

### 5.2 Future native templates

| Candidate | Purpose | Rationale |
|-----------|---------|-----------|
| `cco-develop` | Maintainer/contributor template | Self-development of cco, pre-configured repos |

### 5.3 What native templates are NOT

Native templates are **NOT** technology-specific scaffolds (React, Go, Python, etc.).
Stack-specific configurations are handled by:

- **Packs**: Reusable knowledge bundles for domains/stacks (installable, updatable)
- **User templates**: Users create their own project templates from existing projects
  (`cco template create my-stack --from projects/my-go-app`)

This keeps the native template set **minimal and high-value** — only templates that
teach cco concepts or serve framework-internal purposes.

### 5.4 Decision: Minimal native templates

Non-negotiable: native templates are limited to templates that serve the framework
itself (learning, development, onboarding). Technology/stack templates are the
user's domain, managed via packs and user templates.

---

## 6. Global Defaults: Rules as Framework Value

### 6.1 Why defaults are in Global (not Managed)

The global defaults (`.claude/rules/`, `.claude/agents/`, `.claude/skills/`) represent
cco's **opinionated methodology** — a structured approach to development with
workflow phases, git practices, diagram conventions, etc.

They are in the **Global** scope (not Managed) because:

1. **Users must be able to customize them**: A team with different git practices
   should be able to modify `git-practices.md` without fighting the framework
2. **3-way merge preserves customizations**: When the framework improves a rule,
   the user's modifications are preserved through merge
3. **Managed would be too rigid**: Files in managed scope (`/etc/claude-code/`)
   cannot be overridden by the user at any level

### 6.2 What belongs in Global defaults

| Resource | Belongs in Global? | Rationale |
|----------|-------------------|-----------|
| Workflow rules (phases, approvals) | ✅ Yes | Core cco methodology |
| Git practices (branches, commits) | ✅ Yes | Common across all projects |
| Diagram conventions | ✅ Yes | Consistent output format |
| Language preferences | ✅ Yes (generated) | User preference, regenerated from saved values |
| Agent specs (analyst, reviewer) | ✅ Yes | Framework-provided agents, improvable |
| Skills (analyze, commit, design, review) | ✅ Yes | Framework-provided skills, improvable |
| MCP config | ❌ No (user-owned) | Personal server config |
| Setup scripts | ❌ No (user-owned) | Personal environment |

### 6.3 Decision: Global defaults are framework value

Non-negotiable: the rules, agents, and skills in global defaults ARE the framework's
methodology offering. They are tracked and updated because they represent ongoing
value — improvements to these files are improvements to the user's development
experience.

---

## 7. Interaction with Install/Publish System

### 7.1 How packs and projects arrive via remote

| Command | What it does | Source tracking |
|---------|-------------|----------------|
| `cco pack install <url>` | Clones repo, copies pack to `user-config/packs/` | `.cco-source` file in pack dir |
| `cco pack update <name>` | Re-clones from `.cco-source` URL, replaces pack | Updates `.cco-source` timestamp |
| `cco project install <url>` | Clones repo, copies project template, auto-installs packs | No source tracking at project level |

### 7.2 How cco update interacts with installed resources

**`cco update` does NOT touch packs or remotely-installed projects.**

This is correct and intentional:

| Resource type | Updated by `cco update`? | Updated by? |
|---------------|--------------------------|-------------|
| Global framework files | ✅ Yes | — |
| Project `.claude/settings.json` | ✅ Yes (from base template) | — |
| Project `project.yml` | ✅ Yes (from base template) | — |
| Packs (local) | ❌ No | User modifies directly |
| Packs (remote) | ❌ No | `cco pack update <name>` |
| Template-specific files | ❌ No | Manual or future `cco template sync` |

### 7.3 Pack update semantics

Pack updates (`cco pack update`) are **full-replace** from the remote source:
- No 3-way merge — the pack source is authoritative
- `.cco-source` tracks URL, path, and ref (branch/tag)
- All projects using the pack get the new version at next `cco start`
  (packs are mounted read-only from the central `packs/` directory)

This is a fundamentally different model from `cco update`:
- `cco update` = framework → user propagation (3-way merge, customizations preserved)
- `cco pack update` = source → local synchronization (full replace, source is truth)

### 7.4 Cross-project pack sharing

A pack installed once in `user-config/packs/` is shared by ALL projects that
reference it in their `packs:` list. A single `cco pack update` affects all
projects. This is intentional:
- Packs are reusable knowledge — consistency across projects is the point
- Per-project pack copies would create drift and storage waste
- If a project needs a customized version, the user can `cco pack internalize` it

### 7.5 Future consideration: version pinning

Currently, `cco pack update` pulls HEAD of the stored ref (branch). There is no
version pinning or lockfile. For now this is acceptable (packs are typically
maintained by the same user or team), but a future enhancement could add:
- `pack.yml` version field
- `.cco-source` locked commit hash
- `cco pack update --to <version>` flag

This is out of scope for the current update system sprint.

---

## 8. User Templates and the Update Boundary

### 8.1 User templates are never updated by `cco update`

User templates in `user-config/templates/` are the user's domain. `cco update`
never reads from or writes to this directory. This is a **non-negotiable boundary**.

### 8.2 How users propagate their own template changes

If a user updates `user-config/templates/project/my-preset/`, they want to
propagate those changes to projects created from that template. This is a
**separate operation** from framework updates:

- **Not `cco update`**: that command means "bring me framework improvements"
- **Future command**: `cco template sync <project-name>` or similar
  - Reads the project's creation template from `.cco-meta`
  - Performs 3-way merge against the template source (same engine as `cco update`)
  - Only available for user templates where the source still exists

This separation is important for user trust:
- `cco update` = safe, framework-controlled, predictable
- `cco template sync` = explicit, user-initiated, user-controlled

### 8.3 Consequence: `--sync-templates` flag removed

The earlier design proposed `--sync-templates` as a flag on `cco update`. This is
removed in favor of a future dedicated command. Rationale:
- Mixing framework updates and user template propagation in one command conflates
  two different operations with different trust levels
- A dedicated command gives the user full control over when and which projects
  receive template changes

---

## 9. `cco update` UX — Keeping It Non-Threatening

### 9.1 Design goal

`cco update` must feel like a **helpful routine**, not a risky operation. The user
should run it without hesitation after upgrading cco.

### 9.2 What makes it fast and safe

1. **Few tracked files**: Global has 13 tracked files; project has 2 (settings.json,
   project.yml). Most pass as SAFE_UPDATE (user hasn't modified) — silent, instant.

2. **3-way merge auto-resolves most conflicts**: When both sides changed a file but
   in different sections, `git merge-file` merges automatically. The user is only
   prompted for true line-level conflicts.

3. **Vault snapshot**: If vault is initialized, cco offers a pre-update snapshot.
   This gives the user a safety net and confidence.

4. **Dry-run first**: `cco update --dry-run` shows exactly what would change.
   Recommended before first real update.

5. **Backup always**: Modified files get `.bak` copies before being changed.
   The user can always recover.

### 9.3 Typical update experience

```
$ cco update --all

Global config:
  ✓ rules/workflow.md — safe update (you haven't modified)
  ✓ skills/analyze/SKILL.md — safe update
  ≡ CLAUDE.md — you modified, no framework change (preserved)
  2 updates, 1 preserved

Project 'my-app':
  ✓ project.yml — auto-merged (2 new sections added)
  ≡ .claude/settings.json — no changes
  1 update

Project 'tutorial':
  ≡ project.yml — no changes
  ≡ .claude/settings.json — no changes

✓ Update complete. No conflicts.
```

No prompts, no decisions, done in seconds. This is the typical case.

---

## 10. Decisions — Non-Negotiable

These decisions are final and inform all future design and implementation work.

### D1: `templates/project/base/` is the project update source

All projects receive schema updates from the base template, regardless of which
template was used at creation. Base functions as "project defaults".

### D2: `cco update` uses only native framework sources

`cco update` reads from `defaults/global/` and `templates/project/base/` only.
It never reads from user templates, non-base native templates, or packs.

### D3: User templates are never touched by `cco update`

User template propagation is a separate future command (`cco template sync`),
not a flag on `cco update`.

### D4: Template-specific files are not tracked

Files that exist only in non-base templates (tutorial skills, user template
custom rules) have no base equivalent and are therefore not updated. They are
the user's or the maintainer's responsibility.

### D5: Packs have their own update path

`cco pack update` is independent from `cco update`. Packs use full-replace
from source, not 3-way merge. The two systems do not interact.

### D6: Global defaults represent framework methodology

Rules, agents, and skills in `defaults/global/` are tracked and updated because
they embody cco's development methodology. This is framework value, not boilerplate.

### D7: Managed scope is immutable and Docker-baked

Changes to managed files require `cco build`. No runtime update mechanism.

### D8: Native templates are minimal

Only templates that serve the framework itself (learning, development). No
technology/stack templates — those are packs and user templates.

### D9: Migrations handle structure, merge handles content

Content changes to existing tracked files → 3-way merge (automatic).
Structural changes (new files, renames, schema breaks) → explicit migrations.

### D10: `cco update` must be fast and non-threatening

Design for the common case: most files pass silently, few require interaction.
If update becomes slow or prompt-heavy, the design has failed.

---

## 11. Open Questions (Deferred)

### Q1: Template update notifications
Should `cco update` notify when non-base template updates are available?
Decision deferred — requires `.cco-meta` to store template name (already planned
in migration 008) and a comparison mechanism.

### Q2: Pack version pinning
Should packs support version/commit pinning for reproducibility?
Decision deferred — current full-replace model works for small teams.

### Q3: `cco template sync` command
Future command to propagate user template changes to projects.
Uses the same 3-way merge engine as `cco update`.
Decision deferred — requires design for template-to-project file mapping.

### Q4: Project install source tracking
`cco project install <url>` does not save the source URL at project level
(only at pack level via `.cco-source`). Should projects also track their origin?
Decision deferred — not needed for current update system.
