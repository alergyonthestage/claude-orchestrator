# Vault Profile CLI Namespace — Design Analysis

**Date**: 2026-03-24
**Status**: Analysis — pending design approval

**Note**: This is a supporting analysis document. The definitive design is in
`profile-isolation-design.md`. Some decisions in this analysis were revised
during the design discussion — the design document takes precedence.

**Scope**: CLI command structure for vault profile operations
**Input**: profile-isolation-analysis.md §4, current codebase, user feedback

> This document analyzes the full CLI namespace for vault profiles, proposes
> clean semantic boundaries, and recommends a concrete command structure. It
> supersedes §4 of profile-isolation-analysis.md for CLI design decisions.

---

## 1. Current Command Namespace Mapping

### 1.1 `cco project <subcommand>`

| Subcommand | Purpose | Modifies files? | Uses git? | Profile-aware? |
|---|---|---|---|---|
| `create <name>` | Scaffold project from template | Yes (creates dir) | No | No |
| `install <url>` | Install from Config Repo | Yes (creates dir) | No | No |
| `update <name>` | Update installed project | Yes (merges) | No | No |
| `publish <name> <remote>` | Publish as template | No (reads) | Yes (remote) | No |
| `internalize <name>` | Disconnect from remote | Yes (removes `.cco/source`) | No | No |
| `add-pack <proj> <pack>` | Add pack ref to project.yml | Yes (edits YAML) | No | No |
| `remove-pack <proj> <pack>` | Remove pack ref from project.yml | Yes (edits YAML) | No | No |
| `list` | List projects | No | No | No |
| `show <name>` | Show project details | No | No | No |
| `validate [name]` | Validate structure | No | No | No |

**Observation**: `cco project` operates on project **content and lifecycle** on
the local filesystem. It has no knowledge of vault, git branches, or profiles.
There is no `cco project delete` command.

### 1.2 `cco pack <subcommand>`

| Subcommand | Purpose | Modifies files? | Uses git? | Profile-aware? |
|---|---|---|---|---|
| `create <name>` | Scaffold pack | Yes (creates dir) | No | No |
| `install <url>` | Install from Config Repo | Yes (creates dir) | No | No |
| `update <name>` | Update from remote source | Yes (merges) | No | No |
| `publish <name> [remote]` | Publish to Config Repo | No (reads) | Yes (remote) | No |
| `export <name>` | Export as .tar.gz | Yes (creates archive) | No | No |
| `internalize <name>` | Disconnect from remote | Yes (removes `.cco/source`) | No | No |
| `list` | List packs | No | No | No |
| `show <name>` | Show pack details | No | No | No |
| `remove <name>` | **Delete pack from disk** | Yes (rm -rf) | No | No |
| `validate [name]` | Validate structure | No | No | No |

**Observation**: `cco pack` mirrors `cco project` for lifecycle management. It
DOES have a `remove` command that permanently deletes the pack from disk,
with a confirmation prompt if the pack is in use by projects. It also
refreshes `manifest.yml` after removal.

### 1.3 `cco vault <subcommand>`

| Subcommand | Purpose | Modifies files? | Uses git? |
|---|---|---|---|
| `init` | Initialize git repo | Yes (git init) | Yes |
| `sync [msg]` | Commit config state | Yes (git commit) | Yes |
| `diff` | Show uncommitted changes | No | Yes |
| `log` | Commit history | No | Yes |
| `restore <ref>` | Restore to a previous state | Yes (git checkout) | Yes |
| `status` | Vault state | No | Yes |
| `remote add/remove` | Manage git remotes | Yes (git remote) | Yes |
| `push [remote]` | Push to remote | No (pushes) | Yes |
| `pull [remote]` | Pull from remote | Yes (pulls) | Yes |
| `profile <subcmd>` | Profile management (see below) | Yes | Yes |

**Observation**: `cco vault` is the **git layer**. Every subcommand interacts
with the vault's git repository. `profile` is the only nested subcommand.

### 1.4 `cco vault profile <subcommand>`

