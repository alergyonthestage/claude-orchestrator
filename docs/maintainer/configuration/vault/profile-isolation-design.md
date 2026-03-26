# Vault Profile Real Isolation — Design v2

**Status**: Implemented
**Date**: 2026-03-24
**Scope**: Architecture-level — vault profiles, shared sync, CLI, safety
**Supersedes**: Tracking-only isolation model in `design.md` §5.3 (Sprint 7-Vault)
**Analysis**: `profile-isolation-analysis.md`, `profile-git-mechanics-analysis.md`,
`profile-resource-model-analysis.md`, `profile-cli-analysis.md`

> This document is the authoritative reference for vault profile real isolation.
> It replaces the tracking-only model implemented in Sprint 7-Vault with
> git-level file isolation, where `vault switch` changes the files visible
> on disk. All design decisions have been discussed and approved.

---

## 1. Overview

### 1.1 What Changed

Sprint 7-Vault implemented profiles with **tracking-only** isolation:
resources were marked as exclusive in `.vault-profile` but never physically
removed from other branches. This resulted in:

- All projects visible on all profiles (no real isolation)
- `add`, `remove`, `move` commands operating only on metadata
- Users confused by inconsistent behavior

This design replaces tracking-only with **real git-level isolation**:

- `move` physically copies files to target branch and `git rm`s from source
- `remove` physically deletes files from the current branch
- `switch` changes visible files on disk (git checkout + gitignored file management)
- Shared resources (global, packs) are synchronized across all profile branches

### 1.2 Design Principles

1. **Real isolation**: profile switch = different files on disk
2. **Shared consistency**: shared resources are the same on all profiles, always
3. **Explicit saves**: `vault save` is the conscious save point; no silent auto-commits
4. **Hub-and-spoke sync**: main is the hub; shared changes flow profile → main → all profiles
5. **Single-PC conflict-free**: sync on a single PC never produces conflicts
6. **Backward compatible**: vaults without profiles work exactly as before
7. **Safety first**: destructive operations require confirmation; switch blocks during Docker sessions

---

## 2. Data Model

### 2.1 Branch Structure

```
main                    ← shared resources + main-exclusive projects
├── org-a               ← shared + org-a-exclusive (projects, packs)
└── personal            ← shared + personal-exclusive (projects, packs)
```

Each project exists on exactly ONE branch at a time (main or a profile).
Main acts as the default profile for projects: before any profiles exist,
all projects live on main. New profiles are created empty (shared resources
only); the user moves projects to them with `vault move`.

Shared resources (global, templates, shared packs) are duplicated and
synchronized across all branches via the shared sync algorithm.

### 2.2 Resource Classification

| Resource | Sharing | Default | At switch time |
|----------|---------|---------|----------------|
| `global/` | Always shared | Shared | Synced from main (at `vault save`) |
| `templates/` | Always shared | Shared | Synced from main |
| Pack (shared) | Shared | **Shared** | Synced from main |
| Pack (exclusive) | One profile only | N/A | Appears/disappears via git |
| Project | **Always exclusive** | Exclusive | Appears/disappears via git |
| `.vault-profile` | Per-profile | N/A | Changes with branch |
| `manifest.yml` | Always shared | Shared | Synced from main |
| `.gitignore` | Always shared | Shared | Synced from main |

**Key rules**:
- Projects are always exclusive — one profile or main, never shared
- Packs default to shared (on main); can be made exclusive via `vault move`
- `global/` and `templates/` are unconditionally shared

### 2.3 `.vault-profile` — Retained as Metadata

`.vault-profile` is tracked per profile branch. With real isolation, the branch
content IS the truth, but `.vault-profile` remains valuable for:

- **Sync scoping**: identifies which packs are exclusive vs shared
- **Profile detection**: machine-readable "am I on a profile branch?"
- **Display**: `vault profile show/list/status` read structured info
- **Validation**: `vault status` can warn if `.vault-profile` is inconsistent
  with actual branch content

Format unchanged:

```yaml
profile: org-a
sync:
  projects:
    - org-a-api
    - org-a-frontend
  packs:
    - org-a-conventions
```

### 2.4 Shadow Directory — `.cco/profile-state/`

Git checkout does NOT touch gitignored files. When switching profiles,
gitignored portable files (session transcripts, secrets) must be physically
moved to prevent cross-profile mixing.

**Location**: `user-config/.cco/profile-state/` (gitignored, at vault root)

```
.cco/profile-state/
├── org-a/
│   └── projects/
│       └── org-a-api/
│           ├── .cco/claude-state/     ← session transcripts
│           ├── .cco/meta              ← schema version
│           └── secrets.env            ← API keys
└── personal/
    └── projects/
        └── side-project/
            └── ...
```

**Portable files** (MUST move with project):
- `projects/*/.cco/claude-state/` — session transcripts (/resume history)
- `projects/*/secrets.env`, `*.env`, `*.key`, `*.pem` — secrets
- `projects/*/.cco/meta` — schema version

**Non-portable** (skip — regenerated by `cco start`):
- `projects/*/.cco/docker-compose.yml`
- `projects/*/.cco/managed/`
- `projects/*/.tmp/`
- `projects/*/rag-data/`
- `projects/*/.claude/.cco/pack-manifest`
- `packs/*/.cco/install-tmp/`

**Why `mv`**: On the same filesystem, `mv` is O(1) (rename syscall).
Verified: 0.001s for 1000 files. Alternatives evaluated and rejected:
`git stash --all` (destructive), `tar` (40-90x slower), hardlinks (wrong semantics).

