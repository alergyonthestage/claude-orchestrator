# Sprint 7-Vault — Design: Multi-PC Sync, Memory Architecture & Policy

> **STATUS: PARTIALLY SUPERSEDED** — The tracking-only isolation model described
> in §5.3 and the selective-staging sync mechanics in §4 have been replaced by
> real git-level isolation. See `profile-isolation-design.md` for the current
> design. Memory architecture (§6) and memory policy (§7) remain current.

**Status**: Implemented — Sprint 7-Vault complete
**Date**: 2026-03-14
**Scope**: Architecture-level
**Analysis**: `analysis.md` (same directory)

> This document is the authoritative reference for Sprint 7-Vault implementation.
> It covers vault profiles, shared resource sync, memory separation, and memory
> policy. All design decisions are justified in the analysis document.

---

## 1. Overview

Sprint 7-Vault delivers three interconnected components:

| # | Component | Type | Scope |
|---|---|---|---|
| **#A** | Vault Profile-Based Selective Sync | Code | CLI, vault, git |
| **#B** | Memory Policy | Managed rule | Framework behavior |
| **#C** | Memory Vaulting | Code | Mounts, vault, migration |

### 1.1 Design Principles

1. **Progressive complexity**: no profiles → single-PC vault works unchanged
2. **Branch isolation**: profiles provide read+write isolation via git branches
3. **Selective sync**: shared resources flow through `main`, never full `git merge`
4. **Memory is core**: policy at managed level, memory vault-tracked
5. **Reuse Sprint 5b**: `git merge-file` for conflict resolution

---

## 2. Data Model

### 2.1 Profile Configuration — `.vault-profile`

**Location**: `user-config/.vault-profile`
**Tracked**: Yes — committed on each profile branch
**Created by**: `cco vault profile create <name>`
**Exists on**: Profile branches only (not on `main`)

A profile is a **work context** (e.g., org-A, personal, freelance), not a
machine identity. Any machine can use any profile by switching to it.

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

**Fields**:

| Field | Type | Required | Description |
|---|---|---|---|
| `profile` | string | Yes | Profile name (= git branch name) |
| `sync.projects` | list | Yes | Projects exclusive to this profile |
| `sync.packs` | list | No | Packs exclusive to this profile (default: `[]`) |

**Active profile detection**: The active profile is the current git branch.
If `.vault-profile` exists on the current branch → profile mode is active.
If not (i.e., on `main`) → no profile, vault works as today.

```bash
_get_active_profile() {
    local branch
    branch=$(git -C "$USER_CONFIG_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)
    local profile_file="$USER_CONFIG_DIR/.vault-profile"
    if [[ "$branch" != "main" ]] && [[ -f "$profile_file" ]]; then
        _yml_get "$profile_file" "profile"
    fi
}
```

**Implicit shared resources** (always on `main`, not listed):
- `global/` — always shared
- `templates/` — always shared
- Packs not listed in any profile's `sync.packs` — shared by default
- `manifest.yml`, `.gitignore` — always on `main`

### 2.2 Branch Structure

**Without profiles** (backward compatible):
```
main ← everything, single branch, push/pull as today
```

**With profiles**:
```
main                    ← shared resources only (global, templates, shared packs)
├── org-a               ← shared + org-a-exclusive (projects, packs)
└── personal            ← shared + personal-exclusive (projects, packs)
```

Profile branches are created from `main`. They contain a SUPERSET of `main`
(shared resources + exclusive resources).

### 2.3 Vault .gitignore Updates

No new gitignore entries needed for profiles. `.vault-profile` is **tracked**
(committed on each profile branch), not gitignored.

Note: `projects/*/memory/` is NOT gitignored (intentionally tracked).
The existing `projects/*/.cco/claude-state/` pattern stays (transcripts only).

---

## 3. CLI Commands

### 3.1 Profile Management