| Subcommand | Purpose | Modifies files? | Uses git? |
|---|---|---|---|
| `create <name>` | Create profile (git branch) | Yes (branch + .vault-profile) | Yes |
| `list` | List profiles | No | Yes |
| `show` | Current profile details | No | Yes |
| `switch <name>` | Switch branches | Yes (git checkout) | Yes |
| `rename <new-name>` | Rename branch | Yes (git branch -m) | Yes |
| `delete <name>` | Delete profile (moves resources, deletes branch) | Yes | Yes |
| `add <type> <name>` | Mark resource as profile-exclusive | Yes (.vault-profile) | Yes |
| `remove <type> <name>` | Unmark from profile (make shared) | Yes (.vault-profile) | Yes |
| `move <type> <name> --to <target>` | Transfer resource between branches | Yes (git rm + checkout) | Yes |

**Observation**: `cco vault profile` mixes two distinct concerns:
1. **Profile CRUD**: create, list, show, switch, rename, delete — manage the
   profiles themselves
2. **Resource operations**: add, remove, move — manage which resources belong
   to which profile

This mixing, combined with the `vault profile` prefix, makes resource
operations very long (8 tokens for `move`).

---

## 2. Semantic Boundaries — Analysis

### 2.1 Proposed Boundaries

| Namespace | Semantic domain | Core question it answers |
|---|---|---|
| `cco project` | Project content and lifecycle | "What does this project contain?" |
| `cco pack` | Pack content and lifecycle | "What does this pack contain?" |
| `cco vault` | Versioning, sync, remote backup | "What's the git state of my config?" |
| `cco vault profile` | Profile lifecycle | "Which profiles exist, which is active?" |
| `cco vault <resource-ops>` | Resource placement across profiles | "Where does this resource live?" |

### 2.2 Ambiguity Analysis

**Ambiguity 1: `cco pack remove` vs `cco vault remove pack`**

- `cco pack remove <name>` — permanently deletes the pack directory from disk
  (current working branch). Refreshes manifest. Checks if in use by projects.
- `cco vault remove pack <name>` (proposed) — removes the pack from the
  current profile's branch, but it may still exist on other branches.

These are **different operations**. `cco pack remove` is a filesystem delete
that ignores git branches. `cco vault remove pack` is a git-level operation
that removes tracked files from the current branch. The distinction:

| | `cco pack remove` | `cco vault remove pack` |
|---|---|---|
| Scope | Current disk state | Current vault branch |
| Effect on other branches | None (irrelevant) | None (branch-scoped) |
| Effect on git | None (untracked delete) | `git rm` + commit |
| Requires vault? | No | Yes |
| Profile-aware? | No | Yes |

In practice, if the vault is active and the user is on a profile branch,
`cco pack remove` would delete from disk but NOT commit the removal — leaving
a dirty state that `vault sync` would then commit as a deletion. The two
commands converge in effect but differ in intent and safety.

**Recommendation**: Keep both, but clarify in help text.
- `cco pack remove` = "I want to delete this pack entirely, right now"
- `cco vault remove pack` = "I want to remove this pack from this profile (it
  may still live elsewhere)"

**Ambiguity 2: `cco project delete` (nonexistent) vs `cco vault remove project`**

Currently `cco project delete` does not exist. The user asks whether it should.
See section 3 below.

**Ambiguity 3: `switch` — profile operation or vault operation?**

`cco vault profile switch` is functionally a git checkout. It feels like a
vault operation (changing branches), but it's conceptually a profile operation
(changing workspace context). The user's most common interaction with profiles
is switching — it should be as short as possible.

**Recommendation**: Promote `switch` to `cco vault switch` as a shortcut.
Keep `cco vault profile switch` as an alias for discoverability.

---

## 3. The `cco project delete` Question

### 3.1 What Would `cco project delete` Do?

Without vault: delete the project directory from `user-config/projects/`.
Equivalent to `rm -rf user-config/projects/<name>/` plus manifest refresh.
This mirrors `cco pack remove`.

With vault: the same filesystem delete, but the user is on a specific branch.
The deletion affects only the current branch. Other branches still have the
project.

### 3.2 Comparison With `cco vault remove project`

