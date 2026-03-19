# Configuration Management

> Vault, profiles, Config Repos, publishing, installing, and updates — a unified guide.
>
> Related: [project-setup.md](./project-setup.md) | [knowledge-packs.md](./knowledge-packs.md) | [cli.md](../reference/cli.md)

---

## 1. The Big Picture

CCO manages your configuration across four dimensions:

| Dimension | What it solves | Key commands |
|-----------|---------------|--------------|
| **Vault** | Versioning and backup | `cco vault sync`, `push`, `pull` |
| **Profiles** | Multi-context isolation (work, personal) | `cco vault profile create`, `switch` |
| **Updates** | Keeping config current with framework and publishers | `cco update`, `cco project update` |
| **Sharing** | Publishing and installing projects and packs | `cco project publish`, `cco pack install` |

These form a coherent lifecycle:

```
Create / Install → Customize → Vault sync → Update → Publish / Share
       ↑                                        │
       └────────────────────────────────────────┘
```

---

## 2. Vault — Version Your Configuration

The vault is a git-backed versioning system for your entire `user-config/` directory.

### Getting started

```bash
cco vault init          # Initialize git repo in user-config/
cco vault sync          # Commit current state (with secret detection)
cco vault push          # Push to remote (set up a private GitHub repo)
cco vault pull          # Pull changes from remote
```

Add a remote for backup:

```bash
cco vault remote add origin git@github.com:youruser/cco-vault.git
```

### Day-to-day workflow

1. **Work on your projects** — edit rules, create packs, customize CLAUDE.md
2. **Sync periodically** — `cco vault sync "added deploy pack"` commits with a descriptive message
3. **Push to remote** — `cco vault push` backs up to your private repo

`cco vault sync` shows a categorized summary before committing and includes
**secret detection**: it scans for `.env` files, API keys, credentials, and
other sensitive patterns. If secrets are found, the commit is blocked.

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
Each profile is a git branch with isolated resources.

### When to use profiles

- **Work vs personal**: different projects, different conventions, different packs
- **Client A vs Client B**: separate project sets per client
- **Shared vs private**: some packs are shared across profiles, others are exclusive

### Creating and switching

```bash
cco vault profile create work       # Create "work" profile
cco vault profile create personal   # Create "personal" profile
cco vault profile switch work       # Switch to "work" context
cco vault profile list              # Show all profiles
cco vault profile show              # Show current profile details
```

### Resource isolation

Projects can be **exclusive** to a profile (visible only when active) or
**shared** (visible in all profiles via `main` branch).

```bash
cco vault profile add project my-work-app       # Make exclusive
cco vault profile add pack work-conventions      # Make pack exclusive
cco vault profile remove project my-work-app     # Make shared again
cco vault profile move project my-app --to personal  # Move between profiles
```

> **Note — Tracking-only isolation**: Profile assignment is a tracking
> declaration in `.vault-profile` — it does not physically move files.
> Isolation is enforced at sync time: `vault sync`, `vault push`, and
> `vault pull` selectively stage only the relevant resources.

### Profile sync strategy

When you switch profiles, resources sync automatically. For **shared
resources** (packs, global settings) modified in another profile, CCO detects
conflicts and offers interactive resolution.

**Best practice**: keep shared resources stable. Profile-specific customizations
should go in exclusive resources. If you need different versions of a shared
pack, make a copy exclusive to each profile instead of constantly merging.

Without profiles, the vault works on a single `main` branch. Profiles are
opt-in and only needed for selective sync.

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
| **Commands** | `cco vault push/pull/sync` | `cco pack publish/install`, `cco project publish/install` |

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

# Daily: work, sync, push
cco vault sync "end of day snapshot"
cco vault push

# Periodic: check for framework updates
cco update && cco update --sync
```

### Solo developer — multiple machines

```bash
# Machine A
cco vault sync "added new pack" && cco vault push

# Machine B
cco vault pull
# ... work ...
cco vault sync "changes from machine B" && cco vault push
```

Use profiles for different project sets per machine:

```bash
# Work machine
cco vault profile create work
cco vault profile add project work-api

# Personal machine
cco vault profile create personal
cco vault profile add project side-project
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
cco vault sync "customized api-service" && cco vault push
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
| `cco vault sync [message]` | Commit changes (with secret detection) |
| `cco vault sync --dry-run` | Show summary without committing |
| `cco vault diff` | Show uncommitted changes by category |
| `cco vault log [--limit N]` | Show commit history |
| `cco vault status` | Show vault state, remotes, uncommitted changes |
| `cco vault restore <ref>` | Restore file from history |
| `cco vault push [<remote>]` | Push to remote |
| `cco vault pull [<remote>]` | Pull from remote |
| `cco vault remote add <n> <url>` | Add git remote |
| `cco vault remote remove <n>` | Remove git remote |

### Profiles

| Command | Purpose |
|---------|---------|
| `cco vault profile create <name>` | Create a new profile |
| `cco vault profile list` | List all profiles |
| `cco vault profile show` | Show current profile details |
| `cco vault profile switch <name>` | Switch active profile |
| `cco vault profile rename <name>` | Rename current profile |
| `cco vault profile delete <name>` | Delete profile (moves resources to main) |
| `cco vault profile add project/pack <n>` | Make resource exclusive to profile |
| `cco vault profile remove project/pack <n>` | Make resource shared again |
| `cco vault profile move project/pack <n> --to <p>` | Move resource between profiles |

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
| `cco pack install <url>` | Install packs from Config Repo |
| `cco project internalize <name>` | Disconnect project from remote |
| `cco pack internalize <name>` | Disconnect pack from remote |

### Manifest

| Command | Purpose |
|---------|---------|
| `cco manifest refresh` | Regenerate manifest.yml from disk |
| `cco manifest validate` | Cross-check manifest vs disk |
| `cco manifest show` | Display formatted manifest contents |
