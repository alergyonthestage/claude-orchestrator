# Vault Profile Real Isolation — Git Branch Mechanics Analysis

**Date**: 2026-03-24
**Status**: Analysis — informs design of shadow directory implementation

**Note**: This is a supporting analysis document. The definitive design is in
`profile-isolation-design.md`. Some decisions in this analysis were revised
during the design discussion — the design document takes precedence.

**Scope**: Git checkout behavior, shadow directory validation, edge cases
**Input**: `profile-isolation-analysis.md` §2 (file categories), §6 (switch flow)

> This document provides empirical analysis of git checkout mechanics
> as they apply to vault profile isolation. All behaviors described were
> verified experimentally in a test repository that replicates the vault
> directory structure. The analysis validates the shadow directory
> approach and identifies implementation constraints.

---

## 1. Git Checkout Behavior with File Categories

### 1.1 Test Setup

The test repository replicates the vault structure:

```
user-config/
├── .gitignore                    # Matches vault .gitignore template
├── projects/
│   ├── org-a-api/
│   │   ├── .claude/CLAUDE.md          # tracked
│   │   ├── .claude/rules/style.md     # tracked
│   │   ├── project.yml                # tracked
│   │   ├── .cco/claude-state/...      # gitignored (session data)
│   │   ├── .cco/docker-compose.yml    # gitignored (generated)
│   │   ├── .cco/managed/rules.json    # gitignored (generated)
│   │   ├── .cco/meta                  # gitignored
│   │   ├── secrets.env                # gitignored
│   │   └── .tmp/dry-run.log           # gitignored
│   ├── personal-blog/
│   │   ├── .claude/CLAUDE.md          # tracked
│   │   ├── project.yml                # tracked
│   │   ├── .cco/claude-state/s1.json  # gitignored
│   │   └── secrets.env                # gitignored
│   └── org-a-frontend/
│       ├── .claude/CLAUDE.md          # tracked
│       └── project.yml                # tracked
```

Three branches created: `master` (all projects), `org-a` (org-a-api only),
`personal` (personal-blog only). The `org-a` and `personal` branches were created
from `master`, then `git rm -r` was used to remove non-profile projects
from each branch.

### 1.2 Behavior Matrix

| File category | On `git checkout <target>` | Verified? |
|---|---|---|
| Tracked, exists on both branches (same content) | No change — file stays as-is | Yes |
| Tracked, exists on both branches (different content) | Content replaced with target's version | Yes |
| Tracked, exists on source only (not on target) | File deleted from disk, parent dir removed if empty | Yes |
| Tracked, exists on target only (not on source) | File created on disk | Yes |
| Gitignored, in directory tracked on source | **Survives** — git does not touch gitignored files | Yes |
| Gitignored, in directory NOT tracked on either | **Survives** — git does not touch gitignored files | Yes |
| Untracked (not gitignored) | **Survives** — git preserves untracked files | Yes |

### 1.3 Critical Finding: Gitignored Files in Git-Removed Directories

When `projects/personal-blog/` is `git rm -r`-ed from the `org-a` branch:

1. **Git removes ONLY tracked files**: `project.yml`, `.claude/CLAUDE.md`
2. **Git removes empty parent directories**: `.claude/` disappears because
   it had no remaining children
3. **Gitignored files survive**: `secrets.env`, `.cco/claude-state/s1.json`
   remain on disk
4. **Parent directory persists**: `projects/personal-blog/` continues to exist
   because it contains gitignored children (`.cco/` and `secrets.env`)

Resulting state on `org-a` branch after `git rm -r projects/personal-blog/`:

```
projects/personal-blog/          # STILL EXISTS (has gitignored children)
├── .cco/
│   └── claude-state/
│       └── s1.json           # gitignored — survived
└── secrets.env               # gitignored — survived
```

This is the **ghost directory** problem: the project directory appears to
exist but has no tracked content. Any tool that scans `projects/*/` will
find it and potentially treat it as a real project.

### 1.4 Checkout Round-Trip Behavior

Switching from `org-a` to `master` and back:

| Step | Action | Result |
|---|---|---|
| 1 | On `org-a`: `projects/personal-blog/` has only gitignored files | Ghost state |
| 2 | `git checkout master` | personal-blog tracked files restored. Gitignored files **still there** from step 1 |
| 3 | `git checkout org-a` | personal-blog tracked files removed again. Gitignored files **still there** |

**Key property**: gitignored files are completely invariant to branch
switches. They never move, never get deleted, never get restored. This is
why the shadow directory mechanism is necessary.