| Aspect | `cco project delete` | `cco vault remove project` |
|---|---|---|
| Requires vault | No | Yes |
| Knows about branches | No | Yes |
| Checks other branches | No | **Yes** — warns if last copy |
| Git operations | None (raw rm) | `git rm` + commit |
| Safety checks | Confirmation prompt | Confirmation + last-copy check |
| Conceptual domain | "I don't want this project anymore" | "This project doesn't belong on this profile" |

### 3.3 Recommendation

**Create `cco project delete`**, but with important behavioral differences
from `cco pack remove`:

1. If vault is NOT active: delete directory, refresh manifest. Simple.
2. If vault IS active: **delegate to `cco vault remove project`**. This
   ensures proper git handling, branch awareness, and last-copy safety checks.
   Display a message: `"Vault is active. Removing from current branch (use
   'cco vault remove project' for branch-aware operation)."`

This means `cco project delete` becomes the "simple/intuitive" entry point
that vault-aware users can also reach via `cco vault remove project` for
more explicit control.

The same pattern applies to packs: `cco pack remove` already exists and
works without vault. No change needed for packs.

### 3.4 Should `cco project delete` Delete From ALL Branches?

No. A "delete from all branches" operation is dangerous and rarely needed.
If the user wants to completely purge a project from all profiles, they should
switch to each profile and remove it — or delete the profile itself. The extra
friction is intentional safety.

A `--everywhere` flag could be considered but should be deferred to avoid
scope creep. The common case is removing from one branch at a time.

---

## 4. Command Naming: `move`, `copy`, `remove`

### 4.1 `move`

`move` is the clear winner for transferring resources between profiles. It is:
- Universally understood (mv, Move-Item, drag-and-drop)
- Semantically accurate: the resource leaves the source and appears at the target
- Concise

Alternatives considered:
- `transfer` — too formal, longer, no additional clarity
- `assign` / `reassign` — implies soft reference, not physical file movement

**Recommendation**: `move` (verb: `cco vault move`).

### 4.2 `remove`

`remove` is the best option for taking a resource off the current profile.
Analysis of alternatives:

| Verb | Pros | Cons |
|---|---|---|
| `remove` | Standard, matches `cco pack remove` | Could be ambiguous: "remove from profile" vs "delete permanently" |
| `unassign` | Clear that it's un-linking, not deleting | Jargon; implies tracking-only model |
| `drop` | Short | Unclear — drop from what? |
| `delete` | Implies permanence | Too strong for a branch-scoped operation |

The ambiguity of `remove` is mitigated by context and help text: within
`cco vault`, operations are branch-scoped. The confirmation prompt shows
whether other copies exist, making the scope explicit.

**Recommendation**: `remove` (verb: `cco vault remove`). The help text and
confirmation prompt must clearly state: "Removing from profile 'X'. This
project also exists on: main, Y."

### 4.3 `copy` — Should It Exist?

The preliminary analysis (profile-isolation-analysis.md §10 Q3) already
questions whether `copy` should be exposed.

**Use cases for copy**:
1. Testing modifications without affecting the original — duplicate to a
   "sandbox" profile, experiment, then discard or keep
2. Having the same project available on multiple profiles — rare, since
   profiles are meant to segregate contexts

**Risks of copy**:
- Divergence: the same project on two branches drifts independently with
  no sync mechanism
- Confusion: users may not realize copies are independent
- Complexity: adds a third resource operation to learn and document

**Can `copy` be replaced by other operations?**
- Use case 1: `git stash` or a temporary branch achieves the same goal
- Use case 2: Projects can be "shared" by keeping them on main — no copy needed

**Recommendation**: Do NOT implement `copy` in the initial release. Keep the
command surface minimal: `move` and `remove` only. If users request `copy`
after real-world usage, it can be added later without breaking anything.
The preliminary analysis's Q3 can be resolved as: "Deferred — not needed
for v1 of real isolation."

---

## 5. Positional vs Flag Arguments

### 5.1 Current CLI Conventions

Examining existing cco commands for argument style:

| Command | Style | Example |
|---|---|---|
| `cco project create <name>` | Positional | `cco project create my-api` |
| `cco project add-pack <proj> <pack>` | Positional (2 args) | `cco project add-pack my-api react-tools` |
| `cco vault profile move <type> <name> --to <target>` | Mixed: positional + flag | `cco vault profile move project X --to Y` |
| `cco pack install <url>` | Positional | `cco pack install https://...` |
| `cco remote add <name> <url>` | Positional (2 args) | `cco remote add origin https://...` |
| `cco vault push [remote]` | Positional (optional) | `cco vault push origin` |
| `cco llms rename <old> <new>` | Positional (2 args) | `cco llms rename foo bar` |

**Pattern**: The codebase strongly favors **positional arguments** for resource
names and targets. Flags are used for options that modify behavior
(`--force`, `--yes`, `--template`), not for core arguments.

### 5.2 Comparing Styles for `move`

```bash
# Option A: Flag style (current)
cco vault move project org-a-api --to org-a       # 7 tokens

# Option B: Positional style (proposed)
cco vault move project org-a-api org-a             # 6 tokens

# Option C: All-flags style
cco vault move org-a-api --to org-a --type project # 8 tokens, worst
```

### 5.3 Readability Analysis

Option B reads naturally as English: "vault move project org-a-api [to] org-a".
The `project` keyword acts as a disambiguator — without it, `org-a-api org-a`
could be ambiguous about which argument is the resource and which is the destination.

With the `project`/`pack` keyword, the grammar is:
```
cco vault move <type> <name> <destination>
```

This is unambiguous because:
1. `<type>` is always `project` or `pack` (known keyword)
2. `<name>` is the resource name (validated against existing resources)
3. `<destination>` is the target profile (validated against existing profiles)

If the user swaps `<name>` and `<destination>`, the error message is clear:
"Project 'org-a' not found" or "Profile 'org-a-api' not found".

### 5.4 Tab-Completion Implications

Positional style enables richer tab-completion:
```
cco vault move <TAB>           → project, pack
cco vault move project <TAB>   → list of projects on current branch
cco vault move project X <TAB> → list of profiles (excluding current)
```

Flag style requires the shell to know that `--to` takes a profile name, which
is harder to implement in generic completion.

### 5.5 Recommendation

**Use positional arguments** for `move` and `remove`:
```bash
cco vault move project <name> <destination>    # 6 tokens
cco vault remove project <name>                # 5 tokens
```

Keep `--to` as an **accepted alias** for backward compatibility and for
users who find it more readable:
```bash
cco vault move project org-a-api --to org-a     # also works
```

Both forms are handled by the same parser — `--to` simply sets the target
variable, and positional args fill in order. This is a common CLI pattern
(e.g., `git remote rename` accepts both `git remote rename old new` and
some tools allow `--new-name`).

---

## 6. Shorthand and Aliases

### 6.1 Promoted Commands at `cco vault` Level

The most common daily operations should have the shortest paths. The
hybrid approach (Option E from profile-isolation-analysis.md) promotes
these from `cco vault profile` to `cco vault`:

| Operation | Long form | Short form | Token count |
|---|---|---|---|
| Switch profile | `cco vault profile switch X` | `cco vault switch X` | 4 |
| Move resource | `cco vault profile move project X Y` | `cco vault move project X Y` | 6 |
| Remove resource | `cco vault profile remove project X` | `cco vault remove project X` | 5 |

The long forms remain as aliases (the `profile` subcommand dispatches to
the same implementation).

### 6.2 Unix-Style Short Aliases (`mv`, `rm`)

```bash
cco vault mv project X Y    # alias for move
cco vault rm project X      # alias for remove
```

**Analysis**:
- Pros: Familiar to Unix users, shorter by 2-4 characters
- Cons: Inconsistent with the rest of cco (no other command uses short aliases);
  could confuse non-Unix users; adds complexity to the dispatch table and
  help text; very marginal time savings over `move`/`remove`
- The target user of cco is a developer who uses a terminal, so `mv`/`rm`
  are familiar — but within a structured CLI tool, full words are the norm
  (Docker uses `rm`, but Kubernetes uses `delete`; both work fine)