```bash
# List all profiles (shows branches that have corresponding profile.yml config)
cco vault profile list

# Show current profile details
cco vault profile show

# Create a new profile (creates branch from main, writes profile.yml)
cco vault profile create <name>

# Switch to another profile (auto-commits, switches branch, updates profile.yml)
cco vault profile switch <name>

# Rename current profile (renames branch + updates profile.yml)
cco vault profile rename <new-name>

# Delete a profile (moves exclusive resources to main first, deletes branch)
cco vault profile delete <name>
```

### 3.2 Resource Movement

```bash
# Mark project as exclusive to a profile (tracking-only)
cco vault profile move project <name> --to <profile>

# Make project shared again (remove from profile tracking)
cco vault profile move project <name> --to main

# Mark pack as exclusive to a profile (tracking-only)
cco vault profile move pack <name> --to <profile>

# Make pack shared again (remove from profile tracking)
cco vault profile move pack <name> --to main
```

### 3.3 Quick Add/Remove (Current Profile)

```bash
# Mark project as exclusive to current profile (tracking-only)
cco vault profile add project <name>

# Make project shared again (removes from profile tracking)
cco vault profile remove project <name>

# Mark pack as exclusive to current profile (tracking-only)
cco vault profile add pack <name>

# Make pack shared again (removes from profile tracking)
cco vault profile remove pack <name>
```

> **Note**: `add` and `remove` update `.vault-profile` only — they do not
> `git rm` files from any branch. Isolation is enforced at sync time via
> selective staging.

### 3.4 Create with Profile

```bash
# Create project directly in a profile
cco project create <name> --profile <profile>

# Create pack directly in a profile
cco pack create <name> --profile <profile>
```

These call the standard create flow and then immediately move the resource
to the specified profile branch.

### 3.5 Modified Existing Commands

| Command | Change |
|---|---|
| `cco vault sync [msg]` | With profile: stages only profile paths. Without: stages all (backward compat) |
| `cco vault push [remote]` | With profile: pushes profile branch + auto-syncs shared to main |
| `cco vault pull [remote]` | With profile: pulls profile branch + syncs shared from main |
| `cco vault status` | Shows profile info, sync state with main, exclusive resources |
| `cco vault diff` | With profile: shows only profile-scoped changes |

---

## 4. Vault Sync Mechanics

### 4.1 `vault sync` — Staging Logic

**Without profile** (on `main`, no `.vault-profile`):
```bash
git -C "$vault_dir" add -A
git -C "$vault_dir" commit -m "vault: $message"
```
Identical to current behavior.

**With profile** (on a profile branch, `.vault-profile` exists):
```bash
# Read profile configuration
local profile_projects=($(_yml_get_list "$VAULT_PROFILE_FILE" "sync.projects"))
local profile_packs=($(_yml_get_list "$VAULT_PROFILE_FILE" "sync.packs"))

# Build list of paths to stage
local paths=()

# Shared resources (always staged)
paths+=("global/" "templates/" ".gitignore" "manifest.yml" ".vault-profile")

# Shared packs (not in profile's exclusive list)
for pack_dir in packs/*/; do
    pack_name=$(basename "$pack_dir")
    if ! _array_contains "$pack_name" "${profile_packs[@]+"${profile_packs[@]}"}"; then
        paths+=("packs/$pack_name/")
    fi
done

# Profile-exclusive resources
for project in "${profile_projects[@]}"; do
    paths+=("projects/$project/")
done
for pack in "${profile_packs[@]}"; do
    paths+=("packs/$pack/")
done

# Stage only declared paths (additions, modifications, deletions)
git -C "$vault_dir" add -A -- "${paths[@]}"
git -C "$vault_dir" commit -m "vault: $message"
```

The `git add -A -- <paths>` syntax stages all changes (additions, modifications,
deletions) within the specified paths only. Files outside these paths are
not staged.

### 4.2 `vault push` — Profile Branch + Shared Sync

