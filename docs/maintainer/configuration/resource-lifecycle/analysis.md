# Resource Lifecycle — Analysis

> How is a project/pack updated when its template source evolves?
>
> Date: 2026-03-16
> Status: Analysis (pending review)
> Scope: File policies, update mechanisms, tutorial separation, publish/install sync foundations

---

## 1. Problem Statement

The update system has a fundamental gap: **it cannot reliably notify users
of template changes for project-scope files**. This manifests in several ways:

1. **Tutorial CLAUDE.md is invisible to updates**: `PROJECT_FILE_POLICIES`
   marks `.claude/CLAUDE.md` as `user-owned` for all projects. Changes to the
   tutorial template's CLAUDE.md (curriculum, philosophy, doc map) are never
   discovered by `cco update`.

2. **The `user-owned` policy silences notifications entirely**: A file marked
   `user-owned` receives zero update tracking — no discovery, no diff, no
   merge offer. This is correct for files the user creates from scratch
   (project.yml, secrets.env) but wrong for files where the framework provides
   evolving content.

3. **Tutorial serves two incompatible purposes**: It is both educational
   content (should always be current) and a configurable project (user may
   want extra mounts, write access to user-config, custom Docker options).

4. **No update path for published resources**: After `cco project install` or
   `cco pack install`, there is no mechanism to check for source updates,
   compare versions, or merge changes. `.cco/source` tracks the origin but
   nothing reads it for update purposes.

5. **File policies are static and global**: `PROJECT_FILE_POLICIES` applies
   identically to all projects regardless of template. A tutorial project and
   a base project have the same policy for CLAUDE.md, even though their
   CLAUDE.md files have completely different authorship models.

These are not independent bugs — they are symptoms of a missing design layer:
**template-aware resource lifecycle management**.

---

## 2. Current State

### 2.1 File Policies (pre-Sprint 5c)

> Policies shown below reflect the state **before** the redesign.
> `user-owned` has since been renamed to `untracked`, and project
> `CLAUDE.md` changed to `tracked`. See §3 for the redesign.

```
GLOBAL_FILE_POLICIES:
  .claude/CLAUDE.md           → tracked     (discovery + 3-way merge)
  .claude/settings.json       → tracked
  .claude/mcp.json            → user-owned  (never touched)
  .claude/agents/analyst.md   → tracked
  .claude/agents/reviewer.md  → tracked
  .claude/rules/diagrams.md   → tracked
  .claude/rules/git-practices.md → tracked
  .claude/rules/workflow.md   → tracked
  .claude/rules/language.md   → generated   (regenerated from prefs)
  .claude/skills/*/SKILL.md   → tracked
  setup.sh                    → user-owned
  setup-build.sh              → user-owned

PROJECT_FILE_POLICIES:
  .claude/CLAUDE.md           → user-owned  (PROBLEM: silences all updates)
  .claude/settings.json       → tracked
  .claude/rules/language.md   → user-owned
```

### 2.2 How Discovery Works

`_collect_file_changes()` scans all files in the template source directory,
skips files marked `user-owned`, and classifies the rest via 3-way hash
comparison (new vs base vs installed).

For projects, `_resolve_project_defaults_dir()` reads `.cco/source` to
determine whether to compare against `templates/project/base/.claude/` or
`templates/project/<template-name>/.claude/`.

**What works**: Template-specific files NOT in `PROJECT_FILE_POLICIES`
(e.g., `skills/tutorial/SKILL.md`, `rules/tutorial-behavior.md`) are
implicitly tracked — they ARE discovered because they're not filtered out.

**What breaks**: `CLAUDE.md` is explicitly filtered out as `user-owned` before
discovery even runs. Template-specific CLAUDE.md changes are invisible.

### 2.3 Template Taxonomy (pre-Sprint 5c)

> This table describes the state **before** the redesign implemented in §4.
> Tutorial has since moved to `internal/tutorial/` and config-editor was added
> as a native template. See §5.2 for the current resource classification.