**Recommendation**: Do NOT add `mv`/`rm` aliases. The full words `move` and
`remove` are clear and consistent. If demand arises, aliases can be added
later with zero breaking changes.

### 6.3 Top-Level `cco switch`

```bash
cco switch org-a    # top-level shortcut for profile switch
```

**Analysis**:
- Pros: Maximum brevity (3 tokens)
- Cons: Occupies a top-level command slot; `switch` without context is ambiguous
  (switch what? project? profile? context?); creates a precedent for promoting
  vault subcommands to top level
- Future-proofing concern: if other features need a `switch` verb (e.g.,
  switching template sets or remote endpoints), the top-level slot is taken

**Recommendation**: Do NOT add `cco switch` as a top-level shortcut. The
gain (1 token saved over `cco vault switch`) is marginal. Users who want
brevity can create a shell alias: `alias vs='cco vault switch'`.

### 6.4 Dropping `profile` for CRUD Operations

Consider whether profile CRUD also needs shortening:

```bash
cco vault profile create X   # 5 tokens — infrequent, acceptable
cco vault profile list       # 4 tokens — infrequent, acceptable
cco vault profile show       # 4 tokens — acceptable
cco vault profile delete X   # 5 tokens — infrequent, acceptable
cco vault profile rename X   # 5 tokens — infrequent, acceptable
```

These are all infrequent operations (create: once per profile; delete: rare;
rename: very rare). The `profile` namespace provides clear grouping and
does not need shortening.

**Recommendation**: Keep profile CRUD at `cco vault profile <cmd>`. Only
promote `switch`, `move`, and `remove` to `cco vault <cmd>`.

---

## 7. UX Flows for Common Scenarios

### Flow 1: First-Time Profile Setup

User has 5 projects on main, wants to split into 2 profiles (org-a, personal).

```bash
# Create profiles
cco vault profile create org-a
cco vault profile create personal

# Move projects to org-a profile (from main)
cco vault move project org-a-api org-a
cco vault move project org-a-frontend org-a
cco vault move project org-a-backend org-a

# Move projects to personal profile
cco vault move project personal-blog personal
cco vault move project personal-dashboard personal

# Verify
cco vault profile list
# NAME      PROJECTS  PACKS  CURRENT
# main      0         3      *
# org-a     3         0
# personal  2         0
```

**Evaluation**: 7 commands for 5 projects across 2 profiles. Straightforward
and predictable. Each `move` command is 6 tokens. The only potential
improvement would be a batch command (`cco vault move project org-a-* org-a`)
but glob support adds complexity and is not justified for a one-time setup.

### Flow 2: Daily Profile Switching

```bash
# Start of day — switch to work context
cco vault switch org-a

# Start a session
cco start org-a-api

# ... work ...

# Switch to another client
cco vault switch personal
cco start personal-blog
```

**Evaluation**: 2 commands to switch and start. Clean and intuitive.
`cco vault switch` at 4 tokens is the minimum viable length that preserves
clear namespace hierarchy.

### Flow 3: Moving a Project Between Profiles

User decides project `shared-lib` should move from org-a to personal.

```bash
# Switch to the source profile (if not already there)
cco vault switch org-a

# Move the project
cco vault move project shared-lib personal

# Done — shared-lib is now on personal only
```

**Evaluation**: 2 commands (1 if already on the source profile). The user
must be on the source branch to move from it — this is consistent with
`git` semantics (you operate on the checked-out branch). An alternative
would be to allow specifying the source: `cco vault move project X --from org-a
--to personal`, but this adds complexity with minimal benefit.

### Flow 4: Adding a New Project to a Profile

User creates a new project and assigns it to a profile.

```bash
# Create the project (always created on current branch)
cco project create new-api --repo ~/code/new-api

# If on main, move to the intended profile
cco vault move project new-api org-a

# If already on the org-a branch, the project is already there
# (it was created on the current branch)
```

**Evaluation**: If the user is on the correct profile branch when they create
the project, it's automatically on that profile — zero extra commands.
If on main, one additional `move` command. This flow depends on users
understanding that `cco project create` operates on the current branch.

