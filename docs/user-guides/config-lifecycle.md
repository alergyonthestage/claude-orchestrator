# Configuration Lifecycle

> Managing vault, profiles, updates, publishing, and installing — a unified guide.
>
> Related: [sharing.md](./sharing.md) | [project-setup.md](./project-setup.md) | [knowledge-packs.md](./knowledge-packs.md) | [cli.md](../reference/cli.md)

---

## 1. The Big Picture

CCO manages your configuration across three dimensions:

| Dimension | What it solves | Key commands |
|-----------|---------------|--------------|
| **Vault** | Versioning and backup | `cco vault sync`, `push`, `pull` |
| **Profiles** | Multi-context isolation (work, personal) | `cco vault profile create`, `switch` |
| **Updates** | Keeping config current with framework and publishers | `cco update`, `cco project update` |
| **Sharing** | Publishing and installing projects and packs | `cco project publish`, `cco project install` |

These are not independent features — they form a coherent lifecycle:

```
Create / Install → Customize → Vault sync → Update → Publish / Share
       ↑                                        │
       └────────────────────────────────────────┘
```

---

## 2. Vault — Version Your Configuration

The vault is a git-backed versioning system for your entire `user-config/`
directory. Think of it as "git for your Claude configuration".

### 2.1 Getting Started

```bash
cco vault init          # Initialize git repo in user-config/
cco vault sync          # Commit current state (with secret detection)
cco vault push          # Push to remote (set up a private GitHub repo)
cco vault pull          # Pull changes from remote
```

### 2.2 Daily Workflow

1. **Work on your projects** — edit rules, create packs, customize CLAUDE.md
2. **Sync periodically** — `cco vault sync "added deploy pack"` commits your
   changes with a descriptive message
3. **Push to remote** — `cco vault push` backs up to your private repo

The vault includes **secret detection**: it scans for `.env` files, API keys,
credentials, and other sensitive patterns before committing. If secrets are
found, the commit is blocked with a clear message.

### 2.3 Inspecting Changes

```bash
cco vault diff          # Show uncommitted changes by category
cco vault log           # Show commit history
cco vault status        # Show vault state (branch, clean/dirty, remote)
cco vault restore       # Restore a file from a previous commit
```

---

## 3. Profiles — Multi-Context Isolation

Profiles let you maintain separate configuration contexts on the same machine.
Each profile is a git branch with isolated resources.

### 3.1 When to Use Profiles

- **Work vs personal**: different projects, different conventions, different packs
- **Client A vs Client B**: separate project sets per client
- **Shared vs private**: some packs are shared across profiles, others are exclusive

### 3.2 Creating and Switching

```bash
cco vault profile create work       # Create "work" profile
cco vault profile create personal   # Create "personal" profile
cco vault profile switch work       # Switch to "work" context
cco vault profile list              # Show all profiles
cco vault profile show              # Show current profile details
```

### 3.3 Resource Isolation

Projects can be **exclusive** to a profile (visible only when that profile
is active) or **shared** (visible in all profiles via `main` branch).

```bash
# Make a project exclusive to the current profile
cco vault profile add project my-work-app

# Make a pack exclusive to the current profile
cco vault profile add pack work-conventions

# Release a resource back to shared
cco vault profile remove project my-work-app
```

### 3.4 Profile Sync Strategy

When you switch profiles, resources sync automatically. For **shared
resources** (packs, global settings) that were modified in another profile:

- CCO detects the conflict between your profile's version and main
- An interactive prompt lets you choose: keep yours, take main's, or merge

**Best practice**: keep shared resources stable. Profile-specific customizations
should go in exclusive resources. If you need different versions of a shared
pack, make a copy exclusive to each profile instead of constantly merging.

### 3.5 Moving Resources Between Profiles

```bash
# Move a project from current profile to another
cco vault profile move project my-app --to personal

# Remove exclusivity (make shared again)
cco vault profile remove project my-app
```

---

## 4. Updates — Keeping Config Current

CCO has two sources of updates:

