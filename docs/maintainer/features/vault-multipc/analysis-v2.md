# Sprint 7-Vault — Architecture Analysis v2

**Date**: 2026-03-14
**Scope**: Architecture-level — cross-cutting analysis (vault, memory, sync)
**Supersedes**: `analysis.md` (pre-Sprint-5b analysis, 2026-03-11)
**Related**: `design.md` (definitive design, written in parallel)

> This document establishes the vault profile model, shared resource sync
> semantics, memory architecture, and memory policy for claude-orchestrator.
> It is the analytical foundation for Sprint 7-Vault and supersedes the
> original analysis written before Sprint 5b finalized the update system.

---

## 1. Why This Matters

The vault system determines whether cco is **usable across multiple machines**.
Without selective sync, users with different project sets on different PCs
cannot use a shared vault remote without polluting each machine with irrelevant
projects. Without a clear memory policy, critical knowledge ends up in
machine-local memory files that are never shared or version-controlled.

The value proposition of Sprint 7-Vault:

- **Multi-PC support**: each machine syncs only what it needs
- **Knowledge persistence**: memory files are vault-tracked and survive machine changes
- **Clear boundaries**: users and Claude know when to use memory vs. project docs
- **Zero-friction default**: single-PC users see no changes to their workflow

---

## 2. Current Architecture (Post-Sprint 5b)

### 2.1 Vault State

The vault is a git repository rooted at `user-config/`. Current behavior:

- `cco vault init` → `git init` + `.gitignore` template + initial commit
- `cco vault sync` → `git add -A` + `git commit` (stages everything)
- `cco vault push/pull` → `git push/pull` on current branch (typically `main`)
- `cco vault remote add/remove` → git remote + `.cco-remotes` file (tokens)

No granularity: push/pull operates on the entire `user-config/` directory.

### 2.2 Memory & claude-state Layout

```
user-config/projects/<name>/
├── claude-state/                     ← gitignored in vault
│   ├── memory/
│   │   ├── MEMORY.md                ← auto-loaded first 200 lines every session
│   │   └── <topic>.md              ← topic files, loaded on demand
│   └── <session-transcripts>/       ← enables /resume across container rebuilds
└── .claude/
    └── CLAUDE.md                    ← vault-tracked, synced
```

Docker mount (single bind mount):
```yaml
- ./claude-state:/home/claude/.claude/projects/-workspace
```

**Problem**: Memory and transcripts are bundled together in `claude-state/`.
Both are gitignored. Memory is lost on new machines or after `cco init --force`.

### 2.3 The Memory vs. Docs Boundary Problem

No policy currently defines when Claude should write to `MEMORY.md` vs.
project documentation. In practice:

| Information type | Where it often ends up | Problem |
|---|---|---|
| Sprint progress, active tasks | `MEMORY.md` | Local-machine only, not shared |
| Self-improvement feedback | `MEMORY.md` | Lost on other machines |
| Architecture decisions | `MEMORY.md` or `docs/` (ad hoc) | Inconsistent |
| Code patterns, conventions | `MEMORY.md` | Should be in rules/docs |
| Session-specific scratch notes | `MEMORY.md` | Correct placement |

Risk: Claude accumulates critical knowledge in memory that is never in the
repo or vault. On a second machine, that knowledge disappears.

### 2.4 What Changed Since the Original Analysis

Sprint 5b delivered:
- `.cco-meta` metadata tracking across all scopes
- `.cco-base/` storage for 3-way merge ancestors
- `git merge-file` infrastructure for on-demand file merging
- Migration runner with 4 scopes (global, project, pack, template)
- `cco clean` with multiple categories

These are directly relevant to Sprint 7:
- **3-way merge**: reusable for vault shared resource conflict resolution
- **Migration runner**: handles vault migration (memory separation, .gitignore update)
- **`.cco-meta`**: could track vault profile metadata (evaluated, decided against — see §4.2)

---

## 3. Multi-PC Vault Sync — Problem Analysis

### 3.1 Use Cases