**Note**: `cco vault profile add` (the current `add` command) would be
deprecated since it was a tracking-only operation. With real isolation,
"add to profile" is equivalent to "move to profile from main", which `move`
already handles.

### Flow 5: Removing a Project From a Profile (Last Copy)

```bash
# Switch to the profile
cco vault switch org-a

# Remove the project
cco vault remove project old-project

# Output:
#   Removing project 'old-project' from profile 'org-a':
#     Tracked files: 8 files (.claude/, project.yml, memory/)
#     !! This project does NOT exist on any other branch !!
#   Proceed? [y/N]

# User confirms → project is deleted from the org-a branch
```

**Evaluation**: Clear, safe, with an explicit last-copy warning. The user
can cancel and `move` to another profile first if they want to preserve it.

---

## 8. Help Text and Discoverability

### 8.1 `cco vault --help` (Proposed)

```
Usage: cco vault <command>

Git-backed versioning and backup for your configuration.

Versioning:
  init                    Initialize vault (git repo in user-config/)
  sync [msg] [--yes]      Commit current state with secret detection
  diff                    Show uncommitted changes by category
  log [--limit N]         Show commit history
  restore <ref>           Restore config to a previous state
  status                  Show vault state and sync info

Profiles:
  switch <name>           Switch to another profile (shortcut)
  profile create <name>   Create a new vault profile
  profile list            List all profiles
  profile show            Show current profile details
  profile switch <name>   Switch to another profile
  profile rename <name>   Rename current profile
  profile delete <name>   Delete a profile

Resource placement:
  move <type> <name> <target>    Move project/pack to another profile
  remove <type> <name>           Remove project/pack from current profile

Remote backup:
  remote add <n> <url>    Add a git remote
  remote remove <n>       Remove a git remote
  push [<remote>]         Push to remote (default: origin)
  pull [<remote>]         Pull from remote (default: origin)

Run 'cco vault <command> --help' for command-specific options.
```

**Key design choices**:
- Group by activity type, not by implementation
- `switch` appears in both "Profiles" (full path) and as a shortcut
- "Resource placement" is a distinct section, reinforcing that `move`/`remove`
  are about WHERE resources live, not about lifecycle

### 8.2 `cco vault move --help`

```
Usage: cco vault move <project|pack> <name> <target>

Move a project or pack from the current profile to another profile or main.
The resource is removed from the current branch and added to the target.

Arguments:
  project|pack   Resource type
  name           Name of the project or pack to move
  target         Target profile name (or 'main' for the shared branch)

Examples:
  cco vault move project org-a-api org-a
  cco vault move project my-api main
  cco vault move pack corp-rules personal

Notes:
  - You must be on the source branch (where the resource currently lives)
  - Auto-commits pending changes before moving
  - Gitignored files (secrets.env, claude-state/) are moved alongside tracked files
  - Use 'cco vault profile list' to see available profiles
```

### 8.3 `cco vault remove --help`

```
Usage: cco vault remove <project|pack> <name> [--yes]

Remove a project or pack from the current profile.
The resource is deleted from the current branch's git history.

Arguments:
  project|pack   Resource type
  name           Name of the project or pack to remove

Options:
  --yes, -y      Skip confirmation prompt

Examples:
  cco vault remove project old-api
  cco vault remove pack deprecated-rules
  cco vault remove project old-api --yes

Notes:
  - Shows whether the resource exists on other branches
  - If this is the LAST copy, displays a strong warning
  - Suggests 'vault sync' before removing to save current state
  - Creates an automatic backup when removing the last copy
```

### 8.4 Error Messages

