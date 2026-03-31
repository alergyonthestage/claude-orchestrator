# Configuration Management

> Vault, profiles, Config Repos, publishing, installing, and updates — a unified guide.
>
> Related: [project-setup.md](./project-setup.md) | [knowledge-packs.md](./knowledge-packs.md) | [cli.md](../reference/cli.md)

---

## 1. The Big Picture

CCO manages your configuration across four dimensions:

| Dimension | What it solves | Key commands |
|-----------|---------------|--------------|
| **Vault** | Versioning and backup | `cco vault save`, `push`, `pull` |
| **Profiles** | Multi-context isolation (work, personal) | `cco vault profile create`, `switch` |
| **Updates** | Keeping config current with framework and publishers | `cco update`, `cco project update` |
| **Sharing** | Publishing and installing projects and packs | `cco project publish`, `cco pack install` |

These form a coherent lifecycle:

```
Create / Install → Customize → Vault save → Update → Publish / Share
       ↑                                        │
       └────────────────────────────────────────┘
```

---

## 2. Vault — Version Your Configuration

The vault is a git-backed versioning system for your entire `user-config/` directory.

### Getting started

```bash
cco vault init          # Initialize git repo in user-config/
cco vault save          # Commit current state (with secret detection)
cco vault push          # Push to remote (set up a private GitHub repo)
cco vault pull          # Pull changes from remote
```

Add a remote for backup:

```bash
cco vault remote add origin git@github.com:youruser/cco-vault.git
```

### Day-to-day workflow

1. **Work on your projects** — edit rules, create packs, customize CLAUDE.md
2. **Save periodically** — `cco vault save "added deploy pack"` commits with a descriptive message
3. **Push to remote** — `cco vault push` backs up to your private repo

`cco vault save` shows a categorized summary before committing and includes
**secret detection**: it scans for `.env` files, API keys, credentials, and
other sensitive patterns. If secrets are found, the commit is blocked.

> **Note**: `vault sync` is a deprecated alias for `vault save`.

### Path portability

When you `vault save`, repo and mount paths in `project.yml` are replaced with
`@local` markers. Real paths are stored in `.cco/local-paths.yml` (gitignored,
per-machine). On `vault pull` to a different machine, `cco start` detects
unresolved `@local` entries and prompts to clone or specify local paths.

To pre-configure paths without starting a session:

```bash
cco project resolve myapp                          # Interactive
cco project resolve myapp --repo backend ~/dev/be  # Direct set
cco project resolve myapp --show                   # Show status
```

This applies to both vault save/push/pull and Config Repo install/publish. You
write real paths — the system handles portability transparently.

### Inspecting changes

```bash
cco vault diff          # Show uncommitted changes by category
cco vault log           # Show commit history
cco vault status        # Show vault state (branch, clean/dirty, remote)
cco vault restore       # Restore a file from a previous commit
```

---

## 3. Profiles — Multi-Context Isolation

Profiles let you maintain separate configuration contexts on the same machine.
Each profile is a git branch with **real git-level isolation** — projects
exist on exactly one branch at a time.

### When to use profiles

- **Work vs personal**: different projects, different conventions, different packs
- **Client A vs Client B**: separate project sets per client
- **Shared vs private**: some packs are shared across profiles, others are exclusive

### Creating and switching

New profiles start **empty** — only shared resources (global config, templates,
shared packs) are visible. Use `vault move` to assign projects to a profile.

```bash
cco vault profile create work       # Create "work" profile (empty)
cco vault profile create personal   # Create "personal" profile (empty)
cco vault switch work               # Switch to "work" context
cco vault profile list              # Show all profiles
cco vault profile show              # Show current profile details
```

Switching requires a **clean working tree** (run `cco vault save` first) and
**no active Docker sessions**. This prevents data loss during branch checkout.

### Resource isolation

Each project exists on exactly **one branch** — either `main` (the default)
or a profile branch. Moving a project physically relocates its files via git.
`vault move` auto-detects where the resource is tracked — you don't need to
be on the source branch.

```bash
cco vault move project my-api work           # Move project to "work" profile
cco vault move pack work-conventions work     # Move pack to "work" profile
cco vault move project my-api main           # Move back to shared (main)
```

**Project names must be unique** across all branches. You cannot create a project
with the same name on two different profiles.

Global config, templates, and packs not assigned to any profile remain
**shared** on `main` and are visible from all profiles.

### Profile workflow example

```bash
# 1. Create a work profile
cco vault profile create work

# 2. Assign projects to it
cco vault move project api work
cco vault move project frontend work

# 3. Switch to work context
cco vault switch work

# 4. Work and save
cco start api
cco vault save "end of day"

# 5. Switch back to main when done
cco vault switch main
```