**Case A — Identical config on all PCs** (two work machines):
- Works with current vault push/pull
- Potential merge conflicts if both PCs modify files concurrently
- No feature gap beyond conflict documentation

**Case B — Different project sets per PC** (primary gap):
- PC-A: work projects only
- PC-B: personal projects only
- Shared: global config, packs, templates
- Current behavior: push from PC-A → PC-B gets work projects on pull
- This is undesirable

**Case C — Organization-specific packs and projects**:
- User works with multiple orgs or contexts (e.g., org-A, org-B, personal)
- org-A packs and projects belong to the org-A profile
- org-B packs and projects belong to the org-B profile
- Personal packs shared across all contexts stay on main
- Current behavior: all packs sync to all machines regardless of context

### 3.2 Desired Final State

```
@mygithub/cco-config                    ← personal vault remote
├── main branch (shared):
│   ├── global/                         ← always synced to all profiles
│   ├── templates/                      ← always synced to all profiles
│   ├── packs/personal-utils/           ← shared pack (on main)
│   └── packs/python-tools/             ← shared pack (on main)
│
├── org-a branch:
│   ├── (inherits shared from main)
│   ├── projects/org-a-api/             ← exclusive to org-a profile
│   ├── projects/org-a-frontend/        ← exclusive to org-a profile
│   └── packs/org-a-conventions/        ← exclusive pack
│
└── personal branch:
    ├── (inherits shared from main)
    ├── projects/side-project/          ← exclusive to personal profile
    └── projects/blog/                  ← exclusive to personal profile
```

### 3.3 Options Evaluated

#### Option 1 — Branch per machine (no path scoping)

Each machine works on its own git branch. Shared resources synced via merge.

- **Fatal flaw**: `git add -A` stages ALL files in working tree, including
  projects that exist on disk but don't belong to this profile. Projects
  created locally (by `cco project create`) exist as real directories
  regardless of git branch. Without path scoping, they get committed.

#### Option 2 — Sparse-checkout per machine

Git-native sparse-checkout to pull only relevant paths.

- **Excluded**: complex to manage, fragile state in `.git/info/sparse-checkout`,
  not user-friendly, risk of data loss if misconfigured. Confirmed excluded
  from original analysis.

#### Option 3 — Selective sync (path-scoped push/pull, single branch)

`cco vault push/pull --only <path>` on a single branch.

- **Fatal flaw**: `git pull` on a single branch brings ALL committed files,
  including other machines' projects. Path scoping controls what you push
  but cannot prevent other machines' content from arriving on pull. Would
  need sparse-checkout to filter incoming files — which we excluded.

#### Option 4 — Profile-based vault (single branch + path scoping)

Machine-local `profile.yml` declares what to sync. Push stages only profile
paths. Single branch.

- **Same flaw as Option 3**: single branch means pull brings everything.
  The profile filters push (what you commit) but not pull (what you receive).
  Other machines' projects appear in your working tree after pull.

#### Option 5 — Branch + profile (recommended) ✓

Each profile = dedicated git branch + path scoping declaration. `main`
branch holds shared resources. Profile branches hold shared + exclusive.

- **Solves the core problem**: pull of your profile branch never brings
  other profiles' exclusive content
- **Path scoping**: `vault sync` stages only profile-declared paths
- **Shared resources**: flow through `main` branch, synced automatically
- **Backward compatible**: without profiles, vault works on `main` exactly
  like today

### 3.4 Why Option 5 Wins

The fundamental insight: **git pull on a branch only brings that branch's
content**. This is the ONLY mechanism that prevents unwanted projects from
appearing on pull without resorting to sparse-checkout.

Path scoping (profile.yml) complements branches by controlling what gets
committed — preventing accidental staging of files that exist on disk but
don't belong to the profile.

Together, branches provide **read isolation** (pull only gets your content)
and profiles provide **write isolation** (sync only commits your content).

---

## 4. Profile Model — Design Decisions

### 4.1 Profiles Are Optional