```bash
# Missing resource type
$ cco vault move org-a-api org-a
Error: Missing resource type. Usage: cco vault move <project|pack> <name> <target>

# Resource not found
$ cco vault move project nonexistent org-a
Error: Project 'nonexistent' not found on current branch.
Available projects: org-a-api, org-a-frontend, org-a-backend

# Target profile not found
$ cco vault move project org-a-api nonexistent
Error: Profile 'nonexistent' not found.
Available profiles: main, org-a, personal

# Already on target
$ cco vault move project org-a-api org-a
# (when already on org-a branch)
Error: Project 'org-a-api' is already on the current branch ('org-a').
Use 'cco vault switch <profile>' to change branches first.

# Not on the source branch
# (This case doesn't strictly apply since move operates FROM the current branch.
#  But if the project doesn't exist on the current branch, the "not found" error
#  above covers it.)
```

---

## 9. The `add` Command — Deprecation Analysis

### 9.1 Current `add` Semantics

`cco vault profile add project X` currently marks the project as exclusive in
`.vault-profile` without moving files. With real isolation, this tracking-only
behavior is obsolete — a project must physically exist on the branch to be
"on" that profile.

### 9.2 What Replaces `add`?

There are two scenarios where a user would say "add project X to profile Y":

1. **Project is on main, user wants it on a profile**: This is `move`.
   `cco vault move project X Y`.

2. **Project doesn't exist yet, user wants to create it on a profile**:
   Switch to the profile, then `cco project create`. The project is created
   on the current branch.

Neither scenario needs an `add` command.

### 9.3 Recommendation

**Deprecate `add`**. Remove it from the CLI. If invoked, show:
```
'cco vault profile add' has been removed.
To move a project to the current profile: cco vault move project <name> <current-profile>
To create a new project on the current profile: switch to the profile, then cco project create <name>
```

---

## 10. Backward Compatibility

### 10.1 Commands That Change

| Current command | New command | Breaking? |
|---|---|---|
| `cco vault profile switch X` | `cco vault switch X` (shortcut) | No — old path still works |
| `cco vault profile move project X --to Y` | `cco vault move project X Y` | No — old path still works via alias; `--to` accepted |
| `cco vault profile remove project X` | `cco vault remove project X` | No — old path still works |
| `cco vault profile add project X` | Deprecated (removed) | **Yes** — migration message shown |

### 10.2 New Commands

| Command | Description |
|---|---|
| `cco vault switch <name>` | Shortcut for profile switch |
| `cco vault move <type> <name> <target>` | Move resource (promoted) |
| `cco vault remove <type> <name>` | Remove resource (promoted) |
| `cco project delete <name>` | Delete project (new) |

### 10.3 Unchanged Commands

All `cco project`, `cco pack`, `cco vault profile create/list/show/rename/delete`,
`cco vault init/sync/diff/log/restore/status/push/pull` remain exactly as they are.

---

## 11. Recommendation — Final Command Structure

### 11.1 Design Principles

1. **Positional arguments** for resource names and targets (consistent with cco)
2. **Flags** for behavioral modifiers (`--yes`, `--force`, `--template`)
3. **Full words** for verbs (`move`, `remove`, `switch` — no `mv`/`rm`)
4. **Promoted shortcuts** for daily operations (`vault switch`, `vault move`, `vault remove`)
5. **Namespaced CRUD** for infrequent profile management (`vault profile create/delete/rename`)
6. **No `copy`** in initial release (deferred — see §4.3)
7. **No `add`** — deprecated, replaced by `move`
8. **`--to` accepted but not required** — positional target is primary

### 11.2 Complete Command Tree

```
cco vault
├── init
├── sync [msg] [--yes]
├── diff
├── log [--limit N]
├── restore <ref>
├── status
│
├── switch <name>                              # shortcut (4 tokens)
│
├── move <project|pack> <name> <target>        # promoted (6 tokens)
├── remove <project|pack> <name> [--yes]       # promoted (5 tokens)
│
├── profile
│   ├── create <name>
│   ├── list
│   ├── show
│   ├── switch <name>                          # alias for vault switch
│   ├── rename <new-name>
│   ├── delete <name> [--yes]
│   ├── move <project|pack> <name> <target>    # alias for vault move
│   └── remove <project|pack> <name> [--yes]   # alias for vault remove
│
├── remote
│   ├── add <name> <url>
│   └── remove <name>
├── push [<remote>]
└── pull [<remote>]
```