### 2.5 Vault `.gitignore` Additions

```gitignore
# Profile state — gitignored files stashed during profile switch
.cco/profile-state/

# Profile operation backups
.cco/backups/

# Profile operation log
.cco/profile-ops.log
```

---

## 3. CLI Commands

### 3.1 Command Rename: `vault sync` → `vault save`

`vault sync` is renamed to `vault save` because the command now does more
than committing — it saves work and propagates shared resources across all
profile branches. "Save" is clearer and avoids confusion with remote sync
(push/pull). `vault sync` remains as a deprecated alias.

### 3.2 Complete Command Tree

```
cco vault
├── init
├── save [msg] [--yes]                        ← renamed from sync
├── diff
├── log [--limit N]
├── restore <ref>
├── status
│
├── switch <name>                              ← promoted (4 tokens)
├── move <project|pack> <name> <target> [--yes] ← promoted (6 tokens)
├── remove <project|pack> <name> [--yes]       ← promoted (5 tokens)
│
├── profile
│   ├── create <name>
│   ├── list
│   ├── show
│   ├── switch <name>                          ← alias for vault switch
│   ├── rename <new-name>
│   ├── delete <name> [--yes]
│   ├── move <project|pack> <name> <target> [--yes] ← alias for vault move
│   └── remove <project|pack> <name> [--yes]   ← alias for vault remove
│
├── remote
│   ├── add <name> <url>
│   └── remove <name>
├── push [<remote>]
└── pull [<remote>]
```

```
cco project
├── ...existing commands...
└── delete <name> [--yes]                      ← NEW
```

### 3.3 Deprecated Commands

| Deprecated | Replacement | Reason |
|------------|-------------|--------|
| `vault sync` | `vault save` | Rename for clarity |
| `vault profile add` | `vault move` | `add` was tracking-only; incompatible with real isolation |

### 3.4 Summary Table

| Command | Tokens | Purpose |
|---------|--------|---------|
| **Daily operations** | | |
| `cco vault save [msg]` | 3-4 | Save work (commit + shared sync to all profiles) |
| `cco vault switch <name>` | 4 | Change workspace |
| `cco vault push` | 3 | Send to remote |
| `cco vault pull` | 3 | Get from remote |
| `cco vault move project <name> <target>` | 6 | Move project to another profile |
| `cco vault remove project <name>` | 5 | Remove project from current profile |
| **Profile management** | | |
| `cco vault profile create <name>` | 5 | Create new profile |
| `cco vault profile list` | 4 | List profiles |
| `cco vault profile show` | 4 | Show current profile |
| `cco vault profile delete <name>` | 5 | Delete profile |
| `cco vault profile rename <new-name>` | 5 | Rename current profile |
| **Project lifecycle** | | |
| `cco project delete <name>` | 4 | Delete project from disk (all branches) |

### 3.5 Positional Arguments

Resource operations use positional targets (no `--to` flag required):

```bash
cco vault move project my-api work        # move my-api to profile work
cco vault move pack my-tools personal     # move pack to profile personal
cco vault remove project old-thing        # remove from current profile
```

`--to` is accepted as an alias for backward compatibility:
```bash
cco vault move project my-api --to work   # same as above
```

---

## 4. `vault save` — Complete Flow

### 4.1 Purpose

"Save my work" — commits all changes on the current branch and propagates
shared resource changes to main and all other profile branches.

### 4.2 Flow: On a Profile Branch

```
cco vault save "updated pack rules"

Step 1: Stage and commit on current branch
  git add -A
  git commit -m "vault: updated pack rules"
  → Commits ALL files (exclusive + shared) on current branch

Step 2: Detect shared file changes
  Compare committed files against shared path patterns:
    global/, templates/, packs/<shared>/, manifest.yml, .gitignore
  If no shared files changed → done (skip steps 3-4)

Step 3: Propagate shared to main
  Call _sync_shared_to_main() (see §8.3 for detailed algorithm):
  - Checks out main, copies changed shared files using merge-base comparison
  - Handles conflicts interactively (multi-PC scenario only)
  - Commits sync + merge-base advancement (git merge -s ours)
  - Returns to source branch

Step 4: Propagate shared to each other profile branch
  For each profile branch != current:
    4a. git checkout <other_profile> -q
    4b. Call _sync_shared_from_main() (see §8.4):
        - Copies changed shared files from main using merge-base comparison
        - Commits sync + merge-base advancement
        (Note: _sync_shared_from_main expects caller to be on target branch)

Step 5: Return to original branch
  git checkout <profile> -q

Output:
  ✓ Saved on 'org-a': vault: updated pack rules (3 files)
  ✓ Synced 1 shared file to main and 2 profiles
```

### 4.3 Flow: On Main (No Profile)

```
cco vault save "updated global config"

Step 1: git add -A && git commit
Step 2: Detect shared file changes
Step 3: Propagate to all profile branches (same as step 4 above)
Step 4: Return to main

Output:
  ✓ Saved on 'main': vault: updated global config (2 files)
  ✓ Synced 2 shared files to 3 profiles
```

### 4.4 Flow: No Profiles (Backward Compatible)

```
cco vault save "updates"

Step 1: git add -A && git commit
No shared sync (no profiles exist)

Output:
  ✓ Saved: vault: updates (4 files)
```

Identical to the current `vault sync` behavior.

### 4.5 Why Profile-Scoped Staging Is No Longer Needed