**Decision**: Profiles are opt-in. Without profiles, vault works exactly
like today (everything on `main`, `push/pull` operates on `main`).

**Rationale**:
- Single-PC users (majority) don't need profiles
- Zero migration burden for existing vaults
- Progressive complexity: start simple, add profiles when needed
- `vault init` creates repo on `main`, no default profile

**Workflow**:
1. Start with everything on `main` (single PC, simple)
2. Get a second PC → create profiles, move exclusive resources off `main`
3. Each PC pushes/pulls its own profile branch + auto-syncs shared from `main`

### 4.2 Profile Configuration File

**Decision**: `.vault-profile` in `user-config/` root, **tracked** per branch.

A profile is NOT tied to a specific machine — it is a **work context**
(branch) that can be used on any machine. Any PC can checkout any profile.
The active profile is simply the current git branch.

**Why tracked (not gitignored)**: The profile definition must travel with the
branch. When switching profiles or cloning the vault on a new machine, the
configuration must be available. A gitignored machine-local file would not
survive branch operations or new clones.

**Why not `.cco-meta`**: `.cco-meta` tracks schema versions and file manifests
for the update system. Vault profiles are a separate concern (work context
vs. framework versioning). Mixing them would violate single-responsibility.

**Format**:
```yaml
# Vault profile — tracked on this branch
# Defines which resources are exclusive to this profile
profile: org-a
sync:
  projects:
    - org-a-api
    - org-a-frontend
  packs:
    - org-a-conventions
```

**Semantics**:
- `profile:` — name of the profile (= name of the git branch)
- `sync.projects:` — projects exclusive to this profile
- `sync.packs:` — packs exclusive to this profile
- `global/` and `templates/` are always shared (always on `main`)
- Packs NOT listed in any profile are shared (on `main`)
- Projects are ALWAYS exclusive (on a profile or on `main` if no profiles exist)
- Active profile = current git branch (determined by `git rev-parse --abbrev-ref HEAD`)
- `.vault-profile` only exists on profile branches, not on `main`

### 4.3 Resource Placement Rules

| Resource | No profiles | With profiles |
|---|---|---|
| `global/` | `main` | `main` (always shared) |
| `templates/` | `main` | `main` (always shared) |
| Pack (default) | `main` | `main` (shared) |
| Pack (exclusive) | N/A | Profile branch (listed in `sync.packs`) |
| Project (default) | `main` | Profile branch (listed in `sync.projects`) |
| `.gitignore` | `main` | `main` |
| `manifest.yml` | `main` | `main` |

**Key rule**: A resource lives either on `main` (shared with all profiles)
or on exactly ONE profile branch (exclusive). No resource on multiple profiles.

### 4.4 Profile Switching

**Decision**: Supported. Same PC can switch between profiles.

**Use case**: Single laptop used for both work and personal projects.
A profile is a work context, not a machine identity — any machine can
use any profile by switching to it.

**Mechanics**: `vault profile switch <name>` = auto-commit pending changes
on current branch + `git checkout <target-branch>`. The `.vault-profile`
file on the target branch provides the profile configuration automatically.

**What happens to files on disk**: Projects from the previous profile remain
as directories on disk (they are "real" directories created by `cco project
create`). They are simply not tracked on the new branch. `cco start <project>`
and `cco project list` work regardless of active profile.

### 4.5 Moving Resources Between Profiles

**Decision**: CLI support for moving projects and packs between profiles
and main.

**Same-machine moves**: Direct git operations (remove from source branch,
ensure present on target branch, update `.vault-profile`).

**Cross-machine moves**: Use `main` as intermediary. Move to `main` on PC-A,
pull on PC-B, move from `main` to profile on PC-B. Documented workflow,
no cross-machine automation. Alternatively, switch to the target profile on
the same machine, since profiles are not machine-specific.

**Safety**: `move --to <profile>` from `main` warns that other machines
without that profile will lose access on next pull.

---

## 5. Shared Resource Sync — Mechanics

### 5.1 The Sync Problem