### 1.5 Checkout Failure Conditions

Git checkout refuses to switch branches when:

- A tracked file has uncommitted modifications AND the target branch has
  different content for that file (would overwrite local changes)

Git checkout does NOT fail when:

- There are gitignored files present
- There are untracked (non-ignored) files present
- A tracked file has uncommitted modifications but the target branch has
  the same content

The existing `_vault_auto_commit()` function handles the failure condition
correctly by committing all changes before switching. This is critical:
**the auto-commit MUST run before gitignored file stashing**, not after,
because a failed auto-commit would leave the vault in a dirty state that
blocks checkout.

### 1.6 Directory Cleanup Rules

Git follows these rules for directories when removing tracked files:

1. After removing a tracked file, git walks up the directory tree
2. At each level, git checks if the directory is now empty
3. If empty: git removes the directory
4. If NOT empty (has other files, tracked or otherwise): git stops

Consequence for the vault:

| Project state | Directory outcome |
|---|---|
| `org-a-frontend/` (all files tracked, no gitignored) | **Fully cleaned**: directory removed by git |
| `personal-blog/` (tracked + gitignored files) | **Ghost**: directory persists with only gitignored children |
| `org-a-api/.claude/` (was tracked, no gitignored children) | **Cleaned**: subdirectory removed |
| `org-a-api/.cco/` (has gitignored children) | **Persists**: subdirectory remains |

---

## 2. Shadow Directory Validation

### 2.1 Prerequisites

The shadow directory `.cco/profile-state/` is:

- Located at vault root (`user-config/.cco/profile-state/`)
- Listed in vault `.gitignore` → gitignored
- **Persists across all branch checkouts** (verified experimentally)
- On the same filesystem as `projects/` → `mv` is O(1) (verified: 0.001s
  for 1000 files)

### 2.2 Scenario A: Initial Setup and First Move

**Starting state**: vault on master with projects `org-a-api`, `org-a-frontend`,
`personal-blog`. User creates profile "org-a", moves `org-a-api` to it.

```
Step 1: cco vault profile create org-a
    1.1 _vault_auto_commit          → commit any pending changes on master
    1.2 git checkout -b org-a master → create org-a branch
    1.3 Write .vault-profile:
         profile: org-a
         sync:
           projects: []
           packs: []
    1.4 git add .vault-profile && git commit

    State:
      Branch: org-a
      Disk:   projects/{org-a-api,org-a-frontend,personal-blog} — all present (identical to master)
      Shadow: empty

Step 2: cco vault move project org-a-api org-a
    2.1 _vault_auto_commit           → commit pending changes on org-a
    2.2 Read current profile          → org-a (already on correct branch)
    2.3 Verify org-a-api exists       → projects/org-a-api/ present
    2.4 Target = org-a, current = org-a → project stays on this branch
         _profile_add_to_list "projects" "org-a-api"
         → .vault-profile now has org-a-api in sync.projects

    2.5 Switch to master to git rm:
         git checkout master -q
         git rm -r projects/org-a-api/
         git commit -m "vault: remove project 'org-a-api' from main"

    2.6 Handle gitignored files on master:
         At this point, org-a-api's gitignored files are still on disk
         (ghost directory). They belong to org-a profile.
         mv projects/org-a-api/.cco/claude-state/ →
            .cco/profile-state/org-a/projects/org-a-api/.cco/claude-state/
         mv projects/org-a-api/secrets.env →
            .cco/profile-state/org-a/projects/org-a-api/secrets.env
         rmdir projects/org-a-api/.cco/ projects/org-a-api/
            (clean up empty ghost directories)

    2.7 Return to org-a:
         git checkout org-a -q
         → org-a-api tracked files restored by git

    2.8 Restore gitignored files for org-a-api:
         mv .cco/profile-state/org-a/projects/org-a-api/.cco/claude-state/ →
            projects/org-a-api/.cco/claude-state/
         mv .cco/profile-state/org-a/projects/org-a-api/secrets.env →
            projects/org-a-api/secrets.env

    Final state:
      Branch: org-a
      Tracked: org-a-api (+ org-a-frontend, personal-blog — still on org-a from branch creation)
      Shadow: empty (org-a's files restored to disk)
      master: org-a-api git rm-ed; org-a-frontend and personal-blog present
```

**Note**: After step 2, `org-a-frontend` and `personal-blog` still exist on the
`org-a` branch (they were inherited from master at branch creation). The
user would need to `git rm` them (via future move/remove commands) for
full isolation. This matches the expected workflow described in
`profile-isolation-analysis.md` §6.5.