With tracking-only isolation, `vault sync` used profile-scoped staging to
prevent committing other profiles' files. With real isolation, other profiles'
exclusive files do not exist on the current branch — they were `git rm`-ed.
Therefore `git add -A` is safe on any branch: it only stages files that belong
to the current branch (exclusive + shared).

The complex profile-scoped staging logic (lines 243-294 of current
`cmd-vault.sh`) can be removed.

---

## 5. `vault switch` — Complete Flow

### 5.1 Purpose

"Change workspace" — switches to a different profile branch, managing
gitignored files and verifying safety conditions.

### 5.2 Pre-Switch Checks

```
cco vault switch personal

Check 1: Clean working tree
  git status --porcelain
  If dirty → refuse:
    "✗ You have uncommitted changes (5 files).
     Run 'cco vault save \"message\"' to save your work first."

Check 2: No active Docker sessions
  Check for running containers with cco project labels
  If found → refuse:
    "✗ Cannot switch while Docker sessions are active.
     Running: my-api (container cco-my-api-...)
     Stop sessions with 'cco stop' first."

Check 3: Target exists
  git rev-parse --verify <target>
  If not found → error with suggestion
```

### 5.3 Switch Flow

```
cco vault switch personal

Step 1: Identify departing profile's exclusive resources
  Read .vault-profile → list of exclusive projects and packs

Step 2: Stash portable gitignored files
  For each exclusive project:
    mv projects/<name>/.cco/claude-state/  → .cco/profile-state/<current>/projects/<name>/.cco/claude-state/
    mv projects/<name>/secrets.env         → .cco/profile-state/<current>/projects/<name>/secrets.env
    mv projects/<name>/.cco/meta           → .cco/profile-state/<current>/projects/<name>/.cco/meta
    (same for *.env, *.key, *.pem patterns)

Step 3: Clean non-portable remnants
  For each exclusive project:
    rm -f projects/<name>/.cco/docker-compose.yml
    rm -rf projects/<name>/.cco/managed/
    rm -rf projects/<name>/.tmp/

Step 4: git checkout <target>
  On failure: reverse stash (mv files back), abort

Step 5: Clean ghost directories
  find projects/ -type d -empty -delete 2>/dev/null

Step 6: Restore portable gitignored files for arriving profile
  For each exclusive project on target profile:
    mv .cco/profile-state/<target>/projects/<name>/.cco/claude-state/  → projects/<name>/.cco/claude-state/
    mv .cco/profile-state/<target>/projects/<name>/secrets.env         → projects/<name>/secrets.env
    mv .cco/profile-state/<target>/projects/<name>/.cco/meta           → projects/<name>/.cco/meta

Step 7: No shared sync needed
  Shared resources are already aligned across all profiles
  (propagated by the last 'vault save')

Output:
  ✓ Switched to profile 'personal'
    3 exclusive projects available
```

### 5.4 Switch to Main

```
cco vault switch main

Steps 1-5: Same (stash, checkout, clean)
Step 6: No restore (main has no exclusive projects)
Step 7: No sync

Output:
  ✓ Switched to main (shared resources only)
```

### 5.5 First Switch After Profile Create

When creating a profile, the branch forks from main. All resources are
inherited. No gitignored stash is needed (no exclusive resources yet).
The user must `vault move` resources to segregate them.

```
cco vault profile create work
✓ Profile 'work' created
ℹ You have 5 projects on this branch. Use 'cco vault move project <name> work'
  to assign projects to this profile.
```

---

## 6. Resource Operations

### 6.1 `vault move project <name> <target>`

Transfers a project from the current branch to `<target>`. The project is
removed from source and added to target.

```
Preconditions:
  - Project directory exists: projects/<name>/
  - Target is a valid profile name or "main"
  - Target != current branch
  - Working tree is clean

Flow:
  1. Detect if target already has projects/<name>/
     → If yes AND files differ: prompt for conflict resolution
     → If yes AND identical: skip copy, proceed with rm

  2. Show action summary and request confirmation:
     Moving project 'my-api':
       From: main → To: org-a
       Tracked files: 12 files (.claude/, project.yml, memory/)
       Portable files: claude-state/ (3.2 MB), secrets.env
     Proceed? [y/N]

  3. Copy tracked files to target:
     git checkout <target> -q
     git checkout <source> -- projects/<name>/
     Update .vault-profile on target (add to sync.projects)
     git add -A -- projects/<name>/ .vault-profile
     git commit -m "vault: add project '<name>' (moved from <source>)"
     git checkout <source> -q
     (No merge-base advancement needed — move operates on exclusive resources,
      not shared paths. The shared sync algorithm handles its own merge-base.)

  4. Move portable gitignored files to shadow directory:
     mv projects/<name>/.cco/claude-state/ → .cco/profile-state/<target>/projects/<name>/.cco/claude-state/
     mv projects/<name>/secrets.env → .cco/profile-state/<target>/projects/<name>/secrets.env
     mv projects/<name>/.cco/meta → .cco/profile-state/<target>/projects/<name>/.cco/meta
     (same for *.env, *.key, *.pem patterns)

  5. Clean non-portable remnants:
     rm -f projects/<name>/.cco/docker-compose.yml
     rm -rf projects/<name>/.cco/managed/ .tmp/

  6. Remove tracked files from source:
     git rm -r projects/<name>/
     Update .vault-profile on source (remove from sync.projects if applicable)
     git add -A -- .vault-profile
     git commit -m "vault: remove project '<name>' (moved to <target>)"

  7. Clean ghost directories:
     find projects/<name> -type d -empty -delete 2>/dev/null

  8. Log operation:
     echo "$(date -Iseconds) MOVE project <name> <source>→<target>" >> .cco/profile-ops.log

Output:
  ✓ Moved project 'my-api' to profile 'org-a'
```