### Inspecting profiles

`profile show` displays details about the current context — whether on a profile
or on main:

```bash
cco vault profile show     # Shows projects, packs, shared resources, sync state
cco vault profile list     # Lists all profiles with resource counts + main summary
```

### Deleting profiles

Empty profiles can be deleted directly. Non-empty profiles require `--force`,
which moves all exclusive resources back to main before deleting the branch:

```bash
cco vault profile delete old-profile              # Fails if has projects/packs
cco vault profile delete old-profile --force       # Moves resources to main first
```

### Data safety

CCO protects your files during profile operations:

- **Verify-before-delete**: transfer operations (profile create, vault move)
  never delete files that weren't properly saved. Unknown files are preserved
  with a warning.
- **Self-healing**: if you use `git checkout` directly (bypassing `cco vault
  switch`), the next `cco` command auto-restores portable files from the shadow.
- **Shared pack guards**: removing a shared pack from a profile is blocked
  (it would be re-synced). Remove from main instead.

### Shadow directory

Profile switches use a shadow directory (`.cco/profile-state/`) to preserve
portable gitignored files (like session state) across branch checkouts. This
is automatic and transparent.

### Shared resource sync

When you push or pull, shared resources (global config, templates, shared packs)
are synced between the profile branch and `main`. If both sides modified the
same shared file, CCO offers interactive conflict resolution.

**Best practice**: keep shared resources stable. Profile-specific customizations
should go in exclusive resources.

Without profiles, the vault works on a single `main` branch. Profiles are
opt-in and only needed when you want project isolation.

---

## 4. Config Repos & Sharing

CCO uses git repositories for configuration distribution. There are two
distinct use cases:

### Vault vs Config Repo

| | Vault | Shared Config Repo |
|---|---|---|
| **Purpose** | Personal backup & multi-PC sync | Team/community distribution |
| **Visibility** | Private (single owner) | Team, org, or public |
| **Content** | Everything (global, projects, packs, memory, templates) | Only packs and templates |
| **Flow** | push/pull (bidirectional sync) | publish → install (one-way distribution) |
| **Commands** | `cco vault push/pull/save` | `cco pack publish/install`, `cco project publish/install` |

> **Important**: Never share your vault with teammates. It contains personal
> settings, memory, and project configurations. Always use a dedicated Config
> Repo with `publish`/`install` for team sharing.

### Config Repo structure

```
my-config-repo/
├── manifest.yml           # Declares available packs and templates
├── .gitignore
├── packs/
│   ├── react-guidelines/
│   │   ├── pack.yml
│   │   ├── knowledge/
│   │   ├── skills/
│   │   ├── agents/
│   │   └── rules/
│   └── deploy-patterns/
│       └── ...
└── templates/
    └── microservice/
        ├── project.yml
        └── .claude/
```

When someone runs `cco pack install` against your repo, only `packs/` and
`templates/` are available.

### manifest.yml

Every Config Repo contains a `manifest.yml` at the root, declaring available
packs and templates. CCO generates and maintains it automatically.

```yaml
name: "acme-team-config"
description: "Engineering configuration for ACME Corp"

packs:
  - name: acme-conventions
    description: "Code style, commit conventions, and review standards"
    tags: [conventions, style]

templates:
  - name: acme-service
    description: "Microservice template with standard ACME setup"
    tags: [microservice, fastapi]
```

Managing the manifest:

```bash
cco manifest refresh     # Regenerate from disk (preserves custom metadata)
cco manifest validate    # Cross-check manifest vs disk
cco manifest show        # Formatted view of contents
```

---

## 5. Installing Resources

### Installing packs

```bash
cco pack install https://github.com/acme/cco-config              # All packs
cco pack install https://github.com/acme/cco-config --pick acme-conventions  # Specific pack
cco pack install https://github.com/acme/cco-config --force       # Overwrite existing
```

By default, if a pack exists locally: same-source updates automatically,
different-source aborts (use `--force` to overwrite).

Single-pack repositories (with `pack.yml` at root, no `manifest.yml`) are
recognized and installed directly.

### Installing project templates

```bash
cco project install https://github.com/acme/cco-config --pick acme-service
cco project install https://github.com/acme/cco-config --pick acme-service --as my-api
```

Templates may contain `{{VARIABLE}}` placeholders resolved at install time.
Pre-set values with `--var`:

```bash
cco project install https://github.com/acme/cco-config \
  --pick acme-service --as my-api \
  --var DESCRIPTION="My REST API" --var DB_NAME=myapp_db
```

### Authentication and ref pinning