```
Step 1: Push profile branch
    git push -u origin $profile_branch

Step 2: Detect shared resource changes
    Compare profile branch vs origin/main for shared paths:
    git diff origin/main --name-only -- global/ templates/ packs/<shared>/

Step 3: If shared resources changed → sync to main
    3a. Stash any uncommitted work
    3b. git checkout main
    3c. git pull origin main (get latest main)
    3d. For each changed shared file:
        - If file changed only on profile → copy from profile (git checkout $profile -- $file)
        - If file changed only on main → keep main's version (no action)
        - If file changed on BOTH → interactive prompt (L/R/M/D)
    3e. git commit -m "sync: shared resources from $profile"
    3f. git push origin main
    3g. git checkout $profile_branch
    3h. git stash pop (if stashed)

Step 4: Output summary
    "✓ Pushed profile 'work'"
    "✓ Shared resources synced to main (2 files updated)"
```

**Without profile**: `git push -u origin main` (current behavior).

### 4.3 `vault pull` — Profile Branch + Shared Sync

```
Step 1: Fetch all
    git fetch origin

Step 2: Pull profile branch
    git pull origin $profile_branch

Step 3: Sync shared resources from main
    Compare local shared paths vs origin/main:
    git diff HEAD origin/main --name-only -- global/ templates/ packs/<shared>/

Step 4: For each changed shared file:
    - If file changed only on main → copy from main (git checkout origin/main -- $file)
    - If file changed only locally → keep local (no action)
    - If file changed on BOTH → interactive prompt (L/R/M/D)

Step 5: Commit sync
    git add -A -- global/ templates/ packs/<shared>/
    git commit -m "sync: shared resources from main"

Step 6: Output summary
    "✓ Pulled profile 'work'"
    "✓ Synced 3 shared resources from main"
    "  New shared pack 'team-utils' synced from main"
```

**Without profile**: `git pull origin main` (current behavior).

### 4.4 Interactive Conflict Resolution

When both sides modified a shared file, the user is prompted:

```
Shared resource conflict: global/.claude/CLAUDE.md
  Modified locally AND on main

  [L] Keep local version
  [R] Keep remote (main) version
  [M] 3-way merge (may produce conflict markers)
  [D] Show diff

  Choice [L/R/M/D]:
```

**Implementation**:
- `[L]` → no action (keep local file as-is)
- `[R]` → `git checkout origin/main -- $file`
- `[M]` → 3-way merge using `git merge-file`:
  ```bash
  # Find common ancestor
  base_commit=$(git merge-base HEAD origin/main)
  git show "$base_commit:$file" > "$tmpdir/base"
  git show "origin/main:$file" > "$tmpdir/theirs"
  git merge-file "$file" "$tmpdir/base" "$tmpdir/theirs"
  ```
  If merge produces conflict markers → warn user, file saved with markers.
- `[D]` → `diff "$file" <(git show "origin/main:$file")`, then re-prompt

**Non-TTY fallback**: Skip (no modifications), print warning:
```
⚠ Shared resource conflict in global/.claude/CLAUDE.md — skipped (non-interactive)
  Run 'cco vault pull' interactively to resolve
```

### 4.5 Determining Shared vs. Exclusive Packs

A pack is **exclusive** if it appears in `.vault-profile`'s `sync.packs` list.
All other packs are **shared** (on `main`).

The command reads only the current branch's `.vault-profile`. It does NOT need
to know other profiles' configurations — it only needs to know which packs
this profile owns exclusively.

```bash
_list_shared_pack_paths() {
    local exclusive_packs=()
    if [[ -f "$VAULT_PROFILE_FILE" ]]; then
        exclusive_packs=($(_yml_get_list "$VAULT_PROFILE_FILE" "sync.packs"))
    fi

    for pack_dir in "$USER_CONFIG_DIR"/packs/*/; do
        local pack_name=$(basename "$pack_dir")
        if ! _array_contains "$pack_name" \
             "${exclusive_packs[@]+"${exclusive_packs[@]}"}"; then
            echo "packs/$pack_name/"
        fi
    done
}
```