### 6.2 `vault move pack <name> <target>`

Same semantics as project move. Additional considerations:

- If moving a shared pack to a profile (making it exclusive): the pack is
  `git rm`-ed from main AND automatically cleaned from all other profile branches.
- **Automatic cleanup**: The move iterates all other profile branches and removes
  the synced copy of the pack, committing each removal.
- Packs have minimal gitignored state (only `.cco/install-tmp/`, ephemeral).
  No shadow directory handling needed for packs.

### 6.3 `vault remove project <name>`

Deletes a project from the current branch.

```
Flow:
  1. Check if project exists on any other branch
  2. Show summary with safety information:

     If LAST COPY:
       ⚠ Removing project 'my-api' from profile 'org-a':
         Tracked files: 12 files (will be deleted)
         Portable files: claude-state/ (3.2 MB), secrets.env
         !! THIS IS THE LAST COPY — no other branch has this project !!
         A backup will be created at .cco/backups/
       Proceed? [y/N]

     If other copies exist:
       Removing project 'my-api' from profile 'org-a':
         Tracked files: 12 files (will be deleted)
         Portable files: claude-state/, secrets.env
         This project also exists on: main
       Proceed? [y/N]

  3. If last copy: create backup
     tar czf .cco/backups/project-my-api-20260324-101500.tar.gz projects/my-api/

  4. git rm -r projects/<name>/
     Update .vault-profile (remove from sync.projects)
     git commit -m "vault: remove project '<name>' from profile"

  5. Delete portable gitignored files
     rm -rf projects/<name>/.cco/claude-state/
     rm -f projects/<name>/secrets.env
     find projects/<name> -type d -empty -delete

  6. Log operation

Output:
  ✓ Removed project 'my-api' from profile 'org-a'
  ✓ Backup saved to .cco/backups/project-my-api-20260324-101500.tar.gz
```

### 6.4 `vault remove pack <name>`

Same semantics as project remove. Packs have minimal gitignored state.
Auto-backup only when it is the last copy.

**Shared pack guards**:
- Removing a shared pack from a **profile** is blocked — the pack lives on main
  and would be re-synced. The user is directed to switch to main first.
- Removing a shared pack from **main** automatically cleans all profile branches
  (removes the synced copy from each).

### 6.5 `cco project delete <name>`

Deletes a project from disk entirely — all branches, all profiles.

```
Flow:
  1. List all branches that contain this project
  2. Show summary:
     Deleting project 'my-api' from ALL locations:
       - Branch 'org-a': 12 tracked files + claude-state/, secrets.env
       - Branch 'main': 12 tracked files
     This action is irreversible.
     Proceed? [y/N]

  3. For each branch: git rm, update .vault-profile, commit
  4. Delete all gitignored files
  5. Clean shadow directory entries
```

This delegates to vault when the vault is active. Without a vault, it simply
`rm -rf` the project directory.

### 6.6 `vault profile delete <name>`

Deletes a profile, moving all exclusive resources to main first.

```
Preconditions:
  - Target profile != current branch (must switch away first)
  - Target profile exists

Flow:
  1. Show summary:
     Deleting profile 'org-b':
       Exclusive projects (2): org-b-app, org-b-tools
       Exclusive packs (1): org-b-conventions
       These will be moved to main. Continue? [y/N]

  2. Move exclusive resources to main:
     For each exclusive project listed in target's .vault-profile:
       a. git checkout <target> -q
       b. git checkout main -q
       c. git checkout <target> -- projects/<name>/
       d. git add -A -- projects/<name>/
       e. git commit -m "vault: rescue project '<name>' from deleted profile"
     For each exclusive pack:
       (same flow)

  3. Move portable gitignored files from shadow dir to main location:
     For each rescued project:
       mv .cco/profile-state/<target>/projects/<name>/* → projects/<name>/

  4. Delete the profile branch:
     git branch -D <target>

  5. Clean up shadow directory:
     rm -rf .cco/profile-state/<target>/

  6. Log operation

Output:
  ✓ Moved 2 projects and 1 pack to main
  ✓ Deleted profile 'org-b'
```

### 6.7 `vault profile create <name>` — Behavior Under Real Isolation

Creates a new profile by branching from main. The new profile contains
**only shared resources** — no projects. Projects belong to main until
explicitly moved to the new profile with `vault move`.

```
Flow:
  1. Validate name (lowercase, hyphens, numbers)
  2. git checkout -b <name> main
  3. git rm -r projects/ (remove all projects — they belong to main)
  4. Write .vault-profile (empty project/pack lists)
  5. git add -A && git commit

  The new branch contains:
    - Shared resources (global, templates, shared packs) ✓
    - NO projects (removed in step 3)
    - Projects exclusive to other profiles: NOT present
      (they were git rm-ed from main when moved)

  6. Inform user:
     ✓ Profile '<name>' created (shared resources only)
     ℹ Use 'cco vault move project <name> <profile>' to assign projects.
```

**Key principle**: Each project exists on exactly ONE branch at a time.
Profile create does not duplicate projects — it creates an empty workspace.
The user populates it by moving projects from main (or other profiles).

### 6.8 `cco project create` on a Profile Branch