```bash
# SSH (uses existing key)
cco pack install git@github.com:my-org/cco-config

# HTTPS with saved token
cco remote add team https://github.com/my-org/cco-config.git --token ghp_xxx
cco pack install https://github.com/my-org/cco-config.git   # token auto-resolved

# Pin to branch or tag
cco pack install https://github.com/acme/cco-config@v2.0
```

See [Authentication — Config Repo Authentication](./authentication.md#config-repo-authentication) for full details.

### After installation

Installed resources are fully yours — customize freely. The connection to the
source is maintained for updates, but the publisher cannot force changes.
Every update goes through interactive merge where you choose what to accept.

---

## 6. Publishing

### Setting up a remote

```bash
cco remote add my-remote https://github.com/me/my-config-repo.git
cco remote add my-remote https://github.com/me/my-config-repo.git --token ghp_xxx
```

### Publishing projects

```bash
cco project publish my-project my-remote
```

The publish pipeline includes safety checks:

1. **Migration check** — project must be on latest schema version
2. **Framework alignment** — warns if defaults have pending updates (non-blocking)
3. **Secret scan** — blocks if secrets are detected
4. **Publish-ignore** — excludes files matching `.cco/publish-ignore` patterns
5. **Diff review** — per-file diff vs last published version
6. **Per-file confirmation** — choose to publish or skip each file

Exclude files via `.cco/publish-ignore` (gitignore syntax):

```
.claude/rules/local-*.md
*.draft
memory/
```

Non-interactive publish: `cco project publish my-project my-remote --yes`

### Publishing packs

```bash
cco pack publish my-pack my-remote
```

Same safety checks apply.

### Exporting packs (without git)

```bash
cco pack export acme-conventions     # Creates acme-conventions.tar.gz
```

The recipient extracts into their packs directory:

```bash
tar xzf acme-conventions.tar.gz -C user-config/packs/
```

---

## 7. Updates

CCO has two sources of updates:

1. **Framework updates**: improved default rules, agents, skills, templates
2. **Publisher updates**: new versions from Config Repo publishers

### Checking for updates

```bash
cco update              # Unified discovery: migrations + framework + remotes + changelog
```

### Framework updates

```bash
cco update --sync              # Interactive merge for all framework changes
cco update --sync global       # Only global config
cco update --sync my-project   # Only one project
cco update --diff              # Preview changes without applying
cco update --news              # Show changelog details
```

The interactive merge offers per-file options:

| Option | What it does |
|--------|-------------|
| **(A)pply** | Accept framework version (when you haven't modified the file) |
| **(M)erge** | 3-way merge preserving your changes + framework improvements |
| **(R)eplace** | Overwrite with framework version, save yours as `.bak` |
| **(K)eep** | Keep your version unchanged |
| **(N)ew-file** | Save framework version as `.new` for manual review |
| **(D)iff** | Show differences before deciding |

**Tip**: if you've heavily restructured a file, use **(N)ew-file** instead
of **(M)erge** — it gives you the framework version as a separate file.

### Publisher updates

For installed projects:

```bash
cco project update team-service        # Update one project (3-way merge)
cco project update --all               # Update all installed projects
cco project update team-service --dry-run  # Preview without applying
```

For installed packs:

```bash
cco pack update acme-conventions       # Update one pack (full-replace)
cco pack update --all                  # Update all installed packs
```

Packs use **full-replace** (not merge). Internalize first to preserve local
changes (see §7.4).

### The update chain

For installed projects, updates flow through a chain:

```
Framework defaults → Publisher's project → Your installation
```

- **Local projects** (`cco project create`): framework updates apply directly
  via `cco update --sync`
- **Installed projects** (`cco project install`): the publisher curates
  framework changes and publishes updates. You receive them via
  `cco project update`

If the publisher is slow or inactive:

```bash
cco update --sync team-service --local   # Apply framework defaults directly
cco project internalize team-service     # Disconnect permanently
```

### Internalizing resources

To permanently disconnect from a remote source:

```bash
cco project internalize team-service
cco pack internalize react-guidelines
```

After internalizing:
- The resource becomes fully local
- Framework updates apply directly via `cco update --sync`
- Publisher updates are no longer available
- Your customizations are preserved

---

## 8. Recommended Workflows

### Solo developer — single machine

```bash
cco init && cco vault init && cco project create my-app

# Daily: work, save, push
cco vault save "end of day snapshot"
cco vault push

# Periodic: check for framework updates
cco update && cco update --sync
```

### Solo developer — multiple machines

```bash
# Machine A
cco vault save "added new pack" && cco vault push

# Machine B
cco vault pull
# ... work ...
cco vault save "changes from machine B" && cco vault push
```

Use profiles for different project sets per machine:

```bash
# Work machine
cco vault profile create work
cco vault move project work-api work

# Personal machine
cco vault profile create personal
cco vault move project side-project personal
```

### Team — publisher workflow

```bash
cco remote add team https://github.com/company/team-config.git
cco project create api-service
# ... customize ...
cco project publish api-service team

# When framework updates arrive
cco update --sync api-service
cco project publish api-service team   # Publish updated version
```

**Best practices**: run `cco update` before publishing, use `.cco/publish-ignore`,
communicate changes via version field and commit messages.

### Team — consumer workflow

```bash
cco project install https://github.com/company/team-config.git
# ... customize for your needs ...

# Check and apply updates
cco update
cco project update api-service

# Vault your customizations
cco vault save "customized api-service" && cco vault push
```

**Best practices**: customize freely (3-way merge preserves changes), prefer
additive customizations, update regularly, vault before updating.

### Memory and session data

Each project has two separate directories:

- **`projects/<name>/memory/`** — Auto memory files. **Vault-tracked**, syncs
  across machines. Contains personal working notes and task progress.
- **`projects/<name>/.cco/claude-state/`** — Session transcripts. **Local only**
  (gitignored). Large and machine-specific.

---

## 9. Command Reference

### Vault

| Command | Purpose |
|---------|---------|
| `cco vault init [<path>]` | Initialize git-backed config versioning |
| `cco vault save [message] [--yes]` | Commit changes (with secret detection) |
| `cco vault save --dry-run` | Show summary without committing |
| `cco vault diff` | Show uncommitted changes by category |
| `cco vault log [--limit N]` | Show commit history |
| `cco vault status` | Show vault state, remotes, uncommitted changes |
| `cco vault restore <ref>` | Restore file from history |
| `cco vault switch <name>` | Switch to another profile (clean tree required) |
| `cco vault move <type> <name> <target>` | Move resource between profiles |
| `cco vault remove <type> <name>` | Remove resource from current branch |
| `cco vault push [<remote>]` | Push to remote |
| `cco vault pull [<remote>]` | Pull from remote |
| `cco vault remote add <n> <url>` | Add git remote |
| `cco vault remote remove <n>` | Remove git remote |
| `cco project delete <name> [--yes]` | Delete project from all branches |

### Profiles

| Command | Purpose |
|---------|---------|
| `cco vault profile create <name>` | Create a new profile (empty) |
| `cco vault profile list` | List all profiles |
| `cco vault profile show` | Show current profile details |
| `cco vault profile switch <name>` | Switch active profile (alias for `vault switch`) |
| `cco vault profile rename <name>` | Rename current profile |
| `cco vault profile delete <name>` | Delete profile (moves resources to main) |

### Updates

| Command | Purpose |
|---------|---------|
| `cco update` | Unified discovery (migrations + framework + remotes + changelog) |
| `cco update --sync [scope]` | Interactive framework file merge |
| `cco update --sync <project> --local` | Force framework sync on installed project |
| `cco update --diff [scope]` | Preview framework changes |
| `cco update --news` | Show changelog details |
| `cco update --offline` | Skip remote source checks |
| `cco update --no-cache` | Force fresh remote version check |
| `cco project update <name>` | Fetch and merge publisher updates |
| `cco project update --all` | Update all installed projects |
| `cco pack update <name>` | Update pack from remote (full-replace) |
| `cco pack update --all` | Update all installed packs |

### Publishing & Remotes

| Command | Purpose |
|---------|---------|
| `cco remote add <n> <url> [--token]` | Register a Config Repo remote |
| `cco remote remove <name>` | Unregister a remote |
| `cco remote list` | Show all registered remotes |
| `cco project publish <name> <remote>` | Publish with safety pipeline |
| `cco project publish <name> <remote> --yes` | Non-interactive publish |
| `cco pack publish <name> [remote]` | Publish pack to Config Repo |
| `cco pack export <name>` | Export pack as .tar.gz |

### Installing & Source Management

| Command | Purpose |
|---------|---------|
| `cco project install <url>` | Install project from Config Repo |
| `cco project resolve <name>` | Configure local paths for repos and mounts |
| `cco pack install <url>` | Install packs from Config Repo |
| `cco project internalize <name>` | Disconnect project from remote |
| `cco pack internalize <name>` | Disconnect pack from remote |

### Manifest

| Command | Purpose |
|---------|---------|
| `cco manifest refresh` | Regenerate manifest.yml from disk |
| `cco manifest validate` | Cross-check manifest vs disk |
| `cco manifest show` | Display formatted manifest contents |