1. **Framework updates**: the CCO framework improves its default rules, agents,
   skills, and templates
2. **Publisher updates**: when you install a project or pack from a Config Repo,
   the publisher may release new versions

### 4.1 Checking for Updates

```bash
cco update              # Check everything: migrations, framework, remotes, changelog
```

This is the single "what's new?" command. It shows:

- Pending migrations (applied automatically)
- Framework file changes available for review
- Publisher updates available for installed projects and packs
- New features in the changelog

### 4.2 Applying Framework Updates

```bash
cco update --sync              # Interactive merge for all framework changes
cco update --sync global       # Only global config
cco update --sync my-project   # Only one project
cco update --diff              # Preview changes without applying
```

The interactive merge offers per-file options:

| Option | What it does |
|--------|-------------|
| **(A)pply** | Accept the framework version (when you haven't modified the file) |
| **(M)erge** | 3-way merge preserving your changes and adding framework improvements |
| **(R)eplace** | Overwrite with framework version, save yours as `.bak` |
| **(K)eep** | Keep your version unchanged |
| **(S)kip** | Same as Keep |
| **(N)ew-file** | Save framework version as `.new` for manual review later |
| **(D)iff** | Show the differences before deciding |

**Tip**: if you've heavily restructured a file (reordered sections, reorganized
content), use **(N)ew-file** instead of **(M)erge** — it gives you the
framework version as a separate file for manual comparison.

### 4.3 Applying Publisher Updates

For projects installed from a Config Repo:

```bash
cco project update team-service        # Update one project from its publisher
cco project update --all               # Update all installed projects
cco project update team-service --dry-run  # Preview without applying
```

This fetches the latest version from the publisher and offers the same
interactive merge. Your local customizations are preserved through the 3-way
merge.

For packs:

```bash
cco pack update react-guidelines       # Update one pack from its publisher
cco pack update --all                  # Update all installed packs
```

Packs use **full-replace** (not merge). If you've customized a pack locally,
internalize it first to preserve your changes (see §4.5).

### 4.4 Understanding the Update Chain

For installed projects, updates flow through a chain:

```
Framework defaults → Publisher's project → Your installation
```

When the framework releases new defaults:

- **Local projects** (created with `cco project create`): you apply framework
  updates directly via `cco update --sync`.
- **Installed projects** (created with `cco project install`): the publisher is
  expected to integrate framework improvements and publish an updated version.
  You receive them via `cco project update`.

This means installed projects may lag behind framework updates — intentionally.
The publisher curates which framework changes make sense for their project.

**If the publisher is slow or inactive**, you have two options:

```bash
# Option 1: Apply framework updates directly (temporary override)
cco update --sync team-service --local

# Option 2: Disconnect permanently and manage as local
cco project internalize team-service
```

### 4.5 Internalizing a Resource

To permanently disconnect a project from its remote source:

```bash
cco project internalize team-service
```

After internalizing:
- The project becomes fully local
- Framework updates apply directly via `cco update --sync`
- Publisher updates are no longer checked or available
- Your customizations are fully preserved

Use this when:
- The publisher has abandoned the project
- You want to diverge permanently from the published version
- You installed the project as a starting point, not for ongoing sync

Packs can also be internalized:

```bash
cco pack internalize react-guidelines
```

---

## 5. Publishing — Sharing Your Work

### 5.1 Setting Up a Config Repo

```bash
# Register a remote
cco remote add my-remote https://github.com/me/my-config-repo.git

# If the repo requires authentication
cco remote add my-remote https://github.com/me/my-config-repo.git --token ghp_xxx
```

### 5.2 Publishing a Project

```bash
cco project publish my-project my-remote
```

The publish pipeline includes safety checks:

1. **Migration check** — your project must be up to date with the latest
   framework schema. If not, you are asked to run `cco update` first.
2. **Framework alignment** — if framework defaults have updates you haven't
   applied, you receive a warning (non-blocking).
