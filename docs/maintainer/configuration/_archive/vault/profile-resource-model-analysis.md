# Vault Profile Resource Sharing Model — Analysis

**Date**: 2026-03-24
**Status**: Analysis — input for design decisions

**Note**: This is a supporting analysis document. The definitive design is in
`profile-isolation-design.md`. Some decisions in this analysis were revised
during the design discussion — the design document takes precedence.

**Scope**: How shared and exclusive resources coexist when profiles are git branches
**Prerequisites**: `profile-isolation-analysis.md` (real isolation model),
`design.md` (Sprint 7-Vault data model), `analysis.md` (original analysis)

> This document analyzes the resource sharing model across vault profiles:
> which resources can be shared, which must be exclusive, how git branch
> mechanics affect shared resource visibility, what sync model is correct,
> and how real-world use cases play out under each option. It concludes
> with concrete recommendations for each resource type.

---

## 1. Resource Type Matrix

### 1.1 Complete Classification

| Resource Type | Can be shared? | Can be exclusive? | Default | Valid operations | At profile switch |
|---|---|---|---|---|---|
| `global/` | Yes (always) | No | Shared | Edit only | Sync from main |
| `templates/` | Yes (always) | No | Shared | Edit only | Sync from main |
| `manifest.yml` | Yes (always) | No | Shared | Auto-managed | Sync from main |
| `.gitignore` | Yes (always) | No | Shared | Rare edits | Sync from main |
| Pack (default) | Yes | Yes | **Shared** | move, copy, remove | Sync from main (if shared) |
| Pack (exclusive) | N/A (was shared) | Yes | N/A | move, copy, remove | Appears/disappears via git |
| Project | See §5 | Yes | **Exclusive** | move, copy, remove | Appears/disappears via git |

### 1.2 Key Observations

1. **global/ and templates/ are unconditionally shared** — per D10 and D12
   in the original analysis. No mechanism exists or should exist to make
   them exclusive. Profile-specific conventions are handled via packs.

2. **Packs default to shared** — a pack exists on main unless explicitly
   assigned to a profile via `.vault-profile`'s `sync.packs`. This is the
   correct default because packs serve multiple projects across contexts.

3. **Projects default to exclusive** — in the current design, projects are
   always listed in a profile's `sync.projects`. On main (without profiles),
   projects live on main and that is the only place they exist.

4. **The shared/exclusive distinction maps directly to branch presence** —
   shared = exists on main (and replicated to profile branches via sync);
   exclusive = exists only on the profile branch (git rm from main and
   other branches in the real isolation model).

### 1.3 The "Implicit Shared" Problem

In the current branch model, profile branches are created from main. At
creation time, every file on main is inherited by the new branch. This
creates an important subtlety:

- A pack that nobody has claimed as exclusive exists on main AND on every
  profile branch (inherited at fork time).
- There is no explicit "shared" marker — shared is the absence of
  exclusive marking.
- Over time, the main copy and the profile branch copies can diverge
  silently, because git treats each branch's files independently.

This implicit-shared-by-inheritance model is the root of the sync problem
analyzed in §3.

---

## 2. The Fundamental Git Branch Tension

### 2.1 The Fork-and-Diverge Problem

When a profile branch is created from main, it receives a complete copy
of main's state at that point in time. From that moment, the two branches
are independent git histories. Changes to a file on main do NOT
automatically propagate to profile branches, and vice versa.

**Concrete walkthrough — shared pack `packs/python-tools/`:**

```
Time    Main branch                          Profile "org-a" branch
─────   ──────────────────────────────       ──────────────────────────────
T0      packs/python-tools/rules.md (v1)     (branch created from main)
                                             packs/python-tools/rules.md (v1)
T1      (user on main, edits rules.md)
        packs/python-tools/rules.md (v2)     packs/python-tools/rules.md (v1)
T2      (user switches to org-a)
                                             packs/python-tools/rules.md (v1)
                                             ← user sees v1, NOT v2
T3      (user on org-a, edits rules.md)
                                             packs/python-tools/rules.md (v3)
T4      (user switches to main)
        packs/python-tools/rules.md (v2)     packs/python-tools/rules.md (v3)
        ← user sees v2                       ← org-a still has v3
```

At T4, the pack has diverged: main has v2, org-a has v3. Neither version
contains the other's changes. Without an explicit sync mechanism, these
copies drift indefinitely.

### 2.2 Why This Is a Real Problem

For exclusive resources (projects on a single profile), divergence is not
a problem — the resource exists on exactly one branch, and that is the
single source of truth.

For shared resources, divergence breaks the user's mental model:
- The user thinks "my global config is the same everywhere"
- In reality, each profile branch has its own copy that can silently differ
- The user edits global config on org-a, expects to see those changes on
  main and on every other profile — but they are invisible until synced
- The longer profiles exist without syncing, the wider the divergence

### 2.3 What Git Checkout Actually Does at Switch Time

When `git checkout org-a` executes:

1. **Tracked files**: Git replaces the working tree with org-a's version.
   Files that exist on org-a but not on the current branch appear.
   Files that exist on the current branch but not on org-a disappear.
   Files that exist on both are replaced with org-a's version.