When a user creates a new project while on a profile branch, the project
must be registered in `.vault-profile` to be correctly identified as
exclusive (not shared).

**Behavior**: `cco project create` detects if a vault profile is active
and automatically adds the project to `.vault-profile`'s `sync.projects`.

```
$ cco project create my-new-api     # while on profile 'org-a'
✓ Project 'my-new-api' created from template 'base'
✓ Added to profile 'org-a' (.vault-profile updated)
ℹ Run 'cco vault save' to commit.
```

**Why this matters**: Without auto-registration, the new project would
exist on the branch but NOT be listed in `.vault-profile`. The sync
algorithm could erroneously treat it as a shared resource (since it's
not in any profile's exclusive list) and propagate it to main and other
profiles.

**Implementation**: Add a hook in `cmd-project-create.sh` that calls
`_profile_add_to_list "projects" "$name"` when `_get_active_profile`
returns a non-empty value.

### 6.9 Confirmation and Safety

All resource operations:

1. **Show action summary** before executing
2. **Require explicit confirmation** (`[y/N]`, default No)
3. **Support `--yes`** to skip confirmation (for scripts)
4. **Require TTY** without `--yes`
5. **Auto-backup** when removing the last copy of a project
6. **Log** to `.cco/profile-ops.log`

---

## 7. `vault push` and `vault pull`

### 7.1 `vault push`

"Send my work to remote."

```
cco vault push [remote]

Step 1: vault save (commit pending changes if any + shared sync)
Step 2: Push current branch to remote
  git push -u <remote> <current_branch>
Step 3: Push main to remote (shared resources)
  git push <remote> main

Output:
  ✓ Pushed 'org-a' to origin
  ✓ Pushed 'main' to origin (2 shared files synced)
```

Push operates on the **current profile + main** only. Other profiles are
pushed when the user works on them. Future enhancement: `--all` flag.

### 7.2 `vault pull`

"Get latest from remote."

```
cco vault pull [remote]

Step 1: Fetch all
  git fetch <remote>

Step 2: Pull current branch
  git pull <remote> <current_branch>

Step 3: Pull main
  git checkout main -q
  git pull <remote> main
  git checkout <current_branch> -q

Step 4: Sync shared from main → current profile
  Call _sync_shared_from_main() (see §8.4) for current profile only.
  Auto-copies files changed only on main since last sync.
  Conflict resolution for files changed on both sides (multi-PC only).
  Merge-base advancement (git merge -s ours main).

Output:
  ✓ Pulled 'org-a' from origin (3 commits)
  ✓ Pulled 'main' from origin (1 commit)
  ✓ Synced 2 shared files from main
```

### 7.3 Multi-PC Conflict Handling

Conflicts can occur at pull time when two PCs independently modified the
same shared file on different profile branches:

```
PC-A (on org-a): edits packs/python-tools/rules.md, saves, pushes
PC-B (on personal): edits packs/python-tools/rules.md, saves, pushes

PC-B push step 3 (push main): CONFLICT
  main has PC-A's version, PC-B wants to push different version

Resolution:
  ⚠ Shared resource conflict during push: packs/python-tools/rules.md
    Modified on main (from another PC/profile) AND locally

    [L] Keep local version
    [R] Keep remote (main) version
    [M] 3-way merge
    [D] Show diff

    Choice [L/R/M/D]: _
```

This reuses the existing `_resolve_shared_conflict` function.

### 7.4 Recommended User Workflow

```bash
# Start of session:
cco vault pull                    # get remote updates

# During work:
cco vault save "progress"        # save periodically

# End of session:
cco vault push                   # send to remote

# Switching context:
cco vault save "wip"
cco vault switch personal
cco start side-project
```

---

## 8. Shared Resource Sync — Algorithm

### 8.1 Sync Direction: Hub and Spoke

Main is the hub. Shared changes always flow through main:

```
vault save:    current profile → main → all other profiles
vault push:    current profile → main → remote
vault pull:    remote → main → current profile
vault switch:  no sync needed (save already propagated)
```

### 8.2 Determining Shared Paths

Shared paths are identified by exclusion:

```bash
_list_shared_paths() {
    local paths=("global/" "templates/" ".gitignore" "manifest.yml")

    # Add packs NOT listed in any profile's sync.packs
    for pack_dir in packs/*/; do
        pack_name=$(basename "$pack_dir")
        if ! _is_exclusive_pack "$pack_name"; then
            paths+=("packs/$pack_name/")
        fi
    done

    printf '%s\n' "${paths[@]}"
}
```

### 8.3 Sync Algorithm: Profile → Main

```bash
_sync_shared_to_main() {
    local vault_dir="$1" source_branch="$2"
    local default_branch=$(_vault_default_branch)

    # Identify shared files that differ
    local shared_paths=($(_list_shared_paths "$vault_dir"))
    local changed_files=$(git -C "$vault_dir" diff "$default_branch" "$source_branch" \
        --name-only -- "${shared_paths[@]}")

    [[ -z "$changed_files" ]] && return 0

    # Switch to main
    git -C "$vault_dir" checkout "$default_branch" -q

    # For each changed file, determine direction via merge-base
    local merge_base=$(git -C "$vault_dir" merge-base "$default_branch" "$source_branch")

    while IFS= read -r file; do
        local on_main=$(git -C "$vault_dir" diff "$merge_base" "$default_branch" \
            --name-only -- "$file")
        local on_source=$(git -C "$vault_dir" diff "$merge_base" "$source_branch" \
            --name-only -- "$file")

        if [[ -n "$on_main" && -n "$on_source" ]]; then
            # Both changed → conflict (multi-PC scenario only)
            _resolve_shared_conflict "$vault_dir" "$file" "$source_branch" "$default_branch"
        elif [[ -n "$on_source" ]]; then
            # Only source changed → auto-copy
            git -C "$vault_dir" checkout "$source_branch" -- "$file"
        fi
        # Only main changed or neither → no action
    done <<< "$changed_files"

    # Commit + merge-base advancement
    git -C "$vault_dir" add -A -- "${shared_paths[@]}"
    git -C "$vault_dir" commit -q -m "sync: shared from '$source_branch'" 2>/dev/null || true
    git -C "$vault_dir" merge -s ours "$source_branch" -q \
        -m "sync: merge-base with '$source_branch'" 2>/dev/null || true

    # Return
    git -C "$vault_dir" checkout "$source_branch" -q
}
```

### 8.4 Sync Algorithm: Main → Profile

```bash
_sync_shared_from_main() {
    local vault_dir="$1" target_branch="$2"
    local default_branch=$(_vault_default_branch)

    local shared_paths=($(_list_shared_paths "$vault_dir"))
    local changed_files=$(git -C "$vault_dir" diff "$target_branch" "$default_branch" \
        --name-only -- "${shared_paths[@]}")

    [[ -z "$changed_files" ]] && return 0

    # Already on target branch (called after checkout)
    local merge_base=$(git -C "$vault_dir" merge-base "$default_branch" "$target_branch")

    while IFS= read -r file; do
        local on_main=$(git -C "$vault_dir" diff "$merge_base" "$default_branch" \
            --name-only -- "$file")
        local on_target=$(git -C "$vault_dir" diff "$merge_base" "$target_branch" \
            --name-only -- "$file")

        if [[ -n "$on_main" && -n "$on_target" ]]; then
            _resolve_shared_conflict "$vault_dir" "$file" "$default_branch" "$target_branch"
        elif [[ -n "$on_main" ]]; then
            git -C "$vault_dir" checkout "$default_branch" -- "$file"
        fi
    done <<< "$changed_files"

    git -C "$vault_dir" add -A -- "${shared_paths[@]}"
    git -C "$vault_dir" commit -q -m "sync: shared from main" 2>/dev/null || true
    git -C "$vault_dir" merge -s ours "$default_branch" -q \
        -m "sync: merge-base with main" 2>/dev/null || true
}
```

### 8.5 Merge-Base Advancement

After every shared sync, a `git merge -s ours <other_branch>` is performed.
This creates a merge commit that:

- Does NOT modify any files (strategy "ours" = keep current tree)
- Advances the merge-base between the two branches
- Ensures future syncs only compare changes since the last sync point

**Why this is necessary**: Without merge-base advancement, synced files appear
as "changed on both sides" in future comparisons, producing false conflicts.
With advancement, the merge-base moves forward to the sync point, and only
genuinely new changes are detected.

**Result**: On a single PC, shared sync is always conflict-free. Conflicts
only occur in multi-PC scenarios where two machines independently modify the
same shared file.

### 8.6 New File Detection

Files that exist on main but not on a profile (e.g., a newly installed shared
pack) show up in `git diff` as additions. The `git checkout main -- <path>`
command creates them on the profile. This already works correctly.

---

## 9. Safety

### 9.1 Docker Session Check

`vault switch` must refuse if any Docker session is running:

```bash
_check_no_active_sessions() {
    local running
    # Match containers with the cco.project label (set by cmd-start.sh)
    # or by name prefix cc- (used by cmd-stop.sh)
    running=$(docker ps --filter "label=cco.project" --format "{{.Names}}" 2>/dev/null)
    if [[ -n "$running" ]]; then
        echo -e "${RED}✗${NC} Cannot switch while Docker sessions are active."
        echo "  Running:"
        echo "$running" | sed 's/^/    - /'
        echo "  Stop sessions with 'cco stop' first."
        return 1
    fi
}
```

Rationale: switching profiles moves files that Docker containers have mounted.
This would corrupt the running session's filesystem view.

> **Implementation note**: The label `cco.project` is set by `cmd-start.sh`
> (line 987: `ct_labels_json`). An alternative filter is `--filter "name=cc-"`
> (used by `cmd-stop.sh` line 48). Either approach detects cco-managed containers.

### 9.2 Backup on Remove (Last Copy)

When `vault remove` deletes the last copy of a project:

```bash
tar czf ".cco/backups/project-${name}-$(date +%Y%m%d-%H%M%S).tar.gz" \
    "projects/$name/"
```

The `.cco/backups/` directory is gitignored. Provides last-resort recovery.

### 9.3 Verify-Before-Delete (D27)

Transfer operations (profile create, vault move) must never silently
delete files that weren't properly stashed. The `_safe_remove_resource_dir`
helper enforces this:

```
Flow (after stash + git rm, before rm -rf):
  1. Inventory: find all remaining files in the directory
  2. Classify: check each against _SAFE_TO_REMOVE_PATTERNS (whitelist)
  3. Decision:
     - All files match safe patterns → _force_remove_dir (proceed)
     - Any file is unaccounted → SKIP removal + warn user
```

**Safe-to-remove patterns** (regenerated by `cco start`, no data loss):
- `.cco/docker-compose.yml`, `.cco/managed/*`, `.tmp/*`
- `.cco/install-tmp/*`, `rag-data/*`

**Everything else is protected by default.** This is future-proof: new file
types added to projects or packs will be automatically preserved until
explicitly added to the whitelist.

This check applies to:
- `profile create`: cleaning projects from new branch
- `vault move`: cleaning source directory after transfer

It does NOT apply to `vault remove` (explicit user deletion — backup handles safety).

### 9.4 Self-Healing Shadow Restore (D28)

`_check_vault` detects when portable files are stuck in the shadow directory
(caused by direct `git checkout` bypassing `cco vault switch`). If the
current branch has a shadow entry with files that should be on disk (project
is tracked, portable files are missing), they are auto-restored:

```
⚠ Restored portable files from shadow (direct git checkout detected)
```

This runs on every vault command, providing automatic recovery without
requiring user intervention.

### 9.5 Operation Log

Maintain `.cco/profile-ops.log` (gitignored):

```
2026-03-24T10:15:00 MOVE project my-api main→org-a (commit abc1234)
2026-03-24T10:16:00 MOVE project my-web main→org-a (commit def5678)
2026-03-24T10:20:00 SWITCH main→org-a
```

### 9.4 Rollback on Failure

| Failure point | State | Recovery |
|---------------|-------|----------|
| After commit on target, before rm on source | Project on both branches | Safe — re-run or manual cleanup |
| After rm, before gitignored file move | Tracked files gone, gitignored on disk | Git reflog; gitignored still in place |
| During gitignored file move | Partial — some files in source, some in shadow | Files never deleted, only moved. Recoverable. |
| Git checkout fails after stash | Gitignored files in shadow, wrong branch | Reverse stash (mv back), abort |
| Shared sync fails mid-operation | Partial sync on some profiles | Profiles with pending sync will catch up at next save |

---

## 10. Error Handling

### 10.1 Profile Operations

| Error | Behavior |
|-------|----------|
| Move to self (same branch) | Error: "Project is already on this branch" |
| Move non-existent project | Error: "Project 'X' not found on current branch" |
| Move to non-existent profile | Error: "Profile 'X' not found" |
| Remove non-existent project | Error: "Project 'X' not found on current branch" |
| Switch with dirty working tree | Error: "Run 'cco vault save' first" |
| Switch with active Docker session | Error: "Stop sessions first" |
| Switch to current profile | Info: "Already on profile 'X'" |
| Profile name invalid | Error with naming rules |

### 10.2 Sync Errors

| Error | Behavior |
|-------|----------|
| Non-TTY during conflict | Skip file, warn: "Run interactively to resolve" |
| Merge-base not found | Fall back to full diff (treat all differences as potential conflicts) |
| Shared sync fails on one profile | Continue with other profiles, warn about failed one |

---

## 11. Migration

### 11.1 From Tracking-Only Profiles

Users with existing tracking-only profiles must reset:

```bash
# On user's host machine:
cd ~/.config/claude-orchestrator    # vault directory
git checkout main
git branch -D <profile1> <profile2> ...
```

Then re-create profiles with the new commands. No automatic migration is
possible because tracking-only profiles have all files on all branches
(no reliable state to migrate from).

### 11.2 From No Profiles

No migration needed. The vault continues to work on main exactly as before.
Profiles are opt-in.

### 11.3 New Vault .gitignore Entries

Existing vaults need the new gitignore entries (§2.5). These should be added
by a migration or by `vault profile create` (first profile creation).

---

## 12. Implementation Checklist

### Phase 1: Core Infrastructure

- [ ] Add `.cco/profile-state/`, `.cco/backups/`, `.cco/profile-ops.log` to
      vault `.gitignore` template
- [ ] Implement `_stash_gitignored_files()` and `_restore_gitignored_files()`
- [ ] Implement `_check_no_active_sessions()` (Docker check)
- [ ] Implement `_sync_shared_to_main()` (local, with merge-base advancement)
- [ ] Implement `_sync_shared_from_main()` (local, with merge-base advancement)
- [ ] Implement `_sync_shared_to_all_profiles()` (iterates profile branches)
- [ ] Implement operation logging helper

### Phase 2: Command Rewrites

- [ ] Rewrite `vault save` (renamed from sync): commit + shared propagation
- [ ] Add `vault sync` as deprecated alias for `vault save`
- [ ] Rewrite `vault switch`: clean-tree check, Docker check, stash/restore
- [ ] Rewrite `vault move`: real git rm + copy + gitignored handling
- [ ] Rewrite `vault remove`: git rm + confirmation + backup
- [ ] Implement `vault move/remove/switch` shortcuts at vault level
- [ ] Deprecate `vault profile add` (alias to `vault move`)
- [ ] Rewrite `vault profile delete` for real isolation (§6.6)
- [ ] Update `vault profile create` for real isolation (§6.7)
- [ ] Auto-register project in `.vault-profile` on `cco project create` (§6.8)
- [ ] Implement `cco project delete`

### Phase 3: Push/Pull Updates

- [ ] Update `vault push`: auto-save + push profile + push main
- [ ] Update `vault pull`: pull profile + pull main + sync from main
- [ ] Update `_sync_shared_to_default` for remote push (reuse shared sync)
- [ ] Update `_sync_shared_from_default` for remote pull (reuse shared sync)

### Phase 4: Cleanup and Polish

- [ ] Remove profile-scoped staging logic (no longer needed)
- [ ] Remove `vault profile add` implementation (replaced by move)
- [ ] Update `vault status` to validate `.vault-profile` against branch content
- [ ] Update `vault profile show` for real isolation display
- [ ] Update `vault profile rename` (handle shadow directory rename if needed)
- [ ] Add new `.gitignore` entries via migration or profile create

### Phase 5: Tests

- [ ] Rewrite `test_vault_profiles.sh` for real isolation semantics
- [ ] Test: save with shared propagation to all profiles
- [ ] Test: switch with stash/restore of gitignored files
- [ ] Test: switch refused with dirty tree / active Docker
- [ ] Test: move project between profiles (tracked + gitignored)
- [ ] Test: remove with last-copy backup
- [ ] Test: push/pull with shared sync
- [ ] Test: merge-base advancement prevents false conflicts
- [ ] Test: backward compatibility (no profiles)
- [ ] Test: ghost directory cleanup

### Phase 6: Documentation

- [ ] Update `docs/reference/cli.md`
- [ ] Update `docs/user-guides/configuration-management.md`
- [ ] Update project CLAUDE.md
- [ ] Update roadmap
- [ ] Mark Sprint 7-Vault `design.md` §5.3 as superseded

---

## 13. Files Modified (Estimated)

| File | Change |
|------|--------|
| `lib/cmd-vault.sh` | Rewrite save/switch/move/remove, add shared sync, shadow dir, Docker check |
| `bin/cco` | Add `vault save` dispatch, deprecate `vault sync` |
| `tests/test_vault_profiles.sh` | Rewrite for real isolation |
| `tests/test_vault.sh` | Update save tests (renamed from sync) |
| `lib/cmd-project.sh` | Add `project delete` command |
| `docs/reference/cli.md` | Update command reference |
| `docs/user-guides/configuration-management.md` | Update profile guide |
| `docs/maintainer/configuration/vault/design.md` | Mark §5.3 as superseded |
| `docs/maintainer/decisions/roadmap.md` | Add profile isolation fix |

---

## 14. Decision Record

All decisions approved in design session 2026-03-24.

| # | Decision | Rationale |
|---|----------|-----------|
| D1 | Real git-level isolation (not tracking-only) | Tracking-only doesn't provide visible isolation at switch time |
| D2 | Shadow directory for gitignored files | Git doesn't manage gitignored files; `mv` is O(1) on same fs |
| D3 | Projects always exclusive — one branch only (main or a profile) | Context-specific state (secrets, sessions) makes sharing problematic. Main acts as default profile for projects. New profiles are empty. |
| D4 | Packs shared by default, can be exclusive | Packs serve cross-context needs; exclusivity is the exception |
| D5 | `vault sync` renamed to `vault save` | Clearer semantics; "save" not confused with remote sync |
| D6 | `vault save` propagates shared to main + all profiles | Hub-and-spoke: main is the authoritative source for shared resources |
| D7 | `vault switch` requires clean working tree | Explicit saves with proper commit messages; no silent auto-commits |
| D8 | `vault switch` blocks during Docker sessions | Prevents filesystem corruption from moving mounted files |
| D9 | Merge-base advancement via `git merge -s ours` | Prevents false conflicts on single-PC; conflicts only multi-PC |
| D10 | CLI: promote switch/move/remove to `vault` level | Shorter commands for daily operations (4-6 tokens) |
| D11 | Positional target for move (no `--to` required) | Consistent with cco conventions; `--to` as alias |
| D12 | No `copy` command (deferred) | Divergence risk; move + re-create covers use cases |
| D13 | Deprecate `vault profile add` | Incompatible with real isolation; replaced by `vault move` |
| D14 | `cco project delete` added | Full lifecycle command — deletes from all branches and profiles; no project-level delete existed |
| D15 | Auto-backup on remove when last copy | Safety net for destructive operations |
| D16 | `.vault-profile` retained as metadata | Still needed for sync scoping, profile detection, display |
| D17 | ~~Lazy cleanup~~ → Automatic cleanup when making shared pack exclusive | Auto-removes synced copies from all other branches (supersedes lazy warn approach) |
| D18 | Push/pull: current profile + main only | Other profiles pushed when user works on them |
| D19 | Backward compatible: no profiles = no change | All profile logic gated behind `_get_active_profile` checks |
| D20 | Profile-scoped staging removed | With real isolation, `git add -A` is safe on any branch |
| D21 | `vault move` auto-detects source branch | User can move from any branch, not just current — searches main, then profiles |
| D22 | `profile delete` requires `--force` for non-empty profiles | Safety: prevents accidental deletion of profiles with resources |
| D23 | Project name uniqueness across all branches | Each name can exist on exactly one branch; prevents merge conflicts |
| D24 | `_force_remove_dir`: Docker stub cleanup via Docker itself | macOS Docker Desktop mount points resist `rm -rf`; fallback uses `docker run alpine rm -rf` |
| D25 | Shadow file transfer on move | When moving a project whose portable files are in source's shadow (stashed during profile create/switch), transfer to target's shadow |
| D26 | `.gitignore` auto-update in `_check_vault` | Vaults initialized before profile isolation get missing entries automatically |
| D27 | Verify-before-delete (`_safe_remove_resource_dir`) | Whitelist approach: only known regenerable patterns are deleted. Unknown files are preserved with a warning. Future-proof for new file types. |
| D28 | Self-healing shadow restore in `_check_vault` | Detects portable files stuck in shadow after direct `git checkout` and auto-restores them |
| D29 | Shared pack remove guard | Removing shared pack from profile is blocked (re-sync risk). From main: auto-cleans all profile copies |
| D30 | Pack name uniqueness across all branches | Same enforcement as projects (D23). Checked in `pack create` |