3. **Secret scan** — files are scanned for API keys, credentials, `.env` content.
   Publishing is blocked if secrets are detected.
4. **Diff review** — you see a per-file diff of what changed since the last
   publish, and confirm each file individually.

### 5.3 Excluding Files from Publish

Create `.cco/publish-ignore` in your project directory (gitignore syntax):

```
# Personal notes and local rules
.claude/rules/local-*.md
.claude/rules/personal-*.md

# Session data
memory/

# Draft content
*.draft
*.local
```

Files matching these patterns are automatically excluded from every publish.

### 5.4 Publishing Packs

```bash
cco pack publish my-pack my-remote
```

Same safety checks apply. Packs are typically simpler (fewer files, less
customization) so the review is usually quick.

---

## 6. Installing — Using Shared Resources

### 6.1 Installing a Project

```bash
cco project install https://github.com/team/config-repo.git
```

This:
1. Fetches the project template from the Config Repo
2. Resolves template variables (prompts for values like project name)
3. Installs packs referenced by the project
4. Records the source in `.cco/source` for future updates

### 6.2 Installing Packs

```bash
cco pack install https://github.com/team/config-repo.git
```

You can select which packs to install from the remote's manifest.

### 6.3 After Installation

Your installed resources are fully yours — you can customize them freely.
The connection to the source is maintained for updates, but the publisher
cannot force changes on you. Every update goes through interactive merge
where you choose what to accept.

---

## 7. Recommended Workflows

### 7.1 Solo Developer — Single Machine

```bash
# Initial setup
cco init
cco vault init
cco project create my-app

# Daily work
# ... work on your projects ...
cco vault sync "end of day snapshot"
cco vault push

# Periodic maintenance
cco update                    # Check for framework updates
cco update --sync             # Apply improvements you like
```

### 7.2 Solo Developer — Multiple Machines

```bash
# Machine A (primary)
cco vault sync "added new pack"
cco vault push

# Machine B (secondary)
cco vault pull                # Get latest config
# ... work ...
cco vault sync "changes from machine B"
cco vault push

# Back on Machine A
cco vault pull                # Get Machine B's changes
```

### 7.3 Team — Publisher Workflow

The publisher maintains a Config Repo and distributes projects/packs to the team.

```bash
# Setup
cco remote add team https://github.com/company/team-config.git

# Create and customize a project template
cco project create api-service
# ... customize CLAUDE.md, rules, skills ...

# Publish to team
cco project publish api-service team

# When framework updates arrive
cco update --sync api-service    # Apply framework improvements
# ... review and adjust for team context ...
cco project publish api-service team   # Publish updated version
```

**Best practices for publishers**:

- **Run `cco update` before publishing** — keep your projects aligned with the
  latest framework version. Consumers expect published projects to be current.
- **Review framework changes in context** — not every framework default fits
  every team. Apply what makes sense, skip what doesn't.
- **Use `.cco/publish-ignore`** — exclude personal notes, local paths, and
  draft content from publications.
- **Communicate changes** — use the `version` field in your project metadata
  and commit messages to help consumers understand what changed.

### 7.4 Team — Consumer Workflow

Consumers install from the team's Config Repo and customize for their needs.

```bash
# Install team project
cco project install https://github.com/company/team-config.git

# Customize for your needs
# ... add personal rules, modify CLAUDE.md ...

# Check for updates
cco update                     # See if publisher has updates
cco project update api-service # Apply publisher updates (merge preserves your changes)

# Vault your customizations
cco vault sync "customized api-service"
cco vault push
```

**Best practices for consumers**:

- **Customize freely** — your changes are preserved through 3-way merge when
  updates arrive. Don't be afraid to adapt the project to your needs.
- **Prefer additive customizations** — adding new rules and skills causes fewer
  merge conflicts than heavily rewriting existing ones.
- **Use `cco project update` regularly** — smaller, frequent updates are easier
  to merge than large, infrequent ones.
- **Vault before updating** — `cco vault sync` before `cco project update`
  gives you a restore point if something goes wrong.