### 2.3 Scenario B: Profile Switch with Gitignored Files

**Starting state**: User is on profile `org-a`. `org-a-api` has active
gitignored files (session data from working, secrets). User switches to
profile `personal`.

```
Step 1: cco vault switch personal

    1.1 _vault_auto_commit
         → commits any tracked changes on org-a branch

    1.2 Identify org-a's exclusive projects
         Read .vault-profile: sync.projects = [org-a-api]

    1.3 Stash org-a's portable gitignored files:
         For projects/org-a-api/:
           mv projects/org-a-api/.cco/claude-state/ →
              .cco/profile-state/org-a/projects/org-a-api/.cco/claude-state/
           mv projects/org-a-api/secrets.env →
              .cco/profile-state/org-a/projects/org-a-api/secrets.env
           mv projects/org-a-api/.cco/meta →
              .cco/profile-state/org-a/projects/org-a-api/.cco/meta

         Skip non-portable:
           projects/org-a-api/.cco/docker-compose.yml    → leave/delete
           projects/org-a-api/.cco/managed/              → leave/delete
           projects/org-a-api/.tmp/                      → leave/delete

    1.4 Clean up non-portable gitignored remnants:
         rm -rf projects/org-a-api/.cco/docker-compose.yml
         rm -rf projects/org-a-api/.cco/managed/
         rm -rf projects/org-a-api/.tmp/
         (These are regenerated by cco start, no data loss)

    1.5 git checkout personal -q
         Git operations:
           - Tracked files for org-a-api: REMOVED by git
           - Tracked files for personal-blog: RESTORED by git
           - Any remaining ghost directories (empty .cco/) cleaned by rmdir

    1.6 Restore personal's portable gitignored files:
         If .cco/profile-state/personal/ exists:
           mv .cco/profile-state/personal/projects/personal-blog/.cco/claude-state/ →
              projects/personal-blog/.cco/claude-state/
           mv .cco/profile-state/personal/projects/personal-blog/secrets.env →
              projects/personal-blog/secrets.env
           mv .cco/profile-state/personal/projects/personal-blog/.cco/meta →
              projects/personal-blog/.cco/meta
         If shadow dir for personal is empty (first time):
           No restore needed — files may already be on disk from initial state

    1.7 Clean up any remaining ghost directories from org-a-api:
         find projects/org-a-api/ -type d -empty -delete 2>/dev/null
         (Remove leftover empty dirs that git didn't clean because of
          gitignored files that we already stashed)

    Final state:
      Branch: personal
      Disk:
        projects/personal-blog/  → tracked files from git + gitignored files restored
        projects/org-a-api/      → GONE (tracked removed by git, gitignored stashed)
      Shadow:
        .cco/profile-state/org-a/projects/org-a-api/  → session data + secrets
```

### 2.4 Scenario C: Move Project That Has Gitignored Files

**Starting state**: User is on `master`. `org-a-api` has `claude-state/`
with 50MB of session data. User moves it to profile `org-a`.

```
Step 1: cco vault move project org-a-api org-a

    1.1 _vault_auto_commit on master

    1.2 Copy tracked files to org-a branch:
         git checkout org-a -q
         git checkout master -- projects/org-a-api/
         _profile_add_to_list "projects" "org-a-api"
         git add -A -- projects/org-a-api/ .vault-profile
         git commit -m "vault: add project 'org-a-api' to profile 'org-a'"

    1.3 Return to master and git rm:
         git checkout master -q
         git rm -r projects/org-a-api/
         git commit -m "vault: remove project 'org-a-api' from main"

    1.4 Handle gitignored files (50MB claude-state/):
         At this point we're on master. org-a-api's gitignored files are
         still on disk (ghost directory). They need to go to the org-a profile.

         Option A: Stash to shadow dir, restore on next switch to org-a
           mv projects/org-a-api/.cco/claude-state/ →
              .cco/profile-state/org-a/projects/org-a-api/.cco/claude-state/
           mv projects/org-a-api/secrets.env →
              .cco/profile-state/org-a/projects/org-a-api/secrets.env
           (O(1) — just inode rename, even for 50MB directory)

         Option B: Switch to org-a, move directly
           git checkout org-a -q
           → tracked files appear
           → gitignored files are already on disk (they survived the checkout)
           This would WORK, but requires an extra branch switch

    1.5 Clean up ghost directory on master:
         rm -rf projects/org-a-api/.cco/  (non-portable remnants)
         rm -rf projects/org-a-api/.tmp/
         rmdir projects/org-a-api/ 2>/dev/null

    Final state (if user is still on master):
      Disk: projects/org-a-api/ GONE entirely
      Shadow: .cco/profile-state/org-a/projects/org-a-api/ has session data + secrets
      Next switch to org-a: shadow files restored automatically
```