```
cco project
├── create <name> [--repo <path>] [--template <name>]
├── install <url>
├── update <name>
├── publish <name> <remote>
├── internalize <name>
├── delete <name> [--yes]                      # NEW
├── add-pack <project> <pack>
├── remove-pack <project> <pack>
├── list
├── show <name>
└── validate [name]
```

```
cco pack                                        # unchanged
├── create <name>
├── install <url>
├── update <name>
├── publish <name> [remote]
├── export <name>
├── internalize <name>
├── list
├── show <name>
├── remove <name> [--force]
└── validate [name]
```

### 11.3 Summary Table

| Command | Tokens | Purpose |
|---|---|---|
| **Daily operations** | | |
| `cco vault switch <name>` | 4 | Switch to a profile |
| `cco vault move project <name> <target>` | 6 | Move project to another profile |
| `cco vault move pack <name> <target>` | 6 | Move pack to another profile |
| `cco vault remove project <name>` | 5 | Remove project from current profile |
| `cco vault remove pack <name>` | 5 | Remove pack from current profile |
| | | |
| **Profile management (infrequent)** | | |
| `cco vault profile create <name>` | 5 | Create a new profile |
| `cco vault profile list` | 4 | List all profiles |
| `cco vault profile show` | 4 | Show current profile details |
| `cco vault profile rename <new-name>` | 5 | Rename current profile |
| `cco vault profile delete <name>` | 5 | Delete a profile |
| | | |
| **Project lifecycle** | | |
| `cco project create <name>` | 4 | Create new project |
| `cco project delete <name>` | 4 | Delete project from disk (**new**) |
| | | |
| **Versioning** | | |
| `cco vault sync [msg]` | 3-4 | Commit config changes |
| `cco vault diff` | 3 | Show uncommitted changes |
| `cco vault push` | 3 | Push to remote |
| `cco vault pull` | 3 | Pull from remote |

### 11.4 Justification Summary

| Decision | Rationale |
|---|---|
| Promote `switch`/`move`/`remove` to `vault` level | Saves 1 token on most-used commands; consistent with hybrid approach |
| Positional target for `move` | Matches cco conventions; enables better tab-completion; reads naturally |
| Accept `--to` as alias | Backward compatibility; some users prefer explicit flag |
| No `copy` command | Divergence risk; can be added later; `move` + re-create covers use cases |
| Deprecate `add` | Incompatible with real isolation; replaced by `move` |
| New `cco project delete` | Symmetry with `cco pack remove`; delegates to vault when active |
| No `mv`/`rm` aliases | Inconsistent with cco style; marginal gain |
| No top-level `cco switch` | Ambiguous; occupies a valuable top-level slot |
| Profile CRUD stays namespaced | Infrequent operations; grouping aids discoverability |

---

## 12. Open Questions

### Q1: Should `move` Require Being on the Source Branch?

Currently, `move` operates from the current branch. Should it support
`--from <source>` to move resources without switching first?

**Tradeoff**: `--from` adds flexibility but makes the command longer (8 tokens
with `--from` flag). The current approach (must be on source) is simpler and
consistent with git semantics.

**Recommendation**: Defer `--from` to a later version. If users find the
switch-then-move flow painful, it can be added.

### Q2: Batch Operations?

Should `move` and `remove` accept multiple names?

```bash
cco vault move project org-a-api org-a-frontend org-a-backend org-a    # batch move
```

**Tradeoff**: Useful for first-time setup; adds parser complexity.

**Recommendation**: Defer. First-time setup is a one-time event. Users can
run multiple commands or use a shell loop.

### Q3: How Should `cco vault profile delete` Interact With `remove`?

Currently, `profile delete` moves all exclusive resources to main, then
deletes the branch. With real isolation, "move to main" means the files
appear on main. Should the user be given a choice: move to main, move to
another profile, or discard?

**Recommendation**: Design decision for the profile-isolation design doc.
Not a CLI namespace question.

### Q4: Tab-Completion Script

Should a bash/zsh completion script be implemented alongside the CLI changes?

**Recommendation**: Yes, but as a follow-up task. The positional argument
design was chosen partly to enable good completion, so this should be
planned.