2. **Gitignored files**: Completely untouched. They remain on disk
   regardless of branch. This is why the shadow directory mechanism
   in `profile-isolation-analysis.md` §2.4 is needed.

3. **Untracked files**: Remain on disk unless they conflict with tracked
   files on the target branch (in which case git refuses the checkout).

This means: switching from main to org-a automatically shows org-a's version
of shared resources (which may be stale compared to main's latest). No
sync happens automatically.

### 2.4 The Merge-Base Drift Problem

Each time the user edits a shared file on a profile branch, the
merge-base (common ancestor) between main and that profile stays fixed
at the fork point (or the last sync commit). Over time:

```
                    merge-base
                        |
main:   ─────A──B──C──D──E──F──────
                 \
org-a:   ─────────X──Y──Z──────────
```

If shared file `f` was changed in commits B (main) and X (org-a), a
three-way merge at sync time uses the merge-base version (A) as the
common ancestor. This works correctly as long as the merge-base is
meaningful. But if many independent changes accumulate on both sides
before syncing, the merge becomes harder and more likely to produce
conflicts.

**Implication**: Frequent syncing (at switch time, not just push/pull)
reduces conflict severity.

---

## 3. Sync Model Options — Evaluation

### 3.1 Option S1: Sync on Switch (Selective Checkout from Main)

**Mechanics**: Every `vault switch <profile>` automatically copies
shared resources from main to the profile branch before presenting
the working tree to the user.

**Pros**:
- Shared resources are always up-to-date on every profile
- User never sees stale shared config
- Reduces divergence window to zero

**Cons**:
- May overwrite profile-side changes to shared resources without warning
- Adds latency to every switch operation
- If the user edited a shared pack on the profile (intentionally or not),
  those changes are silently replaced

**Verdict**: Dangerous without conflict detection. If only main changed,
auto-copy is safe. But if the profile also changed the same file, silent
overwrite destroys work. **Rejected as-is.**

### 3.2 Option S2: Sync on Push/Pull Only (Current Model)

**Mechanics**: `_sync_shared_to_default` runs during `vault push`,
`_sync_shared_from_default` runs during `vault pull`. No sync on
switch or any other operation.

**Pros**:
- Simple, predictable — sync only happens when the user explicitly
  pushes or pulls
- No latency on switch
- No risk of silent overwrites during daily operations

**Cons**:
- **Local-only users never sync**: If the user does not use a remote,
  shared changes on main never reach profile branches and vice versa.
  This is the most common scenario for single-PC users with profiles.
- **Switch shows stale data**: User edits global config on main, switches
  to profile — sees old global config. This violates the "shared means
  the same everywhere" expectation.
- Divergence accumulates silently between push/pull cycles

**Verdict**: Correct for remote-aware workflows but broken for local-only
usage. Since profiles are explicitly designed for single-laptop use cases
(see D11: "any PC can use any profile by switching"), **push/pull-only
sync is insufficient.**

### 3.3 Option S3: Sync on Switch + Conflict Detection (Recommended)

**Mechanics**: On `vault switch <profile>`:
1. Identify shared resource paths
2. Compare each shared file between main and the target profile branch
3. Determine which side(s) changed since the merge-base
4. Apply resolution rules:

| Condition | Action |
|---|---|
| Only main changed | Auto-copy main's version to profile (safe — profile never touched it) |
| Only profile changed | No action (profile's version is newer; will flow to main on push) |
| Both changed | Interactive prompt (L/R/M/D) — same as existing conflict resolution |
| New file on main | Auto-copy to profile |
| File deleted on main | Prompt: delete from profile too? |
| Neither changed | No action |

**Pros**:
- Shared resources are always current after a switch
- No silent overwrites — conflict detection prevents data loss
- Works for local-only users (no remote required)
- Merge-base comparison is the same algorithm already used in push/pull
- Reuses existing `_resolve_shared_conflict` infrastructure

**Cons**:
- Switch becomes slightly slower (git diff + possible per-file checkout)
- May present interactive prompts during switch (if both-side conflicts exist)
- First switch after a long period may surface many differences

**Performance mitigation**: The `git diff` between branches for shared paths
is fast (sub-second for typical vault sizes). The selective checkout (`git
checkout main -- <file>`) is O(n) in number of changed shared files, which
is typically very small (global config changes are infrequent).

**Interactive prompt mitigation**: Both-side conflicts on shared resources
are rare in practice. The user would have to edit the same shared file on
main AND on the profile independently. When it does happen, the prompt is
the correct behavior — the user must decide.

**Verdict**: This is the correct option. It provides the strongest
guarantee (shared resources are always current) with acceptable cost
(minimal latency, rare interactive prompts). **Recommended.**

### 3.4 Option S4: Main Is the Single Source of Truth (Edit-on-Main-Only)

**Mechanics**: Profile branches never modify shared resources directly.
All edits to shared files must happen on main. Profiles always inherit
main's version of shared files.

**Pros**:
- No conflicts possible — only one source of truth
- Simplest model to reason about
- Sync is always one-directional (main → profile)

**Cons**:
- **Terrible UX**: User is on profile "org-a", wants to edit global CLAUDE.md.
  Must switch to main, edit, switch back to org-a. For a file that "should
  be the same everywhere," this friction is unacceptable.
- Requires enforcement mechanism (reject commits that touch shared paths
  on profile branches) — complex to implement and confusing when violated
- Running sessions mount vault files. A session on org-a that edits global
  config would write to the profile branch — violating the rule at the
  filesystem level

**Verdict**: Correct in theory but hostile in practice. The user will edit
shared files while on a profile (it is the natural workflow), and the
system must handle that gracefully. **Rejected.**

### 3.5 Recommendation

**Option S3 (Sync on Switch + Conflict Detection)** is the correct model.

It should be implemented as an extension of `cmd_vault_profile_switch`,
integrated with the existing `_sync_shared_from_default` function but
modified to work locally (comparing local main branch, not `origin/main`).

The proposed implementation in `profile-isolation-analysis.md` §3.3
already describes this approach. The sync algorithm in §8.2 of the same
document provides a correct pseudocode implementation using merge-base
comparison.

### 3.6 Sync Trigger Summary (Updated)

| Trigger | Direction | Scope |
|---|---|---|
| `vault switch` (to profile) | Main → profile | Shared files changed on main since last sync |
| `vault switch` (to main) | Profile → main | Shared files changed on profile since last sync |
| `vault push` (on profile) | Profile → main (remote) | Shared files changed on profile |
| `vault pull` (on profile) | Remote main → profile | Shared files changed on remote main |
| `vault sync` | None (local commit) | No cross-branch sync |

**Important addition**: Switching TO main should also sync shared resources
from the departing profile TO main. Otherwise, edits to shared files made
while on a profile are not visible on main until the next push. With
switch-time sync in both directions, the user's shared edits flow to main
immediately on departure, and main's shared edits flow to the profile on
arrival.

---

## 4. Use Case Walkthroughs

### 4.1 UC1: Multi-Org Freelancer

**Setup**:
```
main:
  global/.claude/CLAUDE.md
  templates/base/
  packs/python-tools/         ← shared
  packs/docker-helpers/       ← shared
  manifest.yml

profile "org-a":
  (inherits all shared from main)
  projects/org-a-api/         ← exclusive
  projects/org-a-frontend/    ← exclusive
  packs/org-a-conventions/    ← exclusive

profile "org-b":
  (inherits all shared from main)
  projects/org-b-app/         ← exclusive
  packs/org-b-style/          ← exclusive
```

**Monday morning — start of org-a work**:
```bash
$ cco vault switch org-a
# 1. Auto-commits any pending changes on current branch
# 2. git checkout org-a
# 3. Sync shared resources from main → org-a:
#    - global/, templates/, packs/python-tools/, packs/docker-helpers/
#    - If any of these changed on main since last sync → auto-copy
#    - If any were also changed on org-a → conflict prompt (rare)
# 4. Restore gitignored files for org-a projects from shadow dir
#
# Result:
#   Visible: org-a-api, org-a-frontend, org-a-conventions,
#            python-tools, docker-helpers, global, templates
#   Hidden:  org-b-app, org-b-style (on org-b branch only)

$ cco start org-a-api
# Normal session — works with org-a-api, sees shared packs via mounts
```

**Wednesday — update shared pack while on org-a**:
```bash
# User edits packs/python-tools/rules.md while on org-a profile
# This edit is committed to org-a branch
# It will flow to main at next switch-away or push
```

**Thursday — switch to org-b**:
```bash
$ cco vault switch org-b
# 1. Auto-commit on org-a
# 2. Sync shared from org-a → main (the python-tools edit flows to main)
# 3. git checkout org-b
# 4. Sync shared from main → org-b (python-tools update arrives)
# 5. Stash/restore gitignored files
#
# Result: org-b now has the python-tools update made on org-a.
#         Shared resources are consistent across all profiles.
```

**Key insight**: The bidirectional sync on switch (departing profile → main,
then main → arriving profile) ensures shared edits propagate transitively
across profiles without requiring push/pull.

### 4.2 UC2: Work + Personal on Same Laptop

**Setup**:
```
main:
  global/.claude/CLAUDE.md     ← same rules for both contexts
  packs/general-tools/         ← shared
  templates/base/

profile "work":
  projects/work-api/
  projects/work-dashboard/
  packs/work-conventions/      ← exclusive (corporate style)

profile "personal":
  projects/side-project/
  projects/blog/
```

**Evening switch from work to personal**:
```bash
$ cco vault switch personal
# Sync: work → main (any shared edits on work go to main)
# Checkout: personal branch
# Sync: main → personal (shared edits arrive)
# Gitignored: work project secrets stashed, personal project secrets restored
#
# Visible: side-project, blog, general-tools, global config
# Hidden: work-api, work-dashboard, work-conventions
```

**User edits global CLAUDE.md while on personal** (adds a personal note
that applies everywhere):
```bash
# Edit global/.claude/CLAUDE.md on personal branch
$ cco vault sync "update global config"
# Committed on personal branch
```

**Next morning — switch back to work**:
```bash
$ cco vault switch work
# 1. Sync: personal → main (global CLAUDE.md update flows to main)
# 2. git checkout work
# 3. Sync: main → work (global CLAUDE.md update arrives on work)
# Result: work profile now has the updated global config
```

### 4.3 UC3: Shared Config Edit While on a Profile

**Scenario**: User is on profile "org-a", edits `global/.claude/CLAUDE.md`.

**State after edit (committed on org-a)**:
```
main:     global/.claude/CLAUDE.md = v1 (original)
org-a:    global/.claude/CLAUDE.md = v2 (user's edit)
personal: global/.claude/CLAUDE.md = v1 (inherited, stale)
```

**User switches to profile "personal"**:
```bash
$ cco vault switch personal
# Step 1: Sync org-a → main
#   merge-base for global/.claude/CLAUDE.md between org-a and main = v1
#   org-a has v2, main has v1
#   Only org-a changed → auto-copy v2 to main
#   main now has v2
#
# Step 2: git checkout personal
#   personal still has v1 (inherited, never updated)
#
# Step 3: Sync main → personal
#   merge-base for global/.claude/CLAUDE.md between main and personal = v1
#   main now has v2, personal has v1
#   Only main changed → auto-copy v2 to personal
#   personal now has v2
#
# Result: personal sees v2. The edit propagated org-a → main → personal.
```

**User switches to main**:
```bash
$ cco vault switch main
# Step 1: Sync personal → main
#   personal has v2, main has v2 → no change (already synced)
#
# Step 2: git checkout main
#   main has v2
#
# Result: main has v2. Consistent.
```

**Conclusion**: With bidirectional sync-on-switch, shared config edits
propagate correctly through the main branch as intermediary.

### 4.4 UC4: New Shared Pack Added on Main

**Scenario**: User is on main, installs a pack.
```bash
$ cco vault switch main      # go to main
$ cco pack install <url>     # creates packs/new-tool/
$ cco vault sync "add pack"  # commits on main
```

**State**:
```
main:     packs/new-tool/ exists
org-a:    packs/new-tool/ does NOT exist (branch was created before this pack)
```

**User switches to org-a**:
```bash
$ cco vault switch org-a
# Sync main → org-a:
#   packs/new-tool/ exists on main but not on org-a
#   It is a shared pack (not in any profile's sync.packs)
#   Action: new file on main → auto-copy to org-a
#   git checkout main -- packs/new-tool/
#
# Result: org-a now has packs/new-tool/. The shared pack is visible.
```

This is correct behavior. The sync mechanism must detect new files on
main (not just changed files) and copy them to the profile.

**Implementation note**: The current `git diff` between branches in
`_sync_shared_from_default` compares file-level differences. New files
that exist on main but not on the profile show up as additions in the
diff. The `git checkout main -- <path>` operation creates them on the
profile. This already works correctly.

### 4.5 UC5: Making a Shared Pack Exclusive

**Scenario**: Pack `python-tools` is shared (on main, visible everywhere).
User wants it only on profile "org-a".

**Operation**:
```bash
$ cco vault switch org-a
$ cco vault move pack python-tools org-a
# In real isolation model:
#   1. git rm packs/python-tools/ from main
#   2. Add "python-tools" to org-a's .vault-profile sync.packs
#   3. The pack files already exist on org-a (inherited or synced)
#   4. On other profile branches, packs/python-tools/ also exists
#      (inherited) → must be git rm-ed from those branches too
```

**The multi-branch cleanup problem**: When making a shared pack exclusive
to one profile, it must be removed from ALL other branches. This requires
iterating over all profile branches and running `git rm` on each.

**State after operation**:
```
main:     packs/python-tools/ REMOVED
org-a:    packs/python-tools/ EXISTS (exclusive)
personal: packs/python-tools/ REMOVED (was inherited, now cleaned)
```

**What happens on profiles that had modifications?**: If personal had local
edits to `python-tools/rules.md` (made while the pack was shared), those
edits are lost when git rm is run on personal. This is a destructive
operation and must require confirmation.

**Safer alternative**: Instead of automatic cleanup of other branches,
the move operation could:
1. Remove from main (git rm)
2. Add to org-a's .vault-profile
3. Warn: "python-tools may still exist on other profile branches (personal).
   Switch to each profile and run `cco vault remove pack python-tools`
   to clean up."

This is less magical but safer. The pack on other profiles becomes
"orphaned" — it exists on the branch but is not in that profile's
`.vault-profile`. The sync mechanism would NOT sync it (it is no longer
on main), and it would NOT be staged by `vault sync` on those profiles
(not in their profile scope). It would just sit there until manually
removed.

**Recommendation**: The lazy cleanup approach is safer. Let the user
clean up other branches manually. Document the workflow.

### 4.6 UC6: No Profiles (Backward Compatibility)

**Scenario**: User never creates profiles. Everything on main.

**Verification**:
- `vault init` creates git repo on main. No `.vault-profile` exists.
- `vault sync` runs `git add -A` on all files (no profile scoping).
- `vault push/pull` pushes/pulls main. No shared sync logic triggers
  (profile detection returns empty).
- `vault status` shows "Branch: main" with no profile info.
- All projects, packs, global config, templates are on main.
- `cco start <project>` works normally.

**Code path analysis** (from `cmd-vault.sh`):

```bash
# vault sync (line 241-294):
profile=$(_get_active_profile)
if [[ -n "$profile" ]]; then
    # profile-scoped staging
else
    # git add -A (all files)
fi

# vault push (line 552-556):
profile=$(_get_active_profile)
if [[ -n "$profile" ]]; then
    _sync_shared_to_default ...
fi
# Without profile: just push main, no shared sync

# vault pull (line 583-612):
profile=$(_get_active_profile)
if [[ -n "$profile" ]]; then
    _sync_shared_from_default ...
fi
# Without profile: just pull main, no shared sync
```

**Conclusion**: All code paths correctly guard profile logic behind
`_get_active_profile` checks. Without profiles, the vault behaves
exactly as before Sprint 7-Vault. **Backward compatibility is preserved.**

---

## 5. Projects: Always Exclusive or Allow Shared?

### 5.1 Arguments FOR Exclusive-Only Projects

1. **Simpler model**: A project lives on exactly one branch. No sync
   issues, no divergence, no conflict resolution for project files.

2. **Gitignored state is project-bound**: Projects have more gitignored
   state than any other resource type: `claude-state/` (session transcripts),
   `secrets.env`, `docker-compose.yml` (generated), `.cco/meta`. The
   shadow directory mechanism already handles stashing these during profile
   switch. Sharing projects would mean shared gitignored state — which is
   fundamentally problematic (two profiles sharing the same `secrets.env`?).

3. **Weak use case for shared projects**: When would a user want the same
   project configuration available on all profiles? Projects are
   inherently context-specific — `work-api` belongs to the work context,
   `side-project` belongs to personal. A "utility project" that applies
   everywhere is better modeled as a pack or a template.

4. **Cleaner transition from no-profiles to profiles**: When the user
   first creates profiles, all projects start on main (they were created
   before profiles existed). In the exclusive-only model, this is a known
   starting state: "you have N projects on main that need to be assigned
   to profiles." The user moves them one by one. In a shared model, the
   user must decide for each project: "should this be shared or exclusive?"
   — adding cognitive overhead.

5. **No sync needed for projects**: If projects are always exclusive,
   the shared sync mechanism (§3) only needs to handle global/, templates/,
   and shared packs. Projects are completely outside the sync scope. This
   simplifies the sync algorithm and reduces the surface for bugs.

### 5.2 Arguments FOR Allowing Shared Projects

1. **Consistency with packs**: Packs can be shared or exclusive. If
   projects can only be exclusive, the mental model has an asymmetry:
   "packs can be shared, projects cannot." The user must learn this
   distinction.

2. **Migration smoothness**: When moving from no-profiles to profiles,
   projects on main are effectively "shared" (visible without any profile).
   If shared projects are not supported, the user must immediately assign
   every project to a profile. If shared projects are supported, projects
   can stay on main temporarily without action.

3. **Utility projects**: Some users may have a "scratch" or "playground"
   project used across all contexts. Making it exclusive to one profile
   forces an arbitrary choice.

### 5.3 Analysis of the Consistency Argument

The packs/projects asymmetry is real but justified by different semantics:

- **Packs** provide reusable knowledge/rules that augment projects. A pack
  like `python-tools` naturally applies to many projects across many
  contexts. Sharing is the common case.

- **Projects** represent distinct work contexts with their own state,
  secrets, session history, and Docker configuration. A project like
  `work-api` is inherently bound to a single work context. Exclusivity
  is the common case.

The asymmetry reflects a real difference in how these resources are used,
not an arbitrary design choice.

### 5.4 Analysis of the Migration Argument

When the user creates their first profile, projects on main do not
disappear. They remain on main and are visible when on main. The
`profile-isolation-analysis.md` §6.5 (edge case: first switch after
profile create) already addresses this:

> When creating a profile, all resources start on both main and the new
> profile (since the branch is created from main). The user needs to
> `move` resources to segregate them.

This works regardless of whether shared projects are supported. The
question is only: can projects STAY on main indefinitely (shared model)
or must they be moved to a profile eventually (exclusive model)?

In the exclusive model, projects on main are in a transitional state.
They work fine (main is a valid branch), but they are not associated
with any profile. This is acceptable and even desirable — it motivates
the user to organize their workspace.

### 5.5 Analysis of the Utility Project Argument

A "scratch" project used everywhere can be handled by:
1. Keeping it on main (accessible when on main, not on profiles)
2. Using `copy` to duplicate it to each profile (divergence is acceptable
   for a scratch project)
3. Converting it to a pack (if it is truly context-independent)

None of these require a "shared project" feature.

### 5.6 Recommendation: Exclusive-Only Projects

**Projects should be exclusive-only.** The arguments for shared projects
are weak, while the arguments against add real complexity:

- Sync for projects would require handling gitignored files (secrets,
  claude-state) across branches — far more complex than syncing packs
  or global config
- The "shared project" concept conflicts with the mental model: projects
  have state, sessions, secrets that are inherently contextual
- The utility project use case is better served by other mechanisms

**What "exclusive-only" means in practice**:
- Projects on main (no profile) are accessible only when on main
- Projects on a profile branch are accessible only when on that profile
- `vault profile create` warns about unassigned projects on main
- `vault move project` is the mechanism for assignment
- `vault copy project` allows duplication to multiple profiles (they
  diverge independently)
- No shared sync runs for project paths — only for global/, templates/,
  and shared packs

This aligns with the existing design in `profile-isolation-analysis.md`
Q5, Option B.

---

## 6. The Pack Sync Problem in Detail

### 6.1 Pack Properties That Complicate Sync

Packs have properties that global/ and templates/ do not:

| Property | global/ | templates/ | Packs |
|---|---|---|---|
| Can be installed from remote | No | No | Yes (`.cco/source`) |
| Can be updated via CLI | No | No | Yes (`cco pack update`) |
| Affects running sessions | Yes (mounted) | No (used at create time) | Yes (mounted into Docker) |
| Has metadata files | `.cco/meta`, `.cco/base/` | `.cco/meta` | `.cco/meta`, `.cco/source` |
| Can change shared/exclusive | No (always shared) | No (always shared) | Yes (via profile add/remove) |

### 6.2 Shared Pack Update on Main

**Scenario**: User is on main, runs `cco pack update python-tools`.
The pack is updated from its remote source — files change.

```
State after update:
  main:    packs/python-tools/ = v2 (updated)
  org-a:    packs/python-tools/ = v1 (inherited, stale)
  personal: packs/python-tools/ = v1 (inherited, stale)
```

**How does the update reach profile branches?**

With S3 (sync on switch), the next time the user switches to org-a:
```bash
$ cco vault switch org-a
# Sync main → org-a:
#   packs/python-tools/ changed on main (v1 → v2)
#   packs/python-tools/ unchanged on org-a (still v1)
#   Only main changed → auto-copy v2 to org-a
#
# Result: org-a has updated python-tools
```

This works correctly. The pack update flows through the same shared
sync mechanism as any other shared resource change.

### 6.3 Shared Pack Update While on a Profile

**Scenario**: User is on profile "org-a", runs `cco pack update python-tools`.

```
State after update:
  main:  packs/python-tools/ = v1 (original)
  org-a: packs/python-tools/ = v2 (updated on org-a)
```

**How does the update reach main and other profiles?**

When the user switches away from org-a:
```bash
$ cco vault switch main
# Sync org-a → main:
#   packs/python-tools/ changed on org-a (v1 → v2)
#   packs/python-tools/ unchanged on main (still v1)
#   Only org-a changed → auto-copy v2 to main
#
# Result: main has updated python-tools
```

When the user later switches to personal:
```bash
$ cco vault switch personal
# Sync main → personal:
#   main has v2, personal has v1
#   Auto-copy v2 to personal
```

### 6.4 Shared Pack Updated on Main AND Profile (Conflict)

**Scenario**: User updates python-tools on main, then independently
edits python-tools while on org-a (or another update runs on org-a).

```
State:
  main:  packs/python-tools/rules.md = v2 (updated)
  org-a: packs/python-tools/rules.md = v3 (different edit)
```

On switch:
```bash
$ cco vault switch main
# Sync org-a → main:
#   rules.md changed on both sides since merge-base
#   → Interactive conflict prompt (L/R/M/D)
```

This is the correct behavior. The user must decide which version to keep
or merge them. The existing `_resolve_shared_conflict` function handles
this case.

### 6.5 Pack `.cco/source` and Remote Tracking

When a shared pack is updated via `cco pack update`, the `.cco/source`
file (which tracks the remote origin URL and last-checked timestamp)
is also modified. This is a tracked file that changes alongside the
pack content.

The sync mechanism handles this correctly — `.cco/source` is just another
file under `packs/<name>/` that gets synced along with all other pack
files. No special treatment needed.

### 6.6 Impact on Running Sessions

If a user is in a `cco start` session on profile org-a, and someone (or
another terminal) modifies shared packs on main, the running session is
not affected:
- Docker volume mounts are live but point to the org-a branch's files
- The vault branch has not switched, so org-a's version is still mounted
- Changes are picked up at next `vault switch` or `vault pull`

This is documented in `profile-isolation-analysis.md` §8.3 and is
acceptable behavior. Real-time sync into running sessions would require
filesystem watchers and is out of scope.

---

## 7. The `.vault-profile` Role in the New Model

### 7.1 Current Role (Tracking-Only Model)

In the tracking-only model, `.vault-profile` is the ONLY mechanism for
isolation. It declares which resources are exclusive to a profile, and
this declaration is used by:
- `vault sync` to scope `git add` to declared paths
- `vault push/pull` to determine which paths to sync
- `vault diff` and `vault status` to filter display
- `vault profile show` to display profile details

Without `.vault-profile`, the system has no way to know which resources
belong to which profile.

### 7.2 Role in the Real Isolation Model

With real isolation (git rm from source branches), the branch content
IS the truth:
- Files on the branch = visible resources
- Files NOT on the branch = invisible resources
- `git checkout` handles file appearance/disappearance automatically

**Does `.vault-profile` become redundant?**

No. `.vault-profile` remains valuable for several reasons:

1. **Sync scoping**: `vault sync` needs to know which paths to stage.
   Even with real isolation, the profile branch contains both shared
   resources (synced from main) and exclusive resources. Staging must
   include both types, but the code must know which packs are exclusive
   (listed in `.vault-profile`) vs shared (inferred by absence).

2. **Shared pack identification**: The shared sync mechanism (§3) must
   know which packs to sync from main. A pack NOT in any profile's
   `sync.packs` is shared. This information comes from `.vault-profile`.

3. **Profile metadata**: `.vault-profile` stores the profile name and
   provides a machine-readable way to detect "am I on a profile branch?"
   vs "am I on main?" Without it, the system would need heuristics (like
   checking if the branch name matches a known profile list).

4. **Delete operation**: `vault profile delete` reads `.vault-profile`
   to know which exclusive resources to move back to main before deleting
   the branch. Without it, the delete operation would need to diff the
   branch against main to find exclusive resources.

5. **Display**: `vault profile list`, `show`, and `status` use
   `.vault-profile` to display structured information about each profile.

### 7.3 What Changes in `.vault-profile` with Real Isolation?

The file format remains the same. The semantic meaning shifts slightly:

| Aspect | Tracking-Only | Real Isolation |
|---|---|---|
| `sync.projects` | "These projects are conceptually exclusive" | "These projects exist only on this branch" |
| `sync.packs` | "These packs are conceptually exclusive" | "These packs exist only on this branch" |
| Enforcement | At sync/push/pull time (selective staging) | At git level (files absent from other branches) |
| Source of truth | `.vault-profile` IS the truth | Branch content is the truth; `.vault-profile` is metadata |

The distinction between "IS the truth" and "is metadata" is important:
- In tracking-only, if `.vault-profile` says a project is exclusive
  but the file exists on main, the file IS visible on main (bug — the
  current problem)
- In real isolation, if `.vault-profile` says a project is exclusive,
  AND the file was git rm-ed from main, then the file is truly invisible
  on main. `.vault-profile` documents what was done; git enforces it.

### 7.4 Recommendation

Keep `.vault-profile` in the real isolation model. It serves as both
machine-readable metadata and an index of exclusive resources. The real
isolation model does not make it redundant — it makes it a consistent
descriptor of the actual branch state rather than a promise that may
not be enforced.

**One change**: In the real isolation model, `.vault-profile` should be
validated against branch content on `vault status` or `vault profile show`.
If a resource is listed as exclusive but does not exist on the branch
(or exists on main when it should not), warn the user. This catches
inconsistencies.

---

## 8. The Bidirectional Sync Detail

### 8.1 Why Sync Must Be Bidirectional on Switch

Section 3.6 introduced the idea that switching TO main should sync shared
changes FROM the departing profile. This deserves detailed analysis.

**Without departing-profile → main sync**:

```bash
$ cco vault switch org-a      # on org-a, edit global/.claude/CLAUDE.md
$ cco vault sync "update"     # committed on org-a
$ cco vault switch main       # NO sync: main still has old CLAUDE.md
$ cco vault switch personal   # sync main → personal: personal gets OLD version
```

The edit made on org-a is stuck on org-a until the next `vault push`.
Switching through main does not propagate it.

**With departing-profile → main sync**:

```bash
$ cco vault switch org-a      # on org-a, edit global/.claude/CLAUDE.md
$ cco vault sync "update"     # committed on org-a
$ cco vault switch main       # sync org-a → main: main gets updated CLAUDE.md
$ cco vault switch personal   # sync main → personal: personal gets updated version
```

The edit propagates immediately through the main branch relay.

### 8.2 Implementation Sketch

The enhanced switch flow:

```bash
cmd_vault_profile_switch() {
    local target="$1"
    local vault_dir="$USER_CONFIG_DIR"
    local current_branch=$(git -C "$vault_dir" rev-parse --abbrev-ref HEAD)
    local default_branch=$(_vault_default_branch)

    # Step 1: Auto-commit pending changes
    _vault_auto_commit

    # Step 2: If departing a profile → sync shared resources TO main
    local departing_profile=$(_get_active_profile)
    if [[ -n "$departing_profile" ]]; then
        _sync_shared_to_main_local "$vault_dir" "$current_branch"
    fi

    # Step 3: Stash gitignored files for departing profile (real isolation)
    _stash_gitignored_files "$vault_dir" "$current_branch"

    # Step 4: git checkout target
    git -C "$vault_dir" checkout "$target" -q

    # Step 5: Restore gitignored files for arriving profile
    _restore_gitignored_files "$vault_dir" "$target"

    # Step 6: If arriving at a profile → sync shared resources FROM main
    if [[ "$target" != "$default_branch" ]]; then
        _sync_shared_from_main_local "$vault_dir" "$target"
    fi
}
```

**Note**: `_sync_shared_to_main_local` and `_sync_shared_from_main_local`
are local variants of the existing `_sync_shared_to_default` and
`_sync_shared_from_default`. The difference: they work with local branches
(not `origin/main`) and do not push/pull from the remote.

### 8.3 Performance Implications

The bidirectional sync adds two `git diff` operations per switch (one for
departure, one for arrival) plus selective checkouts for changed files.

Typical vault sizes:
- Shared paths: 10-30 files (global config, templates, a few shared packs)
- Changed files per switch: 0-3 (most switches have no shared changes)

Expected overhead: <500ms for typical vaults. Acceptable.

### 8.4 Edge Case: Switching Between Two Non-Main Profiles

```bash
$ cco vault switch org-a    # from personal to org-a
```

The switch does NOT physically pass through main. But the sync must
logically relay through main:

1. Sync personal → main (departing profile's shared changes)
2. Checkout org-a (via git)
3. Sync main → org-a (shared changes, including what just arrived from personal)

This requires temporary branch operations:
- While still on personal: compare shared files with main, copy changed ones
  to main (using `git checkout main`, stage, commit, `git checkout personal`)
- Then checkout org-a
- Then compare org-a's shared files with main, copy changed ones from main

This is exactly what the existing `_sync_shared_to_default` does (it
checks out main, stages changes, commits, returns to profile). The
difference is the trigger (switch instead of push) and the source
(local main instead of remote).

---

## 9. Open Questions Resolved

### Q1: Which sync model?

**Answer**: Option S3 — Sync on Switch + Conflict Detection. See §3.3.

### Q2: Should projects be shared or exclusive?

**Answer**: Exclusive-only. See §5.6.

### Q3: How do shared pack updates propagate?

**Answer**: Through the same sync-on-switch mechanism as any shared
resource. See §6.2-6.3.

### Q4: Is `.vault-profile` still needed with real isolation?

**Answer**: Yes, as metadata and sync-scoping index. See §7.4.

### Q5: Should sync be bidirectional on switch?

**Answer**: Yes. Departing-profile → main sync ensures shared edits
propagate immediately, not just on push. See §8.1.

---

## 10. Decision Summary

| # | Decision | Rationale |
|---|---|---|
| R1 | global/ and templates/ are always shared, never exclusive | D10, D12 from original analysis. No mechanism needed. |
| R2 | Packs default to shared; can be made exclusive | Packs serve cross-context needs. Exclusive packs are the exception. |
| R3 | Projects are always exclusive (never shared) | Projects have context-specific state (secrets, sessions). Shared projects add complexity for weak use cases. |
| R4 | Sync model: S3 (on switch + conflict detection) | Balances freshness with safety. Works for local-only users. |
| R5 | Bidirectional sync on switch | Ensures shared edits propagate immediately via main as relay. |
| R6 | `.vault-profile` retained as metadata | Still needed for sync scoping, pack identification, profile detection. |
| R7 | Making a shared pack exclusive uses lazy cleanup | Remove from main + target profile, warn about other branches. No automatic multi-branch git rm. |
| R8 | No profiles = no behavioral change | All profile logic gated behind `_get_active_profile` checks. Backward compatible. |
| R9 | Switch-to-main syncs departing profile → main | Without this, shared edits on profiles are invisible on main until push. |

---

## 11. Implementation Impact

### 11.1 Changes to `cmd_vault_profile_switch`

Current implementation (3 lines — auto-commit, checkout, message) must
be expanded to include:
1. Departing profile → main shared sync
2. Gitignored file stash/restore (from `profile-isolation-analysis.md`)
3. Main → arriving profile shared sync

### 11.2 New Functions Needed

- `_sync_shared_to_main_local()` — local variant of `_sync_shared_to_default`
  (no remote push, works with local main)
- `_sync_shared_from_main_local()` — local variant of `_sync_shared_from_default`
  (no remote fetch, works with local main)
- `_stash_gitignored_files()` — move portable gitignored files to shadow dir
- `_restore_gitignored_files()` — restore portable gitignored files from shadow dir

### 11.3 Changes to Existing Sync Functions

`_sync_shared_to_default` and `_sync_shared_from_default` currently
compare against `origin/main`. The local variants compare against the
local `main` branch. Refactoring opportunity: extract a common
`_sync_shared()` function that takes source and target refs as parameters,
usable by both local switch and remote push/pull paths.

### 11.4 Changes to `vault move` (Make Pack Exclusive)

When making a shared pack exclusive:
1. Add to target profile's `.vault-profile`
2. `git rm` from main
3. Warn about other profile branches (do NOT auto-clean)

When making an exclusive pack shared:
1. Remove from profile's `.vault-profile`
2. Copy to main (`git checkout <profile> -- packs/<name>/` on main)
3. Pack is now on main and will sync to all profiles on next switch

---

## 12. Remaining Open Questions

### Q6: Should `vault sync` (local commit) also trigger shared sync?

Current recommendation: No. `vault sync` is a local commit operation.
Cross-branch sync happens on switch and push/pull. Adding sync to
`vault sync` would blur the boundary between "save my work" and
"propagate shared changes," making the command less predictable.

However, there is a scenario where this matters: a user on a profile
runs `vault sync`, then expects `vault push` to include their shared
edits on main. Currently, `vault push` handles this (it syncs shared
to main before pushing). So the existing flow is correct.

### Q7: What if the user never switches profiles?

If a user creates a profile and never switches (uses only one profile),
shared resources diverge from main indefinitely. This is acceptable:
- The user's profile branch is their working state
- If they push, shared resources sync to main
- If they never push, main remains at the fork-point state (which is
  fine — nobody is using main directly)
- If they later add a second profile, the first switch will sync all
  accumulated shared changes

### Q8: Maximum number of profiles?

No technical limit. Each profile is a git branch. Git handles thousands
of branches efficiently. The practical limit is cognitive — managing more
than 3-5 profiles becomes unwieldy. No enforcement needed.