| Type | Location | Owner | Update mechanism |
|------|----------|-------|-----------------|
| Native base | `templates/project/base/` | Framework | Discovery via `cco update` |
| Native non-base | `templates/project/tutorial/` | Framework | Discovery via `cco update` (partial — CLAUDE.md excluded) |
| User template | `user-config/templates/<name>/` | User | None (user manages directly) |
| Remote (Config Repo) | `<remote>/templates/<name>/` | Publisher | None after install (FI-7 needed) |

### 2.4 Resource Source Tracking

`.cco/source` records origin for all non-local resources:

```yaml
# Native template project
source: native:project/tutorial

# Remote-installed project
source: https://github.com/team/cco-config.git
path: templates/my-service
ref: main
installed: 2026-03-05

# Local resource
source: local
```

This metadata exists but is only used for template resolution during discovery.
It is NOT used for version comparison or update notification from remote sources.

---

## 3. File Policy Redesign

### 3.1 Problem with Current Naming

The term `user-owned` conflates two distinct behaviors:

1. **File the user creates from scratch** — framework has no evolving version.
   Example: `project.yml`, `secrets.env`, `setup.sh`. No updates possible.

2. **File the framework provides but the user may customize** — framework
   has an evolving version. Example: project `CLAUDE.md` from a template.
   Updates should be discoverable.

Currently both are `user-owned`, which means "never track, never notify".
This is correct for case 1, wrong for case 2.

### 3.2 Proposed Policy Taxonomy

| Policy | Behavior | Discovery | Merge | Auto-apply | Use case |
|--------|----------|-----------|-------|------------|----------|
| `tracked` | 3-way merge available | Yes | Yes (opt-in via `--sync`) | No | Opinionated files that evolve with framework (rules, skills, agents, CLAUDE.md) |
| `untracked` | Never compared, never notified | No | No | No | Files 100% authored by user, no framework version exists (project.yml, secrets.env, setup.sh, mcp.json) |
| `generated` | Regenerated from template + saved values | N/A | N/A | Yes (regeneration) | Derived files (language.md) |

**Key change**: rename `user-owned` → `untracked`. The new name communicates
the actual behavior: "the framework does not track this file". The old name
implied ownership semantics that were misleading.

### 3.3 Sync Strategy: Skip + .new (New Option)

The current `cco update --sync` offers these options per file:

- **(A)pply**: Copy framework version (when user hasn't modified)
- **(M)erge 3-way**: Attempt auto-merge (when both modified)
- **(R)eplace + .bak**: Overwrite, save user's as `.bak`
- **(K)eep**: Keep user's version
- **(S)kip**: Same as keep
- **(D)iff**: Show changes

**Problem with Merge on restructured files**: 3-way merge works well when
the file structure is stable (same sections, similar ordering). It works
poorly when the user has reorganized blocks, reordered sections, or
substantially restructured the file. In that case, the diff identifies
line-level differences that don't correspond to semantic changes — the
merge produces confusing results or false conflicts.

**Proposed new option: (N)ew-file**:
- Save the framework version as `<filename>.new` alongside the user's file
- User's file is NOT modified
- User can review `.new` at their leisure and manually integrate the parts
  they want

This is the inverse of Replace+.bak:
- Replace+.bak: user gets framework version, old version saved as `.bak`
- **New-file: user keeps their version, framework version saved as `.new`**

**When to recommend New-file over Merge**:
- The file has been substantially restructured by the user
- The diff shows many line changes that are positional (reordering) rather
  than content changes
- For CLAUDE.md files specifically, where users often reorganize sections
  to match their mental model

**Documentation**: The sync UI should indicate when New-file is recommended.
A heuristic could be: if the 3-way merge produces more than N conflict
markers, suggest New-file as an alternative. Or simply document the guideline:
"If you've reorganized this file's structure, use (N)ew-file instead of
(M)erge for a cleaner review."

### 3.4 Revised File Policies

#### Global (no changes needed — already correct)

```
GLOBAL_FILE_POLICIES:
  .claude/CLAUDE.md                    → tracked
  .claude/settings.json                → tracked
  .claude/mcp.json                     → untracked   (renamed from user-owned)
  .claude/agents/analyst.md            → tracked
  .claude/agents/reviewer.md           → tracked
  .claude/rules/diagrams.md            → tracked
  .claude/rules/git-practices.md       → tracked
  .claude/rules/workflow.md            → tracked
  .claude/rules/language.md            → generated
  .claude/skills/analyze/SKILL.md      → tracked
  .claude/skills/review/SKILL.md       → tracked
  .claude/skills/design/SKILL.md       → tracked
  .claude/skills/commit/SKILL.md       → tracked
  setup.sh                             → untracked
  setup-build.sh                       → untracked
```

#### Project base (CLAUDE.md changes from untracked to tracked)

```
PROJECT_BASE_FILE_POLICIES:
  .claude/CLAUDE.md                    → tracked      (CHANGED: was user-owned)
  .claude/settings.json                → tracked
  .claude/rules/language.md            → untracked    (renamed from user-owned)
```

**Rationale for CLAUDE.md → tracked**: The base template's CLAUDE.md contains
structural placeholders (`{{PROJECT_NAME}}`, section headers for Architecture,
Key Commands, etc.). If the framework improves the template structure, users
should be notified. The 3-way merge preserves user content while showing
what the framework added.

**Counter-argument considered**: "Users write 100% of the project CLAUDE.md
content, so tracking is noise." Response: the 3-way merge handles this
gracefully — if the user has heavily modified the file, merge shows the diff
and the user can Skip. If the user hasn't touched the template sections,
they get the improvement automatically. The cost of a false notification is
low; the cost of a missed improvement is higher.

#### Project (template-specific — dynamic)

For non-base templates, the file policies should be resolved dynamically:

1. Start with `PROJECT_BASE_FILE_POLICIES` as defaults
2. The template MAY declare additional policies via a `file_policies` section
   in `.cco/meta` or a dedicated `.cco/policies` file
3. Files not in any policy list but present in the template are implicitly
   `tracked` (current behavior, already correct)

Example for a hypothetical template:

```yaml
# .cco/policies (in template source)
file_policies:
  .claude/CLAUDE.md: tracked           # override base default if needed
  .claude/skills/my-skill/SKILL.md: tracked
  .claude/rules/my-rule.md: tracked
```

**For the tutorial specifically**: all `.claude/` files from the template are
tracked. The user doesn't author any of them — the framework provides
everything. But this point may be moot if we adopt the internal tutorial
approach (see §4).

---

## 4. Tutorial Separation

### 4.1 Two Distinct Use Cases

The current tutorial project serves two purposes that should be separated:

| Aspect | Tutorial (educational) | Config Editor (productive) |
|--------|----------------------|---------------------------|
| **Purpose** | Learn cco concepts, explore features | Edit user-config, create packs/projects, extract resources |
| **Content author** | Framework (curriculum, modules, skills) | Framework provides base, user customizes |
| **Update model** | Always current with framework version | User-owned, updated via standard policies |
| **Configuration** | Fixed (no user customization needed) | Configurable (extra mounts, Docker, permissions) |
| **Naming** | `tutorial` | `config-editor` or similar |
| **Lifecycle** | Internal to framework, not installed | Installed from template, user-owned |

### 4.2 Tutorial as Internal Project (Option D)

The tutorial becomes a **framework-internal resource**, not a user project
and not a template.

**Positioning in directory tree**:

The tutorial moves from `templates/project/tutorial/` to `internal/tutorial/`.
This is a new top-level directory in the repo, alongside `templates/`,
`defaults/`, `lib/`, etc.

**Why not `defaults/`**: The `defaults/` directory has a specific meaning:
- `defaults/global/` = config copied to user-config on `cco init` (user-owned)
- `defaults/managed/` = immutable framework infrastructure (baked in Docker)
- Tutorial is neither — it's not copied to user-config and it's not baked
  into the Docker image. It runs directly from its source.

**Why not `templates/`**: Templates are scaffolds that get copied and
customized. The tutorial is no longer copied — it runs in-place. Keeping it
in `templates/` is misleading about its lifecycle.

**`internal/` semantics**: Framework-internal resources that are used directly
at runtime, not copied or installed. Currently only tutorial. Future internal
resources (if any) would live here too.

```
internal/
└── tutorial/
    ├── project.yml              # Fixed config (not customizable by user)
    ├── .claude/
    │   ├── CLAUDE.md            # Curriculum, doc map, behavior
    │   ├── settings.json
    │   ├── skills/
    │   │   └── tutorial/
    │   │       └── SKILL.md
    │   └── rules/
    │       └── tutorial-behavior.md
    └── setup.sh
```

**Implementation**:
- `cco start tutorial` recognizes `tutorial` as a reserved name
- Generates docker-compose.yml from `internal/tutorial/project.yml` directly
  (no copy to user-config/projects/)
- No `.cco/base/`, no `.cco/source/`, no update tracking needed
- Always reflects the current framework version
- Session state (transcripts) stored in a framework-managed location
  (e.g., `user-config/.cco/tutorial-state/` or similar)
- Tutorial does not appear in `cco project list`

**What the user CANNOT do with internal tutorial**:
- Customize project.yml (extra mounts, Docker socket, ports)
- Enable write access to user-config
- Add repos or other resources
- Use it as a general-purpose config editing session

**What the user CAN do**:
- Start it: `cco start tutorial`
- Learn cco concepts, explore docs, get guided assistance
- Read (not write) their user-config for context-aware guidance

### 4.3 Config Editor as Separate Template

A new template `config-editor` provides the productive use case:

```bash
cco project create my-editor --template config-editor
```

This creates a standard user-owned project with:
- **`user-config` mounted as a repo** (not as extra_mount read-only).
  The intent of config-editor is working on user-config, so it should be
  treated as a first-class repository. The path uses `{{CCO_USER_CONFIG_DIR}}`
  for portability.
- cco documentation mounted as extra_mount read-only (same as tutorial)
- Skills focused on config editing (create packs, scaffold projects,
  manage vault, publish/install)
- Standard update policies — user gets notified of template improvements

**Config-editor project.yml**:

```yaml
name: {{PROJECT_NAME}}
description: "Configuration editor for claude-orchestrator"

repos:
  - path: {{CCO_USER_CONFIG_DIR}}
    name: user-config

extra_mounts:
  - source: {{CCO_REPO_ROOT}}/docs
    target: /workspace/cco-docs
    readonly: true

docker:
  mount_socket: false
  ports: []
  env: {}

auth:
  method: oauth
```

**CLAUDE.md and rules**: The config-editor's `.claude/` must include:
- Instructions on how to manage vault operations (sync, diff, push/pull)
- Guidelines for publish/install workflows
- References to official documentation (via `/workspace/cco-docs/` mount)
- Safety rules for editing user-config (backup before destructive changes,
  validate after modifications)
- Guidance on pack structure best practices

These instructions come from the same documentation that the tutorial reads,
but are encoded as actionable rules rather than educational content.

**Key difference from tutorial**: The config-editor template provides tools
and skills, not educational content. The CLAUDE.md describes capabilities,
not curriculum modules. The user customizes it as needed.

**Naming alternatives considered**:
- `config-editor` — descriptive, clear purpose
- `workspace-manager` — broader scope
- `cco-assistant` — too generic
- `setup-wizard` — implies one-time use

Recommendation: `config-editor` — directly communicates what it does.

### 4.4 Migration Path

For users who already have a `tutorial` project in their user-config:

1. The project continues to work as-is (no breaking change)
2. `cco update` could inform them: "The tutorial is now built-in. Run
   `cco start tutorial` directly. Your existing tutorial project can be
   removed with `cco project remove tutorial`."
3. If they want config editing capabilities, suggest:
   `cco project create my-editor --template config-editor`

---

## 5. Resource Lifecycle — Unified Model

### 5.1 The Central Question

> When a resource's source evolves, how does the change reach the user?

This question applies uniformly to all resource types. The answer depends on
two factors:

1. **Where is the source?** (framework-internal, local, remote Config Repo)
2. **What is the update policy?** (tracked, untracked, generated, internal)

### 5.2 Resource Classification Matrix

| Resource | Source location | Update policy | Update mechanism | User notification |
|----------|---------------|---------------|-----------------|-------------------|
| **Managed files** | `defaults/managed/` | Internal (rebuild) | `cco build` | None (user rebuilds intentionally) |
| **Global opinionated files** | `defaults/global/` | Tracked | `cco update` discovery + `--sync` merge | Yes (discovery summary) |
| **Global user files** | Created by user | Untracked | None | None |
| **Project settings.json** | Template `.claude/` | Tracked | `cco update` discovery + `--sync` merge | Yes |
| **Project CLAUDE.md** | Template `.claude/` | Tracked (CHANGED) | `cco update` discovery + `--sync` merge | Yes |
| **Project user files** | Created by user | Untracked | None | None |
| **Tutorial** | `internal/tutorial/` | Internal | Always current (runs in-place) | N/A |
| **Config-editor project** | `templates/project/config-editor/` | Tracked (template-aware) | `cco update` discovery + `--sync` merge | Yes |
| **Pack (local)** | Created by user | Untracked | None | None |
| **Pack (installed)** | Remote Config Repo | Full-replace | `cco pack update` | Via `cco update` discovery (FI-7) |
| **Project (installed)** | Remote Config Repo | Tracked (FI-7) | `cco project update` (3-way merge) | Via `cco update` discovery (FI-7) |
| **cco-develop project** | Remote Config Repo | Tracked (FI-7) | `cco project install` + `cco project update` | Via `cco update` discovery (FI-7) |

### 5.3 Update Flow by Source Type

#### Framework-internal (managed, defaults, native templates)

```
Framework maintainer updates defaults/ or templates/
  ↓
User runs cco update
  ↓
Discovery: compare template vs .cco/base/ vs installed
  ↓
Report: "N files have updates available"
  ↓
User runs cco update --sync → interactive 3-way merge
```

**Already works** for global scope. Partially works for project scope
(blocked by CLAUDE.md being untracked — fix in §3).

#### Remote Config Repo (publish/install — FI-7)

```
Publisher runs cco pack publish / cco project publish
  ↓
Config Repo updated (git push)
  ↓
Consumer runs cco update
  ↓
Discovery: read .cco/source → check remote for newer version
  ↓
Report: "Pack 'X' has updates from remote" / "Project 'Y' template updated"
  ↓
Consumer runs cco pack update <name> → full-replace (packs are read-only)
Consumer runs cco project update <name> → 3-way merge (projects are user-modified)
```

**Not yet implemented**. This is FI-7. The analysis here provides the
foundation for its design.

#### Vault sync (same user, different machines)

```
Machine A: user modifies config → cco vault sync → git push
  ↓
Machine B: cco vault sync → git pull → files updated
```

**Already works** for transferring files between machines. Does NOT handle
the case where Machine A also ran `cco update --sync` (applied framework
updates) — Machine B gets the updated files via vault pull, but its
`.cco/base/` may be stale. This is acceptable: Machine B's next `cco update`
will see no changes (files already match template) and update `.cco/base/`
via the manifest hash in `.cco/meta`.

### 5.4 cco-develop: Publish/Install as Intended

The `cco-develop` project (for framework maintainers working on
claude-orchestrator itself) is the canonical demonstration of publish/install:

- **Source**: A Config Repo managed by the claude-orchestrator maintainer team
- **Distribution**: `cco project install <cco-develop-repo-url>`
- **Updates**: `cco project update cco-develop` (once FI-7 is implemented)
- **Permissions**: GitHub manages read/write access per collaborator
  - Maintainers with write access: can `cco project publish` updates
  - Contributors with read access: can `cco project install` and receive updates
  - Admins: can approve PRs to the Config Repo

This validates the publish/install flow in a real-world scenario and avoids
special-casing cco-develop as an internal template. It also demonstrates that
the Config Repo model works for any team, not just the cco maintainers.

**Note**: The actual design and creation of cco-develop is a separate task.
This analysis only establishes that it should use publish/install, not an
internal mechanism.

---

## 6. Foundations for FI-7 (Publish/Install Sync)

### 6.1 What Already Exists

1. **`.cco/source`**: Records origin URL, path, ref, install/update dates
2. **`.cco/base/`**: Stores last-seen version for 3-way merge
3. **`_collect_file_changes()`**: Generic diff engine (works on any source/target)
4. **`_interactive_sync()`**: Interactive merge UI (Apply/Merge/Replace/Keep/Skip)
5. **`cco pack update`**: Full-replace update from remote (for packs)

### 6.2 What's Missing for FI-7

1. **Remote version check**: Read `.cco/source`, fetch remote HEAD hash,
   compare with installed version hash. Determine if update available.

2. **`cco project update <name>`**: Like `cco pack update` but with 3-way
   merge instead of full-replace (projects have user modifications).

3. **Discovery integration**: `cco update` should check `.cco/source` for
   all installed resources and report available updates from remotes. This
   requires network access (sparse git fetch), so it should be opt-in or
   cached.

4. **Version metadata**: Optional `version:` field in template/pack metadata
   for human-readable version tracking. Git commit hashes provide precise
   comparison; version labels provide user communication.

5. **Publish safety**: Before `cco project publish`, diff the local project
   against the remote version to detect accidental inclusion of local-only
   changes (personal CLAUDE.md content, local secrets references, etc.).

### 6.3 Design Decisions Deferred to FI-7

- Network access policy for discovery (check on every `cco update`? cache? opt-in?)
- Version display format in `cco update` output
- Conflict resolution UX for remote project updates
- Pack update granularity (full-replace vs file-level merge for packs with
  user customizations)
- Interaction between vault profiles and remote updates

### 6.4 What This Analysis Provides for FI-7

The file policy redesign (§3) and the resource lifecycle model (§5) establish
the framework within which FI-7 operates:

- **Tracked files** in projects support 3-way merge → FI-7 reuses this for
  remote project updates
- **`.cco/source`** already tracks origin → FI-7 adds version comparison
- **`.cco/base/`** already stores merge ancestor → FI-7 updates base after
  remote sync
- **Discovery engine** is source-agnostic → FI-7 adds "remote source" as
  another discovery input alongside "framework defaults"

---

## 7. File-by-File Policy Review

### 7.1 Global Scope

| File | Current | Proposed | Rationale |
|------|---------|----------|-----------|
| `.claude/CLAUDE.md` | tracked | **tracked** (no change) | Framework methodology, evolves with framework |
| `.claude/settings.json` | tracked | **tracked** (no change) | Permission baseline |
| `.claude/mcp.json` | user-owned | **untracked** (rename only) | 100% user-authored, no framework version |
| `.claude/agents/analyst.md` | tracked | **tracked** (no change) | Framework agent spec |
| `.claude/agents/reviewer.md` | tracked | **tracked** (no change) | Framework agent spec |
| `.claude/rules/diagrams.md` | tracked | **tracked** (no change) | Framework convention |
| `.claude/rules/git-practices.md` | tracked | **tracked** (no change) | Framework convention |
| `.claude/rules/workflow.md` | tracked | **tracked** (no change) | Framework convention |
| `.claude/rules/language.md` | generated | **generated** (no change) | Derived from user preferences |
| `.claude/skills/*/SKILL.md` | tracked | **tracked** (no change) | Framework skills |
| `setup.sh` | user-owned | **untracked** (rename only) | User bootstrap script |
| `setup-build.sh` | user-owned | **untracked** (rename only) | User build script |

**Summary**: Global policies are correct. Only naming change (user-owned → untracked).

### 7.2 Project Scope (Base Template)

| File | Current | Proposed | Change? | Rationale |
|------|---------|----------|---------|-----------|
| `.claude/CLAUDE.md` | user-owned | **tracked** | **YES** | Template provides structure; user fills in content. 3-way merge preserves user content while offering framework improvements to template structure. |
| `.claude/settings.json` | tracked | **tracked** | No | Permission baseline, rarely customized per-project |
| `.claude/rules/language.md` | user-owned | **untracked** | Rename | User override of global language; no framework version at project level |
| `project.yml` | (not in policy) | **untracked** | Explicit | 100% user-authored after template substitution. New fields handled via additive changes + code defaults. Schema changes via migrations. |
| `setup.sh` | (copy-if-missing) | **untracked** | Explicit | User bootstrap, no framework evolution |
| `secrets.env` | (copy-if-missing) | **untracked** | Explicit | User secrets, never tracked |
| `mcp-packages.txt` | (copy-if-missing) | **untracked** | Explicit | User MCP packages |

**Key change**: `.claude/CLAUDE.md` moves from `user-owned` to `tracked`.
This is the fix for the bug that started this analysis.

### 7.3 Project Scope (Template-Specific Files)

Files present in a template's `.claude/` directory but NOT in
`PROJECT_FILE_POLICIES` are **implicitly tracked** by `_collect_file_changes()`.
This is the current behavior and it is correct.

Examples for tutorial template:
- `skills/tutorial/SKILL.md` → implicitly tracked ✓
- `rules/tutorial-behavior.md` → implicitly tracked ✓

No change needed for these files. The implicit tracking is the right default:
any file the template provides and the framework may update should be
discoverable.

### 7.4 Implicit vs Explicit Policy

The current system has two ways a file gets its policy:

1. **Explicitly listed** in `*_FILE_POLICIES` arrays → policy from the list
2. **Not listed but present in template** → implicitly tracked (discovered
   by `_collect_file_changes()`, not filtered out)

This implicit tracking is a strength, not a bug. It means template maintainers
don't need to register every file — they just add it to the template and
it becomes discoverable automatically.

The only issue is when the **explicit policy is wrong** (as with CLAUDE.md
being `user-owned`), which overrides the correct implicit behavior.

**Recommendation**: Keep implicit tracking for template-specific files.
Use explicit policies only for files that need special treatment (untracked
or generated). Default is tracked.

---

## 8. Implementation Priorities

### 8.1 Immediate (Bug Fix)

1. **Rename `user-owned` → `untracked`** in code and docs
2. **Change project CLAUDE.md from `untracked` to `tracked`**
3. **Verify `.cco/base/` is populated** for project CLAUDE.md at creation time
   (it should already be, since `_save_base_versions()` runs for all files
   in the template, but verify)

Impact: All projects get CLAUDE.md update discovery. Existing projects
without `.cco/base/CLAUDE.md` will see `BASE_MISSING` status on first
`cco update`, which is handled gracefully (direct comparison).

### 8.2 Short-term (Tutorial Separation)

1. **Implement internal tutorial** (`cco start tutorial` from template directly)
2. **Create config-editor template** (new template in `templates/project/`)
3. **Migration for existing tutorial projects** (informational, not breaking)
4. **Update documentation** (tutorial is built-in, config-editor is a template)

### 8.3 Medium-term (FI-7 Foundations)

1. **Remote version check** in `cco update` discovery
2. **`cco project update <name>`** with 3-way merge
3. **Publish safety check** (diff before publish)
4. **Version metadata** in `.cco/source`

### 8.4 Later (cco-develop)

1. **Create cco-develop Config Repo** on GitHub
2. **Publish cco-develop project template** to Config Repo
3. **Document contributor setup**: `cco project install <url>`
4. **Validate FI-7 flow** with real multi-user scenario

---

## 9. Design Principles (Updated)

Based on this analysis, the following principles are confirmed or added:

1. **All installed files are user-owned after creation** — framework provides
   defaults and merge tools, never forces changes. (Confirmed, unchanged.)

2. **`tracked` is the default for template-provided files** — if a file comes
   from a template, the framework assumes it will evolve and should be
   discoverable. Only files explicitly marked `untracked` are excluded.
   (Clarified — was implicit, now explicit.)

3. **`untracked` means "no framework version exists"** — the framework does
   not have an evolving version of this file. No discovery, no diff, no merge.
   Use for files 100% authored by the user. (Renamed from `user-owned` for
   clarity.)

4. **Template-specific policies override base policies** — if a template
   needs different tracking behavior for a file, it can declare it. The
   mechanism is implicit tracking (already works) plus explicit overrides
   in the policy arrays.

5. **Internal resources are not user-configurable** — resources internal to
   the framework (tutorial, managed files) are not installed in user-config
   and do not participate in the update system. They are always current.

6. **Published resources use the same update semantics as native templates** —
   the 3-way merge engine is source-agnostic. FI-7 adds "remote source" as
   a discovery input, not a new merge mechanism.

7. **cco-develop uses publish/install, not special-casing** — demonstrates
   that the Config Repo model works for the framework's own development team.

---

## 10. Open Questions

1. **Should `cco update` check remotes automatically?** Network access during
   discovery adds latency and requires connectivity. Options: always check,
   check only with `--remote` flag, cache with TTL, skip with `--offline`.
   Decision deferred to FI-7 design.

2. **Should packs support 3-way merge?** Currently packs are full-replaced on
   update. If a user customizes a pack, their changes are lost. Options:
   require `cco pack internalize` before modifying (current approach),
   add merge support for packs. Decision: current approach is correct — packs
   are mounted read-only, so customization should happen via fork
   (internalize) not merge.

3. **Config-editor template scope**: What skills should it include? Should it
   have access to Docker? Should it be able to run `cco` commands somehow?
   Decision deferred to template creation.

4. **Tutorial session state**: Where to store transcripts for `cco start
   tutorial` when the project isn't in user-config? Options: `user-config/
   .cco/tutorial-state/`, temp directory (lost on exit), dedicated location.
   Decision deferred to implementation.

5. **Multiple simultaneous update sources**: A project created from a native
   template and later also receiving updates from a remote Config Repo.
   This is a conflicting scenario — should be prevented (one source per
   resource) or handled (priority chain). Decision: one source per resource.
   If user wants remote updates, they install from remote; if they want
   framework updates, they use a native template. Switching source requires
   explicit action.

---

## 11. Cross-References

| Topic | Document |
|-------|----------|
| Update system design | `docs/maintainer/configuration/update-system/design.md` |
| Update system analysis | `docs/maintainer/configuration/update-system/analysis.md` |
| Sharing/publish design | `docs/maintainer/configuration/sharing/enhancements-design.md` |
| Config Repo design | `docs/maintainer/configuration/sharing/design.md` |
| Vault design | `docs/maintainer/configuration/vault/design.md` |
| FI-7 in roadmap | `docs/maintainer/decisions/roadmap.md` § Sprint 11 |
| FI-7 details | `docs/maintainer/decisions/framework-improvements.md` § FI-7 |
| Current file policies | `lib/update.sh` lines 25-50 |
| Discovery engine | `lib/update.sh` `_collect_file_changes()` |
| Template resolution | `lib/update.sh` `_resolve_project_defaults_dir()` |
| Rules/guidelines analysis | `docs/maintainer/configuration/rules-and-guidelines/analysis.md` |
| Owner preferences | `docs/maintainer/configuration/rules-and-guidelines/owner-preferences.md` |