---

## 5. Profile Management — Detailed Flows

### 5.1 `vault profile create <name>`

```
Preconditions:
  - Vault initialized (git repo exists)
  - Profile name is valid (lowercase, hyphens, no spaces)
  - No existing branch with this name

Steps:
  1. Auto-commit any pending changes on current branch
  2. Create branch from main: git checkout -b <name> main
  3. Write .vault-profile:
     profile: <name>
     sync:
       projects: []
       packs: []
  4. Commit .vault-profile: "vault: create profile '<name>'"
  5. Output: "✓ Profile '<name>' created. Use 'cco vault profile add' to add resources."
```

### 5.2 `vault profile switch <name>`

```
Preconditions:
  - Target profile branch exists
  - Target profile is different from current

Steps:
  1. Auto-commit any pending changes (vault sync --yes "auto-save before switch")
  2. git checkout <name>
  3. Output: "✓ Switched to profile '<name>'"
```

Since `.vault-profile` is **tracked per branch**, it automatically changes
with the branch checkout. No regeneration or extra file management needed.
This is the key advantage of using a tracked file over a gitignored one.

### 5.3 `vault profile move project <name> --to <target>`

> **Implementation note**: The actual implementation uses **tracking-only** isolation
> rather than the original git-level move design described in the initial draft.
> Resources are NOT `git rm`-ed from the source branch. Instead, `.vault-profile`
> is updated to declare which resources are exclusive to each profile, and isolation
> is enforced at sync time via selective staging (`vault sync`, `vault push`, `vault pull`
> scope their `git add` to the profile's declared paths only).

**Move project to a profile (tracking-only):**
```
Preconditions:
  - Project directory exists: projects/<name>/
  - Target is a valid profile name or "main"

Steps:
  1. If currently on a profile, switch to target profile branch
  2. Update .vault-profile: add project to sync.projects list
  3. Stage .vault-profile and the project directory
  4. Commit: "vault: add project '<name>' to profile '<target>'"
  5. Return to original branch if needed
```

**Move project back to main (tracking-only):**
```
Steps:
  1. Update .vault-profile: remove project from sync.projects list
  2. Stage .vault-profile
  3. Commit: "vault: remove project '<name>' from profile"
  4. The project is now shared (synced to main at next push)
```

**Move between profiles:**
```
Steps:
  1. Remove from source profile's .vault-profile
  2. Add to target profile's .vault-profile
  3. Net effect: resource tracked under new profile, isolation enforced at sync time
```

### 5.4 `vault profile rename <new-name>`

```
Steps:
  1. Rename git branch: git branch -m <old> <new>
  2. Update .vault-profile: profile: <new-name>
  3. Commit: "vault: rename profile '<old>' to '<new>'"
  4. If remote exists: git push origin :<old> && git push -u origin <new>
```

### 5.5 `vault profile delete <name>`

```
Steps:
  1. Cannot delete current profile (must switch first)
  2. Warn: "All exclusive resources will be moved to main. Continue? [y/N]"
  3. Move all exclusive projects and packs to main
  4. Delete branch: git branch -D <name>
  5. If remote: git push origin --delete <name>
```

### 5.6 `vault profile list`

```
Output:
  Vault profiles:
    * work (active)          3 projects, 1 pack
      home                   2 projects, 0 packs
    Main (shared):           global, templates, 5 packs
```

### 5.7 `vault profile show`

```
Output:
  Profile: work
  Branch: work
  Sync state: up-to-date with main

  Exclusive projects:
    - work-api
    - work-frontend
    - internal-tools

  Exclusive packs:
    - corporate-rules

  Shared (from main):
    - global/
    - templates/ (2 templates)
    - packs/ (5 shared packs)

  Uncommitted changes: 3 files
```

### 5.8 `vault status` (Enhanced)

**Without profile** (current behavior + enhancements):
```
Vault: initialized
Branch: main
Remote: origin → git@github.com:user/cco-config.git
Commits: 42
Uncommitted: 3 files
```

**With profile**:
```
Vault: initialized
Profile: work (branch: work)
Remote: origin → git@github.com:user/cco-config.git
Shared sync: up-to-date with main
Exclusive: 3 projects, 1 pack
Commits: 42
Uncommitted: 3 files
```

---

## 6. Memory Separation — Implementation

### 6.1 New Directory Structure

**Before** (current):
```
user-config/projects/<name>/
├── claude-state/
│   ├── memory/
│   │   ├── MEMORY.md
│   │   └── <topic>.md
│   └── <session-transcripts>/
└── .claude/
```

**After**:
```
user-config/projects/<name>/
├── claude-state/                   ← gitignored (transcripts only)
│   └── <session-transcripts>/
├── memory/                         ← vault-tracked (NEW location)
│   ├── MEMORY.md
│   └── <topic>.md
└── .claude/
```

### 6.2 Docker Compose Volume Mounts

**Current** (in `lib/cmd-start.sh`):
```yaml
- ./claude-state:/home/claude/.claude/projects/-workspace
```

**New** (add child mount):
```yaml
# Claude state: session transcripts (enables /resume across rebuilds)
- ./claude-state:/home/claude/.claude/projects/-workspace
# Memory: auto memory files (vault-tracked, separate from transcripts)
- ./memory:/home/claude/.claude/projects/-workspace/memory
```

The child mount (`memory`) overrides the `memory/` subdirectory within
the parent mount (`claude-state`). Docker's mount precedence guarantees
the child mount takes priority.

### 6.3 Changes to `cmd-start.sh`

```bash
# After the claude-state mount line, add:
echo "      - ./memory:/home/claude/.claude/projects/-workspace/memory"
```

Also update the directory creation:
```bash
# Existing
mkdir -p "$project_dir/claude-state"
# New
mkdir -p "$project_dir/memory"
```

### 6.4 Changes to `cmd-project-create.sh` (Project Create)

Replace:
```bash
mkdir -p "$project_dir/claude-state/memory"
```

With:
```bash
mkdir -p "$project_dir/claude-state"
mkdir -p "$project_dir/memory"
```

### 6.5 Migration — Project Scope

**File**: `migrations/project/008_separate_memory.sh`

```bash
MIGRATION_ID=8
MIGRATION_DESC="Separate memory from claude-state for vault tracking"

migrate() {
    local target_dir="$1"
    local memory_dst="$target_dir/memory"
    local memory_src="$target_dir/claude-state/memory"

    # Already migrated
    [[ -d "$memory_dst" ]] && return 0

    # Move memory from claude-state to project root
    if [[ -d "$memory_src" ]] && [[ -n "$(ls -A "$memory_src" 2>/dev/null)" ]]; then
        cp -r "$memory_src" "$memory_dst"
        # Don't delete source — it will be shadowed by the new mount
        # Keeping it prevents data loss if user runs old cco version
    else
        mkdir -p "$memory_dst"
    fi

    return 0
}
```

**Idempotency**: checks if `memory/` already exists at target.
**Safety**: copies (not moves) from `claude-state/memory/`. Old directory
stays as fallback. Shadowed by mount at runtime.

### 6.6 Vault .gitignore — No Changes Needed

Current `.gitignore` already has:
```
projects/*/.cco/claude-state/
```

This covers `claude-state/` (including the old `memory/` subdirectory).
The new `projects/*/memory/` is NOT matched by any pattern → automatically
vault-tracked. Correct behavior.

### 6.7 Publish/Install Exclusion

**`lib/cmd-project-publish.sh` — publish flow**: Exclude `memory/` from the
published archive. Add to the exclude list alongside `.cco/claude-state/`,
`.cco/docker-compose.yml`, `.cco/managed/`, `.tmp/`.

**`lib/cmd-project-install.sh` — install flow**: Do not create `memory/` from
remote templates. Memory is created by `cco project create` only.

---

## 7. Memory Policy — Managed Rule

### 7.1 New File: `defaults/managed/.claude/rules/memory-policy.md`

This file is baked into the Docker image at
`/etc/claude-code/.claude/rules/memory-policy.md`. Non-overridable.

```markdown
# Memory vs. Documentation Policy

## When to use MEMORY.md

Write to memory (`~/.claude/projects/-workspace/memory/`) for:
- Session-specific working notes and scratch pad
- Sprint or task progress tracking (e.g., "Sprint 7: #A done, #B in progress")
- Personal interaction preferences for this project
- Self-improvement feedback received from the user
- Short-lived context (e.g., "mid-refactor, skip module X for now")
- Observations about tools or model behavior

Memory is personal, machine-synced via vault, and NOT shared when projects
are published. Treat it as a private notebook.

## When to use project documentation

Write to project docs (`.claude/CLAUDE.md`, `.claude/rules/`, `docs/`) for:
- Architecture decisions and rationale
- Learned code patterns that future sessions should know
- Conventions, naming rules, style guides → `.claude/rules/<topic>.md`
- "Always do X when working on Y" rules → `.claude/rules/`
- Gotchas, known issues, workarounds
- API reference, configuration docs

Documentation is per-project, persistent, and shared when projects are
published. Treat it as the project's permanent knowledge base.

## Key distinction

- **Memory** = per-user, transient, vault-synced, never published
- **Docs** = per-project, persistent, repo-committed, shareable

## Documentation file precedence

When the user has defined documentation files for a specific purpose
(e.g., `docs/roadmap.md`, `docs/maintainer/decisions/`), those files
ALWAYS take precedence over memory for that type of information.

- If `docs/roadmap.md` exists → update the roadmap there, not in memory
- If `.claude/rules/` has conventions → don't duplicate in memory
- Memory can supplement docs with personal annotations, task checklists,
  or sprint-specific working notes that don't belong in permanent docs

Rule: docs define the canonical location; memory is the overflow for
transient, personal, or in-progress notes.

## User-owned config files

Rules (`.claude/rules/`), agents, skills, and other config files are
user-configured resources. Do NOT modify them without explicit user
approval. When the memory policy says "move knowledge to rules," this
means proposing the change to the user, not writing directly.

## Memory maintenance

- Review memory entries at the start of each session
- Remove completed tasks, resolved issues, and outdated context
- When a memory entry becomes permanent knowledge, propose moving it
  to docs/rules (with user approval)
- Keep MEMORY.md under 200 lines (only the first 200 are auto-loaded)
```

### 7.2 Directory Creation

The `defaults/managed/.claude/rules/` directory does not currently exist.
It must be created in the source tree:

```
defaults/managed/
├── CLAUDE.md
├── managed-settings.json
└── .claude/
    ├── rules/                          ← NEW directory
    │   └── memory-policy.md            ← NEW file
    └── skills/
        └── init-workspace/
            └── SKILL.md
```

**Dockerfile**: The existing `COPY defaults/managed/ /etc/claude-code/`
already copies the entire `managed/` tree. No Dockerfile changes needed.

### 7.3 Updates to `defaults/managed/CLAUDE.md`

Add a reference to the memory policy:

```markdown
## Memory Policy
- A managed rule (`memory-policy.md`) defines when to use MEMORY.md vs project docs
- Memory is personal and transient — use docs for persistent project knowledge
- See `.claude/rules/memory-policy.md` for the complete policy
```

### 7.4 Updates to init-workspace Skill

Add guidance to Step 5 (Write CLAUDE.md) in `SKILL.md`:

```markdown
When generating the CLAUDE.md, do NOT include memory-related content.
Memory policy is enforced by the managed rule `memory-policy.md`.
If you discover important patterns or conventions during exploration,
write them to `.claude/rules/` or the CLAUDE.md — not to memory.
```

---

## 8. Migration Plan

### 8.1 Project Migration: Memory Separation

**Scope**: project
**File**: `migrations/project/008_separate_memory.sh`
**Trigger**: `cco update` (automatic when `schema_version < 8`)

Copies `claude-state/memory/` to `projects/<name>/memory/`. Idempotent.
See §6.5 for full implementation.

### 8.2 No Vault Profile Migration

Profiles are optional. Existing vaults stay on `main` with no profile.
`.vault-profile` is tracked (not gitignored), so no gitignore migration needed.
Users create profiles on-demand.

### 8.3 Migration Order

1. Project migration 008 (memory separation) — per project

Runs automatically via `cco update`.

---

## 9. Updated Vault .gitignore Template

For new `vault init` operations, the `.gitignore` template is updated:

```gitignore
# Secrets — never committed
secrets.env
*.env
.credentials.json
*.key
*.pem

# Runtime files — generated, not user config
projects/*/.cco/docker-compose.yml
projects/*/.cco/managed/
projects/*/.tmp/
projects/*/.claude/.cco/pack-manifest
projects/*/.cco/meta

# Session state — transient, large, personal
global/claude-state/
projects/*/.cco/claude-state/
projects/*/rag-data/

# Pack install temporary files
packs/*/.cco/install-tmp/

# Machine-specific config
.cco/remotes
```

Changes from current template:
- None for profiles (`.vault-profile` is tracked, not gitignored)

Note: `projects/*/memory/` is intentionally NOT listed (vault-tracked).

---

## 10. Error Handling

### 10.1 Profile Operations

| Error | Behavior |
|---|---|
| Profile name invalid (spaces, uppercase) | Error with naming rules |
| Profile already exists | Error: "Profile 'X' already exists" |
| Switch to non-existent profile | Error: "Profile 'X' not found. Available: ..." |
| Move project that doesn't exist | Error: "Project 'X' not found in projects/" |
| Move to self (already on target) | No-op with message: "Project 'X' is already on '<target>'" |
| Delete current profile | Error: "Cannot delete active profile. Switch first." |
| Move to non-existent profile | Error: "Profile 'X' not found" |

### 10.2 Sync Conflicts

| Error | Behavior |
|---|---|
| Non-TTY during conflict | Skip: "⚠ Conflict in X — skipped (non-interactive)" |
| Push fails (remote rejected) | Standard git error, suggest `vault pull` first |
| Pull fails (merge conflict) | Show conflicting files, instructions to resolve |
| Main branch doesn't exist on remote | Create it: `git push -u origin main` |
| Stash fails before branch switch | Error: commit changes first |

### 10.3 Memory Mount

| Error | Behavior |
|---|---|
| memory/ directory missing | Created by `cco start` (mkdir -p) |
| Claude Code path resolution fails | Fallback: memory writes to claude-state/memory/ (parent mount) |

---

## 11. Implementation Checklist

**Status**: All phases implemented as part of Sprint 7-Vault.

### Phase 1: Memory (#B + #C) — Implemented
- [x] Create `defaults/managed/.claude/rules/memory-policy.md`
- [x] Update `defaults/managed/CLAUDE.md` with memory policy reference
- [x] Update `defaults/managed/.claude/skills/init-workspace/SKILL.md`
- [x] Create `migrations/project/008_separate_memory.sh`
- [x] Update `lib/cmd-start.sh`: add memory child mount
- [x] Update `lib/cmd-project-create.sh`: create `memory/` instead of `claude-state/memory/`
- [x] Update `lib/cmd-project-publish.sh`: exclude `memory/` from publish
- [x] Tests: memory mount, migration, publish exclusion

### Phase 2: Vault Profiles (#A — Core) — Implemented
- [x] Add `.vault-profile` parsing functions to `lib/cmd-vault.sh`
- [x] Implement `vault profile create` (branch + `.vault-profile`)
- [x] Implement `vault profile list`
- [x] Implement `vault profile show`
- [x] Implement `vault profile switch` (auto-commit + branch checkout)
- [x] Implement `vault profile rename`
- [x] Implement `vault profile delete`
- [x] Tests: profile CRUD, switch, list/show

### Phase 3: Selective Sync (#A — Sync) — Implemented
- [x] Modify `vault sync` to use profile-scoped staging
- [x] Modify `vault push` to sync shared resources to main
- [x] Modify `vault pull` to sync shared resources from main
- [x] Implement interactive conflict resolution (L/R/M/D)
- [x] Update `vault status` with profile info
- [x] Update `vault diff` with profile scoping
- [x] Tests: selective staging, push/pull sync, conflict resolution

### Phase 4: Resource Movement (#A — Move) — Implemented
- [x] Implement `vault profile move project --to`
- [x] Implement `vault profile move pack --to`
- [x] Implement `vault profile add/remove` shortcuts
- [x] `--profile` flag on `project create` and `pack create` is **deferred** to a future sprint (see §3.4)
- [x] Tests: move project/pack between profiles and main

### Phase 5: Validation & Polish — Implemented
- [x] E2E test: memory mount override (Docker required)
- [x] E2E test: multi-profile push/pull cycle
- [x] Update roadmap.md
- [x] Update CLAUDE.md with vault profile commands
- [x] Update CLI reference (docs/reference/cli.md)

> **Note**: The `--profile` flag on `cco project create` and `cco pack create` (§3.4) is deferred to a future sprint. Users can achieve the same result by creating the resource and then running `cco vault profile add project|pack <name>`.

---

## 12. Open Questions (Deferred)

### 12.1 Permission Model for User Config Modifications

The memory policy directs persistent knowledge to `.claude/rules/` and docs.
However, rules, agents, skills, and settings are **user-configured** resources
that Claude should respect and execute, not modify without approval.

Questions for a future design:
- Should Claude propose rule changes (diff/suggestion) vs. writing directly?
- Should a managed-level guard prevent silent rule modifications?
- How does this interact with the update system's "user-owned after install"?

**For Sprint 7**: The memory policy states that knowledge SHOULD go to
docs/rules, but Claude must ask for user approval before modifying those
files. This is consistent with the existing workflow. A deeper permission
model analysis is deferred to a future sprint.

**Roadmap**: Add as exploratory item — "Config modification permission model".

---

## 13. Files Modified

| File | Change |
|---|---|
| `lib/cmd-vault.sh` | Profile management, selective sync, enhanced status |
| `lib/cmd-start.sh` | Memory child mount in docker-compose generation |
| `lib/cmd-project-create.sh`, `lib/cmd-project-publish.sh` | Memory dir creation, publish exclusion, `--profile` flag |
| `lib/cmd-pack.sh` | `--profile` flag |
| `defaults/managed/.claude/rules/memory-policy.md` | NEW: managed memory policy |
| `defaults/managed/CLAUDE.md` | Memory policy reference |
| `defaults/managed/.claude/skills/init-workspace/SKILL.md` | Memory guidance |
| `migrations/project/008_separate_memory.sh` | NEW: memory separation |
| `tests/test_vault.sh` | Profile tests, sync tests, memory tests |
| `tests/test_vault_profiles.sh` | NEW: dedicated profile test suite |
| `docs/maintainer/decisions/roadmap.md` | Sprint 7 status update |
| `docs/reference/cli.md` | Vault profile commands |
| `CLAUDE.md` | Vault profile commands reference |