Profile branches contain shared resources (global/, templates/, shared packs)
AND exclusive resources (profile projects/packs). When syncing shared resources
between profiles via `main`, we must:

1. Push profile's shared changes to `main` (so other profiles can pull them)
2. Pull `main`'s shared changes into profile (from other profiles' pushes)
3. Never leak exclusive resources to `main`
4. Never delete profile-exclusive resources when syncing from `main`

### 5.2 Why Full `git merge` Doesn't Work

A full `git merge origin/main` into a profile branch propagates deletions.
If a project was moved from `main` to a profile (deleted from `main`), merging
`main` into the profile would attempt to delete the project from the profile.
This is the opposite of what we want.

Similarly, merging a profile into `main` would bring exclusive resources
onto `main`, defeating the purpose of profiles.

### 5.3 Recommended Approach: Selective Sync with Interactive Conflict Resolution

**Push (profile → main, shared resources only)**:
1. Detect changed shared resource files vs. `origin/main`
2. Checkout `main`, pull latest
3. Copy shared resource files from profile branch via `git checkout <profile> -- <paths>`
4. If a file was also modified on `main` since last sync → interactive prompt
5. Commit and push `main`
6. Return to profile branch

**Pull (main → profile, shared resources only)**:
1. Pull profile branch from remote
2. Fetch latest `main`
3. Copy shared resource files from `origin/main` via `git checkout origin/main -- <paths>`
4. If a file was also modified locally → interactive prompt
5. Commit sync

**Interactive conflict resolution** (when both sides modified a shared file):
```
Shared resource conflict: global/.claude/CLAUDE.md
  Modified locally (profile 'work') AND on main

  [L] Keep local version
  [R] Keep remote (main) version
  [M] 3-way merge (may produce conflict markers)
  [D] Show diff

  Choice [L/R/M/D]:
```

The 3-way merge option uses `git merge-file` — the same infrastructure
implemented in Sprint 5b for `cco update --apply`.

**Non-TTY fallback**: Skip (no modifications, warning message). Same pattern
as `cco update --apply`.

### 5.4 Conflict Scenarios

| Scenario | Behavior |
|---|---|
| Only profile changed shared file | Push: update main. Pull: no-op |
| Only main changed shared file | Push: no-op. Pull: update profile |
| Both changed same shared file | Interactive prompt (L/R/M/D) |
| New shared file on main | Pull: add to profile |
| New shared file on profile | Push: add to main |
| Shared file deleted on main | Pull: prompt (delete local or keep?) |
| Shared file deleted on profile | Push: prompt (delete from main or keep?) |
| Exclusive resource changed | No sync (stays on profile branch only) |

### 5.5 Why Selective Checkout Over Full Merge

| Aspect | Full `git merge` | Selective checkout |
|---|---|---|
| Deletion propagation | Propagates (breaks profile exclusives) | No (only touches declared paths) |
| Merge conflicts | Standard git conflicts | Per-file interactive resolution |
| Complexity | Conceptually simple, practically broken | More code, but correct |
| Profile isolation | Violated by merge | Preserved |
| Reuse of 5b infra | No | Yes (`git merge-file`) |

---

## 6. Memory Architecture

### 6.1 Decision: Separate Memory from claude-state

**Current layout** (memory bundled with transcripts):
```
projects/<name>/claude-state/       ← gitignored (ALL contents)
├── memory/MEMORY.md
├── memory/<topic>.md
└── <session-transcripts>/
```

**New layout** (memory separated):
```
projects/<name>/
├── claude-state/                   ← gitignored (transcripts only)
│   └── <session-transcripts>/
├── memory/                         ← vault-tracked
│   ├── MEMORY.md
│   └── <topic>.md
└── .claude/                        ← vault-tracked
```

### 6.2 Docker Mount: Child Override

The memory directory requires a child bind mount that overrides a subdirectory
of the parent `claude-state` mount:

```yaml
# Parent: maps entire claude-state to Claude Code's project directory
- ./claude-state:/home/claude/.claude/projects/-workspace
# Child: overrides the memory subdirectory with a separate host directory
- ./memory:/home/claude/.claude/projects/-workspace/memory
```

**Precedent**: This pattern is already used in cco for pack resource mounts.
Individual pack files are mounted on top of `/workspace/.claude/` (the project
`.claude` directory). Docker's mount precedence rule guarantees that child
mounts take priority over parent mounts.

**Behavior**:
- Reads from `~/.../-workspace/memory/` go to `./memory/` on host
- Writes to `~/.../-workspace/memory/` go to `./memory/` on host
- `./claude-state/memory/` still exists on disk but is shadowed (invisible inside container)

**Validation required**: Test that Claude Code correctly reads/writes
MEMORY.md through the child mount override. The mount mechanism is
well-understood (Linux kernel VFS), but Claude Code's internal path
resolution should be validated with an E2E test.

### 6.3 Vault Tracking

After separation:
- `projects/*/claude-state/` → stays gitignored (transcripts, large, personal)
- `projects/*/memory/` → NOT gitignored → vault-tracked
- Memory syncs with the project's profile branch (or main if no profiles)

### 6.4 Publish/Install Exclusion

Memory is personal (per-user working notes). It is excluded from
`cco project publish` and `cco project install`:
- Publish: does not include `memory/` directory
- Install: does not create `memory/` from remote (only `.claude/`, `project.yml`, etc.)

Memory is created by `cco project create` (local project setup).

### 6.5 Why Not Split memory/user + memory/project

**Evaluated and deferred**. The proposal to split memory into `user/`
(personal) and `project/` (shareable via publish) was analyzed:

- **Cost**: Claude Code writes to `memory/` as a flat directory. Routing
  writes to subdirectories requires managed rules with runtime classification.
  Risk of misclassification. Adds mount complexity.
- **Benefit**: `project/` memory could be shared via publish.
- **Mitigation**: The memory policy (§7) already directs project knowledge
  to docs/rules (shareable) and reserves memory for personal notes (not
  shareable). The split adds complexity without clear benefit when the
  policy is followed.
- **Decision**: Single `memory/` directory. Revisit if a clear use case
  for shared memory emerges.

---

## 7. Memory Policy

### 7.1 Decision: Memory Policy Is Core (Managed Level)

**Not opinionated**: The memory policy is not a user preference — it is a
fundamental mechanism that ensures:
- Vault sharing works correctly (personal notes in memory, not docs)
- Knowledge persists across machines (important info in docs, not memory)
- Project publish shares the right content (docs, not personal notes)

**Implementation**: `defaults/managed/.claude/rules/memory-policy.md`
(baked into Docker image at `/etc/claude-code/.claude/rules/`).
Non-overridable by users — this is framework behavior, not a suggestion.

### 7.2 Policy Definition

**Use `MEMORY.md` for:**
- Session-specific working notes (scratch pad for the current task)
- Sprint/task progress tracking ("Sprint 7 in progress, #A done, #B pending")
- Personal interaction preferences for this project
- Self-improvement feedback received from the user
- Short-lived context ("we're mid-refactor, skip X for now")
- Observations about tools or model behavior

**Use project docs (`.claude/`, `docs/`, `.claude/rules/`) for:**
- Architecture decisions and rationale (ADRs, design docs)
- Learned code patterns that future sessions should know
- Conventions, naming rules, style guides → `.claude/rules/`
- "Always do X when working on Y" rules → `.claude/rules/`
- Gotchas, known issues, workarounds
- Configuration reference, API docs

**Key distinction**: Memory is **per-user, transient, vault-synced**.
Docs are **per-project, persistent, repo-committed**.

### 7.3 Documentation File Precedence

When the user has defined documentation files or structures for a specific
purpose (e.g., `docs/roadmap.md`, `docs/maintainer/decisions/`), those
files **always take precedence** over memory for that type of information.

- If `docs/roadmap.md` exists → update the roadmap there, not in memory
- If `.claude/rules/` has conventions → don't duplicate in memory
- Memory can supplement docs with personal annotations, task checklists,
  or sprint-specific details that don't belong in the project's permanent
  documentation structure