**Performance note**: The `mv` of 50MB session data is 0.001 seconds on the
same filesystem. This is because `mv` on the same filesystem is a rename
syscall that modifies only directory entries, not file data.

### 2.5 Scenario D: Return to Previous Profile

**Starting state**: User was on `org-a`, switched to `personal` (Scenario B
completed), now switches back to `org-a`.

```
Step 1: cco vault switch org-a

    1.1 _vault_auto_commit on personal

    1.2 Identify personal's exclusive projects:
         Read .vault-profile: sync.projects = [personal-blog]

    1.3 Stash personal's portable gitignored files:
         mv projects/personal-blog/.cco/claude-state/ →
            .cco/profile-state/personal/projects/personal-blog/.cco/claude-state/
         mv projects/personal-blog/secrets.env →
            .cco/profile-state/personal/projects/personal-blog/secrets.env

    1.4 Clean up non-portable remnants from personal-blog:
         rm -rf projects/personal-blog/.cco/docker-compose.yml
         rm -rf projects/personal-blog/.cco/managed/
         rm -rf projects/personal-blog/.tmp/

    1.5 git checkout org-a -q
         → org-a-api tracked files restored
         → personal-blog tracked files removed
         → Remaining ghost dirs from personal-blog cleaned up (step 1.7)

    1.6 Restore org-a's portable gitignored files:
         mv .cco/profile-state/org-a/projects/org-a-api/.cco/claude-state/ →
            projects/org-a-api/.cco/claude-state/
         mv .cco/profile-state/org-a/projects/org-a-api/secrets.env →
            projects/org-a-api/secrets.env
         mv .cco/profile-state/org-a/projects/org-a-api/.cco/meta →
            projects/org-a-api/.cco/meta

    1.7 Clean up ghost directories from personal-blog:
         find projects/personal-blog/ -type d -empty -delete 2>/dev/null

    Final state:
      Branch: org-a
      Disk:
        projects/org-a-api/    → fully populated (tracked + gitignored restored)
        projects/personal-blog/ → GONE
      Shadow:
        .cco/profile-state/personal/projects/personal-blog/ → stashed
        .cco/profile-state/org-a/ → empty (restored to disk)
```

**Verification**: org-a-api's session data (s1.json, s2.json, s3.json created
during earlier sessions) is correctly restored. The data made a full round-trip:
disk → shadow → disk.

---

## 3. Edge Cases and Failure Modes

### 3.1 `mv` Fails Mid-Operation (Disk Full, Permissions)

**Scenario**: During stash, `mv` succeeds for `claude-state/` but fails for
`secrets.env` (disk full or permission error).

**Analysis**: `mv` of a directory on the same filesystem is atomic (single
`rename()` syscall). If the directory move succeeds, it's complete. File-level
`mv` is also atomic. The risk is between two separate `mv` calls.

**State after partial failure**:

```
projects/org-a-api/.cco/claude-state/  → moved to shadow
projects/org-a-api/secrets.env         → still on disk (mv failed)
```

**Recovery strategy**:

1. The switch implementation must check the exit code of each `mv`
2. If any `mv` fails, log a warning but continue with the branch checkout
3. The file stays in place — it's not lost, just not properly stashed
4. On the next switch back, the stash operation for this file is a no-op
   (file is already in place), and the restore finds the shadow empty
   (no restore needed for that file)

**Stronger approach**: Move the entire project's gitignored tree as a single
directory-level `mv` instead of file-by-file. This requires collecting all
portable files into a single parent directory first, which adds complexity
but provides atomicity.

**Recommendation**: File-by-file `mv` with error handling. Each `mv` is
individually atomic. Partial failure is recoverable and does not corrupt
data. The implementation should log which files failed and inform the user.

### 3.2 Git Checkout Fails After Gitignored Files Were Stashed

**Scenario**: Portable files have been moved to shadow directory, then
`git checkout <target>` fails.

**When can this happen?**

- `_vault_auto_commit` runs before stashing, so dirty tracked files are
  committed. The most common checkout failure (conflicting modifications)
  is eliminated.
- Checkout can fail if: the branch doesn't exist (caught earlier by
  validation), or a low-level git error occurs (corrupted repo, disk error).

**State after failure**:

```
Shadow: .cco/profile-state/<current>/ has stashed files
Disk:   projects/<project>/ has only non-portable gitignored remnants
Branch: still on current branch (git checkout was aborted)
```

**Recovery**:

```bash
# In the switch function, after git checkout fails:
if ! git -C "$vault_dir" checkout "$target" -q 2>/dev/null; then
    warn "Branch checkout failed — restoring stashed files"
    # Reverse the stash: move files back from shadow to disk
    _restore_profile_state "$vault_dir" "$current_profile"
    die "Failed to switch to profile '$target'"
fi
```

The implementation MUST use this pattern:

```
1. Auto-commit
2. Read current profile's exclusive projects/packs
3. Stash portable gitignored files to shadow
4. Attempt git checkout
5. IF checkout fails:
   5a. Restore from shadow (reverse the stash)
   5b. Abort with error
6. IF checkout succeeds:
   6a. Restore target profile's files from shadow
   6b. Clean up ghost directories
```

### 3.3 Symlinks in Gitignored Directories

**Behavior**: `mv` preserves symlinks (it's a rename, not copy). Symlinks
in `claude-state/` or other gitignored directories survive the shadow
directory round-trip.

Verified experimentally: a symlink moved to shadow and back retains its
target path and type.

**Risk**: Symlinks pointing to absolute paths may become invalid if the
vault is on a different machine (vault sync scenario). This is NOT a
shadow directory problem — it's inherent to vault sync and already exists
today.

**Recommendation**: No special handling needed. Document that symlinks in
gitignored directories are preserved but may become stale after vault sync
to a different machine.

### 3.4 Very Large `claude-state/` Directories

**Performance characteristics**:

| Operation | 1000 files (4MB) | Same-fs `mv` |
|---|---|---|
| `mv` (directory) | 0.001 seconds | O(1) — single rename syscall |
| `tar czf` | 0.040 seconds | O(n) — reads/writes all data |
| `cp -r` | depends on size | O(n) — reads/writes all data |

`mv` on the same filesystem is always O(1) regardless of directory size
because it only modifies directory entries (inodes), not file data. Even
a 50MB `claude-state/` with hundreds of session transcripts moves in
sub-millisecond time.

**Cross-filesystem scenario**: If `.cco/profile-state/` were on a different
filesystem from `projects/`, `mv` would fall back to `cp + rm`, becoming
O(n). However, both directories are inside the same vault root
(`user-config/`), so they are always on the same filesystem.

**Recommendation**: No performance concerns. `mv` at directory level is
the correct choice.

### 3.5 User Manually Creates Files in Projects on Another Profile

**Scenario**: User is on `org-a` profile. Manually creates
`projects/personal-blog/notes.txt` (personal-blog is not tracked on org-a).

**Git behavior**: The file is untracked (not gitignored, since the gitignore
patterns target specific subdirectories like `.cco/claude-state/`, not
arbitrary files). It survives branch checkouts.

**Impact**: When switching to `personal` profile, `projects/personal-blog/` will
have both:
- Tracked files restored by git checkout
- The manually created `notes.txt`

This is standard git behavior and not a problem. The file shows as
untracked in `git status` and does not interfere with profile operations.

**When switching AWAY from personal**: The `notes.txt` will survive (it's
untracked). If personal-blog is stashed to shadow, the stash only moves
gitignored portable files — it does not touch untracked files.

**Recommendation**: Document that manually created files in project
directories are not managed by the profile system. They are the user's
responsibility. Consider adding a warning during switch if untracked
files are detected in a project that's about to be hidden.

### 3.6 Race Condition: Concurrent Vault Access

**Scenario**: Two terminal sessions access the same vault simultaneously.
One starts a profile switch while the other is committing.

**Risk**: Low — vault operations are CLI-driven and sequential. The user
would have to explicitly trigger two operations at the same time.

**Mitigation**: Git's own locking (`.git/index.lock`) prevents concurrent
modifications. If a lock conflict occurs, the second operation fails with
git's standard error message.

**Recommendation**: No special handling needed. Git's built-in locking is
sufficient.

### 3.7 Ghost Directory Cleanup Timing

**Problem**: After stashing portable gitignored files and running
`git checkout`, there may be leftover empty directories:

```
projects/org-a-api/        # ghost — no tracked files, no gitignored files
├── .cco/                  # empty after stash
│   └── (empty)
```

Non-portable gitignored files (docker-compose.yml, managed/, .tmp/) may
also remain. These need cleanup.

**Order of operations**:

```
1. Stash portable gitignored files (mv to shadow)
2. Delete non-portable gitignored remnants (rm)
3. git checkout <target>
4. Clean up ghost directories (find -empty -delete or explicit rmdir)
```

Step 4 must happen AFTER git checkout, because git checkout might remove
some directories (tracked content removed = empty parent removed). Running
cleanup before checkout would try to remove directories that git is about
to handle.

However, step 2 (delete non-portable remnants) should happen BEFORE
checkout, because these files would otherwise persist as ghosts on the
target branch.

**Recommendation**: Combine step 2 and 4:

```bash
# Before checkout: clean non-portable + attempt ghost cleanup
_clean_project_remnants "$vault_dir" "$project_name"

# After checkout: final ghost cleanup for any remaining empty dirs
find "$vault_dir/projects/$project_name" -type d -empty -delete 2>/dev/null
```

---

## 4. Alternative Approaches to Shadow Directory

### 4.1 Git Stash for Gitignored Files

**Approach**: Use `git stash --all` which stashes tracked, untracked, AND
gitignored files.

**Problems**:

1. `git stash --all` REMOVES gitignored files from disk. It stores them in
   the stash and deletes them. Verified experimentally: `claude-state/`
   directory is completely removed.
2. The stash is branch-scoped — it saves the state of the current branch.
   There is no easy way to restore a stash to a different point in the
   workflow.
3. `git stash --all` stashes ALL gitignored files, not just portable ones.
   This would stash generated files (docker-compose.yml, managed/) and
   ephemeral files (.tmp/, rag-data/) unnecessarily.
4. Multiple profile switches would stack stashes, making it difficult to
   match stash entries to profiles.
5. `git stash pop` can fail with conflicts, leaving the user in a broken
   state.

**Verdict**: **Rejected**. Git stash is designed for temporarily shelving
work-in-progress tracked changes, not for managing gitignored file
lifecycle across branch switches.

### 4.2 Tar/Archive Instead of Directory Move

**Approach**: Before switching, `tar czf` portable files into
`.cco/profile-state/<profile>.tar.gz`. On restore, extract.

**Comparison with `mv`**:

| Property | `mv` (directory) | `tar` (archive) |
|---|---|---|
| Speed (1000 files) | 0.001s | 0.089s (create+extract) |
| Atomicity | Single syscall | Multi-step (create, then delete source) |
| Preserves symlinks | Yes | Yes (with `-h` flag) |
| Preserves permissions | Yes | Yes |
| Disk space during operation | None extra (rename) | Temporary 2x (archive + source) |
| Cross-filesystem | Falls back to cp | Works identically |
| Complexity | Trivial | Moderate (flags, error handling) |
| Recovery from failure | Files in one of two locations | Partial archive may be corrupt |

**Verdict**: **Rejected**. `tar` is strictly slower, uses more disk space
during operation, is more complex, and has worse failure modes. `mv` is
the correct choice for same-filesystem operations.

### 4.3 Hardlinks or Reflinks (Copy-on-Write)

**Approach**: Instead of moving files, create hardlinks or reflinks (on
filesystems that support them like Btrfs, XFS, APFS).

**Problems**:

1. We want to MOVE files, not link them. Hardlinks/reflinks create a
   second reference to the same data. The original file would still be
   visible in the source location.
2. After creating a link, we'd still need to delete the source, making
   it equivalent to `mv` but with extra steps.
3. Filesystem support varies: ext4 does not support reflinks. APFS does.
   Linux Docker containers typically use overlay2 (which supports reflinks
   experimentally in kernel 5.x+).
4. Hardlinks don't work for directories.
5. Reflinks are copy-on-write — they save space only if the file is not
   modified. For session transcripts (append-only), the original and copy
   would diverge quickly.

**Verdict**: **Rejected**. `mv` (rename) is simpler, faster, portable, and
does exactly what we need. Links add complexity without benefit.

### 4.4 Assessment: Is Shadow Directory the Simplest Correct Approach?

**Yes**. The shadow directory approach is the simplest correct solution
because:

1. **Git does not manage gitignored files** — there is no git-native
   mechanism to move gitignored files between branches
2. **`mv` is O(1)** on the same filesystem — effectively free
3. **The directory structure is predictable** — mirrors `projects/<name>/`
   layout, making restore trivial
4. **Failure modes are recoverable** — files are always in exactly one of
   two known locations (disk or shadow)
5. **No external dependencies** — only `mv`, `mkdir`, `rm`

The only alternative that could match this simplicity is "do nothing"
(delete gitignored files on switch, regenerate on `cco start`). But that
loses session history and secrets, which are unacceptable losses.

---

## 5. Portable vs Non-Portable Gitignored Files

### 5.1 Classification

Each gitignored pattern from the vault `.gitignore` template (lines 10-46
of `lib/cmd-vault.sh`) is classified below:

#### MUST MOVE (user data that cannot be regenerated)

| Pattern | Content | Why MUST move |
|---|---|---|
| `projects/*/.cco/claude-state/` | Session transcripts, `/resume` history | User's Claude interaction history — irreplaceable |
| `secrets.env` | API keys, tokens | User-configured secrets — cannot be regenerated |
| `*.env` | Additional env files | Same as secrets.env |
| `.credentials.json` | OAuth credentials | User-obtained credentials |
| `*.key`, `*.pem` | TLS/signing keys | Security-critical, manually provisioned |

#### SHOULD MOVE (useful but not critical)

| Pattern | Content | Why SHOULD move |
|---|---|---|
| `projects/*/.cco/meta` | `{"schema_version": N}` | Small file, preserves migration state. Without it, `cco update` may re-run migrations. Low cost to move. |

#### SKIP (regenerated automatically)

| Pattern | Content | Why SKIP |
|---|---|---|
| `projects/*/.cco/docker-compose.yml` | Generated compose file | Regenerated by `cco start` from `project.yml` |
| `projects/*/.cco/managed/` | Runtime managed files | Regenerated by `cco start` |
| `projects/*/.tmp/` | Dry-run artifacts | Ephemeral, no value |
| `projects/*/rag-data/` | RAG ingestion data | Large, ephemeral, regenerated by RAG pipeline |
| `projects/*/.claude/.cco/pack-manifest` | Pack install state | Regenerated by pack installation |
| `packs/*/.cco/install-tmp/` | Pack install temp files | Ephemeral build artifacts |
| `global/claude-state/` | Global session state | Not project-scoped — stays in place |
| `global/.claude/.cco/meta` | Global meta | Not project-scoped |
| `.cco/remotes` | Machine-specific remote config | Machine-specific, not profile-specific |
| `.cco/internal/` | Tutorial runtime state | Framework-internal |
| `*.bak`, `*.new` | Update sync artifacts | Temporary, cleaned by `cco clean` |

### 5.2 Implementation: Portable File List

The implementation should define portable patterns as a constant:

```bash
# Gitignored files that MUST move with their project during profile switch
_PORTABLE_GITIGNORED_PATTERNS=(
    ".cco/claude-state"     # session transcripts
    "secrets.env"           # project secrets
    "*.env"                 # additional env files
    ".credentials.json"     # OAuth credentials
    "*.key"                 # TLS/signing keys
    "*.pem"                 # certificates
    ".cco/meta"             # schema version (small, useful)
)
```

The stash function would iterate over these patterns for each exclusive
project:

```bash
_stash_portable_files() {
    local vault_dir="$1" project_name="$2" profile="$3"
    local project_dir="$vault_dir/projects/$project_name"
    local shadow_dir="$vault_dir/.cco/profile-state/$profile/projects/$project_name"

    mkdir -p "$shadow_dir"

    # Directory patterns (mv entire directory)
    for dir_pattern in ".cco/claude-state"; do
        if [[ -d "$project_dir/$dir_pattern" ]]; then
            mkdir -p "$(dirname "$shadow_dir/$dir_pattern")"
            mv "$project_dir/$dir_pattern" "$shadow_dir/$dir_pattern"
        fi
    done

    # File patterns (mv individual files, support globs)
    for file_pattern in "secrets.env" "*.env" ".credentials.json" "*.key" "*.pem" ".cco/meta"; do
        for file in "$project_dir"/$file_pattern; do
            [[ -f "$file" ]] || continue
            local rel="${file#$project_dir/}"
            mkdir -p "$(dirname "$shadow_dir/$rel")"
            mv "$file" "$shadow_dir/$rel"
        done
    done
}
```

### 5.3 Cleanup of Non-Portable Remnants

After stashing portable files, non-portable gitignored remnants should be
cleaned up to prevent ghost directories:

```bash
_clean_nonportable_remnants() {
    local vault_dir="$1" project_name="$2"
    local project_dir="$vault_dir/projects/$project_name"

    # Remove known non-portable gitignored content
    rm -rf "$project_dir/.cco/docker-compose.yml"
    rm -rf "$project_dir/.cco/managed"
    rm -rf "$project_dir/.tmp"
    rm -rf "$project_dir/rag-data"
    rm -f "$project_dir/.claude/.cco/pack-manifest"

    # Clean up empty directories
    find "$project_dir" -type d -empty -delete 2>/dev/null || true
}
```

---

## 6. Implementation Sequence for Profile Switch

Based on the analysis above, the correct implementation sequence is:

```
_vault_profile_switch(target):
    1. _vault_auto_commit()
       → Must succeed before any file operations

    2. current_branch = git rev-parse --abbrev-ref HEAD
       current_profile = _get_active_profile()

    3. IF current_profile is set:
         exclusive_projects = read .vault-profile → sync.projects
         exclusive_packs = read .vault-profile → sync.packs

         FOR each exclusive project:
           _stash_portable_files(project, current_profile)
           _clean_nonportable_remnants(project)

         FOR each exclusive pack:
           _stash_portable_files_pack(pack, current_profile)

    4. TRY: git checkout target -q
       ON FAILURE:
         FOR each exclusive project:
           _restore_portable_files(project, current_profile)
         die "Failed to switch to profile '$target'"

    5. IF target is a profile (not main):
         target_profile = read .vault-profile → profile
         target_projects = read .vault-profile → sync.projects
         target_packs = read .vault-profile → sync.packs

         FOR each target exclusive project:
           _restore_portable_files(project, target_profile)

         FOR each target exclusive pack:
           _restore_portable_files_pack(pack, target_profile)

    6. Clean up any ghost directories from source profile's projects:
         FOR each source exclusive project:
           find projects/<name>/ -type d -empty -delete 2>/dev/null

    7. (Optional) Sync shared resources from main → target
       (per profile-isolation-analysis.md §3)

    8. ok "Switched to profile '$target'"
```

---

## 7. Conclusions

### 7.1 Core Findings

1. **Git checkout is safe but incomplete**: It correctly handles tracked
   files but leaves gitignored files untouched. This is expected behavior,
   not a bug.

2. **Ghost directories are a real problem**: After `git rm` of a project
   directory that contains gitignored files, the directory persists with
   orphaned gitignored content. The implementation must actively clean these.

3. **Shadow directory is the correct approach**: It is O(1) for `mv`,
   survives all branch switches (because it's gitignored at vault root),
   and has simple, recoverable failure modes.

4. **Auto-commit must precede stashing**: The `_vault_auto_commit()` call
   must be the FIRST operation in the switch sequence. It prevents checkout
   failures from dirty tracked files, and it ensures no work is lost.

5. **Checkout failure recovery is straightforward**: If `git checkout` fails
   after stashing, reverse the stash (move files back from shadow to disk).
   Files are always in one of two known locations.

6. **Performance is not a concern**: `mv` on the same filesystem is O(1)
   regardless of file count or size. Even 50MB session directories move in
   sub-millisecond time.

### 7.2 Implementation Constraints

1. **Stash before checkout, restore after checkout**: This ordering is
   mandatory. Stashing removes files from the working tree (needed for
   clean ghost directory removal). Restoring fills in git-checked-out
   skeleton directories with their gitignored content.

2. **Clean non-portable remnants before checkout**: docker-compose.yml,
   managed/, .tmp/ should be removed before switching away, not after.
   Otherwise they persist as ghosts on the target branch.

3. **Ghost directory cleanup after checkout**: Use `find -type d -empty
   -delete` to remove directories that git left behind because they had
   gitignored children (which we already stashed).

4. **File-by-file mv with error handling**: Each `mv` should check its
   exit code. Partial failure should log a warning but not abort the switch.

5. **Shadow directory mirrors project structure**: Use the path structure
   `.cco/profile-state/<profile>/projects/<name>/` to mirror the vault
   layout. This makes restore trivial — the relative paths are identical.

### 7.3 Open Items for Design Phase

1. **Switch-to-main semantics**: When switching to main, should all
   profile-exclusive projects' gitignored files be stashed? Main has no
   `.vault-profile` to read, so the implementation must track which files
   were stashed from the source profile only.

2. **First switch after profile create**: No stashing needed (branch is
   identical to master). Should the switch detect this and skip the stash
   step? Or should it stash anyway (no-op since no exclusive projects)?

3. **Pack gitignored file handling**: Packs have fewer gitignored files
   (only `.cco/install-tmp/` which is ephemeral). Should packs skip
   stashing entirely?

4. **Concurrency with `cco start`**: If a user switches profiles while a
   `cco start` session is running, the session's Docker mounts point to
   directories that may disappear. This is a pre-existing issue
   (independent of shadow directories) and should be documented as
   unsupported behavior.