### 7.5 Multi-Context with Profiles

For developers working across multiple organizations or contexts:

```bash
# Create profiles
cco vault profile create org-a
cco vault profile create personal

# Add projects to profiles
cco vault profile switch org-a
cco project install https://github.com/org-a/config.git
cco vault profile add project org-a-api

cco vault profile switch personal
cco project create side-project
cco vault profile add project side-project

# Daily switching
cco vault profile switch org-a    # See only org-a projects
# ... work ...
cco vault profile switch personal # See only personal projects
```

**Shared resources** (global settings, common packs) are available in all
profiles. Make packs exclusive to a profile only when they genuinely conflict
with other contexts.

### 7.6 Minimizing Merge Conflicts

Merge conflicts happen when the publisher and consumer modify the same lines
of the same file. To minimize them:

1. **Publishers**: make structural changes in dedicated commits. Avoid mixing
   content changes with formatting or reorganization.
2. **Consumers**: prefer adding new files over modifying existing ones. A new
   `rules/my-extra-rule.md` never conflicts with publisher updates.
3. **Both**: keep CLAUDE.md sections clearly separated. The publisher provides
   architecture and conventions; the consumer adds project-specific notes in
   dedicated sections.
4. **When conflicts occur**: the interactive merge shows the diff clearly.
   Choose **(M)erge** for line-level conflicts the merge tool can handle.
   Choose **(N)ew-file** when the file has been restructured and line-level
   merge would produce confusing results.
5. **Vault before updating**: always `cco vault sync` before running
   `cco project update`. This gives you a clean restore point.

---

## 8. Command Reference

### 8.1 Vault

| Command | Purpose |
|---------|---------|
| `cco vault init` | Initialize git-backed config versioning |
| `cco vault sync [message]` | Commit changes (with secret detection) |
| `cco vault diff` | Show uncommitted changes |
| `cco vault log` | Show commit history |
| `cco vault status` | Show vault state |
| `cco vault push` | Push to remote |
| `cco vault pull` | Pull from remote |
| `cco vault restore` | Restore file from history |

### 8.2 Profiles

| Command | Purpose |
|---------|---------|
| `cco vault profile create <name>` | Create a new profile |
| `cco vault profile list` | List all profiles |
| `cco vault profile show` | Show current profile |
| `cco vault profile switch <name>` | Switch active profile |
| `cco vault profile rename <name>` | Rename current profile |
| `cco vault profile delete <name>` | Delete profile (moves resources to main) |
| `cco vault profile add project/pack <name>` | Make resource exclusive to profile |
| `cco vault profile remove project/pack <name>` | Make resource shared again |
| `cco vault profile move project <name> --to <profile>` | Move resource between profiles |

### 8.3 Updates

| Command | Purpose |
|---------|---------|
| `cco update` | Unified discovery (migrations + framework + remotes + changelog) |
| `cco update --sync [scope]` | Interactive framework file merge |
| `cco update --sync <project> --local` | Force framework sync on installed project |
| `cco update --diff [scope]` | Preview framework changes |
| `cco update --news` | Show changelog details |
| `cco update --offline` | Skip remote source checks |
| `cco project update <name>` | Fetch and merge publisher updates |
| `cco project update --all` | Update all installed projects |
| `cco pack update <name>` | Update pack from remote (full-replace) |
| `cco pack update --all` | Update all installed packs |

### 8.4 Publishing

| Command | Purpose |
|---------|---------|
| `cco project publish <name> <remote>` | Publish with safety pipeline |
| `cco project publish <name> <remote> --yes` | Publish without interactive prompts |
| `cco pack publish <name> [remote]` | Publish pack to Config Repo |

### 8.5 Source Management

| Command | Purpose |
|---------|---------|
| `cco project install <url>` | Install project from Config Repo |
| `cco pack install <url>` | Install packs from Config Repo |
| `cco project internalize <name>` | Disconnect from remote, convert to local |
| `cco pack internalize <name>` | Disconnect pack from remote source |