The rule: **docs define the canonical location; memory is the overflow
for transient, personal, or in-progress notes**.

### 7.4 Open Question: Rules and Config User-Ownership

The memory policy directs persistent knowledge to `.claude/rules/` and
project docs. However, rules, agents, skills, and other config files are
**user-configured** resources. Claude should respect and execute them,
not modify them without explicit user approval.

This raises a broader question: **what is the permission model for Claude
modifying user config?** The memory policy says "move knowledge to rules"
but rules are user-owned. This needs a separate analysis:

- Should Claude propose rule changes (via diff/suggestion) rather than
  writing directly?
- Should there be a managed-level guard preventing silent rule modifications?
- How does this interact with the update system's "user-owned after install"
  principle?

**Decision**: Annotate as a future design topic (roadmap). For Sprint 7,
the memory policy states that persistent knowledge SHOULD go to docs/rules,
but does not define the permission model for Claude writing to those files.
The user's existing workflow (explicit approval before changes) remains the
default behavior.

### 7.5 Memory Maintenance

Memory must be kept current. Stale entries (completed sprints, resolved
issues, outdated context) should be removed or archived. The managed rule
should instruct Claude to:

- Review memory at session start (already happens — first 200 lines loaded)
- Remove completed/stale entries proactively
- Move important discoveries to docs/rules when they become persistent knowledge

### 7.6 Integration Points

| Component | Change |
|---|---|
| `defaults/managed/.claude/rules/memory-policy.md` | New file: policy rules (non-overridable) |
| `defaults/managed/.claude/skills/init-workspace/SKILL.md` | Add guidance on memory vs. docs classification |
| `defaults/managed/CLAUDE.md` | Add reference to memory policy |

---

## 8. Resource Tracking Matrix

Complete mapping of every resource type to its vault, sync, and sharing behavior.

| Resource | In vault? | Branch (no profiles) | Branch (with profiles) | Publish/Install | Notes |
|---|---|---|---|---|---|
| `global/.claude/CLAUDE.md` | Yes | main | main (always) | No | Opinionated, user-owned |
| `global/.claude/settings.json` | Yes | main | main | No | User-owned |
| `global/.claude/rules/*.md` | Yes | main | main | No | User-owned |
| `global/.claude/agents/*.md` | Yes | main | main | No | User-owned |
| `global/.claude/skills/` | Yes | main | main | No | User-owned |
| `global/.claude/mcp.json` | Yes | main | main | No | User-owned |
| `global/.claude/.cco-meta` | Yes | main | main | No | Schema tracking |
| `global/.claude/.cco-base/` | Yes | main | main | No | Merge ancestors |
| `global/setup.sh` | Yes | main | main | No | Runtime setup |
| `global/setup-build.sh` | Yes | main | main | No | Build-time setup |
| `global/claude-state/` | **No** | — | — | No | Credentials, session metadata |
| `templates/*/` | Yes | main | main (always) | Via manifest | Shared templates |
| `packs/<name>/` (shared) | Yes | main | main | Via manifest | Default: shared |
| `packs/<name>/` (exclusive) | Yes | main | profile branch | Via manifest | Listed in .vault-profile |
| `packs/<name>/.cco-meta` | Yes | with pack | with pack | No | Schema tracking |
| `packs/<name>/.cco-source` | Yes | with pack | with pack | No | Origin tracking |
| `projects/<name>/.claude/` | Yes | main | profile branch | Yes (publish) | Project context |
| `projects/<name>/project.yml` | Yes | main | profile branch | Yes (publish) | Project config |
| `projects/<name>/memory/` | **Yes** | main | profile branch | **No** | NEW: separated from claude-state |
| `projects/<name>/claude-state/` | **No** | — | — | No | Transcripts only |
| `projects/<name>/.cco-source` | Yes | main | profile branch | No | Origin tracking |
| `projects/<name>/.cco-meta` | **No** | — | — | No | Gitignored |
| `projects/<name>/docker-compose.yml` | **No** | — | — | No | Generated |
| `projects/<name>/.managed/` | **No** | — | — | No | Runtime generated |
| `projects/<name>/setup.sh` | Yes | main | profile branch | Yes (publish) | Copy-if-missing |
| `projects/<name>/secrets.env` | **No** | — | — | No | Secret |
| `projects/<name>/mcp-packages.txt` | Yes | main | profile branch | Yes (publish) | Copy-if-missing |
| `manifest.yml` | Yes | main | main | N/A | Sharing manifest |
| `.vault-profile` | Yes | — | profile branch | No | Profile metadata (tracked per branch) |
| `.cco-remotes` | **No** | — | — | No | Machine-local tokens |
| `.gitignore` | Yes | main | main | No | Vault structure |

---

## 9. Non-Negotiable Design Decisions

**D1 — Profiles are optional**: Vault without profiles works exactly like
today. Profiles are opt-in for multi-PC users.

**D2 — Branch + path scoping**: Each profile = git branch + path declaration
in `.vault-profile` (tracked per branch). This is the only approach that
provides both read isolation (pull) and write isolation (push).

**D3 — No `git merge` for shared sync**: Shared resources are synced via
selective checkout with interactive conflict resolution, not full git merge.
Full merge propagates deletions and breaks profile exclusivity.

**D4 — Interactive conflict resolution**: When both sides modify a shared
file, user chooses: keep local, keep remote, 3-way merge, or show diff.
Reuses Sprint 5b's `git merge-file` infrastructure.

**D5 — Memory separated from claude-state**: `memory/` is a standalone
directory with its own bind mount. Vault-tracked. `claude-state/` contains
only transcripts (gitignored).

**D6 — Memory policy at managed level**: Not opinionated. Core framework
behavior that ensures correct vault/sharing/persistence semantics.

**D7 — Memory excluded from publish**: Memory is per-user. Project
publish/install does not include `memory/`.

**D8 — Single memory directory**: No user/project split. Memory policy
directs shared knowledge to docs, personal notes to memory.

**D9 — A resource lives on main OR one profile**: No resource on multiple
profiles. This simplifies the model and prevents sync conflicts.

**D10 — Global and templates always shared**: `global/` and `templates/`
are always on `main`. Only projects and packs can be profile-exclusive.

**D11 — Profiles are work contexts, not machine identities**: Any PC can
use any profile by switching to it. Profile switching is supported via CLI.

**D12 — Global always shared**: `global/` is always on `main`, shared across
all profiles. Profile-specific conventions are handled via packs (the
designated mechanism for sharing resources among a subset of projects),
not via per-profile global config.

---

## 10. Questions Resolved

| # | Question (from analysis v1) | Resolution |
|---|---|---|
| 1 | `vault.yml` or `.cco-meta` for profiles? | `.vault-profile` — tracked per branch, separate concern from schema versioning |
| 2 | How does sync handle untracked projects? | `vault sync` only stages paths declared in profile |
| 3 | Separate `--global` flag on pull? | No — shared sync is automatic on every push/pull |
| 4 | Does bind-mount override work? | Pattern confirmed by existing pack mounts; E2E test required |
| 5 | Interactive profile setup or separate subcommand? | `cco vault profile create` — dedicated subcommand |
| 6 | Branch names: hostname or user-specified? | User-specified — hostname is fragile and not meaningful |

---

## 11. Deferred Items

### 11.1 Vault Branch Strategy (Phase 2 — from original analysis)

The original analysis proposed a Phase 2 with per-machine branches
and `cco vault pull --global`. This is now the CORE approach, not
a future phase. There is no separate Phase 2.

### 11.2 Memory user/project Split

Evaluated and deferred (§6.5). Revisit if a clear use case for shared
memory in project publish emerges.

### 11.3 Session Resume (`cco attach`)

Unrelated to Sprint 7. Remains in Long-term/Exploratory (roadmap).
